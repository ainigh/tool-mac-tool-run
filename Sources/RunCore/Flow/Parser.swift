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

    init(_ kind: Kind, _ pos: Pos) {
        self.kind = kind
        self.pos = pos
    }
}

/// A line of a block: a `let` (a name for a value, or a function with its parameters), or an
/// expression whose value is used (the last one) or that's run for what it does.
public struct Item: Sendable {
    public enum Kind: Sendable {
        case bind(name: String, params: [Param], body: Expr)
        case expr(Expr)
    }
    public let kind: Kind
    public let pos: Pos
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

    init(tokens: [Token]) {
        self.tokens = tokens
    }

    static func parse(_ source: String) throws -> Expr {
        var p = Parser(tokens: try Lexer.tokenize(source))
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

    // MARK: blocks and items

    /// Items lined up at `col`, one after another; its value is the last one's.
    private mutating func block(col: Int) throws -> Expr {
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
        return Expr(.block(items), start)
    }

    private mutating func item() throws -> Item {
        let t = peek
        if isKeyword("let") {
            _ = next()
            if isKeyword("rec") { _ = next() }
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
            return Item(kind: .bind(name: name, params: params, body: body), pos: t.pos)
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

    private mutating func expr() throws -> Expr { try pipe() }

    private mutating func pipe() throws -> Expr {
        var left = try compose()
        while !atBoundary && isSymbol("|>") {
            let op = next()
            let f = try compose()
            left = Expr(.apply(f, left), op.pos)
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
            left = Expr(.lambda([.name(x)], Expr(.apply(right, Expr(.apply(left, arg), op.pos)), op.pos)), op.pos)
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
            let right = s == "@" ? try binary(level: level) : try binary(level: level + 1)
            let name = s == "==" ? "=" : s == "!=" ? "<>" : s
            left = Expr(.binary(name, left, right), op.pos)
            if s == "@" || level == 2 { break }
        }
        return left
    }

    private mutating func unary() throws -> Expr {
        if isSymbol("-") {
            let op = next()
            return Expr(.negate(try unary()), op.pos)
        }
        return try application()
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
        if isKeyword("if") || isKeyword("fun") { return try atom() }
        var f = try postfix()
        while !atBoundary && startsArgument {
            let arg = try postfix()
            f = Expr(.apply(f, arg), arg.pos)
        }
        return f
    }

    private mutating func postfix() throws -> Expr {
        var e = try atom()
        while isSymbol(".") && !peek.startsLine {
            _ = next()
            guard case let .ident(field) = peek.kind else {
                throw FlowError(.syntax, peek.pos, "A field name should follow the `.`, such as .out, .err, .code or .ok.")
            }
            let t = next()
            e = Expr(.field(e, field), t.pos)
        }
        return e
    }

    private mutating func atom() throws -> Expr {
        let t = peek
        switch t.kind {
        case let .int(n):
            _ = next()
            return Expr(.int(n), t.pos)
        case let .string(s):
            _ = next()
            return Expr(.str(s), t.pos)
        case let .interpolated(texts, holes):
            _ = next()
            var exprs: [Expr] = []
            for (source, pos) in holes {
                var sub = Parser(tokens: try Lexer.tokenize(source, origin: pos))
                if sub.peek.kind == .eof { throw FlowError(.syntax, pos, "This {} is empty.", fix: "Put a name or an expression in it, such as {count}.") }
                let e = try sub.expr()
                if sub.peek.kind != .eof { throw FlowError(.syntax, sub.peek.pos, "I didn't expect \(Self.describe(sub.peek)) inside {…}.") }
                exprs.append(e)
            }
            return Expr(.interp(texts: texts, holes: exprs), t.pos)
        case .keyword("true"), .keyword("false"):
            _ = next()
            return Expr(.bool(t.kind == .keyword("true")), t.pos)
        case let .ident(name):
            _ = next()
            return Expr(.name(name), t.pos)
        case .symbol("("):
            _ = next()
            if isSymbol(")") {
                _ = next()
                return Expr(.unit, t.pos)
            }
            offside.append(0)
            let e = try expr()
            offside.removeLast()
            _ = try expect(")", "`)` to close the `(` on \(t.pos)")
            return e
        case .symbol("["):
            _ = next()
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
            return Expr(.list(items), t.pos)
        case .keyword("fun"):
            _ = next()
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
            _ = next()
            return Expr(.lambda(params, try branch(after: "->")), t.pos)
        case .keyword("if"):
            return try conditional()
        default:
            throw FlowError(.syntax, t.pos, "I expected a value here, found \(Self.describe(t)).")
        }
    }

    private mutating func conditional() throws -> Expr {
        let start = next()  // if or elif
        let test = try expr()
        guard isKeyword("then") && !atBoundary else {
            throw FlowError(.syntax, peek.pos, "Expected `then` after the `\(start.kind == .keyword("if") ? "if" : "elif")` test, found \(Self.describe(peek)).")
        }
        _ = next()
        let yes = try branch(after: "then")
        var no: Expr?
        if !atBoundary && isKeyword("elif") {
            no = try conditional()
        } else if !atBoundary && isKeyword("else") {
            _ = next()
            no = try branch(after: "else")
        }
        return Expr(.cond(test, yes, no), start.pos)
    }
}
