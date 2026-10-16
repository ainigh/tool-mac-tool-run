import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Which of a script's two outputs a piece of text came from.
public enum OutputStream: String, Codable, Sendable {
    case out, err
}

/// How a run ended: by itself, with an exit code, or by a signal (the one Stop sends, or another,
/// such as a crash).
public struct RunEnding: Equatable, Sendable {
    /// Its exit code. Ended by a signal: 128 + the signal, as a shell reports it.
    public var code: Int32
    /// The signal that ended it; nil when it exited by itself.
    public var signal: Int32?
    /// It ended because it was asked to stop (`ScriptProcess.stop()`).
    public var stopped: Bool
    public var ok: Bool { code == 0 && signal == nil }

    public init(code: Int32, signal: Int32? = nil, stopped: Bool = false) {
        self.code = code
        self.signal = signal
        self.stopped = stopped
    }

    /// From what the system says: an exit status, or the signal that ended it.
    init(status: Int32, bySignal: Bool, stopped: Bool) {
        self.init(code: bySignal ? 128 + status : status, signal: bySignal ? status : nil, stopped: stopped)
    }

    /// How it ended, said short: "exit code 3", "stopped", "killed by signal 11 (SIGSEGV)".
    public var summary: String {
        if stopped { return "stopped" }
        if let signal { return "killed by signal \(signal)" + (Self.signalName(signal).map { " (\($0))" } ?? "") }
        return "exit code \(code)"
    }

    /// SIGTERM, SIGKILL, SIGSEGV…: a signal's name (the numbers differ between macOS and Linux).
    public static func signalName(_ signal: Int32) -> String? {
        let names: [Int32: String] = [
            SIGHUP: "SIGHUP", SIGINT: "SIGINT", SIGQUIT: "SIGQUIT", SIGILL: "SIGILL", SIGTRAP: "SIGTRAP",
            SIGABRT: "SIGABRT", SIGBUS: "SIGBUS", SIGFPE: "SIGFPE", SIGKILL: "SIGKILL", SIGUSR1: "SIGUSR1",
            SIGSEGV: "SIGSEGV", SIGUSR2: "SIGUSR2", SIGPIPE: "SIGPIPE", SIGALRM: "SIGALRM", SIGTERM: "SIGTERM",
            SIGXCPU: "SIGXCPU", SIGXFSZ: "SIGXFSZ", SIGSYS: "SIGSYS",
        ]
        return names[signal]
    }
}

/// What a finished script left: its exit code, everything it printed, how long it took.
public struct RunResult: Equatable, Sendable {
    /// Its exit code (ended by a signal: 128 + the signal).
    public var code: Int32
    public var out: String
    public var err: String
    public var seconds: Double
    /// The signal that ended it; nil when it exited by itself.
    public var signal: Int32?
    /// It ended because it was asked to stop.
    public var stopped: Bool
    public var ok: Bool { code == 0 && signal == nil }

    public init(code: Int32, out: String, err: String, seconds: Double, signal: Int32? = nil, stopped: Bool = false) {
        self.code = code
        self.out = out
        self.err = err
        self.seconds = seconds
        self.signal = signal
        self.stopped = stopped
    }

    /// How it ended.
    public var ending: RunEnding { RunEnding(code: code, signal: signal, stopped: stopped) }
}

/// A script that couldn't be started, said so a person can fix it.
public struct LaunchError: Error, CustomStringConvertible, Equatable {
    public let message: String
    /// The fix, when there's one to name.
    public let fix: String?
    public var description: String { fix.map { "\(message)\n→ fix: \($0)" } ?? message }

    public init(_ message: String, fix: String? = nil) {
        self.message = message
        self.fix = fix
    }
}

/// One run of a script: started with its interpreter, its output handed over as it's printed, and
/// stopped on request (politely first, then for good, with everything it started).
///
/// A script with a `#!` line is run by what that line names, with its words (as macOS runs it,
/// without needing it to be executable); one without, by its language's program. A text file with
/// neither is run by /bin/sh, as a shell would.
public final class ScriptProcess: @unchecked Sendable {
    public let script: URL
    public let language: ScriptLanguage
    public let arguments: [String]

