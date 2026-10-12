import AppKit
import RunCore
import UserNotifications

/// Every run: the ones going now (with what they print, as they print it) and the ones before,
/// kept between launches. The cells, the Runs window and the menu all read it.
@MainActor
final class RunStore: ObservableObject {
    @Published private(set) var records: [RunRecord] = []

    private var processes: [UUID: ScriptProcess] = [:]
    private var hosts: [UUID: LocalFlowHost] = [:]
    /// Output waiting to be shown: gathered off the main thread, shown ten times a second.
    private let pending = PendingOutput()
    private var flushScheduled = false
    private var saveTask: Task<Void, Never>?

    init() {
        records = RunHistory.load()
    }

    var runningCount: Int { records.filter { $0.state == .running && $0.parent == nil }.count }

    /// The latest top-level runs, newest first.
    func recent(_ n: Int) -> [RunRecord] {
        Array(records.reversed().filter { $0.parent == nil }.prefix(n))
    }

    /// The latest run of a cell's script or flow.
    func latest(file: String, kind: GridKind) -> RunRecord? {
        let k: RunRecord.Kind = kind == .scripts ? .script : .flow
        return records.last { $0.file == file && $0.kind == k }
    }

    func record(_ id: UUID) -> RunRecord? { records.first { $0.id == id } }

    func steps(of id: UUID) -> [RunRecord] { records.filter { $0.parent == id } }

    private func index(_ id: UUID) -> Int? { records.lastIndex { $0.id == id } }

    private func change(_ id: UUID, _ body: (inout RunRecord) -> Void) {
        guard let i = index(id) else { return }
        body(&records[i])
    }

    // MARK: running a script

    /// Runs a script with its arguments. Returns the run (it shows on the cell at once).
    @discardableResult
    func run(script item: ScriptItem, arguments: [String], folder: URL) -> UUID {
        let p = ScriptProcess(script: item.url, language: item.language, arguments: arguments, workingDirectory: folder)
        var rec = RunRecord(kind: .script, name: item.id, file: item.id, arguments: arguments, command: p.commandLine)
        let id = rec.id
        let pending = self.pending
        do {
            try p.start(output: { [weak self] stream, text in
                pending.add(id, stream, text)
                Task { @MainActor in self?.scheduleFlush() }
            }, exit: { [weak self] code in
                Task { @MainActor in self?.finished(id, code: code) }
            })
            processes[id] = p
            records.append(rec)
        } catch let e as LaunchError {
            rec.finish(code: nil, state: .couldNotStart)
            rec.problem = e.description
            records.append(rec)
            save()
        } catch {
            rec.finish(code: nil, state: .couldNotStart)
            rec.problem = error.localizedDescription
            records.append(rec)
            save()
        }
        return id
    }

    private func finished(_ id: UUID, code: Int32) {
        flush()
        let stopped = processes[id]?.wasStopped == true
        processes[id] = nil
        change(id) { $0.finish(code: code, state: stopped ? .stopped : code == 0 ? .succeeded : .failed) }
        if let r = record(id) { tellIfLong(r) }
        save()
    }

    // MARK: running a flow

