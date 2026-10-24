import Foundation

/// Every request another app makes that reaches the card on the Mac (a run, a flow, Flow code, or
/// an automation), by its id, from the moment it arrives: waiting for the click, how the person
/// answered, the run it became and how that went. The id goes back to the app at once
/// (`X-Request-Id`, and `request` in every answer), so the app can ask `GET /api/requests/{id}`
/// any time later, whether it waited for the answer, streamed it, or hung up.
///
/// A result is handed over once. The answer that carries it (the waited-for run, the 403 for
/// Don't Run, a stream's last line, or the first read of `/api/requests/{id}` once it's over)
/// clears it: asked about again, the request says how it ended but no longer carries the output.
/// The ones not cleared yet, oldest first, are `GET /api/requests/open`: what the app is still
/// waiting on, and what's ready to collect.
public actor RequestLedger {
    public enum Outcome: Sendable, Equatable {
        /// On the Mac, waiting for Run (or Allow).
        case waiting
        case denied
        case notAnswered
        /// Started: the run's id.
        case running(UUID)
        /// Tagged to run by itself (an automation request).
        case automated
        /// Allowed to stop this run (a stop request), and told to stop.
        case stopped(UUID)
        /// Allowed, but it couldn't be started (or tagged): why.
        case failed(HTTPError)
        /// Taken back by the app that asked, before anyone clicked (the card went away).
        case withdrawn
    }

    /// How a request left the open list.
    public enum Clearing: String, Sendable {
        /// Its result went back in the answer to the request itself (it was waited for, streamed,
        /// or refused there and then).
        case delivered
        /// Its result was read at `/api/requests/{id}`, once it was over.
        case collected
        /// The app cleared it without reading it (`DELETE /api/requests/{id}`, `/api/requests/clear`).
        case dismissed
        /// The app took it back while it waited for the click.
        case withdrawn
    }

    public struct Entry: Sendable {
        public let id: UUID
        public let request: RunRequest
        public let asked: Date
        public var outcome: Outcome = .waiting
        /// When the person answered (or the two minutes ran out).
        public var answered: Date?
        /// How it was asked for: `run`, `compose`, `automation` or `stop` (which endpoint).
        public let via: String
        /// When its result was handed over, or it was cleared without it (nil: it's open).
        public var cleared: Date?
        public var clearedBy: Clearing?

        public var runID: UUID? {
            if case let .running(id) = outcome { return id }
            return nil
        }
    }

    /// How many are kept (the latest).
    public let capacity: Int
    private var entries: [UUID: Entry] = [:]
    private var order: [UUID] = []
    private var byRun: [UUID: UUID] = [:]
    /// The asking of an async request, while it waits for the click: cancelling it takes the
    /// card away.
    private var asking: [UUID: Task<Void, Never>] = [:]

    public init(capacity: Int = 500) {
        self.capacity = capacity
    }

    /// Records a request as it arrives (waiting for the click).
    @discardableResult
    public func add(_ request: RunRequest, via: String) -> Entry {
        let entry = Entry(id: request.id, request: request, asked: Date(), via: via)
        entries[request.id] = entry
        order.append(request.id)
        while order.count > capacity, let oldest = order.first {
            order.removeFirst()
            if let gone = entries.removeValue(forKey: oldest), let run = gone.runID { byRun[run] = nil }
            asking[oldest] = nil
        }
        return entry
    }

    /// What became of it.
    public func set(_ id: UUID, _ outcome: Outcome) {
        // Withdrawn stays withdrawn (the card going away answers Don't Run, after).
        guard var e = entries[id], e.outcome != .withdrawn else { return }
        e.outcome = outcome
        if e.answered == nil { e.answered = Date() }
        entries[id] = e
        if case let .running(run) = outcome { byRun[run] = id }
    }

    public func entry(_ id: UUID) -> Entry? { entries[id] }

    /// Takes it off the open list (its result handed over, or not wanted). The first way it
    /// went is the one kept.
    public func clear(_ id: UUID, _ how: Clearing) {
        guard var e = entries[id], e.cleared == nil else { return }
        e.cleared = Date()
        e.clearedBy = how
        entries[id] = e
    }

    /// The ones not cleared yet, oldest first.
    public func open() -> [Entry] {
        order.compactMap { entries[$0] }.filter { $0.cleared == nil }
    }

    /// Keeps the task asking on the Mac for an async request, so it can be withdrawn.
    public func hold(_ id: UUID, _ task: Task<Void, Never>) {
        if entries[id]?.outcome == .waiting { asking[id] = task }
    }

    /// Whether it can still be taken back (an async request, waiting for the click).
    public func holds(_ id: UUID) -> Bool { asking[id] != nil && entries[id]?.outcome == .waiting }

    /// The asking is over (answered, or the run started).
    public func release(_ id: UUID) { asking[id] = nil }

    /// Takes back a request still waiting for the click: the card goes, nothing runs. False when
    /// it isn't waiting, or its caller is still on the line (it hangs up to take it back).
    public func withdraw(_ id: UUID) -> Bool {
        guard let e = entries[id], e.outcome == .waiting, let task = asking.removeValue(forKey: id) else { return false }
        set(id, .withdrawn)
        clear(id, .withdrawn)
        task.cancel()
        return true
    }

    /// The request a run came from (nil: it wasn't asked for over the API, or it's been forgotten).
    public func request(forRun run: UUID) -> UUID? { byRun[run] }

    /// The latest, newest first.
    public func recent(_ limit: Int) -> [Entry] {
        order.suffix(limit).reversed().compactMap { entries[$0] }
    }

    public var count: Int { entries.count }
}
