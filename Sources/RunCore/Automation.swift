import Foundation

/// When a script or a flow runs by itself: a tag from a fixed set (never one made up on the
/// spot), either a schedule ("every morning") or something that sets it off ("when a script
/// runs"). An item can wear several. The Automation board groups the items by tag; the app's
/// `AutomationCenter` watches the clock and the runs and starts what's due; other apps tag an
/// item over the API (`"automation": ["every morning"]`).
public enum AutomationTag: String, CaseIterable, Codable, Sendable {
    // Schedules: on the clock.
    case everyMinute = "every-minute"
    case every5Minutes = "every-5-minutes"
    case every10Minutes = "every-10-minutes"
    case every30Minutes = "every-30-minutes"
    case everyHour = "every-hour"
    case everyMorning = "every-morning"
    case everyAfternoon = "every-afternoon"
    case everyEvening = "every-evening"
    case everyDay = "every-day"
    case everyWeek = "every-week"
    case everyMonth = "every-month"
    // Triggers: something that happens sets it off.
    case whenAPICalled = "when-api-called"
    case whenScriptRuns = "when-a-script-runs"
    case whenFlowRuns = "when-a-flow-runs"
    case whenUtilityRuns = "when-a-utility-runs"
    case whenBrowserScriptRuns = "when-a-browser-script-runs"
    case afterItem = "after-an-item"
    case whenAnythingRuns = "when-anything-runs"

    public enum Kind: String, Sendable {
        case schedule, trigger
    }

    public var kind: Kind {
        switch self {
        case .everyMinute, .every5Minutes, .every10Minutes, .every30Minutes, .everyHour,
             .everyMorning, .everyAfternoon, .everyEvening, .everyDay, .everyWeek, .everyMonth: .schedule
        case .whenAPICalled, .whenScriptRuns, .whenFlowRuns, .whenUtilityRuns, .whenBrowserScriptRuns, .afterItem, .whenAnythingRuns: .trigger
        }
    }

    /// As shown on a cell, a tile and in a menu.
    public var title: String {
        switch self {
        case .everyMinute: "Every minute"
        case .every5Minutes: "Every 5 minutes"
        case .every10Minutes: "Every 10 minutes"
        case .every30Minutes: "Every 30 minutes"
        case .everyHour: "Every hour"
        case .everyMorning: "Every morning"
        case .everyAfternoon: "Every afternoon"
        case .everyEvening: "Every evening"
        case .everyDay: "Every day"
        case .everyWeek: "Every week"
        case .everyMonth: "Every month"
        case .whenAPICalled: "When the API is called"
        case .whenScriptRuns: "When a script runs"
        case .whenFlowRuns: "When a flow runs"
        case .whenUtilityRuns: "When a utility runs"
        case .whenBrowserScriptRuns: "When a browser script runs"
        case .afterItem: "After an item"
        case .whenAnythingRuns: "When anything runs"
        }
    }

    /// Exactly when, in a sentence (under the pointer, and on the board).
    public var about: String {
        switch self {
        case .everyMinute: "Runs once a minute, from when it was tagged (while the app is open)."
        case .every5Minutes: "Runs every 5 minutes, from when it was tagged."
        case .every10Minutes: "Runs every 10 minutes, from when it was tagged."
        case .every30Minutes: "Runs every 30 minutes, from when it was tagged."
        case .everyHour: "Runs once an hour, from when it was tagged."
        case .everyMorning: "Runs at 7:00 every day."
        case .everyAfternoon: "Runs at 13:00 every day."
        case .everyEvening: "Runs at 19:00 every day."
        case .everyDay: "Runs at 9:00 every day."
        case .everyWeek: "Runs at 9:00 every Monday."
        case .everyMonth: "Runs at 9:00 on the first day of every month."
        case .whenAPICalled: "Runs after another app has run something over the HTTP API (once that run has ended)."
        case .whenScriptRuns: "Runs after any script on the Scripts grid has run (once it has ended)."
        case .whenFlowRuns: "Runs after any flow has run."
        case .whenUtilityRuns: "Runs after any utility has run."
        case .whenBrowserScriptRuns: "Runs after any browser script has run."
        case .afterItem: "Runs after the items you pick have run (once each has ended)."
        case .whenAnythingRuns: "Runs after anything at all has run: a script, a flow, a utility, a browser script, from a click or the API."
        }
    }

    public var symbol: String {
        switch self {
        case .everyMinute, .every5Minutes, .every10Minutes, .every30Minutes, .everyHour: "clock"
        case .everyMorning: "sunrise"
        case .everyAfternoon: "sun.max"
        case .everyEvening: "sunset"
        case .everyDay: "calendar"
        case .everyWeek: "calendar.badge.clock"
        case .everyMonth: "calendar.circle"
        case .whenAPICalled: "network"
        case .whenScriptRuns: "terminal"
        case .whenFlowRuns: "point.3.connected.trianglepath.dotted"
        case .whenUtilityRuns: "wrench.and.screwdriver"
        case .whenBrowserScriptRuns: "globe"
        case .afterItem: "arrow.right.circle"
        case .whenAnythingRuns: "bolt"
        }
    }

