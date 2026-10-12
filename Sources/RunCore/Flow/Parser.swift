import Foundation

/// A parameter of a function: a name, or `()` (a function that takes nothing worth naming).
public enum Param: Equatable, Sendable {
    case name(String)
    case unit

    var name: String? {
        if case let .name(n) = self { return n }
        return nil
    }
}

/// A piece of a .flow program.
public final class Expr: @unchecked Sendable {
    public indirect enum Kind {
        case int(Int)
        case str(String)
        case bool(Bool)
        case unit
        /// $"…": text parts around the holes (`texts.count == holes.count + 1`).
        case interp(texts: [String], holes: [Expr])
        case list([Expr])
        case name(String)
        case apply(Expr, Expr)
        case lambda([Param], Expr)
        case binary(String, Expr, Expr)
        case negate(Expr)
        case cond(Expr, Expr, Expr?)
        case field(Expr, String)
        case block([Item])
    }

    public let kind: Kind
    public let pos: Pos
    /// Where its keywords are, for the block editor: an `if`'s `then` and `else` (or `elif`), a
    /// `fun`'s `->`, a `for`'s `do`.
    var marks: [Pos] = []
    /// How many levels deep the tree under it goes (1 for a value on its own). The checker and
    /// the interpreter go one call deeper per level, so the parser keeps it in bounds.
    let depth: Int

    init(_ kind: Kind, _ pos: Pos) {
        self.kind = kind
        self.pos = pos
        depth = 1 + (Self.children(of: kind).map(\.depth).max() ?? 0)
    }

    private static func children(of kind: Kind) -> [Expr] {
        switch kind {
        case .int, .str, .bool, .unit, .name: []
        case let .interp(_, holes): holes
        case let .list(items): items
        case let .apply(f, a): [f, a]
        case let .lambda(_, body): [body]
        case let .binary(_, l, r): [l, r]
        case let .negate(x): [x]
        case let .cond(test, yes, no): [test, yes] + (no.map { [$0] } ?? [])
        case let .field(x, _): [x]
        case let .block(items): items.map {
            switch $0.kind {
            case let .bind(_, _, _, body): body
            case let .expr(x): x
            }
        }
        }
    }
}

/// A line of a block: a `let` (a name for a value, or a function with its parameters), or an
/// expression whose value is used (the last one) or that's run for what it does. Only a
/// `let rec` function sees its own name inside its body (so it can call itself); in a plain
/// `let`, the name inside is whatever it meant above (`let f x = f (x * 10)` uses the old `f`).
public struct Item: Sendable {
    public enum Kind: Sendable {
        case bind(name: String, rec: Bool, params: [Param], body: Expr)
        case expr(Expr)
    }
    public let kind: Kind
    public let pos: Pos
    /// Just after its last token.
    public var end = Pos(line: 0, col: 0)
}

/// Reads tokens into a program, with F#'s layout rule: a line indented under the one before
/// carries it on; a line at the same indent starts the next step of the block; a line starting
/// with an operator (|>, +, &&…), `then`, `elif` or `else` carries on what's above it.
struct Parser {
    private var tokens: [Token]
    private var index = 0
    /// The column a token starting a line must be right of to carry on the current item.
    private var offside: [Int] = [0]
    private var fresh = 0
    /// How many brackets, blocks, `if`s and `fun`s deep the parser is now.
    private var nesting = 0
    private let stack: StackGuard
    /// Just after the last token read.
    private var lastEnd = Pos(line: 0, col: 0)

    /// How deep things may nest (brackets in brackets, or a chain like 1 + 1 + … with this many
    /// terms). Far more than a flow needs, and little enough that reading, checking and running
    /// it stay well inside even a small (512 KB) thread stack.
    static let maxDepth = 300

    init(tokens: [Token], stack: StackGuard = StackGuard()) {
        self.tokens = tokens
        self.stack = stack
    }

    static func parse(_ source: String) throws -> Expr {
        try parse(tokens: try Lexer.tokenize(source))
    }

