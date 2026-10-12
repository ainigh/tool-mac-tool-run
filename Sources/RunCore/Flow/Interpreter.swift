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
}

/// Runs a checked program, step by step.
public final class Interpreter: @unchecked Sendable {
    let host: FlowHost

    init(host: FlowHost) {
        self.host = host
    }

    static func globals(args: [String]) -> Env {
        let env = Env()
        for b in Builtin.all { env.define(b.name, .fn(FlowFunction(.builtin(b)))) }
        env.define("args", .list(args.map { .str($0) }))
        return env
    }

    func checkStop(_ pos: Pos) throws {
        if host.isCancelled { throw FlowError(.stopped, pos, "Stopped.") }
    }

    func eval(_ e: Expr, _ env: Env) throws -> Value {
        switch e.kind {
        case let .int(n): return .int(n)
        case let .str(s): return .str(s)
        case let .bool(b): return .bool(b)
        case .unit: return .unit
        case let .interp(texts, holes):
            var s = texts[0]
            for (k, h) in holes.enumerated() {
                s += try eval(h, env).text
                s += texts[k + 1]
            }
            return .str(s)
        case let .list(items):
            return .list(try items.map { try eval($0, env) })
        case let .name(n):
            guard let v = env.lookup(n) else { throw FlowError(.run, e.pos, "`\(n)` isn't defined.") }
            return v
        case let .apply(f, a):
            let fv = try eval(f, env)
            let av = try eval(a, env)
            return try apply(fv, av, pos: e.pos)
        case let .lambda(params, body):
            return .fn(FlowFunction(.closure(params: params, body: body, env: env)))
        case let .binary(op, l, r):
            return try binary(op, l, r, env, e.pos)
        case let .negate(x):
            return .int(-(try eval(x, env).int))
        case let .cond(test, yes, no):
            if try eval(test, env).bool { return try eval(yes, env) }
            if let no { return try eval(no, env) }
            return .unit
        case let .field(x, name):
            guard case let .run(r) = try eval(x, env) else { return .unit }
            switch name {
            case "out": return .str(r.out)
            case "err": return .str(r.err)
            case "code": return .int(r.code)
            default: return .bool(r.ok)
            }
        case let .block(items):
            return try block(items, env)
        }
    }

    func block(_ items: [Item], _ env: Env) throws -> Value {
        var scope = env
        var last: Value = .unit
        for item in items {
            try checkStop(item.pos)
            switch item.kind {
            case let .bind(name, params, body):
                let inner = Env(parent: scope)
                if params.isEmpty {
                    inner.define(name, try eval(body, scope))
                } else {
                    // Defined in its own scope, so it can call itself.
                    inner.define(name, .fn(FlowFunction(.closure(params: params, body: body, env: inner))))
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
        guard case let .fn(fn) = f else { throw FlowError(.run, pos, "That isn't a function.") }
        let args = fn.applied + [arg]
        guard args.count >= fn.arity else { return .fn(FlowFunction(fn.impl, applied: args)) }
        switch fn.impl {
        case let .builtin(b):
            return try b.body(self, args, pos)
        case let .closure(params, body, env):
            let scope = Env(parent: env)
            for (p, v) in zip(params, args) {
                if let n = p.name { scope.define(n, v) }
            }
            return try eval(body, scope)
        }
    }

    private func binary(_ op: String, _ l: Expr, _ r: Expr, _ env: Env, _ pos: Pos) throws -> Value {
        // && and || only look at the right side when they need to.
        if op == "&&" { return try eval(l, env).bool ? .bool(try eval(r, env).bool) : .bool(false) }
        if op == "||" { return try eval(l, env).bool ? .bool(true) : .bool(try eval(r, env).bool) }
        let a = try eval(l, env), b = try eval(r, env)
        switch op {
        case "+":
            if case let .str(x) = a { return .str(x + b.string) }
            return .int(a.int &+ b.int)
        case "-": return .int(a.int &- b.int)
        case "*": return .int(a.int &* b.int)
        case "/", "%":
            guard b.int != 0 else { throw FlowError(.run, pos, "Divided by zero.") }
            return .int(op == "/" ? a.int / b.int : a.int % b.int)
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

    func requireSuccess(_ r: RunValue, name: String, pos: Pos) throws {
        guard !r.ok else { return }
        let detail = r.err.isEmpty ? "" : ": " + (r.err.split(whereSeparator: \.isNewline).last.map(String.init) ?? "")
        throw FlowError(.run, pos, "\(name) failed (exit code \(r.code))\(detail)",
                        fix: "Fix the script (its output is above), or use `attempt` instead of `run` to keep going when it fails.")
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
