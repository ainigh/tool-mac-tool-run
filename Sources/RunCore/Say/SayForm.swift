import Foundation

/// One template the adapter offers (`POST /api/say`): a stable title in plain words, and either
/// one sentence with blanks (the inline shape) or a line for each value (the labeled shape).
/// The client copies it, fills the blanks and says it back; the adapter knows its own fixed
/// words, so reading it back is easy, and it calls what the template stands for.
///
///     Search the web                     Remember something
///       search the web for {what}        - category: [PEOPLE | ORGANIZATIONS | …]
///                                        - about: {who or what it's about}
///                                        - date (optional): {a day}
///
/// `{…}` is a blank, `[a | b]` a choice of one, `(optional)` a line that may be left out, and a
/// field of several lines is filled in a fenced block under its label.
public struct SayForm: @unchecked Sendable {
    /// One line of the labeled shape.
    public struct Field: Sendable {
        public let label: String
        /// What goes in the blank, in words (nil: it's a choice).
        public let blank: String?
        /// Choose exactly one of these.
        public let choices: [String]
        public let optional: Bool
        /// It can run to several lines (filled in a fenced block).
        public let multiline: Bool

        public init(_ label: String, _ blank: String? = nil, choices: [String] = [], optional: Bool = false, multiline: Bool = false) {
            self.label = label
            self.blank = blank
            self.choices = choices
            self.optional = optional
            self.multiline = multiline
        }

        /// As the template shows it.
        var shown: String {
            let head = "- \(label)\(optional ? " (optional)" : ""):"
            if !choices.isEmpty { return head + " [" + choices.joined(separator: " | ") + "]" }
            if multiline { return head + "\n```\n{\(blank ?? label)}\n```" }
            return head + " {\(blank ?? label)}"
        }
    }

    /// What it does once it's filled.
    enum Action {
        /// One of the API's tools, its arguments made from the values.
        case tool(String, @Sendable (SayFilled) throws -> [String: Any])
        /// A script or a flow in the folder, its inputs in order (their values, by the blank's place).
        case script(ScriptItem)
        case flow(ScriptItem)
        /// About the conversation itself.
        case builtin(SayBuiltin)
        /// Tags a script or flow to run by itself.
        case automation
    }

    public let title: String
    /// Titles it had before: still taken (a title is a contract client models learn).
    public let formerly: [String]
    /// The inline shape's sentences: the first is offered, any of them is taken.
    public let sentences: [String]
    /// The labeled shape's lines (empty for the inline shape).
    public let fields: [Field]
    /// Words it's found by, beyond its title and wording.
    public let words: String
    /// What it's for, in a line (for a list of everything there is).
    public let about: String
    /// It changes something (a note written, something remembered, a run asked for): an
    /// uncertain match is asked about before it's done. A read is answered at once.
    public let changes: Bool
    /// It waits for the person at the Mac to click Run.
    public let asks: Bool
    /// The titles of the forms that usually come after it.
    public let next: [String]
    let action: Action
    /// Where it comes from: "tool", "script", "flow", "builtin".
    public let kind: String

    init(_ title: String, _ sentence: String? = nil, fields: [Field] = [], also: [String] = [], formerly: [String] = [], words: String = "",
         about: String = "", changes: Bool = false, asks: Bool = false, next: [String] = [], kind: String = "tool", action: Action) {
        self.title = title
        self.sentences = (sentence.map { [$0] } ?? []) + also
        self.fields = fields
        self.formerly = formerly
        self.words = words
        self.about = about
        self.changes = changes
        self.asks = asks
        self.next = next
        self.kind = kind
        self.action = action
        variants = sentences.flatMap(SayForm.variants)
    }

    /// The inline shape.
    public var isInline: Bool { !sentences.isEmpty }

    /// The template, as it's offered: its title, then its sentence (indented) or its lines.
    public var template: String {
        if let s = sentences.first { return title + "\n  " + s }
        if fields.isEmpty { return title }
        return ([title] + fields.map(\.shown)).joined(separator: "\n")
    }

