import Foundation

/// A name a flow defines at its top level, with the type worked out for it.
public struct FlowBinding: Equatable, Sendable {
    public var name: String
    public var type: String
    public var line: Int
}

/// Works out every value's type before anything runs (Hindley–Milner, as F# does): nothing in a
/// flow needs a type written down, and a mistake is caught, with where it is and how to fix it,
/// before the first script starts.
final class Checker {
    private var nextID = 0
    private var level = 0
    private var constrained: [TVar] = []
    private var topLevel: [(name: String, scheme: Scheme, line: Int)] = []
    /// The scripts in the folder, by file name and by name without the extension (nil: don't check).
    private let scripts: [String]?
    /// The names of the `let`s being worked out now (for the message when one calls itself
    /// without `rec`).
    private var defining: [String] = []
    private let stack = StackGuard()

    init(scripts: [String]?) {
        self.scripts = scripts
    }

    // MARK: entry

    func check(_ program: Expr) throws -> [FlowBinding] {
        var env: [String: Scheme] = [:]
        for b in Builtin.all + Builtin.hidden { env[b.name] = scheme(signature: b.signature) }
        for g in Globals.names { env[g.name] = Scheme(generic: [], type: g.type) }
        _ = try infer(program, env, top: true)
        // A + or < that was never pinned down is on numbers, as in F#.
        for tv in constrained where tv.link == nil { tv.link = .int }
        return topLevel.map { FlowBinding(name: $0.name, type: TypePrinter.show($0.scheme.type), line: $0.line) }
    }

    // MARK: type variables

    private func fresh() -> FType {
        nextID += 1
        return .v(TVar(id: nextID, level: level))
    }

    private func scheme(signature: String) -> Scheme {
        var vars: [String: FType] = [:]
        var ids: [Int] = []
        let t = SignatureReader.read(signature) { name in
            if let v = vars[name] { return v }
            let v = fresh()
            if case let .v(tv) = v { ids.append(tv.id) }
            vars[name] = v
            return v
        }
        return Scheme(generic: ids, type: t)
    }

    private func instantiate(_ s: Scheme) -> FType {
        guard !s.generic.isEmpty else { return s.type }
        var map: [Int: FType] = [:]
        func copy(_ t: FType) -> FType {
            switch t.resolved {
            case let .v(tv):
                guard s.generic.contains(tv.id) else { return .v(tv) }
                if let v = map[tv.id] { return v }
                // A new variable for each use, keeping what it has to be (comparable with =).
                nextID += 1
                let v = FType.v(TVar(id: nextID, level: level, equatable: tv.equatable))
                map[tv.id] = v
                return v
            case let .con(n, args): return .con(n, args.map(copy))
            }
        }
        return copy(s.type)
    }

    private func generalize(_ t: FType) -> Scheme {
        var ids: [Int] = []
        func walk(_ t: FType) {
            switch t.resolved {
            case let .v(tv):
                if tv.level > level && !tv.numberOrText && !ids.contains(tv.id) { ids.append(tv.id) }
            case let .con(_, args): args.forEach(walk)
            }
        }
        walk(t)
        return Scheme(generic: ids, type: t)
    }

    // MARK: unification

    private struct Mismatch: Error {
        enum Why {
            /// Two different types.
            case types
            /// A type that would have to contain itself.
            case itself
            /// Something added or compared with < (a number or text) used as something else.
            case numberOrText
            /// Something compared with = that is, or has inside it, a function.
            case function
        }
        var why: Why = .types
    }

    /// Makes `t` comparable with =: false when it is, or has inside it, a function.
    private func makeEquatable(_ t: FType) -> Bool {
        switch t.resolved {
        case let .v(tv):
            tv.equatable = true
            return true
        case .con("->", _): return false
        case let .con(_, args): return args.allSatisfy(makeEquatable)
        }
    }

    private func occurs(_ tv: TVar, in t: FType) -> Bool {
        switch t.resolved {
        case let .v(other):
            if other.id == tv.id { return true }
            other.level = min(other.level, tv.level)
            return false
        case let .con(_, args): return args.contains { occurs(tv, in: $0) }
        }
    }

