import Foundation

/// Where something is in a .flow file (1-based), for messages.
public struct Pos: Equatable, Hashable, Sendable, CustomStringConvertible {
    public var line: Int
    public var col: Int
    public init(line: Int, col: Int) {
        self.line = line
        self.col = col
    }
    public var description: String { "line \(line), column \(col)" }
}

/// A problem in a .flow file: where it is, what's wrong, and (when there's one) how to fix it.
public struct FlowError: Error, Equatable, CustomStringConvertible, Sendable {
    public enum Stage: String, Sendable {
        case syntax, type, run, stopped
    }
    public var stage: Stage
    public var pos: Pos?
    public var message: String
    public var fix: String?

    public init(_ stage: Stage, _ pos: Pos?, _ message: String, fix: String? = nil) {
        self.stage = stage
        self.pos = pos
        self.message = message
        self.fix = fix
    }

    public var description: String {
        var s = pos.map { "line \($0.line): " } ?? ""
        s += message
        if let fix { s += "\n→ fix: \(fix)" }
        return s
    }
}

struct Token: Equatable {
    enum Kind: Equatable {
        case int(Int)
        case string(String)
        /// $"…{expr}…": the text parts and the holes' source, in order (`holes[i]` comes after `texts[i]`).
        case interpolated(texts: [String], holes: [(String, Pos)])
        case ident(String)
        case keyword(String)
        case symbol(String)
        case eof

        static func == (a: Kind, b: Kind) -> Bool {
            switch (a, b) {
            case let (.int(x), .int(y)): x == y
            case let (.string(x), .string(y)): x == y
            case let (.ident(x), .ident(y)), let (.keyword(x), .keyword(y)), let (.symbol(x), .symbol(y)): x == y
            case (.eof, .eof): true
            case let (.interpolated(t1, h1), .interpolated(t2, h2)): t1 == t2 && h1.map(\.0) == h2.map(\.0)
            default: false
            }
        }
    }

    var kind: Kind
    var pos: Pos
    /// The first token on its line (where the layout rules look).
    var startsLine: Bool
}

enum Lexer {
    static let keywords: Set<String> = ["let", "rec", "fun", "if", "then", "elif", "else", "true", "false"]
    /// Longest first, so `|>` isn't read as `|` then `>`.
    static let symbols = ["|>", ">>", "->", "==", "!=", "<>", "<=", ">=", "&&", "||",
                          "=", "<", ">", "+", "-", "*", "/", "%", "@", "(", ")", "[", "]", ";", ",", "."]

