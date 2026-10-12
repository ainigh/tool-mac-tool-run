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
    /// Which grid's cell it belongs to (its file name), for the cell to show it.
    public var file: String?
    public var arguments: [String]
    /// What was run, as typed in a terminal (to copy and run there).
    public var command: String
    public var started: Date
    public var ended: Date?
    public var code: Int32?
    public var state: State
    public var output: [Chunk]
    /// The run of a flow this is a step of.
    public var parent: UUID?
    /// Why it couldn't start or why the flow stopped, and the fix.
    public var problem: String?
    /// Earlier output was dropped to keep it to `maxOutput` characters.
    public var trimmed: Bool

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
    }

    /// Adds printed text (joined to the last piece when it's the same stream), dropping the
    /// oldest when there's too much.
    public mutating func append(_ stream: OutputStream, _ text: String) {
        if let last = output.last, last.stream == stream {
            output[output.count - 1].text += text
        } else {
            output.append(Chunk(stream: stream, text: text))
        }
        var total = output.reduce(0) { $0 + $1.text.utf8.count }
        while total > Self.maxOutput, !output.isEmpty {
            let over = total - Self.maxOutput
            if output[0].text.utf8.count <= over {
                total -= output[0].text.utf8.count
                output.removeFirst()
            } else {
                let cut = output[0].text.utf8.index(output[0].text.utf8.startIndex, offsetBy: over)
                output[0].text = String(output[0].text[cut...])
                total -= over
            }
            trimmed = true
        }
    }

    /// Everything it printed, in order.
    public var text: String { output.map(\.text).joined() }

    /// Its last line of output (what a cell shows while it runs).
    public var lastLine: String? {
        text.split(whereSeparator: \.isNewline).last.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    public var seconds: Double? { ended.map { $0.timeIntervalSince(started) } }

    public mutating func finish(code: Int32?, state: State, at date: Date = Date()) {
        self.code = code
        self.state = state
        ended = date
    }

    /// "0.4 s", "12 s", "3 min 05 s", "1 h 02 min".
    public static func duration(_ seconds: Double) -> String {
        if seconds < 10 { return String(format: "%.1f s", seconds) }
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        if s < 3600 { return String(format: "%d min %02d s", s / 60, s % 60) }
        return String(format: "%d h %02d min", s / 3600, (s % 3600) / 60)
    }
}

/// The runs kept between launches (the last few hundred), in Application Support.
public enum RunHistory {
    public static let keep = 300

    public static var url: URL { AppPaths.support.appendingPathComponent("runs.json") }

    public static func load() -> [RunRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        var runs = (try? dec.decode([RunRecord].self, from: data)) ?? []
        // A run that was going when the app quit didn't finish: say so rather than show it running forever.
        for i in runs.indices where runs[i].state == .running {
            runs[i].finish(code: nil, state: .stopped, at: runs[i].ended ?? runs[i].started)
            runs[i].problem = "The app quit while this was running."
        }
        return runs
    }

    public static func save(_ runs: [RunRecord]) throws {
        try FileManager.default.createDirectory(at: AppPaths.support, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(Array(runs.suffix(keep))).write(to: url, options: .atomic)
    }
}
