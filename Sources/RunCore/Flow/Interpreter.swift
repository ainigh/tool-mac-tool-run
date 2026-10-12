import Foundation

/// What a running flow reaches the world through: running the scripts, showing output, the
/// notifications. The app and the `flow` command each give their own; the tests give a pretend one.
public protocol FlowHost: AnyObject, Sendable {
    /// Runs a script from the folder (by its file name, or its name without the extension).
    /// Throws a `FlowError` when there's no such script or it can't start.
    func runScript(_ name: String, args: [String], stdin: String?, pos: Pos) throws -> RunResult
    /// Runs one line of shell.
    func runShell(_ command: String, stdin: String?, pos: Pos) throws -> RunResult
    /// A line for the run's output.
    func say(_ text: String)
    func notify(_ text: String)
    var environment: [String: String] { get }
    /// Asked to stop: the flow ends at its next step.
    var isCancelled: Bool { get }
    /// Asks the person running the flow (`confirm`, `ask`, `choose`, `askYesNo`) and waits for the
    /// answer. `.stop` (or a stop while it waits) ends the flow, as stopped.
    func ask(_ question: FlowQuestion) -> FlowAnswer
    /// Runs `epa` with these words (`epa`, `attemptEpa`), asking its questions through `ask`.
    /// Throws a `FlowError` when it can't start (not set up) or is stopped.
    func runEPA(_ words: [String], pos: Pos) throws -> EPA.Outcome
}

extension FlowHost {
    /// No one to ask (a host that doesn't take questions): the flow stops, saying why.
    public func ask(_ question: FlowQuestion) -> FlowAnswer { .unavailable }

    /// A host that can't run EPA (a pretend one): says so.
    public func runEPA(_ words: [String], pos: Pos) throws -> EPA.Outcome {
        throw FlowError(.run, pos, EPA.notSetUp, fix: EPA.setupFix)
    }
}

/// A question a flow asks the person running it, and waits for.
public struct FlowQuestion: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Continue or Stop (`confirm`).
        case proceed
        /// Yes or No (`askYesNo`).
        case yesNo
        /// A line of text (`ask`).
        case text
        /// One of these (`choose`).
        case choice([String])
        /// Text to read, with Done to go on (`showResult`, like Shortcuts' Show Result). With no
        /// one to show it to, the flow goes on: it's in the run's output either way.
        case result
    }
    public var kind: Kind
    public var prompt: String
    /// Where in the flow it's asked.
    public var line: Int
    /// Going ahead can't be undone (EPA removing something): Continue is shown as such, and
    /// `flow run --yes` doesn't answer it by itself.
    public var destructive: Bool
    /// The answer is a secret (a key EPA asks for): it isn't shown as it's typed, or kept.
    public var secret: Bool

    /// The page the answer comes from (where an EPA key is made): offered next to the field.
    public var link: URL?
    /// Where the answer is kept (EPA saves a key to .env under this name).
    public var savedAs: String?

    public init(kind: Kind, prompt: String, line: Int, destructive: Bool = false, secret: Bool = false,
                link: URL? = nil, savedAs: String? = nil) {
        self.kind = kind
        self.prompt = prompt
        self.line = line
        self.destructive = destructive
        self.secret = secret
        self.link = link
        self.savedAs = savedAs
    }
}

/// The answer to a `FlowQuestion`.
public enum FlowAnswer: Sendable, Equatable {
    /// Continue, or Yes.
    case yes
    case no
    /// What was typed, or picked.
    case text(String)
    /// Stop the flow.
    case stop
    /// There's no one to ask (no terminal, nothing showing questions).
    case unavailable
}

/// Runs a checked program, step by step.
public final class Interpreter: @unchecked Sendable {
    let host: FlowHost
    /// How many of the flow's own functions are running now, one inside another.
    private var depth: Int
    private let stack = StackGuard()

    /// How deep functions may call functions. Each call of a flow's function takes several Swift
    /// calls of the interpreter's own: measured on `1 + f (n - 1)`, about 5.5 KB of stack in a
    /// debug build and 3 KB optimised. So on a thread with a big stack (the app runs flows on one)
    /// this limit comes first; on a smaller one (the `flow` command's 8 MB main thread: about 1,400
    /// calls debug, 2,700 optimised; a `parallel` step's) the stack guard stops it sooner. Either
    /// way it's a message, not a crash.
    static let maxCallDepth = 10_000