    static func parse(tokens: [Token]) throws -> Expr {
        var p = Parser(tokens: tokens)
        let first = p.peek
        if first.kind == .eof { return Expr(.block([]), first.pos) }
        let program = try p.block(col: first.pos.col)
        let rest = p.peek
        if rest.kind != .eof {
            if rest.startsLine && rest.pos.col > first.pos.col {
                throw FlowError(.syntax, rest.pos, "This line is indented, but there's nothing above it for it to carry on.",
                                fix: "Line it up with the lines above, or indent it under a `let … =` or `fun … ->` it belongs to.")
            }
            throw FlowError(.syntax, rest.pos, "I didn't expect \(Self.describe(rest)) here.")
        }
        return program
    }

    // MARK: tokens

    private var peek: Token { tokens[index] }

    private mutating func next() -> Token {
        let t = tokens[index]
        if index < tokens.count - 1 { index += 1 }
        if t.kind != .eof { lastEnd = t.end }
        return t
    }

    private static let infix: Set<String> = ["|>", ">>", "||", "&&", "=", "==", "!=", "<>", "<", "<=", ">", ">=", "@", "+", "-", "*", "/", "%"]

    /// The next token ends the item being read: the end, or a new line that isn't indented under it.
    private var atBoundary: Bool {
        let t = peek
        if t.kind == .eof { return true }
        guard t.startsLine else { return false }
        let limit = offside.last ?? 0
        switch t.kind {
        case let .symbol(s) where Self.infix.contains(s): return t.pos.col < limit
        case .keyword("then"), .keyword("elif"), .keyword("else"): return t.pos.col < limit
        default: return t.pos.col <= limit
        }
    }

    private func isSymbol(_ s: String) -> Bool { peek.kind == .symbol(s) }
    private func isKeyword(_ k: String) -> Bool { peek.kind == .keyword(k) }

    private mutating func expect(_ s: String, _ what: String) throws -> Token {
        if peek.kind == .symbol(s) || peek.kind == .keyword(s) { return next() }
        throw FlowError(.syntax, peek.pos, "Expected \(what), found \(Self.describe(peek)).")
    }

    static func describe(_ t: Token) -> String {
        switch t.kind {
        case let .int(n): "the number \(n)"
        case let .string(s): "the text \"\(s)\""
        case .interpolated: "a $\"…\" text"
        case let .ident(s): "`\(s)`"
        case let .keyword(k): "`\(k)`"
        case let .symbol(s): "`\(s)`"
        case .eof: "the end of the file"
        }
    }

    // MARK: how deep

    static func tooDeep(_ pos: Pos) -> FlowError {
        FlowError(.syntax, pos, "This is nested too deeply: more than \(maxDepth) levels of brackets, blocks, `if`s, `fun`s or operators inside one another.",
                  fix: "Split it up: give the inner parts names with `let`, one per line.")
    }

    /// A piece of the tree, as long as it isn't too deep.
    private func node(_ kind: Expr.Kind, _ pos: Pos) throws -> Expr {
        let e = Expr(kind, pos)
        if e.depth > Self.maxDepth { throw Self.tooDeep(pos) }
        return e
    }

    /// Goes one level deeper (a bracket, a block, an `if`…), as long as that isn't too deep.
    private mutating func enter() throws {
        nesting += 1
        if nesting > Self.maxDepth || !stack.hasRoom { throw Self.tooDeep(peek.pos) }
    }

    private mutating func leave() { nesting -= 1 }

    // MARK: blocks and items

    /// Items lined up at `col`, one after another; its value is the last one's.
    private mutating func block(col: Int) throws -> Expr {
        try enter()
        defer { leave() }
        let start = peek.pos
        var items: [Item] = []
        while true {
            offside.append(col)
            let item = try self.item()
            offside.removeLast()
            items.append(item)
            let t = peek
            if t.kind == .eof { break }
            if t.startsLine && t.pos.col == col { continue }
            if t.startsLine && t.pos.col > col {
                throw FlowError(.syntax, t.pos, "I didn't expect \(Self.describe(t)) here: it's indented more than the line before it, which is complete.",
                                fix: "Line it up with the line above, or join it to that line.")
            }
            break
        }
        return try node(.block(items), start)
    }

    private mutating func item() throws -> Item {
        var it = try itemOnly()
        it.end = lastEnd
        return it
    }

