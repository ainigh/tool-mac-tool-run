import Foundation
@testable import RunCore
import XCTest

/// The app, as the API sees it: a folder of scripts, an answer for every approval, and runs that
/// end when the test says.
final class FakeRunHost: RunHost, @unchecked Sendable {
    private let lock = NSLock()
    var catalogValue: Catalog?
    var answer: Approval = .allowed
    private(set) var asked: [RunRequest] = []
    private(set) var started: [RunRequest] = []
    private(set) var stopped: [UUID] = []
    var runs: [UUID: RunRecord] = [:]
    var stepsByRun: [UUID: [RunRecord]] = [:]
    /// What a started run does: by default it prints "hi" and succeeds at once.
    var behave: (inout RunRecord) -> Void = { r in
        r.append(.out, "hi\n")
        r.finish(code: 0, state: .succeeded)
    }

    init(folder: URL, scripts: [ScriptItem] = [], flows: [ScriptItem] = []) {
        catalogValue = Catalog(folder: folder, scripts: scripts, flows: flows)
    }

    func catalog() async -> Catalog? { lock.withLock { catalogValue } }

    func approve(_ request: RunRequest) async -> Approval {
        lock.withLock {
            asked.append(request)
            return answer
        }
    }

    func start(_ request: RunRequest) async throws -> UUID {
        lock.withLock {
            started.append(request)
            var r = RunRecord(kind: request.isScript ? .script : .flow, name: request.name, file: request.name,
                              arguments: request.arguments, command: request.command)
            r.requestedBy = request.requestedBy
            behave(&r)
            runs[r.id] = r
            return r.id
        }
    }

    func update(_ id: UUID, _ change: (inout RunRecord) -> Void) {
        lock.withLock { if var r = runs[id] { change(&r); runs[id] = r } }
    }

    func record(_ id: UUID) async -> RunRecord? { lock.withLock { runs[id] } }
    func steps(of id: UUID) async -> [RunRecord] { lock.withLock { stepsByRun[id] ?? [] } }
    func recent(_ limit: Int) async -> [RunRecord] { lock.withLock { Array(runs.values.sorted { $0.started > $1.started }.prefix(limit)) } }

    func stop(_ id: UUID) async -> Bool {
        lock.withLock {
            stopped.append(id)
            return runs[id]?.state == .running
        }
    }
}

/// Collects a streamed body.
final class Collector: ResponseWriter {
    var data = Data()
    func write(_ d: Data) async throws { data.append(d) }
}

extension RunAPI {
    func send(_ method: String, _ target: String, body: Data = Data(), headers: [String: String] = [:],
              fromLoopback: Bool = true) async -> (HTTPResponse, Data) {
        let r = await handle(HTTPRequest(method: method, target: target, headers: headers, body: body, fromLoopback: fromLoopback))
        switch r.body {
        case .data(let d): return (r, d)
        case .stream(let make):
            let c = Collector()
            try? await make(c)
            return (r, c.data)
        }
    }

    func post(_ target: String, _ json: String, headers: [String: String] = [:]) async -> (HTTPResponse, Data) {
        await send("POST", target, body: Data(json.utf8), headers: ["Content-Type": "application/json"].merging(headers) { _, b in b })
    }
}

func json(_ d: Data) -> [String: Any] { JSON.object(d) ?? [:] }

func events(_ d: Data) -> [[String: Any]] {
    String(decoding: d, as: UTF8.self).split(separator: "\n").compactMap { JSON.object(Data($0.utf8)) }
}

