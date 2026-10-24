import Foundation
@testable import RunCore
import XCTest

/// Finding the way without reading every route: a search by words, the groups alone, "next" on
/// every answer; and the requests a client sent, each result handed over once.
final class DiscoveryTests: XCTestCase {
    var folder: URL!
    var host: FakeRunHost!
    var settings = APISettings()
    var api: RunAPI!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("discovery-\(UUID().uuidString)", isDirectory: true)
        let lib = Library(root: folder)
        _ = try lib.ensure()
        try "#!/bin/bash\n# Says hello\necho hello \"$@\"\n".write(to: folder.appendingPathComponent("hello.sh"), atomically: true, encoding: .utf8)
        try "#!/bin/bash\n# What the sky will do\n# Tags: forecast, rain umbrella\n# Input: A city\necho sunny\n"
            .write(to: lib.folder(.utilities).appendingPathComponent("sky.sh"), atomically: true, encoding: .utf8)
        try "// Greets\n// Tags: welcome\nlet x = run \"hello.sh\" []\nprint x\n".write(to: lib.composerFolder.appendingPathComponent("greet.flow"), atomically: true, encoding: .utf8)
        host = FakeRunHost(folder: folder, scripts: lib.scripts(), flows: lib.flows())
        settings = APISettings()
        api = RunAPI(host: host, version: "0.1.9") { [unowned self] in self.settings }
        api.poll = 5_000_000
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func paths(_ d: Data, kind: String = "route") -> [String] {
        (json(d)["results"] as? [[String: Any]] ?? []).filter { $0["kind"] as? String == kind }.compactMap { r in
            kind == "route" ? (r["method"] as? String).map { $0 + " " + (r["path"] as? String ?? "") } : r["name"] as? String
        }
    }

    private func next(_ d: Data) -> [String] {
        (json(d)["next"] as? [[String: Any]] ?? []).map { "\($0["method"] as? String ?? "") \($0["path"] as? String ?? "")" }
    }

    // MARK: search

    func testSearchFindsTheRoutesForWhatsWanted() async {
        let (r, d) = await api.send("GET", "/api/search?q=remember%20a%20birthday")
        XCTAssertEqual(r.status, 200)
        let found = paths(d)
        XCTAssertEqual(json(d)["words"] as? [String], ["remember", "birthday"])
        XCTAssertTrue(found.prefix(3).contains("POST /api/memory/remember"), "\(found)")
        XCTAssertLessThan(found.count, 15, "a few, not every route")
        XCTAssertLessThanOrEqual(json(d)["count"] as? Int ?? 99, 10)

        // By what someone would say, not the path's words: a job's status.
        let status = paths(await api.send("GET", "/api/search?q=check%20status%20of%20my%20job").1)
        XCTAssertTrue(status.prefix(3).contains("GET /api/requests/{id}"), "\(status)")
        let open = paths(await api.send("GET", "/api/search?q=pending%20requests").1)
        XCTAssertEqual(open.first, "GET /api/requests/open")
        let stop = paths(await api.send("GET", "/api/search?q=cancel+a+running+script").1)
        XCTAssertTrue(stop.prefix(3).contains("POST /api/runs/{id}/stop"), "\(stop)")
        let notes = paths(await api.send("GET", "/api/search?q=delete%20a%20note&in=routes").1)
        XCTAssertEqual(notes.first, "DELETE /api/library/files/{name}")

        // Each route says how it's called, and what it matched.
        let first = (json(d)["results"] as? [[String: Any]])?.first
        XCTAssertNotNil(first?["call"])
        XCTAssertNotNil(first?["tags"])
        XCTAssertFalse((first?["matched"] as? [String] ?? []).isEmpty)
        XCTAssertFalse(next(d).isEmpty)
    }