    private let process = Process()
    private let input: String?
    /// A line of shell run with `bash -c` instead of a file.
    private var inline: String?
    private let lock = NSLock()
    /// How many times it's been asked to stop.
    private var stops = 0
    private var pid: pid_t = 0
    /// It leads a process group of its own, so a signal can reach everything it started too.
    private var ownGroup = false
    private var leaderExited = false
    /// The script's own exit status, or the signal that ended it.
    private var leaderStatus: (status: Int32, bySignal: Bool)?
    private var ended = false
    /// Output isn't read any more (the script ended; something it left in the background holds it open).
    private var abandoned = false
    private var abandonNoted = false
    private var finalEnding: RunEnding?
    /// Its input, while it's kept open for typing (`keepsInputOpen`).
    private var inputHandle: FileHandle?
    private let inputQueue = DispatchQueue(label: "ToolMacToolRun.input")

    /// Its input stays open after `stdin` is written, for answers typed while it runs (`send`),
    /// until `endInput` (or it ends). Otherwise it reads an empty input once `stdin` is written.
    public var keepsInputOpen = false

    /// Seconds from asking it to stop (SIGTERM) to ending it for good (SIGKILL, to its whole group).
    var killGrace: TimeInterval = 2
    /// Seconds its output is still read once the script itself has ended, while something it
    /// started in the background holds the output open. Then the run ends anyway.
    var drainGrace: TimeInterval = 2

    /// `stdin`: text handed to the script as its input (nil: none, it reads an empty input).
    public init(script: URL, language: ScriptLanguage, arguments: [String] = [], stdin: String? = nil,
                workingDirectory: URL? = nil, environment: [String: String] = ShellEnvironment.shared.environment) {
        self.script = script
        self.language = language
        self.arguments = arguments
        self.input = stdin
        process.currentDirectoryURL = workingDirectory ?? script.deletingLastPathComponent()
        var env = environment
        env["TMR_SCRIPT"] = script.path
        process.environment = env
    }

    /// One line of shell (`bash -c`), run in `workingDirectory`.
    public convenience init(shell command: String, stdin: String? = nil, workingDirectory: URL,
                            environment: [String: String] = ShellEnvironment.shared.environment) {
        self.init(script: workingDirectory, language: .bash, stdin: stdin, workingDirectory: workingDirectory, environment: environment)
        inline = command
    }

    /// The folder it runs in.
    public var workingDirectory: URL { process.currentDirectoryURL ?? script.deletingLastPathComponent() }

    /// What's run, as it would be typed in a terminal: `cd '<its folder>' && <the command>`, the
    /// same program and words the run uses (pasted in a terminal, it does what the app does).
    public var commandLine: String {
        "cd \(ShellEnvironment.quote(workingDirectory.path)) && " + invocation
    }

    /// The command alone, without the `cd` (`/bin/bash /Users/me/Scripts/hello.sh friend`).
    public var invocation: String { launch.shown }

    // MARK: how it's started

    /// The program that's started, the words after it, and how that reads in a terminal. `problem`:
    /// why it can't start (its program is missing), found before trying.
    struct Launch {
        var executable: String
        var arguments: [String]
        var shown: String
        var problem: LaunchError?
    }

    private var launch: Launch {
        Self.launch(script: script, language: language, arguments: arguments, inline: inline,
                    path: process.environment?["PATH"] ?? "")
    }

