import Foundation

/// The page in front of Chrome, for an app guiding the person through a site (`/api/browser…`):
/// what's open, what it says, whether some words are on it, where a thing is, and a red ring to
/// show them. It only reads (and rings); it never clicks, types or opens a page.
extension RunAPI {
    static let browserRoutes: [(method: String, path: String, summary: String)] = [
        ("GET", "/api/browser", "whether Chrome is open and what's in front (and whether apps may read inside its pages)"),
        ("GET", "/api/browser/url", "the tab in front: its title and address (needs nothing switched on in Chrome)"),
        ("GET", "/api/browser/tabs", "every tab of the front window (?all=true: every window), the one in front marked"),
        ("GET", "/api/browser/page", "the page in front: title, address, its text (?max=20000 characters), what's selected, how far down it is (?outline=true: its outline too)"),
        ("GET", "/api/browser/has", "whether words are on the page: ?text=Compute (?case_sensitive, ?whole_words): true or false, how many times, the lines"),
        ("GET", "/api/browser/find", "where a thing is: ?text=Compute — each match's kind (link, button…), whether it's in view, above, below, or in a closed menu, and what it's in"),
        ("POST", "/api/browser/highlight", "shows the person where: {\"text\": \"Compute\", \"seconds\"?: 4} scrolls to it and rings it in red (or the closed menu it's in)"),
        ("GET", "/api/browser/outline", "the page's outline: headings, landmarks, navigation, buttons, fields, links"),
    ]