    init(host: FlowHost, depth: Int = 0) {
        self.host = host
        self.depth = depth
    }

    /// One for a step run on another thread (by `parallel`): made on that thread, so it watches
    /// that thread's stack, and carrying on from how deep this one is.
    func forked() -> Interpreter { Interpreter(host: host, depth: depth) }

    private func tooDeep(_ pos: Pos) -> FlowError {
        FlowError(.run, pos, "Functions calling functions went \(depth) deep, more than a flow has room for, so it stopped. A function that calls itself probably never stops.",
                  fix: "Make sure it stops calling itself: an `if` whose other side doesn't call it again, such as: if n = 0 then 0 else n + f (n - 1).")
    }

    static func tooBig(_ what: String, _ pos: Pos) -> FlowError {
        FlowError(.run, pos, "\(what) is too big a number.", fix: Lexer.tooBigFix)
    }

    static func globals(args: [String]) -> Env {
        let env = Env()
        for b in Builtin.all + Builtin.hidden { env.define(b.name, .fn(FlowFunction(.builtin(b)))) }
        env.define("args", .list(args.map { .str($0) }))
        return env
    }

    func checkStop(_ pos: Pos) throws {
        if host.isCancelled { throw FlowError(.stopped, pos, "Stopped.") }
    }

    func eval(_ e: Expr, _ env: Env) throws -> Value {
        guard stack.hasRoom else { throw tooDeep(e.pos) }
        // Each case past the simplest is a function of its own: Swift gives a function one stack
        // frame big enough for all its cases, and eval is in every level of a flow's calls, so a
        // small eval lets a flow go deeper.
        switch e.kind {
        case .apply: return try call(e, env)
        case .name: return try lookup(e, env)
        case .cond: return try cond(e, env)
        case .binary: return try binary(e, env)
        default: return try other(e, env)
        }
    }

    private func other(_ e: Expr, _ env: Env) throws -> Value {
        switch e.kind {
        case let .int(n): return .int(n)
        case let .str(s): return .str(s)
        case let .bool(b): return .bool(b)
        case .unit: return .unit
        case let .interp(texts, holes): return try interpolate(texts, holes, env)
        case let .list(items): return .list(try items.map { try eval($0, env) })
        case let .lambda(params, body): return .fn(FlowFunction(.closure(params: params, body: body, env: env)))
        case let .negate(x): return try negate(x, env, e.pos)
        case let .field(x, name): return try field(x, name, env)
        case let .block(items): return try block(items, env)
        case .apply, .name, .cond, .binary: return try eval(e, env)
        }
    }

    private func interpolate(_ texts: [String], _ holes: [Expr], _ env: Env) throws -> Value {
        var s = texts[0]
        for (k, h) in holes.enumerated() {
            s += try eval(h, env).text
            s += texts[k + 1]
        }
        return .str(s)
    }

    private func lookup(_ e: Expr, _ env: Env) throws -> Value {
        guard case let .name(n) = e.kind else { return .unit }
        guard let v = env.lookup(n) else { throw Self.undefined(n, e.pos) }
        return v
    }

    private static func undefined(_ n: String, _ pos: Pos) -> FlowError {
        FlowError(.run, pos, "`\(n)` isn't defined.")
    }

    private func call(_ e: Expr, _ env: Env) throws -> Value {
        guard case let .apply(f, a) = e.kind else { return .unit }
        let fv = try eval(f, env)
        let av = try eval(a, env)
        return try apply(fv, av, pos: e.pos)
    }

    private func negate(_ x: Expr, _ env: Env, _ pos: Pos) throws -> Value {
        let n = try eval(x, env).int
        let (r, overflow) = 0.subtractingReportingOverflow(n)
        if overflow { throw Self.tooBig("-(\(n))", pos) }
        return .int(r)
    }

    private func cond(_ e: Expr, _ env: Env) throws -> Value {
        guard case let .cond(test, yes, no) = e.kind else { return .unit }
        if try eval(test, env).bool { return try eval(yes, env) }
        if let no { return try eval(no, env) }
        return .unit
    }