    private mutating func itemOnly() throws -> Item {
        let t = peek
        if isKeyword("let") {
            _ = next()
            let rec = isKeyword("rec")
            if rec { _ = next() }
            guard case let .ident(name) = peek.kind else {
                throw FlowError(.syntax, peek.pos, "A `let` needs a name next, found \(Self.describe(peek)).",
                                fix: "Write it as: let name = value")
            }
            _ = next()
            var params: [Param] = []
            while !isSymbol("=") {
                if case let .ident(p) = peek.kind {
                    _ = next()
                    params.append(.name(p))
                } else if isSymbol("(") && tokens[index + 1].kind == .symbol(")") {
                    _ = next(); _ = next()
                    params.append(.unit)
                } else {
                    throw FlowError(.syntax, peek.pos, "Expected `=` after `let \(name)`, found \(Self.describe(peek)).",
                                    fix: "Write it as: let \(name) = value (or let \(name) x y = … for a function)")
                }
            }
            _ = next()
            let body = try branch(after: "let \(name) =")
            if rec && params.isEmpty {
                // let rec f = fun x -> … is let rec f x = … (the `fun` may be on the line under it).
                var fn = body
                if case let .block(items) = fn.kind, items.count == 1, case let .expr(x) = items[0].kind { fn = x }
                guard case let .lambda(ps, inner) = fn.kind else {
                    throw FlowError(.syntax, body.pos, "Only a function can call itself, so `let rec \(name)` needs to be a function.",
                                    fix: "Give it parameters (let rec \(name) x = …), or make it a `fun` (let rec \(name) = fun x -> …). Or leave out `rec`.")
                }
                return Item(kind: .bind(name: name, rec: true, params: ps, body: inner), pos: t.pos)
            }
            return Item(kind: .bind(name: name, rec: rec, params: params, body: body), pos: t.pos)
        }
        if t.kind == .eof {
            throw FlowError(.syntax, t.pos, "I expected a step here, found \(Self.describe(t)).")
        }
        return Item(kind: .expr(try expr()), pos: t.pos)
    }

    /// What follows `=`, `->`, `then` or `else`: on the same line, an expression; on the lines
    /// under it (indented), a block.
    private mutating func branch(after what: String) throws -> Expr {
        let t = peek
        if t.kind == .eof { throw FlowError(.syntax, t.pos, "Nothing follows `\(what)`.") }
        if t.startsLine {
            guard t.pos.col > (offside.last ?? 0) else {
                throw FlowError(.syntax, t.pos, "What follows `\(what)` should be on the same line, or on the lines under it, indented.")
            }
            return try block(col: t.pos.col)
        }
        return try expr()
    }

    // MARK: expressions, loosest first

    private mutating func expr() throws -> Expr {
        try enter()
        defer { leave() }
        return try pipe()
    }

    private mutating func pipe() throws -> Expr {
        var left = try compose()
        while !atBoundary && isSymbol("|>") {
            let op = next()
            let f = try compose()
            left = try node(.apply(f, left), op.pos)
        }
        return left
    }

    private mutating func compose() throws -> Expr {
        var left = try binary(level: 0)
        while !atBoundary && isSymbol(">>") {
            let op = next()
            let right = try binary(level: 0)
            fresh += 1
            let x = "$x\(fresh)"
            let arg = Expr(.name(x), op.pos)
            left = try node(.lambda([.name(x)], try node(.apply(right, try node(.apply(left, arg), op.pos)), op.pos)), op.pos)
        }
        return left
    }

    private static let levels: [[String]] = [["||"], ["&&"], ["=", "==", "!=", "<>", "<", "<=", ">", ">="], ["@"], ["+", "-"], ["*", "/", "%"]]

    private mutating func binary(level: Int) throws -> Expr {
        guard level < Self.levels.count else { return try unary() }
        var left = try binary(level: level + 1)
        while !atBoundary, case let .symbol(s) = peek.kind, Self.levels[level].contains(s) {
            let op = next()
            // @ joins to the right; comparisons don't chain.
            let right: Expr
            if s == "@" {
                try enter()
                right = try binary(level: level)
                leave()
            } else {
                right = try binary(level: level + 1)
            }
            let name = s == "==" ? "=" : s == "!=" ? "<>" : s
            left = try node(.binary(name, left, right), op.pos)
            if s == "@" || level == 2 { break }
        }
        return left
    }