    func browserRoute(_ req: HTTPRequest, path: String, _ s: APISettings) async throws -> HTTPResponse {
        guard s.isOn(.browser) else {
            throw HTTPError(status: 503, code: "endpoint_off", message: "\(APIEndpoint.browser.title.lowercased()) is turned off in Tool Mac Tool Run")
        }
        let rest = Array(path.split(separator: "/").map(String.init).dropFirst(2))
        let method = req.method == "HEAD" ? "GET" : req.method
        let fields = try self.fields(req)
        let f = LibraryAPI.Fields(values: fields)
        let chrome = self.chrome
        let op: String
        switch (method, rest.first, rest.count) {
        case ("GET", nil, _): op = "status"
        case ("GET", "url", 1), ("GET", "front", 1): op = "url"
        case ("GET", "tabs", 1): op = "tabs"
        case ("GET", "page", 1), ("GET", "text", 1): op = "page"
        case ("GET", "has", 1), ("POST", "has", 1): op = "has"
        case ("GET", "find", 1), ("POST", "find", 1), ("GET", "where", 1): op = "find"
        case ("POST", "highlight", 1), ("POST", "show", 1): op = "highlight"
        case ("GET", "outline", 1): op = "outline"
        case ("GET", "operations", 1):
            let limit = min(500, max(1, Int(req.query["limit"] ?? "") ?? 20))
            return JSON.response(["operations": await libraryLog.recent(500).filter { $0.kind == "browser" }.prefix(limit).map(LibraryLog.json)])
        case (_, let first?, 1) where ["url", "tabs", "page", "has", "find", "highlight", "outline"].contains(first):
            throw HTTPError(status: 405, code: "bad_request", message: "\(path) takes \(first == "highlight" ? "POST" : "GET")")
        default:
            throw HTTPError(status: 404, code: "not_found", message: "no such route: \(req.method) \(req.path) (GET /api/browser lists Chrome's routes)")
        }
        return await logged("browser", op, f, req) {
            func text() throws -> String {
                guard let t = f.text("text") ?? f.text("q") ?? f.text("name"), !t.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw HTTPError(status: 400, code: "bad_request", message: "say what to look for: \"text\" (?text=Compute)")
                }
                return t
            }
            switch op {
            case "status":
                var out: [String: Any] = ["routes": Self.browserRoutes.map { ["method": $0.method, "path": $0.path, "summary": $0.summary] },
                                          "reads_only": "it never clicks, types or opens pages (Straw does that, asking first: /api/straw)"]
                do {
                    let t = try await Self.offThread { try chrome.front() }
                    out["chrome"] = "open"
                    out["front"] = ["title": t.title, "url": t.url, "loading": t.loading]
                    do {
                        _ = try await Self.offThread { try chrome.js("return {ok: true}") }
                        out["javascript"] = true
                    } catch let e as ChromeError {
                        out["javascript"] = false
                        out["javascript_fix"] = e.fix ?? e.message
                    }
                } catch let e as ChromeError {
                    out["chrome"] = e.code.rawValue
                    out["said"] = e.message
                    if let fix = e.fix { out["fix"] = fix }
                }
                return .json(out, summary: "Chrome: \(out["chrome"] ?? "")")
            case "url":
                let t = try await Self.offThread { try chrome.front() }
                return .json(["title": t.title, "url": t.url, "loading": t.loading, "text": t.url, "lines": [t.title, t.url]], summary: t.url)
            case "tabs":
                let all = f.bool("all") ?? false
                let tabs = try await Self.offThread { try chrome.tabs(all: all) }
                return .json(["count": tabs.count, "tabs": tabs.map { ["window": $0.window, "index": $0.index, "active": $0.active, "title": $0.title, "url": $0.url] as [String: Any] },
                              "lines": tabs.map { ($0.active ? "▶ " : "  ") + "\($0.title) — \($0.url)" }], summary: "\(tabs.count) tabs")
            case "page":
                let max = Swift.max(100, Swift.min(500_000, f.int("max") ?? 20000))
                let outline = f.bool("outline") ?? false
                var out = try await Self.offThread { try chrome.page(max: max, outline: outline) }
                if f.bool("text") == false { out["text"] = nil }
                return .json(out, summary: "read \(out["url"] as? String ?? "the page")")
            case "has":
                let t = try text()
                let cs = f.bool("case_sensitive") ?? false, whole = f.bool("whole_words") ?? false
                var out = try await Self.offThread { try chrome.has(t, caseSensitive: cs, wholeWords: whole) }
                out["answer"] = (out["present"] as? Bool) == true ? "yes" : "no"
                return .json(out, summary: "\"\(t)\": \((out["present"] as? Bool) == true ? "there" : "not there")")
            case "find":
                let t = try text()
                let limit = Swift.max(1, Swift.min(50, f.int("limit") ?? 10))
                var out = try await Self.offThread { try chrome.find(t, limit: limit) }
                out["lines"] = ((out["found"] as? [[String: Any]]) ?? []).map { Self.describe($0) }
                return .json(out, summary: "find \"\(t)\": \(out["count"] ?? 0)")
            case "highlight":
                let t = try text()
                let seconds = f.double("seconds") ?? 4
                let out = try await Self.offThread { try chrome.highlight(t, seconds: seconds) }
                return .json(out, summary: "highlight \"\(t)\": \((out["highlighted"] as? Bool) == true ? "shown" : "not found")")
            default:
                let out = try await Self.offThread { try chrome.outline() }
                return .json(out, summary: "outline of \(out["url"] as? String ?? "the page")")
            }
        }
    }

    /// A match, in a sentence a person can follow: "The link “Compute” is in view, at the top
    /// left, in navigation “Sidebar”."
    static func describe(_ m: [String: Any]) -> String {
        let kind = m["kind"] as? String ?? "thing"
        let text = (m["text"] as? String ?? "").components(separatedBy: "\n").first ?? ""
        var s = "The \(kind) “\(text.count > 60 ? String(text.prefix(59)) + "…" : text)”"
        let where_ = m["where"] as? String ?? ""
        s += " is " + (where_ == "in view" ? "in view" + ((m["side"] as? String).map { $0.isEmpty ? "" : ", at \($0)" } ?? "") : where_)
        if let inside = m["in"] as? [String], !inside.isEmpty { s += ", in " + inside.joined(separator: ", in ") }
        if m["clickable"] as? Bool == false { s += " (it isn't something to click)" }
        return s + "."
    }

    /// Blocking work (waiting on osascript) away from the cooperative threads.
    static func offThread<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async {
                do { c.resume(returning: try work()) } catch { c.resume(throwing: error) }
            }
        }
    }
}