    static func tokenize(_ source: String, origin: Pos = Pos(line: 1, col: 1)) throws -> [Token] {
        var tokens: [Token] = []
        let chars = Array(source)
        var i = 0
        var line = origin.line, col = origin.col
        var lineHasToken = false

        func advance(_ n: Int = 1) {
            for _ in 0..<n {
                if i < chars.count, chars[i] == "\n" {
                    line += 1
                    col = 1
                    lineHasToken = false
                } else {
                    col += 1
                }
                i += 1
            }
        }
        func add(_ kind: Token.Kind, _ pos: Pos) {
            tokens.append(Token(kind: kind, pos: pos, startsLine: !lineHasToken))
            lineHasToken = true
        }

        while i < chars.count {
            let c = chars[i]
            if c == " " || c == "\t" || c == "\r" || c == "\n" {
                advance()
                continue
            }
            // Comments: // to the end of the line, # too (so a #! line is fine), (* … *) across lines.
            if c == "/" && i + 1 < chars.count && chars[i + 1] == "/" || c == "#" {
                while i < chars.count && chars[i] != "\n" { advance() }
                continue
            }
            if c == "(" && i + 1 < chars.count && chars[i + 1] == "*" {
                let start = Pos(line: line, col: col)
                advance(2)
                while i < chars.count && !(chars[i] == "*" && i + 1 < chars.count && chars[i + 1] == ")") { advance() }
                guard i < chars.count else { throw FlowError(.syntax, start, "This (* comment is never closed.", fix: "End it with *)") }
                advance(2)
                continue
            }
            let pos = Pos(line: line, col: col)
            if c.isNumber {
                var s = ""
                while i < chars.count, chars[i].isNumber || chars[i] == "_" {
                    if chars[i] != "_" { s.append(chars[i]) }
                    advance()
                }
                guard let n = Int(s) else { throw FlowError(.syntax, pos, "\(s) is too big a number.") }
                add(.int(n), pos)
                continue
            }
            if c.isLetter || c == "_" {
                var s = ""
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" || chars[i] == "'" {
                    s.append(chars[i])
                    advance()
                }
                add(keywords.contains(s) ? .keyword(s) : .ident(s), pos)
                continue
            }
            if c == "\"" || (c == "$" && i + 1 < chars.count && chars[i + 1] == "\"") {
                let interpolated = c == "$"
                advance(interpolated ? 2 : 1)
                var texts: [String] = []
                var holes: [(String, Pos)] = []
                var current = ""
                var closed = false
                while i < chars.count {
                    let ch = chars[i]
                    if ch == "\"" {
                        advance()
                        closed = true
                        break
                    }
                    if ch == "\\" && i + 1 < chars.count {
                        let next = chars[i + 1]
                        switch next {
                        case "n": current.append("\n")
                        case "t": current.append("\t")
                        case "\"": current.append("\"")
                        case "\\": current.append("\\")
                        case "{": current.append("{")
                        case "}": current.append("}")
                        case "$": current.append("$")
                        default:
                            throw FlowError(.syntax, Pos(line: line, col: col), "\\\(next) isn't an escape I know.",
                                            fix: "Use \\n (new line), \\t (tab), \\\" (a quote) or \\\\ (a backslash).")
                        }
                        advance(2)
                        continue
                    }
                    if interpolated && ch == "{" {
                        if i + 1 < chars.count && chars[i + 1] == "{" {
                            current.append("{")
                            advance(2)
                            continue
                        }
                        advance()
                        let holePos = Pos(line: line, col: col)
                        var depth = 1
                        var hole = ""
                        while i < chars.count {
                            if chars[i] == "{" { depth += 1 }
                            if chars[i] == "}" {
                                depth -= 1
                                if depth == 0 { break }
                            }
                            hole.append(chars[i])
                            advance()
                        }
                        guard i < chars.count else {
                            throw FlowError(.syntax, holePos, "A { in this text is never closed.", fix: "Close it with }, or write {{ for a { of its own.")
                        }
                        advance()
                        texts.append(current)
                        current = ""
                        holes.append((hole, holePos))
                        continue
                    }
                    if interpolated && ch == "}" && i + 1 < chars.count && chars[i + 1] == "}" {
                        current.append("}")
                        advance(2)
                        continue
                    }
                    current.append(ch)
                    advance()
                }
                guard closed else { throw FlowError(.syntax, pos, "This text is never closed.", fix: "End it with a \" on the same line.") }
                texts.append(current)
                add(interpolated ? .interpolated(texts: texts, holes: holes) : .string(current), pos)
                continue
            }
            if let sym = symbols.first(where: { matches($0, chars, i) }) {
                advance(sym.count)
                add(.symbol(sym), pos)
                continue
            }
            throw FlowError(.syntax, pos, "\(c) isn't something a flow can contain here.")
        }
        tokens.append(Token(kind: .eof, pos: Pos(line: line + 1, col: 1), startsLine: true))
        return tokens
    }

    private static func matches(_ sym: String, _ chars: [Character], _ i: Int) -> Bool {
        let s = Array(sym)
        guard i + s.count <= chars.count else { return false }
        for k in 0..<s.count where chars[i + k] != s[k] { return false }
        return true
    }
}