    func testSearchFindsScriptsAndFlowsByTheirTagsWithTheRequestThatRunsThem() async {
        let (_, d) = await api.send("GET", "/api/search?q=umbrella")
        XCTAssertEqual(paths(d, kind: "script"), ["utilities/sky.sh"])
        let hit = (json(d)["results"] as? [[String: Any]])?.first { $0["kind"] as? String == "script" }
        XCTAssertEqual(hit?["tags"] as? [String], ["forecast", "rain", "umbrella"])
        let run = hit?["run"] as? [String: Any]
        XCTAssertEqual(run?["path"] as? String, "/api/run")
        let body = run?["body"] as? [String: Any]
        XCTAssertEqual(body?["script"] as? String, "utilities/sky.sh")
        XCTAssertEqual(body?["async"] as? Bool, true)
        XCTAssertEqual(body?["args"] as? [String], ["<A city>"])
        XCTAssertEqual(next(d).first, "POST /api/run")

        let welcome = await api.send("GET", "/api/search?q=welcome").1
        XCTAssertEqual(paths(welcome, kind: "flow"), ["greet.flow"])
        let hello = await api.send("GET", "/api/search?q=hello&in=scripts").1
        XCTAssertEqual(paths(hello, kind: "script"), ["hello.sh"])
        let routesOnly = await api.send("GET", "/api/search?q=hello&in=routes").1
        XCTAssertTrue(paths(routesOnly, kind: "script").isEmpty)
        // The tags are in the lists too.
        let (_, scripts) = await api.send("GET", "/api/scripts?group=utilities")
        XCTAssertEqual((json(scripts)["scripts"] as? [[String: Any]])?.first?["tags"] as? [String], ["forecast", "rain", "umbrella"])
    }

    func testSearchSaysWhatItNeeds() async {
        let (r, d) = await api.send("GET", "/api/search")
        XCTAssertEqual(r.status, 400)
        XCTAssertEqual(json(d)["code"] as? String, "missing_query")
        let (r2, _) = await api.send("GET", "/api/search?q=x&in=everything")
        XCTAssertEqual(r2.status, 400)
        let (r3, d3) = await api.send("GET", "/api/search?q=x&group=nope")
        XCTAssertEqual(json(d3)["code"] as? String, "unknown_group")
        XCTAssertEqual(r3.status, 400)
        let (_, d4) = await api.send("GET", "/api/search?q=zzqqxx")
        XCTAssertEqual(json(d4)["count"] as? Int, 0)
        XCTAssertEqual(next(d4).first, "GET /api/endpoints?brief=true")
        let (_, d5) = await api.send("GET", "/api/search?q=trash&group=library&limit=3")
        XCTAssertEqual(json(d5)["count"] as? Int, 3)
        XCTAssertTrue(paths(d5).allSatisfy { $0.contains("/api/library") }, "\(paths(d5))")
    }

    func testTheGroupsAloneAndEndpointsByWords() async {
        let (_, all) = await api.send("GET", "/api/endpoints")
        let (r, d) = await api.send("GET", "/api/endpoints?brief=true")
        XCTAssertEqual(r.status, 200)
        let groups = json(d)["groups"] as? [[String: Any]] ?? []
        XCTAssertEqual(groups.map { $0["id"] as? String }, APIRoutes.groups.map(\.id))
        XCTAssertNil(groups.first?["routes"] as? [Any], "a count, not the routes")
        XCTAssertNotNil(groups.first?["tags"])
        XCTAssertLessThan(d.count, all.count / 3)
        let (_, q) = await api.send("GET", "/api/endpoints?q=upcoming%20birthdays")
        XCTAssertEqual(paths(q).first, "GET /api/memory/upcoming")
        XCTAssertTrue(paths(q, kind: "script").isEmpty)
    }

