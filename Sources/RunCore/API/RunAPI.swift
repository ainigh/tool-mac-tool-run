import Foundation

/// What another app asks to run, as it's shown on the Mac for the person to allow (or not).
public struct RunRequest: Identifiable, Sendable {
    public enum What: Sendable {
        /// A script in the folder.
        case script(ScriptItem)
        /// A flow in the folder's composer folder.
        case flow(ScriptItem)
        /// Flow code the app sent (checked already).
        case source(String)
        /// Stopping a run the person started (at the Mac, or by itself): it's theirs, so they're asked.
        case stop(UUID)
    }

    public let id = UUID()
    public var what: What
    /// The script's or flow's file name, or the name the app gave the code it sent.
    public var name: String
    public var arguments: [String]
    /// Text handed to a script as its input.
    public var stdin: String?
    /// Who's asking, in its own words ("client" in the request, else its User-Agent).
    public var client: String
    /// Where it's asking from: "this Mac", "a page at http://localhost:3000", "192.168.1.20".
    public var from: String
    /// What will run, as typed in a terminal (for a script), or how the flow is run.
    public var command: String
    /// What a script looks like it does that can't be undone (`Caution`).
    public var dangers: [String]
    /// Why the app wants it run, in its own words (the request's `why`), shown on the card so the
    /// person knows before clicking Run. Nil: it didn't say (the card says that too).
    public var why: String?
    /// Not a run now: the app asks to tag the item so it runs by itself (the request's
    /// `automation`). The card says so, and Run tags it. Empty tags take the automation off.
    public var automation: Automation?
    /// Code an app sent that's run as a script (Straw code, kept in a file of its own): the card
    /// shows it in full, as it does Flow code.
    public var shownCode: String?

    public init(what: What, name: String, arguments: [String] = [], stdin: String? = nil, client: String,
                from: String = "this Mac", command: String, dangers: [String] = [], why: String? = nil, automation: Automation? = nil) {
        self.what = what
        self.name = name
        self.arguments = arguments
        self.stdin = stdin
        self.client = client
        self.from = from
        self.command = command
        self.dangers = dangers
        self.why = why
        self.automation = automation
    }

    /// Kept with the run: who asked for it ("curl, on this Mac").
    public var requestedBy: String { "\(client), \(from == "this Mac" ? "on this Mac" : "from \(from)")" }

    /// The item's id, for a script or a flow in the folder (nil for code the app sent).
    public var itemID: String? {
        switch what {
        case let .script(item), let .flow(item): item.id
        case .source, .stop: nil
        }
    }

    /// The code it runs, when an app sent it (Flow code, or Straw code): shown in full on the Mac
    /// before it's allowed.
    public var source: String? {
        if case let .source(s) = what { return s }
        return shownCode
    }

    public var isScript: Bool {
        if case .script = what { return true }
        return false
    }

    /// It asks to stop a run, not to start one.
    public var isStop: Bool {
        if case .stop = what { return true }
        return false
    }

    /// What it's called in the ledger and on the card: automation, stop, script or flow.
    public var kindName: String {
        if automation != nil { return "automation" }
        switch what {
        case .script: return "script"
        case .flow, .source: return "flow"
        case .stop: return "stop"
        }
    }
}

/// How the person answered.
public enum Approval: Sendable, Equatable {
    case allowed, denied
    /// No one answered in time (the request said nothing ran).
    case unanswered
}

/// The folder as the API sees it.
public struct Catalog: Sendable {
    public var folder: URL
    public var scripts: [ScriptItem]
    public var flows: [ScriptItem]

    public init(folder: URL, scripts: [ScriptItem], flows: [ScriptItem]) {
        self.folder = folder
        self.scripts = scripts
        self.flows = flows
    }
}

/// What the API needs from the app: the folder, the person's go-ahead, and the runs.
public protocol RunHost: AnyObject, Sendable {
    /// The scripts and flows (nil: no folder has been chosen yet).
    func catalog() async -> Catalog?
    /// Shows the request on the Mac and waits for Run or Don't Run. A cancelled task (the caller
    /// hung up) takes the question away.
    func approve(_ request: RunRequest) async -> Approval
    /// Starts an allowed request: its run's id (it shows on its cell and in Runs, as any run does).
    func start(_ request: RunRequest) async throws -> UUID
    func record(_ id: UUID) async -> RunRecord?
    /// A flow's steps, in order.
    func steps(of id: UUID) async -> [RunRecord]
    /// The latest top-level runs, newest first.
    func recent(_ limit: Int) async -> [RunRecord]
    /// Stops a run: false when it isn't running.
    func stop(_ id: UUID) async -> Bool
    /// The items that run by themselves, with their tags and next times.
    func automations() async -> [AutomationEntry]
    /// Tags the request's item as its `automation` says (the person allowed it): how it's
    /// automated now. Throws an `HTTPError` when the item is gone.
    func automate(_ request: RunRequest) async throws -> AutomationEntry
    /// Shows something to the person: a window in front of everything, with copy buttons.
    func present(_ p: Presentation) async throws
    /// Puts text on the clipboard.
    func copy(_ text: String) async throws
}

extension RunHost {
    /// A host with no automation (a pretend one): nothing is automated, and nothing can be.
    public func automations() async -> [AutomationEntry] { [] }

    public func automate(_ request: RunRequest) async throws -> AutomationEntry {
        throw HTTPError(status: 500, code: "failed", message: "automation isn't available here")
    }

    /// A host with no screen: nothing can be shown.
    public func present(_ p: Presentation) async throws {
        throw HTTPError(status: 501, code: "not_available", message: "showing things needs the Tool Mac Tool Run app on a Mac")
    }

    public func copy(_ text: String) async throws {
        throw HTTPError(status: 501, code: "not_available", message: "the clipboard needs the Tool Mac Tool Run app on a Mac")
    }
}

/// Something to show the person (POST /api/present, or "present": true on a read): its title,
/// its text and how to show it, where it's from, and who asked.
public struct Presentation: Sendable, Equatable {
    public enum Format: String, CaseIterable, Sendable {
        case markdown, text, json, mind
    }

    public var title: String
    public var text: String
    public var format: Format
    /// Where it's from, in words: "MEMORY/PEOPLE.md", "the mind", "Chrome: Cloudflare".
    public var source: String?
    /// The shelf and name it is, when it's a file (the window offers to open it on its board).
    public var shelf: Shelf?
    public var name: String?
    public var client: String
    public var why: String?

    public init(title: String, text: String, format: Format = .markdown, source: String? = nil, shelf: Shelf? = nil, name: String? = nil,
                client: String = "An app", why: String? = nil) {
        self.title = title
        self.text = text
        self.format = format
        self.source = source
        self.shelf = shelf
        self.name = name
        self.client = client
        self.why = why
    }
}

/// The HTTP API (see API.md): requests in, responses out. The server around it only moves bytes.
/// Nothing runs without the person clicking Run on the Mac: every run request waits for that.
public final class RunAPI: @unchecked Sendable {
    public let host: RunHost
    public let version: String
    /// Every request that reached the card, by its id (`GET /api/requests/{id}`).
    public let requests = RequestLedger()
    /// Every file library operation, by its id (`GET /api/library/operations/{id}`).
    public let libraryLog = LibraryLog()
    /// The file library it serves (LIBRARY, in TOOL-MAC-RUN on the Desktop).
    let library: @Sendable () -> FileLibrary
    /// MEMORY, the mind and SYSTEM-DOCS.
    let shelves: @Sendable () -> Shelves
    /// The page in front of Chrome.
    let chrome: ChromePage
    /// The web, read from this Mac.
    let web: Web
    private let settings: @Sendable () -> APISettings
    /// How often a run being waited for is looked at.
    var poll: UInt64 = 200_000_000