    private func field(_ x: Expr, _ name: String, _ env: Env) throws -> Value {
        guard case let .run(r) = try eval(x, env) else { return .unit }
        switch name {
        case "out": return .str(r.out)
        case "err": return .str(r.err)
        case "code": return .int(r.code)
        default: return .bool(r.ok)
        }
    }

    func block(_ items: [Item], _ env: Env) throws -> Value {
        var scope = env
        var last: Value = .unit
        for item in items {
            try checkStop(item.pos)
            switch item.kind {
            case let .bind(name, rec, params, body):
                let inner = Env(parent: scope)
                if params.isEmpty {
                    inner.define(name, try eval(body, scope))
                } else {
                    // A `let rec` is defined in its own scope, so it can call itself; a plain
                    // `let` sees the scope before it (so its name inside is the old one).
                    inner.define(name, .fn(FlowFunction(.closure(params: params, body: body, env: rec ? inner : scope))))
                }
                scope = inner
                last = .unit
            case let .expr(x):
                last = try eval(x, scope)
            }
        }
        return last
    }

    func apply(_ f: Value, _ arg: Value, pos: Pos) throws -> Value {
        try checkStop(pos)
        guard case let .fn(fn) = f else { throw Self.notAFunction(pos) }
        let args = fn.applied + [arg]
        guard args.count >= fn.arity else { return .fn(FlowFunction(fn.impl, applied: args)) }
        guard case let .closure(params, body, env) = fn.impl else { return try builtin(fn, args, pos) }
        depth += 1
        defer { depth -= 1 }
        if depth > Self.maxCallDepth { throw tooDeep(pos) }
        return try eval(body, Self.scope(env, params, args))
    }

    private static func notAFunction(_ pos: Pos) -> FlowError { FlowError(.run, pos, "That isn't a function.") }

    private func builtin(_ fn: FlowFunction, _ args: [Value], _ pos: Pos) throws -> Value {
        guard case let .builtin(b) = fn.impl else { return .unit }
        return try b.body(self, args, pos)
    }

    /// A function's parameters, named for its body.
    private static func scope(_ env: Env, _ params: [Param], _ args: [Value]) -> Env {
        let scope = Env(parent: env)
        for (p, v) in zip(params, args) {
            if let n = p.name { scope.define(n, v) }
        }
        return scope
    }

    /// Whole-number arithmetic that stops the flow when the answer doesn't fit, rather than
    /// crashing or quietly wrapping round to a wrong one.
    static func arithmetic(_ op: String, _ a: Int, _ b: Int, _ pos: Pos) throws -> Int {
        let (r, overflow): (Int, Bool)
        switch op {
        case "+": (r, overflow) = a.addingReportingOverflow(b)
        case "-": (r, overflow) = a.subtractingReportingOverflow(b)
        case "*": (r, overflow) = a.multipliedReportingOverflow(by: b)
        case "/", "%":
            guard b != 0 else { throw FlowError(.run, pos, "Divided by zero.") }
            // The one case that overflows: -9223372036854775808 / -1. Its remainder is 0.
            if op == "%" { return b == -1 ? 0 : a % b }
            (r, overflow) = a.dividedReportingOverflow(by: b)
        default: throw FlowError(.run, pos, "\(op) isn't an operator I know.")
        }
        if overflow { throw tooBig("\(a) \(op) \(b)", pos) }
        return r
    }

    private func binary(_ e: Expr, _ env: Env) throws -> Value {
        guard case let .binary(op, l, r) = e.kind else { return .unit }
        // && and || only look at the right side when they need to.
        if op == "&&" || op == "||" {
            let left = try eval(l, env).bool
            if left == (op == "||") { return .bool(left) }
            return .bool(try eval(r, env).bool)
        }
        let a = try eval(l, env)
        let b = try eval(r, env)
        return try Self.combine(op, a, b, e.pos)
    }

    /// What an operator gives for these two values (kept apart from `binary`, so the frame
    /// that stays on the stack while its sides are worked out is small).
    private static func combine(_ op: String, _ a: Value, _ b: Value, _ pos: Pos) throws -> Value {
        switch op {
        case "+":
            if case let .str(x) = a { return .str(x + b.string) }
            return .int(try arithmetic(op, a.int, b.int, pos))
        case "-", "*", "/", "%": return .int(try arithmetic(op, a.int, b.int, pos))
        case "@": return .list(a.items + b.items)
        case "=": return .bool(Value.equal(a, b))
        case "<>": return .bool(!Value.equal(a, b))
        case "<": return .bool(Value.less(a, b))
        case ">": return .bool(Value.less(b, a))
        case "<=": return .bool(!Value.less(b, a))
        case ">=": return .bool(!Value.less(a, b))
        default: throw FlowError(.run, pos, "\(op) isn't an operator I know.")
        }
    }

