import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Which of a script's two outputs a piece of text came from.
public enum OutputStream: String, Codable, Sendable {
    case out, err
}

/// What a finished script left: its exit code, everything it printed, how long it took.
public struct RunResult: Equatable, Sendable {
    public var code: Int32
    public var out: String
    public var err: String
    public var seconds: Double
    public var ok: Bool { code == 0 }

    public init(code: Int32, out: String, err: String, seconds: Double) {
        self.code = code
        self.out = out
        self.err = err
        self.seconds = seconds
    }
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
/// stopped on request (politely first, then for good).
public final class ScriptProcess: @unchecked Sendable {
    public let script: URL
    public let language: ScriptLanguage
    public let arguments: [String]

    private let process = Process()
    private let input: String?
    /// A line of shell run with `bash -c` instead of a file.
    private var inline: String?
    private let lock = NSLock()
    private var stopped = false

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

    /// What's run, as it would be typed in a terminal.
    public var commandLine: String {
        if let inline { return inline }
        let parts: [String]
        if let cmd = language.command {
            parts = [cmd.program] + cmd.leading + [script.path] + arguments
        } else {
            parts = [script.path] + arguments
        }
        return parts.map(ShellEnvironment.quote).joined(separator: " ")
    }

    /// Starts it. `output` is called (on a background queue) with each piece of text as it's
    /// printed; `exit` once, after the last of it, with the exit code. Throws when it can't start,
    /// saying why and what fixes it.
    public func start(output: @escaping @Sendable (OutputStream, String) -> Void,
                      exit: @escaping @Sendable (Int32) -> Void) throws {
        let env = process.environment ?? [:]
        let path = env["PATH"] ?? ""
        if let cmd = language.command {
            guard ShellEnvironment.find(cmd.program, path: path) != nil else {
                throw LaunchError("\(language.title) scripts need `\(cmd.program)`, and it isn't installed (or isn't on the PATH).",
                                  fix: Remedy.install(cmd.program))
            }
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            if let inline {
                process.arguments = [cmd.program, "-c", inline]
            } else {
                process.arguments = [cmd.program] + cmd.leading + [script.path] + arguments
            }
        } else if language == .executable {
            process.executableURL = script
            process.arguments = arguments
        } else {
            throw LaunchError("Couldn't tell what language \(script.lastPathComponent) is written in.",
                              fix: "Add a first line naming its program, such as #!/bin/bash or #!/usr/bin/env python3, or give the file an extension (.sh, .py, .js…).")
        }

        let out = Pipe(), err = Pipe(), inPipe = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = inPipe
        let done = DispatchGroup()
        var readers: [() -> Void] = []
        for (pipe, stream) in [(out, OutputStream.out), (err, OutputStream.err)] {
            done.enter()
            let handle = pipe.fileHandleForReading
            // A blocking read on a thread of its own: it ends when the script (and whatever it
            // started that holds the output open) is done.
            readers.append {
                let decoder = UTF8Chunker()
                while true {
                    let data = handle.availableData
                    if data.isEmpty { break }
                    let text = decoder.feed(data)
                    if !text.isEmpty { output(stream, text) }
                }
                let rest = decoder.finish()
                if !rest.isEmpty { output(stream, rest) }
                try? handle.close()
                done.leave()
            }
        }
        done.enter()
        process.terminationHandler = { _ in done.leave() }
        do {
            try process.run()
        } catch {
            throw LaunchError("Couldn't start \(script.lastPathComponent): \(error.localizedDescription)",
                              fix: language == .executable ? "Make it executable: chmod +x \(ShellEnvironment.quote(script.path))" : nil)
        }
        // The parent's copies of the write ends: closed, so a read ends when the script's do.
        try? out.fileHandleForWriting.close()
        try? err.fileHandleForWriting.close()
        for reader in readers { DispatchQueue.global().async(execute: reader) }
        let writer = inPipe.fileHandleForWriting
        let text = input
        DispatchQueue.global().async {
            if let text, let data = text.data(using: .utf8) { try? writer.write(contentsOf: data) }
            try? writer.close()
        }
        let process = self.process
        done.notify(queue: .global()) { exit(process.terminationStatus) }
    }

    /// Asks it to stop (SIGTERM, and its children with it), and ends it for good two seconds on
    /// if it hasn't.
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard process.isRunning, !stopped else { return }
        stopped = true
        let pid = process.processIdentifier
        kill(-pid, SIGTERM)
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [process] in
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    public var wasStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    /// Runs it to the end, handing each piece of output to `output` as it comes, and returns all of it.
    public func runToEnd(output: @escaping @Sendable (OutputStream, String) -> Void = { _, _ in }) throws -> RunResult {
        let started = Date()
        let collected = Collected()
        let finished = DispatchSemaphore(value: 0)
        let code = Box<Int32>(0)
        try start(output: { stream, text in
            collected.append(stream, text)
            output(stream, text)
        }, exit: { status in
            code.value = status
            finished.signal()
        })
        finished.wait()
        let (o, e) = collected.both
        return RunResult(code: code.value, out: o, err: e, seconds: Date().timeIntervalSince(started))
    }
}

/// The failure → fix table: how to get a missing program, by name.
public enum Remedy {
    static let packages: [String: String] = [
        "python3": "brew install python", "node": "brew install node", "npx": "brew install node",
        "deno": "brew install deno", "ruby": "brew install ruby", "perl": "brew install perl",
        "php": "brew install php", "lua": "brew install lua", "fish": "brew install fish",
        "go": "brew install go", "Rscript": "brew install r", "pwsh": "brew install --cask powershell",
        "swift": "xcode-select --install", "osascript": "AppleScript only runs on a Mac",
        "zsh": "brew install zsh", "bash": "brew install bash",
    ]

    /// The command that installs `program` (Homebrew's, on a Mac).
    public static func install(_ program: String) -> String {
        if let p = packages[program] { return "\(p), then run it again." }
        return "Install \(program) (for example: brew install \(program)), then run it again."
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