    /// Checks a flow and runs it on a thread of its own; each script it runs is a step under it.
    @discardableResult
    func run(flow item: ScriptItem, arguments: [String], library: Library) -> UUID {
        var rec = RunRecord(kind: .flow, name: item.id, file: item.id, arguments: arguments,
                            command: "flow run \(ShellEnvironment.quote(item.url.path))" + arguments.map { " " + ShellEnvironment.quote($0) }.joined())
        let id = rec.id
        let source: String
        do {
            source = try String(contentsOf: item.url, encoding: .utf8)
        } catch {
            rec.finish(code: nil, state: .couldNotStart)
            rec.problem = "Couldn't read \(item.id): \(error.localizedDescription)"
            records.append(rec)
            return id
        }
        let names = LocalFlowHost.names(in: library)
        let checked: Flow.Checked
        do {
            checked = try Flow.check(source, scripts: names)
        } catch let e as FlowError {
            rec.finish(code: nil, state: .couldNotStart)
            rec.problem = "\(item.id), \(e.description)\n\nNothing was run. Open the flow with the pencil to fix it."
            records.append(rec)
            save()
            return id
        } catch {
            return id
        }
        records.append(rec)
        let pending = self.pending
        let host = LocalFlowHost(library: library) { [weak self] event in
            pending.event(id, event)
            Task { @MainActor in self?.scheduleFlush() }
        }
        hosts[id] = host
        Thread.detachNewThread {
            var outcome: (RunRecord.State, String?)
            do {
                try Flow.run(checked, host: host, args: arguments)
                outcome = (.succeeded, nil)
            } catch let e as FlowError {
                outcome = e.stage == .stopped ? (.stopped, nil) : (.failed, "\(item.id), \(e.description)")
            } catch {
                outcome = (.failed, error.localizedDescription)
            }
            let result = outcome
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.flush()
                self.hosts[id] = nil
                self.change(id) { r in
                    r.finish(code: result.0 == .succeeded ? 0 : 1, state: result.0)
                    r.problem = result.1
                    if let p = result.1 { r.append(.err, "\n❌ " + p + "\n") }
                }
                // Steps still marked running (stopped mid-way) are stopped.
                for i in self.records.indices where self.records[i].parent == id && self.records[i].state == .running {
                    self.records[i].finish(code: nil, state: .stopped)
                }
                if let r = self.record(id) { self.tellIfLong(r) }
                self.save()
            }
        }
        return id
    }

    // MARK: stopping

    func stop(_ id: UUID) {
        processes[id]?.stop()
        hosts[id]?.cancel()
    }

    func stopAll() {
        processes.values.forEach { $0.stop() }
        hosts.values.forEach { $0.cancel() }
    }

    func isRunning(_ id: UUID) -> Bool { processes[id] != nil || hosts[id] != nil }

    /// Forgets the finished runs (the ones going stay).
    func clearFinished() {
        let keep = Set(records.filter { $0.state == .running }.map(\.id))
        records.removeAll { !keep.contains($0.id) && !keep.contains($0.parent ?? UUID()) }
        save()
    }

    // MARK: output, ten times a second

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.flushScheduled = false
            self?.flush()
        }
    }

    private func flush() {
        for item in pending.take() {
            switch item {
            case let .output(id, stream, text):
                change(id) { $0.append(stream, text) }
            case let .event(flow, event):
                apply(event, flow: flow)
            }
        }
    }

    private func apply(_ event: FlowEvent, flow: UUID) {
        switch event {
        case let .say(text):
            change(flow) { $0.append(.out, text + "\n") }
        case let .stepStarted(id, name, command):
            var step = RunRecord(id: id, kind: .step, name: name, file: nil, command: command, parent: flow)
            step.state = .running
            records.append(step)
            change(flow) { $0.append(.out, "👉 \(name)\n") }
        case let .stepOutput(id, stream, text):
            change(id) { $0.append(stream, text) }
        case let .stepFinished(id, name, result):
            change(id) { r in
                if r.output.isEmpty && !result.err.isEmpty { r.append(.err, result.err) }
                r.finish(code: result.code, state: result.ok ? .succeeded : .failed)
            }
            let line = result.ok ? "✅ \(name) · \(RunRecord.duration(result.seconds))" : "❌ \(name) · exit code \(result.code)"
            change(flow) { $0.append(result.ok ? .out : .err, line + "\n") }
        case let .notify(text):
            change(flow) { $0.append(.out, "🔔 \(text)\n") }
            Notifier.post(title: record(flow)?.name ?? "Flow", body: text)
        }
    }

    // MARK: keeping them

    private func save() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        try? RunHistory.save(records)
    }

    /// A run that took a while, finishing while you're elsewhere: a notification says how it went.
    private func tellIfLong(_ r: RunRecord) {
        guard r.parent == nil, let secs = r.seconds, secs >= 15 else { return }
        Notifier.post(title: "\(r.state.mark) \(r.name)", body: "\(r.state.title) after \(RunRecord.duration(secs)).")
    }
}

/// Output and flow events gathered from the runs' threads until the main thread shows them.
final class PendingOutput: @unchecked Sendable {
    enum Item {
        case output(UUID, RunCore.OutputStream, String)
        case event(UUID, FlowEvent)
    }

    private let lock = NSLock()
    private var items: [Item] = []

    func add(_ id: UUID, _ stream: RunCore.OutputStream, _ text: String) {
        lock.lock()
        items.append(.output(id, stream, text))
        lock.unlock()
    }

    func event(_ flow: UUID, _ e: FlowEvent) {
        lock.lock()
        items.append(.event(flow, e))
        lock.unlock()
    }

    func take() -> [Item] {
        lock.lock()
        defer { lock.unlock() }
        let out = items
        items = []
        return out
    }
}

/// Notifications (a flow's `notify`, a long run finishing). macOS asks once whether to allow them.
enum Notifier {
    static func post(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else {
            NSSound.beep()
            return
        }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