    /// The schedules, then the triggers: the order the board and the menu list them in.
    public static let schedules: [AutomationTag] = allCases.filter { $0.kind == .schedule }
    public static let triggers: [AutomationTag] = allCases.filter { $0.kind == .trigger }

    /// The seconds between runs, for a tag that counts from when it was tagged (nil: on the clock).
    public var interval: TimeInterval? {
        switch self {
        case .everyMinute: 60
        case .every5Minutes: 300
        case .every10Minutes: 600
        case .every30Minutes: 1800
        case .everyHour: 3600
        default: nil
        }
    }

    /// The time of day a calendar tag runs at (hour, minute), and for a week or a month, the day.
    var clock: (hour: Int, minute: Int, weekday: Int?, day: Int?)? {
        switch self {
        case .everyMorning: (7, 0, nil, nil)
        case .everyAfternoon: (13, 0, nil, nil)
        case .everyEvening: (19, 0, nil, nil)
        case .everyDay: (9, 0, nil, nil)
        case .everyWeek: (9, 0, 2, nil)   // Monday (Sunday is 1)
        case .everyMonth: (9, 0, nil, 1)
        default: nil
        }
    }

    /// When a schedule next runs: `interval` after it last ran (or was tagged), or the next time
    /// on the clock after that. A trigger has no next time.
    public func next(after last: Date, calendar: Calendar = .current) -> Date? {
        if let interval { return last.addingTimeInterval(interval) }
        guard let clock else { return nil }
        var parts = DateComponents()
        parts.hour = clock.hour
        parts.minute = clock.minute
        parts.second = 0
        if let weekday = clock.weekday { parts.weekday = weekday }
        if let day = clock.day { parts.day = day }
        return calendar.nextDate(after: last, matching: parts, matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
    }

    /// The tag a name means, as another app (or a person) writes it: "every-morning",
    /// "every morning", "Every Morning", "hourly", "daily"… (nil: no such tag).
    public static func named(_ text: String) -> AutomationTag? {
        let key = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" }).joined(separator: "-")
        if let tag = AutomationTag(rawValue: key) { return tag }
        return aliases[key]
    }

    private static let aliases: [String: AutomationTag] = [
        "minutely": .everyMinute, "every-1-minute": .everyMinute,
        "every-hour": .everyHour, "hourly": .everyHour, "every-1-hour": .everyHour, "every-60-minutes": .everyHour,
        "daily": .everyDay, "every-week": .everyWeek, "weekly": .everyWeek, "monthly": .everyMonth,
        "morning": .everyMorning, "afternoon": .everyAfternoon, "evening": .everyEvening,
        "when-api-call-is-made": .whenAPICalled, "api": .whenAPICalled, "when-the-api-is-called": .whenAPICalled, "on-api-call": .whenAPICalled,
        "when-script-runs": .whenScriptRuns, "when-any-script-runs": .whenScriptRuns,
        "when-flow-runs": .whenFlowRuns, "when-any-flow-runs": .whenFlowRuns,
        "when-utility-runs": .whenUtilityRuns, "when-any-utility-runs": .whenUtilityRuns,
        "when-browser-script-runs": .whenBrowserScriptRuns,
        "after": .afterItem, "after-item": .afterItem, "after-items": .afterItem, "when-item-runs": .afterItem,
        "when-any-item-runs": .whenAnythingRuns, "when-anything-happens": .whenAnythingRuns, "when-any-occurs": .whenAnythingRuns, "always": .whenAnythingRuns,
    ]

    /// Every tag's name, for a message listing them.
    public static var names: String { allCases.map(\.rawValue).joined(separator: ", ") }
}

/// How one item is automated: its tags, whether it's for one time only, and (for "after an
/// item") which items set it off. Kept in its grid's settings, by the item's id.
public struct Automation: Codable, Equatable, Sendable {
    public var tags: [AutomationTag]
    /// One time only: once it has run by itself, its tags are taken off.
    public var once: Bool
    /// For `afterItem`: the ids of the items it runs after (`hello.sh`, `utilities/speak.sh`, `morning.flow`).
    public var after: [String]

    public init(tags: [AutomationTag] = [], once: Bool = false, after: [String] = []) {
        self.tags = Self.ordered(tags)
        self.once = once
        self.after = after
    }

    enum CodingKeys: String, CodingKey {
        case tags, once, after
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A tag a newer version added (or an older one dropped) doesn't lose the rest.
        tags = Self.ordered((try? c.decode([String].self, forKey: .tags))?.compactMap(AutomationTag.init(rawValue:)) ?? [])
        once = (try? c.decode(Bool.self, forKey: .once)) ?? false
        after = (try? c.decode([String].self, forKey: .after)) ?? []
    }