    /// How deep a type a `let` may have. Each `let` can double it (let g = f >> f), and working
    /// with a type goes one call deeper per level, so a type with no limit could run the checker
    /// out of stack.
    static let maxTypeDepth = 100

    /// Whether a type goes more than maxTypeDepth deep (or is too big to look all through):
    /// looked through with a list of what's left, not by calling itself.
    private static func isHuge(_ t: FType) -> Bool {
        var todo: [(FType, Int)] = [(t, 1)]
        var looked = 0
        while let (t, depth) = todo.popLast() {
            looked += 1
            if depth > maxTypeDepth || looked > 100_000 { return true }
            if case let .con(_, args) = t.resolved { todo += args.map { ($0, depth + 1) } }
        }
        return false
    }

    private func unify(_ a: FType, _ b: FType) throws {
        // A type is only as deep as the parser and isHuge allow; this is for a small stack.
        guard stack.hasRoom else { throw Mismatch() }
        let x = a.resolved, y = b.resolved
        switch (x, y) {
        case let (.v(p), .v(q)):
            if p.id == q.id { return }
            if p.numberOrText {
                q.numberOrText = true
                constrained.append(q)
            }
            if p.equatable { q.equatable = true }
            q.level = min(p.level, q.level)
            p.link = y
        case let (.v(p), .con), let (.con, .v(p)):
            let other = x.isVar ? y : x
            if occurs(p, in: other) { throw Mismatch(why: .itself) }
            if p.numberOrText, case let .con(name, _) = other, name != "int" && name != "string" { throw Mismatch(why: .numberOrText) }
            if p.equatable && !makeEquatable(other) { throw Mismatch(why: .function) }
            p.link = other
        case let (.con(n1, a1), .con(n2, a2)):
            guard n1 == n2, a1.count == a2.count else { throw Mismatch() }
            for (s, t) in zip(a1, a2) { try unify(s, t) }
        }
    }

    /// Makes `t` a number or text (for + and comparisons); false when it's something else.
    private func requireNumberOrText(_ t: FType) -> Bool {
        switch t.resolved {
        case let .v(tv):
            tv.numberOrText = true
            constrained.append(tv)
            return true
        case let .con(name, _): return name == "int" || name == "string"
        }
    }

    // MARK: inference

    private func infer(_ e: Expr, _ env: [String: Scheme], top: Bool = false) throws -> FType {
        // The parser keeps the tree shallow enough; this is for a thread with a small stack.
        guard stack.hasRoom else { throw Parser.tooDeep(e.pos) }
        // The bigger cases are functions of their own: Swift gives a function one stack frame
        // big enough for all its cases, and infer is in every level of the tree.
        switch e.kind {
        case .int: return .int
        case .str: return .string
        case .bool: return .bool
        case .unit: return .unit
        case let .interp(_, holes):
            for h in holes { _ = try infer(h, env) }
            return .string
        case .list: return try inferList(e, env)
        case .name: return try inferName(e, env)
        case .apply: return try inferApply(e, env)
        case .lambda: return try inferLambda(e, env)
        case let .binary(op, l, r):
            return try binary(op, l, r, env, e.pos)
        case .negate: return try inferNegate(e, env)
        case .cond: return try inferCond(e, env)
        case .field: return try inferField(e, env)
        case .block: return try inferBlock(e, env, top: top)
        }
    }

    private func inferList(_ e: Expr, _ env: [String: Scheme]) throws -> FType {
        guard case let .list(items) = e.kind else { return .unit }
        let elem = fresh()
        for (k, item) in items.enumerated() {
            let t = try infer(item, env)
            do { try unify(elem, t) } catch {
                var p = TypePrinter()
                let before = p.show(elem), this = p.show(t)
                throw FlowError(.type, item.pos, "Every item of a list has to be the same type: item \(k + 1) is \(this), the ones before it are \(before).",
                                fix: hint(expected: elem, actual: t))
            }
        }
        return .list(elem)
    }