    public init(host: RunHost, version: String, library: @escaping @Sendable () -> FileLibrary = { FileLibrary() },
                shelves: @escaping @Sendable () -> Shelves = { Shelves() }, chrome: ChromePage = ChromePage(),
                web: Web = Web(), settings: @escaping @Sendable () -> APISettings) {
        self.host = host
        self.version = version
        self.library = library
        self.shelves = shelves
        self.chrome = chrome
        self.web = web
        self.settings = settings
    }

    func settingsNow() -> APISettings { settings() }

    public func handle(_ req: HTTPRequest) async -> HTTPResponse {
        let s = settings()
        if let refusal = Access.refusal(req, settings: s) { return failure(refusal) }
        let cors = Access.cors(req, settings: s)
        if req.method == "OPTIONS" { return HTTPResponse(status: 204, headers: cors) }
        var response: HTTPResponse
        do {
            response = try await route(req, s)
        } catch let e as HTTPError {
            response = failure(e)
        } catch {
            response = failure(HTTPError(status: 500, code: "failed", message: "\(error)"))
        }
        // What to call next, on every JSON answer that doesn't say already.
        APINext.add(to: &response, for: req)
        response.headers += cors
        return response
    }

    private static let routes: [String: String] = [
        "/": "GET", "/index.html": "GET", "/favicon.ico": "GET", "/api/health": "GET", "/api/doc": "GET",
        "/api": "GET", "/api/endpoints": "GET", "/api/search": "GET",
        "/api/scripts": "GET", "/api/flows": "GET", "/api/runs": "GET", "/api/requests": "GET",
        "/api/run": "POST", "/api/compose": "POST", "/api/check": "POST",
    ]

    func route(_ req: HTTPRequest, _ s: APISettings) async throws -> HTTPResponse {
        var path = req.path
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if path.hasPrefix("/api/runs/") { return try await runRoute(req, path: path, s) }
        if path.hasPrefix("/api/requests/") { return try await requestRoute(req, path: path, s) }
        if path == "/api/automation" { return try await automationRoute(req, s) }
        for shelf in Shelf.allCases where path == shelf.apiPath || path.hasPrefix(shelf.apiPath + "/") { return try await shelfRoute(shelf, req, path: path, s) }
        if path == "/api/mind" || path.hasPrefix("/api/mind/") { return try await mindRoute(req, path: path, s) }
        if path == "/api/browser" || path.hasPrefix("/api/browser/") { return try await browserRoute(req, path: path, s) }
        if path == "/api/present" || path == "/api/clipboard" { return try await screenRoute(req, path: path, s) }
        if path == "/api/straw" || path.hasPrefix("/api/straw/") { return try await strawRoute(req, path: path, s) }
        if path == "/api/web" || path.hasPrefix("/api/web/") { return try await webRoute(req, path: path, s) }
        if path == "/api/tools" || path.hasPrefix("/api/tools/") { return try await toolsRoute(req, path: path, s) }
        guard let method = Self.routes[path] else {
            throw HTTPError(status: 404, code: "not_found", message: "no such route: \(req.path) (GET /api/endpoints lists every route)")
        }
        try allow(req, method, path)
        switch path {
        case "/", "/index.html":
            return HTTPResponse(contentType: "text/html; charset=utf-8", data: Data(StatusPage.html.utf8))
        case "/favicon.ico":
            return HTTPResponse(status: 204)
        case "/api/health":
            return JSON.response(await health(s))
        case "/api/search":
            return try await search(req, s)
        case "/api", "/api/endpoints":
            // Words to look for: only what matches (the same as /api/search, routes alone).
            if let q = req.query["q"], !q.trimmingCharacters(in: .whitespaces).isEmpty {
                var r = req
                r.query["in"] = r.query["in"] ?? "routes"
                return try await search(r, s)
            }
            // The groups alone, without their routes: small, for a client to look deeper from.
            if Self.flag(req.query["brief"]) {
                return JSON.response(["ok": true, "version": version, "count": APIRoutes.all.count, "doc": "/api/doc",
                                      "groups": APISearch.brief(settings: s),
                                      "next": [APINext.search.json,
                                               APINext.Hint("GET", "/api/endpoints?group={id}", "one group's routes").json]])
            }
            // Every route, in its groups (?group=library: one of them).
            var groups = APIRoutes.groups
            if let wanted = req.query["group"] {
                groups = groups.filter { $0.id == wanted.lowercased() }
                if groups.isEmpty {
                    throw HTTPError(status: 400, code: "unknown_group", message: "there's no group called \(wanted); the groups: \(APIRoutes.groups.map(\.id).joined(separator: ", "))")
                }
            }
            return JSON.response(["ok": true, "version": version, "count": groups.reduce(0) { $0 + $1.routes.count },
                                  "doc": "/api/doc", "groups": groups.map { APIRoutes.json($0, settings: s) }])
        case "/api/doc":
            // The API in one page, with this server's own address (and token, for a caller on the network).
            let doc = APIDoc.text(baseURL: Access.baseURL(req, settings: s), token: s.allowNetwork ? s.token : nil, version: version)
            return HTTPResponse(contentType: "text/markdown; charset=utf-8", data: Data(doc.utf8))
        case "/api/scripts":
            try need(.catalog, s)
            let c = try await catalog()
            // ?group=utilities (or scripts, browser): one grid's scripts only.
            let group = req.query["group"].flatMap { GridKind(rawValue: $0) }
            if let wanted = req.query["group"], group == nil || group?.isFlow == true {
                throw HTTPError(status: 400, code: "unknown_group", message: "there's no group of scripts called \(wanted); the groups: \(GridKind.scriptGrids.map(\.rawValue).joined(separator: ", "))")
            }
            let scripts = c.scripts.filter { group == nil || $0.grid == group }
            return JSON.response(["folder": c.folder.path, "scripts": scripts.map(Self.scriptJSON)])
        case "/api/flows":
            try need(.catalog, s)
            let c = try await catalog()
            return JSON.response(["folder": c.composerPath, "flows": c.flows.map(Self.flowJSON)])
        case "/api/runs":
            try need(.runs, s)
            let limit = min(300, max(1, Int(req.query["limit"] ?? "") ?? 20))
            var runs: [[String: Any]] = []
            for r in await host.recent(limit) {
                var out = Self.runJSON(r, output: false)
                if let request = await requests.request(forRun: r.id) { out["request"] = request.uuidString }
                runs.append(out)
            }
            return JSON.response(["runs": runs])
        case "/api/requests":
            try need(.runs, s)
            let limit = min(500, max(1, Int(req.query["limit"] ?? "") ?? 20))
            var list: [[String: Any]] = []
            for e in await requests.recent(limit) { list.append(await requestJSON(e, run: false)) }
            return JSON.response(["requests": list])
        case "/api/run":
            try need(.run, s)
            return try await runScript(req)
        case "/api/compose":
            try need(.compose, s)
            return try await compose(req)
        case "/api/check":
            try need(.compose, s)
            return try await check(req)
        default:
            throw HTTPError(status: 404, code: "not_found", message: "no such route: \(req.path)")
        }
    }

    private func allow(_ req: HTTPRequest, _ method: String, _ path: String) throws {
        guard req.method == method || (method == "GET" && req.method == "HEAD") else {
            throw HTTPError(status: 405, code: "bad_request", message: "\(path) takes \(method)")
        }
    }

