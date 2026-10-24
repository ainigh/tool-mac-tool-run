import Foundation

/// The words of what a client says, as the template adapter compares them with its own: each
/// word lowercased, accents and apostrophes aside ("What's" is whats), with where it is in the
/// text, so a value can be cut out exactly as it was written. And how close two words, or two
/// runs of words, are: the adapter is forgiving about its own fixed words, never about values.
enum SayText {
    struct Token {
        let norm: String
        let range: Range<String.Index>
    }

    /// The words of a text, in order, with where each is.
    static func tokens(_ text: String) -> [Token] {
        var out: [Token] = []
        var start: String.Index?
        var i = text.startIndex
        func close(_ end: String.Index) {
            guard let s = start else { return }
            let n = norm(String(text[s..<end]))
            if !n.isEmpty { out.append(Token(norm: n, range: s..<end)) }
            start = nil
        }
        while i < text.endIndex {
            let c = text[i]
            let inWord = c.isLetter || c.isNumber || ((c == "'" || c == "’") && start != nil)
            if inWord {
                if start == nil { start = i }
            } else {
                close(i)
            }
            i = text.index(after: i)
        }
        close(text.endIndex)
        return out
    }

    /// A word as it's compared: lowercased, no accents, no apostrophes.
    static func norm(_ word: String) -> String {
        word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    /// The words alone.
    static func words(_ text: String) -> [String] { tokens(text).map(\.norm) }

    /// A text without anything but its letters and digits: how a choice is compared
    /// ("event dates" and "EVENT-DATES" are the same).
    static func squashed(_ text: String) -> String { norm(text) }

    /// How many single-character changes turn one into the other, two letters swapped ("raed")
    /// counting as one.
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var d = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1) }
            }
        }
        return d[a.count][b.count]
    }

    /// 1 for the same word, less the more it takes to change one into the other; a number is
    /// only ever itself.
    static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        if a.isEmpty || b.isEmpty { return 0 }
        if a.allSatisfy(\.isNumber) || b.allSatisfy(\.isNumber) { return 0 }
        return 1 - Double(distance(a, b)) / Double(max(a.count, b.count))
    }

    /// Small words a client leaves out or adds without changing what it means: cheaper to miss.
    static let fillers: Set<String> = ["the", "a", "an", "my", "me", "please", "some", "this", "that", "your", "now", "just", "can", "you", "i"]

    /// How close a run of words is to a template's fixed words, 0 to 1: a word for a word, a
    /// misspelt word for a little, one missing or extra for one (a small word for half).
    static func closeness(_ fixed: [String], _ said: [String]) -> Double {
        guard !fixed.isEmpty else { return said.isEmpty ? 1 : 0 }
        let n = fixed.count, m = said.count
        func skip(_ w: String) -> Double { fillers.contains(w) ? 0.5 : 1 }
        var d = [[Double]](repeating: [Double](repeating: 0, count: m + 1), count: n + 1)
        for i in 1...n { d[i][0] = d[i - 1][0] + skip(fixed[i - 1]) }
        if m > 0 { for j in 1...m { d[0][j] = d[0][j - 1] + skip(said[j - 1]) } }
        if m > 0 {
            for i in 1...n {
                for j in 1...m {
                    let s = similarity(fixed[i - 1], said[j - 1])
                    let change = s >= 0.7 ? (1 - s) : 1
                    d[i][j] = min(d[i - 1][j] + skip(fixed[i - 1]), d[i][j - 1] + skip(said[j - 1]), d[i - 1][j - 1] + change)
                }
            }
        }
        return max(0, 1 - d[n][m] / Double(max(n, 1)))
    }

    /// A value as the client wrote it, trimmed, without quotes around it.
    static func value(_ s: Substring) -> String {
        var v = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for (open, close) in [("\"", "\""), ("“", "”"), ("'", "'"), ("‘", "’"), ("`", "`")] where v.count >= 2 && v.hasPrefix(open) && v.hasSuffix(close) {
            v = String(v.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            break
        }
        return v
    }

    /// The end of a sentence ("Lagos?") isn't part of the value at its end.
    static func endOfSentence(_ v: String) -> String {
        var v = v
        while let last = v.last, ".?!".contains(last) { v.removeLast() }
        return v.trimmingCharacters(in: .whitespaces)
    }
}