    private func inferName(_ e: Expr, _ env: [String: Scheme]) throws -> FType {
        guard case let .name(n) = e.kind else { return .unit }
        if let s = env[n] { return instantiate(s) }
        if defining.contains(n) {
            throw FlowError(.type, e.pos, "`\(n)` can't use itself here: a `let` only sees its own name when it's a `let rec`.",
                            fix: "To let `\(n)` call itself, write `let rec \(n) …`.")
        }
        let near = Self.closest(n, among: Array(env.keys))
        throw FlowError(.type, e.pos, "I don't know `\(n)`.",
                        fix: near.map { "Did you mean `\($0)`?" } ?? "Define it first with: let \(n) = …")
    }

    private func inferApply(_ e: Expr, _ env: [String: Scheme]) throws -> FType {
        guard case let .apply(f, a) = e.kind else { return .unit }
        try checkScriptName(f, a)
        let tf = try infer(f, env)
        let ta = try infer(a, env)
        switch tf.resolved {
        case let .con("->", parts):
            do { try unify(parts[0], ta) } catch let m as Mismatch {
                var p = TypePrinter()
                let got = p.show(ta)
                if m.why == .function {
                    throw FlowError(.type, a.pos, "\(Self.who(f)) compares what it's given with =, and functions can't be compared, but this is \(Self.article(got)).",
                                    fix: "Give it something that isn't a function (or has none inside it).")
                }
                let want = m.why == .numberOrText ? "a number or text" : Self.article(p.show(parts[0]))
                throw FlowError(.type, a.pos, "\(Self.who(f)) needs \(want) here, but this is \(Self.article(got)).",
                                fix: hint(expected: parts[0], actual: ta))
            }
            return parts[1]
        case .v:
            let r = fresh()
            do { try unify(tf, .fn(ta, r)) } catch let m as Mismatch {
                switch m.why {
                case .numberOrText:
                    throw FlowError(.type, e.pos, "This is a number or text (it's added, or compared with < or >), so it can't be given \(Self.describe(a)) as if it were a function.",
                                    fix: "If \(Self.describe(a)) starts a new step, put it on a line of its own; if it should go into the sum, put an operator before it.")
                case .function:
                    throw FlowError(.type, e.pos, "This is compared with =, and functions can't be compared, so it can't be a function given \(Self.describe(a)).")
                case .itself, .types:
                    throw FlowError(.type, e.pos, "This would have to take itself as a value, which can't be.")
                }
            }
            return r
        case .con:
            // print "a" "b": the head is a function, given more values than it takes.
            if case .apply = f.kind, case let .name(n) = Self.head(f).kind {
                let takes = Self.argumentCount(f)
                throw FlowError(.type, a.pos, "`\(n)` is a function given one value too many: it takes \(takes), so \(Self.describe(a)) is left over.",
                                fix: "If this is a new step, put it on a line of its own. To hand a result on, use |> or brackets: print (upper name).")
            }
            let shown = TypePrinter.show(tf)
            throw FlowError(.type, a.pos, "\(Self.who(f)) is \(Self.article(shown)), not a function, so it can't be given \(Self.describe(a)).",
                            fix: "If this is a new step, put it on a line of its own. To hand a result on, use |> or brackets: print (upper name).")
        }
    }

    private func inferLambda(_ e: Expr, _ env: [String: Scheme]) throws -> FType {
        guard case let .lambda(params, body) = e.kind else { return .unit }
        var inner = env
        var types: [FType] = []
        for p in params {
            if let n = p.name {
                let t = fresh()
                inner[n] = Scheme(generic: [], type: t)
                types.append(t)
            } else {
                types.append(.unit)
            }
        }
        let tb = try infer(body, inner)
        return types.reversed().reduce(tb) { .fn($1, $0) }
    }

    private func inferNegate(_ e: Expr, _ env: [String: Scheme]) throws -> FType {
        guard case let .negate(x) = e.kind else { return .unit }
        let t = try infer(x, env)
        do { try unify(t, .int) } catch {
            throw FlowError(.type, x.pos, "Only a number can be made negative; this is \(Self.article(TypePrinter.show(t))).")
        }
        return .int
    }