    /// /api/runs/{id} and /api/runs/{id}/stop.
    private func runRoute(_ req: HTTPRequest, path: String, _ s: APISettings) async throws -> HTTPResponse {
        try need(.runs, s)
        let parts = path.dropFirst("/api/runs/".count).split(separator: "/").map(String.init)
        guard let first = parts.first, let id = UUID(uuidString: first), parts.count <= 2 else {
            throw HTTPError(status: 404, code: "not_found", message: "no such route: \(req.path) (a run is /api/runs/<its id>)")
        }
        if parts.count == 2 {
            guard parts[1] == "stop" else { throw HTTPError(status: 404, code: "not_found", message: "no such route: \(req.path)") }
            try allow(req, "POST", path)
            guard let record = await host.record(id) else { throw unknownRun(id) }
            // A run another app asked for (and the person allowed) stops at once. One the person
            // started (its cell, a flow, a schedule) is theirs: they're asked first, on the card.
            guard record.state == .running, await requests.request(forRun: id) == nil else {
                return JSON.response(["ok": true, "stopping": await host.stop(id)])
            }
            let fields = try body(req)
            let started = record.requestedBy.map { "started by \($0)" } ?? "started on the Mac"
            let request = RunRequest(what: .stop(id), name: record.name, client: Self.client(req, fields), from: Self.from(req),
                                     command: "stop \(record.name) (\(started), running \(RunRecord.duration(Date().timeIntervalSince(record.started))))",
                                     why: Self.why(fields))
            await requests.add(request, via: "stop")
            do {
                try await approve(request)
            } catch let e as HTTPError {
                return await refused(e, request)
            }
            await requests.set(request.id, .stopped(id))
            await requests.clear(request.id, .delivered)
            return JSON.response(["ok": true, "stopping": await host.stop(id), "request": request.id.uuidString,
                                  "next": [APINext.Hint("GET", "/api/runs/\(id.uuidString)", "the run, with what it printed before it stopped").json]],
                                 headers: [("X-Request-Id", request.id.uuidString)])
        }
        try allow(req, "GET", path)
        guard let r = await host.record(id) else { throw unknownRun(id) }
        var out = Self.runJSON(r, steps: await host.steps(of: id))
        if let request = await requests.request(forRun: id) { out["request"] = request.uuidString }
        return JSON.response(out)
    }

    /// /api/requests/open, /api/requests/clear, and /api/requests/{id}: where a request is, from
    /// the moment it arrived. Once it's over, the first read hands over its result and clears
    /// it; read again, it says how it ended, without the output.
    private func requestRoute(_ req: HTTPRequest, path: String, _ s: APISettings) async throws -> HTTPResponse {
        try need(.runs, s)
        let parts = path.dropFirst("/api/requests/".count).split(separator: "/").map(String.init)
        if parts == ["open"] {
            try allow(req, "GET", path)
            return JSON.response(await openRequests())
        }
        if parts == ["clear"] {
            try allow(req, "POST", path)
            return try await clearRequests(req)
        }
        guard parts.count == 1, let id = UUID(uuidString: parts[0]) else {
            throw HTTPError(status: 404, code: "not_found", message: "no such route: \(req.path) (a request is /api/requests/<its id>; the open ones are /api/requests/open)")
        }
        if req.method == "DELETE" { return try await dismiss(id) }
        try allow(req, "GET", path)
        guard let e = await requests.entry(id) else {
            // A library operation's id answers here too.
            if let op = await libraryLog.entry(id) { return JSON.response(LibraryLog.json(op), headers: [("X-Request-Id", id.uuidString)]) }
            throw HTTPError(status: 404, code: "unknown_request",
                            message: "no request \(id.uuidString) (the latest \(requests.capacity) are kept while the app runs)")
        }
        let peek = Self.flag(req.query["peek"])
        var out = await requestJSON(e, run: e.cleared == nil)
        let delivery = await delivery(e)
        out["delivery"] = delivery
        switch delivery {
        case "ready" where !peek:
            await requests.clear(id, .collected)
            out["delivery"] = "delivered"
            out["note"] = "This is its result, handed over once: it's cleared now. Asked about again, it says how it ended, without the output."
        case "ready":
            out["note"] = "Over, and ready to collect: read it without ?peek=true to take it (it's cleared then)."
        case "cleared":
            if let cleared = e.cleared { out["cleared"] = JSON.date(cleared) }
            out["cleared_by"] = e.clearedBy?.rawValue
            out["note"] = (e.clearedBy == .dismissed
                ? "Cleared without being read: this is how it ended, without the output."
                : "Its result was handed over already, so it's cleared: this is how it ended, without the output.")
                + (e.runID != nil ? " The run itself is at run_url while the app keeps it." : "")
        default:
            break
        }
        out["next"] = await requestNext(e, delivery: out["delivery"] as? String ?? delivery).map(\.json)
        return JSON.response(out, headers: [("X-Request-Id", id.uuidString)])
    }

    /// Where a request's result is: `pending` (waiting or running: nothing to collect yet),
    /// `ready` (over, not collected), or `cleared` (handed over, or cleared without it).
    func delivery(_ e: RequestLedger.Entry) async -> String {
        if e.cleared != nil { return "cleared" }
        switch e.outcome {
        case .waiting: return "pending"
        case let .running(id):
            guard let r = await host.record(id) else { return "ready" }
            return r.state.finished ? "ready" : "pending"
        default: return "ready"
        }
    }

    /// GET /api/requests/open: the requests not cleared yet, in the order they came, each with
    /// where it is; what's ready to collect, counted.
    private func openRequests() async -> [String: Any] {
        var list: [[String: Any]] = []
        var waiting = 0, running = 0, ready = 0
        var next: [APINext.Hint] = []
        for (k, e) in await requests.open().enumerated() {
            var out = await requestJSON(e, run: false)
            let delivery = await delivery(e)
            out["position"] = k + 1
            out["delivery"] = delivery
            let state = out["state"] as? String ?? ""
            if delivery == "ready" {
                ready += 1
                if next.count < 3 { next.append(APINext.Hint("GET", "/api/requests/\(e.id.uuidString)", "collect \(e.request.name)'s result (\(state)): it's handed over once, then cleared")) }
            } else if state == "waiting" {
                waiting += 1
            } else {
                running += 1
            }
            list.append(out)
        }
        if waiting + running > 0 {
            next.append(APINext.Hint("GET", "/api/requests/open", "ask again in a few seconds: \(waiting) waiting for a click on the Mac, \(running) running"))
        }
        if ready > 1 { next.append(APINext.Hint("POST", "/api/requests/clear", "clear every one that's over without reading them")) }
        if list.isEmpty { next.append(APINext.Hint("GET", "/api/search?q={words}", "nothing open: find something to run, by a few words")) }
        return ["ok": true, "count": list.count, "waiting": waiting, "running": running, "ready": ready, "requests": list,
                "order": "oldest first", "next": next.map(\.json)]
    }

    /// DELETE /api/requests/{id}: cleared without being read; one still waiting for the click
    /// (sent with "async": true) is taken back, and the card goes.
    private func dismiss(_ id: UUID) async throws -> HTTPResponse {
        guard let e = await requests.entry(id) else {
            throw HTTPError(status: 404, code: "unknown_request", message: "no request \(id.uuidString) (the latest \(requests.capacity) are kept while the app runs)")
        }
        let tagged = [("X-Request-Id", id.uuidString)]
        switch await delivery(e) {
        case "pending":
            if case .waiting = e.outcome {
                guard await requests.withdraw(id) else {
                    throw HTTPError(status: 409, code: "still_waiting",
                                    message: "\(e.request.name) is waiting for a click on the Mac, and the call that sent it is still waiting on it: hang that call up to take it back")
                }
                return JSON.response(["ok": true, "request": id.uuidString, "state": "withdrawn", "delivery": "cleared",
                                      "note": "Taken back: the card is gone from the Mac and nothing runs.",
                                      "next": [APINext.Hint("GET", "/api/requests/open", "the requests still open").json]], headers: tagged)
            }
            let stop = e.runID.map { "/api/runs/\($0.uuidString)/stop" } ?? "/api/runs"
            throw HTTPError(status: 409, code: "still_running", message: "\(e.request.name) is running: stop it first (POST \(stop)), or collect it once it's over")
        default:
            // "ok" stays the request's own (how it ended); "cleared" says this worked.
            await requests.clear(id, .dismissed)
            let now = await requests.entry(id) ?? e
            var out = await requestJSON(now, run: false)
            out["delivery"] = "cleared"
            if let cleared = now.cleared { out["cleared"] = JSON.date(cleared) }
            out["cleared_by"] = now.clearedBy?.rawValue
            out["next"] = [APINext.Hint("GET", "/api/requests/open", "the requests still open").json]
            return JSON.response(out, headers: tagged)
        }
    }

