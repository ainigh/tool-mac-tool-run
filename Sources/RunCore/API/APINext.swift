import Foundation

/// What to call next: every JSON answer carries `"next"`, a few calls that usually come after the
/// one just made (each `{"method", "path", "why"}`), so a client finds its way from any answer
/// without knowing the API ahead of time. Answers about a request or a run say it with their own
/// ids filled in (where it is, collecting its result, stopping it); the rest come from this
/// table, with the path's own values (`{name}`, `{id}`) filled in where the next call takes the
/// same. `?next=false` leaves it out.
public enum APINext {
    public struct Hint: Sendable {
        public let method: String
        public let path: String
        public let why: String

        public init(_ method: String, _ path: String, _ why: String) {
            self.method = method
            self.path = path
            self.why = why
        }

        public var json: [String: Any] { ["method": method, "path": path, "why": why] }
    }

    static let search = Hint("GET", "/api/search?q={words}", "find the route, script or flow for something else, by a few words")

    /// What opens a page, and what finds things out without Chrome.
    static let openPage = Hint("POST", "/api/browser/open", "open another page in Chrome, in a new tab, and read it: {\"url\"} (at once)")
    static let webSearch = Hint("GET", "/api/web/search?q={words}", "find something out on the web, without Chrome (at once)")

    /// The calls that usually come after each route, by "METHOD path".
    static let table: [String: [Hint]] = [
        // About
        "GET /api/endpoints": [search, Hint("GET", "/api/endpoints?brief=true", "the groups alone, small"), Hint("GET", "/api/doc", "the whole API on one page")],
        "GET /api/health": [search, Hint("GET", "/api/requests/open", "the requests not collected yet"), Hint("GET", "/api/endpoints?brief=true", "the groups of routes")],
        "GET /api/doc": [search],
        // Scripts and flows
        "GET /api/scripts": [Hint("POST", "/api/run", "run one: {\"script\", \"args\"?, \"async\": true, \"client\", \"why\"} (it waits for Run on the Mac)"), search],
        "GET /api/flows": [Hint("POST", "/api/compose", "run one: {\"flow\", \"async\": true, \"client\", \"why\"} (it waits for Run on the Mac)"), search],
        "POST /api/check": [Hint("POST", "/api/compose", "run it: {\"source\", \"name\", \"async\": true, \"why\"}")],
        // Straw
        "GET /api/straw": [Hint("POST", "/api/straw/check", "check Straw code before running it {\"source\"}"), Hint("POST", "/api/straw/run", "run a Straw script {\"script\"} or code {\"source\"}")],
        "POST /api/straw/check": [Hint("POST", "/api/straw/run", "run it {\"source\", \"name\"?, \"async\": true, \"why\"} (it waits for Run on the Mac)")],
        // The file library
        "GET /api/library": [Hint("GET", "/api/library/files", "every note"), Hint("GET", "/api/library/search?q={words}", "search every note's text"), Hint("POST", "/api/library", "any operation {\"op\", …}")],
        "POST /api/library": [Hint("GET", "/api/library/files", "every note"), Hint("GET", "/api/library/search?q={words}", "search every note's text")],
        "GET /api/library/files": [Hint("GET", "/api/library/files/{name}", "read one"), Hint("GET", "/api/library/search?q={words}", "search their text")],
        "POST /api/library/files": [Hint("GET", "/api/library/files/{name}", "read it"), Hint("POST", "/api/library/files/{name}/append", "add to it {\"text\"}")],
        "GET /api/library/files/{name}": [Hint("PUT", "/api/library/files/{name}", "replace its text {\"text\"}"), Hint("POST", "/api/library/files/{name}/append", "add a line at its end {\"text\"}"),
                                          Hint("POST", "/api/present", "show it to the person {\"shelf\": \"library\", \"name\": \"{name}\"}")],
        "PUT /api/library/files/{name}": [Hint("GET", "/api/library/files/{name}", "read it back")],
        "DELETE /api/library/files/{name}": [Hint("POST", "/api/library/trash/restore", "bring it back {\"name\": \"{name}\"}"), Hint("GET", "/api/library/trash", "what's in the library's Trash")],
        "POST /api/library/files/{name}/append": [Hint("GET", "/api/library/files/{name}", "read it")],
        "POST /api/library/files/{name}/rename": [Hint("GET", "/api/library/files", "every note")],
        "POST /api/library/files/{name}/copy": [Hint("GET", "/api/library/files", "every note")],
        "GET /api/library/files/{name}/exists": [Hint("GET", "/api/library/files/{name}", "read it"), Hint("PUT", "/api/library/files/{name}", "write it {\"text\"}")],
        "GET /api/library/files/{name}/outline": [Hint("GET", "/api/library/files/{name}", "read it")],
        "GET /api/library/files/{name}/backlinks": [Hint("GET", "/api/library/files/{name}", "read it")],
        "GET /api/library/names": [Hint("GET", "/api/library/files/{name}", "read one")],
        "GET /api/library/search": [Hint("GET", "/api/library/files/{name}", "read one it found"), Hint("GET", "/api/library/find?q={words}", "the names alone")],
        "GET /api/library/find": [Hint("GET", "/api/library/files/{name}", "read one it found")],
        "GET /api/library/recent": [Hint("GET", "/api/library/files/{name}", "read one")],
        "GET /api/library/stats": [Hint("GET", "/api/library/files", "every note")],
        "GET /api/library/trash": [Hint("POST", "/api/library/trash/restore", "bring one back {\"name\"}"), Hint("POST", "/api/library/trash/empty", "empty it for good")],
        "POST /api/library/trash/restore": [Hint("GET", "/api/library/files/{name}", "read it")],
        "POST /api/library/trash/empty": [Hint("GET", "/api/library/trash", "what's left in it")],
        "GET /api/library/operations": [Hint("GET", "/api/library/operations/{id}", "one of them")],
        "GET /api/library/operations/{id}": [Hint("GET", "/api/library/operations", "the latest")],
        // MEMORY
        "GET /api/memory": [Hint("GET", "/api/memory/recall?name={name}", "what's known about a name"), Hint("POST", "/api/memory/remember", "remember something {\"category\", \"about\", \"text\"}"),
                            Hint("GET", "/api/memory/upcoming?days=30", "the days coming up")],
        "POST /api/memory": [Hint("GET", "/api/memory/recall?name={name}", "what's known about a name")],
        "POST /api/memory/remember": [Hint("GET", "/api/memory/recall?name={name}", "read back what's known about it"), Hint("GET", "/api/mind/nodes/{name}", "it in the mind, with its links")],
        "GET /api/memory/recall": [Hint("POST", "/api/memory/remember", "remember more about it {\"category\", \"about\", \"text\"}"), Hint("GET", "/api/mind/nodes/{name}", "it in the mind, with its links"),
                                   Hint("POST", "/api/present", "show it to the person {\"mind\": \"{name}\"}")],
        "GET /api/memory/categories": [Hint("GET", "/api/memory/categories/{name}/members", "what's filed under one")],
        "GET /api/memory/categories/{name}/members": [Hint("GET", "/api/memory/recall?name={name}", "what's known about one of them")],
        "GET /api/memory/upcoming": [Hint("POST", "/api/present", "show them to the person {\"title\", \"text\"}"), Hint("POST", "/api/memory/remember", "remember a date {\"category\": \"EVENT-DATES\", …}")],
        "GET /api/memory/files": [Hint("GET", "/api/memory/files/{name}", "read one")],
        "GET /api/memory/files/{name}": [Hint("POST", "/api/memory/files/{name}/append", "add a line {\"text\"}"), Hint("POST", "/api/present", "show it {\"shelf\": \"memory\", \"name\": \"{name}\"}")],
        "GET /api/memory/search": [Hint("GET", "/api/memory/recall?name={name}", "all that's known about one it found")],
        "GET /api/memory/operations": [Hint("GET", "/api/requests/{id}", "one of them, by its id")],
        // The mind
        "GET /api/mind": [Hint("GET", "/api/mind/nodes/{name}", "all about one thing"), Hint("GET", "/api/mind/find?q={words}", "things by words"), Hint("POST", "/api/mind/query", "ask in the notation {\"q\"}")],
        "POST /api/mind": [Hint("GET", "/api/mind/nodes/{name}", "all about one thing")],
        "GET /api/mind/nodes": [Hint("GET", "/api/mind/nodes/{name}", "all about one")],
        "GET /api/mind/nodes/{name}": [Hint("GET", "/api/mind/nodes/{name}/neighbors?depth=2", "what's around it"), Hint("POST", "/api/mind/add", "link it to something {\"from\": \"{name}\", \"label\", \"to\"}"),
                                       Hint("POST", "/api/mind/note", "a note on it {\"name\": \"{name}\", \"note\"}")],
        "GET /api/mind/nodes/{name}/neighbors": [Hint("GET", "/api/mind/path?from={name}&to={other}", "how it connects to another")],
        "GET /api/mind/find": [Hint("GET", "/api/mind/nodes/{name}", "all about one it found")],
        "GET /api/mind/path": [Hint("GET", "/api/mind/nodes/{name}", "all about one on the way")],
        "GET /api/mind/edges": [Hint("GET", "/api/mind/nodes/{name}", "all about one end")],
        "GET /api/mind/notes": [Hint("GET", "/api/mind/nodes/{name}", "all about one")],
        "GET /api/mind/dates": [Hint("GET", "/api/memory/upcoming?days=30", "the same days, with MEMORY's dated lines too")],
        "POST /api/mind/query": [Hint("GET", "/api/mind/nodes/{name}", "all about one it found")],
        "POST /api/mind/context": [Hint("POST", "/api/mind/prompt", "the notation's prompt for a model {\"messages\"}")],
        "POST /api/mind/check": [Hint("POST", "/api/mind/append", "write them {\"lines\"}")],
        "POST /api/mind/add": [Hint("GET", "/api/mind/nodes/{name}", "read it back")],
        "POST /api/mind/append": [Hint("GET", "/api/mind/problems", "lines that couldn't be read")],
        "POST /api/mind/note": [Hint("GET", "/api/mind/nodes/{name}", "read it back")],
        "POST /api/mind/rename": [Hint("GET", "/api/mind/nodes/{name}", "read it back")],
        // SYSTEM-DOCS
        "GET /api/system-docs": [Hint("GET", "/api/system-docs/files/START-HERE", "where to start"), Hint("GET", "/api/system-docs/search?q={words}", "search them")],
        "GET /api/system-docs/files": [Hint("GET", "/api/system-docs/files/{name}", "read one")],
        "GET /api/system-docs/files/{name}": [Hint("GET", "/api/system-docs/files/{name}/outline", "its headings"), Hint("GET", "/api/system-docs/search?q={words}", "search every doc")],
        "GET /api/system-docs/search": [Hint("GET", "/api/system-docs/files/{name}", "read one it found")],
        "GET /api/system-docs/names": [Hint("GET", "/api/system-docs/files/{name}", "read one")],
        // Show and copy
        "GET /api/present": [Hint("POST", "/api/present", "show something {\"title\", \"text\", \"why\"}")],
        "POST /api/present": [Hint("POST", "/api/clipboard", "put it on the clipboard too {\"text\"}")],
        "GET /api/clipboard": [Hint("POST", "/api/clipboard", "copy something {\"text\"}")],
        "POST /api/clipboard": [Hint("POST", "/api/present", "show it too {\"title\", \"text\"}")],
        // Chrome's page
        "GET /api/browser": [Hint("GET", "/api/browser/page", "what the page says"), Hint("GET", "/api/browser/find?text={words}", "where a thing is on it"), openPage],
        "GET /api/browser/url": [Hint("GET", "/api/browser/page", "what the page says"), Hint("GET", "/api/browser/has?text={words}", "whether words are on it"), openPage],
        "GET /api/browser/tabs": [Hint("GET", "/api/browser/page", "the page in front"), openPage],
        "GET /api/browser/page": [Hint("GET", "/api/browser/find?text={words}", "where a thing is"), Hint("GET", "/api/browser/has?text={words}", "whether words are on it"), openPage],
        "GET /api/browser/has": [Hint("GET", "/api/browser/find?text={words}", "where it is"), Hint("POST", "/api/browser/highlight", "ring it in red for the person {\"text\"}")],
        "GET /api/browser/find": [Hint("POST", "/api/browser/highlight", "ring it in red for the person {\"text\"}")],
        "POST /api/browser/highlight": [Hint("GET", "/api/browser/has?text={words}", "read again after the person's next step")],
        "GET /api/browser/outline": [Hint("GET", "/api/browser/find?text={words}", "where one thing is")],
        "POST /api/browser/open": [Hint("GET", "/api/browser/find?text={words}", "where a thing is on it"), Hint("POST", "/api/browser/highlight", "ring it in red for the person {\"text\"}"),
                                   Hint("GET", "/api/browser/page", "read it again, once it's changed")],
        // The web
        "GET /api/web": [webSearch, Hint("GET", "/api/web/fetch?url={address}", "read an address")],
        "GET /api/web/search": [Hint("GET", "/api/web/fetch?url={address}", "read the result that fits best (a page, or a JSON API it points to)"), Hint("POST", "/api/browser/open", "open it in Chrome for the person {\"url\"}")],
        "GET /api/web/fetch": [Hint("GET", "/api/web/fetch?url={address}", "follow one of its links, or the API it points to"), Hint("GET", "/api/web/fetch?url={address}&find={words}", "only the lines with some words"),
                               Hint("POST", "/api/browser/open", "open it in Chrome for the person {\"url\"}")],
        // Say
        "GET /api/say/forms": [Hint("POST", "/api/say", "say one back, its blanks filled (text/plain)")],
        "GET /api/say/log": [Hint("POST", "/api/say", "ask about one in words: \"what happened to {something you asked for}\"")],
        "POST /api/say/reset": [Hint("POST", "/api/say", "say what you want (text/plain)")],
        // Tools
        "GET /api/tools": [Hint("POST", "/api/tools/{name}", "call one {\"arguments\": {…}}"), Hint("GET", "/api/search?q={words}&in=tools", "the tools for something, by a few words")],
        "GET /api/tools/{name}": [Hint("POST", "/api/tools/{name}", "call it {\"arguments\": {…}}")],
        // Automation
        "GET /api/automation": [Hint("POST", "/api/automation", "tag a script or flow to run by itself {\"script\"|\"flow\", \"automation\": [tags], \"why\"}")],
        // Runs and requests
        "GET /api/runs": [Hint("GET", "/api/runs/{id}", "one run, with everything it printed"), Hint("GET", "/api/requests/open", "the requests not collected yet")],
        "GET /api/runs/{id}": [Hint("POST", "/api/runs/{id}/stop", "stop it, if it's running"), Hint("GET", "/api/requests/open", "the requests not collected yet")],
        "GET /api/requests": [Hint("GET", "/api/requests/open", "only the ones not cleared yet, oldest first")],
    ]

