import Foundation

/// One run of a script or a flow (or a step of a flow): what was run, when, how it ended, and
/// what it printed. The Runs window lists them; the cells show their latest.
public struct RunRecord: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case script, flow, step
    }

    public enum State: String, Codable, Sendable {
        case running, succeeded, failed, stopped
        /// It never started (no interpreter, a mistake in the flow): `problem` says why and what fixes it.
        case couldNotStart

        public var title: String {
            switch self {
            case .running: "Running"
            case .succeeded: "Succeeded"
            case .failed: "Failed"
            case .stopped: "Stopped"
            case .couldNotStart: "Couldn't start"
            }
        }

        /// The one mark each state wears, everywhere (the app draws it as an icon and a color).
        public var mark: String {
            switch self {
            case .running: "👉"
            case .succeeded: "✅"
            case .failed: "❌"
            case .stopped: "⏹"
            case .couldNotStart: "⚠️"
            }
        }

        public var finished: Bool { self != .running }
    }

    public struct Chunk: Codable, Equatable, Sendable {
        public var stream: OutputStream
        public var text: String
    }

    public var id: UUID
    public var kind: Kind
    /// Its file name (or, for a line of shell, the line).
    public var name: String
    /// Which grid's cell it belongs to (its id: the file name, after its folder for a utility or a
    /// browser script), for the cell to show it.
    public var file: String?
    public var arguments: [String]
    /// What was run, as typed in a terminal (to copy and run there).
    public var command: String
    public var started: Date
    public var ended: Date?
    /// Its exit code (ended by a signal: 128 + the signal).
    public var code: Int32?
    /// The signal that ended it, when one did (see `ending`).
    public var signal: Int32?
    public var state: State
    public var output: [Chunk]
    /// The run of a flow this is a step of.
    public var parent: UUID?
    /// A step: the line of its flow that ran it (the block editor marks that block).
    public var line: Int?
    /// Why it couldn't start or why the flow stopped, and the fix.
    public var problem: String?
    /// Earlier output was dropped to keep it to `maxOutput` bytes.
    public var trimmed: Bool
    /// Another app asked for it, over the API, and the person allowed it: who ("curl, on this Mac").
    public var requestedBy: String?
    /// Why it was asked for, in the asker's words (the API's `why`), when it said.
    public var why: String?
    /// Every byte of output it has printed so far, counting what was dropped: only ever goes up,
    /// so it's a cheap way to notice new output (scroll to the end when it changes).
    public private(set) var receivedBytes: Int
    /// The bytes of output kept now (`text.utf8.count`, without adding it up).
    public private(set) var outputBytes: Int

    /// The most output kept in memory, in bytes (UTF-8).
    public static let maxOutput = 300_000

    public init(id: UUID = UUID(), kind: Kind, name: String, file: String?, arguments: [String] = [], command: String,
                started: Date = Date(), parent: UUID? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.file = file
        self.arguments = arguments
        self.command = command
        self.started = started
        self.parent = parent
        state = .running
        output = []
        trimmed = false
        receivedBytes = 0
        outputBytes = 0
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, name, file, arguments, command, started, ended, code, signal, state, output, parent, line, problem, trimmed, receivedBytes, requestedBy, why
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(Kind.self, forKey: .kind)
        name = try c.decode(String.self, forKey: .name)
        file = try c.decodeIfPresent(String.self, forKey: .file)
        arguments = try c.decodeIfPresent([String].self, forKey: .arguments) ?? []
        command = try c.decode(String.self, forKey: .command)
        started = try c.decode(Date.self, forKey: .started)
        ended = try c.decodeIfPresent(Date.self, forKey: .ended)
        code = try c.decodeIfPresent(Int32.self, forKey: .code)
        signal = try c.decodeIfPresent(Int32.self, forKey: .signal)
        state = try c.decode(State.self, forKey: .state)
        output = try c.decodeIfPresent([Chunk].self, forKey: .output) ?? []
        parent = try c.decodeIfPresent(UUID.self, forKey: .parent)
        line = try c.decodeIfPresent(Int.self, forKey: .line)
        problem = try c.decodeIfPresent(String.self, forKey: .problem)
        trimmed = try c.decodeIfPresent(Bool.self, forKey: .trimmed) ?? false
        requestedBy = try c.decodeIfPresent(String.self, forKey: .requestedBy)
        why = try c.decodeIfPresent(String.self, forKey: .why)
        outputBytes = output.reduce(0) { $0 + $1.text.utf8.count }
        receivedBytes = max(try c.decodeIfPresent(Int.self, forKey: .receivedBytes) ?? 0, outputBytes)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(file, forKey: .file)
        try c.encode(arguments, forKey: .arguments)
        try c.encode(command, forKey: .command)
        try c.encode(started, forKey: .started)
        try c.encodeIfPresent(ended, forKey: .ended)
        try c.encodeIfPresent(code, forKey: .code)
        try c.encodeIfPresent(signal, forKey: .signal)
        try c.encode(state, forKey: .state)
        try c.encode(output, forKey: .output)
        try c.encodeIfPresent(parent, forKey: .parent)
        try c.encodeIfPresent(line, forKey: .line)
        try c.encodeIfPresent(problem, forKey: .problem)
        try c.encode(trimmed, forKey: .trimmed)
        try c.encode(receivedBytes, forKey: .receivedBytes)
        try c.encodeIfPresent(requestedBy, forKey: .requestedBy)
        try c.encodeIfPresent(why, forKey: .why)
    }

    /// Adds printed text (joined to the last piece when it's the same stream). Past `maxOutput`
    /// bytes, the oldest tenth is dropped (a tenth at a time, so a run that prints a lot isn't
    /// trimmed, and copied, on every piece).
    public mutating func append(_ stream: OutputStream, _ text: String) {
        guard !text.isEmpty else { return }
        let n = text.utf8.count
        receivedBytes += n
        outputBytes += n
        if let last = output.indices.last, output[last].stream == stream {
            output[last].text += text
        } else {
            output.append(Chunk(stream: stream, text: text))
        }
        if outputBytes > Self.maxOutput { trimOutput(to: Self.maxOutput - Self.maxOutput / 10) }
    }

    /// Drops the oldest output until at most `bytes` bytes are left (cutting between characters,
    /// never inside one), and marks it `trimmed`.
    public mutating func trimOutput(to bytes: Int) {
        let limit = max(0, bytes)
        while outputBytes > limit, !output.isEmpty {
            let over = outputBytes - limit
            let first = output[0].text.utf8.count
            if first <= over {
                outputBytes -= first
                output.removeFirst()
            } else {
                let s = output[0].text
                var cut = s.utf8.index(s.utf8.startIndex, offsetBy: over)
                // Forward to where a Unicode scalar starts (String's own subscript would round a cut
                // inside a character back to its start, keeping more than counted).
                while cut < s.utf8.endIndex, cut.samePosition(in: s.unicodeScalars) == nil { cut = s.utf8.index(after: cut) }
                outputBytes -= s.utf8.distance(from: s.utf8.startIndex, to: cut)
                output[0].text = String(s.unicodeScalars[cut...])
                if output[0].text.isEmpty { output.removeFirst() }
            }
            trimmed = true
        }
    }

    /// Everything it printed, in order.
    public var text: String { output.map(\.text).joined() }

    /// Its last line of output (what a cell shows while it runs). Found from the end, so it costs
    /// the length of that line, not of all the output; a line longer than 2,000 characters gives
    /// its last 2,000.
    public var lastLine: String? {
        var pieces: [Substring] = []
        var length = 0
        var inLine = false
        scan: for chunk in output.reversed() {
            let t = chunk.text
            var end = t.endIndex
            if !inLine {
                // Line breaks at the very end don't count: the last line is the one before them.
                while end > t.startIndex, t[t.index(before: end)].isNewline { end = t.index(before: end) }
                if end == t.startIndex { continue }
                inLine = true
            }
            var start = end
            while start > t.startIndex, !t[t.index(before: start)].isNewline, length < 2000 {
                start = t.index(before: start)
                length += 1
            }
            pieces.append(t[start..<end])
            if start > t.startIndex || length >= 2000 { break scan }
        }
        let line = pieces.reversed().joined().trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? nil : line
    }

    public var seconds: Double? { ended.map { $0.timeIntervalSince(started) } }

    public mutating func finish(code: Int32?, state: State, at date: Date = Date()) {
        self.code = code
        self.state = state
        ended = date
    }

    /// Finishes it as `ending` says: stopped, succeeded, or failed (with its exit code, or the
    /// signal that ended it).
    public mutating func finish(_ ending: RunEnding, at date: Date = Date()) {
        signal = ending.signal
        finish(code: ending.code, state: ending.stopped ? .stopped : ending.ok ? .succeeded : .failed, at: date)
    }

    /// How it ended, once it has with a code: `ending?.summary` is "exit code 3", "stopped" or
    /// "killed by signal 11 (SIGSEGV)".
    public var ending: RunEnding? {
        guard state != .running, let code else { return nil }
        return RunEnding(code: code, signal: signal, stopped: state == .stopped)
    }

    /// "0.4 s", "12 s", "3 min 05 s", "1 h 02 min".
    public static func duration(_ seconds: Double) -> String {
        let seconds = max(0, seconds)  // a clock set back never shows "-0.3 s"
        // Below 9.95 s, not 10: "%.1f" would round 9.97 up to "10.0 s", a second before "10 s".
        if seconds < 9.95 { return String(format: "%.1f s", seconds) }
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        if s < 3600 { return String(format: "%d min %02d s", s / 60, s % 60) }
        return String(format: "%d h %02d min", s / 3600, (s % 3600) / 60)
    }

    /// "just now", "2 min ago", "3 h ago", "yesterday", or the date. Whole minutes and hours,
    /// counted down (59 min 40 s is "59 min ago", never "60 min ago"), never "0 min".
    public static func ago(_ date: Date, now: Date = Date()) -> String {
        let s = now.timeIntervalSince(date)
        if s < 45 { return "just now" }
        if s < 3600 { return "\(max(1, Int(s / 60))) min ago" }
        if s < 86_400 { return "\(Int(s / 3600)) h ago" }
        if s < 172_800 { return "yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

/// The runs kept between launches (the last few hundred), in Application Support.
public enum RunHistory {
    /// How many runs are kept: top-level runs (scripts and flows); a flow's steps go with it.
    public static let keep = 300
    /// The most output saved with each run, in bytes (its last part), so the file stays small.
    public static let savedOutput = 48 * 1024

    public static var url: URL { AppPaths.support.appendingPathComponent("runs.json") }

    public static func load() -> [RunRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard var runs = try? decode(data) else {
            // Not readable at all: kept aside, so the next save doesn't write over the only copy.
            let aside = url.deletingLastPathComponent().appendingPathComponent("runs.unreadable.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: url, to: aside)
            return []
        }
        // A run that was going when the app quit didn't finish: say so rather than show it running forever.
        for i in runs.indices where runs[i].state == .running {
            runs[i].finish(code: nil, state: .stopped, at: runs[i].ended ?? runs[i].started)
            runs[i].problem = "The app quit while this was running."
        }
        return runs
    }

    public static func save(_ runs: [RunRecord]) throws {
        try FileManager.default.createDirectory(at: AppPaths.support, withIntermediateDirectories: true)
        try encode(runs).write(to: url, options: .atomic)
    }

    /// The runs as saved: the latest `keep` top-level runs with their steps, each with at most the
    /// last `savedOutput` bytes of its output. Dates keep their fractions of a second.
    public static func encode(_ runs: [RunRecord]) throws -> Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        }
        let kept = trimmed(runs).map { r -> RunRecord in
            var r = r
            r.trimOutput(to: savedOutput)
            return r
        }
        return try enc.encode(kept)
    }

    /// Reads saved runs: dates with fractions of a second, or whole seconds (as saved before).
    public static func decode(_ data: Data) throws -> [RunRecord] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if let d = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(s) { return d }
            if let d = try? Date.ISO8601FormatStyle().parse(s) { return d }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not an ISO 8601 date: \(s)")
        }
        // Each run on its own: one that can't be read (a newer app's, a hand edit) is left out,
        // not the whole history with it. A step whose flow was left out goes too.
        let runs = try dec.decode([Lossy].self, from: data).compactMap(\.run)
        let ids = Set(runs.map(\.id))
        return runs.filter { $0.parent.map(ids.contains) ?? true }
    }

    private struct Lossy: Decodable {
        let run: RunRecord?
        init(from decoder: Decoder) { run = try? RunRecord(from: decoder) }
    }

    /// The latest `keep` top-level runs (scripts and flows), each with its steps, in their order.
    /// Runs still going are always kept, with their steps.
    public static func trimmed(_ runs: [RunRecord], keep: Int = keep) -> [RunRecord] {
        var kept = Set(runs.filter { $0.parent == nil }.suffix(max(0, keep)).map(\.id))
        for r in runs where r.state == .running { kept.insert(r.parent ?? r.id) }
        return runs.filter { r in kept.contains(r.parent ?? r.id) || r.state == .running }
    }
}