    /// POST /api/requests/clear: every request that's over and not collected (or the ones
    /// named, {"requests": [ids]}), cleared without being read.
    private func clearRequests(_ req: HTTPRequest) async throws -> HTTPResponse {
        let fields = try body(req)
        let named = (fields["requests"] as? [Any] ?? fields["ids"] as? [Any])?.compactMap { Self.text($0).flatMap(UUID.init(uuidString:)) }
        var cleared: [String] = [], left: [[String: Any]] = []
        for e in await requests.open() where named == nil || named!.contains(e.id) {
            if await delivery(e) == "ready" {
                await requests.clear(e.id, .dismissed)
                cleared.append(e.id.uuidString)
            } else {
                left.append(["request": e.id.uuidString, "name": e.request.name, "why": "not over yet"])
            }
        }
        return JSON.response(["ok": true, "cleared": cleared, "count": cleared.count, "still_open": left,
                              "next": [APINext.Hint("GET", "/api/requests/open", "the requests still open").json]])
    }

    /// What to call after reading a request, by where it is.
    func requestNext(_ e: RequestLedger.Entry, delivery: String) async -> [APINext.Hint] {
        let url = "/api/requests/\(e.id.uuidString)"
        var out: [APINext.Hint] = []
        switch delivery {
        case "pending":
            if case .waiting = e.outcome {
                out.append(APINext.Hint("GET", url, "ask again in a few seconds: it's on the Mac, waiting for the person to click (no click in two minutes is Don't Run)"))
                if await requests.holds(e.id) { out.append(APINext.Hint("DELETE", url, "take it back: the card goes, nothing runs")) }
            } else {
                out.append(APINext.Hint("GET", url, "ask again in a few seconds: it's running (run.output is what it has printed so far)"))
                if let run = e.runID { out.append(APINext.Hint("POST", "/api/runs/\(run.uuidString)/stop", "stop it")) }
            }
        case "ready":
            out.append(APINext.Hint("GET", url, "take its result: it's handed over once, then cleared"))
        default:
            if let run = e.runID { out.append(APINext.Hint("GET", "/api/runs/\(run.uuidString)", "the run again, with everything it printed, while the app keeps it")) }
            switch e.outcome {
            case .denied, .notAnswered, .withdrawn:
                out.append(APINext.Hint("POST", "/api/\(e.via == "automation" ? "automation" : e.via == "stop" ? "runs/{id}/stop" : e.via)", "ask again, only if the person wants it (say why, in \"why\")"))
            case .automated:
                out.append(APINext.Hint("GET", "/api/automation", "what runs by itself now"))
            default: break
            }
        }
        out.append(APINext.Hint("GET", "/api/requests/open", "every request not collected yet, oldest first"))
        return out
    }

    /// A request as the API gives it: its state (`waiting`, `denied`, `not_answered`, `running`,
    /// then how its run ended, or `automated`), who asked and why, and (with `run`) the run itself.
    func requestJSON(_ e: RequestLedger.Entry, run: Bool = true) async -> [String: Any] {
        let r = e.request
        var out: [String: Any] = [
            "request": e.id.uuidString, "name": r.name, "kind": r.kindName,
            "via": e.via, "client": r.client, "from": r.from, "asked": JSON.date(e.asked), "url": "/api/requests/\(e.id.uuidString)",
        ]
        if let why = r.why { out["why"] = why }
        if let answered = e.answered { out["answered"] = JSON.date(answered) }
        switch e.outcome {
        case .waiting:
            out["state"] = "waiting"
            out["message"] = r.isStop ? "On the Mac, waiting for Stop It" : r.automation == nil ? "On the Mac, waiting for Run" : "On the Mac, waiting for Allow"
        case .denied:
            let err = Self.denied(r)
            out["state"] = "denied"; out["ok"] = false; out["code"] = err.code; out["error"] = err.message
        case .notAnswered:
            let err = Self.unanswered(r)
            out["state"] = "not_answered"; out["ok"] = false; out["code"] = err.code; out["error"] = err.message
        case .automated:
            out["state"] = "automated"; out["ok"] = true
        case let .stopped(id):
            out["state"] = "stopped"; out["ok"] = true
            out["run_id"] = id.uuidString
            out["run_url"] = "/api/runs/\(id.uuidString)"
        case let .failed(err):
            out["state"] = "could_not_start"; out["ok"] = false; out["code"] = err.code; out["error"] = err.message
        case .withdrawn:
            out["state"] = "withdrawn"; out["ok"] = false; out["error"] = "\(r.name) was taken back by the app that asked, before anyone clicked"
        case let .running(id):
            out["run_id"] = id.uuidString
            out["run_url"] = "/api/runs/\(id.uuidString)"
            if let record = await host.record(id) {
                out["state"] = Self.stateName(record.state)
                if record.state.finished { out["ok"] = record.state == .succeeded }
                if run {
                    var runOut = Self.runJSON(record, steps: await host.steps(of: id))
                    runOut["request"] = e.id.uuidString
                    out["run"] = runOut
                }
            } else {
                out["state"] = "gone"
                out["error"] = "the run was cleared from the app's history (Clear Finished)"
            }
        }
        return out
    }

    /// GET /api/automation: the tags there are, and the items that run by themselves. POST: tags
    /// a script or a flow (the same as /api/run or /api/compose with "automation"), once Run is
    /// clicked on the Mac.
    private func automationRoute(_ req: HTTPRequest, _ s: APISettings) async throws -> HTTPResponse {
        switch req.method {
        case "GET", "HEAD":
            try need(.catalog, s)
            _ = try await catalog()
            let tags = AutomationTag.allCases.map { ["name": $0.rawValue, "title": $0.title, "kind": $0.kind.rawValue, "about": $0.about] }
            let items = await host.automations().map(Self.automationJSON)
            return JSON.response(["tags": tags, "items": items])
        case "POST":
            let fields = try body(req)
            guard fields["automation"] != nil || fields["tags"] != nil else {
                throw HTTPError(status: 400, code: "bad_request",
                                message: "send {\"script\": \"<name>\" or \"flow\": \"<name>\", \"automation\": [\"every morning\"]} (an empty list takes its automation off); GET /api/automation lists the tags")
            }
            if Self.text(fields["flow"]) != nil {
                try need(.compose, s)
                return try await compose(req, fields: fields)
            }
            try need(.run, s)
            return try await runScript(req, fields: fields)
        default:
            throw HTTPError(status: 405, code: "bad_request", message: "/api/automation takes GET or POST")
        }
    }

    private func unknownRun(_ id: UUID) -> HTTPError {
        HTTPError(status: 404, code: "unknown_run", message: "no run \(id.uuidString) (runs are kept until Clear Finished, the latest 300)")
    }

    func need(_ e: APIEndpoint, _ s: APISettings) throws {
        guard s.isOn(e) else {
            throw HTTPError(status: 503, code: "endpoint_off", message: "\(e.title.lowercased()) is turned off in Tool Mac Tool Run")
        }
    }

    func catalog() async throws -> Catalog {
        guard let c = await host.catalog() else {
            throw HTTPError(status: 409, code: "no_folder",
                            message: "no scripts folder is chosen yet: click Tool Mac Tool Run's icon in the menu bar and choose one")
        }
        return c
    }

    // MARK: Search

