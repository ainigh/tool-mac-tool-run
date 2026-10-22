import AppKit
import RunCore
import SwiftUI

/// What runs by itself: the items tagged with a schedule ("every morning") or a trigger ("when
/// the API is called"). It watches the clock (every 20 seconds) and every run that ends, and
/// starts what's due, with the arguments remembered for the cell, marked in Runs as started by
/// the automation. An item that asks before it runs (it looks like it can't be undone, or it's
/// set to) asks here too: the same card another app's request gets, with Run and Don't Run.
/// A run the automation started never sets off another.
@MainActor
final class AutomationCenter: ObservableObject {
    static let shared = AutomationCenter()

    /// When each tag of each item last ran (or was tagged); saved as it changes.
    @Published private(set) var log = AutomationLog.load()
    /// Goes up each time something fires (the board follows it).
    @Published private(set) var fired = 0
    private var timer: Timer?
    private var saveTask: Task<Void, Never>?

    private init() {}

    /// Starts watching the clock (at launch).
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Soon after launch too: a schedule missed while the app was closed runs now, once.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            MainActor.assumeIsolated { AutomationCenter.shared.tick() }
        }
    }

    private var app: AppModel { AppModel.shared }

    // MARK: what's automated

    /// Every automated item, in the grids' order, with when its schedule next runs.
    func entries() -> [AutomationEntry] {
        var out: [AutomationEntry] = []
        for kind in GridKind.allCases {
            let items = app.items(kind)
            for (id, a) in app.settings(kind).automation.sorted(by: { $0.key < $1.key }) where !a.isEmpty {
                let title = items.first { $0.id == id }?.title ?? (id as NSString).deletingPathExtension
                out.append(AutomationEntry(id: id, grid: kind, title: title, automation: a, next: next(for: id, kind: kind)?.at))
            }
        }
        return out
    }

    /// How an item is automated (nothing, unless it was tagged).
    func automation(for item: ScriptItem) -> Automation { app.settings(item.grid).automation(for: item.id) }

    /// Tags an item (an empty automation takes its tags off). A schedule just added counts from now.
    func set(_ a: Automation, for item: ScriptItem) {
        let before = automation(for: item)
        app.update(item.grid) { $0.setAutomation(a, for: item.id) }
        var changed = false
        for tag in a.schedules where !before.tags.contains(tag) {
            log.mark(item.id, tag)
            changed = true
        }
        if a.isEmpty, !before.isEmpty {
            log.forget(item.id)
            changed = true
        }
        if changed { save() }
        objectWillChange.send()
    }

    /// An item renamed: its tags and times go with it (the grid's settings are moved by `AppModel`).
    func renamed(from old: String, to new: String) {
        log.rename(old, to: new)
        save()
    }

    /// When an item's schedule next runs (nil: no schedule). Read-only: a schedule with no time
    /// yet counts from now (the clock writes it down at its next look).
    func next(for id: String, kind: GridKind) -> (tag: AutomationTag, at: Date)? {
        let a = app.settings(kind).automation(for: id)
        guard !a.schedules.isEmpty else { return nil }
        var copy = log
        return copy.next(for: id, a)
    }

    /// "in 12 min", "at 7:00 tomorrow", "now".
    static func when(_ date: Date, now: Date = Date()) -> String {
        let s = date.timeIntervalSince(now)
        if s < 30 { return "now" }
        if s < 3600 { return "in \(max(1, Int(s / 60))) min" }
        if Calendar.current.isDate(date, inSameDayAs: now) { return "at " + date.formatted(date: .omitted, time: .shortened) }
        if let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now), Calendar.current.isDate(date, inSameDayAs: tomorrow) {
            return "at \(date.formatted(date: .omitted, time: .shortened)) tomorrow"
        }
        return "on " + date.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: the clock

    /// Starts every item whose schedule is due (once each, however many of its schedules are).
    private func tick() {
        guard app.library != nil else { return }
        let now = Date()
        for kind in GridKind.allCases {
            let settings = app.settings(kind)
            for (id, a) in settings.automation where !a.schedules.isEmpty {
                var due: [AutomationTag] = []
                for tag in a.schedules {
                    let from = log.last(id, tag) ?? now
                    if log.last(id, tag) == nil { log.mark(id, tag, at: now) }
                    if let at = tag.next(after: from), at <= now { due.append(tag) }
                }
                guard !due.isEmpty else { continue }
                guard let item = app.items(kind).first(where: { $0.id == id }) else { continue }
                // Still going from last time: it runs again once that's over (its time stays due).
                if app.runs.latest(file: id, kind: kind)?.state == .running { continue }
                for tag in due { log.mark(id, tag, at: now) }
                fire(item, because: due[0], once: a.once)
            }
        }
        save()
    }

    // MARK: runs that set others off

    /// A run ended: every item whose trigger it matches runs now (never the automation's own
    /// runs, and never the item itself).
    func runEnded(_ record: RunRecord) {
        guard record.parent == nil else { return }
        if record.isAutomated, record.state == .failed || record.state == .couldNotStart {
            let how = record.requestedBy?.dropFirst(RunRecord.automationPrefix.count + 2) ?? ""
            Notifier.post(title: record.name, body: "Started by itself (\(how)) and \(record.state.title.lowercased())" + (record.problem.map { ": \($0.prefix(140))" } ?? ".") + " Click for its output.",
                          run: record.id, tone: Theme.tone(record.state))
        }
        guard !record.isAutomated else { return }
        let grid: GridKind? = record.kind == .flow ? .composer : record.file.map(GridKind.of(scriptID:))
        for kind in GridKind.allCases {
            for (id, a) in app.settings(kind).automation where id != record.file {
                guard let tag = a.trigger(for: record, grid: grid) else { continue }
                guard let item = app.items(kind).first(where: { $0.id == id }) else { continue }
                log.mark(id, tag)
                fire(item, because: tag, once: a.once)
            }
        }
        save()
    }

    // MARK: starting one

    /// Runs an item because of a tag: with its cell's remembered arguments, marked as the
    /// automation's. One that asks before it runs asks on the card first. One-time: its tags
    /// come off, and a notice says so.
    private func fire(_ item: ScriptItem, because tag: AutomationTag, once: Bool) {
        guard let lib = app.library else { return }
        let actions = GridActions(app: app, kind: item.grid)
        let argv = ShellEnvironment.split(app.settings(item.grid).arguments[item.id] ?? "")
        let by = "\(RunRecord.automationPrefix): \(tag.title.prefix(1).lowercased() + tag.title.dropFirst())"
        let go: () -> Void = { [weak self] in
            if item.grid.isFlow {
                self?.app.runs.run(flow: item, arguments: argv, library: lib, requestedBy: by)
            } else {
                self?.app.runs.run(script: item, arguments: argv, folder: lib.root, requestedBy: by)
            }
        }
        if once {
            set(Automation(), for: item)
            Notifier.post(title: item.id, body: "Running by itself this once (\(tag.title.lowercased())). Its automation is off now; tag it again to repeat it.", tone: .info)
        }
        fired += 1
        guard actions.asksFirst(item) else {
            go()
            return
        }
        // It asks before it runs: the card, as for another app's request. No one to click Run
        // in two minutes, and it doesn't run (the card says so).
        let request = RunRequest(what: item.grid.isFlow ? .flow(item) : .script(item), name: item.id, arguments: argv,
                                 client: "Automation (\(tag.title.lowercased()))", from: "this Mac",
                                 command: actions.command(item, argv: argv), dangers: item.dangers,
                                 why: actions.askReason(item) + " It's tagged to run \(tag.title.lowercased()): " + tag.about)
        Task { @MainActor in
            if await ApprovalCenter.ask(request) == .allowed { go() }
        }
    }

    private func save() {
        saveTask?.cancel()
        let log = self.log
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            try? log.save()
        }
    }
}

