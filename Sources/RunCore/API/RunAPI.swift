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

    public init(what: What, name: String, arguments: [String] = [], stdin: String? = nil, client: String,
                from: String = "this Mac", command: String, dangers: [String] = []) {
        self.what = what
        self.name = name
        self.arguments = arguments
        self.stdin = stdin
        self.client = client
        self.from = from
        self.command = command
        self.dangers = dangers
    }

    /// Kept with the run: who asked for it ("curl, on this Mac").
    public var requestedBy: String { "\(client), \(from == "this Mac" ? "on this Mac" : "from \(from)")" }

    /// Flow code: what it is (shown in full on the Mac before it's allowed).
    public var source: String? {
        if case let .source(s) = what { return s }
        return nil
    }

    public var isScript: Bool {
        if case .script = what { return true }
        return false
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
}

/// The HTTP API (see API.md): requests in, responses out. The server around it only moves bytes.
/// Nothing runs without the person clicking Run on the Mac: every run request waits for that.
public final class RunAPI: @unchecked Sendable {
    public let host: RunHost
    public let version: String
    private let settings: @Sendable () -> APISettings
    /// How often a run being waited for is looked at.
    var poll: UInt64 = 200_000_000

    public init(host: RunHost, version: String, settings: @escaping @Sendable () -> APISettings) {
        self.host = host
        self.version = version
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
        "/api/scripts": "GET", "/api/flows": "GET", "/api/runs": "GET",
        "/api/run": "POST", "/api/compose": "POST", "/api/check": "POST",
    ]

    private func route(_ req: HTTPRequest, _ s: APISettings) async throws -> HTTPResponse {
        var path = req.path
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if path.hasPrefix("/api/runs/") { return try await runRoute(req, path: path, s) }
        guard let method = Self.routes[path] else {
            throw HTTPError(status: 404, code: "not_found", message: "no such route: \(req.path) (see /api/health)")
        }
        try allow(req, method, path)
        switch path {
        case "/", "/index.html":
            return HTTPResponse(contentType: "text/html; charset=utf-8", data: Data(StatusPage.html.utf8))
        case "/favicon.ico":
            return HTTPResponse(status: 204)
        case "/api/health":
            return JSON.response(await health(s))
        case "/api/doc":
            // The API in one page, with this server's own address (and token, for a caller on the network).
            let doc = APIDoc.text(baseURL: Access.baseURL(req, settings: s), token: s.allowNetwork ? s.token : nil, version: version)
            return HTTPResponse(contentType: "text/markdown; charset=utf-8", data: Data(doc.utf8))
        case "/api/scripts":
            try need(.catalog, s)
            let c = try await catalog()
            return JSON.response(["folder": c.folder.path, "scripts": c.scripts.map(Self.scriptJSON)])
        case "/api/flows":
            try need(.catalog, s)
            let c = try await catalog()
            return JSON.response(["folder": c.composerPath, "flows": c.flows.map(Self.flowJSON)])
        case "/api/runs":
            try need(.runs, s)
            let limit = min(300, max(1, Int(req.query["limit"] ?? "") ?? 20))
            return JSON.response(["runs": await host.recent(limit).map { Self.runJSON($0, output: false) }])
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
            guard await host.record(id) != nil else { throw unknownRun(id) }
            return JSON.response(["ok": true, "stopping": await host.stop(id)])
        }
        try allow(req, "GET", path)
        guard let r = await host.record(id) else { throw unknownRun(id) }
        return JSON.response(Self.runJSON(r, steps: await host.steps(of: id)))
    }

    private func unknownRun(_ id: UUID) -> HTTPError {
        HTTPError(status: 404, code: "unknown_run", message: "no run \(id.uuidString) (runs are kept until Clear Finished, the latest 300)")
    }

    private func need(_ e: APIEndpoint, _ s: APISettings) throws {
        guard s.isOn(e) else {
            throw HTTPError(status: 503, code: "endpoint_off", message: "\(e.title.lowercased()) is turned off in Tool Mac Tool Run")
        }
    }