    /// The hints for an answer to `req`, from the table (or its group's first route and a
    /// search), with the path's values filled in.
    public static func hints(for req: HTTPRequest) -> [Hint] {
        let method = req.method == "HEAD" ? "GET" : req.method
        var path = req.path
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        // MEMORY and SYSTEM-DOCS take the library's routes too: the library's next calls, at theirs.
        var shelfPrefix: String?
        var found = APIRoutes.match(method, path)
        if found == nil {
            for prefix in ["/api/memory", "/api/system-docs"] where path == prefix || path.hasPrefix(prefix + "/") {
                found = APIRoutes.match(method, "/api/library" + path.dropFirst(prefix.count))
                shelfPrefix = prefix
            }
        }
        guard let (route, group, found) = found else { return [search] }
        // What else it was asked with fills in the rest: a name, the words searched for.
        var params = found
        let body = JSON.object(req.body) ?? [:]
        if params["name"] == nil, let name = req.query["name"] ?? RunAPI.text(body["name"]) ?? RunAPI.text(body["about"]) ?? RunAPI.text(body["from"]) {
            params["name"] = name
        }
        if params["words"] == nil, let words = req.query["q"] ?? req.query["text"] ?? RunAPI.text(body["q"]) { params["words"] = words }
        var hints = table[route.key] ?? fallback(route, group)
        if let prefix = shelfPrefix {
            hints = hints.map { Hint($0.method, $0.path.replacingOccurrences(of: "/api/library", with: prefix), $0.why) }
            if prefix == "/api/system-docs" { hints = hints.filter { $0.method == "GET" } }
        }
        return hints.map { fill($0, params) }
    }