    private func inferCond(_ e: Expr, _ env: [String: Scheme]) throws -> FType {
        guard case let .cond(test, yes, no) = e.kind else { return .unit }
        let tt = try infer(test, env)
        do { try unify(tt, .bool) } catch {
            throw FlowError(.type, test.pos, "The test after `if` has to be true or false (bool), but this is \(Self.article(TypePrinter.show(tt))).",
                            fix: "Compare it to something: if count > 0 then …, or if name <> \"\" then …")
        }
        let ty = try infer(yes, env)
        guard let no else {
            do { try unify(ty, .unit) } catch {
                throw FlowError(.type, yes.pos, "An `if` without `else` can only do something, but this gives back \(Self.article(TypePrinter.show(ty))).",
                                fix: "Add an `else` giving back the same type, or end the step with |> ignore.")
            }
            return .unit
        }
        let tn = try infer(no, env)
        do { try unify(ty, tn) } catch {
            var p = TypePrinter()
            let a = p.show(ty), b = p.show(tn)
            throw FlowError(.type, no.pos, "Both sides of an `if` have to give back the same type: `then` gives \(Self.article(a)), `else` gives \(Self.article(b)).",
                            fix: hint(expected: ty, actual: tn))
        }
        return ty
    }

    private func inferField(_ e: Expr, _ env: [String: Scheme]) throws -> FType {
        guard case let .field(x, name) = e.kind else { return .unit }
        let tx = try infer(x, env)
        guard let field = RunValue.fields.first(where: { $0.name == name }) else {
            throw FlowError(.type, e.pos, "There's no field `.\(name)`.", fix: "A script's result (from `attempt`) has .out, .err, .code and .ok.")
        }
        do { try unify(tx, .run) } catch {
            throw FlowError(.type, e.pos, "Only a script's result (from `attempt`) has .\(name); this is \(Self.article(TypePrinter.show(tx))).",
                            fix: "`run` gives back just the output; use `attempt` to get the whole result.")
        }
        return field.type
    }

    private func inferBlock(_ e: Expr, _ env: [String: Scheme], top: Bool) throws -> FType {
        guard case let .block(items) = e.kind else { return .unit }
        var scope = env
        var last: FType = .unit
        for (k, item) in items.enumerated() {
            switch item.kind {
            case let .bind(name, rec, params, body):
                level += 1
                defining.append(name)
                let t: FType
                if params.isEmpty {
                    t = try infer(body, scope)
                } else {
                    // A `let rec` function can call itself; in a plain `let`, its name inside
                    // is the one from above (if there's one).
                    let me = fresh()
                    var inner = scope
                    if rec { inner[name] = Scheme(generic: [], type: me) }
                    var types: [FType] = []
                    for p in params {
                        if let n = p.name {
                            let pt = fresh()
                            inner[n] = Scheme(generic: [], type: pt)
                            types.append(pt)
                        } else {
                            types.append(.unit)
                        }
                    }
                    let tb = try infer(body, inner)
                    t = types.reversed().reduce(tb) { .fn($1, $0) }
                    do { try unify(me, t) } catch {
                        throw FlowError(.type, item.pos, "`\(name)` calls itself in a way that doesn't fit how it's defined (\(TypePrinter.show(t))).")
                    }
                }
                defining.removeLast()
                level -= 1
                if Self.isHuge(t) {
                    throw FlowError(.type, item.pos, "`\(name)`'s type is too big to work with: it has types inside types more than \(Self.maxTypeDepth) deep.",
                                    fix: "This comes from functions built from functions again and again (such as f >> f, many times over). Write it more simply.")
                }
                let s = generalize(t)
                scope[name] = s
                if top { topLevel.append((name, s, item.pos.line)) }
                last = .unit
            case let .expr(x):
                last = try infer(x, scope)
                // A step that's still a function (print, or map upper with no list) does
                // nothing: it's missing values. The last line of a block is its value, so a
                // function there is fine, except at the end of the flow, where nothing uses it.
                if k < items.count - 1 || top, last.resolved.isFunction {
                    let n = Self.arrows(last)
                    throw FlowError(.type, x.pos, "\(Self.who(x)) is missing \(n == 1 ? "a value" : "values"): it needs \(n) more, so as it is this step does nothing.",
                                    fix: "Give it the rest of its values after it on the same line, or hand the last one in with |> (names |> map upper).")
                }
            }
        }
        return last
    }