    /// GET /api/search?q=words: the routes, scripts and flows that match, the best first, each
    /// with how to call it (?in=routes,scripts,flows; ?group=memory; ?limit=10, at most 50).
    private func search(_ req: HTTPRequest, _ s: APISettings) async throws -> HTTPResponse {
        guard let q = (req.query["q"] ?? req.query["query"])?.trimmingCharacters(in: .whitespaces), !q.isEmpty else {
            throw HTTPError(status: 400, code: "missing_query",
                            message: "send ?q= and a few words of what you want to do (?q=remember a birthday, ?q=run a script, ?q=status of a request)")
        }
        var scopes = Set(APISearch.Scope.allCases)
        if let wanted = req.query["in"] {
            let named = wanted.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            scopes = Set(named.compactMap(APISearch.Scope.init(rawValue:)))
            guard scopes.count == named.count, !scopes.isEmpty else {
                throw HTTPError(status: 400, code: "bad_request", message: "?in= takes \(APISearch.Scope.allCases.map(\.rawValue).joined(separator: ", ")) (one, or several with commas)")
            }
        }
        let group = req.query["group"]?.lowercased()
        if let group, !APIRoutes.groups.contains(where: { $0.id == group }) {
            throw HTTPError(status: 400, code: "unknown_group", message: "there's no group called \(group); the groups: \(APIRoutes.groups.map(\.id).joined(separator: ", "))")
        }
        let limit = min(50, max(1, Int(req.query["limit"] ?? "") ?? 10))
        // Scripts and flows only while the catalog is on and a folder is chosen; routes always.
        let catalog = s.isOn(.catalog) && (scopes.contains(.scripts) || scopes.contains(.flows)) ? await host.catalog() : nil
        let (hits, total) = APISearch.search(q, scopes: scopes, group: group, catalog: catalog, settings: s, limit: limit)
        let results: [[String: Any]] = hits.map { h in
            var out = h.json
            out["kind"] = h.kind
            out["matched"] = h.matched
            out["score"] = h.score
            return out
        }
        var next: [APINext.Hint] = []
        if let top = hits.first {
            if top.kind == "tool", let name = top.json["name"] as? String {
                next.append(APINext.Hint("POST", "/api/tools/\(name)", "call the best match, the \(name) tool {\"arguments\": {…}}"))
            } else if top.kind == "route", let path = top.json["path"] as? String, let method = top.json["method"] as? String {
                next.append(APINext.Hint(method, path, "the best match: \(top.json["summary"] as? String ?? "")"))
                if let g = top.json["group"] as? String { next.append(APINext.Hint("GET", "/api/endpoints?group=\(g)", "the rest of its group's routes")) }
            } else if let run = top.json["run"] as? [String: Any], let path = run["path"] as? String {
                next.append(APINext.Hint("POST", path, "run the best match, \(top.json["name"] as? String ?? ""), with the body its \"run\" gives (it waits for Run on the Mac; send \"async\": true and keep the request id)"))
            }
        } else {
            next.append(APINext.Hint("GET", "/api/endpoints?brief=true", "nothing matched: the groups, each with the words it's found by"))
        }
        if total > hits.count { next.append(APINext.Hint("GET", "/api/search?q=\(q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q)&limit=\(min(50, total))", "all \(total) matches")) }
        return JSON.response(["ok": true, "q": q, "words": APISearch.query(q), "count": results.count, "total": total,
                              "results": results, "lines": hits.map(Self.line), "next": next.map(\.json)])
    }

    /// A string as JSON writes it, quotes and all ("a \"b\"").
    static func jsonString(_ s: String) -> String {
        let d = JSON.data([s])
        return String(String(decoding: d, as: UTF8.self).dropFirst().dropLast())
    }

    /// A query's true or false: "true", "1", "yes" (or there with nothing after it).
    static func flag(_ value: String?) -> Bool {
        guard let v = value?.lowercased() else { return false }
        return ["", "true", "1", "yes"].contains(v)
    }

    // MARK: Health

    private func health(_ s: APISettings) async -> [String: Any] {
        var out: [String: Any] = [
            "ok": true, "service": "toolmactoolrun", "version": version,
            "approval": "each run waits for a click on Run, on the Mac",
        ]
        if let c = await host.catalog() {
            out["folder"] = c.folder.path
            out["scripts"] = c.scripts.count
            out["flows"] = c.flows.count
            out["automated"] = await host.automations().count
        } else {
            out["folder"] = NSNull()
        }
        // Each switch, by its name; and the shelves, where they are.
        for e in APIEndpoint.allCases { out[e.rawValue] = s.isOn(e) }
        // The requests not collected yet: what a client coming back has to pick up.
        var waiting = 0, running = 0, ready = 0
        for e in await requests.open() {
            switch await delivery(e) {
            case "ready": ready += 1
            default: if case .waiting = e.outcome { waiting += 1 } else { running += 1 }
            }
        }
        out["requests"] = ["open": waiting + running + ready, "waiting": waiting, "running": running, "ready": ready, "list": "/api/requests/open"]
        let sh = shelves()
        out["home"] = Home.root.path
        out["shelves"] = [
            "library": ["folder": library().root.path, "notes": library().list().count, "approval": "none (answered at once)"] as [String: Any],
            "memory": ["folder": sh.memory.files.root.path, "files": sh.memory.files.list().count, "approval": "none (answered at once)"] as [String: Any],
            "system-docs": ["folder": sh.systemDocs.root.path, "docs": sh.systemDocs.list().count, "approval": "none (read only)"] as [String: Any],
            "mind": ["file": sh.mind.file.path, "nodes": sh.mind.graph().nodes.count, "approval": "none (append only)"] as [String: Any],
        ]
        return out
    }

    // MARK: Running

    private func runScript(_ req: HTTPRequest, fields given: [String: Any]? = nil) async throws -> HTTPResponse {
        let fields = try given ?? body(req)
        guard let name = Self.text(fields["script"]) ?? Self.text(fields["name"]), !name.isEmpty else {
            throw HTTPError(status: 400, code: "missing_script", message: "send {\"script\": \"<its file name>\"} (GET /api/scripts lists them)")
        }
        let c = try await catalog()
        guard let match = ScriptNames.match(name, in: c.scripts.map(\.id)), let item = c.scripts.first(where: { $0.id == match }) else {
            throw HTTPError(status: 404, code: "unknown_script",
                            message: "no script named \(name) in \(c.folder.path); the scripts: \(Self.names(c.scripts))")
        }
        let args = try Self.arguments(fields)
        let command = ScriptProcess(script: item.url, language: item.language, arguments: args,
                                    workingDirectory: c.folder, environment: [:]).commandLine
        let stdin = fields["stdin"].map { Self.text($0) ?? "" }
        let request = RunRequest(what: .script(item), name: item.id, arguments: args, stdin: stdin,
                                 client: Self.client(req, fields), from: Self.from(req), command: command, dangers: item.dangers,
                                 why: Self.why(fields), automation: try Self.automation(fields, items: c.scripts + c.flows))
        return try await execute(request, fields, via: given == nil ? "run" : "automation")
    }

