import Foundation
import RunCore

// flow: checks and runs .flow files from a terminal (the app runs them from the Composer grid).
//
//   flow run composer/morning.flow [args…]   check it, then run it
//   flow check composer/morning.flow         check it, and show the type of everything it defines
//   flow functions                           every builtin function, with its type
//
// The scripts it runs are the ones in the folder above `composer/` (or --folder <path>).

let usage = """
Usage:
  flow run <file.flow> [args…]     check a flow, then run it
  flow check <file.flow>           check a flow and show the type of each name it defines
  flow functions                   list the builtin functions and their types
  flow examples <folder>           put the example scripts and flows in a folder (keeps what's there)
Options:
  --folder <path>                  the scripts folder (default: the folder above composer/)

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

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(("❌ " + message + "\n").data(using: .utf8)!)
    exit(code)
}

setvbuf(stdout, nil, _IOLBF, 0)
var arguments = Array(CommandLine.arguments.dropFirst())
var folder: URL?
if let k = arguments.firstIndex(of: "--folder") {
    guard k + 1 < arguments.count else { fail("--folder needs a path after it.") }
    folder = URL(fileURLWithPath: (arguments[k + 1] as NSString).expandingTildeInPath)
    arguments.removeSubrange(k...(k + 1))
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
    let host = LocalFlowHost(library: lib) { event in
        switch event {
        case let .say(text):
            steps.flush()
            print(text)
        case let .stepStarted(_, name, cmd):
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
    signal(SIGINT, SIG_IGN)
    let source2 = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    source2.setEventHandler { host.cancel() }
    source2.resume()
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