    private func catalog() async throws -> Catalog {
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
        } else {
            out["folder"] = NSNull()
        }
        for e in APIEndpoint.allCases { out[e.rawValue] = s.isOn(e) }
        return out
    }

    // MARK: Running

    private func runScript(_ req: HTTPRequest) async throws -> HTTPResponse {
        let fields = try body(req)
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
                                 client: Self.client(req, fields), from: Self.from(req), command: command, dangers: item.dangers)
        return try await execute(request, fields)
    }

    private func compose(_ req: HTTPRequest) async throws -> HTTPResponse {
        let fields = try body(req, plainTextAs: "source")
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
        let request = RunRequest(what: what, name: name, arguments: args, client: Self.client(req, fields),
                                 from: Self.from(req), command: command)
        return try await execute(request, fields)
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

    private static func flowMistake(_ e: FlowError, status: Int = 400) -> HTTPResponse {
        var out: [String: Any] = ["ok": false, "code": "flow_mistake", "error": e.description, "message": e.message]
        if let line = e.pos?.line { out["line"] = line }
        if let fix = e.fix { out["fix"] = fix }
        return JSON.response(out, status: status)
    }

    /// Asks on the Mac, then runs it: waiting for it to end (the default), answering at once
    /// (`"wait": false`), or sending what it prints as it prints it (`"stream": true`).
    private func execute(_ request: RunRequest, _ fields: [String: Any]) async throws -> HTTPResponse {
        if fields["stream"] as? Bool == true { return stream(request) }
        switch await host.approve(request) {
        case .allowed: break
        case .denied: throw Self.denied(request)
        case .unanswered: throw Self.unanswered(request)
        }
        let id = try await host.start(request)
        if fields["wait"] as? Bool == false {
            return JSON.response(["id": id.uuidString, "state": "running", "url": "/api/runs/\(id.uuidString)"], status: 202)
        }
        let (run, steps) = try await finish(id)
        return JSON.response(Self.runJSON(run, steps: steps))
    }

    static func denied(_ r: RunRequest) -> HTTPError {
        HTTPError(status: 403, code: "denied", message: "\(r.name) didn't run: the person at the Mac chose Don't Run")
    }

    static func unanswered(_ r: RunRequest) -> HTTPError {
        HTTPError(status: 403, code: "not_answered", message: "\(r.name) didn't run: no one clicked Run on the Mac in time")
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
        let host = self.host, poll = self.poll
        return HTTPResponse(status: 200, headers: [("Content-Type", "application/x-ndjson"), ("Cache-Control", "no-cache")],
                            body: .stream { out in
            try await out.write(JSON.line(["type": "waiting", "message": "Waiting for the person at the Mac to click Run"]))
            switch await host.approve(request) {
            case .allowed: break
            case .denied:
                let e = Self.denied(request)
                try await out.write(JSON.line(["type": "denied", "code": e.code, "message": e.message]))
                return
            case .unanswered:
                let e = Self.unanswered(request)
                try await out.write(JSON.line(["type": "denied", "code": e.code, "message": e.message]))
                return
            }
            let id: UUID
            do {
                id = try await host.start(request)
            } catch {
                try await out.write(JSON.line(["type": "error", "message": (error as? HTTPError)?.message ?? "\(error)"]))
                return
            }
            try await out.write(JSON.line(["type": "started", "id": id.uuidString, "name": request.name]))
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
                    try await out.write(JSON.line(["type": "done"].merging(Self.runJSON(run, steps: steps)) { a, _ in a }))
                    return
                }
                try await Task.sleep(nanoseconds: poll)
            }
        })
    }

    // MARK: Reading requests

    /// The body as JSON fields. Plain text (for compose and check) is the flow's code; nothing at
    /// all is no fields.
    private func body(_ req: HTTPRequest, plainTextAs field: String? = nil) throws -> [String: Any] {
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
        var out: [String: Any] = ["name": s.id, "title": s.title, "language": s.language.rawValue,
                                  "language_name": s.language.title, "asks_for_input": s.asksForInput,
                                  "dangers": s.dangers, "uses_epa": s.usesEPA]
        if let summary = s.summary { out["summary"] = summary }
        return out
    }

    static func flowJSON(_ f: ScriptItem) -> [String: Any] {
        var out: [String: Any] = ["name": f.id, "title": f.title, "uses_epa": f.usesEPA]
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
