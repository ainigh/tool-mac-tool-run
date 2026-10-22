import AppKit
import Combine
import RunCore

/// Every run: the ones going now (with what they print, as they print it) and the ones before,
/// kept between launches. The cells, the Runs window and the menu all read it.
@MainActor
final class RunStore: ObservableObject {
    /// The runs, oldest first. Changed in place (the array isn't copied for each piece of output),
    /// with one change announced per batch.
    private var store: [RunRecord] = []
    var records: [RunRecord] { store }
    /// Never changed: it's here so the synthesized `objectWillChange` (sent by hand for `store`)
    /// is the one SwiftUI listens to.
    @Published private var anchor = 0

    private var processes: [UUID: ScriptProcess] = [:]
    private var hosts: [UUID: LocalFlowHost] = [:]
    /// Script runs waiting for the login shell's PATH before they start (only ever the first runs).
    private var waitingToStart: Set<UUID> = []
    /// The scripts' environment, once it has been read (off the main thread).
    private var environment: [String: String]?
    /// Output waiting to be shown: gathered off the main thread, shown ten times a second.
    private let pending = PendingOutput()
    private var flushScheduled = false
    private var saveTask: Task<Void, Never>?
    private let writer = HistoryWriter()
    /// How many times each run's output has changed (the output views follow it, even once the
    /// output is at its cap and its length stays the same).
    private var versions: [UUID: Int] = [:]
    /// The last line of each running run's output, worked out once per batch (the cells show it).
    private var lastLines: [UUID: String] = [:]
    /// When each running run last printed something (or started): silence reads as broken, so
    /// the cells say how long it's been quiet.
    private var lastOutputAt: [UUID: Date] = [:]
    /// Runs already told about for taking long (once each).
    private var toldSlow: Set<UUID> = []
    private var watchTimer: Timer?

    /// After how many seconds a run still going is worth a notification (0: never).
    static let slowKey = "notifyAfterSeconds"
    static var slowAfter: Int {
        get { UserDefaults.standard.object(forKey: slowKey) as? Int ?? 60 }
        set { UserDefaults.standard.set(newValue, forKey: slowKey) }
    }