    static func launch(script: URL, language: ScriptLanguage, arguments: [String], inline: String?, path: String) -> Launch {
        func words(_ w: [String]) -> String { w.map(ShellEnvironment.quote).joined(separator: " ") }
        let fm = FileManager.default
        if let inline {
            let found = find("bash", path: path) != nil
            return Launch(executable: "/usr/bin/env", arguments: ["bash", "-c", inline], shown: inline,
                          problem: found ? nil : LaunchError("Running a line of shell needs `bash`, and it isn't on the PATH.", fix: Remedy.install("bash")))
        }
        let name = script.lastPathComponent
        let head = Library.head(of: script)
        if let head, let shebang = Shebang.parse(head), shebang.interpreter.hasPrefix("/") {
            let all = shebang.arguments + [script.path] + arguments
            let shown = shebang.plainEnv ? words(all) : words([shebang.interpreter] + all)
            var problem: LaunchError?
            if !fm.isExecutableFile(atPath: shebang.interpreter) {
                problem = LaunchError("\(name) is run by \(shebang.interpreter) (its first line, #!), and that isn't there.",
                                      fix: Remedy.interpreter(shebang.interpreter))
            } else if shebang.usesEnv {
                if let program = shebang.program {
                    if find(program, path: path) == nil {
                        problem = LaunchError("\(name) is run by `\(program)` (its first line, #!), and it isn't installed (or isn't on the PATH).",
                                              fix: program.contains("/") ? Remedy.interpreter(program) : Remedy.install(program))
                    }
                } else {
                    problem = LaunchError("\(name)'s first line (#!\(shebang.interpreter) \(shebang.arguments.joined(separator: " "))) doesn't name a program.",
                                          fix: "Name one after env, such as #!/usr/bin/env python3")
                }
            }
            return Launch(executable: shebang.interpreter, arguments: all, shown: shown, problem: problem)
        }
        if let cmd = language.command {
            let all = [cmd.program] + cmd.leading + [script.path] + arguments
            let found = find(cmd.program, path: path) != nil
            return Launch(executable: "/usr/bin/env", arguments: all, shown: words(all),
                          problem: found ? nil : LaunchError("\(language.title) scripts need `\(cmd.program)`, and it isn't installed (or isn't on the PATH).",
                                                             fix: Remedy.install(cmd.program)))
        }
        if language == .executable {
            if head != nil {
                // Text with no #! line: what a shell does with it (it can't be started as a program).
                let all = [script.path] + arguments
                return Launch(executable: "/bin/sh", arguments: all, shown: words(["sh"] + all), problem: nil)
            }
            return Launch(executable: script.path, arguments: arguments, shown: words([script.path] + arguments), problem: nil)
        }
        return Launch(executable: script.path, arguments: arguments, shown: words([script.path] + arguments),
                      problem: LaunchError("Couldn't tell what language \(name) is written in.",
                                           fix: "Add a first line naming its program, such as #!/bin/bash or #!/usr/bin/env python3, or give the file an extension (.sh, .py, .js…)."))
    }

    /// The program a script needs, and where it was found (nil: missing). Nil when it needs none
    /// (a program run as it is).
    static func requirement(script: URL, language: ScriptLanguage, path: String) -> (program: String, found: String?)? {
        if let head = Library.head(of: script), let shebang = Shebang.parse(head), shebang.interpreter.hasPrefix("/") {
            let fm = FileManager.default
            guard shebang.usesEnv else {
                return (shebang.interpreter, fm.isExecutableFile(atPath: shebang.interpreter) ? shebang.interpreter : nil)
            }
            guard let program = shebang.program, fm.isExecutableFile(atPath: shebang.interpreter) else { return (shebang.interpreter, nil) }
            return (program, find(program, path: path))
        }
        guard let cmd = language.command else { return nil }
        return (cmd.program, find(cmd.program, path: path))
    }

    private static func find(_ program: String, path: String) -> String? { ShellEnvironment.find(program, path: path) }

    // MARK: running

    /// Starts it. `output` is called (on a background thread) with each piece of text as it's
    /// printed; `exit` once, after the last of it, with the exit code (128 + the signal when a
    /// signal ended it). Throws when it can't start, saying why and what fixes it.
    public func start(output: @escaping @Sendable (OutputStream, String) -> Void,
                      exit: @escaping @Sendable (Int32) -> Void) throws {
        try start(output: output, ended: { exit($0.code) })
    }

