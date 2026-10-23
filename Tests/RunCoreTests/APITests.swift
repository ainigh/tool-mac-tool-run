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
            r.why = request.why
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

    /// What's been tagged to run by itself (by `automate`), by the item's id.
    private(set) var automated: [String: Automation] = [:]
    private(set) var automateRequests: [RunRequest] = []

    func automations() async -> [AutomationEntry] {
        lock.withLock {
            automated.map { AutomationEntry(id: $0.key, grid: GridKind.of(scriptID: $0.key), title: $0.key, automation: $0.value, next: nil) }
                .sorted { $0.id < $1.id }
        }
    }

    func automate(_ request: RunRequest) async throws -> AutomationEntry {
        try lock.withLock {
            automateRequests.append(request)
            guard let id = request.itemID, let a = request.automation else { throw HTTPError(status: 400, code: "bad_request", message: "nothing to tag") }
            if a.isEmpty { automated[id] = nil } else { automated[id] = a }
            return AutomationEntry(id: id, grid: request.isScript ? .scripts : .composer, title: id, automation: a,
                                   next: a.schedules.isEmpty ? nil : Date(timeIntervalSince1970: 1_800_000_000))
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

    func testUtilitiesAndBrowserScriptsAreScriptsWithTheirGroup() async throws {
        let lib = Library(root: folder)
        try "#!/bin/bash\n# Says it\n# Input: What to say\n# Why: It's said out loud, as typed\n# Input text (optional): More\nsay \"$@\"\n".write(to: lib.folder(.utilities).appendingPathComponent("speak.sh"), atomically: true, encoding: .utf8)
        try "#!/bin/bash\n# The page\necho page\n".write(to: lib.folder(.browser).appendingPathComponent("page-info.sh"), atomically: true, encoding: .utf8)
        host.catalogValue = Catalog(folder: folder, scripts: lib.scripts(), flows: lib.flows())

        let (_, d) = await api.send("GET", "/api/scripts")
        let all = json(d)["scripts"] as? [[String: Any]] ?? []
        XCTAssertEqual(all.map { $0["name"] as? String }, ["hello.sh", "wipe.sh", "utilities/speak.sh", "browser/page-info.sh"])
        XCTAssertEqual(all.map { $0["group"] as? String }, ["scripts", "scripts", "utilities", "browser"])
        let inputs = all[2]["inputs"] as? [[String: Any]]
        XCTAssertEqual(inputs?.map { $0["prompt"] as? String }, ["What to say", "More"])
        XCTAssertEqual(inputs?.map { $0["kind"] as? String }, ["argument", "stdin"])
        XCTAssertEqual(inputs?.map { $0["optional"] as? Bool }, [false, true])
        XCTAssertEqual(inputs?.map { $0["why"] as? String }, ["It's said out loud, as typed", nil])
        XCTAssertEqual((all[0]["inputs"] as? [Any])?.count, 0)
        let (_, u) = await api.send("GET", "/api/scripts?group=utilities")
        XCTAssertEqual((json(u)["scripts"] as? [[String: Any]])?.map { $0["name"] as? String }, ["utilities/speak.sh"])
        let (bad, b) = await api.send("GET", "/api/scripts?group=composer")
        XCTAssertEqual(bad.status, 400)
        XCTAssertEqual(json(b)["code"] as? String, "unknown_group")

        // Run by its name alone, or with its folder.
        let (r, _) = await api.post("/api/run", #"{"script": "speak", "args": ["hi"]}"#)
        XCTAssertEqual(r.status, 200)
        let (r2, _) = await api.post("/api/run", #"{"script": "browser/page-info.sh"}"#)
        XCTAssertEqual(r2.status, 200)
        XCTAssertEqual(host.started.map(\.name), ["utilities/speak.sh", "browser/page-info.sh"])
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

    func testWhyGoesWithTheQuestionAndTheRun() async {
        let (_, d) = await api.post("/api/run", #"{"script": "hello.sh", "client": "My App", "why": "You pressed Greet\nin the toolbar"}"#)
        XCTAssertEqual(host.asked.first?.why, "You pressed Greet\nin the toolbar")
        XCTAssertEqual(host.started.first?.why, "You pressed Greet\nin the toolbar")
        XCTAssertEqual(json(d)["why"] as? String, "You pressed Greet\nin the toolbar")
        // Not said: nil, and nothing in the run. "reason" is the same field.
        _ = await api.post("/api/run", #"{"script": "hello.sh"}"#)
        XCTAssertNil(host.asked.last?.why)
        _ = await api.post("/api/compose", #"{"flow": "greet.flow", "reason": "Morning check"}"#)
        XCTAssertEqual(host.asked.last?.why, "Morning check")
        // Kept short, one line each, no control characters.
        _ = await api.post("/api/run", #"{"script": "hello.sh", "why": "a\u0007b\n\n\n   \nc"}"#)
        XCTAssertEqual(host.asked.last?.why, "ab\nc")
    }

    func testAutomationIsAskedAboutThenTaggedNotRun() async {
        let (r, d) = await api.post("/api/run", #"{"script": "hello", "automation": ["every morning", "when-api-called"], "client": "My App", "why": "Keep it fresh"}"#)
        XCTAssertEqual(r.status, 200, String(decoding: d, as: UTF8.self))
        XCTAssertEqual(host.asked.count, 1)
        XCTAssertEqual(host.asked.first?.automation?.tags, [.everyMorning, .whenAPICalled])
        XCTAssertEqual(host.asked.first?.why, "Keep it fresh")
        XCTAssertTrue(host.started.isEmpty, "nothing runs now")
        XCTAssertEqual(host.automateRequests.count, 1)
        let out = json(d)
        XCTAssertEqual(out["ok"] as? Bool, true)
        XCTAssertEqual(out["automated"] as? Bool, true)
        XCTAssertEqual(out["name"] as? String, "hello.sh")
        XCTAssertEqual(out["tags"] as? [String], ["every-morning", "when-api-called"])
        XCTAssertEqual(out["once"] as? Bool, false)
        XCTAssertEqual(out["summary"] as? String, "every morning, when the API is called")
        XCTAssertNotNil(out["next"])

        // Listed, with the tags there are.
        let (_, list) = await api.send("GET", "/api/automation")
        let items = json(list)["items"] as? [[String: Any]]
        XCTAssertEqual(items?.map { $0["name"] as? String }, ["hello.sh"])
        XCTAssertEqual(items?.first?["kind"] as? String, "script")
        let tags = json(list)["tags"] as? [[String: Any]]
        XCTAssertEqual(tags?.count, AutomationTag.allCases.count)
        XCTAssertEqual(tags?.first?["name"] as? String, "every-minute")
        XCTAssertEqual(tags?.first?["kind"] as? String, "schedule")
        let (h, _) = await api.send("GET", "/api/health")
        _ = h
        let (_, hd) = await api.send("GET", "/api/health")
        XCTAssertEqual(json(hd)["automated"] as? Int, 1)

        // A flow, once, after an item, through /api/automation; then taken off with an empty list.
        let (r2, d2) = await api.post("/api/automation", #"{"flow": "greet", "automation": [], "once": true, "after": ["hello"]}"#)
        XCTAssertEqual(r2.status, 200, String(decoding: d2, as: UTF8.self))
        XCTAssertEqual(json(d2)["tags"] as? [String], ["after-an-item"])
        XCTAssertEqual(json(d2)["after"] as? [String], ["hello.sh"])
        XCTAssertEqual(json(d2)["once"] as? Bool, true)
        XCTAssertEqual(json(d2)["kind"] as? String, "flow")
        let (r3, d3) = await api.post("/api/automation", #"{"flow": "greet", "automation": []}"#)
        XCTAssertEqual(r3.status, 200)
        XCTAssertEqual(json(d3)["tags"] as? [String], [])
        let (_, list2) = await api.send("GET", "/api/automation")
        XCTAssertEqual((json(list2)["items"] as? [[String: Any]])?.count, 1)

        // Don't Run means not tagged.
        host.answer = .denied
        let (r4, d4) = await api.post("/api/run", #"{"script": "hello.sh", "automation": "every-day"}"#)
        XCTAssertEqual(r4.status, 403)
        XCTAssertTrue((json(d4)["error"] as? String ?? "").contains("wasn't automated"))
        host.answer = .allowed

        // What can't be: an unknown tag, "after" with nothing to run after, code that isn't a file.
        let (r5, d5) = await api.post("/api/run", #"{"script": "hello.sh", "automation": ["every blue moon"]}"#)
        XCTAssertEqual(r5.status, 400)
        XCTAssertEqual(json(d5)["code"] as? String, "unknown_tag")
        XCTAssertTrue((json(d5)["error"] as? String ?? "").contains("every-morning"))
        let (r6, _) = await api.post("/api/run", #"{"script": "hello.sh", "automation": ["after an item"]}"#)
        XCTAssertEqual(r6.status, 400)
        let (r7, d7) = await api.post("/api/run", #"{"script": "hello.sh", "after": ["nope.sh"]}"#)
        XCTAssertEqual(r7.status, 404, String(decoding: d7, as: UTF8.self))
        let (r8, d8) = await api.post("/api/compose", #"{"source": "print 1", "automation": ["every day"]}"#)
        XCTAssertEqual(r8.status, 400, String(decoding: d8, as: UTF8.self))
        let (r9, _) = await api.post("/api/automation", #"{"script": "hello.sh"}"#)
        XCTAssertEqual(r9.status, 400)
        let (r10, _) = await api.send("DELETE", "/api/automation")
        XCTAssertEqual(r10.status, 405)
        XCTAssertEqual(host.asked.count, 4, "nothing that can't be done is asked about")
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

    /// A run the person started (its cell, a schedule) is theirs: another app asking to stop it
    /// gets the card first, and Keep Running leaves it going. One that has ended isn't asked about.
    func testStoppingARunThePersonStartedAsksFirst() async {
        var mine = RunRecord(kind: .script, name: "backup.sh", file: "backup.sh", arguments: [], command: "bash backup.sh")
        mine.append(.out, "copying\n")
        host.runs[mine.id] = mine
        host.answer = .denied
        let (r, d) = await api.post("/api/runs/\(mine.id.uuidString)/stop", #"{"client": "Stopper", "why": "It's taking too long"}"#)
        XCTAssertEqual(r.status, 403)
        XCTAssertEqual(json(d)["code"] as? String, "denied")
        XCTAssertEqual(json(d)["error"] as? String, "backup.sh wasn't stopped: the person at the Mac chose Keep Running")
        XCTAssertTrue(host.stopped.isEmpty, "Keep Running leaves it going")
        XCTAssertEqual(host.asked.last?.isStop, true)
        XCTAssertEqual(host.asked.last?.client, "Stopper")
        XCTAssertEqual(host.asked.last?.why, "It's taking too long")
        XCTAssertTrue(host.asked.last?.command.hasPrefix("stop backup.sh (started on the Mac") == true, host.asked.last?.command ?? "")

        host.answer = .allowed
        let (r2, d2) = await api.post("/api/runs/\(mine.id.uuidString)/stop", "{}")
        XCTAssertEqual(r2.status, 200)
        XCTAssertEqual(json(d2)["stopping"] as? Bool, true)
        XCTAssertEqual(host.stopped, [mine.id])
        let request = json(d2)["request"] as? String ?? ""
        let (_, q) = await api.send("GET", "/api/requests/\(request)")
        XCTAssertEqual(json(q)["state"] as? String, "stopped")
        XCTAssertEqual(json(q)["kind"] as? String, "stop")
        XCTAssertEqual(json(q)["run_id"] as? String, mine.id.uuidString)

        // Ended already: nothing to ask about.
        let asked = host.asked.count
        host.update(mine.id) { $0.finish(code: 0, state: .succeeded) }
        let (r3, d3) = await api.post("/api/runs/\(mine.id.uuidString)/stop", "{}")
        XCTAssertEqual(r3.status, 200)
        XCTAssertEqual(json(d3)["stopping"] as? Bool, false)
        XCTAssertEqual(host.asked.count, asked)
    }

    /// A flow that runs a script that can't be undone says so on the card, as the script would.
    func testAFlowsCardCarriesTheDangersOfWhatItRuns() async throws {
        let lib = Library(root: folder)
        try "// Tidies\nlet x = run \"wipe\" []\nprint x\n".write(to: lib.composerFolder.appendingPathComponent("tidy.flow"), atomically: true, encoding: .utf8)
        host.catalogValue = Catalog(folder: folder, scripts: lib.scripts(), flows: lib.flows())
        _ = await api.post("/api/compose", #"{"flow": "tidy"}"#)
        XCTAssertEqual(host.asked.last?.dangers, ["runs wipe.sh, which deletes files for good (rm -r / rm -f)"])
        _ = await api.post("/api/compose", #"{"source": "sh \"sudo true\" |> print"}"#)
        XCTAssertEqual(host.asked.last?.dangers, ["runs commands as the administrator (sudo)"])
        _ = await api.post("/api/compose", #"{"flow": "greet"}"#)
        XCTAssertEqual(host.asked.last?.dangers, [])
    }

    /// Every request has an id from the moment it arrives, in the header and the JSON, on
    /// success and refusal alike; /api/requests/{id} answers for it afterwards.
    func testEveryRequestHasAnIdToAskAboutLater() async {
        let (r, d) = await api.post("/api/run", #"{"script": "hello.sh", "client": "My App", "why": "Testing"}"#)
        XCTAssertEqual(r.status, 200)
        let id = json(d)["request"] as? String ?? ""
        XCTAssertNotNil(UUID(uuidString: id), id)
        XCTAssertEqual(r.header("X-Request-Id"), id)
        let runID = json(d)["id"] as? String ?? ""
        let (q, qd) = await api.send("GET", "/api/requests/\(id)")
        XCTAssertEqual(q.status, 200)
        XCTAssertEqual(q.header("X-Request-Id"), id)
        let status = json(qd)
        XCTAssertEqual(status["state"] as? String, "succeeded")
        XCTAssertEqual(status["ok"] as? Bool, true)
        XCTAssertEqual(status["kind"] as? String, "script")
        XCTAssertEqual(status["via"] as? String, "run")
        XCTAssertEqual(status["name"] as? String, "hello.sh")
        XCTAssertEqual(status["client"] as? String, "My App")
        XCTAssertEqual(status["why"] as? String, "Testing")
        XCTAssertEqual(status["run_id"] as? String, runID)
        XCTAssertEqual(status["run_url"] as? String, "/api/runs/\(runID)")
        XCTAssertEqual(status["url"] as? String, "/api/requests/\(id)")
        XCTAssertNotNil(status["asked"]); XCTAssertNotNil(status["answered"])
        let run = status["run"] as? [String: Any]
        XCTAssertEqual(run?["output"] as? String, "hi\n")
        XCTAssertEqual(run?["request"] as? String, id)
        // The run knows its request too, alone and in the list.
        let (_, rd) = await api.send("GET", "/api/runs/\(runID)")
        XCTAssertEqual(json(rd)["request"] as? String, id)
        let (_, ld) = await api.send("GET", "/api/runs")
        XCTAssertEqual((json(ld)["runs"] as? [[String: Any]])?.first?["request"] as? String, id)

        // Refused: the id is there just the same, and the request says why.
        host.answer = .denied
        let (r2, d2) = await api.post("/api/run", #"{"script": "hello.sh"}"#)
        XCTAssertEqual(r2.status, 403)
        let denied = json(d2)["request"] as? String ?? ""
        XCTAssertEqual(r2.header("X-Request-Id"), denied)
        let (_, q2) = await api.send("GET", "/api/requests/\(denied)")
        XCTAssertEqual(json(q2)["state"] as? String, "denied")
        XCTAssertEqual(json(q2)["ok"] as? Bool, false)
        XCTAssertEqual(json(q2)["code"] as? String, "denied")
        XCTAssertTrue((json(q2)["error"] as? String ?? "").contains("Don't Run"))
        host.answer = .unanswered
        let (r3, d3) = await api.post("/api/compose", #"{"flow": "greet"}"#)
        XCTAssertEqual(r3.status, 403)
        let (_, q3) = await api.send("GET", "/api/requests/\(json(d3)["request"] as? String ?? "")")
        XCTAssertEqual(json(q3)["state"] as? String, "not_answered")
        XCTAssertEqual(json(q3)["kind"] as? String, "flow")
        XCTAssertEqual(json(q3)["via"] as? String, "compose")

        // Automated: the same.
        host.answer = .allowed
        let (r4, d4) = await api.post("/api/automation", #"{"script": "hello.sh", "automation": ["every morning"]}"#)
        XCTAssertEqual(r4.status, 200)
        let tagged = json(d4)["request"] as? String ?? ""
        XCTAssertEqual(r4.header("X-Request-Id"), tagged)
        let (_, q4) = await api.send("GET", "/api/requests/\(tagged)")
        XCTAssertEqual(json(q4)["state"] as? String, "automated")
        XCTAssertEqual(json(q4)["kind"] as? String, "automation")
        XCTAssertEqual(json(q4)["via"] as? String, "automation")
        XCTAssertEqual(json(q4)["ok"] as? Bool, true)

        // The list: newest first, without the runs' output; an unknown id is said.
        let (_, list) = await api.send("GET", "/api/requests?limit=2")
        let listed = json(list)["requests"] as? [[String: Any]]
        XCTAssertEqual(listed?.map { $0["request"] as? String }, [tagged, json(d3)["request"] as? String])
        XCTAssertNil(listed?.first?["run"])
        let (g, gd) = await api.send("GET", "/api/requests/\(UUID().uuidString)")
        XCTAssertEqual(g.status, 404)
        XCTAssertEqual(json(gd)["code"] as? String, "unknown_request")
        let (bad, _) = await api.send("GET", "/api/requests/nope")
        XCTAssertEqual(bad.status, 404)
        settings.off = [.runs]
        let (off, _) = await api.send("GET", "/api/requests/\(id)")
        XCTAssertEqual(off.status, 503)
    }

    /// "async": true answers before anyone has clicked; the run goes on by itself, and the
    /// request's id is the way to follow it.
    func testAsyncAnswersBeforeTheClickAndTheRequestFollowsTheRun() async {
        host.behave = { r in r.append(.out, "working\n") }
        let (r, d) = await api.post("/api/run", #"{"script": "hello.sh", "async": true}"#)
        XCTAssertEqual(r.status, 202)
        let id = json(d)["request"] as? String ?? ""
        XCTAssertEqual(r.header("X-Request-Id"), id)
        XCTAssertEqual(json(d)["state"] as? String, "waiting")
        XCTAssertEqual(json(d)["url"] as? String, "/api/requests/\(id)")
        XCTAssertNil(json(d)["id"], "no run yet")
        // It's asked and started on its own.
        var status: [String: Any] = [:]
        for _ in 0..<200 {
            status = json(await api.send("GET", "/api/requests/\(id)").1)
            if status["state"] as? String == "running" { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(status["state"] as? String, "running")
        XCTAssertNil(status["ok"])
        let runID = status["run_id"] as? String ?? ""
        XCTAssertEqual(host.started.map(\.name), ["hello.sh"])
        XCTAssertEqual((status["run"] as? [String: Any])?["output"] as? String, "working\n")
        host.update(UUID(uuidString: runID)!) { r in r.finish(code: 2, state: .failed) }
        let after = json(await api.send("GET", "/api/requests/\(id)").1)
        XCTAssertEqual(after["state"] as? String, "failed")
        XCTAssertEqual(after["ok"] as? Bool, false)
        XCTAssertEqual((after["run"] as? [String: Any])?["code"] as? Int, 2)
        // A run cleared from the app's history: said as such, not lost.
        host.runs = [:]
        let gone = json(await api.send("GET", "/api/requests/\(id)").1)
        XCTAssertEqual(gone["state"] as? String, "gone")
        // Denied while nobody waited: the request says so.
        host.answer = .denied
        let (r2, d2) = await api.post("/api/compose", #"{"flow": "greet", "async": true}"#)
        XCTAssertEqual(r2.status, 202)
        var state = ""
        for _ in 0..<200 {
            state = json(await api.send("GET", "/api/requests/\(json(d2)["request"] as? String ?? "")").1)["state"] as? String ?? ""
            if state == "denied" { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(state, "denied")
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
        let rq = e[0]["request"] as? String ?? ""
        XCTAssertEqual(r.header("X-Request-Id"), rq)
        XCTAssertEqual(e[0]["url"] as? String, "/api/requests/\(rq)")
        XCTAssertEqual(e.map { $0["request"] as? String }, [rq, rq, nil, rq])
        let (_, followed) = await api.send("GET", "/api/requests/\(rq)")
        XCTAssertEqual(json(followed)["state"] as? String, "succeeded")
        XCTAssertEqual(e[2]["text"] as? String, "hi\n")
        XCTAssertEqual(e[3]["state"] as? String, "succeeded")
    }

    func testStreamSaysDenied() async {
        host.answer = .denied
        let (_, d) = await api.post("/api/run", #"{"script": "hello.sh", "stream": true}"#)
        XCTAssertEqual(events(d).map { $0["type"] as? String }, ["waiting", "denied"])
        XCTAssertEqual(events(d).map { $0["request"] as? String }.compactMap { $0 }.count, 2)
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

    func testWithSharingOnARebindingWebsiteStillNeedsTheToken() async {
        settings.allowNetwork = true
        settings.token = "secret"
        // From this Mac, but by a website's own name: it may be a page that rebound its name.
        let (r, _) = await api.send("GET", "/api/runs", headers: ["Host": "evil.example:8768"])
        XCTAssertEqual(r.status, 401)
        let (r2, _) = await api.send("GET", "/api/runs", headers: ["Host": "evil.example:8768", "Authorization": "Bearer secret"])
        XCTAssertEqual(r2.status, 200)
        let (r3, _) = await api.send("GET", "/api/health", headers: ["Host": "127.0.0.1:8768"])
        XCTAssertEqual(r3.status, 200)
    }

    func testAPreflightFromAnotherDeviceGetsTheCORSHeaders() async {
        settings.allowNetwork = true
        settings.token = "secret"
        settings.origins = ["https://app.example.com"]
        let (r, _) = await api.send("OPTIONS", "/api/run", headers: ["Origin": "https://app.example.com", "Host": "192.168.1.5:8768"],
                                    fromLoopback: false)
        XCTAssertEqual(r.status, 204)
        XCTAssertEqual(r.header("Access-Control-Allow-Origin"), "https://app.example.com")
        XCTAssertTrue(r.header("Access-Control-Allow-Headers")?.contains("X-Client") ?? false)
        // Sharing off: another device gets nothing, preflight or not.
        settings.allowNetwork = false
        let (r2, _) = await api.send("OPTIONS", "/api/run", headers: ["Origin": "https://app.example.com"], fromLoopback: false)
        XCTAssertEqual(r2.status, 403)
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

    func testTheDocIsOnePageWithTheCallersAddress() async {
        let (r, d) = await api.send("GET", "/api/doc")
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.header("Content-Type"), "text/markdown; charset=utf-8")
        let doc = String(decoding: d, as: UTF8.self)
        XCTAssertTrue(doc.contains("Base URL: http://127.0.0.1:8768"))
        for route in ["/api/health", "/api/scripts", "/api/flows", "/api/run", "/api/compose", "/api/check", "/api/runs", "/api/runs/{id}/stop", "/api/doc", "/api/automation", "/api/requests/{id}"] {
            XCTAssertTrue(doc.contains(route), route)
        }
        for word in ["endpoint_off", "not_answered", "flow_mistake", "x-ndjson", "\"stream\": true", "v0.1.9", "\"why\"", "every-morning", "confirmBecause", "unknown_tag", "X-Request-Id", "\"async\": true", "unknown_request"] {
            XCTAssertTrue(doc.contains(word), word)
        }
        XCTAssertFalse(doc.contains("Bearer"), "no token while sharing is off")
        // From another device, with sharing on: its own address, and the token it must send.
        settings.allowNetwork = true
        settings.token = "secret"
        let (r2, d2) = await api.send("GET", "/api/doc", headers: ["Host": "192.168.1.5:8768", "Authorization": "Bearer secret"], fromLoopback: false)
        XCTAssertEqual(r2.status, 200)
        let doc2 = String(decoding: d2, as: UTF8.self)
        XCTAssertTrue(doc2.contains("Base URL: http://192.168.1.5:8768"))
        XCTAssertTrue(doc2.contains("Authorization: Bearer secret"))
        // What the panel copies is the same page, with the Mac's own address.
        XCTAssertTrue(APIDoc.text(baseURL: "http://127.0.0.1:8768").hasPrefix("# Tool Mac Tool Run API\n\nBase URL: http://127.0.0.1:8768\n"))
    }

    func testTheStatusPagesExampleFlowChecks() throws {
        let page = StatusPage.html
        let start = try XCTUnwrap(page.range(of: "<textarea id=\"code\">")).upperBound
        let end = try XCTUnwrap(page.range(of: "</textarea>")).lowerBound
        XCTAssertNoThrow(try Flow.check(String(page[start..<end]), scripts: []))
    }
}

final class HTTPTests: XCTestCase {
    func testAHugeChunkSizeIsTooLargeNotACrash() {
        var p = HTTPParser()
        let raw = "POST /api/run HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n1\r\na\r\n7fffffffffffffff\r\n"
        XCTAssertThrowsError(try p.feed(Data(raw.utf8))) { e in
            XCTAssertEqual((e as? HTTPError)?.status, 413)
        }
    }

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

    func testNewOutputJoiningTheLastCharacterIsKept() {
        // "\r" then "\n" make one character in Swift; the "\n" is still new output.
        var r = RunRecord(kind: .script, name: "a", file: "a", command: "a")
        r.append(.out, "line\r")
        let mark = r.receivedBytes
        r.append(.out, "\nnext")
        XCTAssertEqual(r.newOutput(since: mark).map(\.text).joined(), "\nnext")
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

/// The snippets the panel's Copy for… buttons copy: each has this Mac's address, the token only
/// when there is one, and code that's code (Python and JavaScript parse).
final class APIClientTests: XCTestCase {
    func testEverySnippetHasTheAddressAndTheRules() {
        for client in APIClient.allCases {
            let text = client.text(baseURL: "http://127.0.0.1:8768")
            XCTAssertTrue(text.contains("http://127.0.0.1:8768"), client.title)
            XCTAssertTrue(text.contains("why"), "\(client.title) says to send why")
            XCTAssertTrue(text.contains("client") || text.contains("CLIENT"), "\(client.title) names the caller")
            XCTAssertFalse(text.contains("Bearer"), "\(client.title): no token unless sharing is on")
            XCTAssertTrue(client.text(baseURL: "http://127.0.0.1:8768", token: "tok3n").contains("Bearer tok3n"), client.title)
            XCTAssertFalse(client.help.isEmpty)
        }
        XCTAssertEqual(APIClient.allCases.map(\.title), ["curl", "Python", "JavaScript", "Swift", "Shortcuts", "AI Agent"])
    }

    func testThePythonAndJavaScriptParse() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clients-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for token in [nil, "tok3n"] {
            if ShellEnvironment.shared.find("python3") != nil {
                let py = dir.appendingPathComponent("client.py")
                try APIClient.python.text(baseURL: "http://127.0.0.1:8768", token: token).write(to: py, atomically: true, encoding: .utf8)
                let r = try ScriptProcess(shell: "python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' \(ShellEnvironment.quote(py.path))",
                                          workingDirectory: dir).runToEnd()
                XCTAssertEqual(r.code, 0, r.err)
            }
            if ShellEnvironment.shared.find("node") != nil {
                let js = dir.appendingPathComponent("client.mjs")
                try APIClient.javascript.text(baseURL: "http://127.0.0.1:8768", token: token).write(to: js, atomically: true, encoding: .utf8)
                let r = try ScriptProcess(shell: "node --check \(ShellEnvironment.quote(js.path))", workingDirectory: dir).runToEnd()
                XCTAssertEqual(r.code, 0, r.err)
            }
        }
    }
}