    init() {
        store = RunHistory.load()
        trimToCap()
        // Every few seconds: is anything taking long, or gone quiet?
        watchTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watch() }
        }
        // Read the login shell's PATH now, off the main thread, so the first run doesn't wait for it.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let env = ShellEnvironment.shared.environment
            Task { @MainActor in self?.environment = env }
        }
    }

    var runningCount: Int { store.filter { $0.state == .running && $0.parent == nil }.count }

    /// The latest top-level runs, newest first.
    func recent(_ n: Int) -> [RunRecord] {
        Array(store.reversed().filter { $0.parent == nil }.prefix(n))
    }

    /// The latest run of a cell's script or flow.
    func latest(file: String, kind: GridKind) -> RunRecord? {
        let k: RunRecord.Kind = kind.isFlow ? .flow : .script
        return store.last { $0.file == file && $0.kind == k }
    }

    /// The latest run of a grid's script or flow, whichever cell it was (what its result pane shows).
    func latestTop(_ kind: GridKind) -> RunRecord? {
        if kind.isFlow { return store.last { $0.parent == nil && $0.kind == .flow } }
        return store.last { $0.parent == nil && $0.kind == .script && GridKind.of(scriptID: $0.file ?? "") == kind }
    }

    func record(_ id: UUID) -> RunRecord? { store.first { $0.id == id } }

    func steps(of id: UUID) -> [RunRecord] { store.filter { $0.parent == id } }

    /// Goes up by one each time the run's output changes.
    func version(_ id: UUID) -> Int { versions[id] ?? 0 }

    /// The last line a running run printed (what its cell shows).
    func lastLine(_ id: UUID) -> String? { lastLines[id] }

    /// How long a running run has printed nothing, in seconds (0 when it isn't running).
    func quietFor(_ id: UUID, now: Date = Date()) -> TimeInterval {
        guard let since = lastOutputAt[id], isRunning(id) else { return 0 }
        return now.timeIntervalSince(since)
    }

    /// A long run: a notification (once) that it's still going, with what it last printed and a
    /// click to watch it. Seconds pass on the cells and in Runs by themselves.
    private func watch() {
        let after = Self.slowAfter
        guard after > 0 else { return }
        let now = Date()
        for r in store where r.state == .running && r.parent == nil && !toldSlow.contains(r.id) {
            let secs = now.timeIntervalSince(r.started)
            guard secs >= Double(after) else { continue }
            toldSlow.insert(r.id)
            // Waiting on a question: that has its own notice.
            if PromptCenter.shared.pending(for: r.id) != nil { continue }
            var body = "Still running after \(RunRecord.duration(secs))."
            if quietFor(r.id, now: now) >= 30 {
                body += " It hasn't printed anything for \(RunRecord.duration(quietFor(r.id, now: now)))" + (acceptsInput(r.id) ? ": it may be waiting for you to type something." : ".")
            } else if let line = lastLines[r.id] {
                body += " Last: \(line.prefix(80))"
            }
            Notifier.post(title: r.name, body: body + " Click to watch it (or stop it).", run: r.id, tone: .running)
        }
    }

    private func index(_ id: UUID) -> Int? { store.lastIndex { $0.id == id } }

    private func change(_ id: UUID, _ body: (inout RunRecord) -> Void) {
        guard let i = index(id) else { return }
        body(&store[i])
    }

    /// Adds output to a run, keeping its version and last line up to date.
    private func append(at i: Int, _ stream: RunCore.OutputStream, _ text: String, dropped: Bool = false) {
        store[i].append(stream, text)
        if dropped { store[i].trimmed = true }
        let id = store[i].id
        versions[id, default: 0] += 1
        if store[i].state == .running { lastLines[id] = Self.tailLine(store[i].output) }
    }

    private func append(_ id: UUID, _ stream: RunCore.OutputStream, _ text: String) {
        guard let i = index(id) else { return }
        append(at: i, stream, text)
    }

    /// The last non-empty line of some output, looking only at its end.
    static func tailLine(_ chunks: [RunRecord.Chunk]) -> String? {
        var tail = ""
        for c in chunks.reversed() {
            let need = 4096 - tail.utf8.count
            if need <= 0 { break }
            tail = String(c.text.suffix(need)) + tail
        }
        guard let last = tail.split(whereSeparator: \.isNewline).last else { return nil }
        let line = last.trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? nil : line
    }

    // MARK: running a script

    /// Runs a script with its arguments. Returns the run (it shows on the cell at once).
    /// `stdin`: text handed to it as its input. `requestedBy`: the app that asked for it over the
    /// API (and was allowed).
    @discardableResult
    func run(script item: ScriptItem, arguments: [String], folder: URL, stdin: String? = nil, requestedBy: String? = nil, why: String? = nil) -> UUID {
        // The command, for the record (an empty environment: working it out isn't needed for this).
        let command = ScriptProcess(script: item.url, language: item.language, arguments: arguments,
                                    workingDirectory: folder, environment: [:]).commandLine
        var rec = RunRecord(kind: .script, name: item.id, file: item.id, arguments: arguments, command: command)
        rec.requestedBy = requestedBy
        rec.why = why
        let id = rec.id
        objectWillChange.send()
        store.append(rec)
        if let env = environment {
            launch(id, item: item, arguments: arguments, folder: folder, stdin: stdin, environment: env)
        } else {
            // The login shell's PATH is still being read: wait for it off the main thread.
            waitingToStart.insert(id)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let env = ShellEnvironment.shared.environment
                Task { @MainActor in
                    guard let self else { return }
                    self.environment = env
                    // Stopped while it waited: it never starts.
                    guard self.waitingToStart.remove(id) != nil else { return }
                    self.launch(id, item: item, arguments: arguments, folder: folder, stdin: stdin, environment: env)
                }
            }
        }
        return id
    }

    private func launch(_ id: UUID, item: ScriptItem, arguments: [String], folder: URL, stdin: String?, environment env: [String: String]) {
        let p = ScriptProcess(script: item.url, language: item.language, arguments: arguments, stdin: stdin,
                              workingDirectory: folder, environment: env)
        // It asks for typed answers: its input stays open for them (Runs and the editor show a place
        // to type). Unless it was given its input.
        p.keepsInputOpen = item.asksForInput && stdin == nil
        lastOutputAt[id] = Date()
        let pending = self.pending
        do {
            try p.start(output: { [weak self] stream, text in
                if pending.add(id, stream, text) {
                    Task { @MainActor in self?.scheduleFlush() }
                }
            }, ended: { [weak self] ending in
                Task { @MainActor in self?.finished(id, ending) }
            })
            processes[id] = p
        } catch {
            let problem = (error as? LaunchError)?.description ?? error.localizedDescription
            objectWillChange.send()
            change(id) { r in
                r.finish(code: nil, state: .couldNotStart)
                r.problem = problem
            }
            save()
        }
    }

    private func finished(_ id: UUID, _ ending: RunEnding) {
        flush()
        processes[id] = nil
        objectWillChange.send()
        change(id) { $0.finish(ending) }
        lastLines[id] = nil
        lastOutputAt[id] = nil
        if let r = record(id) {
            tellIfLong(r)
            AutomationCenter.shared.runEnded(r)
        }
        save()
    }

    // MARK: running a flow

    /// Checks a flow and runs it on a thread of its own; each script it runs is a step under it.
    @discardableResult
    func run(flow item: ScriptItem, arguments: [String], library: Library, requestedBy: String? = nil, why: String? = nil) -> UUID {
        var rec = RunRecord(kind: .flow, name: item.id, file: item.id, arguments: arguments,
                            command: "flow run \(ShellEnvironment.quote(item.url.path))" + arguments.map { " " + ShellEnvironment.quote($0) }.joined())
        rec.requestedBy = requestedBy
        rec.why = why
        let source: String
        do {
            source = try String(contentsOf: item.url, encoding: .utf8)
        } catch {
            rec.finish(code: nil, state: .couldNotStart)
            rec.problem = "Couldn't read \(item.id): \(error.localizedDescription)"
            objectWillChange.send()
            store.append(rec)
            save()
            return rec.id
        }
        return start(flow: source, record: rec, arguments: arguments, library: library,
                     fix: "Open the flow with the pencil to fix it.")
    }

    /// Runs Flow code that isn't in a file (another app sent it over the API, and it was allowed;
    /// or a tile of the API board made it). It's in Runs under `name`; it has no cell. `command`:
    /// what Runs shows was run; `fix`: what to do when the code has a mistake.
    @discardableResult
    func run(flowSource source: String, name: String, arguments: [String], library: Library, requestedBy: String?,
             command: String = "flow code sent over the API", fix: String? = nil, why: String? = nil) -> UUID {
        var rec = RunRecord(kind: .flow, name: name, file: nil, arguments: arguments, command: command)
        rec.requestedBy = requestedBy
        rec.why = why
        return start(flow: source, record: rec, arguments: arguments, library: library,
                     fix: fix ?? "It came from \(requestedBy ?? "another app"): it's for that app to fix.")
    }

    private func start(flow source: String, record: RunRecord, arguments: [String], library: Library, fix: String) -> UUID {
        var rec = record
        let id = rec.id
        let flowName = rec.name
        let names = LocalFlowHost.names(in: library)
        let checked: Flow.Checked
        do {
            checked = try Flow.check(source, scripts: names)
        } catch let e as FlowError {
            rec.finish(code: nil, state: .couldNotStart)
            rec.problem = "\(flowName), \(e.description)\n\nNothing was run. \(fix)"
            objectWillChange.send()
            store.append(rec)
            save()
            return id
        } catch {
            rec.finish(code: nil, state: .couldNotStart)
            rec.problem = "\(flowName) couldn't be checked: \(error.localizedDescription)\n\nNothing was run."
            objectWillChange.send()
            store.append(rec)
            save()
            return id
        }
        objectWillChange.send()
        store.append(rec)
        lastOutputAt[id] = Date()
        let pending = self.pending
        // A script asks from inside a flow as its cell does: when it's set to Ask Before Running,
        // or when it looks like it does something that can't be undone (unless set never to ask).
        let app = AppModel.shared
        let askSettings = GridKind.scriptGrids.reduce(into: [String: Bool]()) { all, kind in
            all.merge(app.settings(kind).ask) { mine, _ in mine }
        }
        let host = LocalFlowHost(library: library, asker: { question in
            PromptCenter.ask(run: id, from: flowName, question)
        }, askBefore: { script in
            guard askSettings[script.id] ?? !script.dangers.isEmpty else { return nil }
            return script.dangers.isEmpty ? "Run \(script.id)? (It's set to ask before it runs.)"
                : "Run \(script.id)? It looks like it \(GridActions.list(script.dangers))."
        }) { [weak self] event in
            if pending.event(id, event) {
                Task { @MainActor in self?.scheduleFlush() }
            }
        }
        hosts[id] = host
        // A thread with a big stack: a deeply nested flow reaches the interpreter's own depth limit
        // (and says so) long before it could overflow the stack.
        let thread = Thread { [weak self] in
            var outcome: (RunRecord.State, String?)
            do {
                try Flow.run(checked, host: host, args: arguments)
                outcome = (.succeeded, nil)
            } catch let e as FlowError {
                outcome = e.stage == .stopped ? (.stopped, nil) : (.failed, "\(flowName), \(e.description)")
            } catch {
                outcome = (.failed, error.localizedDescription)
            }
            let result = outcome
            Task { @MainActor in self?.flowFinished(id, state: result.0, problem: result.1) }
        }
        thread.stackSize = 256 << 20
        thread.name = "flow \(flowName)"
        thread.start()
        return id
    }

    private func flowFinished(_ id: UUID, state: RunRecord.State, problem: String?) {
        flush()
        hosts[id] = nil
        lastOutputAt[id] = nil
        PromptCenter.shared.cancel(run: id)
        objectWillChange.send()
        if let i = index(id) {
            store[i].finish(code: state == .succeeded ? 0 : 1, state: state)
            store[i].problem = problem
            if let p = problem { append(at: i, .err, "\n❌ " + p + "\n") }
        }
        // Steps still marked running (stopped mid-way) are stopped.
        for i in store.indices where store[i].parent == id && store[i].state == .running {
            store[i].finish(code: nil, state: .stopped)
            lastLines[store[i].id] = nil
        }
        lastLines[id] = nil
        if let r = record(id) {
            tellIfLong(r)
            AutomationCenter.shared.runEnded(r)
        }
        save()
    }

    // MARK: stopping

    /// Stops a run. A flow's step stops its flow (the step's script is the flow's to stop).
    func stop(_ id: UUID) {
        if waitingToStart.remove(id) != nil {
            objectWillChange.send()
            change(id) { $0.finish(code: nil, state: .stopped) }
            save()
            return
        }
        if let p = processes[id] {
            p.stop()
            return
        }
        if let h = hosts[id] {
            h.cancel()
            // A question it's waiting on is answered Stop.
            PromptCenter.shared.cancel(run: id)
            return
        }
        if let parent = record(id)?.parent, parent != id {
            stop(parent)
        }
    }

    func stopAll() {
        for id in waitingToStart { stop(id) }
        processes.values.forEach { $0.stop() }
        hosts.values.forEach { $0.cancel() }
        for id in hosts.keys { PromptCenter.shared.cancel(run: id) }
    }

    func isRunning(_ id: UUID) -> Bool { processes[id] != nil || hosts[id] != nil || waitingToStart.contains(id) }

    /// A flow that was asked to stop (it may still be on its way out).
    func isStopping(_ id: UUID) -> Bool { hosts[id]?.isCancelled == true }

    // MARK: typing into a run

    /// Whether a running script takes typed answers now.
    func acceptsInput(_ id: UUID) -> Bool { processes[id]?.acceptsInput == true }

    /// Types a line into a running script (shown in its output, as a terminal would, unless it's hidden).
    func send(_ id: UUID, _ line: String, echo: Bool = true) {
        guard let p = processes[id], p.send(line + "\n") else { return }
        note(id, echo ? line : String(repeating: "•", count: min(line.count, 8)))
    }

    /// A line in a run's output from the app (a question asked, its answer, what was typed).
    func note(_ id: UUID, _ text: String) {
        flush()
        guard index(id) != nil else { return }
        objectWillChange.send()
        append(id, .out, text + "\n")
        lastOutputAt[id] = Date()
    }

    /// Ends a running script's input (Control-D in a terminal).
    func endInput(_ id: UUID) {
        processes[id]?.endInput()
        objectWillChange.send()
    }

    /// Something is still going (a script, a flow, or a run about to start).
    var hasLiveRuns: Bool { !processes.isEmpty || !hosts.isEmpty || !waitingToStart.isEmpty }

    /// Forgets the finished runs (the ones going stay).
    func clearFinished() {
        let keep = Set(store.filter { $0.state == .running }.map(\.id))
        objectWillChange.send()
        store.removeAll { !keep.contains($0.id) && !keep.contains($0.parent ?? UUID()) }
        forgetGone()
        save()
    }

    // MARK: output, ten times a second

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            MainActor.assumeIsolated {
                self?.flushScheduled = false
                self?.flush()
            }
        }
    }

    /// Shows what's been gathered: every run's new output at once, in one change.
    func flush() {
        let batch = pending.take()
        guard !batch.events.isEmpty || !batch.outputs.isEmpty else { return }
        objectWillChange.send()
        var outputs = batch.outputs
        for (flow, event) in batch.events {
            // A step's output goes on before it's marked finished.
            if case let .stepFinished(stepID, _, _) = event, let buffer = outputs.removeValue(forKey: stepID) {
                apply(buffer, to: stepID)
            }
            apply(event, flow: flow)
        }
        for (id, buffer) in outputs { apply(buffer, to: id) }
    }

    private func apply(_ buffer: PendingOutput.Buffer, to id: UUID) {
        guard let i = index(id) else { return }
        let now = Date()
        lastOutputAt[id] = now
        if let parent = store[i].parent { lastOutputAt[parent] = now }
        for (n, piece) in buffer.pieces.enumerated() {
            append(at: i, piece.stream, piece.text, dropped: n == 0 && buffer.dropped)
        }
    }

    private func apply(_ event: FlowEvent, flow: UUID) {
        switch event {
        case .say, .stepOutput:
            break  // their text came with the output
        case let .stepStarted(id, name, command, line):
            var step = RunRecord(id: id, kind: .step, name: name, file: nil, command: command, parent: flow)
            step.state = .running
            step.line = line > 0 ? line : nil
            store.append(step)
            lastOutputAt[flow] = Date()
        case let .stepFinished(id, _, result):
            if let i = index(id) {
                if store[i].output.isEmpty && !result.err.isEmpty { append(at: i, .err, result.err) }
                store[i].finish(result.ending)
            }
            lastLines[id] = nil
        case let .notify(text):
            Notifier.post(title: record(flow)?.name ?? "Flow", body: text, run: flow, tone: .info)
        }
    }

    // MARK: keeping them

    /// Keeps the latest `RunHistory.keep` top-level runs (and any still running), each flow with
    /// its steps.
    private func trimToCap() {
        let cap = RunHistory.keep
        var topLevel = 0
        for r in store where r.parent == nil { topLevel += 1 }
        guard topLevel > cap else { return }
        var keep = Set<UUID>()
        var counted = 0
        for r in store.reversed() where r.parent == nil {
            if counted < cap || r.state == .running { keep.insert(r.id) }
            counted += 1
        }
        store.removeAll { r in
            if let parent = r.parent { return !keep.contains(parent) && r.state != .running }
            return !keep.contains(r.id)
        }
        forgetGone()
    }

    /// Drops what's kept about runs that are gone.
    private func forgetGone() {
        let ids = Set(store.map(\.id))
        versions = versions.filter { ids.contains($0.key) }
        lastLines = lastLines.filter { ids.contains($0.key) }
        lastOutputAt = lastOutputAt.filter { ids.contains($0.key) }
        toldSlow = toldSlow.filter { ids.contains($0) }
    }

    private func save() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.objectWillChange.send()
            self.trimToCap()
            // Written off the main thread; a newer save replaces one not written yet.
            self.writer.write(self.store)
        }
    }

    /// Writes the history now, waiting for it (when quitting).
    func saveNow() {
        flush()
        saveTask?.cancel()
        trimToCap()
        writer.waitUntilIdle()
        try? RunHistory.save(store)
    }

    /// A run that took a while, finishing while you're elsewhere: a notification says how it went
    /// (one that was told about for taking long always says how it ended).
    private func tellIfLong(_ r: RunRecord) {
        guard r.parent == nil, let secs = r.seconds, secs >= 15 || toldSlow.contains(r.id) else { return }
        if NSApp.isActive && !toldSlow.contains(r.id) { return }
        var body = "\(r.state.title) after \(RunRecord.duration(secs))."
        if r.state == .failed, let problem = r.problem ?? r.ending.map(\.summary) { body += " \(problem.prefix(120))" }
        Notifier.post(title: r.name, body: body, run: r.id, tone: Theme.tone(r.state))
    }
}