    private func compose(_ req: HTTPRequest, fields given: [String: Any]? = nil) async throws -> HTTPResponse {
        let fields = try given ?? body(req, plainTextAs: "source")
        let c = try await catalog()
        let names = c.scripts.map(\.id) + c.flows.map(\.id)
        let args = try Self.arguments(fields)
        let what: RunRequest.What
        let name: String
        let source: String
        let command: String
        if let code = Self.text(fields["source"]) ?? Self.text(fields["code"]), !code.isEmpty {
            source = code
            name = Self.clean(Self.text(fields["name"]) ?? "", limit: 60).nonEmpty ?? "Flow sent by \(Self.client(req, fields))"
            what = .source(code)
            let lines = code.split(whereSeparator: \.isNewline).count
            command = "flow code sent over the API (\(lines) line\(lines == 1 ? "" : "s"))"
        } else if let flowName = Self.text(fields["flow"]) ?? Self.text(fields["name"]), !flowName.isEmpty {
            guard let match = ScriptNames.match(flowName, in: c.flows.map(\.id)), let item = c.flows.first(where: { $0.id == match }) else {
                throw HTTPError(status: 404, code: "unknown_flow", message: "no flow named \(flowName); the flows: \(Self.names(c.flows))")
            }
            do {
                source = try String(contentsOf: item.url, encoding: .utf8)
            } catch {
                throw HTTPError(status: 500, code: "failed", message: "couldn't read \(item.id): \(error.localizedDescription)")
            }
            name = item.id
            what = .flow(item)
            command = (["flow", "run", item.url.path] + args).map(ShellEnvironment.quote).joined(separator: " ")
        } else {
            throw HTTPError(status: 400, code: "missing_flow",
                            message: "send {\"flow\": \"<its file name>\"} (GET /api/flows lists them), or {\"source\": \"<Flow code>\"}")
        }
        // A mistake is said now, before the person is asked about something that can't run.
        do {
            _ = try Flow.check(source, scripts: names)
        } catch let e as FlowError {
            return Self.flowMistake(e)
        }
        let automation = try Self.automation(fields, items: c.scripts + c.flows)
        if automation != nil, case .source = what {
            throw HTTPError(status: 400, code: "bad_request", message: "only a flow from the folder can be automated: send {\"flow\": \"<its name>\", \"automation\": […]}")
        }
        let request = RunRequest(what: what, name: name, arguments: args, client: Self.client(req, fields),
                                 from: Self.from(req), command: command, dangers: Self.flowDangers(source, scripts: c.scripts),
                                 why: Self.why(fields), automation: automation)
        return try await execute(request, fields, via: given == nil ? "compose" : "automation")
    }

    /// Checks Flow code (nothing runs, nothing is asked): its types, or its mistake.
    private func check(_ req: HTTPRequest) async throws -> HTTPResponse {
        let fields = try body(req, plainTextAs: "source")
        guard let code = Self.text(fields["source"]) ?? Self.text(fields["code"]) else {
            throw HTTPError(status: 400, code: "missing_flow", message: "send {\"source\": \"<Flow code>\"}")
        }
        let c = try await catalog()
        do {
            let checked = try Flow.check(code, scripts: c.scripts.map(\.id) + c.flows.map(\.id))
            return JSON.response(["ok": true, "bindings": checked.bindings.map { ["name": $0.name, "type": $0.type, "line": $0.line] }])
        } catch let e as FlowError {
            return Self.flowMistake(e, status: 200)
        }
    }

