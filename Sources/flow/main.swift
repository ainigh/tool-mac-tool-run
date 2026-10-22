import Foundation
import RunCore

// flow: checks and runs .flow files from a terminal (the app runs them from the Composer grid).
//
//   flow run composer/morning.flow [args…]   check it, then run it
//   flow check composer/morning.flow         check it, and show the type of everything it defines
//   flow functions                           every builtin function, with its type
//
// The scripts it runs are the ones in the folder above `composer/` (or --folder <path>), and its
// `utilities/` and `browser/` folders.

let usage = """
Usage:
  flow run <file.flow> [args…]     check a flow, then run it (its questions are asked here)
  flow check <file.flow>           check a flow and show the type of each name it defines
  flow functions                   list the builtin functions and their types
  flow examples <folder>           put the example scripts, utilities, browser scripts and flows in a folder (keeps what's there)
  flow recipes <folder>            put the EPA recipes in a folder: setup-epa, epa-keys and the epa-… flows
Options:
  --folder <path>                  the scripts folder (default: the folder above composer/)
  --yes                            answer Continue and Yes to every question (with no one at the keyboard)

The guide: docs/FLOW-GUIDE.md
"""

/// What a step prints, shown under it with "   │ " at the start of each line. Each output keeps
/// its unfinished last line until its line break comes (or the step ends), so lines from stdout
/// and stderr come out whole, one after the other, and the next status line starts on a line of
/// its own.
final class StepOutput: @unchecked Sendable {
    private let lock = NSLock()
    /// The unfinished last line of each output.
    private var partial: [RunCore.OutputStream: String] = [:]
    /// A line of that output has been started on screen (a long one, shown before its end).
    private var midLine: [RunCore.OutputStream: Bool] = [:]
    private static let bar = "   │ "

    func add(_ stream: RunCore.OutputStream, _ text: String) {
        lock.lock()
        defer { lock.unlock() }
        var pending = (partial[stream] ?? "") + text
        var shown = ""
        let scalars = pending.unicodeScalars
        if let lastBreak = scalars.lastIndex(of: "\n") {
            let whole = scalars[...lastBreak].split(separator: "\n", omittingEmptySubsequences: false).dropLast()
            for line in whole {
                shown += (midLine[stream] == true ? "" : Self.bar) + String(String.UnicodeScalarView(line)) + "\n"
                midLine[stream] = false
            }
            pending = String(String.UnicodeScalarView(scalars[scalars.index(after: lastBreak)...]))
        }
        // A very long line with no break yet: show what's there, and carry on with it later.
        if pending.utf8.count > 16_384 {
            shown += (midLine[stream] == true ? "" : Self.bar) + pending
            midLine[stream] = true
            pending = ""
        }
        partial[stream] = pending
        write(stream, shown)
    }

    /// Shows what's left of each output's last line, ending it with a line break.
    func flush() {
        lock.lock()
        defer { lock.unlock() }
        for stream in [RunCore.OutputStream.out, .err] {
            let pending = partial[stream] ?? ""
            if !pending.isEmpty {
                write(stream, (midLine[stream] == true ? "" : Self.bar) + pending + "\n")
            } else if midLine[stream] == true {
                write(stream, "\n")
            }
            partial[stream] = ""
            midLine[stream] = false
        }
    }

    private func write(_ stream: RunCore.OutputStream, _ text: String) {
        guard !text.isEmpty else { return }
        fflush(stdout)
        FileHandle(fileDescriptor: stream == .out ? 1 : 2).write(Data(text.utf8))
    }
}

/// Asks a flow's question at the terminal (on /dev/tty, so it works while output is piped).
/// End of input, or "stop", is Stop.
final class TerminalAsker: @unchecked Sendable {
    private let lock = NSLock()
    private let yes: Bool
    private let flush: () -> Void
    private let cancelLock = NSLock()
    private var cancelled = false

    init(yes: Bool, flush: @escaping () -> Void) {
        self.yes = yes
        self.flush = flush
    }

    /// Control-C: a question being asked ends now, as Stop (and so does any asked after).
    func cancel() {
        cancelLock.lock()
        cancelled = true
        cancelLock.unlock()
    }

    private var isCancelled: Bool {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        return cancelled
    }