/// Writes the run history on a queue of its own, the newest only when saves come faster than writes.
final class HistoryWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ToolMacToolRun.history", qos: .utility)
    private let lock = NSLock()
    private var next: [RunRecord]?
    private var busy = false

    func write(_ runs: [RunRecord]) {
        lock.lock()
        next = runs
        let start = !busy
        busy = true
        lock.unlock()
        if start { queue.async { self.drain() } }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let runs = next else {
                busy = false
                lock.unlock()
                return
            }
            next = nil
            lock.unlock()
            try? RunHistory.save(runs)
        }
    }

    /// Waits for the writes asked for so far.
    func waitUntilIdle() { queue.sync {} }
}

/// Output and flow events gathered from the runs' threads until the main thread shows them. Each
/// run's output is joined into a few pieces between showings, and never kept beyond what a run
/// keeps anyway (`RunRecord.maxOutput`): only the latest is.
final class PendingOutput: @unchecked Sendable {
    struct Piece {
        var stream: RunCore.OutputStream
        var text: String
    }

    struct Buffer {
        var pieces: [Piece] = []
        var bytes = 0
        /// Earlier output was dropped before it was shown.
        var dropped = false
    }

    struct Batch {
        var events: [(UUID, FlowEvent)]
        var outputs: [UUID: Buffer]
    }

