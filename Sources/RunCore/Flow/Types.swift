import Foundation

/// A type not known yet: filled in (linked) as the program is read.
final class TVar {
    let id: Int
    var link: FType?
    /// How deep in `let`s it was made: a variable deeper than the `let` being finished is the
    /// `let`'s own, so it's generic.
    var level: Int
    /// It has to end up a number or text (it's added or compared).
    var numberOrText: Bool
    /// What made it so, for the message when it isn't.
    var constraintPos: Pos?
    /// It's compared with = or <>, so it can't be a function, or have one inside it (a list of
    /// functions). Unlike numberOrText, it stays generic: `let same a b = a = b` works on
    /// anything that can be compared.
    var equatable: Bool

    init(id: Int, level: Int, equatable: Bool = false) {
        self.id = id
        self.level = level
        self.equatable = equatable
        numberOrText = false
    }
}

/// A type in a flow: int, string, bool, unit, Run, `'a list`, `'a -> 'b`, or one not known yet.
indirect enum FType {
    case con(String, [FType])
    case v(TVar)

    static let int = FType.con("int", [])
    static let string = FType.con("string", [])
    static let bool = FType.con("bool", [])
    static let unit = FType.con("unit", [])
    static let run = FType.con("Run", [])
    static func list(_ t: FType) -> FType { .con("list", [t]) }
    static func fn(_ a: FType, _ b: FType) -> FType { .con("->", [a, b]) }

    /// Following the links: the type as far as it's known.
    var resolved: FType {
        if case let .v(tv) = self, let link = tv.link {
            let r = link.resolved
            tv.link = r
            return r
        }
        return self
    }

    var isFunction: Bool {
        if case .con("->", _) = resolved { return true }
        return false
    }
}

/// A type with its generic variables (`'a -> 'a list`): each use gets new ones.
struct Scheme {
    var generic: [Int]
    var type: FType
}

/// Writes types as F# does: `int`, `string list`, `'a -> 'b`, `(int -> bool) -> int list -> int list`.
struct TypePrinter {
    private var names: [Int: String] = [:]

    mutating func show(_ t: FType) -> String { show(t, top: true) }

    private mutating func show(_ t: FType, top: Bool) -> String {
        switch t.resolved {
        case let .v(tv):
            if let n = names[tv.id] { return n }
            let n = "'" + String(UnicodeScalar(UInt8(97 + names.count % 26))) + (names.count >= 26 ? "\(names.count / 26)" : "")
            names[tv.id] = n
            return n
        case let .con("->", args):
            let a = args[0].resolved.isFunction ? "(\(show(args[0], top: false)))" : show(args[0], top: false)
            let s = "\(a) -> \(show(args[1], top: true))"
            return top ? s : s
        case let .con("list", args):
            let inner = show(args[0], top: false)
            return args[0].resolved.isFunction ? "(\(inner)) list" : "\(inner) list"
        case let .con(name, _):
            return name
        }
    }

    static func show(_ t: FType) -> String {
        var p = TypePrinter()
        return p.show(t)
    }
}

/// Reads a builtin's signature, written as it's shown: `('a -> bool) -> 'a list -> 'a list`.
enum SignatureReader {
    static func read(_ text: String, fresh: (String) -> FType) -> FType {
        var tokens: [String] = []
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c == " " { i = text.index(after: i); continue }
            if c == "(" || c == ")" { tokens.append(String(c)); i = text.index(after: i); continue }
            if c == "-" { tokens.append("->"); i = text.index(i, offsetBy: 2); continue }
            var word = ""
            while i < text.endIndex, text[i].isLetter || text[i].isNumber || text[i] == "'" {
                word.append(text[i])
                i = text.index(after: i)
            }
            tokens.append(word)
        }
        var k = 0
        func arrow() -> FType {
            let left = postfix()
            if k < tokens.count && tokens[k] == "->" {
                k += 1
                return .fn(left, arrow())
            }
            return left
        }
        func postfix() -> FType {
            var t = atom()
            while k < tokens.count && tokens[k] == "list" {
                k += 1
                t = .list(t)
            }
            return t
        }
        func atom() -> FType {
            let w = tokens[k]
            k += 1
            if w == "(" {
                let t = arrow()
                k += 1
                return t
            }
            if w.hasPrefix("'") { return fresh(w) }
            return .con(w, [])
        }
        return arrow()
    }
}