    /// No hints of its own: its group's first route (what's there) and a search.
    static func fallback(_ route: APIRoutes.Route, _ group: APIRoutes.Group) -> [Hint] {
        var out: [Hint] = []
        if let first = group.routes.first, first.key != route.key, first.method == "GET" {
            out.append(Hint("GET", first.path, "\(group.title.prefix(1).lowercased() + group.title.dropFirst()): \(first.summary)"))
        }
        out.append(search)
        return out
    }

    /// The path's own values put into a hint that takes the same ones (`{name}`, `{id}`).
    static func fill(_ h: Hint, _ params: [String: String]) -> Hint {
        var path = h.path, why = h.why
        for (k, v) in params where !v.isEmpty {
            let inPath = v.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?&=+"))) ?? v
            path = path.replacingOccurrences(of: "{\(k)}", with: inPath)
            why = why.replacingOccurrences(of: "{\(k)}", with: v)
        }
        return Hint(h.method, path, why)
    }

    /// The hints for a refusal: where to look instead.
    static func hints(forError code: String, _ req: HTTPRequest) -> [Hint] {
        switch code {
        case "not_found" where req.path.hasPrefix("/api") && !req.path.hasPrefix("/api/library/files/") && !req.path.hasPrefix("/api/memory/files/"):
            let words = req.path.split(separator: "/").dropFirst().joined(separator: " ")
            let q = words.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? words
            return [Hint("GET", "/api/search?q=\(q)", "the routes that match the words of the path you asked for"),
                    Hint("GET", "/api/endpoints?brief=true", "the groups of routes")]
        case "endpoint_off":
            return [Hint("GET", "/api/health", "which groups are on (the person switches them in the app)")]
        case "unknown_request":
            return [Hint("GET", "/api/requests/open", "the requests not cleared yet"), Hint("GET", "/api/runs", "the latest runs, each with its request id")]
        case "unknown_run":
            return [Hint("GET", "/api/runs", "the latest runs")]
        case "unknown_script":
            return [Hint("GET", "/api/search?q={words}&in=scripts", "scripts by what they do"), Hint("GET", "/api/scripts", "every script")]
        case "unknown_flow":
            return [Hint("GET", "/api/search?q={words}&in=flows", "flows by what they do"), Hint("GET", "/api/flows", "every flow")]
        case "chrome_not_open", "no_window":
            return [openPage, webSearch, Hint("GET", "/api/web/fetch?url={address}", "read an address without Chrome")]
        case "browser_reads_only":
            let q = req.query["text"] ?? req.query["q"] ?? (JSON.object(req.body)?["text"] as? String) ?? ""
            return RunAPI.actHints(q)
        case "unknown_group":
            return [Hint("GET", "/api/endpoints?brief=true", "the groups there are")]
        default:
            return hints(for: req)
        }
    }

