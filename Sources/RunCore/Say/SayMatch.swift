import Foundation

/// Reading back what a client said against the templates: an inline sentence by its fixed
/// words (forgiving about them), a labeled form by its title and labels (forgiving about those,
/// and about the choices), and the values always exactly as written.
enum SayMatch {
    /// How sure a match must be to count at all, and to be acted on without asking.
    static let floor = 0.72
    static let clean = 0.9

    /// What a text came to against one form.
    enum Outcome {
        /// Filled: its values, and how close its fixed words (or title) were.
        case filled(SayFilled, score: Double)
        /// The title alone, or some lines but not the ones it needs.
        case incomplete(SayFilled, missing: [SayForm.Field], score: Double)
        /// A choice that isn't one of its options.
        case badChoice(SayForm.Field, given: String, score: Double)
        /// A line it has no label for.
        case unknownLabel(String, score: Double)

        var score: Double {
            switch self {
            case let .filled(_, s), let .incomplete(_, _, s), let .badChoice(_, _, s), let .unknownLabel(_, s): s
            }
        }
    }

    // MARK: the inline shape

    /// The best way the text fills one of the form's sentences, or nil.
    static func inline(_ text: String, _ form: SayForm) -> (SayFilled, Double)? {
        inlineWeighed(text, form).map { ($0.0, $0.1) }
    }

    /// The same, with how many fixed words it matched: of two as close, the one that matched
    /// more of its own words is the more particular ("read the note {…}" over "read {…}").
    static func inlineWeighed(_ text: String, _ form: SayForm) -> (SayFilled, Double, Int)? {
        let toks = SayText.tokens(text)
        var best: (SayFilled, Double, Int)?
        for v in form.variants {
            guard let m = match(v, toks, in: text) else { continue }
            let fixed = v.pieces.reduce(0) { n, p in if case let .words(w) = p { return n + w.count }; return n }
            if best == nil || m.1 > best!.1 + 0.001 || (abs(m.1 - best!.1) <= 0.001 && fixed > best!.2) { best = (m.0, m.1, fixed) }
        }
        return best
    }

    /// The text against one way of saying it: each fixed run of words where it best fits (the
    /// first at the start, each after a blank where it first fits well, the last at the end),
    /// and each blank everything between, the last one the rest of the text.
    static func match(_ v: SayForm.Variant, _ toks: [SayText.Token], in text: String) -> (SayFilled, Double)? {
        var pos = 0
        var blank: String?
        var total = 0.0, weight = 0.0
        var filled = SayFilled()
        filled.chose = v.chose
        // A blank starts right after the fixed word before it (a quote before its value is the value's).
        func from(_ k: Int) -> String.Index { k > 0 ? toks[k - 1].range.upperBound : text.startIndex }
        func put(_ label: String, _ value: String) {
            filled.values[label] = value
            filled.ordered.append(value)
        }
        for (k, piece) in v.pieces.enumerated() {
            let last = k == v.pieces.count - 1
            switch piece {
            case let .blank(b):
                blank = b
            case let .words(w):
                let n = w.count
                var best: (i: Int, m: Int, s: Double)?
                // A blank before takes at least one word.
                let starts: [Int] = blank == nil ? [pos] : (pos + 1 <= toks.count ? Array((pos + 1)...toks.count) : [])
                search: for i in starts {
                    let lengths: [Int] = last ? [toks.count - i] : Array(max(1, n - 1)...(n + 1))
                    for m in lengths where m >= 0 && i + m <= toks.count {
                        let s = SayText.closeness(w, toks[i..<(i + m)].map(\.norm))
                        if best == nil || s > best!.s { best = (i, m, s) }
                    }
                    if blank != nil, let b = best, b.s >= clean { break search }
                }
                guard let b = best, b.s >= 0.5 else { return nil }
                if let label = blank {
                    guard b.i > pos, b.i <= toks.count else { return nil }
                    let end = b.i < toks.count ? toks[b.i].range.lowerBound : text.endIndex
                    let value = SayText.value(text[from(pos)..<end])
                    guard !value.isEmpty else { return nil }
                    put(label, value)
                    blank = nil
                }
                total += b.s * Double(n)
                weight += Double(n)
                pos = b.i + b.m
            }
        }
        if let label = blank {
            guard pos < toks.count else { return nil }
            let value = SayText.value(Substring(SayText.endOfSentence(String(text[from(pos)...]))))
            guard !value.isEmpty else { return nil }
            put(label, value)
        }
        guard weight > 0 else { return nil }
        return (filled, total / weight)
    }