/// The Automation submenu on a cell, a tile and the Automation board: a tick for each tag (the
/// schedules, then the triggers), After… with the items, One Time Only, and Not Automated.
struct AutomationMenu: View {
    let item: ScriptItem
    @ObservedObject var app: AppModel
    @ObservedObject var center = AutomationCenter.shared

    private var current: Automation { center.automation(for: item) }

    var body: some View {
        Menu {
            Section("Runs by itself…") {
                ForEach(AutomationTag.schedules, id: \.self) { tag in toggle(tag) }
            }
            Section("…or when something happens") {
                ForEach(AutomationTag.triggers.filter { $0 != .afterItem }, id: \.self) { tag in toggle(tag) }
                Menu("After an Item…") {
                    ForEach(app.scripts + app.flows) { other in
                        if other.id != item.id {
                            Toggle(other.id, isOn: Binding(get: { current.after.contains(other.id) }, set: { on in
                                var a = current
                                if on { a.after.append(other.id) } else { a.after.removeAll { $0 == other.id } }
                                a.set(.afterItem, on: !a.after.isEmpty)
                                center.set(a, for: item)
                            }))
                        }
                    }
                }
            }
            Divider()
            Toggle("One Time Only", isOn: Binding(get: { current.once }, set: { on in
                var a = current
                a.once = on
                center.set(a, for: item)
            }))
            .disabled(current.isEmpty)
            Button("Not Automated") { center.set(Automation(), for: item) }
                .disabled(current.isEmpty)
            Divider()
            Button("Open the Automation Board") { Windows.showAutomationBoard() }
        } label: {
            Text(current.isEmpty ? "Automation" : "Automation: \(current.summary)")
        }
    }

    private func toggle(_ tag: AutomationTag) -> some View {
        Toggle(tag.title, isOn: Binding(get: { current.tags.contains(tag) }, set: { on in
            var a = current
            a.set(tag, on: on)
            center.set(a, for: item)
        }))
        .help(tag.about)
    }
}

/// A small line saying how a cell or a tile runs by itself ("every morning · once"), with the
/// next time under the pointer.
struct AutomationBadge: View {
    let automation: Automation
    let next: Date?
    var dark = false

    var body: some View {
        if !automation.isEmpty {
            Label(automation.summary, systemImage: automation.schedules.isEmpty ? "bolt.fill" : "clock.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(dark ? Color.black.opacity(0.6) : Color.secondary)
                .lineLimit(1)
                .help(tooltip)
        }
    }

    private var tooltip: String {
        var s = "Runs by itself: " + automation.tags.map { $0.title.lowercased() + " (" + $0.about + ")" }.joined(separator: "; ")
        if !automation.after.isEmpty { s += " After: " + automation.after.joined(separator: ", ") + "." }
        if let next { s += " Next: \(AutomationCenter.when(next))." }
        if automation.once { s += " One time only: its tags come off once it has run." }
        return s + " (Right-click → Automation to change it.)"
    }
}