    // MARK: what the builtins use

    func script(_ name: String, args: [String], stdin: String?, pos: Pos) throws -> RunValue {
        try checkStop(pos)
        let r = try host.runScript(name, args: args, stdin: stdin, pos: pos)
        try checkStop(pos)
        return RunValue(out: r.out.trimmingCharacters(in: .whitespacesAndNewlines),
                        err: r.err.trimmingCharacters(in: .whitespacesAndNewlines), code: Int(r.code))
    }

    func shell(_ command: String, stdin: String?, pos: Pos) throws -> RunValue {
        try checkStop(pos)
        let r = try host.runShell(command, stdin: stdin, pos: pos)
        try checkStop(pos)
        return RunValue(out: r.out.trimmingCharacters(in: .whitespacesAndNewlines),
                        err: r.err.trimmingCharacters(in: .whitespacesAndNewlines), code: Int(r.code))
    }

    /// Runs `epa` with these words. A Stop answered to one of its questions stops the flow.
    func epa(_ words: [String], pos: Pos) throws -> EPA.Outcome {
        try checkStop(pos)
        if words.isEmpty || words[0].hasPrefix("-") {
            throw FlowError(.run, pos, "`epa` needs the command first, such as [\"doctor\"] or [\"connect\"; \"resend\"].",
                            fix: "Commands: " + EPA.commandNames.joined(separator: ", ") + ".")
        }
        let o = try host.runEPA(words, pos: pos)
        try checkStop(pos)
        if o.stoppedByPerson { throw FlowError(.stopped, pos, "Stopped: you chose Stop at one of EPA's questions.") }
        return o
    }

    /// An EPA run as a script's result (`attemptEpa`): its words, what failed and the next step.
    static func runValue(_ o: EPA.Outcome) -> RunValue {
        let err = [o.failure, o.next.map { "Next: \($0)" }].compactMap { $0 }.joined(separator: "\n")
        return RunValue(out: o.text.trimmingCharacters(in: .whitespacesAndNewlines), err: err, code: o.ok ? 0 : Int(max(o.code, 1)))
    }

    func requireSuccess(_ r: RunValue, name: String, pos: Pos) throws {
        guard !r.ok else { return }
        let detail = r.err.isEmpty ? "" : ": " + (r.err.split(whereSeparator: \.isNewline).last.map(String.init) ?? "")
        throw FlowError(.run, pos, "\(name) failed (exit code \(r.code))\(detail)",
                        fix: "Fix the script (its output is above), or use `attempt` instead of `run` to keep going when it fails.")
    }

    /// Asks the person running the flow. Stop (or no one to ask) ends the flow here.
    func ask(_ question: FlowQuestion, pos: Pos) throws -> FlowAnswer {
        try checkStop(pos)
        let answer = host.ask(question)
        try checkStop(pos)
        switch answer {
        case .stop:
            throw FlowError(.stopped, pos, "Stopped: you chose Stop at “\(question.prompt)”.")
        case .unavailable:
            let yesFits = question.kind == .proceed || question.kind == .yesNo
            throw FlowError(.run, pos, "This flow asks “\(question.prompt)”, and there's no one here to answer.",
                            fix: yesFits
                                ? "Run it from the app, or from a terminal (flow run). With no one at the keyboard, `flow run --yes` answers Continue and Yes for you."
                                : "Run it from the app, or from a terminal (flow run) where someone can type the answer. (`--yes` answers only Continue and Yes questions: give the flow arguments instead.)")
        default:
            return answer
        }
    }

    /// Waits, a little at a time, so a stop ends it at once.
    func pause(seconds: Double) throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if host.isCancelled { throw FlowError(.stopped, nil, "Stopped.") }
            Thread.sleep(forTimeInterval: min(0.1, max(0, end.timeIntervalSinceNow)))
        }
    }
}