    func ask(_ q: FlowQuestion) -> FlowAnswer {
        lock.lock()
        defer { lock.unlock() }
        flush()
        // A result is in the output already: nothing to wait for at a terminal.
        if q.kind == .result { return .yes }
        if yes {
            switch q.kind {
            case .proceed where q.destructive:
                // --yes approves going on, never what can't be undone (as EPA's own --yes).
                print("❓ \(q.prompt) → no (--yes doesn't approve what can't be undone: run it at a terminal to answer)")
                return .no
            case .text where q.secret:
                print("❓ \(q.prompt) → no answer (--yes can't type a secret: put it in .env)")
                return .unavailable
            case .proceed, .yesNo:
                print("❓ \(q.prompt) → yes (--yes)")
                return .yes
            case .text, .choice:
                print("❓ \(q.prompt)")
                return .unavailable
            case .result:
                return .yes
            }
        }
        guard let tty = fopen("/dev/tty", "r+") else { return .unavailable }
        defer { fclose(tty) }
        func say(_ s: String) {
            fputs(s, tty)
            fflush(tty)
        }
        // A line typed, read a byte at a time (and not through stdio's buffer) so a Control-C
        // ends the wait at once rather than at the next Return. Nil: end of input, or Control-C.
        func line() -> String? {
            let fd = fileno(tty)
            var bytes: [UInt8] = []
            while !isCancelled {
                var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&p, 1, 100)
                if ready < 0, errno != EINTR { return nil }
                if ready <= 0 { continue }
                var b: UInt8 = 0
                let n = read(fd, &b, 1)
                if n < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    return nil
                }
                if n == 0 { return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self) }
                if b == UInt8(ascii: "\n") { return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .newlines) }
                bytes.append(b)
            }
            return nil
        }
        while true {
            switch q.kind {
            case .proceed where q.destructive:
                say("⚠️ \(q.prompt) [go ahead/stop] ")
                guard let a = line()?.lowercased() else { return .stop }
                if a == "go ahead" || a == "yes" { return .yes }
                if a.isEmpty || "stop".hasPrefix(a) || a == "n" || a == "no" { return .stop }
            case .proceed:
                say("❓ \(q.prompt) [Continue/stop] ")
                guard let a = line()?.lowercased() else { return .stop }
                if a.isEmpty || "continue".hasPrefix(a) || a == "y" || a == "yes" { return .yes }
                if "stop".hasPrefix(a) || a == "n" || a == "no" { return .stop }
            case .yesNo:
                say("❓ \(q.prompt) [yes/no/stop] ")
                guard let a = line()?.lowercased() else { return .stop }
                if a == "y" || a == "yes" { return .yes }
                if a == "n" || a == "no" { return .no }
                if a == "stop" { return .stop }
            case .text:
                say("❓ \(q.prompt) ")
                // A secret isn't shown as it's typed.
                var saved = termios()
                let hide = q.secret && tcgetattr(fileno(tty), &saved) == 0
                if hide {
                    var quiet = saved
                    quiet.c_lflag &= ~tcflag_t(ECHO)
                    tcsetattr(fileno(tty), TCSANOW, &quiet)
                }
                let a = line()
                if hide {
                    tcsetattr(fileno(tty), TCSANOW, &saved)
                    say("\n")
                }
                guard let a else { return .stop }
                return .text(a)
            case let .choice(options):
                say("❓ \(q.prompt)\n")
                for (k, o) in options.enumerated() { say("   \(k + 1). \(o)\n") }
                say("   Pick 1–\(options.count) (or stop): ")
                guard let a = line() else { return .stop }
                if a.lowercased() == "stop" { return .stop }
                if let n = Int(a), n >= 1, n <= options.count { return .text(options[n - 1]) }
                if let o = options.first(where: { $0.lowercased() == a.lowercased() }) { return .text(o) }
            case .result:
                return .yes
            }
            say("   (I didn't get that: try again.)\n")
        }
    }
}

/// Where the Control-C handler writes (a handler can only do something this small).
var interruptFD: Int32 = -1

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(("❌ " + message + "\n").data(using: .utf8)!)
    exit(code)
}

setvbuf(stdout, nil, _IOLBF, 0)
var arguments = Array(CommandLine.arguments.dropFirst())
// The options come before the .flow file: what follows it is the flow's own arguments, passed
// on as they are (a flow can be given --folder or --yes of its own).
func optionIndex(_ name: String) -> Int? {
    let fileAt = arguments.firstIndex { $0.hasSuffix(".flow") } ?? arguments.count
    return arguments[..<fileAt].firstIndex(of: name)
}
var folder: URL?
if let k = optionIndex("--folder") {
    guard k + 1 < arguments.count, !arguments[k + 1].hasSuffix(".flow") else { fail("--folder needs a path after it.") }
    folder = URL(fileURLWithPath: (arguments[k + 1] as NSString).expandingTildeInPath)
    arguments.removeSubrange(k...(k + 1))
}
// --yes: nobody's at the keyboard; every confirm goes on.
var answerYes = false
if let k = optionIndex("--yes") {
    answerYes = true
    arguments.remove(at: k)
}
guard let command = arguments.first else {
    print(usage)
    exit(0)
}

func library(for file: URL) -> Library {
    if let folder { return Library(root: folder) }
    let dir = file.deletingLastPathComponent()
    return Library(root: dir.lastPathComponent == "composer" ? dir.deletingLastPathComponent() : dir)
}