    func testEveryRouteHasTagsAndTheSearchStems() {
        for r in APIRoutes.all { XCTAssertFalse(r.tags.isEmpty, r.key) }
        XCTAssertEqual(APISearch.words("Birthdays, categories & scheduled"), ["birthday", "category", "schedul"])
        XCTAssertEqual(APISearch.words("schedule"), APISearch.words("schedules"))
        XCTAssertEqual(APISearch.words("strings"), APISearch.words("string"))
        XCTAssertEqual(APISearch.words("running stopped"), ["run", "stop"])
        XCTAssertEqual(APISearch.query("how do I run a script"), ["run", "script"])
        XCTAssertEqual(APISearch.query("the"), ["the"], "only stop words: they're the words then")
        XCTAssertEqual(ScriptInput.declaredTags(in: "#!/bin/sh\n# Does it\n# Tags: A, b c\n# tags: c d\necho\n# Tags: late\n"), ["a", "b", "c", "d"])
        XCTAssertEqual(Library.summary("# Tags: a b\n# Does it\n"), "Does it")
    }

    // MARK: next

    func testEveryAnswerSaysWhatToCallNext() async throws {
        let (_, h) = await api.send("GET", "/api/health")
        XCTAssertTrue(next(h).contains("GET /api/requests/open"), "\(next(h))")
        let (_, s) = await api.send("GET", "/api/scripts")
        XCTAssertEqual(next(s).first, "POST /api/run")
        // The path's own values filled in.
        _ = await api.post("/api/library/files", #"{"name": "groceries", "text": "eggs"}"#)
        let (_, n) = await api.send("GET", "/api/library/files/groceries")
        XCTAssertTrue(next(n).contains("PUT /api/library/files/groceries"), "\(next(n))")
        XCTAssertTrue(next(n).contains("POST /api/library/files/groceries/append"))
        // And what it was asked with.
        let (_, rec) = await api.send("GET", "/api/memory/recall?name=ada")
        XCTAssertTrue(next(rec).contains("GET /api/mind/nodes/ada"), "\(next(rec))")
        // MEMORY's library routes: the library's next calls, at MEMORY's paths; SYSTEM-DOCS reads only.
        let (_, m) = await api.send("GET", "/api/memory/files/PEOPLE/outline")
        XCTAssertTrue(next(m).contains("GET /api/memory/files/PEOPLE"), "\(next(m))")
        // A route that isn't one: a search for its words.
        let (r404, d404) = await api.send("GET", "/api/rememberz/things")
        XCTAssertEqual(r404.status, 404)
        XCTAssertEqual(next(d404).first, "GET /api/search?q=rememberz%20things")
        // An unknown request: the open list.
        let (_, u) = await api.send("GET", "/api/requests/\(UUID().uuidString)")
        XCTAssertEqual(next(u).first, "GET /api/requests/open")
        // Left out when asked.
        let (_, quiet) = await api.send("GET", "/api/health?next=false")
        XCTAssertNil(json(quiet)["next"])
        // Every hint in the table is for a real route, and points at real ones.
        for key in APINext.table.keys {
            let parts = key.split(separator: " ", maxSplits: 1).map(String.init)
            XCTAssertNotNil(APIRoutes.match(parts[0], parts[1].replacingOccurrences(of: "{name}", with: "x").replacingOccurrences(of: "{id}", with: "x")), key)
            for h in APINext.table[key]! {
                let path = String(h.path.split(separator: "?").first!)
                let concrete = path.replacingOccurrences(of: "{name}", with: "x").replacingOccurrences(of: "{id}", with: "x").replacingOccurrences(of: "{other}", with: "x")
                XCTAssertNotNil(APIRoutes.match(h.method, path) ?? APIRoutes.match(h.method, concrete), "\(key) → \(h.method) \(h.path)")
            }
        }
    }

    // MARK: requests, each result handed over once

    private func waitFor(_ id: String, _ delivery: String) async -> [String: Any] {
        var out: [String: Any] = [:]
        for _ in 0..<400 {
            let (_, d) = await api.send("GET", "/api/requests/open")
            out = (json(d)["requests"] as? [[String: Any]] ?? []).first { $0["request"] as? String == id } ?? [:]
            if out["delivery"] as? String == delivery { break }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return out
    }

    func testAResultIsHandedOverOnceThenCleared() async {
        host.behave = { r in r.append(.out, "working\n") }
        let (r, d) = await api.post("/api/run", #"{"script": "hello.sh", "async": true}"#)
        XCTAssertEqual(r.status, 202)
        let id = json(d)["request"] as? String ?? ""
        XCTAssertTrue(next(d).contains("GET /api/requests/\(id)"))
        XCTAssertNotNil(json(d)["note"])

        // Running: reading it collects nothing.
        let running = await waitFor(id, "pending")
        XCTAssertEqual(running["position"] as? Int, 1)
        while (json(await api.send("GET", "/api/requests/\(id)").1)["state"] as? String) != "running" { try? await Task.sleep(nanoseconds: 2_000_000) }
        let (_, during) = await api.send("GET", "/api/requests/\(id)")
        XCTAssertEqual(json(during)["delivery"] as? String, "pending")
        let runID = json(during)["run_id"] as? String ?? ""
        XCTAssertTrue(next(during).contains("POST /api/runs/\(runID)/stop"), "\(next(during))")

        host.update(UUID(uuidString: runID)!) { $0.finish(code: 0, state: .succeeded) }
        let ready = await waitFor(id, "ready")
        XCTAssertEqual(ready["state"] as? String, "succeeded")
        let (_, h) = await api.send("GET", "/api/health")
        XCTAssertEqual((json(h)["requests"] as? [String: Any])?["ready"] as? Int, 1)

        // A peek leaves it there.
        let (_, peek) = await api.send("GET", "/api/requests/\(id)?peek=true")
        XCTAssertEqual(json(peek)["delivery"] as? String, "ready")
        XCTAssertNotNil(json(peek)["run"])
        // The first read takes it, with the run.
        let (_, first) = await api.send("GET", "/api/requests/\(id)")
        XCTAssertEqual(json(first)["delivery"] as? String, "delivered")
        XCTAssertEqual((json(first)["run"] as? [String: Any])?["output"] as? String, "working\n")
        // Then it's cleared: how it ended, without the output; off the open list.
        let (_, again) = await api.send("GET", "/api/requests/\(id)")
        XCTAssertEqual(json(again)["delivery"] as? String, "cleared")
        XCTAssertEqual(json(again)["cleared_by"] as? String, "collected")
        XCTAssertEqual(json(again)["state"] as? String, "succeeded")
        XCTAssertEqual(json(again)["ok"] as? Bool, true)
        XCTAssertNil(json(again)["run"])
        XCTAssertTrue(next(again).contains("GET /api/runs/\(runID)"), "the run is still there")
        let (_, open) = await api.send("GET", "/api/requests/open")
        XCTAssertEqual(json(open)["count"] as? Int, 0)
        // The history still has it.
        let (_, history) = await api.send("GET", "/api/requests")
        XCTAssertEqual((json(history)["requests"] as? [[String: Any]])?.first?["request"] as? String, id)
    }

    func testTheOpenListIsInOrderAndLeavesOutWhatWasAnsweredAlready() async {
        // Waited for: answered in its own answer, so never open.
        let (_, waited) = await api.post("/api/run", #"{"script": "hello.sh"}"#)
        XCTAssertEqual(json(waited)["delivery"] as? String, "delivered")
        host.answer = .denied
        let (refused, rd) = await api.post("/api/run", #"{"script": "hello.sh"}"#)
        XCTAssertEqual(refused.status, 403)
        XCTAssertEqual(json(rd)["delivery"] as? String, "delivered")
        let (_, streamed) = await api.post("/api/run", #"{"script": "hello.sh", "stream": true}"#)
        XCTAssertFalse(streamed.isEmpty)
        let none = await api.send("GET", "/api/requests/open").1
        XCTAssertEqual(json(none)["count"] as? Int, 0)

        // Three sent without waiting: in the order they came.
        host.answer = .allowed
        var ids: [String] = []
        for name in ["hello.sh", "greet", "hello.sh"] {
            let body = name == "greet" ? #"{"flow": "greet", "async": true}"# : #"{"script": "hello.sh", "async": true}"#
            ids.append(json(await api.post(name == "greet" ? "/api/compose" : "/api/run", body).1)["request"] as? String ?? "")
        }
        _ = await waitFor(ids[2], "ready")
        let (_, d) = await api.send("GET", "/api/requests/open")
        let list = json(d)["requests"] as? [[String: Any]] ?? []
        XCTAssertEqual(list.map { $0["request"] as? String }, ids)
        XCTAssertEqual(list.map { $0["position"] as? Int }, [1, 2, 3])
        XCTAssertEqual(json(d)["ready"] as? Int, 3)
        XCTAssertEqual(json(d)["order"] as? String, "oldest first")
        XCTAssertNil(list.first?["run"], "the list doesn't hand results over")
        XCTAssertTrue(next(d).contains("GET /api/requests/\(ids[0])"))

        // One dismissed without reading; the rest cleared at once.
        let (del, dd) = await api.send("DELETE", "/api/requests/\(ids[1])")
        XCTAssertEqual(del.status, 200)
        XCTAssertEqual(json(dd)["cleared_by"] as? String, "dismissed")
        let two = await api.send("GET", "/api/requests/open").1
        XCTAssertEqual((json(two)["requests"] as? [[String: Any]])?.map { $0["request"] as? String }, [ids[0], ids[2]])
        let (_, c) = await api.post("/api/requests/clear", "{}")
        XCTAssertEqual(json(c)["cleared"] as? [String], [ids[0], ids[2]])
        let empty = await api.send("GET", "/api/requests/open").1
        XCTAssertEqual(json(empty)["count"] as? Int, 0)
        let dismissed = await api.send("GET", "/api/requests/\(ids[1])").1
        XCTAssertEqual(json(dismissed)["cleared_by"] as? String, "dismissed")
    }

    func testARequestStillWaitingCanBeTakenBack() async {
        host.holdApprovals = true
        let (_, d) = await api.post("/api/run", #"{"script": "hello.sh", "async": true}"#)
        let id = json(d)["request"] as? String ?? ""
        while host.asked.isEmpty { try? await Task.sleep(nanoseconds: 2_000_000) }
        let (_, w) = await api.send("GET", "/api/requests/\(id)")
        XCTAssertEqual(json(w)["state"] as? String, "waiting")
        XCTAssertTrue(next(w).contains("DELETE /api/requests/\(id)"), "\(next(w))")
        let waiting = await api.send("GET", "/api/requests/open").1
        XCTAssertEqual(json(waiting)["waiting"] as? Int, 1)

        let (r, t) = await api.send("DELETE", "/api/requests/\(id)")
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(json(t)["state"] as? String, "withdrawn")
        try? await Task.sleep(nanoseconds: 30_000_000)
        let (_, after) = await api.send("GET", "/api/requests/\(id)")
        XCTAssertEqual(json(after)["state"] as? String, "withdrawn", "the card going away doesn't make it denied")
        XCTAssertEqual(json(after)["ok"] as? Bool, false)
        XCTAssertTrue(host.started.isEmpty)
        let left = await api.send("GET", "/api/requests/open").1
        XCTAssertEqual(json(left)["count"] as? Int, 0)

        // Running: stop it first.
        host.holdApprovals = false
        host.behave = { r in r.append(.out, "working\n") }
        let rq = json(await api.post("/api/run", #"{"script": "hello.sh", "async": true}"#).1)["request"] as? String ?? ""
        while host.started.isEmpty { try? await Task.sleep(nanoseconds: 2_000_000) }
        _ = await waitFor(rq, "pending")
        try? await Task.sleep(nanoseconds: 20_000_000)
        let (busy, bd) = await api.send("DELETE", "/api/requests/\(rq)")
        XCTAssertEqual(busy.status, 409)
        XCTAssertEqual(json(bd)["code"] as? String, "still_running")
    }
}