    // MARK: the labeled shape

    /// A text as lines: its title (a first line that isn't a label's), and each `- label: value`
    /// line, a value of several lines in a fenced block (or the lines under its label).
    struct Lines {
        var title: String?
        /// Each line as written: its label and value, or (nil label) a line that's neither.
        var lines: [(label: String?, value: String, raw: String)]

        var labels: [String] { lines.compactMap(\.label) }
    }

    /// A line that's a label and its value: "- fact: rain likely", "fact: rain likely".
    static func labelLine(_ raw: String) -> (label: String, value: String, dashed: Bool)? {
        var line = Substring(raw.trimmingCharacters(in: .whitespaces))
        var dashed = false
        if let f = line.first, "-*•".contains(f) {
            line = line.dropFirst().drop { $0 == " " }
            dashed = true
        }
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let label = line[..<colon].trimmingCharacters(in: .whitespaces)
        // A label is a few words, not a sentence (and not an address's "https").
        guard !label.isEmpty, label.count <= 48, label.split(separator: " ").count <= 7, !label.contains("{"),
              label.lowercased() != "https", label.lowercased() != "http" else { return nil }
        let rest = line[line.index(after: colon)...]
        if !dashed, !(rest.isEmpty || rest.first == " ") { return nil }
        return (label, rest.trimmingCharacters(in: .whitespaces), dashed)
    }