    /// Starts it. `output` is called (on a background thread) with each piece of text as it's
    /// printed; `ended` once, after the last of it, with how it ended. Throws when it can't start,
    /// saying why and what fixes it.
    public func start(output: @escaping @Sendable (OutputStream, String) -> Void,
                      ended: @escaping @Sendable (RunEnding) -> Void) throws {
        let launch = self.launch
        if let problem = launch.problem { throw problem }
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments

        let out = Pipe(), err = Pipe(), inPipe = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = inPipe
        let done = DispatchGroup()
        done.enter()
        let grace = drainGrace
        let leaderEnded = Once()
        let onLeaderExit: @Sendable ((status: Int32, bySignal: Bool)) -> Void = { status in
            leaderEnded.run {
                self.lock.lock()
                self.leaderExited = true
                self.leaderStatus = status
                self.lock.unlock()
                // Something it started in the background may hold its output open for ever: read
                // what's left for a moment, then stop waiting.
                DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
                    self.lock.lock()
                    if !self.ended { self.abandoned = true }
                    self.lock.unlock()
                }
                done.leave()
            }
        }
        process.terminationHandler = { p in onLeaderExit((p.terminationStatus, p.terminationReason == .uncaughtSignal)) }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            let executable = FileManager.default.isExecutableFile(atPath: script.path)
            throw LaunchError("Couldn't start \(script.lastPathComponent): \(error.localizedDescription)",
                              fix: language != .executable ? nil
                                  : executable ? "It isn't a program this computer can run. If it's a script, add a first line naming its program, such as #!/bin/bash or #!/usr/bin/env python3."
                                  : "Make it executable: chmod +x \(ShellEnvironment.quote(script.path))")
        }
        let pid = process.processIdentifier
        let group = getpgid(pid)
        lock.lock()
        self.pid = pid
        // Foundation starts it as the leader of a group of its own; gone already (-1), it was too.
        ownGroup = group == pid || group < 0
        let stopAsked = stops > 0
        lock.unlock()
        if stopAsked {
            send(SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + killGrace) { self.send(SIGKILL, evenAfterEnd: true) }
        }
        #if os(Linux)
        // Foundation on Linux only notices the script ended once everything it started has ended
        // too: watch for the script itself.
        let process = self.process
        Thread.detachNewThread {
            var wait: useconds_t = 2_000
            while true {
                if let status = exitStatus(of: process) {
                    onLeaderExit(status)
                    return
                }
                usleep(wait)
                wait = min(wait * 2, 50_000)
            }
        }
        #endif

        // The parent's copies of the script's ends: closed, so a read ends when the script's do,
        // and a write fails (rather than waits) when the script is gone.
        try? out.fileHandleForWriting.close()
        try? err.fileHandleForWriting.close()
        try? inPipe.fileHandleForReading.close()
        for (pipe, stream) in [(out, OutputStream.out), (err, OutputStream.err)] {
            done.enter()
            let handle = pipe.fileHandleForReading
            Thread.detachNewThread {
                self.pump(handle.fileDescriptor, stream, output)
                try? handle.close()
                done.leave()
            }
        }
        let writer = inPipe.fileHandleForWriting
        let data = input.flatMap { $0.data(using: .utf8) } ?? Data()
        let keepOpen = keepsInputOpen
        if keepOpen {
            lock.lock()
            inputHandle = writer
            lock.unlock()
        }
        inputQueue.async {
            // A script that stops reading (or never reads) is fine: the rest isn't wanted.
            if !data.isEmpty { _ = writeAll(data, to: writer.fileDescriptor) }
            if !keepOpen { try? writer.close() }
        }
        done.notify(queue: .global()) {
            self.lock.lock()
            self.ended = true
            let status = self.leaderStatus ?? (0, false)
            let ending = RunEnding(status: status.status, bySignal: status.bySignal, stopped: self.stops > 0)
            self.finalEnding = ending
            self.lock.unlock()
            self.process.terminationHandler = nil
            self.endInput()
            ended(ending)
        }
    }

    /// Types a line (or any text) into its input, while it's kept open. False when it isn't.
    @discardableResult
    public func send(_ text: String) -> Bool {
        lock.lock()
        let handle = inputHandle
        lock.unlock()
        guard let handle else { return false }
        let data = Data(text.utf8)
        inputQueue.async { _ = writeAll(data, to: handle.fileDescriptor) }
        return true
    }

    /// Closes its input (as Control-D does in a terminal): what reads it to the end goes on.
    public func endInput() {
        lock.lock()
        let handle = inputHandle
        inputHandle = nil
        lock.unlock()
        guard let handle else { return }
        inputQueue.async { try? handle.close() }
    }

    /// Whether its input is still open for typing.
    public var acceptsInput: Bool {
        lock.lock()
        defer { lock.unlock() }
        return inputHandle != nil
    }

    /// Reads one of its outputs until it's closed (or abandoned), handing the text on.
    private func pump(_ fd: Int32, _ stream: OutputStream, _ output: @Sendable (OutputStream, String) -> Void) {
        let decoder = UTF8Chunker()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if isAbandoned {
                lock.lock()
                let first = !abandonNoted
                abandonNoted = true
                lock.unlock()
                if first {
                    output(.err, "\n⚠️ It ended, but something it started is still running and holding its output open: what that prints isn't shown.\n")
                }
                break
            }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&p, 1, 100)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 { continue }
            let n = buffer.withUnsafeMutableBytes { readSome(fd, $0) }
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                break
            }
            if n == 0 { break }
            let text = decoder.feed(Data(buffer[0..<n]))
            if !text.isEmpty { output(stream, text) }
        }
        let rest = decoder.finish()
        if !rest.isEmpty { output(stream, rest) }
    }

    private var isAbandoned: Bool {
        lock.lock()
        defer { lock.unlock() }
        return abandoned
    }

    /// Asks it to stop: SIGTERM to it and everything it started (its process group), and SIGKILL
    /// to all of them two seconds on if any are still there. Asked again, SIGKILL at once. Works
    /// too when the script itself has ended but something it started still holds its output.
    public func stop() {
        lock.lock()
        guard pid > 0, !ended else {
            // Not started yet: it's stopped as soon as it is (a Stop in that moment isn't lost).
            if pid == 0, !ended { stops += 1 }
            lock.unlock()
            return
        }
        stops += 1
        let first = stops == 1
        lock.unlock()
        if first {
            send(SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + killGrace) { self.send(SIGKILL, evenAfterEnd: true) }
        } else {
            send(SIGKILL, evenAfterEnd: true)
        }
    }

    /// `evenAfterEnd`: the run has ended (the script died and its output closed), but something
    /// it started that ignored SIGTERM can still be in its group: Stop's SIGKILL reaches it too.
    private func send(_ sig: Int32, evenAfterEnd: Bool = false) {
        lock.lock()
        let pid = self.pid, group = ownGroup, leaderGone = leaderExited, over = ended
        lock.unlock()
        guard pid > 0, !over || evenAfterEnd else { return }
        // The group outlives its leader while anything in it is running; when nothing is, this
        // fails (ESRCH) and there's nothing to do.
        if group { kill(-pid, sig) }
        if !leaderGone, !over { kill(pid, sig) }
    }

    public var wasStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stops > 0
    }

    /// How it ended (nil while it runs, or if it never started).
    public var ending: RunEnding? {
        lock.lock()
        defer { lock.unlock() }
        return finalEnding
    }

    /// Runs it to the end, handing each piece of output to `output` as it comes, and returns all of it.
    public func runToEnd(output: @escaping @Sendable (OutputStream, String) -> Void = { _, _ in }) throws -> RunResult {
        let started = Date()
        let collected = Collected()
        let finished = DispatchSemaphore(value: 0)
        let ending = Box<RunEnding>(RunEnding(code: 0))
        try start(output: { stream, text in
            collected.append(stream, text)
            output(stream, text)
        }, ended: { e in
            ending.value = e
            finished.signal()
        })
        finished.wait()
        let (o, e) = collected.both
        let end = ending.value
        return RunResult(code: end.code, out: o, err: e, seconds: Date().timeIntervalSince(started), signal: end.signal, stopped: end.stopped)
    }
}