    private mutating func unary() throws -> Expr {
        // The minus signs first (a loop, so - - - … can't run the parser out of room), then
        // what they apply to, inside out.
        var minuses: [Pos] = []
        while isSymbol("-") { minuses.append(next().pos) }
        var e: Expr
        if let last = minuses.last, case let .int(n) = peek.kind {
            // A minus sign right before a number is part of it: -3 is a number, and so is
            // -9223372036854775808 (whose digits alone are one too big to be one).
            let t = next()
            guard n <= UInt64(Int.max) + 1 else { throw Self.tooBig(n, t.pos) }
            e = Expr(.int(n == UInt64(Int.max) + 1 ? Int.min : -Int(n)), last)
            minuses.removeLast()
            e = try postfixAndArguments(e)
        } else {
            e = try application()
        }
        for pos in minuses.reversed() { e = try node(.negate(e), pos) }
        return e
    }

    static func tooBig(_ n: UInt64, _ pos: Pos) -> FlowError {
        FlowError(.syntax, pos, "\(n) is too big a number.", fix: Lexer.tooBigFix)
    }

    private var startsArgument: Bool {
        switch peek.kind {
        case .int, .string, .interpolated, .ident: true
        case .keyword("true"), .keyword("false"): true
        case .symbol("("), .symbol("["): true
        default: false
        }
    }

    private mutating func application() throws -> Expr {
        if isKeyword("if") || isKeyword("fun") || isKeyword("for") { return try atom() }
        return try postfixAndArguments(try atom())
    }

    /// The fields after `e` (`.out`), then the arguments it's given.
    private mutating func postfixAndArguments(_ e: Expr) throws -> Expr {
        var f = try postfix(e)
        while !atBoundary && startsArgument {
            let arg = try postfix(try atom())
            f = try node(.apply(f, arg), arg.pos)
        }
        return f
    }

    private mutating func postfix(_ atom: Expr) throws -> Expr {
        var e = atom
        while isSymbol(".") && !peek.startsLine {
            _ = next()
            guard case let .ident(field) = peek.kind else {
                throw FlowError(.syntax, peek.pos, "A field name should follow the `.`, such as .out, .err, .code or .ok.")
            }
            let t = next()
            e = try node(.field(e, field), t.pos)
        }
        return e
    }

    private mutating func atom() throws -> Expr {
        let t = peek
        switch t.kind {
        case let .int(n):
            _ = next()
            guard let value = Int(exactly: n) else { throw Self.tooBig(n, t.pos) }
            return Expr(.int(value), t.pos)
        case let .string(s):
            _ = next()
            return Expr(.str(s), t.pos)
        case .interpolated:
            return try interpolated()
        case .keyword("true"), .keyword("false"):
            _ = next()
            return Expr(.bool(t.kind == .keyword("true")), t.pos)
        case let .ident(name):
            _ = next()
            return Expr(.name(name), t.pos)
        case .symbol("("):
            return try parenthesised()
        case .symbol("["):
            return try list()
        case .keyword("fun"):
            return try lambda()
        case .keyword("if"):
            return try conditional()
        case .keyword("for"):
            return try loop()
        default:
            throw FlowError(.syntax, t.pos, "I expected a value here, found \(Self.describe(t)).")
        }
    }

    // The bigger atoms are functions of their own: Swift gives a function one stack frame big
    // enough for all its cases, and atom is in every level of nesting.

    private mutating func interpolated() throws -> Expr {
        let t = next()
        guard case let .interpolated(texts, holes) = t.kind else { return Expr(.unit, t.pos) }
        var exprs: [Expr] = []
        for (source, pos) in holes {
            var sub = Parser(tokens: try Lexer.tokenize(source, origin: pos), stack: stack)
            sub.nesting = nesting
            if sub.peek.kind == .eof { throw FlowError(.syntax, pos, "This {} is empty.", fix: "Put a name or an expression in it, such as {count}.") }
            let e = try sub.expr()
            if sub.peek.kind != .eof { throw FlowError(.syntax, sub.peek.pos, "I didn't expect \(Self.describe(sub.peek)) inside {…}.") }
            exprs.append(e)
        }
        return try node(.interp(texts: texts, holes: exprs), t.pos)
    }

