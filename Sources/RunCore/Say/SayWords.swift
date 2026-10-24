import Foundation

/// The API's answers in a few plain sentences: what the template adapter says back. Never
/// JSON, routes, file names or ids. Lists are numbered (so a client can say "the second one"),
/// and a long answer is cut down by fixed rules: its first lines, then "say more".
enum SayWords {
    /// How much of an answer goes in one reply.
    static let pageLines = 20
    static let pageChars = 1500

    /// An answer cut into pages: the first, and the rest (for "more").
    static func pages(_ text: String) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out: [String] = []
        var page: [String] = []
        var chars = 0
        for line in lines {
            // A line longer than a page is cut where it fits (at a space if there's one near).
            var rest = Substring(line)
            while rest.count > pageChars {
                if !page.isEmpty { out.append(page.joined(separator: "\n")); page = []; chars = 0 }
                var cut = rest.index(rest.startIndex, offsetBy: pageChars)
                if let space = rest[..<cut].lastIndex(of: " "), rest.distance(from: rest.startIndex, to: space) > pageChars / 2 { cut = space }
                out.append(String(rest[..<cut]))
                rest = rest[cut...].drop { $0 == " " }
            }
            if page.count >= pageLines || chars + rest.count > pageChars {
                out.append(page.joined(separator: "\n"))
                page = []
                chars = 0
            }
            page.append(String(rest))
            chars += rest.count + 1
        }
        if !page.isEmpty { out.append(page.joined(separator: "\n")) }
        // No page of blank lines alone.
        return out.map { $0.trimmingCharacters(in: .newlines) }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// What follows a page when there's more.
    static func moreLine(_ rest: [String]) -> String {
        let lines = rest.reduce(0) { $0 + $1.split(separator: "\n").count }
        return "(\(lines) more line\(lines == 1 ? "" : "s"): say \"more\" for the rest.)"
    }

    /// A list, numbered.
    static func numbered(_ items: [String]) -> String {
        items.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }

    /// A message from the API without what's only for programs: routes, JSON bits, field names.
    static func plain(_ message: String) -> String {
        var m = message
        // "(GET /api/scripts lists them)", "(POST /api/run …)": a route in brackets goes.
        m = m.replacingOccurrences(of: #"\s*\([^()]*(/api/|\{\")[^()]*\)"#, with: "", options: .regularExpression)
        // A route or a JSON fragment left in the sentence.
        m = m.replacingOccurrences(of: #"(GET|POST|PUT|DELETE)\s+/api/\S*"#, with: "the API", options: .regularExpression)
        m = m.replacingOccurrences(of: #"\{\"[^}]*\}"#, with: "", options: .regularExpression)
        m = m.replacingOccurrences(of: #"\s+:"#, with: ":", options: .regularExpression)
        m = m.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        m = m.trimmingCharacters(in: CharacterSet(charactersIn: " :;,"))
        guard let first = m.first else { return message }
        let s = String(first).uppercased() + m.dropFirst()
        return s.hasSuffix(".") || s.hasSuffix("!") || s.hasSuffix("?") ? s : s + "."
    }

    /// A line of the mind's notation as words: "| ada - works at | acme" is "ada works at acme".
    static func notation(_ line: String) -> String {
        var l = line.trimmingCharacters(in: .whitespaces)
        var prefix = ""
        // "PEOPLE, line 8: | PEOPLE | ada": where it is, then the line.
        if let r = l.range(of: ": |"), !l.hasPrefix("|") {
            prefix = String(l[..<r.lowerBound]) + ": "
            l = "|" + l[r.upperBound...]
        }
        guard l.hasPrefix("|") else { return prefix + l }
        let parts = l.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if parts.count == 1 {
            let p = parts[0]
            if let at = p.firstIndex(of: "@") {
                let who = p[..<at].trimmingCharacters(in: .whitespaces)
                return prefix + "\(who): \(p[p.index(after: at)...])"
            }
            return prefix + p
        }
        if parts.count >= 2 {
            let head = parts[0]
            if let dash = head.range(of: " - ") {
                return prefix + "\(head[..<dash.lowerBound]) \(head[dash.upperBound...]) \(parts[1])"
            }
            var tail = parts[1]
            // "ada lovelace @birthday 03-14": the thing, and its note in brackets.
            if let at = tail.firstIndex(of: "@") { tail = tail[..<at].trimmingCharacters(in: .whitespaces) + " (\(tail[tail.index(after: at)...]))" }
            if head == head.uppercased(), head.contains(where: \.isLetter) { return prefix + "\(tail) is filed under \(head)" }
            return prefix + "\(head) is linked to \(tail)"
        }
        return prefix + l
    }

    /// A dated thing without its date said twice: "lagos trip: date 2026-10-25 Lagos trip" is
    /// "lagos trip", "ada: birthday 03-14" is "ada's birthday".
    static func dated(_ what: String) -> String {
        var w = notation(what)
        guard let colon = w.range(of: ": ") else { return w }
        let who = String(w[..<colon.lowerBound])
        var rest = String(w[colon.upperBound...])
        let birthday = rest.lowercased().hasPrefix("birthday")
        rest = rest.replacingOccurrences(of: #"^(date|birthday)\s+(\d{4}-)?\d{2}-\d{2}\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
        if birthday, rest.isEmpty { return "\(who)'s birthday" }
        w = rest.isEmpty || rest.lowercased() == who.lowercased() ? who : "\(who): \(rest)"
        return w
    }

    /// Strings from a list in the JSON.
    static func strings(_ v: Any?) -> [String] { (v as? [Any])?.compactMap { RunAPI.text($0) } ?? [] }

    /// A JSON value as lines of words: "base: EUR", "rates: JPY: 163.2".
    static func flatten(_ v: Any, indent: String = "") -> [String] {
        switch v {
        case let d as [String: Any]:
            return d.keys.sorted().flatMap { k -> [String] in
                let x = d[k]!
                if let s = RunAPI.text(x) { return ["\(indent)\(k): \(s)"] }
                return ["\(indent)\(k):"] + flatten(x, indent: indent + "  ")
            }
        case let l as [Any]:
            return l.enumerated().flatMap { k, x -> [String] in
                if let s = RunAPI.text(x) { return ["\(indent)\(k + 1). \(s)"] }
                return ["\(indent)\(k + 1)."] + flatten(x, indent: indent + "  ")
            }
        default:
            return [indent + (RunAPI.text(v) ?? "\(v)")]
        }
    }

    /// The answer to a tool's call, in words: what was done or found (and, for a list, its
    /// items, to refer to by number).
    static func answer(tool: String, args: [String: Any], status: Int, json j: [String: Any]) -> String {
        if status >= 400 || j["ok"] as? Bool == false {
            return failure(j)
        }
        let op = (args["op"] as? String) ?? (j["op"] as? String) ?? ""
        let lines = strings(j["lines"])
        switch tool {
        case "web_search":
            let q = j["q"] as? String ?? (args["q"] as? String ?? "")
            let results = j["results"] as? [[String: Any]] ?? []
            if results.isEmpty { return "Nothing came up on the web for \"\(q)\"." }
            let items = results.map { r -> String in
                let snippet = (r["snippet"] as? String).flatMap { $0.isEmpty ? nil : "\n   " + $0 } ?? ""
                return "\(r["title"] as? String ?? "")\n   \(r["url"] as? String ?? "")\(snippet)"
            }
            return "The web has these for \"\(q)\":\n" + numbered(items)
        case "web_fetch":
            return page(j, find: j["find"] as? String, lines: lines)
        case "browser":
            switch op {
            case "open": return "Opened in Chrome. " + page(j, find: nil, lines: [])
            case "page": return page(j, find: nil, lines: [])
            case "tabs":
                return lines.isEmpty ? "No tabs are open in Chrome's window in front." : "The tabs:\n" + numbered(lines.map { $0.replacingOccurrences(of: #"^\d+\.\s*"#, with: "", options: .regularExpression) })
            case "highlight":
                return (j["said"] as? String) ?? "It's ringed in red on the page."
            default:
                if let said = j["said"] as? String { return said }
                if !lines.isEmpty { return lines.joined(separator: "\n") }
                return generic(j)
            }
        case "remember":
            let file = j["file"] as? String ?? (args["category"] as? String ?? "")
            return "Remembered under \(file): \(args["about"] as? String ?? (j["node"] as? String ?? ""))."
        case "recall":
            let name = args["name"] as? String ?? (j["name"] as? String ?? "")
            if j["found"] as? Bool == false || lines.isEmpty { return "Nothing is remembered about \(name) yet." }
            return "What's known about \(name):\n" + lines.map { "- " + notation($0) }.joined(separator: "\n")
        case "memory":
            switch op {
            case "upcoming":
                let days = j["days"] as? Int ?? 30
                if lines.isEmpty { return "Nothing is coming up in the next \(days) day\(days == 1 ? "" : "s")." }
                let items = (j["upcoming"] as? [[String: Any]] ?? []).map { u -> String in
                    let inDays = u["in_days"] as? Int ?? 0
                    let when = inDays == 0 ? "today" : inDays == 1 ? "tomorrow" : "in \(inDays) days"
                    return "\(u["day"] as? String ?? ""), \(when): \(dated(u["what"] as? String ?? ""))"
                }
                return "Coming up in the next \(days) days:\n" + numbered(items.isEmpty ? lines : items)
            case "members":
                let members = strings(j["members"])
                let name = j["name"] as? String ?? ""
                return members.isEmpty ? "Nothing is filed under \(name) yet." : "Filed under \(name):\n" + numbered(members)
            default: return generic(j)
            }
        case "mind":
            switch op {
            case "add", "note": return "Added to the mind: " + lines.map(notation).joined(separator: "; ") + "."
            case "path":
                if j["found"] as? Bool == false { return "The mind has no way from \(args["from"] ?? "") to \(args["to"] ?? "")." }
                return "How they connect:\n" + lines.map { "- " + notation($0) }.joined(separator: "\n")
            default:
                if !lines.isEmpty { return lines.map { "- " + notation($0) }.joined(separator: "\n") }
                return generic(j)
            }
        case "library":
            let name = j["name"] as? String ?? (args["name"] as? String ?? "")
            switch op {
            case "read":
                let text = j["text"] as? String ?? ""
                return text.isEmpty ? "The note \(name) is empty." : "The note \(name):\n\(text)"
            case "write", "create": return j["new"] as? Bool == true ? "Wrote a new note, \(name)." : "Wrote the note \(name) (what was in it before was replaced)."
            case "append": return j["new"] as? Bool == true ? "Started a new note, \(name), with that." : "Added that to the end of the note \(name)."
            case "find":
                let names = strings(j["names"])
                return names.isEmpty ? "No note matches \"\(j["query"] as? String ?? "")\"." : "The notes that match, the best first:\n" + numbered(names)
            case "search":
                let results = j["results"] as? [[String: Any]] ?? []
                if results.isEmpty { return "No note has \"\(j["query"] as? String ?? "")\" in it." }
                let items = results.map { r -> String in
                    let found = (r["lines"] as? [[String: Any]] ?? []).prefix(3).map { "   line \($0["line"] ?? ""): \($0["text"] as? String ?? "")" }
                    return ([r["name"] as? String ?? ""] + found).joined(separator: "\n")
                }
                return "The notes with \"\(j["query"] as? String ?? "")\" in them:\n" + numbered(items)
            case "list", "recent":
                let notes = (j["notes"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
                return notes.isEmpty ? "There are no notes yet." : "The notes, the latest changed first:\n" + numbered(notes)
            case "rename": return "The note \(j["from"] as? String ?? (args["name"] as? String ?? "")) is called \(name) now."
            case "delete": return "Moved the note \(name) to the library's Trash. Say \"bring back the note \(name)\" to undo it."
            case "restore": return "The note \(name) is back."
            default: return generic(j)
            }
        case "show": return "It's on the Mac's screen now, in a window in front of everything."
        case "copy": return "Copied: it's on the clipboard, ready to paste."
        case "docs":
            switch op {
            case "list", "names": return "The guides:\n" + numbered(strings(j["names"]))
            case "read":
                if let text = j["text"] as? String { return text }
                return generic(j)
            default:
                if !lines.isEmpty { return lines.joined(separator: "\n") }
                return generic(j)
            }
        case "runs":
            let runs = j["runs"] as? [[String: Any]] ?? []
            if runs.isEmpty { return "Nothing has run lately." }
            return "The latest runs, newest first:\n" + numbered(runs.prefix(10).map { r in
                "\(spokenName(r["name"] as? String ?? "")): \(state(r["state"] as? String ?? ""))\(time(r["started"] as? String).map { ", at \($0)" } ?? "")"
            })
        case "check_flow":
            let bindings = (j["bindings"] as? [[String: Any]] ?? []).compactMap { b in (b["name"] as? String).map { "\($0) (\(b["type"] as? String ?? ""))" } }
            return "No mistakes" + (bindings.isEmpty ? "." : ": it defines " + bindings.joined(separator: ", ") + ".")
        default:
            return generic(j)
        }
    }

    /// A page read (from the web or Chrome): its title, then the lines asked for, or its text.
    static func page(_ j: [String: Any], find: String?, lines: [String]) -> String {
        var out: [String] = []
        if let title = j["title"] as? String, !title.isEmpty { out.append(title) }
        if j["kind"] as? String == "json", let json = j["json"] {
            out.append(contentsOf: flatten(json))
            return out.joined(separator: "\n")
        }
        if let find, !find.isEmpty {
            out.append(lines.isEmpty ? "Nothing on it has \"\(find)\"." : "The lines with \"\(find)\":\n" + lines.map { "- " + $0 }.joined(separator: "\n"))
        } else if let text = j["text"] as? String {
            out.append(text)
        }
        return out.joined(separator: "\n")
    }

    /// A refusal or a failure: its sentence, and its fix.
    static func failure(_ j: [String: Any]) -> String {
        var out = plain(j["error"] as? String ?? j["message"] as? String ?? "That didn't work.")
        if let fix = j["fix"] as? String, !fix.isEmpty { out += " " + plain(fix) }
        return out
    }

    /// Anything else: its words ("said", "message", "lines"), else its plain values.
    static func generic(_ j: [String: Any]) -> String {
        if let said = j["said"] as? String { return said }
        let lines = strings(j["lines"])
        if !lines.isEmpty { return lines.map(notation).joined(separator: "\n") }
        if let m = j["message"] as? String { return plain(m) }
        if let t = j["text"] as? String { return t }
        let skip: Set<String> = ["ok", "next", "request", "tool", "op", "url", "id", "run_id", "run_url", "file", "folder", "takes", "tools", "created", "modified", "scope", "written", "delivery", "note"]
        let kept = j.filter { !skip.contains($0.key) && RunAPI.text($0.value) != nil }
        if kept.isEmpty { return "Done." }
        return kept.keys.sorted().map { "\($0.replacingOccurrences(of: "_", with: " ")): \(RunAPI.text(kept[$0]!) ?? "")" }.joined(separator: "\n")
    }

    // MARK: runs and requests

    /// "utilities/nightly-backup.sh" → "nightly backup".
    static func spokenName(_ id: String) -> String {
        SayForms.spoken(((id as NSString).lastPathComponent as NSString).deletingPathExtension)
    }

    /// A run's state, as said.
    static func state(_ s: String) -> String {
        switch s {
        case "running": return "running"
        case "succeeded": return "worked"
        case "failed": return "failed"
        case "stopped": return "stopped"
        case "could_not_start": return "couldn't start"
        default: return s.replacingOccurrences(of: "_", with: " ")
        }
    }

    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "H:mm"
        return f
    }()

    /// "9:12", from a date as the API writes it.
    static func time(_ s: String?) -> String? {
        guard let s, let d = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(s) else { return nil }
        return clock.string(from: d)
    }

    static func time(_ d: Date) -> String { clock.string(from: d) }
}