    private let lock = NSLock()
    private var events: [(UUID, FlowEvent)] = []
    private var outputs: [UUID: Buffer] = [:]
    /// A showing has been asked for since the last `take`.
    private var signalled = false

    /// Adds a run's output. True when the main thread should be asked to show it (the first
    /// since the last showing).
    func add(_ id: UUID, _ stream: RunCore.OutputStream, _ text: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        addLocked(id, stream, text)
        return signal()
    }

    /// Adds a flow's event (its text goes with the output, in order).
    func event(_ flow: UUID, _ e: FlowEvent) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        switch e {
        case let .say(text):
            addLocked(flow, .out, text + "\n")
        case let .stepStarted(_, name, _, _):
            events.append((flow, e))
            addLocked(flow, .out, "👉 \(name)\n")
        case let .stepOutput(id, stream, text):
            addLocked(id, stream, text)
        case let .stepFinished(_, name, result):
            events.append((flow, e))
            let line = result.ok ? "✅ \(name) · \(RunRecord.duration(result.seconds))" : "❌ \(name) · \(result.ending.summary)"
            addLocked(flow, result.ok ? .out : .err, line + "\n")
        case let .notify(text):
            events.append((flow, e))
            addLocked(flow, .out, "🔔 \(text)\n")
        }
        return signal()
    }

    func take() -> Batch {
        lock.lock()
        defer { lock.unlock() }
        let batch = Batch(events: events, outputs: outputs)
        events = []
        outputs = [:]
        signalled = false
        return batch
    }

    private func signal() -> Bool {
        if signalled { return false }
        signalled = true
        return true
    }

    private func addLocked(_ id: UUID, _ stream: RunCore.OutputStream, _ text: String) {
        guard !text.isEmpty else { return }
        var b = outputs[id] ?? Buffer()
        if let last = b.pieces.last, last.stream == stream {
            b.pieces[b.pieces.count - 1].text += text
        } else {
            b.pieces.append(Piece(stream: stream, text: text))
        }
        b.bytes += text.utf8.count
        // Too much to show before the next showing: only the latest is kept.
        let cap = RunRecord.maxOutput
        while b.bytes > cap, !b.pieces.isEmpty {
            let over = b.bytes - cap
            let first = b.pieces[0].text
            let n = first.utf8.count
            if n <= over {
                b.pieces.removeFirst()
                b.bytes -= n
            } else {
                let utf8 = first.utf8
                var cut = utf8.index(utf8.startIndex, offsetBy: over)
                // Not in the middle of a character.
                while cut < utf8.endIndex, utf8[cut] & 0xC0 == 0x80 { utf8.formIndex(after: &cut) }
                let rest = String(first[cut...])
                b.pieces[0].text = rest
                b.bytes -= n - rest.utf8.count
            }
            b.dropped = true
        }
        outputs[id] = b
    }
}

/// Notifications (a flow's `notify`, a long run, a question waiting, an update): the app's own
/// large notice in the middle of the screen (`NoticeCenter`), never a corner banner that's easy
/// to miss or that macOS may be hiding. A click on one about a run shows that run (or its
/// question); on an update, it installs it.
@MainActor
enum Notifier {
    static func post(title: String, body: String, run: UUID? = nil, update: Bool = false, tone: Notice.Tone = .info) {
        NoticeCenter.shared.post(Notice(tone: update ? .update : tone, title: title, body: body, run: run, update: update))
    }
}
