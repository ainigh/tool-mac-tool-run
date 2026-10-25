import Foundation

/// Chrome's pages, for an app working beside the person or guiding them through a site
/// (`/api/browser…`): what's open, what it says, whether some words are on it, where a thing is, a
/// red ring to show them, and a page opened for them to see. It never clicks or types (Straw does,
/// after Run): what it does is seen and undone in a click, so it's answered at once.
///
/// Each of these works in any of three places (`where`): **side by side** (the default: a Chrome
/// window of the app's own on the right half of the screen, the person's on the left, so the two
/// work beside each other), **on screen** (the person's own tab in front), or **in the
/// background** (the app's own window, kept behind the person's). A read with no `where` reads
/// the app's own window while there is one, else the person's.
extension RunAPI {
    static let browserRoutes: [(method: String, path: String, summary: String)] = [
        ("GET", "/api/browser", "whether Chrome is open, what's in front, the app's own window (where it is), and whether apps may read inside its pages"),
        ("GET", "/api/browser/url", "the tab in front: its title and address (needs nothing switched on in Chrome)"),
        ("GET", "/api/browser/tabs", "every tab of the front window (?all=true: every window), the one in front marked"),
        ("GET", "/api/browser/page", "the page in front: title, address, its text (?max=20000 characters), what's selected, how far down it is (?outline=true: its outline too)"),
        ("GET", "/api/browser/has", "whether words are on the page: ?text=Compute (?case_sensitive, ?whole_words): true or false, how many times, the lines"),
        ("GET", "/api/browser/find", "where a thing is: ?text=Compute — each match's kind (link, button…), whether it's in view, above, below, or in a closed menu, and what it's in"),
        ("POST", "/api/browser/highlight", "shows the person where: {\"text\": \"Compute\", \"seconds\"?: 4} scrolls to it and rings it in red (or the closed menu it's in)"),
        ("POST", "/api/browser/open", "opens an address in Chrome {\"url\", \"where\"?: \"side_by_side\" (the default) | \"on_screen\" | \"background\", \"new_tab\"?}, waits for it to load, and reads it (as /page; ?max=8000): for the person to see it, or to read a site as they would"),
        ("POST", "/api/browser/place", "puts the app's own window {\"where\": \"side_by_side\" | \"background\"} (on_screen: closes it, as /close); the person's window goes to the left half beside it, and back when it leaves"),
        ("POST", "/api/browser/close", "closes the app's own window and puts the person's back where it was"),
        ("GET", "/api/browser/outline", "the page's outline: headings, landmarks, navigation, buttons, fields, links"),
    ]

    /// The words each is found by (`GET /api/search`), beyond its path and summary.
    static let browserTags: [String: String] = [
        "/api/browser": "status javascript front ready",
        "/api/browser/url": "address title current front tab which where",
        "/api/browser/tabs": "tabs windows list",
        "/api/browser/page": "page text read content selection scroll links",
        "/api/browser/open": "open go goto navigate visit load url address website link tab show",
        "/api/browser/has": "has contains present check words text there",
        "/api/browser/find": "find where locate button link element",
        "/api/browser/highlight": "highlight point show ring mark where",
        "/api/browser/outline": "outline headings structure landmarks menus buttons fields map",
        "/api/browser/place": "side by side beside split screen arrange window background behind own place where",
        "/api/browser/close": "close done put back restore window own side by side",
    ]

