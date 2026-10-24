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
}

extension RunHost {
    /// A host with no automation (a pretend one): nothing is automated, and nothing can be.
    public func automations() async -> [AutomationEntry] { [] }

    public func automate(_ request: RunRequest) async throws -> AutomationEntry {
        throw HTTPError(status: 500, code: "failed", message: "automation isn't available here")
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
    /// The file library it serves (LIBRARY (in TOOL-MAC-RUN on the Desktop)).
    let library: @Sendable () -> FileLibrary
    private let settings: @Sendable () -> APISettings
    /// How often a run being waited for is looked at.
    var poll: UInt64 = 200_000_000

    public init(host: RunHost, version: String, library: @escaping @Sendable () -> FileLibrary = { FileLibrary() },
                settings: @escaping @Sendable () -> APISettings) {
        self.host = host
        self.version = version
        self.library = library
        self.settings = settings
    }

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
        response.headers += cors
        return response
    }

    private static let routes: [String: String] = [
        "/": "GET", "/index.html": "GET", "/favicon.ico": "GET", "/api/health": "GET", "/api/doc": "GET",
        "/api": "GET", "/api/endpoints": "GET",
        "/api/scripts": "GET", "/api/flows": "GET", "/api/runs": "GET", "/api/requests": "GET",
        "/api/run": "POST", "/api/compose": "POST", "/api/check": "POST",
    ]

    private func route(_ req: HTTPRequest, _ s: APISettings) async throws -> HTTPResponse {
        var path = req.path
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if path.hasPrefix("/api/runs/") { return try await runRoute(req, path: path, s) }
        if path.hasPrefix("/api/requests/") { return try await requestRoute(req, path: path, s) }
        if path == "/api/automation" { return try await automationRoute(req, s) }
        if path == "/api/library" || path.hasPrefix("/api/library/") { return try await libraryRoute(req, path: path, s) }
        if path == "/api/straw" || path.hasPrefix("/api/straw/") { return try await strawRoute(req, path: path, s) }
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
        case "/api", "/api/endpoints":
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
                return refused(e, request)
            }
            await requests.set(request.id, .stopped(id))
            return JSON.response(["ok": true, "stopping": await host.stop(id), "request": request.id.uuidString],
                                 headers: [("X-Request-Id", request.id.uuidString)])
        }
        try allow(req, "GET", path)
        guard let r = await host.record(id) else { throw unknownRun(id) }
        var out = Self.runJSON(r, steps: await host.steps(of: id))
        if let request = await requests.request(forRun: id) { out["request"] = request.uuidString }
        return JSON.response(out)
    }

    /// GET /api/requests/{id}: where a request is, from the moment it arrived.
    private func requestRoute(_ req: HTTPRequest, path: String, _ s: APISettings) async throws -> HTTPResponse {
        try need(.runs, s)
        let parts = path.dropFirst("/api/requests/".count).split(separator: "/").map(String.init)
        guard parts.count == 1, let id = UUID(uuidString: parts[0]) else {
            throw HTTPError(status: 404, code: "not_found", message: "no such route: \(req.path) (a request is /api/requests/<its id>)")
        }
        try allow(req, "GET", path)
        guard let e = await requests.entry(id) else {
            // A library operation's id answers here too.
            if let op = await libraryLog.entry(id) { return JSON.response(LibraryLog.json(op), headers: [("X-Request-Id", id.uuidString)]) }
            throw HTTPError(status: 404, code: "unknown_request",
                            message: "no request \(id.uuidString) (the latest \(requests.capacity) are kept while the app runs)")
        }
        return JSON.response(await requestJSON(e), headers: [("X-Request-Id", id.uuidString)])
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
        let lib = library()
        out["library"] = ["folder": lib.root.path, "notes": lib.list().count, "approval": "none (answered at once)"] as [String: Any]
        for e in APIEndpoint.allCases { out[e.rawValue] = s.isOn(e) }
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
                var out = Self.automationJSON(entry)
                out["ok"] = true
                out["automated"] = true
                out["request"] = id
                return JSON.response(out, headers: tagged)
            } catch let e as HTTPError {
                return refused(e, request)
            }
        }
        if fields["stream"] as? Bool == true { return stream(request) }
        if fields["async"] as? Bool == true {
            // Answered now; the card stays on the Mac, and the run (if allowed) goes on without the
            // caller: a task of its own, which the caller hanging up doesn't cancel.
            Task { [self] in _ = try? await self.approveAndStart(request) }
            return JSON.response(["request": id, "state": "waiting", "url": "/api/requests/\(id)",
                                  "message": "On the Mac, waiting for Run; GET /api/requests/\(id) says how it goes"],
                                 status: 202, headers: tagged)
        }
        let runID: UUID
        do {
            runID = try await approveAndStart(request)
        } catch let e as HTTPError {
            return refused(e, request)
        }
        if fields["wait"] as? Bool == false {
            return JSON.response(["id": runID.uuidString, "request": id, "state": "running", "url": "/api/runs/\(runID.uuidString)"],
                                 status: 202, headers: tagged)
        }
        let (run, steps) = try await finish(runID)
        var out = Self.runJSON(run, steps: steps)
        out["request"] = id
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
    private func refused(_ e: HTTPError, _ request: RunRequest) -> HTTPResponse {
        JSON.response(["error": e.message, "code": e.code, "request": request.id.uuidString], status: e.status,
                      headers: [("X-Request-Id", request.id.uuidString)])
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
                return
            } catch {
                try await out.write(JSON.line(["type": "error", "request": rq, "message": (error as? HTTPError)?.message ?? "\(error)"]))
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
                    try await out.write(JSON.line(["type": "done", "request": rq].merging(Self.runJSON(run, steps: steps)) { a, _ in a }))
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
