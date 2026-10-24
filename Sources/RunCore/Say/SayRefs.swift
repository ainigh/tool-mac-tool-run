import Foundation

/// The ways a client refers to something it asked for, without ids: "the last one", a word from
/// it ("the backup"), a time ("the one around 3"), or a number from the last list ("the second
/// one", "2"). And the times it says ("since 9", "since this morning").
enum SayRefs {
    static let ordinals: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10,
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "1st": 1, "2nd": 2, "3rd": 3, "4th": 4, "5th": 5, "6th": 6, "7th": 7, "8th": 8, "9th": 9, "10th": 10,
    ]

    /// A number picked from a list: "2", "#2", "2.", "number 2", "the second one", "the 2nd". Nil
    /// when the words say more than that.
    static func ordinal(_ s: String) -> Int? {
        let all = SayText.words(s)
        let words = all.count > 1 ? all.filter { !["the", "number", "no", "option", "one", "pick", "choose", "that"].contains($0) } : all
        guard words.count == 1, let w = words.first else {
            // "the one" alone isn't a number.
            return nil
        }
        if let n = Int(w), n > 0, n < 100 { return n }
        return ordinals[w]
    }

    /// Words that mean the latest thing asked for.
    static let latest: Set<String> = ["it", "that", "this", "last", "latest", "lastone", "thelastone", "thelatest", "thatone", "thelast", "itsresult", "recent", "mostrecent"]

    /// The entry a phrase means, or nil.
    static func resolve(_ phrase: String, in c: SayLog.Conversation, now: Date = Date()) -> SayLog.Entry? {
        let entries = c.entries
        guard !entries.isEmpty else { return nil }
        let squashed = SayText.squashed(phrase)
        var words = SayText.words(phrase)
        words.removeAll { ["the", "one", "my", "request", "thing", "i", "asked", "for", "about", "of"].contains($0) }
        if words.isEmpty || latest.contains(squashed) || (words.count == 1 && latest.contains(words[0])) { return entries.last }
        // A number from the last list (or, with none, from today's in order).
        if let k = ordinal(phrase) {
            if !c.list.isEmpty { return k <= c.list.count ? entries.first { $0.number == c.list[k - 1] } : nil }
            let today = entries.filter { Calendar.current.isDate($0.asked, inSameDayAs: now) }
            return k <= today.count ? today[k - 1] : nil
        }
        // A time: the nearest asked within two hours of it.
        if let t = time(phrase, now: now), words.allSatisfy({ $0.first?.isNumber == true || ["around", "at", "from", "am", "pm", "oclock"].contains($0) }) {
            let near = entries.min { abs($0.asked.timeIntervalSince(t)) < abs($1.asked.timeIntervalSince(t)) }
            if let n = near, abs(n.asked.timeIntervalSince(t)) <= 7200 { return n }
            return nil
        }
        // Its words: the one sharing most of them (the latest, on a tie).
        let q = Set(APISearch.query(phrase))
        guard !q.isEmpty else { return nil }
        var best: (SayLog.Entry, Int)?
        for e in entries {
            let w = e.words
            let hits = q.filter { word in w.contains(word) || (word.count >= 4 && w.contains { $0.hasPrefix(word) || word.hasPrefix($0) && $0.count >= 4 }) }.count
            if hits > 0, best == nil || hits >= best!.1 { best = (e, hits) }
        }
        return best?.0
    }

    /// A time of day someone says: "3", "3pm", "15:30", "9.30 am", "around 3", "noon"; the latest
    /// such moment not after now (3 is 3 in the afternoon at 4, 3 in the morning at 2). Or a part
    /// of the day: "this morning", "yesterday", "an hour ago".
    static func time(_ s: String, now: Date = Date()) -> Date? {
        let cal = Calendar.current
        let words = SayText.words(s)
        let start = cal.startOfDay(for: now)
        if words.contains("yesterday") { return cal.date(byAdding: .day, value: -1, to: start) }
        if words.contains("morning") || words.contains("today") { return start }
        if words.contains("afternoon") { return cal.date(byAdding: .hour, value: 12, to: start) }
        if words.contains("evening") || words.contains("tonight") { return cal.date(byAdding: .hour, value: 17, to: start) }
        if words.contains("noon") || words.contains("midday") { return cal.date(byAdding: .hour, value: 12, to: start) }
        if words.contains("ago") {
            let n = words.compactMap { Int($0) ?? ordinals[$0] }.first ?? (words.contains("an") || words.contains("a") ? 1 : nil)
            if let n {
                if words.contains(where: { $0.hasPrefix("hour") }) { return now.addingTimeInterval(-Double(n) * 3600) }
                if words.contains(where: { $0.hasPrefix("minute") || $0 == "min" || $0 == "mins" }) { return now.addingTimeInterval(-Double(n) * 60) }
            }
        }
        let lower = s.lowercased()
        guard let re = try? NSRegularExpression(pattern: #"(\d{1,2})(?:[:.h](\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)?"#),
              let m = re.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
              let hr = Range(m.range(at: 1), in: lower), var hour = Int(lower[hr]), hour < 24 else { return nil }
        let minute = Range(m.range(at: 2), in: lower).flatMap { Int(lower[$0]) } ?? 0
        let half = Range(m.range(at: 3), in: lower).map { String(lower[$0]) }
        if let half {
            if half.hasPrefix("p"), hour < 12 { hour += 12 }
            if half.hasPrefix("a"), hour == 12 { hour = 0 }
        }
        guard minute < 60, let at = cal.date(bySettingHour: hour, minute: minute, second: 0, of: now) else { return nil }
        if half == nil, hour <= 12 {
            // No am or pm: the later of the two that isn't after now.
            let later = at.addingTimeInterval(12 * 3600)
            if hour < 12, later <= now.addingTimeInterval(60) { return later }
        }
        return at <= now.addingTimeInterval(60) ? at : at.addingTimeInterval(-24 * 3600)
    }
}