    /// Every route takes where: the three places, said.
    static let browserWhere = "\"where\": \"side_by_side\" (a window of its own on the right half of the screen, the person's on the left: the default), \"on_screen\" (the person's own tab in front) or \"background\" (its own window, behind the person's). A read with no where reads its own window while there is one, else the person's."

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
        case ("POST", "open", 1), ("GET", "open", 1), ("POST", "go", 1), ("POST", "goto", 1), ("POST", "navigate", 1), ("POST", "visit", 1), ("POST", "load", 1): op = "open"
        case ("GET", "outline", 1): op = "outline"
        case ("POST", "place", 1), ("POST", "arrange", 1), ("POST", "where", 1): op = "place"
        case ("POST", "close", 1), ("POST", "done", 1), ("POST", "restore", 1): op = "close"
        case ("GET", "operations", 1):
            let limit = min(500, max(1, Int(req.query["limit"] ?? "") ?? 20))
            return JSON.response(["operations": await libraryLog.recent(500).filter { $0.kind == "browser" }.prefix(limit).map(LibraryLog.json)])
        case (_, let first?, 1) where ["url", "tabs", "page", "has", "find", "highlight", "outline", "open", "place", "close"].contains(first):
            throw HTTPError(status: 405, code: "bad_request", message: "\(path) takes \(["highlight", "open", "place", "close"].contains(first) ? "POST" : "GET")")
        case (_, let first?, _) where Self.actions.contains(first.lowercased()):
            // Asked to act (search, click, type…): it doesn't. Said, with what does.
            let wanted = f.text("text") ?? f.text("q") ?? f.text("url") ?? f.text("address") ?? ""
            throw HTTPError(status: 400, code: "browser_reads_only",
                            message: "Chrome's page reads the tab in front and opens pages; it can't \(first.lowercased())\(wanted.isEmpty ? "" : " \"\(wanted)\""). " + Self.whatActs(wanted))
        default:
            throw HTTPError(status: 404, code: "not_found", message: "no such route: \(req.method) \(req.path) (GET /api/browser lists Chrome's routes; they only read)")
        }
        // An address or words sent to a read (url, page…): it doesn't go there. Said in the answer,
        // with the call that does, so the page in front isn't taken for the one asked for.
        let elsewhere = ["open", "place", "close"].contains(op) ? nil : f.text("url") ?? f.text("address") ?? f.text("go") ?? f.text("open")
            ?? (["status", "url", "tabs", "page", "outline"].contains(op) ? f.text("text") ?? f.text("q") : nil)
        let asked = try Self.place(f)
        let response = await logged("browser", op, f, req) {
            func text() throws -> String {
                guard let t = f.text("text") ?? f.text("q") ?? f.text("name"), !t.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw HTTPError(status: 400, code: "bad_request", message: "say what to look for: \"text\" (?text=Compute)")
                }
                return t
            }
            switch op {
            case "status":
                var out: [String: Any] = ["routes": Self.browserRoutes.map { ["method": $0.method, "path": $0.path, "summary": $0.summary] },
                                          "never": "it never clicks, types or fills in anything: that's Straw (POST /api/straw/run, which waits for Run on the Mac). To open a page: POST /api/browser/open {\"url\"}. To find something out without Chrome: GET /api/web/search?q=…, GET /api/web/fetch?url=…"]
                out["where"] = Self.browserWhere
                let own = await browserWindow.state
                out["its_window"] = own.map { ["id": $0.id, "where": $0.place.rawValue, "said": $0.place.words] as [String: Any] } ?? NSNull()
                do {
                    let t = try await Self.offThread { try chrome.front(not: own?.id) }
                    out["chrome"] = "open"
                    out["front"] = ["title": t.title, "url": t.url, "loading": t.loading]
                    do {
                        _ = try await Self.offThread { try chrome.js("return {ok: true}", not: own?.id) }
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
            case "open":
                guard let raw = f.text("url") ?? f.text("address") ?? f.text("text") ?? f.text("q"), !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw HTTPError(status: 400, code: "bad_request", message: "say which address to open: \"url\" (https://example.com)")
                }
                let url = Self.isAddress(raw) ? (raw.contains("://") ? raw : "https://" + raw)
                    : "https://www.google.com/search?q=" + (raw.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? raw)
                guard let u = URL(string: url), ["http", "https"].contains(u.scheme?.lowercased() ?? "") else {
                    throw HTTPError(status: 400, code: "bad_url", message: "\(raw) isn't a web address: give one like https://example.com")
                }
                // Side by side unless it says otherwise (or its own window is somewhere already).
                let current = await browserWindow.state?.place
                let place = asked ?? current ?? .sideBySide
                let window = place == .onScreen ? nil : try await browserPlace(place)
                let own = await browserWindow.state?.id
                // The person's window gets a tab of its own; the app's own window goes to the page.
                let newTab = f.bool("new_tab") ?? f.bool("tab") ?? (place == .onScreen)
                let t = try await Self.offThread { try chrome.open(u.absoluteString, newTab: newTab, window: window, not: own) }
                var out: [String: Any] = ["opened": true, "title": t.title, "url": t.url, "loading": t.loading, "new_tab": newTab]
                Self.said(&out, place)
                if !Self.isAddress(raw) { out["searched"] = raw }
                // Read as it stands now, so what's on it comes back in the same answer.
                do {
                    let max = Swift.max(100, Swift.min(100_000, f.int("max") ?? 8000))
                    let page = try await Self.offThread { try chrome.page(max: max, window: window, not: own) }
                    for (k, v) in page where out[k] == nil || k == "title" || k == "url" { out[k] = v }
                } catch let e as ChromeError {
                    out["read"] = false
                    out["read_problem"] = e.message
                    if let fix = e.fix { out["fix"] = fix }
                }
                return .json(out, summary: "opened \(t.url)")
            case "place":
                guard let place = asked else {
                    throw HTTPError(status: 400, code: "bad_request", message: "say where: \(Self.browserWhere)")
                }
                if place == .onScreen {
                    let out = try await browserClose()
                    return .json(out, summary: "its own window closed")
                }
                let id = try await browserPlace(place)
                var out: [String: Any] = ["placed": true, "window": id]
                Self.said(&out, place)
                return .json(out, summary: "its own window \(place.words)")
            case "close":
                let out = try await browserClose()
                return .json(out, summary: "its own window closed")
            case "url":
                let (t, place) = try await inWindow(asked) { w, own in try chrome.front(window: w, not: own) }
                var out: [String: Any] = ["title": t.title, "url": t.url, "loading": t.loading, "text": t.url, "lines": [t.title, t.url]]
                Self.said(&out, place)
                return .json(out, summary: t.url)
            case "tabs":
                let all = f.bool("all") ?? false
                let (tabs, place) = try await inWindow(asked) { w, own in try chrome.tabs(all: all, window: w, not: own) }
                var out: [String: Any] = ["count": tabs.count, "tabs": tabs.map { ["window": $0.window, "index": $0.index, "active": $0.active, "title": $0.title, "url": $0.url] as [String: Any] },
                                          "lines": tabs.map { ($0.active ? "▶ " : "  ") + "\($0.title) — \($0.url)" }]
                Self.said(&out, place)
                return .json(out, summary: "\(tabs.count) tabs")
            case "page":
                let max = Swift.max(100, Swift.min(500_000, f.int("max") ?? 20000))
                let outline = f.bool("outline") ?? false
                var (out, place) = try await inWindow(asked) { w, own in try chrome.page(max: max, outline: outline, window: w, not: own) }
                if f.bool("text") == false { out["text"] = nil }
                Self.said(&out, place)
                return .json(out, summary: "read \(out["url"] as? String ?? "the page")")
            case "has":
                let t = try text()
                let cs = f.bool("case_sensitive") ?? false, whole = f.bool("whole_words") ?? false
                var (out, place) = try await inWindow(asked) { w, own in try chrome.has(t, caseSensitive: cs, wholeWords: whole, window: w, not: own) }
                out["answer"] = (out["present"] as? Bool) == true ? "yes" : "no"
                Self.said(&out, place)
                return .json(out, summary: "\"\(t)\": \((out["present"] as? Bool) == true ? "there" : "not there")")
            case "find":
                let t = try text()
                let limit = Swift.max(1, Swift.min(50, f.int("limit") ?? 10))
                var (out, place) = try await inWindow(asked) { w, own in try chrome.find(t, limit: limit, window: w, not: own) }
                out["lines"] = ((out["found"] as? [[String: Any]]) ?? []).map { Self.describe($0) }
                Self.said(&out, place)
                return .json(out, summary: "find \"\(t)\": \(out["count"] ?? 0)")
            case "highlight":
                let t = try text()
                let seconds = f.double("seconds") ?? 4
                var (out, place) = try await inWindow(asked) { w, own in try chrome.highlight(t, seconds: seconds, window: w, not: own) }
                Self.said(&out, place)
                return .json(out, summary: "highlight \"\(t)\": \((out["highlighted"] as? Bool) == true ? "shown" : "not found")")
            default:
                var (out, place) = try await inWindow(asked) { w, own in try chrome.outline(window: w, not: own) }
                Self.said(&out, place)
                return .json(out, summary: "outline of \(out["url"] as? String ?? "the page")")
            }
        }
        guard let asked = elsewhere?.trimmingCharacters(in: .whitespaces), !asked.isEmpty,
              let data = response.bodyData, var out = JSON.object(data) else { return response }
        out["not_opened"] = asked
        out["note"] = "This read the tab already open\((out["url"] as? String).map { " (\($0))" } ?? ""); a read goes nowhere, so it didn't open \"\(asked)\". " + Self.whatActs(asked)
        out["next"] = Self.actHints(asked).map(\.json)
        var changed = response
        changed.body = .data(JSON.data(out))
        return changed
    }

    // MARK: where

    /// The place asked for (`where`): nil when none was said; a refusal for one that isn't a place.
    static func place(_ f: LibraryAPI.Fields) throws -> ChromePage.Place? {
        guard let said = f.text("where") ?? f.text("place"), !said.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard let p = ChromePage.Place(said: said) else {
            throw HTTPError(status: 400, code: "bad_where", message: "\"\(said)\" isn't a place: \(browserWhere)")
        }
        return p
    }

    /// Where it was, in the answer: `where` (side_by_side, on_screen, background) and in words.
    static func said(_ out: inout [String: Any], _ place: ChromePage.Place) {
        out["where"] = place.rawValue
        out["where_said"] = place == .onScreen ? "the person's own tab, on their screen" : place == .sideBySide
            ? "its own window, side by side with the person's" : "its own window, in the background"
    }

    /// Works on the window asked for: the app's own (while there is one, unless the person's was
    /// asked for), else the person's. Asked for its own when there's none: said, with how to open
    /// one. Its own closed meanwhile is forgotten (and, with nothing asked, the person's is read).
    func inWindow<T: Sendable>(_ asked: ChromePage.Place?, _ work: @escaping @Sendable (_ window: Int?, _ own: Int?) throws -> T) async throws -> (T, ChromePage.Place) {
        if asked != .onScreen, let own = await browserWindow.state {
            do {
                return (try await Self.offThread { try work(own.id, nil) }, own.place)
            } catch let e as ChromeError where e.code == .windowGone {
                await browserWindow.forget()
                if asked != nil { throw Self.noWindow(asked!) }
            }
        } else if let asked, asked != .onScreen {
            throw Self.noWindow(asked)
        }
        let own = await browserWindow.state?.id
        return (try await Self.offThread { try work(nil, own) }, .onScreen)
    }

    static func noWindow(_ place: ChromePage.Place) -> HTTPError {
        HTTPError(status: 409, code: "no_window_of_its_own",
                  message: "there's no page \(place.words) yet: open one there first (POST /api/browser/open {\"url\", \"where\": \"\(place.rawValue)\"}), or read the person's own tab (\"where\": \"on_screen\")")
    }

    /// Puts the app's own window where asked (making it when there's none): side by side, it on
    /// the right half of the screen and the person's front window on the left (where that was is
    /// kept, to put it back); in the background, behind every other (the person's put back if it
    /// was moved). Already there: left as it is, so what the person has moved since stays moved.
    func browserPlace(_ place: ChromePage.Place) async throws -> Int {
        let chrome = self.chrome
        var state = await browserWindow.state
        let windows = try await Self.offThread { try chrome.windows() }
        if let s = state, !windows.contains(where: { $0.id == s.id }) {
            state = nil
            await browserWindow.forget()
        }
        if let s = state, s.place == place { return s.id }
        switch place {
        case .sideBySide:
            let user = windows.first { $0.id != state?.id && !$0.minimized } ?? windows.first { $0.id != state?.id }
            let ownNow = windows.first { $0.id == state?.id }
            let screens = try await Self.offThread { try chrome.screens() }
            guard let (left, right) = ChromePage.sideBySide(around: user?.bounds ?? ownNow?.bounds, on: screens) else {
                throw ChromeError(.failed, "macOS didn't say what screens there are.")
            }
            let ownID = state?.id
            let id = try await Self.offThread { try chrome.arrange(own: ownID, ownBounds: right, user: user?.id, userBounds: user == nil ? nil : left, activate: true) }
            await browserWindow.set(.init(id: id, place: .sideBySide, user: user?.id, userBounds: user?.bounds))
            return id
        case .background:
            if let s = state, s.place == .sideBySide, let u = s.user, let b = s.userBounds, windows.contains(where: { $0.id == u }) {
                try await Self.offThread { try chrome.restore(u, to: b) }
            }
            let ownID = state?.id
            let id = try await Self.offThread { try chrome.arrange(own: ownID, ownBounds: nil, behind: true) }
            await browserWindow.set(.init(id: id, place: .background, user: nil, userBounds: nil))
            return id
        case .onScreen:
            throw HTTPError(status: 400, code: "bad_where", message: "on screen is the person's own tab: there's nothing of its own to put there")
        }
    }

    /// Closes the app's own window, and puts the person's back where it was before side by side.
    func browserClose() async throws -> [String: Any] {
        let chrome = self.chrome
        guard let s = await browserWindow.state else { return ["closed": false, "said": "There's no window of its own to close."] }
        await browserWindow.forget()
        var restored = false
        if let u = s.user, let b = s.userBounds {
            let windows = try await Self.offThread { try chrome.windows() }
            if windows.contains(where: { $0.id == u }) {
                try await Self.offThread { try chrome.restore(u, to: b) }
                restored = true
            }
        }
        try await Self.offThread { try chrome.close(window: s.id) }
        return ["closed": true, "window": s.id, "restored": restored,
                "said": restored ? "Its own window is closed, and the person's is back where it was." : "Its own window is closed."]
    }

    /// Words that ask the page to do something rather than be read.
    static let actions: Set<String> = ["search", "google", "click", "type", "fill", "press", "submit", "browse", "launch", "scroll", "select", "tap"]

    /// Looks like an address (google.com, https://…), not words to search for.
    static func isAddress(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.contains("://") || (!t.contains(" ") && t.contains(".") && t.last != ".")
    }

    /// What does what was asked: open an address, search the web, or Straw to click and type.
    static func whatActs(_ wanted: String) -> String {
        let quoted = RunAPI.jsonString(wanted.isEmpty ? "<address>" : wanted)
        let words = RunAPI.jsonString(wanted.isEmpty ? "<words>" : wanted)
        return (isAddress(wanted) || wanted.isEmpty
                ? "To open it in Chrome: POST /api/browser/open {\"url\": \(quoted)}. To read it without Chrome: GET /api/web/fetch?url=…."
                : "To search the web for it: GET /api/web/search?q=… (\(words)), then read a result with GET /api/web/fetch?url=…. To open an address in Chrome: POST /api/browser/open {\"url\"}.")
            + " To click and type: Straw, POST /api/straw/run {\"source\"}, which waits for Run on the Mac."
    }

    static func actHints(_ wanted: String) -> [APINext.Hint] {
        let address = isAddress(wanted) ? wanted : "<address>"
        let open = APINext.Hint("POST", "/api/browser/open", "open it in Chrome, in a new tab, and read it: {\"url\": \(RunAPI.jsonString(address))} (at once)")
        let fetch = APINext.Hint("GET", "/api/web/fetch?url=\(address.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? address)", "read it without Chrome (at once)")
        let q = isAddress(wanted) || wanted.isEmpty ? "<words>" : wanted
        let search = APINext.Hint("GET", "/api/web/search?q=\(q.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? q)", "search the web (at once)")
        let straw = APINext.Hint("POST", "/api/straw/run", "click and type on a page: Straw {\"source\": \"open example.com\\nclick \\\"More\\\"\", \"why\"} (waits for Run on the Mac)")
        return isAddress(wanted) || wanted.isEmpty ? [open, fetch, straw] : [search, open, straw]
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