func load(_ path: String?) -> (URL, String) {
    guard let path else { fail("Name the .flow file.\n\n" + usage) }
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    guard let source = try? String(contentsOf: url, encoding: .utf8) else { fail("Couldn't read \(path).") }
    return (url, source)
}

func show(_ error: FlowError, file: URL) -> Never {
    fail("\(file.lastPathComponent), " + error.description, code: error.stage == .stopped ? 130 : 1)
}

switch command {
case "functions":
    var group = ""
    for b in Builtin.all {
        if b.group != group {
            group = b.group
            print("\n\(group)")
        }
        print("  \(b.name) : \(b.signature)")
        print("      \(b.summary)")
    }
case "examples":
    guard let path = arguments.dropFirst().first ?? folder?.path else { fail("Name the folder.\n\n" + usage) }
    let lib = Library(root: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
    do {
        let added = try lib.addExamples()
        if added.isEmpty { print("— The examples are already in \(lib.root.path): nothing to add.") }
        for url in added { print("✅ Added \(url.path)") }
        print("Next: flow run \(ShellEnvironment.quote(lib.composerFolder.appendingPathComponent("morning.flow").path))")
    } catch {
        fail("Couldn't add the examples: \(error.localizedDescription)")
    }
case "recipes":
    guard let path = arguments.dropFirst().first ?? folder?.path else { fail("Name the folder.\n\n" + usage) }
    let lib = Library(root: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
    do {
        let added = try lib.addEPARecipes()
        if added.isEmpty { print("— The EPA recipes are already in \(lib.root.path): nothing to add.") }
        for url in added { print("✅ Added \(url.path)") }
        if EPA.find(path: ShellEnvironment.shared.environment["PATH"] ?? "") == nil {
            print("Next: set EPA up: \(ShellEnvironment.quote(lib.root.appendingPathComponent(EPA.setupScript).path))")
        } else {
            print("Next: flow run \(ShellEnvironment.quote(lib.composerFolder.appendingPathComponent("epa-check-connections.flow").path))")
        }
    } catch {
        fail("Couldn't add the EPA recipes: \(error.localizedDescription)")
    }
case "check":
    let (url, source) = load(arguments.dropFirst().first)
    let lib = library(for: url)
    do {
        let checked = try Flow.check(source, scripts: LocalFlowHost.names(in: lib))
        print("✅ \(url.lastPathComponent) checks out.")
        for b in checked.bindings { print("   line \(b.line): \(b.name) : \(b.type)") }
    } catch let e as FlowError {
        show(e, file: url)
    }
case "run":
    let (url, source) = load(arguments.dropFirst().first)
    let lib = library(for: url)
    let started = Date()
    let steps = StepOutput()
    let asker = TerminalAsker(yes: answerYes) { steps.flush() }
    let host = LocalFlowHost(library: lib, asker: { asker.ask($0) }) { event in
        switch event {
        case let .say(text):
            steps.flush()
            print(text)
        case let .stepStarted(_, name, cmd, _):
            steps.flush()
            print(isatty(1) == 1 ? "👉 \(name)   \u{1B}[2m\(cmd)\u{1B}[0m" : "👉 \(name)   \(cmd)")
        case let .stepOutput(_, stream, text):
            steps.add(stream, text)
        case let .stepFinished(_, name, r):
            steps.flush()
            print(r.ok ? "✅ \(name) · \(String(format: "%.1f", r.seconds)) s"
                : r.stopped ? "⏹ \(name) · stopped" : "❌ \(name) · \(r.ending.summary)")
        case let .notify(text):
            steps.flush()
            print("🔔 \(text)")
        }
    }
    // Control-C stops the flow: its scripts are stopped too, and a question waiting is answered
    // Stop at once. Caught by a handler rather than ignored, so a script it starts never inherits
    // an ignored Control-C (a caught signal goes back to its default in a program started).
    var pipeEnds: [Int32] = [0, 0]
    guard pipe(&pipeEnds) == 0 else { fail("Couldn't set up Control-C.") }
    interruptFD = pipeEnds[1]
    let readEnd = pipeEnds[0]
    signal(SIGINT) { _ in
        var b: UInt8 = 1
        _ = write(interruptFD, &b, 1)
    }
    Thread.detachNewThread {
        var b: UInt8 = 0
        while true {
            let n = read(readEnd, &b, 1)
            if n < 0, errno == EINTR { continue }
            if n <= 0 { return }
            asker.cancel()
            host.cancel()
        }
    }
    do {
        defer { steps.flush() }
        try Flow.run(source, host: host, scripts: LocalFlowHost.names(in: lib), args: Array(arguments.dropFirst(2)))
        steps.flush()
        print("✅ \(url.lastPathComponent) finished in \(String(format: "%.1f", Date().timeIntervalSince(started))) s.")
    } catch let e as FlowError {
        show(e, file: url)
    }
default:
    fail("I don't know the command \(command).\n\n" + usage)
}