    /// What a flow looks like it does that can't be undone: in its own code (a `shell` line), and
    /// in each script it runs, by name ("runs cleanup.sh, which deletes files for good"). The
    /// card shows them in red, as it does a script's.
    static func flowDangers(_ source: String, scripts: [ScriptItem]) -> [String] {
        var found = Caution.dangers(in: source)
        let ids = scripts.map(\.id)
        let pattern = #"\b(run|attempt|pipe|attemptPipe)\s+"([^"\n]+)""#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return found }
        var seen: Set<String> = []
        for m in re.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            guard let r = Range(m.range(at: 2), in: source), let id = ScriptNames.match(String(source[r]), in: ids),
                  seen.insert(id).inserted, let item = scripts.first(where: { $0.id == id }) else { continue }
            found += item.dangers.map { "runs \(item.id), which \($0)" }
        }
        return found
    }

    private static func flowMistake(_ e: FlowError, status: Int = 400) -> HTTPResponse {
        var out: [String: Any] = ["ok": false, "code": "flow_mistake", "error": e.description, "message": e.message]
        if let line = e.pos?.line { out["line"] = line }
        if let fix = e.fix { out["fix"] = fix }
        return JSON.response(out, status: status)
    }

    /// Asks on the Mac, then runs it: waiting for it to end (the default), answering at once
    /// (`"wait": false`: once it has started; `"async": true`: before anyone has clicked), or
    /// sending what it prints as it prints it (`"stream": true`). Every way, the request's id goes
    /// back (`X-Request-Id`, and `request` in the JSON), and `GET /api/requests/{id}` has the rest.
    func execute(_ request: RunRequest, _ fields: [String: Any], via: String) async throws -> HTTPResponse {
        await requests.add(request, via: via)
        let id = request.id.uuidString
        let tagged: [(String, String)] = [("X-Request-Id", id)]
        // Tagging it to run by itself: asked about the same way, then tagged rather than run.
        if request.automation != nil {
            do {
                try await approve(request)
                let entry: AutomationEntry
                do {
                    entry = try await host.automate(request)
                } catch let e as HTTPError {
                    await requests.set(request.id, .failed(e))
                    throw e
                }
                await requests.set(request.id, .automated)
                await requests.clear(request.id, .delivered)
                var out = Self.automationJSON(entry)
                out["ok"] = true
                out["automated"] = true
                out["request"] = id
                out["next"] = [APINext.Hint("GET", "/api/automation", "what runs by itself now").json]
                return JSON.response(out, headers: tagged)
            } catch let e as HTTPError {
                return await refused(e, request)
            }
        }
        if fields["stream"] as? Bool == true { return stream(request) }
        let url = "/api/requests/\(id)"
        if fields["async"] as? Bool == true {
            // Answered now; the card stays on the Mac, and the run (if allowed) goes on without the
            // caller: a task of its own, which the caller hanging up doesn't cancel (but taking
            // the request back, DELETE /api/requests/{id}, does).
            let asking = Task { [self] in
                _ = try? await self.approveAndStart(request)
                await self.requests.release(request.id)
            }
            await requests.hold(request.id, asking)
            return JSON.response(["request": id, "state": "waiting", "url": url, "delivery": "pending",
                                  "message": "On the Mac, waiting for Run; GET \(url) says how it goes",
                                  "note": "Keep the request id: ask about it any time. Once it's over, the first read hands over its result and clears it.",
                                  "next": [APINext.Hint("GET", url, "where it is: ask every few seconds; once it's over, this hands over the result (once)").json,
                                           APINext.Hint("DELETE", url, "take it back while it waits: the card goes, nothing runs").json,
                                           APINext.Hint("GET", "/api/requests/open", "every request not collected yet, oldest first").json]],
                                 status: 202, headers: tagged)
        }
        let runID: UUID
        do {
            runID = try await approveAndStart(request)
        } catch let e as HTTPError {
            return await refused(e, request)
        }
        if fields["wait"] as? Bool == false {
            return JSON.response(["id": runID.uuidString, "request": id, "state": "running", "url": "/api/runs/\(runID.uuidString)", "delivery": "pending",
                                  "next": [APINext.Hint("GET", url, "where it is; once it's over, this hands over the result (once)").json,
                                           APINext.Hint("POST", "/api/runs/\(runID.uuidString)/stop", "stop it").json]],
                                 status: 202, headers: tagged)
        }
        let (run, steps) = try await finish(runID)
        // The result goes back in this answer: handed over, so it's cleared.
        await requests.clear(request.id, .delivered)
        var out = Self.runJSON(run, steps: steps)
        out["request"] = id
        out["delivery"] = "delivered"
        out["next"] = [APINext.Hint("GET", "/api/runs/\(runID.uuidString)", "this run again, while the app keeps it").json,
                       APINext.Hint("GET", "/api/requests/open", "every request not collected yet, oldest first").json]
        return JSON.response(out, headers: tagged)
    }

    /// Waits for the click, recording how it went; throws `denied` or `not_answered`.
    private func approve(_ request: RunRequest) async throws {
        switch await host.approve(request) {
        case .allowed: break
        case .denied:
            await requests.set(request.id, .denied)
            throw Self.denied(request)
        case .unanswered:
            await requests.set(request.id, .notAnswered)
            throw Self.unanswered(request)
        }
    }

    /// Waits for the click, then starts it: the run's id. The ledger follows along.
    private func approveAndStart(_ request: RunRequest) async throws -> UUID {
        try await approve(request)
        do {
            let id = try await host.start(request)
            await requests.set(request.id, .running(id))
            return id
        } catch let e as HTTPError {
            await requests.set(request.id, .failed(e))
            throw e
        } catch {
            let e = HTTPError(status: 500, code: "failed", message: "\(error)")
            await requests.set(request.id, .failed(e))
            throw e
        }
    }

    /// A request that didn't run (or wasn't automated), with its id still: the app can ask
    /// `/api/requests/{id}` later and get the same answer.
    private func refused(_ e: HTTPError, _ request: RunRequest) async -> HTTPResponse {
        // Said here and now: handed over, so it's cleared.
        await requests.clear(request.id, .delivered)
        var next = [APINext.Hint("GET", "/api/requests/open", "every request not collected yet, oldest first")]
        if e.code == "not_answered" { next.insert(APINext.Hint("POST", "/api/\(request.isStop ? "runs/{id}/stop" : request.automation != nil ? "automation" : request.isScript ? "run" : "compose")", "send it again, if the person still wants it: they have two minutes to click"), at: 0) }
        return JSON.response(["error": e.message, "code": e.code, "request": request.id.uuidString, "delivery": "delivered", "next": next.map(\.json)],
                             status: e.status, headers: [("X-Request-Id", request.id.uuidString)])
    }

    static func denied(_ r: RunRequest) -> HTTPError {
        HTTPError(status: 403, code: "denied", message: r.isStop
                  ? "\(r.name) wasn't stopped: the person at the Mac chose Keep Running"
                  : r.automation == nil
                  ? "\(r.name) didn't run: the person at the Mac chose Don't Run"
                  : "\(r.name) wasn't automated: the person at the Mac chose Don't Allow")
    }

    static func unanswered(_ r: RunRequest) -> HTTPError {
        HTTPError(status: 403, code: "not_answered", message: r.isStop
                  ? "\(r.name) wasn't stopped: no one clicked Stop It on the Mac in time"
                  : r.automation == nil
                  ? "\(r.name) didn't run: no one clicked Run on the Mac in time"
                  : "\(r.name) wasn't automated: no one clicked Allow on the Mac in time")
    }

    /// Waits for a run to end.
    private func finish(_ id: UUID) async throws -> (RunRecord, [RunRecord]) {
        while true {
            guard let r = await host.record(id) else { throw unknownRun(id) }
            if r.state.finished { return (r, await host.steps(of: id)) }
            try await Task.sleep(nanoseconds: poll)
        }
    }

    /// NDJSON, one event a line: waiting, then started (or denied), output as it's printed, the
    /// steps of a flow as they start and end, and done with everything a waited-for run gives.
    private func stream(_ request: RunRequest) -> HTTPResponse {
        let host = self.host, poll = self.poll, rq = request.id.uuidString
        return HTTPResponse(status: 200, headers: [("Content-Type", "application/x-ndjson"), ("Cache-Control", "no-cache"), ("X-Request-Id", rq)],
                            body: .stream { [self] out in
            try await out.write(JSON.line(["type": "waiting", "request": rq, "url": "/api/requests/\(rq)",
                                           "message": "Waiting for the person at the Mac to click Run"]))
            let id: UUID
            do {
                id = try await self.approveAndStart(request)
            } catch let e as HTTPError where e.code == "denied" || e.code == "not_answered" {
                try await out.write(JSON.line(["type": "denied", "request": rq, "code": e.code, "message": e.message]))
                await self.requests.clear(request.id, .delivered)
                return
            } catch {
                try await out.write(JSON.line(["type": "error", "request": rq, "message": (error as? HTTPError)?.message ?? "\(error)"]))
                await self.requests.clear(request.id, .delivered)
                return
            }
            try await out.write(JSON.line(["type": "started", "id": id.uuidString, "request": rq, "name": request.name]))
            var sent: [UUID: Int] = [:]
            var stepStates: [UUID: RunRecord.State] = [:]
            while true {
                guard let run = await host.record(id) else {
                    try await out.write(JSON.line(["type": "error", "message": "the run was cleared from the app's history"]))
                    return
                }
                let steps = await host.steps(of: id)
                for r in [run] + steps {
                    if r.kind == .step, stepStates[r.id] == nil {
                        stepStates[r.id] = .running
                        try await out.write(JSON.line(["type": "step", "id": r.id.uuidString, "name": r.name, "state": "running"]))
                    }
                    for chunk in r.newOutput(since: sent[r.id] ?? 0) {
                        var line: [String: Any] = ["type": "output", "stream": chunk.stream.rawValue, "text": chunk.text]
                        if r.kind == .step { line["step"] = r.name }
                        try await out.write(JSON.line(line))
                    }
                    sent[r.id] = r.receivedBytes
                    if r.kind == .step, r.state.finished, stepStates[r.id] != r.state {
                        stepStates[r.id] = r.state
                        var line: [String: Any] = ["type": "step", "id": r.id.uuidString, "name": r.name, "state": Self.stateName(r.state)]
                        if let code = r.code { line["code"] = Int(code) }
                        try await out.write(JSON.line(line))
                    }
                }
                if run.state.finished {
                    try await out.write(JSON.line(["type": "done", "request": rq, "delivery": "delivered"].merging(Self.runJSON(run, steps: steps)) { a, _ in a }))
                    // Handed over in the stream: cleared.
                    await self.requests.clear(request.id, .delivered)
                    return
                }
                try await Task.sleep(nanoseconds: poll)
            }
        })
    }

    // MARK: Reading requests

    /// The body as JSON fields. Plain text (for compose and check) is the flow's code; nothing at
    /// all is no fields.
    func body(_ req: HTTPRequest, plainTextAs field: String? = nil) throws -> [String: Any] {
        if req.body.isEmpty { return [:] }
        if let field, req.contentType.hasPrefix("text/") {
            return [field: String(decoding: req.body, as: UTF8.self)]
        }
        guard let fields = JSON.object(req.body) else {
            throw HTTPError(status: 400, code: "bad_request", message: "send a JSON object (Content-Type: application/json)")
        }
        return fields
    }

    /// The arguments: a list (["--all", "2"], numbers taken as written), or one line split as a
    /// shell would ("--all '/tmp/my files'").
    static func arguments(_ fields: [String: Any]) throws -> [String] {
        guard let value = fields["args"] ?? fields["arguments"] else { return [] }
        if let line = value as? String { return ShellEnvironment.split(line) }
        if let list = value as? [Any] {
            return try list.map { item in
                guard let s = text(item) else {
                    throw HTTPError(status: 400, code: "bad_args", message: "args is a list of strings, or one line of them")
                }
                return s
            }
        }
        if value is NSNull { return [] }
        throw HTTPError(status: 400, code: "bad_args", message: "args is a list of strings, or one line of them")
    }

    /// A string, or a number or true/false as written.
    static func text(_ value: Any?) -> String? {
        switch value {
        case let s as String: return s
        case let n as NSNumber:
            #if canImport(Darwin)
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            #endif
            return n.stringValue
        default: return nil
        }
    }

    /// Why the app asks for it, in its words ("why", or "reason"; "justification" too): a few
    /// lines at most, shown on the card. Nil when it didn't say.
    static func why(_ fields: [String: Any]) -> String? {
        guard let said = text(fields["why"]) ?? text(fields["reason"]) ?? text(fields["justification"]) else { return nil }
        let lines = said.split(whereSeparator: \.isNewline).map { clean(String($0), limit: 200) }.filter { !$0.isEmpty }
        let kept = lines.prefix(6).joined(separator: "\n")
        return kept.isEmpty ? nil : kept
    }

    /// How the app wants the item automated: "automation" (or "tags"), a list of tag names or
    /// one name (an empty list: not automated any more); "once": one time only; "after": the
    /// items it runs after (their names, as /api/scripts and /api/flows give them). Nil when the
    /// request doesn't mention it (a run now).
    static func automation(_ fields: [String: Any], items: [ScriptItem]) throws -> Automation? {
        // "after" alone means the after-an-item tag.
        guard let value = fields["automation"] ?? fields["tags"] ?? (fields["after"] != nil ? [Any]() : nil) else { return nil }
        var given: [String]
        switch value {
        case let one as String: given = one.isEmpty ? [] : [one]
        case let list as [Any]: given = list.compactMap(text)
        case is NSNull: given = []
        default: throw HTTPError(status: 400, code: "bad_request", message: "automation is a list of tag names (GET /api/automation lists them)")
        }
        var tags: [AutomationTag] = []
        for name in given {
            guard let tag = AutomationTag.named(name) else {
                throw HTTPError(status: 400, code: "unknown_tag", message: "there's no automation tag called \(name); the tags: \(AutomationTag.names)")
            }
            tags.append(tag)
        }
        var after: [String] = []
        if let list = fields["after"] as? [Any] {
            for name in list.compactMap(text) {
                guard let match = ScriptNames.match(name, in: items.map(\.id)) else {
                    throw HTTPError(status: 404, code: "unknown_script", message: "no script or flow named \(name) to run after; the names: \(names(items))")
                }
                after.append(match)
            }
        } else if let one = text(fields["after"]), !one.isEmpty {
            guard let match = ScriptNames.match(one, in: items.map(\.id)) else {
                throw HTTPError(status: 404, code: "unknown_script", message: "no script or flow named \(one) to run after; the names: \(names(items))")
            }
            after = [match]
        }
        if !after.isEmpty { tags.append(.afterItem) }
        if tags.contains(.afterItem), after.isEmpty {
            throw HTTPError(status: 400, code: "bad_request", message: "\"after-an-item\" needs \"after\": [\"<a script's or flow's name>\"]")
        }
        return Automation(tags: tags, once: fields["once"] as? Bool ?? false, after: after)
    }

    /// Who's asking: what it calls itself, else its User-Agent's product ("curl/8.4" → "curl").
    static func client(_ req: HTTPRequest, _ fields: [String: Any]) -> String {
        if let named = text(fields["client"]).map({ clean($0, limit: 60) }), !named.isEmpty { return named }
        if let named = req.header("x-client").map({ clean($0, limit: 60) }), !named.isEmpty { return named }
        if let agent = req.header("user-agent"), let product = agent.split(separator: " ").first?.split(separator: "/").first {
            let p = clean(String(product), limit: 40)
            if !p.isEmpty { return p }
        }
        return "An app"
    }

    /// Where it's asking from, in words for the person at the Mac.
    static func from(_ req: HTTPRequest) -> String {
        if !req.fromLoopback { return req.peer.map { "another device (\($0))" } ?? "another device" }
        if let origin = req.header("origin") { return "a web page at \(clean(origin, limit: 80))" }
        return "this Mac"
    }

    /// One line, no control characters, at most `limit` characters: what's shown on the Mac.
    static func clean(_ s: String, limit: Int) -> String {
        let one = String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
        let t = one.trimmingCharacters(in: .whitespaces)
        return t.count > limit ? String(t.prefix(limit - 1)) + "…" : t
    }

    private static func names(_ items: [ScriptItem]) -> String {
        items.isEmpty ? "(none)" : items.prefix(30).map(\.id).joined(separator: ", ") + (items.count > 30 ? ", …" : "")
    }

    // MARK: Writing responses

    static func scriptJSON(_ s: ScriptItem) -> [String: Any] {
        var out: [String: Any] = ["name": s.id, "title": s.title, "group": s.grid.rawValue, "language": s.language.rawValue,
                                  "language_name": s.language.title, "asks_for_input": s.asksForInput,
                                  "dangers": s.dangers, "uses_epa": s.usesEPA, "inputs": inputsJSON(s.inputs)]
        if let summary = s.summary { out["summary"] = summary }
        if !s.tags.isEmpty { out["tags"] = s.tags }
        return out
    }

    /// What it asks for before it runs (its header's `Input:` lines): each an argument, or text
    /// for its stdin, in order.
    static func inputsJSON(_ inputs: [ScriptInput]) -> [[String: Any]] {
        inputs.map { input in
            var out: [String: Any] = ["prompt": input.prompt, "kind": input.kind == .text ? "stdin" : "argument", "optional": input.optional]
            if let why = input.why { out["why"] = why }
            return out
        }
    }

    /// An automated item: its name, kind, tags, once, after, and when its schedule next runs.
    static func automationJSON(_ e: AutomationEntry) -> [String: Any] {
        var out: [String: Any] = [
            "name": e.id, "kind": e.grid.isFlow ? "flow" : "script", "group": e.grid.rawValue, "title": e.title,
            "tags": e.automation.tags.map(\.rawValue), "once": e.automation.once, "after": e.automation.after,
            "summary": e.automation.summary,
        ]
        if let next = e.next { out["next"] = JSON.date(next) }
        return out
    }

    static func flowJSON(_ f: ScriptItem) -> [String: Any] {
        var out: [String: Any] = ["name": f.id, "title": f.title, "uses_epa": f.usesEPA, "inputs": inputsJSON(f.inputs)]
        if let summary = f.summary { out["summary"] = summary }
        if !f.tags.isEmpty { out["tags"] = f.tags }
        return out
    }

    static func stateName(_ s: RunRecord.State) -> String {
        s == .couldNotStart ? "could_not_start" : s.rawValue
    }

    /// A run as the API gives it: how it went, and (with `output`) what it printed, its errors
    /// apart too, and a flow's steps.
    static func runJSON(_ r: RunRecord, steps: [RunRecord] = [], output: Bool = true) -> [String: Any] {
        var out: [String: Any] = [
            "id": r.id.uuidString, "kind": r.kind.rawValue, "name": r.name, "state": stateName(r.state),
            "ok": r.state == .succeeded, "command": r.command, "arguments": r.arguments, "started": JSON.date(r.started),
        ]
        if let ended = r.ended { out["ended"] = JSON.date(ended) }
        if let s = r.seconds { out["seconds"] = JSON.round(s) }
        if let code = r.code { out["code"] = Int(code) }
        if let signal = r.signal { out["signal"] = Int(signal) }
        if let p = r.problem { out["problem"] = p }
        if let by = r.requestedBy { out["requested_by"] = by }
        if let why = r.why { out["why"] = why }
        if output {
            out["output"] = r.text
            out["stdout"] = r.output.filter { $0.stream == .out }.map(\.text).joined()
            out["stderr"] = r.output.filter { $0.stream == .err }.map(\.text).joined()
            out["trimmed"] = r.trimmed
            if r.kind == .flow { out["steps"] = steps.map { runJSON($0) } }
        }
        return out
    }

    private func failure(_ e: HTTPError) -> HTTPResponse {
        JSON.response(["error": e.message, "code": e.code], status: e.status)
    }
}

extension Catalog {
    var composerPath: String { folder.appendingPathComponent("composer", isDirectory: true).path }
}

extension RunRecord {
    /// What it printed after the first `received` bytes (`receivedBytes` as it was then): the new
    /// output, in order, as much of it as is still kept.
    public func newOutput(since received: Int) -> [Chunk] {
        var need = receivedBytes - received
        guard need > 0 else { return [] }
        var picked: [Chunk] = []
        for c in output.reversed() {
            let n = c.text.utf8.count
            if n <= need {
                picked.append(c)
                need -= n
            } else {
                let s = c.text
                var cut = s.utf8.index(s.utf8.endIndex, offsetBy: -need)
                // Forward to where a Unicode scalar starts (not a character: new output can join the
                // last character, "\r" then "\n", and cutting there would drop the "\n").
                while cut < s.utf8.endIndex, cut.samePosition(in: s.unicodeScalars) == nil { cut = s.utf8.index(after: cut) }
                picked.append(Chunk(stream: c.stream, text: String(s.unicodeScalars[cut...])))
                need = 0
            }
            if need == 0 { break }
        }
        return picked.reversed()
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
