import Foundation

/// The Flow language: a small F#-like language for composing the scripts in the folder (see
/// docs/FLOW-GUIDE.md). Check a flow first (it works out every type and catches mistakes before
/// anything runs), then run it.
public enum Flow {
    /// A flow that has been read and checked, ready to run.
    public struct Checked: @unchecked Sendable {
        /// The names it defines at its top level, with their types (shown beside the editor).
        public let bindings: [FlowBinding]
        let program: Expr
    }

    /// Reads and checks a flow. `scripts`: the names `run` may use (nil: don't check them).
    public static func check(_ source: String, scripts: [String]? = nil) throws -> Checked {
        let program = try Parser.parse(source)
        let bindings = try Checker(scripts: scripts).check(program)
        return Checked(bindings: bindings, program: program)
    }

    /// Runs a checked flow. Returns its last value.
    @discardableResult
    public static func run(_ checked: Checked, host: FlowHost, args: [String] = []) throws -> Value {
        let interpreter = Interpreter(host: host)
        return try interpreter.eval(checked.program, Interpreter.globals(args: args))
    }

    /// Checks, then runs.
    @discardableResult
    public static func run(_ source: String, host: FlowHost, scripts: [String]? = nil, args: [String] = []) throws -> Value {
        try run(check(source, scripts: scripts), host: host, args: args)
    }
}

/// What happens while a flow runs, for whoever shows it.
public enum FlowEvent: Sendable {
    /// A line from `print` (or from the flow itself: a step starting, a warning).
    case say(String)
    /// A script (or a line of shell) starting: its name and the command as typed in a terminal.
    case stepStarted(id: UUID, name: String, command: String)
    case stepOutput(id: UUID, stream: OutputStream, text: String)
    case stepFinished(id: UUID, name: String, result: RunResult)
    case notify(String)
}

/// Runs a flow's scripts from a folder, for real. The app and the `flow` command both use it;
/// each shows the events its own way.
public final class LocalFlowHost: FlowHost, @unchecked Sendable {
    public let library: Library
    private let events: @Sendable (FlowEvent) -> Void
    private let lock = NSLock()
    private var cancelled = false
    private var running: [UUID: ScriptProcess] = [:]
    /// How deep in flows run from flows (so a flow that runs itself stops).
    private let depth: Int

    public init(library: Library, depth: Int = 0, events: @escaping @Sendable (FlowEvent) -> Void) {
        self.library = library
        self.depth = depth
        self.events = events
    }

    public var environment: [String: String] { ShellEnvironment.shared.environment }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Stops the flow: the script running now is stopped, and nothing after it starts.
    public func cancel() {
        lock.lock()
        cancelled = true
        let procs = Array(running.values)
        lock.unlock()
        procs.forEach { $0.stop() }
    }

    public func say(_ text: String) { events(.say(text)) }
    public func notify(_ text: String) { events(.notify(text)) }

    /// Every name `run` can use: the scripts, then the flows.
    public static func names(in library: Library) -> [String] {
        library.scriptNames() + library.flows().map(\.id)
    }

    public func runScript(_ name: String, args: [String], stdin: String?, pos: Pos) throws -> RunResult {
        if let item = library.script(named: name) {
            let p = ScriptProcess(script: item.url, language: item.language, arguments: args, stdin: stdin, workingDirectory: library.root)
            return try execute(p, name: item.id, pos: pos)
        }
        let flows = library.flows()
        if let match = ScriptNames.match(name, in: flows.map(\.id)), let flow = flows.first(where: { $0.id == match }) {
            return try runFlow(flow, args: args, pos: pos)
        }
        let all = Self.names(in: library)
        throw FlowError(.run, pos, "There's no script called \"\(name)\" in \(library.root.path).",
                        fix: Checker.closest(name, among: all).map { "Did you mean \"\($0)\"?" } ?? "Add it to the folder, or check the name.")
    }

    public func runShell(_ command: String, stdin: String?, pos: Pos) throws -> RunResult {
        let p = ScriptProcess(shell: command, stdin: stdin, workingDirectory: library.root)
        return try execute(p, name: command, pos: pos)
    }

    private func execute(_ p: ScriptProcess, name: String, pos: Pos) throws -> RunResult {
        let id = UUID()
        lock.lock()
        if cancelled {
            lock.unlock()
            throw FlowError(.stopped, pos, "Stopped.")
        }
        running[id] = p
        lock.unlock()
        defer {
            lock.lock()
            running[id] = nil
            lock.unlock()
        }
        events(.stepStarted(id: id, name: name, command: p.commandLine))
        do {
            let events = self.events
            let r = try p.runToEnd { stream, text in events(.stepOutput(id: id, stream: stream, text: text)) }
            events(.stepFinished(id: id, name: name, result: r))
            if p.wasStopped { throw FlowError(.stopped, pos, "Stopped.") }
            return r
        } catch let e as LaunchError {
            let r = RunResult(code: 127, out: "", err: e.description, seconds: 0)
            events(.stepFinished(id: id, name: name, result: r))
            throw FlowError(.run, pos, e.message, fix: e.fix)
        }
    }

    /// A flow run from a flow: what it prints is its output.
    private func runFlow(_ flow: ScriptItem, args: [String], pos: Pos) throws -> RunResult {
        guard depth < 8 else {
            throw FlowError(.run, pos, "Flows running flows went 8 deep: \(flow.id) probably runs itself.")
        }
        let source = (try? String(contentsOf: flow.url, encoding: .utf8)) ?? ""
        let id = UUID()
        let started = Date()
        events(.stepStarted(id: id, name: flow.id, command: "flow run \(ShellEnvironment.quote(flow.id))"))
        let out = Collected()
        let parent = self
        let events = self.events
        let child = LocalFlowHost(library: library, depth: depth + 1) { event in
            if case let .say(text) = event {
                out.append(.out, text + "\n")
                events(.stepOutput(id: id, stream: .out, text: text + "\n"))
            } else {
                events(event)
            }
        }
        let watcher = CancelLink(parent: parent, child: child)
        defer { watcher.end() }
        do {
            try Flow.run(source, host: child, scripts: Self.names(in: library), args: args)
            let r = RunResult(code: 0, out: out.both.0, err: "", seconds: Date().timeIntervalSince(started))
            events(.stepFinished(id: id, name: flow.id, result: r))
            return r
        } catch let e as FlowError {
            if e.stage == .stopped { throw e }
            let r = RunResult(code: 1, out: out.both.0, err: "\(flow.id): \(e.description)", seconds: Date().timeIntervalSince(started))
            events(.stepFinished(id: id, name: flow.id, result: r))
            return r
        }
    }
}

/// Passes a stop on to a flow run from a flow, while it runs.
private final class CancelLink: @unchecked Sendable {
    private let timer: DispatchSourceTimer

    init(parent: LocalFlowHost, child: LocalFlowHost) {
        timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak parent, weak child] in
            if parent?.isCancelled == true { child?.cancel() }
        }
        timer.resume()
    }

    func end() { timer.cancel() }
}
