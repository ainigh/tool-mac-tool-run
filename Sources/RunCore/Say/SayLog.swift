import Foundation

/// What the template adapter keeps for each client, so the client keeps nothing: every request it
/// made in words (what, when, how it's going, the system's id for it, whether its result was
/// shown), the last numbered list (for "the second one"), the rest of a long answer (for
/// "more"), a match waiting for "yes", and which templates it uses (offered first next time).
///
/// A conversation starts again after six hours without a word (the numbers and anything pending
/// are forgotten; the log stays). The log keeps a week, at most 200 requests a client; the
/// latest 100 clients are kept. All of it lasts while the app runs.
public actor SayLog {
    public enum State: Sendable, Equatable {
        /// Answered at once (a read).
        case answered
        /// Done at once (something changed).
        case done
        /// It couldn't be done: why.
        case failed(String)
        /// On the Mac, waiting for Run (or Allow).
        case waiting
        case running
        /// Over: whether it worked, its exit code.
        case finished(ok: Bool, code: Int?)
        case denied
        case notAnswered
        case withdrawn
        case couldNotStart(String)
        /// Stopped before it ended.
        case stopped

        /// Still going (waiting for the click, or running).
        public var open: Bool { self == .waiting || self == .running }

        /// A word for it, as it's told: "worked", "waiting for Run on the Mac".
        public var key: String {
            switch self {
            case .answered: "answered"
            case .done: "done"
            case .failed: "failed"
            case .waiting: "waiting"
            case .running: "running"
            case let .finished(ok, _): ok ? "worked" : "failed"
            case .denied: "denied"
            case .notAnswered: "not_answered"
            case .withdrawn: "withdrawn"
            case .couldNotStart: "could_not_start"
            case .stopped: "stopped"
            }
        }
    }

    public struct Entry: Sendable {
        public let number: Int
        public let asked: Date
        /// What the client said (its first line).
        public let said: String
        /// The template it filled.
        public let form: String
        /// What it asked for, in words: "the weather in Lagos", "remember something: Lagos trip".
        public var what: String
        /// How it's referred to: "the nightly backup".
        public var short: String
        /// The system's id for it, while there's something to follow (a run asked for).
        public var request: UUID?
        public var state: State
        /// The result in full, once there's one.
        public var result: String?
        /// The result was shown in full.
        public var shown = false
        /// The state last told in the news (each change is told once).
        public var told: String?
        /// "I'm done with it": no more news about it.
        public var muted = false
        public var ended: Date?
        /// It waits for the person at the Mac (a run, a tag to run by itself).
        public var asks = false

        /// Words it's found by when the client refers to it.
        var words: Set<String> { Set(APISearch.query(what + " " + short + " " + form + " " + said)) }
    }

    /// A match waiting for "yes" (or one of several, by number).
    public struct Pending: Sendable {
        public var choices: [(form: String, filled: SayFilled, text: String)]
    }

    public struct Conversation: Sendable {
        public var entries: [Entry] = []
        public var lastSpoke: Date?
        /// The entry numbers of the last list of requests shown.
        public var list: [Int] = []
        /// The titles of the templates last offered, in order.
        public var offered: [String] = []
        /// The rest of a long answer, a page each.
        public var more: [String] = []
        public var pending: Pending?
        /// How many times each template was used.
        public var used: [String: Int] = [:]
        /// Where to tell the client how its runs went, as it said (`reply_to`): nil, it hears at
        /// the start of its next reply.
        public var replyTo: URL?
        var counter = 0

        /// Something to tell it yet: a run still going, or one over and not told.
        var untold: Bool { entries.contains { $0.asks && ($0.state.open || (!$0.muted && $0.state.key != $0.told)) } }
    }

    public static let idle: TimeInterval = 6 * 3600
    public static let keep: TimeInterval = 7 * 24 * 3600
    public static let perClient = 200
    public static let clients = 100

    private var conversations: [String: Conversation] = [:]
    private var order: [String] = []
    /// The clients whose requests are being followed, to tell them how they went.
    private var watched: Set<String> = []

    public init() {}

    /// The client's conversation, to read and change (begun again after six idle hours).
    public func with<T: Sendable>(_ client: String, now: Date = Date(), _ body: (inout Conversation) -> T) -> T {
        var c = conversations[client] ?? Conversation()
        if let last = c.lastSpoke, now.timeIntervalSince(last) > Self.idle {
            c.list = []; c.offered = []; c.more = []; c.pending = nil
        }
        c.entries.removeAll { now.timeIntervalSince($0.asked) > Self.keep && !$0.state.open }
        if c.entries.count > Self.perClient { c.entries.removeFirst(c.entries.count - Self.perClient) }
        let out = body(&c)
        conversations[client] = c
        order.removeAll { $0 == client }
        order.append(client)
        while order.count > Self.clients { conversations[order.removeFirst()] = nil }
        return out
    }

    /// Adds a request to the log: its number.
    public func add(_ client: String, said: String, form: String, what: String, short: String, state: State, asks: Bool = false,
                    request: UUID? = nil, result: String? = nil) -> Int {
        with(client) { c in
            c.counter += 1
            var e = Entry(number: c.counter, asked: Date(), said: said, form: form, what: what, short: short, request: request, state: state, result: result)
            e.asks = asks
            e.shown = result != nil && !asks
            e.told = state.key
            if !state.open { e.ended = Date() }
            c.entries.append(e)
            c.used[form, default: 0] += 1
            return c.counter
        }
    }

    /// Changes one entry.
    public func update(_ client: String, _ number: Int, _ change: @Sendable (inout Entry) -> Void) {
        with(client) { c in
            if let k = c.entries.firstIndex(where: { $0.number == number }) { change(&c.entries[k]) }
        }
    }

    public func entries(_ client: String) -> [Entry] { with(client) { $0.entries } }

    /// Whether a client has somewhere to be told and something to tell it, with no watch on it yet.
    public func needsWatch(_ client: String) -> Bool {
        guard !watched.contains(client), let c = conversations[client] else { return false }
        return c.replyTo != nil && c.untold
    }

    /// Starts following a client's requests: false when they're followed already.
    public func watch(_ client: String) -> Bool { watched.insert(client).inserted }

    public func unwatch(_ client: String) { watched.remove(client) }

    /// Stops following a client's requests if there's nothing left to tell it (at once, so a
    /// request it makes meanwhile is never missed): whether it stopped.
    public func unwatchIfIdle(_ client: String) -> Bool {
        guard let c = conversations[client], c.replyTo != nil, c.untold else {
            watched.remove(client)
            return true
        }
        return false
    }

    /// Forgets the conversation (the numbers, what's pending); with `log`, what was asked too.
    public func reset(_ client: String, log: Bool = false) {
        with(client) { c in
            c.list = []; c.offered = []; c.more = []; c.pending = nil
            if log { c.entries = []; c.used = [:] }
        }
    }
}
