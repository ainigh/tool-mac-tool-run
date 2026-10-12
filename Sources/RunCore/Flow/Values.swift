import Foundation

/// A value while a flow runs.
public enum Value: Sendable {
    case int(Int)
    case str(String)
    case bool(Bool)
    case unit
    case list([Value])
    case fn(FlowFunction)
    /// What `attempt` returns: a script's result, whether or not it succeeded.
    case run(RunValue)

    /// As `print` and `string` show it: text as it is, a list as [a; b], a script's result as its output.
    public var text: String {
        switch self {
        case let .int(n): String(n)
        case let .str(s): s
        case let .bool(b): b ? "true" : "false"
        case .unit: "()"
        case let .list(items): "[" + items.map(\.quoted).joined(separator: "; ") + "]"
        case .fn: "<function>"
        case let .run(r): r.out
        }
    }

    /// Inside a list, text is quoted (so ["a b"] isn't read as two items).
    var quoted: String {
        if case let .str(s) = self { return "\"" + s.replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        return text
    }

    static func equal(_ a: Value, _ b: Value) -> Bool {
        switch (a, b) {
        case let (.int(x), .int(y)): x == y
        case let (.str(x), .str(y)): x == y
        case let (.bool(x), .bool(y)): x == y
        case (.unit, .unit): true
        case let (.list(x), .list(y)): x.count == y.count && zip(x, y).allSatisfy { equal($0, $1) }
        case let (.run(x), .run(y)): x == y
        default: false
        }
    }

    /// Ordering for `<` and `sort`: numbers by size, text alphabetically.
    static func less(_ a: Value, _ b: Value) -> Bool {
        switch (a, b) {
        case let (.int(x), .int(y)): return x < y
        case let (.str(x), .str(y)): return x < y
        case let (.bool(x), .bool(y)): return !x && y
        case let (.list(x), .list(y)):
            for (p, q) in zip(x, y) {
                if less(p, q) { return true }
                if less(q, p) { return false }
            }
            return x.count < y.count
        default: return false
        }
    }
}

/// A script's result, as a flow sees it.
public struct RunValue: Equatable, Sendable {
    public var out: String
    public var err: String
    public var code: Int
    public var ok: Bool { code == 0 }

    public init(out: String, err: String, code: Int) {
        self.out = out
        self.err = err
        self.code = code
    }

    /// The fields `r.out`, `r.err`, `r.code` and `r.ok`, with their types.
    static let fields: [(name: String, type: FType, doc: String)] = [
        ("out", .string, "what it printed (trimmed)"),
        ("err", .string, "what it printed as errors (trimmed)"),
        ("code", .int, "its exit code (0 is success)"),
        ("ok", .bool, "true when the exit code is 0"),
    ]
}

/// A function: one written in the flow (with what it closed over), or a builtin, with the values
/// it has been given so far (they're applied one at a time, as in F#).
public final class FlowFunction: @unchecked Sendable {
    enum Impl {
        case closure(params: [Param], body: Expr, env: Env)
        case builtin(Builtin)
    }

    let impl: Impl
    let applied: [Value]

    init(_ impl: Impl, applied: [Value] = []) {
        self.impl = impl
        self.applied = applied
    }

    var arity: Int {
        switch impl {
        case let .closure(params, _, _): params.count
        case let .builtin(b): b.arity
        }
    }
}

/// The names in scope while a flow runs.
final class Env: @unchecked Sendable {
    private var values: [String: Value] = [:]
    private let parent: Env?

    init(parent: Env? = nil) {
        self.parent = parent
    }

    func lookup(_ name: String) -> Value? {
        var e: Env? = self
        while let env = e {
            if let v = env.values[name] { return v }
            e = env.parent
        }
        return nil
    }

    func define(_ name: String, _ value: Value) {
        values[name] = value
    }
}