/// Writes all of `data` to `fd`. False when the reader went away (EPIPE): the script stopped
/// reading, which is no failure. On macOS the pipe is marked F_SETNOSIGPIPE, so a write raises no
/// SIGPIPE at all (there, one raised by a write can go to any thread, so blocking it here wouldn't
/// be enough). Elsewhere SIGPIPE is held back on this thread while it writes (and one raised by it
/// is taken back before the thread goes on), so it can't end the process.
///
/// SIGPIPE isn't ignored for the whole process instead: Foundation's Process hands an ignored
/// SIGPIPE on to the scripts it starts (seen on Linux), and in a script `yes | head` and the like
/// would then print "Broken pipe" errors instead of ending quietly.
@discardableResult
func writeAll(_ data: Data, to fd: Int32) -> Bool {
    #if canImport(Darwin)
    _ = fcntl(fd, F_SETNOSIGPIPE, 1)
    #endif
    var pipeOnly = sigset_t()
    sigemptyset(&pipeOnly)
    sigaddset(&pipeOnly, SIGPIPE)
    var previous = sigset_t()
    pthread_sigmask(SIG_BLOCK, &pipeOnly, &previous)
    defer {
        var pending = sigset_t()
        sigpending(&pending)
        if sigismember(&pending, SIGPIPE) == 1 {
            var taken: Int32 = 0
            sigwait(&pipeOnly, &taken)
        }
        pthread_sigmask(SIG_SETMASK, &previous, nil)
    }
    return data.withUnsafeBytes { raw -> Bool in
        guard let base = raw.baseAddress else { return true }
        var offset = 0
        while offset < raw.count {
            let n = writeSome(fd, base + offset, raw.count - offset)
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return false  // EPIPE: it stopped reading (or another error: nothing more to do)
            }
            offset += n
        }
        return true
    }
}