    /// Adds `"next"` to a JSON object answer that hasn't one (`?next=false`: never).
    static func add(to response: inout HTTPResponse, for req: HTTPRequest) {
        guard req.query["next"]?.lowercased() != "false", response.header("Content-Type") == "application/json",
              let data = response.bodyData, var object = JSON.object(data), object["next"] == nil else { return }
        let hints = (response.status >= 400 ? hints(forError: object["code"] as? String ?? "", req) : hints(for: req))
        guard !hints.isEmpty else { return }
        object["next"] = hints.map(\.json)
        response.body = .data(JSON.data(object))
    }
}

extension APIRoutes {
    /// The route a request is for, its group, and the values in its path (`{name}`, `{id}`):
    /// a route's own path first, then the ones with values in them.
    public static func match(_ method: String, _ path: String) -> (Route, Group, [String: String])? {
        for g in groups { for r in g.routes where r.method == method && r.path == path { return (r, g, [:]) } }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        for g in groups {
            for r in g.routes where r.method == method && r.path.contains("{") {
                let template = r.path.split(separator: "/").map(String.init)
                guard template.count == parts.count else { continue }
                var params: [String: String] = [:]
                var ok = true
                for (t, p) in zip(template, parts) {
                    if t.hasPrefix("{"), t.hasSuffix("}") { params[String(t.dropFirst().dropLast())] = p }
                    else if t != p { ok = false; break }
                }
                if ok { return (r, g, params) }
            }
        }
        return nil
    }
}