    /// The template in one line where it has one ("search the web for {what to look for}"), else
    /// the whole of it.
    public var short: String { sentences.first ?? template }

    // MARK: the inline shape, as pieces

    enum Piece: Equatable {
        /// Fixed words.
        case words([String])
        /// A blank: what goes in it.
        case blank(String)
    }

    /// One way to say it: its pieces, and the choices it took (`[today | recently]`: "today").
    struct Variant {
        var pieces: [Piece]
        var chose: [String]
    }

    let variants: [Variant]

    /// Every way a sentence can be said: one per option of each choice in it.
    static func variants(_ sentence: String) -> [Variant] {
        // The parts: fixed text, a {blank}, a [choice | of | options].
        enum Part { case text(String), blank(String), choice([String]) }
        var parts: [Part] = []
        var s = Substring(sentence)
        while !s.isEmpty {
            if s.first == "{", let end = s.firstIndex(of: "}") {
                parts.append(.blank(String(s[s.index(after: s.startIndex)..<end])))
                s = s[s.index(after: end)...]
            } else if s.first == "[", let end = closing(s) {
                let inner = s[s.index(after: s.startIndex)..<end]
                parts.append(.choice(splitOptions(inner)))
                s = s[s.index(after: end)...]
            } else {
                let stop = s.firstIndex { $0 == "{" || $0 == "[" } ?? s.endIndex
                let cut = stop == s.startIndex ? s.index(after: stop) : stop
                parts.append(.text(String(s[..<cut])))
                s = s[cut...]
            }
        }
        var out: [Variant] = [Variant(pieces: [], chose: [])]
        func add(_ piece: Piece, to v: inout Variant) {
            if case let .words(w) = piece, case let .words(prev)? = v.pieces.last {
                v.pieces[v.pieces.count - 1] = .words(prev + w)
            } else if case let .words(w) = piece, w.isEmpty {
                return
            } else {
                v.pieces.append(piece)
            }
        }
        for part in parts {
            switch part {
            case let .text(t):
                for k in out.indices { add(.words(SayText.words(t)), to: &out[k]) }
            case let .blank(b):
                for k in out.indices { add(.blank(b), to: &out[k]) }
            case let .choice(options):
                var grown: [Variant] = []
                for v in out {
                    for o in options {
                        for sub in variants(o) {
                            var x = v
                            for p in sub.pieces { add(p, to: &x) }
                            x.chose += [o] + sub.chose
                            grown.append(x)
                        }
                    }
                }
                out = grown
            }
        }
        return out
    }

    /// Where the `]` that closes the `[` at the start is.
    static func closing(_ s: Substring) -> Substring.Index? {
        var depth = 0
        for i in s.indices {
            if s[i] == "[" { depth += 1 }
            if s[i] == "]" { depth -= 1; if depth == 0 { return i } }
        }
        return nil
    }

    /// "today | recently | since {a time}" → its options.
    static func splitOptions(_ s: Substring) -> [String] {
        s.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// The values a filled template gave: by label (or a blank's words), and in order.
public struct SayFilled: Sendable {
    /// Each value, under its label (labeled) or its blank's words (inline).
    public var values: [String: String] = [:]
    /// The values in the order of the template's blanks or lines.
    public var ordered: [String] = []
    /// The choices an inline sentence took.
    public var chose: [String] = []
    /// What was corrected on the way ("taken as PEOPLE").
    public var corrections: [String] = []

    public subscript(_ key: String) -> String? {
        if let v = values[key], !v.isEmpty { return v }
        return nil
    }

    func at(_ k: Int) -> String? { k < ordered.count && !ordered[k].isEmpty ? ordered[k] : nil }
}

/// The forms about the conversation itself, always there.
public enum SayBuiltin: String, Sendable, CaseIterable {
    case whatCanYouDo, whatHappened, whatHaveIAsked, showMe, more, stop, done, yes, no, startOver, pick
}
