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
        /// A whole number as written, without a sign (so -9223372036854775808 can be written: the
        /// parser joins a minus sign to it).
        case int(UInt64)
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
        // Windows (\r\n) and old Mac (\r) line endings read as \n: Swift counts \r\n as one
        // Character, which would hide the line break from everything below.
        let chars = Array(source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
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

        /// Reads the source of a {…} hole in a $"…" text up to its closing } (left for the caller),
        /// or nil when it's never closed. Text inside the hole is skipped whole, so a brace in it
        /// doesn't count: $"{ "}" }". A \" in the hole is a quote, so $"{name + \"!\"}" works too.
        /// Texts with holes of their own inside a hole are followed with a stack, not by calling
        /// itself, so no nesting can run it out of room.
        func scanHole() throws -> String? {
            enum Mode {
                case hole(depth: Int)
                case text(interpolated: Bool)
                /// Text started with \" inside a hole: it ends at the next \".
                case escapedText
            }
            var modes: [Mode] = [.hole(depth: 1)]
            var hole = ""
            while i < chars.count, let mode = modes.last {
                // Each text in a hole is read again when the hole is, so stop early rather than
                // read a very deep one over and over (the parser would stop it anyway).
                if modes.count > 2 * Parser.maxDepth { throw Parser.tooDeep(Pos(line: line, col: col)) }
                let ch = chars[i]
                let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
                switch mode {
                case let .hole(depth):
                    if ch == "}" {
                        modes.removeLast()
                        if depth == 1 && modes.isEmpty { return hole }
                        if depth > 1 { modes.append(.hole(depth: depth - 1)) }
                    } else if ch == "{" {
                        modes[modes.count - 1] = .hole(depth: depth + 1)
                    } else if ch == "\"" {
                        modes.append(.text(interpolated: hole.last == "$"))
                    } else if ch == "\\" && next == "\"" {
                        modes.append(.escapedText)
                        hole.append("\"")
                        advance(2)
                        continue
                    }
                case let .text(interpolated):
                    if ch == "\\", let next {
                        hole.append(ch)
                        hole.append(next)
                        advance(2)
                        continue
                    }
                    if ch == "\"" {
                        modes.removeLast()
                    } else if interpolated && ch == "{" {
                        if next == "{" {
                            hole += "{{"
                            advance(2)
                            continue
                        }
                        modes.append(.hole(depth: 1))
                    }
                case .escapedText:
                    if ch == "\\" && next == "\"" {
                        modes.removeLast()
                        hole.append("\"")
                        advance(2)
                        continue
                    }
                }
                hole.append(ch)
                advance()
            }
            return nil
        }

        while i < chars.count {
            let c = chars[i]
            if c == " " || c == "\t" || c == "\n" {
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
            if isDigit(c) {
                var s = ""
                while i < chars.count, isDigit(chars[i]) || chars[i] == "_" {
                    if chars[i] != "_" { s.append(chars[i]) }
                    advance()
                }
                guard let n = UInt64(s) else { throw FlowError(.syntax, pos, "\(s) is too big a number.", fix: tooBigFix) }
                add(.int(n), pos)
                continue
            }
            if c.isLetter || c == "_" {
                var s = ""
                while i < chars.count, chars[i].isLetter || isDigit(chars[i]) || chars[i] == "_" || chars[i] == "'" {
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
                        guard let hole = try scanHole() else {
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
                guard closed else { throw FlowError(.syntax, pos, "This text is never closed.", fix: "End it with a \". Text can carry on over several lines, so the \" it's missing may belong further down.") }
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

    static let tooBigFix = "Whole numbers in a flow go from -9223372036854775808 to 9223372036854775807."

    /// 0 to 9 only: other numerals (², ٣) aren't numbers to a flow.
    private static func isDigit(_ c: Character) -> Bool { c.isASCII && c.isWholeNumber }

    private static func matches(_ sym: String, _ chars: [Character], _ i: Int) -> Bool {
        let s = Array(sym)
        guard i + s.count <= chars.count else { return false }
        for k in 0..<s.count where chars[i + k] != s[k] { return false }
        return true
    }
}