    private func binary(_ op: String, _ l: Expr, _ r: Expr, _ env: [String: Scheme], _ pos: Pos) throws -> FType {
        let tl = try infer(l, env)
        let tr = try infer(r, env)
        return try binary(op, l, r, tl, tr, pos)
    }

    /// The type an operator gives, from its sides' (apart from the above, to keep the frame that
    /// stays on the stack while the sides are worked out small).
    private func binary(_ op: String, _ l: Expr, _ r: Expr, _ tl: FType, _ tr: FType, _ pos: Pos) throws -> FType {
        func same(_ what: String) throws {
            do { try unify(tl, tr) } catch {
                var p = TypePrinter()
                let a = p.show(tl), b = p.show(tr)
                throw FlowError(.type, pos, "Both sides of \(what) have to be the same type: the left is \(Self.article(a)), the right is \(Self.article(b)).",
                                fix: hint(expected: tl, actual: tr))
            }
        }
        func both(_ t: FType, _ what: String) throws {
            for (side, e) in [(tl, l), (tr, r)] {
                do { try unify(side, t) } catch {
                    throw FlowError(.type, e.pos, "\(what) works on \(Self.article(TypePrinter.show(t))), but this is \(Self.article(TypePrinter.show(side))).",
                                    fix: hint(expected: t, actual: side))
                }
            }
        }
        switch op {
        case "+":
            try same("+")
            guard requireNumberOrText(tl) else {
                throw FlowError(.type, pos, "+ adds numbers or joins text, but these are \(TypePrinter.show(tl)).",
                                fix: tl.resolved.isList ? "To join two lists, use @." : nil)
            }
            return tl
        case "-", "*", "/", "%":
            try both(.int, "`\(op)`")
            return .int
        case "<", "<=", ">", ">=":
            try same("`\(op)`")
            guard requireNumberOrText(tl) else {
                throw FlowError(.type, pos, "`\(op)` compares numbers or text, but these are \(TypePrinter.show(tl)).")
            }
            return .bool
        case "=", "<>":
            try same("`\(op)`")
            guard makeEquatable(tl) else {
                let shown = TypePrinter.show(tl)
                throw FlowError(.type, pos, tl.resolved.isFunction ? "Functions can't be compared, and these are functions (\(shown))."
                                    : "Functions can't be compared, and these have functions inside them (\(shown)).",
                                fix: "Compare what the functions give back instead.")
            }
            return .bool
        case "&&", "||":
            try both(.bool, "`\(op)`")
            return .bool
        case "@":
            let elem = fresh()
            try both(.list(elem), "`@`")
            return .list(elem)
        default:
            throw FlowError(.type, pos, "\(op) isn't an operator I know.")
        }
    }

    // MARK: the scripts named in run, attempt, pipe and attemptPipe

    private func checkScriptName(_ f: Expr, _ a: Expr) throws {
        try checkEPACommand(f, a)
        guard let scripts, case let .name(fn) = f.kind, ["run", "attempt", "pipe", "attemptPipe"].contains(fn),
              case let .str(name) = a.kind else { return }
        if ScriptNames.match(name, in: scripts) != nil { return }
        let near = Self.closest(name, among: scripts)
        let list = scripts.isEmpty ? "Your scripts folder has no scripts yet." : "Scripts there: " + scripts.prefix(12).joined(separator: ", ")
        throw FlowError(.type, a.pos, "There's no script called \"\(name)\" in your scripts folder.",
                        fix: near.map { "Did you mean \"\($0)\"? " + list } ?? list)
    }