final class APITests: XCTestCase {
    var folder: URL!
    var host: FakeRunHost!
    var settings = APISettings()
    var api: RunAPI!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("api-\(UUID().uuidString)", isDirectory: true)
        let lib = Library(root: folder)
        _ = try lib.ensure()
        try "#!/bin/bash\n# Says hello\necho hello \"$@\"\n".write(to: folder.appendingPathComponent("hello.sh"), atomically: true, encoding: .utf8)
        try "#!/bin/bash\nrm -rf /tmp/whatever\n".write(to: folder.appendingPathComponent("wipe.sh"), atomically: true, encoding: .utf8)
        try "// Greets\nlet x = run \"hello.sh\" []\nprint x\n".write(to: lib.composerFolder.appendingPathComponent("greet.flow"), atomically: true, encoding: .utf8)
        host = FakeRunHost(folder: folder, scripts: lib.scripts(), flows: lib.flows())
        settings = APISettings()
        api = RunAPI(host: host, version: "0.1.9") { [unowned self] in self.settings }
        api.poll = 5_000_000
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testHealthSaysWhatsOnAndTheFolder() async {
        settings.off = [.runs]
        let (r, d) = await api.send("GET", "/api/health")
        XCTAssertEqual(r.status, 200)
        let h = json(d)
        XCTAssertEqual(h["ok"] as? Bool, true)
        XCTAssertEqual(h["service"] as? String, "toolmactoolrun")
        XCTAssertEqual(h["version"] as? String, "0.1.9")
        XCTAssertEqual(h["run"] as? Bool, true)
        XCTAssertEqual(h["runs"] as? Bool, false)
        XCTAssertEqual(h["scripts"] as? Int, 2)
        XCTAssertEqual(h["flows"] as? Int, 1)
        XCTAssertEqual(h["folder"] as? String, folder.path)
    }

    func testScriptsAndFlowsAreListed() async {
        let (_, d) = await api.send("GET", "/api/scripts")
        let scripts = json(d)["scripts"] as? [[String: Any]]
        XCTAssertEqual(scripts?.map { $0["name"] as? String }, ["hello.sh", "wipe.sh"])
        XCTAssertEqual(scripts?.first?["summary"] as? String, "Says hello")
        XCTAssertEqual(scripts?.first?["language"] as? String, "bash")
        XCTAssertFalse((scripts?.last?["dangers"] as? [String] ?? []).isEmpty)
        let (_, f) = await api.send("GET", "/api/flows")
        let flows = json(f)["flows"] as? [[String: Any]]
        XCTAssertEqual(flows?.first?["name"] as? String, "greet.flow")
        XCTAssertEqual(flows?.first?["summary"] as? String, "Greets")
    }