    /// The text's lines, or nil when it isn't the labeled shape (no line is a label's).
    static func lines(_ text: String) -> Lines? {
        let raw = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out = Lines(title: nil, lines: [])
        var fence: [String]?
        var any = false
        for (k, line) in raw.enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if var f = fence {
                if t.hasPrefix("```") {
                    // The fence closes: its lines are the value of the line above it.
                    let value = f.joined(separator: "\n")
                    if let last = out.lines.indices.last, out.lines[last].label != nil, out.lines[last].value.isEmpty {
                        out.lines[last].value = value
                    } else {
                        out.lines.append((nil, value, value))
                    }
                    fence = nil
                } else {
                    f.append(line)
                    fence = f
                }
                continue
            }
            if t.hasPrefix("```") { fence = []; continue }
            if out.title == nil, out.lines.isEmpty {
                if t.isEmpty { continue }
                if let l = labelLine(line), l.dashed || k > 0 {
                    out.lines.append((l.label, l.value, line))
                    any = true
                } else {
                    out.title = t.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                }
                continue
            }
            if let l = labelLine(line) {
                out.lines.append((l.label, l.value, line))
                any = any || l.dashed || out.title != nil
            } else if !t.isEmpty || !out.lines.isEmpty {
                out.lines.append((nil, line, line))
            }
        }
        // A fence never closed: what's in it is still the value.
        if let f = fence {
            let value = f.joined(separator: "\n")
            if let last = out.lines.indices.last, out.lines[last].label != nil, out.lines[last].value.isEmpty { out.lines[last].value = value }
            else { out.lines.append((nil, value, value)) }
        }
        return any ? out : nil
    }

    /// How close a title (or a label) is to what was said: the closer of its words in either direction.
    static func near(_ fixed: String, _ said: String) -> Double {
        let a = SayText.words(fixed), b = SayText.words(said)
        if SayText.squashed(fixed) == SayText.squashed(said) { return 1 }
        return min(SayText.closeness(a, b), SayText.closeness(b, a) + 0.05)
    }

    /// The title's closeness to one of the form's titles (its own, or one it had).
    static func titleScore(_ said: String, _ form: SayForm) -> Double {
        ([form.title] + form.formerly).map { near($0, said) }.max() ?? 0
    }

    /// The field a label means, and how close it was.
    static func field(_ label: String, in form: SayForm) -> (SayForm.Field, Double)? {
        let clean = label.replacingOccurrences(of: "(optional)", with: "").trimmingCharacters(in: .whitespaces)
        var best: (SayForm.Field, Double)?
        for f in form.fields {
            var s = near(f.label, clean)
            let a = SayText.squashed(f.label), b = SayText.squashed(clean)
            if b.count >= 3, a.hasPrefix(b) || b.hasPrefix(a) { s = max(s, 0.85) }
            if best == nil || s > best!.1 { best = (f, s) }
        }
        guard let b = best, b.1 >= 0.7 else { return nil }
        return b
    }

    /// The option a choice means, and how close it was (a word it begins counts, and case,
    /// spaces and dashes never do).
    static func choose(_ value: String, _ options: [String]) -> (String, Double)? {
        let v = SayText.squashed(value)
        guard !v.isEmpty else { return nil }
        var best: (String, Double)?
        for o in options {
            let w = SayText.squashed(o)
            var s = w == v ? 1 : SayText.similarity(w, v)
            if v.count >= 3, w.hasPrefix(v) { s = max(s, 0.85) }
            if best == nil || s > best!.1 { best = (o, s) }
        }
        guard let b = best, b.1 >= 0.6 else { return nil }
        return b
    }

    /// The lines against one labeled form: its values, what's missing, or what's wrong.
    static func labeled(_ l: Lines, _ form: SayForm, titleScore: Double) -> Outcome {
        var filled = SayFilled()
        var current: SayForm.Field?
        var worst = 1.0
        for line in l.lines {
            if let label = line.label, let (f, s) = field(label, in: form) {
                // A field given twice: the second carries on the first (a list of lines).
                if let old = filled.values[f.label], !old.isEmpty, f.multiline {
                    filled.values[f.label] = old + "\n" + line.value
                } else {
                    filled.values[f.label] = SayText.value(Substring(line.value))
                }
                worst = min(worst, s)
                current = f
            } else if let c = current, c.multiline || line.label == nil {
                // A line under a value that runs to several: more of it.
                let old = filled.values[c.label] ?? ""
                filled.values[c.label] = old.isEmpty ? line.raw : old + "\n" + line.raw
            } else if let label = line.label {
                return .unknownLabel(label, score: titleScore)
            }
        }
        for f in form.fields where !f.choices.isEmpty {
            guard let given = filled.values[f.label], !given.isEmpty else { continue }
            guard let (o, s) = choose(given, f.choices) else { return .badChoice(f, given: given, score: titleScore) }
            if SayText.squashed(o) != SayText.squashed(given) { filled.corrections.append("taken as \(o)") }
            filled.values[f.label] = o
            worst = min(worst, s)
        }
        filled.ordered = form.fields.map { filled.values[$0.label] ?? "" }
        let missing = form.fields.filter { !$0.optional && (filled.values[$0.label] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let score = min(titleScore, worst)
        return missing.isEmpty ? .filled(filled, score: score) : .incomplete(filled, missing: missing, score: score)
    }

    /// Which form some lines with no title are for: the one all of their labels belong to.
    static func formByLabels(_ l: Lines, _ forms: [SayForm]) -> (SayForm, Double)? {
        let labels = l.labels
        guard !labels.isEmpty else { return nil }
        var best: (SayForm, Double, Int)?
        for f in forms where !f.fields.isEmpty {
            let hits = labels.compactMap { field($0, in: f)?.1 }
            guard hits.count == labels.count else { continue }
            let s = hits.reduce(0, +) / Double(hits.count)
            // The more of its lines given, the likelier it's the one.
            let covered = Set(labels.compactMap { field($0, in: f)?.0.label }).count
            if best == nil || covered > best!.2 || (covered == best!.2 && s > best!.1) { best = (f, s, covered) }
        }
        return best.map { ($0.0, min($0.1, 0.85)) }
    }
}