    /// `epa ["conect"; …]`: a command EPA doesn't have is caught before anything runs.
    private func checkEPACommand(_ f: Expr, _ a: Expr) throws {
        guard case let .name(fn) = f.kind, fn == "epa" || fn == "attemptEpa", case let .list(items) = a.kind,
              let head = items.first, case let .str(command) = head.kind, !command.hasPrefix("-"),
              !EPA.commandNames.contains(command) else { return }
        let near = Self.closest(command, among: EPA.commandNames)
        throw FlowError(.type, head.pos, "EPA has no command \"\(command)\".",
                        fix: (near.map { "Did you mean \"\($0)\"? " } ?? "") + "Its commands: " + EPA.commandNames.joined(separator: ", ") + ".")
    }

    // MARK: words for messages

    /// A suggestion for the commonest mix-ups.
    private func hint(expected: FType, actual: FType) -> String? {
        let e = TypePrinter.show(expected), a = TypePrinter.show(actual)
        switch (e, a) {
        case ("string", "int"): return "Turn the number into text with `string n`, or put it in $\"…{n}…\"."
        case ("int", "string"): return "Read a number from text with `int s`."
        case ("string list", "string"): return "Put it in a list: [x]. Arguments to a script always go in a list."
        case ("string list", "int list"): return "Turn the numbers into text first: map string numbers, or [string n]."
        case ("string", "Run"): return "Take its output with .out (or use `run` instead of `attempt`)."
        case ("string", "string list"): return "Join the list into one text with `join \"\\n\"`, or take one item with `first`."
        case ("unit", _): return "End the step with |> ignore if you only want what it does."
        default: return nil
        }
    }

    private static func article(_ type: String) -> String {
        switch type {
        case "int": return "a number (int)"
        case "string": return "text (string)"
        case "bool": return "true or false (bool)"
        case "unit": return "nothing (unit)"
        case "Run": return "a script's result (Run)"
        default:
            if type.hasSuffix(" list") && !type.contains("->") { return "a list (\(type))" }
            if type.contains("->") { return "a function (\(type))" }
            return type
        }
    }

    private static func who(_ f: Expr) -> String {
        if case let .name(n) = head(f).kind { return n == Builtin.forName ? "This `for`" : "`\(n)`" }
        return "This function"
    }

    /// The function at the front of f a b c (f).
    private static func head(_ f: Expr) -> Expr {
        var head = f
        while case let .apply(g, _) = head.kind { head = g }
        return head
    }

    /// How many values f a b c gives the function at its front (3).
    private static func argumentCount(_ f: Expr) -> Int {
        var n = 0
        var e = f
        while case let .apply(g, _) = e.kind {
            n += 1
            e = g
        }
        return n
    }

    /// How many more values a function takes (2 for int -> int -> int).
    private static func arrows(_ t: FType) -> Int {
        var n = 0
        var t = t.resolved
        while case let .con("->", parts) = t {
            n += 1
            t = parts[1].resolved
        }
        return n
    }

    private static func describe(_ e: Expr) -> String {
        switch e.kind {
        case let .str(s): return "\"\(s)\""
        case let .int(n): return "\(n)"
        case let .name(n): return "`\(n)`"
        default: return "another value"
        }
    }

    /// The name nearest to `name`, if one is near enough to be a typo.
    static func closest(_ name: String, among names: [String]) -> String? {
        let lower = name.lowercased()
        let scored = names.map { ($0, distance(lower, $0.lowercased())) }.filter { $0.1 <= max(2, name.count / 3) }
        return scored.min { $0.1 < $1.1 || ($0.1 == $1.1 && $0.0 < $1.0) }?.0
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var row = Array(0...y.count)
        for i in 1...x.count {
            var prev = row[0]
            row[0] = i
            for j in 1...y.count {
                let cur = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (x[i - 1] == y[j - 1] ? 0 : 1))
                prev = cur
            }
        }
        return row[y.count]
    }
}

extension FType {
    var isVar: Bool {
        if case .v = self { return true }
        return false
    }
    var isList: Bool {
        if case .con("list", _) = self { return true }
        return false
    }
}

/// How `run "name"` finds its script: the file name, else the name without its extension.
public enum ScriptNames {
    public static func match(_ name: String, in names: [String]) -> String? {
        if names.contains(name) { return name }
        return names.first { ($0 as NSString).deletingPathExtension == name }
    }
}