    func testRunAsksFirstThenWaitsForTheResult() async {
        let (r, d) = await api.post("/api/run", #"{"script": "hello", "args": ["a b", 2], "client": "My App"}"#)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(host.asked.count, 1)
        let ask = host.asked[0]
        XCTAssertEqual(ask.name, "hello.sh")
        XCTAssertEqual(ask.arguments, ["a b", "2"])
        XCTAssertEqual(ask.client, "My App")
        XCTAssertEqual(ask.from, "this Mac")
        XCTAssertTrue(ask.command.contains("hello.sh"), ask.command)
        XCTAssertTrue(ask.command.contains("'a b'"), ask.command)
        XCTAssertEqual(host.started.count, 1)
        let run = json(d)
        XCTAssertEqual(run["state"] as? String, "succeeded")
        XCTAssertEqual(run["ok"] as? Bool, true)
        XCTAssertEqual(run["code"] as? Int, 0)
        XCTAssertEqual(run["output"] as? String, "hi\n")
        XCTAssertEqual(run["stdout"] as? String, "hi\n")
        XCTAssertEqual(run["stderr"] as? String, "")
        XCTAssertEqual(run["requested_by"] as? String, "My App, on this Mac")
    }

    func testArgumentsCanBeOneLine() async {
        _ = await api.post("/api/run", #"{"script": "hello.sh", "args": "--all '/tmp/my files'"}"#)
        XCTAssertEqual(host.started.first?.arguments, ["--all", "/tmp/my files"])
    }

    func testDontRunMeansNothingRuns() async {
        host.answer = .denied
        let (r, d) = await api.post("/api/run", #"{"script": "hello.sh"}"#)
        XCTAssertEqual(r.status, 403)
        XCTAssertEqual(json(d)["code"] as? String, "denied")
        XCTAssertTrue(host.started.isEmpty)
        host.answer = .unanswered
        let (r2, d2) = await api.post("/api/run", #"{"script": "hello.sh"}"#)
        XCTAssertEqual(r2.status, 403)
        XCTAssertEqual(json(d2)["code"] as? String, "not_answered")
        XCTAssertTrue(host.started.isEmpty)
    }

    func testDangersGoWithTheQuestion() async {
        _ = await api.post("/api/run", #"{"script": "wipe.sh"}"#)
        XCTAssertFalse(host.asked.first?.dangers.isEmpty ?? true)
    }

    func testAnUnknownScriptIsNeverAskedAbout() async {
        let (r, d) = await api.post("/api/run", #"{"script": "../../bin/rm"}"#)
        XCTAssertEqual(r.status, 404)
        XCTAssertEqual(json(d)["code"] as? String, "unknown_script")
        XCTAssertTrue((json(d)["error"] as? String ?? "").contains("hello.sh"))
        XCTAssertTrue(host.asked.isEmpty)
        let (r2, d2) = await api.post("/api/run", #"{}"#)
        XCTAssertEqual(r2.status, 400)
        XCTAssertEqual(json(d2)["code"] as? String, "missing_script")
    }

    func testNoWaitAnswersAtOnceAndTheRunCanBeRead() async {
        host.behave = { r in r.append(.out, "working\n") }
        let (r, d) = await api.post("/api/run", #"{"script": "hello.sh", "wait": false}"#)
        XCTAssertEqual(r.status, 202)
        let id = json(d)["id"] as? String ?? ""
        XCTAssertEqual(json(d)["url"] as? String, "/api/runs/\(id)")
        let (_, run) = await api.send("GET", "/api/runs/\(id)")
        XCTAssertEqual(json(run)["state"] as? String, "running")
        XCTAssertEqual(json(run)["output"] as? String, "working\n")
        let (s, stop) = await api.send("POST", "/api/runs/\(id)/stop")
        XCTAssertEqual(s.status, 200)
        XCTAssertEqual(json(stop)["stopping"] as? Bool, true)
        XCTAssertEqual(host.stopped.map(\.uuidString), [id])
        let (_, list) = await api.send("GET", "/api/runs")
        let runs = json(list)["runs"] as? [[String: Any]]
        XCTAssertEqual(runs?.count, 1)
        XCTAssertNil(runs?.first?["output"], "the list leaves the output out")
        let (g, _) = await api.send("GET", "/api/runs/\(UUID().uuidString)")
        XCTAssertEqual(g.status, 404)
    }

    func testWaitingFollowsTheRunToItsEnd() async {
        host.behave = { r in r.append(.out, "first\n") }
        let api = self.api!, host = self.host!
        async let response = api.post("/api/run", #"{"script": "hello.sh"}"#)
        // Once it has started, it fails a little later.
        while host.started.isEmpty { try? await Task.sleep(nanoseconds: 2_000_000) }
        try? await Task.sleep(nanoseconds: 20_000_000)
        let id = await host.recent(1)[0].id
        host.update(id) { r in
            r.append(.err, "oops\n")
            r.finish(code: 3, state: .failed)
        }
        let (r, d) = await response
        XCTAssertEqual(r.status, 200)
        let run = json(d)
        XCTAssertEqual(run["state"] as? String, "failed")
        XCTAssertEqual(run["ok"] as? Bool, false)
        XCTAssertEqual(run["code"] as? Int, 3)
        XCTAssertEqual(run["stderr"] as? String, "oops\n")
        XCTAssertEqual(run["output"] as? String, "first\noops\n")
    }

    func testStreamSaysWaitingThenTheOutputThenDone() async {
        let (r, d) = await api.post("/api/run", #"{"script": "hello.sh", "stream": true}"#)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.header("Content-Type"), "application/x-ndjson")
        let e = events(d)
        XCTAssertEqual(e.map { $0["type"] as? String }, ["waiting", "started", "output", "done"])
        XCTAssertEqual(e[2]["text"] as? String, "hi\n")
        XCTAssertEqual(e[3]["state"] as? String, "succeeded")
    }

    func testStreamSaysDenied() async {
        host.answer = .denied
        let (_, d) = await api.post("/api/run", #"{"script": "hello.sh", "stream": true}"#)
        XCTAssertEqual(events(d).map { $0["type"] as? String }, ["waiting", "denied"])
        XCTAssertTrue(host.started.isEmpty)
    }

    func testComposeRunsAFlowByName() async {
        let (r, d) = await api.post("/api/compose", #"{"flow": "greet"}"#)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(host.asked.first?.name, "greet.flow")
        guard case .flow(let item)? = host.asked.first?.what else { return XCTFail("not a flow") }
        XCTAssertEqual(item.id, "greet.flow")
        XCTAssertEqual(json(d)["kind"] as? String, "flow")
        XCTAssertNotNil(json(d)["steps"])
    }

    func testComposeTakesFlowCodeAndChecksItBeforeAsking() async {
        let (r, d) = await api.post("/api/compose", #"{"source": "let x = 1 +\n", "name": "Mine"}"#)
        XCTAssertEqual(r.status, 400)
        XCTAssertEqual(json(d)["code"] as? String, "flow_mistake")
        XCTAssertNotNil(json(d)["line"])
        XCTAssertTrue(host.asked.isEmpty, "a flow with a mistake is never asked about")
        let (r2, _) = await api.post("/api/compose", #"{"source": "run \"nope.sh\" []\n"}"#)
        XCTAssertEqual(r2.status, 400, "a script that isn't in the folder is a mistake too")
        let (r3, _) = await api.send("POST", "/api/compose", body: Data("print (run \"hello.sh\" [])\n".utf8), headers: ["Content-Type": "text/plain"])
        XCTAssertEqual(r3.status, 200)
        XCTAssertEqual(host.asked.first?.source, "print (run \"hello.sh\" [])\n")
        XCTAssertTrue(host.asked.first?.name.hasPrefix("Flow sent by") ?? false)
    }

    func testCheckSaysTheTypesAndRunsNothing() async {
        let (r, d) = await api.post("/api/check", #"{"source": "let double x = x * 2\n"}"#)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(json(d)["ok"] as? Bool, true)
        let b = json(d)["bindings"] as? [[String: Any]]
        XCTAssertEqual(b?.first?["name"] as? String, "double")
        XCTAssertEqual(b?.first?["type"] as? String, "int -> int")
        let (_, bad) = await api.post("/api/check", #"{"source": "let y = nothing\n"}"#)
        XCTAssertEqual(json(bad)["ok"] as? Bool, false)
        XCTAssertTrue(host.asked.isEmpty && host.started.isEmpty)
    }

    func testSwitchedOffEndpointsSaySo() async {
        settings.off = [.run, .catalog]
        let (r, d) = await api.post("/api/run", #"{"script": "hello.sh"}"#)
        XCTAssertEqual(r.status, 503)
        XCTAssertEqual(json(d)["code"] as? String, "endpoint_off")
        let (r2, _) = await api.send("GET", "/api/scripts")
        XCTAssertEqual(r2.status, 503)
        XCTAssertTrue(host.asked.isEmpty)
    }

    func testNoFolderYet() async {
        host.catalogValue = nil
        let (r, d) = await api.post("/api/run", #"{"script": "hello.sh"}"#)
        XCTAssertEqual(r.status, 409)
        XCTAssertEqual(json(d)["code"] as? String, "no_folder")
        let (_, h) = await api.send("GET", "/api/health")
        XCTAssertTrue(json(h)["folder"] is NSNull)
    }

    func testWebsitesAndOtherMachinesAreKeptOut() async {
        let (r, _) = await api.post("/api/run", #"{"script": "hello.sh"}"#, headers: ["Origin": "https://evil.example"])
        XCTAssertEqual(r.status, 403)
        let (r2, _) = await api.send("GET", "/api/health", headers: ["Host": "evil.example:8768"])
        XCTAssertEqual(r2.status, 403)
        let (r3, _) = await api.send("GET", "/api/health", fromLoopback: false)
        XCTAssertEqual(r3.status, 403)
        settings.allowNetwork = true
        settings.token = "secret"
        let (r4, _) = await api.send("GET", "/api/health", fromLoopback: false)
        XCTAssertEqual(r4.status, 401)
        let (r5, _) = await api.send("GET", "/api/health", headers: ["Authorization": "Bearer secret"], fromLoopback: false)
        XCTAssertEqual(r5.status, 200)
        XCTAssertTrue(host.asked.isEmpty)
        // This Mac's own pages may call, with CORS.
        settings = APISettings()
        let (r6, _) = await api.send("GET", "/api/health", headers: ["Origin": "http://localhost:3000"])
        XCTAssertEqual(r6.status, 200)
        XCTAssertEqual(r6.header("Access-Control-Allow-Origin"), "http://localhost:3000")
        let (_, d) = await api.post("/api/run", #"{"script": "hello.sh"}"#, headers: ["Origin": "http://localhost:3000"])
        XCTAssertEqual(json(d)["state"] as? String, "succeeded")
        XCTAssertEqual(host.asked.last?.from, "a web page at http://localhost:3000")
    }

    func testTheClientIsNamedFromItsUserAgentAndCleaned() {
        let req = HTTPRequest(method: "POST", target: "/api/run", headers: ["User-Agent": "curl/8.4.0"])
        XCTAssertEqual(RunAPI.client(req, [:]), "curl")
        XCTAssertEqual(RunAPI.client(HTTPRequest(method: "POST", target: "/"), [:]), "An app")
        XCTAssertEqual(RunAPI.client(req, ["client": "Evil\nApp\u{7}"]), "EvilApp")
        XCTAssertEqual(RunAPI.client(req, ["client": String(repeating: "x", count: 100)]).count, 60)
    }

    func testRoutesAndMethods() async {
        let (r, _) = await api.send("GET", "/api/run")
        XCTAssertEqual(r.status, 405)
        let (r2, _) = await api.send("GET", "/api/nope")
        XCTAssertEqual(r2.status, 404)
        let (r3, page) = await api.send("GET", "/")
        XCTAssertEqual(r3.header("Content-Type"), "text/html; charset=utf-8")
        XCTAssertTrue(String(decoding: page, as: UTF8.self).contains("/api/compose"))
        let (r4, _) = await api.send("OPTIONS", "/api/run", headers: ["Origin": "http://127.0.0.1:5173"])
        XCTAssertEqual(r4.status, 204)
    }

    func testTheStatusPagesExampleFlowChecks() throws {
        let page = StatusPage.html
        let start = try XCTUnwrap(page.range(of: "<textarea id=\"code\">")).upperBound
        let end = try XCTUnwrap(page.range(of: "</textarea>")).lowerBound
        XCTAssertNoThrow(try Flow.check(String(page[start..<end]), scripts: []))
    }
}

final class HTTPTests: XCTestCase {
    func testParsesARequestInPieces() throws {
        var p = HTTPParser()
        let raw = "POST /api/run?x=1 HTTP/1.1\r\nHost: 127.0.0.1:8768\r\nContent-Type: application/json\r\nContent-Length: 16\r\n\r\n{\"script\": \"a\"} "
        let bytes = Array(raw.utf8)
        var outcome: HTTPParser.Outcome = .more(sendContinue: false)
        for b in bytes { outcome = try p.feed(Data([b])) }
        guard case .done(let req) = outcome else { return XCTFail("not done") }
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/api/run")
        XCTAssertEqual(req.query["x"], "1")
        XCTAssertEqual(req.contentType, "application/json")
        XCTAssertEqual(String(decoding: req.body, as: UTF8.self), "{\"script\": \"a\"} ")
    }

    func testChunkedBodiesAndLimits() throws {
        var p = HTTPParser()
        let raw = "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n"
        guard case .done(let req) = try p.feed(Data(raw.utf8)) else { return XCTFail("not done") }
        XCTAssertEqual(String(decoding: req.body, as: UTF8.self), "abcde")
        var small = HTTPParser()
        small.maxBody = 10
        XCTAssertThrowsError(try small.feed(Data("POST / HTTP/1.1\r\nContent-Length: 11\r\n\r\n".utf8)))
    }

    func testNewOutputIsWhatCameSince() {
        var r = RunRecord(kind: .script, name: "a", file: "a", command: "a")
        r.append(.out, "one\n")
        let mark = r.receivedBytes
        r.append(.out, "two\n")
        r.append(.err, "bad\n")
        let new = r.newOutput(since: mark)
        XCTAssertEqual(new.map(\.text), ["two\n", "bad\n"])
        XCTAssertEqual(new.map(\.stream), [.out, .err])
        XCTAssertTrue(r.newOutput(since: r.receivedBytes).isEmpty)
        XCTAssertEqual(r.newOutput(since: 0).map(\.text).joined(), "one\ntwo\nbad\n")
    }

    func testRequestedByIsKept() throws {
        var r = RunRecord(kind: .script, name: "a", file: "a", command: "a")
        r.requestedBy = "curl, on this Mac"
        let back = try RunHistory.decode(RunHistory.encode([r]))
        XCTAssertEqual(back.first?.requestedBy, "curl, on this Mac")
    }

    func testSettingsSurviveAnEndpointTheyDontKnow() throws {
        let data = Data(#"{"off": ["run", "teleport"], "port": 9000}"#.utf8)
        let s = try JSONDecoder().decode(APISettings.self, from: data)
        XCTAssertEqual(s.off, [.run])
        XCTAssertEqual(s.port, 9000)
        XCTAssertFalse(s.allowNetwork)
    }
}
