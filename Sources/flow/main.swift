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
    let host = LocalFlowHost(library: lib) { event in
        switch event {
        case let .say(text): print(text)
        case let .stepStarted(_, name, cmd): print(isatty(1) == 1 ? "👉 \(name)   \u{1B}[2m\(cmd)\u{1B}[0m" : "👉 \(name)   \(cmd)")
        case let .stepOutput(_, stream, text):
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let shown = lines.enumerated().map { k, l in k == lines.count - 1 && l.isEmpty ? "" : "   │ " + l }.joined(separator: "\n")
            FileHandle(fileDescriptor: stream == .out ? 1 : 2).write(shown.data(using: .utf8)!)
        case let .stepFinished(_, name, r):
            print(r.ok ? "✅ \(name) · \(String(format: "%.1f", r.seconds)) s" : "❌ \(name) · exit code \(r.code)")
        case let .notify(text): print("🔔 \(text)")
        }
    }
    signal(SIGINT, SIG_IGN)
    let source2 = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    source2.setEventHandler { host.cancel() }
    source2.resume()
    do {
        try Flow.run(source, host: host, scripts: LocalFlowHost.names(in: lib), args: Array(arguments.dropFirst(2)))
        print("✅ \(url.lastPathComponent) finished in \(String(format: "%.1f", Date().timeIntervalSince(started))) s.")
    } catch let e as FlowError {
        show(e, file: url)
    }
default:
    fail("I don't know the command \(command).\n\n" + usage)
}
