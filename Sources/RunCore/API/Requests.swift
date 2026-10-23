import Foundation

/// Every request another app makes that reaches the card on the Mac (a run, a flow, Flow code, or
/// an automation), by its id, from the moment it arrives: waiting for the click, how the person
/// answered, the run it became and how that went. The id goes back to the app at once
/// (`X-Request-Id`, and `request` in every answer), so the app can ask `GET /api/requests/{id}`
/// any time later, whether it waited for the answer, streamed it, or hung up.
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
        /// Allowed, but it couldn't be started (or tagged): why.
        case failed(HTTPError)
    }

    public struct Entry: Sendable {
        public let id: UUID
        public let request: RunRequest
        public let asked: Date
        public var outcome: Outcome = .waiting
        /// When the person answered (or the two minutes ran out).
        public var answered: Date?
        /// How it was asked for: `run`, `compose` or `automation` (which endpoint).
        public let via: String

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
        }
        return entry
    }

    /// What became of it.
    public func set(_ id: UUID, _ outcome: Outcome) {
        guard var e = entries[id] else { return }
        e.outcome = outcome
        if e.answered == nil { e.answered = Date() }
        entries[id] = e
        if case let .running(run) = outcome { byRun[run] = id }
    }

    public func entry(_ id: UUID) -> Entry? { entries[id] }

    /// The request a run came from (nil: it wasn't asked for over the API, or it's been forgotten).
    public func request(forRun run: UUID) -> UUID? { byRun[run] }

    /// The latest, newest first.
    public func recent(_ limit: Int) -> [Entry] {
        order.suffix(limit).reversed().compactMap { entries[$0] }
    }

    public var count: Int { entries.count }
}
