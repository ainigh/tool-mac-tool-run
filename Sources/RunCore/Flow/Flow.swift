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

/// Room left on this thread's stack. Reading, checking and running a flow each go one call deeper
/// for each level of nesting (and running, for each call of a function in the flow), so something
/// nested very deeply, or a function that calls itself forever, would use up the stack and crash
/// the app. Each stage asks this first, and stops with a message while there's still room.
/// Made on the thread that uses it: each thread has a stack of its own.
struct StackGuard {
    /// The stack may not go below this address (0: unknown, so no limit).
    private let floor: UInt

    init() {
        var low: UInt = 0, size: UInt = 0
        #if canImport(Darwin)
        let thread = pthread_self()
        size = UInt(pthread_get_stacksize_np(thread))
        low = UInt(bitPattern: pthread_get_stackaddr_np(thread)) - size
        #elseif os(Linux)
        // pthread_getattr_np is a GNU extension Swift's Glibc doesn't show, so it's looked up.
        typealias GetAttr = @convention(c) (pthread_t, UnsafeMutablePointer<pthread_attr_t>) -> Int32
        var attr = pthread_attr_t()
        if let symbol = dlsym(nil, "pthread_getattr_np"),
           unsafeBitCast(symbol, to: GetAttr.self)(pthread_self(), &attr) == 0 {
            var addr: UnsafeMutableRawPointer?
            var bytes = 0
            if pthread_attr_getstack(&attr, &addr, &bytes) == 0 {
                low = UInt(bitPattern: addr)
                size = UInt(bytes)
            }
            pthread_attr_destroy(&attr)
        }
        #endif
        // Keep a quarter of the stack (at most 256 KB) for what runs between two checks: a
        // builtin, Foundation, printing the message.
        floor = size == 0 ? 0 : low + min(size / 4, 256 * 1024)
    }

    /// False when the stack is nearly used up.
    var hasRoom: Bool {
        guard floor != 0 else { return true }
        var marker: UInt8 = 0
        return withUnsafeMutablePointer(to: &marker) { UInt(bitPattern: $0) } > floor
    }
}

/// What happens while a flow runs, for whoever shows it.
public enum FlowEvent: Sendable {
    /// A line from `print` (or from the flow itself: a step starting, a warning).
    case say(String)
    /// A script (or a line of shell) starting: its name, the command as typed in a terminal, and
    /// the line of the flow that runs it (0 for a flow run from a flow's own steps).
    case stepStarted(id: UUID, name: String, command: String, line: Int)
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
    /// Answers the flow's questions (nil: there's no one to ask).
    private let asker: (@Sendable (FlowQuestion) -> FlowAnswer)?
    /// For a script about to run: the question to ask first (it's marked "Ask Before Running"),
    /// or nil to run it straight away.
    private let askBefore: (@Sendable (ScriptItem) -> String?)?

    public init(library: Library, depth: Int = 0,
                asker: (@Sendable (FlowQuestion) -> FlowAnswer)? = nil,
                askBefore: (@Sendable (ScriptItem) -> String?)? = nil,
                events: @escaping @Sendable (FlowEvent) -> Void) {
        self.library = library
        self.depth = depth
        self.asker = asker
        self.askBefore = askBefore
        self.events = events
    }

    public func ask(_ question: FlowQuestion) -> FlowAnswer {
        guard let asker else { return .unavailable }
        return asker(question)
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
            if let prompt = askBefore?(item) {
                switch ask(FlowQuestion(kind: .proceed, prompt: prompt, line: pos.line)) {
                case .yes, .text: break
                case .unavailable:
                    throw FlowError(.run, pos, "\(item.id) is set to ask before it runs, and there's no one here to answer.",
                                    fix: "Run the flow from the app, or turn off Ask Before Running on its cell.")
                default:
                    throw FlowError(.stopped, pos, "Stopped: you chose not to run \(item.id).")
                }
            }
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

    /// `epa` with these words, in the folder: a step of its own, showing EPA's own words (not
    /// its JSON), with its questions asked through `ask`.
    public func runEPA(_ words: [String], pos: Pos) throws -> EPA.Outcome {
        let env = ShellEnvironment.shared.environment
        guard let program = EPA.find(path: env["PATH"] ?? "") else {
            throw FlowError(.run, pos, EPA.notSetUp, fix: EPA.setupFix)
        }
        let line = ([program] + EPA.arguments(words)).map(ShellEnvironment.quote).joined(separator: " ")
        let p = ScriptProcess(shell: "exec " + line, workingDirectory: library.root, environment: env)
        p.keepsInputOpen = true
        let id = UUID()
        let name = (["epa"] + words).joined(separator: " ")
        let events = self.events
        let session = EPA.Session(line: pos.line, ask: { [weak self] q in self?.ask(q) ?? .unavailable },
                                  send: { p.send($0) }, closeInput: { p.endInput() },
                                  show: { events(.stepOutput(id: id, stream: .out, text: $0)) })
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
        events(.stepStarted(id: id, name: name, command: EPA.commandLine(words, folder: library.root), line: pos.line))
        do {
            let r = try p.runToEnd { stream, text in
                if stream == .out { session.feed(text) } else { events(.stepOutput(id: id, stream: stream, text: text)) }
            }
            session.finish()
            let o = session.outcome(code: r.code)
            events(.stepFinished(id: id, name: name, result: RunResult(code: o.ok ? 0 : max(r.code, 1), out: o.text, err: r.err,
                                                                      seconds: r.seconds, signal: r.signal, stopped: r.stopped)))
            if p.wasStopped { throw FlowError(.stopped, pos, "Stopped.") }
            return o
        } catch let e as LaunchError {
            events(.stepFinished(id: id, name: name, result: RunResult(code: 127, out: "", err: e.description, seconds: 0)))
            throw FlowError(.run, pos, e.message, fix: e.fix)
        }
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
        events(.stepStarted(id: id, name: name, command: p.commandLine, line: pos.line))
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
        guard let source = try? String(contentsOf: flow.url, encoding: .utf8) else {
            throw FlowError(.run, pos, "Couldn't read \(flow.id).", fix: "Check it's still there and is UTF-8 text.")
        }
        let id = UUID()
        let started = Date()
        events(.stepStarted(id: id, name: flow.id, command: "flow run \(ShellEnvironment.quote(flow.id))", line: pos.line))
        let out = Collected()
        let parent = self
        let events = self.events
        let child = LocalFlowHost(library: library, depth: depth + 1, asker: asker, askBefore: askBefore) { event in
            if case let .say(text) = event {
                out.append(.out, text + "\n")
                events(.stepOutput(id: id, stream: .out, text: text + "\n"))
            } else if case let .stepStarted(stepID, name, command, _) = event {
                // Its line is in the other flow, not this one.
                events(.stepStarted(id: stepID, name: name, command: command, line: 0))
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