/// How `process` ended (its exit status, or the signal that ended it); nil while it runs.
///
/// Foundation on Linux learns a process ended from a socket the process inherits, so it only
/// notices once everything the process started (which inherits it too) has ended: there, this
/// asks the system directly (`waitid` with WNOWAIT, leaving the process for Foundation to reap).
func exitStatus(of process: Process) -> (status: Int32, bySignal: Bool)? {
    if !process.isRunning { return (process.terminationStatus, process.terminationReason == .uncaughtSignal) }
    #if os(Linux)
    let pid = process.processIdentifier
    var info = siginfo_t()
    if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0, info._sifields._sigchld.si_pid == pid {
        let code = info.si_code
        return (info._sifields._sigchld.si_status, code == Int32(CLD_KILLED) || code == Int32(CLD_DUMPED))
    }
    #endif
    return nil
}

private func readSome(_ fd: Int32, _ buffer: UnsafeMutableRawBufferPointer) -> Int {
    read(fd, buffer.baseAddress, buffer.count)
}

private func writeSome(_ fd: Int32, _ bytes: UnsafeRawPointer, _ count: Int) -> Int {
    write(fd, bytes, count)
}

/// The failure → fix table: how to get a missing program, by name.
public enum Remedy {
    static let packages: [String: String] = [
        "python3": "brew install python", "node": "brew install node", "npx": "brew install node",
        "deno": "brew install deno", "ruby": "brew install ruby", "perl": "brew install perl",
        "php": "brew install php", "lua": "brew install lua", "fish": "brew install fish",
        "go": "brew install go", "Rscript": "brew install r", "pwsh": "brew install --cask powershell",
        "swift": "xcode-select --install", "osascript": "AppleScript only runs on a Mac",
        "zsh": "brew install zsh", "bash": "brew install bash", "bun": "brew install oven-sh/bun/bun",
        "tsx": "npm install -g tsx", "ts-node": "npm install -g ts-node",
        "epa": "Run setup-epa on the Scripts grid (Add the EPA Recipes puts it there)",
    ]

    /// The command that installs `program` (Homebrew's, on a Mac).
    public static func install(_ program: String) -> String {
        let name = (program as NSString).lastPathComponent
        if let p = packages[name] ?? (name.hasPrefix("python") ? packages["python3"] : nil) { return "\(p), then run it again." }
        return "Install \(name) (for example: brew install \(name)), then run it again."
    }

    /// The fix for a `#!` line naming a program by a path that isn't there.
    public static func interpreter(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        let dir = (path as NSString).deletingLastPathComponent
        if ["/bin", "/usr/bin", "/usr/local/bin", "/opt/homebrew/bin"].contains(dir) {
            return install(name).replacingOccurrences(of: ", then run it again.", with: "")
                + ", or change the script's first line to #!/usr/bin/env \(name) (it then uses the one on the PATH)."
        }
        return "Check that \(path) is there (a virtual environment that was moved or deleted?), or change the script's first line to #!/usr/bin/env \(name)."
    }
}

/// UTF-8 text from pieces of data that can split a character in two: the split part is kept for
/// the next piece.
final class UTF8Chunker: @unchecked Sendable {
    private var pending = Data()

    func feed(_ data: Data) -> String {
        pending.append(data)
        // How many bytes at the end start a character that isn't complete yet.
        var cut = pending.count
        var back = 0
        while back < 4, cut - back - 1 >= 0 {
            let b = pending[pending.startIndex + cut - back - 1]
            if b & 0b1100_0000 == 0b1000_0000 { back += 1; continue }  // continuation byte
            let need = b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : b >= 0xC0 ? 2 : 1
            if need > back + 1 { cut -= back + 1 }
            break
        }
        let ready = pending.prefix(cut)
        let text = String(decoding: ready, as: UTF8.self)
        pending = Data(pending.suffix(from: pending.startIndex + cut))
        return text
    }

    func finish() -> String {
        defer { pending = Data() }
        return String(decoding: pending, as: UTF8.self)
    }
}

final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var out = "", err = ""
    func append(_ s: OutputStream, _ t: String) {
        lock.lock()
        if s == .out { out += t } else { err += t }
        lock.unlock()
    }
    var both: (String, String) {
        lock.lock()
        defer { lock.unlock() }
        return (out, err)
    }
}

final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

/// Something done once, however many times it's asked for.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}