    private mutating func parenthesised() throws -> Expr {
        let t = next()
        if isSymbol(")") {
            _ = next()
            return Expr(.unit, t.pos)
        }
        offside.append(0)
        let e = try expr()
        offside.removeLast()
        _ = try expect(")", "`)` to close the `(` on \(t.pos)")
        return e
    }

    private mutating func list() throws -> Expr {
        let t = next()
        var items: [Expr] = []
        if isSymbol("]") {
            _ = next()
            return Expr(.list([]), t.pos)
        }
        let col = peek.pos.col
        while true {
            offside.append(col)
            items.append(try expr())
            offside.removeLast()
            if isSymbol(";") || isSymbol(",") {
                _ = next()
                if isSymbol("]") { break }
                continue
            }
            if isSymbol("]") { break }
            if peek.startsLine && peek.pos.col == col { continue }
            throw FlowError(.syntax, peek.pos, "Expected `;` or `]` in the list started on \(t.pos), found \(Self.describe(peek)).",
                            fix: "Separate items with ; (or put each on its own line) and end the list with ].")
        }
        _ = next()
        return try node(.list(items), t.pos)
    }

    private mutating func lambda() throws -> Expr {
        let t = next()
        var params: [Param] = []
        while !isSymbol("->") {
            if case let .ident(p) = peek.kind {
                _ = next()
                params.append(.name(p))
            } else if isSymbol("(") && tokens[index + 1].kind == .symbol(")") {
                _ = next(); _ = next()
                params.append(.unit)
            } else {
                throw FlowError(.syntax, peek.pos, "Expected `->` after `fun` and its parameters, found \(Self.describe(peek)).",
                                fix: "Write it as: fun x -> …")
            }
        }
        guard !params.isEmpty else { throw FlowError(.syntax, peek.pos, "`fun` needs a parameter before `->`.", fix: "fun x -> …, or fun () -> … for none") }
        let arrow = next()
        let e = try node(.lambda(params, try branch(after: "->")), t.pos)
        e.marks = [arrow.pos]
        return e
    }

    /// `for x in xs do body`: `body` for each item of `xs`, in order. It's `each` written as a
    /// step (what the block editor's "Repeat" writes): `$for (fun x -> body) xs`.
    private mutating func loop() throws -> Expr {
        try enter()
        defer { leave() }
        let start = next()
        guard case let .ident(name) = peek.kind else {
            throw FlowError(.syntax, peek.pos, "A `for` needs a name for each item next, found \(Self.describe(peek)).",
                            fix: "Write it as: for line in lines text do …")
        }
        let nameToken = next()
        guard isKeyword("in") else {
            throw FlowError(.syntax, peek.pos, "Expected `in` after `for \(name)`, found \(Self.describe(peek)).",
                            fix: "Write it as: for \(name) in items do …")
        }
        _ = next()
        let items = try expr()
        guard isKeyword("do") && !atBoundary else {
            throw FlowError(.syntax, peek.pos, "Expected `do` after `for \(name) in …`, found \(Self.describe(peek)).",
                            fix: "Write it as: for \(name) in items do, with the steps on the lines under it, indented.")
        }
        let doToken = next()
        let body = try branch(after: "do")
        let fn = try node(.lambda([.name(name)], body), nameToken.pos)
        fn.marks = [doToken.pos]
        let e = try node(.apply(try node(.apply(Expr(.name(Builtin.forName), start.pos), fn), start.pos), items), start.pos)
        e.marks = [doToken.pos]
        return e
    }

    private mutating func conditional() throws -> Expr {
        try enter()
        defer { leave() }
        let start = next()  // if or elif
        let test = try expr()
        guard isKeyword("then") && !atBoundary else {
            throw FlowError(.syntax, peek.pos, "Expected `then` after the `\(start.kind == .keyword("if") ? "if" : "elif")` test, found \(Self.describe(peek)).")
        }
        let thenToken = next()
        let yes = try branch(after: "then")
        var no: Expr?
        var marks = [thenToken.pos]
        if !atBoundary && isKeyword("elif") {
            marks.append(peek.pos)
            no = try conditional()
        } else if !atBoundary && isKeyword("else") {
            marks.append(next().pos)
            no = try branch(after: "else")
        }
        let e = try node(.cond(test, yes, no), start.pos)
        e.marks = marks
        return e
    }
}