    /// Each tag once, in the table's order.
    static func ordered(_ tags: [AutomationTag]) -> [AutomationTag] {
        AutomationTag.allCases.filter(tags.contains)
    }

    /// Nothing automates it.
    public var isEmpty: Bool { tags.isEmpty }

    public var schedules: [AutomationTag] { tags.filter { $0.kind == .schedule } }
    public var triggers: [AutomationTag] { tags.filter { $0.kind == .trigger } }

    public mutating func set(_ tag: AutomationTag, on: Bool) {
        if on { tags = Self.ordered(tags + [tag]) } else { tags.removeAll { $0 == tag } }
    }

    /// "every morning, when the API is called · once".
    public var summary: String {
        var words = tags.map { tag in
            tag == .afterItem && !after.isEmpty ? "after " + after.joined(separator: ", ") : tag.title.prefix(1).lowercased() + tag.title.dropFirst()
        }.joined(separator: ", ")
        if words.isEmpty { words = "not automated" }
        return once ? words + " · once" : words
    }

    /// Whether a run that just ended sets this off: the tag that did, or nil. A run the
    /// automation itself started never sets off another (no loops).
    public func trigger(for run: RunRecord, grid: GridKind?) -> AutomationTag? {
        guard run.parent == nil, !run.isAutomated else { return nil }
        for tag in triggers {
            switch tag {
            case .whenAnythingRuns: return tag
            case .whenAPICalled where run.requestedBy != nil: return tag
            case .whenFlowRuns where run.kind == .flow: return tag
            case .whenScriptRuns where run.kind == .script && grid == .scripts: return tag
            case .whenUtilityRuns where run.kind == .script && grid == .utilities: return tag
            case .whenBrowserScriptRuns where run.kind == .script && grid == .browser: return tag
            case .afterItem where run.file.map(after.contains) == true: return tag
            default: continue
            }
        }
        return nil
    }
}

/// When each tag of each item last ran by itself (or was tagged): what a schedule's next time is
/// counted from. Kept in Application Support.
public struct AutomationLog: Codable, Equatable, Sendable {
    /// By item id, then tag.
    public var last: [String: [String: Date]] = [:]

    public init() {}

    public func last(_ id: String, _ tag: AutomationTag) -> Date? { last[id]?[tag.rawValue] }

    public mutating func mark(_ id: String, _ tag: AutomationTag, at date: Date = Date()) {
        last[id, default: [:]][tag.rawValue] = date
    }

    public mutating func forget(_ id: String) { last[id] = nil }

    /// An item renamed: its times go with it.
    public mutating func rename(_ old: String, to new: String) {
        if let times = last.removeValue(forKey: old) { last[new] = times }
    }

    /// When an item's schedule next runs: the earliest of its schedules' next times. A schedule
    /// with no time yet (just tagged) is counted from `now`, and remembered as such.
    public mutating func next(for id: String, _ automation: Automation, now: Date = Date(), calendar: Calendar = .current) -> (tag: AutomationTag, at: Date)? {
        var best: (AutomationTag, Date)?
        for tag in automation.schedules {
            let from: Date
            if let known = last(id, tag) {
                from = known
            } else {
                from = now
                mark(id, tag, at: now)
            }
            guard let at = tag.next(after: from, calendar: calendar) else { continue }
            if best == nil || at < best!.1 { best = (tag, at) }
        }
        return best
    }

    public static var url: URL { AppPaths.support.appendingPathComponent("automation.json") }

    public static func load() -> AutomationLog {
        guard let data = try? Data(contentsOf: url) else { return AutomationLog() }
        return (try? JSONDecoder().decode(AutomationLog.self, from: data)) ?? AutomationLog()
    }

    public func save() throws {
        try FileManager.default.createDirectory(at: AppPaths.support, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: Self.url, options: .atomic)
    }
}

/// An automated item, as the API lists it and the board shows it.
public struct AutomationEntry: Sendable, Equatable {
    /// The item's id (`hello.sh`, `utilities/speak.sh`, `morning.flow`).
    public var id: String
    public var grid: GridKind
    public var title: String
    public var automation: Automation
    /// When its schedule next runs (nil: only triggers, or nothing).
    public var next: Date?

    public init(id: String, grid: GridKind, title: String, automation: Automation, next: Date? = nil) {
        self.id = id
        self.grid = grid
        self.title = title
        self.automation = automation
        self.next = next
    }
}

extension RunRecord {
    /// Where a run the automation started says so (`requestedBy`), so it never sets off another.
    public static let automationPrefix = "Automation"

    /// The automation started it (a schedule, or a trigger), not a click or another app.
    public var isAutomated: Bool { requestedBy?.hasPrefix(Self.automationPrefix) == true }
}
