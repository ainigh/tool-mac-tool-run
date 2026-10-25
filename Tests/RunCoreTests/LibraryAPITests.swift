import Foundation
@testable import RunCore
import XCTest

/// The file library over HTTP: answered at once (nothing is asked on the Mac), each call with an
/// id; Straw's routes; and the list of every route, which each answer to.
final class LibraryAPITests: XCTestCase {
    var folder: URL!
    var notes: URL!
    var host: FakeRunHost!
    var settings = APISettings()
    var api: RunAPI!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("libapi-\(UUID().uuidString)", isDirectory: true)
        notes = folder.appendingPathComponent("LIBRARY", isDirectory: true)
        let lib = Library(root: folder)
        try lib.ensure()
        try lib.addExamples(for: .browser)
        host = FakeRunHost(folder: folder, scripts: lib.scripts(), flows: lib.flows())
        settings = APISettings()
        let root = notes!
        let home = folder!
        api = RunAPI(host: host, version: "0.1.9", library: { FileLibrary(root: root) },
                     shelves: { Shelves(memory: Memory(files: FileLibrary(root: home.appendingPathComponent("MEMORY"), shelf: .memory), mind: MindStore(root: home.appendingPathComponent("MIND"))),
                                        systemDocs: FileLibrary(root: home.appendingPathComponent("SYSTEM-DOCS"), shelf: .systemDocs)) },
                     chrome: ChromePage { _, _ in "TMR_NOT_RUNNING" }) { [unowned self] in self.settings }
        api.poll = 5_000_000
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func put(_ name: String, _ text: String) async -> (HTTPResponse, [String: Any]) {
        let (r, d) = await api.send("PUT", "/api/library/files/\(name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name)",
                                    body: Data(text.utf8), headers: ["Content-Type": "text/markdown"])
        return (r, json(d))
    }

    func testNotesByNameWithoutAskingAndEachWithAnID() async throws {
        // Written (created), read, replaced: a key and its value.
        let (w, wd) = await put("groceries", "# Groceries\n- eggs\n")
        XCTAssertEqual(w.status, 200, "\(wd)")
        XCTAssertEqual(wd["new"] as? Bool, true)
        XCTAssertEqual(wd["action"] as? String, "created")
        XCTAssertEqual(wd["name"] as? String, "groceries")
        XCTAssertEqual(wd["op"] as? String, "write")
        let id = try XCTUnwrap(wd["request"] as? String)
        XCTAssertEqual(w.headers.first { $0.0 == "X-Request-Id" }?.1, id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: notes.appendingPathComponent("groceries.md").path))

        let (_, rd) = await api.send("GET", "/api/library/files/groceries")
        XCTAssertEqual(json(rd)["text"] as? String, "# Groceries\n- eggs\n")
        XCTAssertEqual(json(rd)["title"] as? String, "Groceries")
        let (raw, rawd) = await api.send("GET", "/api/library/files/groceries.md?format=text")
        XCTAssertEqual(String(decoding: rawd, as: UTF8.self), "# Groceries\n- eggs\n")
        XCTAssertTrue(raw.headers.contains { $0.0 == "Content-Type" && $0.1.hasPrefix("text/markdown") })
        let (_, again) = await api.post("/api/library/files/groceries/append", #"{"text": "- milk"}"#)
        XCTAssertEqual(json(again)["new"] as? Bool, false)
        XCTAssertEqual(json(again)["action"] as? String, "appended")
        XCTAssertEqual(try FileLibrary(root: notes).read("groceries").text, "# Groceries\n- eggs\n- milk\n")

        // The same through the one endpoint that does everything.
        let (c, cd) = await api.post("/api/library", #"{"op": "create", "name": "Trip to Lagos", "text": "Call the bank.\n", "client": "Notes App"}"#)
        XCTAssertEqual(c.status, 200, "\(json(cd))")
        let (dup, dd) = await api.post("/api/library", #"{"op": "create", "name": "trip to lagos"}"#)
        XCTAssertEqual(dup.status, 409)
        XCTAssertEqual(json(dd)["code"] as? String, "already_exists")
        XCTAssertNotNil(json(dd)["request"], "a refusal has its id too")
        let (_, list) = await api.send("GET", "/api/library/files")
        XCTAssertEqual((json(list)["notes"] as? [[String: Any]])?.compactMap { $0["name"] as? String }, ["groceries", "Trip to Lagos"])
        let (_, names) = await api.post("/api/library", #"{"op": "names"}"#)
        XCTAssertEqual(json(names)["names"] as? [String], ["groceries", "Trip to Lagos"])
        let (_, many) = await api.post("/api/library", #"{"op": "read_many", "names": ["groceries", "nope"]}"#)
        XCTAssertEqual((json(many)["notes"] as? [Any])?.count, 1)
        XCTAssertEqual(json(many)["missing"] as? [String], ["nope"])

        // Nothing was asked on the Mac, and every call is in the log, by its id.
        XCTAssertTrue(host.asked.isEmpty)
        let (_, op) = await api.send("GET", "/api/library/operations/\(id)")
        XCTAssertEqual(json(op)["op"] as? String, "write")
        XCTAssertEqual(json(op)["summary"] as? String, "created groceries (19 bytes)")
        let (_, same) = await api.send("GET", "/api/requests/\(id)")
        XCTAssertEqual(json(same)["kind"] as? String, "library", "the library's ids answer where every request's does")
        let (_, ops) = await api.send("GET", "/api/library/operations?limit=3")
        XCTAssertEqual((json(ops)["operations"] as? [[String: Any]])?.first?["op"] as? String, "read_many")
        XCTAssertEqual((json(ops)["operations"] as? [[String: Any]])?.count, 3)
        let logged = await api.libraryLog.recent(20)
        XCTAssertTrue(logged.contains { $0.client == "Notes App" })

        // A note that isn't there: 404, with the names near it.
        let (miss, md) = await api.send("GET", "/api/library/files/grocery")
        XCTAssertEqual(miss.status, 404)
        XCTAssertEqual(json(md)["code"] as? String, "not_found")
        XCTAssertEqual(json(md)["fix"] as? String, "Near it: groceries")
        let (bad, bd) = await api.post("/api/library", #"{"op": "fly"}"#)
        XCTAssertEqual(bad.status, 400)
        XCTAssertEqual(json(bd)["code"] as? String, "unknown_op")
        let (noop, _) = await api.post("/api/library", #"{"name": "x"}"#)
        XCTAssertEqual(noop.status, 400)
        let (badName, bn) = await put(".secret", "x")
        XCTAssertEqual(badName.status, 400)
        XCTAssertEqual(bn["code"] as? String, "bad_name")
    }

    func testDeletingRestoringAndSearching() async throws {
        _ = await put("draft", "one about the bank")
        _ = await put("bank", "# Bank\nOpen a savings account.\n")
        _ = await put("index", "See [[bank]].\n")
        // Deleted twice: draft (1) and draft (2) in the library's Trash.
        let (d1, dd1) = await api.send("DELETE", "/api/library/files/draft")
        XCTAssertEqual(d1.status, 200)
        XCTAssertEqual((json(dd1)["trash"] as? [String: Any])?["file"] as? String, "draft (1).md")
        _ = await put("draft", "two")
        let (_, dd2) = await api.send("DELETE", "/api/library/files/draft")
        XCTAssertEqual((json(dd2)["trash"] as? [String: Any])?["number"] as? Int, 2)
        let (_, trash) = await api.send("GET", "/api/library/trash")
        XCTAssertEqual((json(trash)["trash"] as? [[String: Any]])?.compactMap { $0["number"] as? Int }, [2, 1])
        let (_, back) = await api.post("/api/library/trash/restore", #"{"name": "draft", "number": 1}"#)
        XCTAssertEqual(json(back)["name"] as? String, "draft")
        XCTAssertEqual(try FileLibrary(root: notes).read("draft").text, "one about the bank")

        // Full text: the lines; find: the names alone, the best first.
        let (_, s) = await api.send("GET", "/api/library/search?q=bank")
        let results = json(s)["results"] as? [[String: Any]] ?? []
        XCTAssertEqual(results.compactMap { $0["name"] as? String }, ["bank", "index", "draft"])
        XCTAssertEqual((results.first?["lines"] as? [[String: Any]])?.first?["line"] as? Int, 1)
        let (_, f) = await api.send("GET", "/api/library/find?q=savings%20account")
        XCTAssertEqual(json(f)["names"] as? [String], ["bank"])
        let (_, any) = await api.post("/api/library", #"{"op": "find", "q": "savings two", "match": "any"}"#)
        XCTAssertEqual(Set(json(any)["names"] as? [String] ?? []), ["bank"])
        let (_, links) = await api.send("GET", "/api/library/files/bank/backlinks")
        XCTAssertEqual((json(links)["results"] as? [[String: Any]])?.compactMap { $0["name"] as? String }, ["index"])
        let (_, outline) = await api.send("GET", "/api/library/files/bank/outline")
        XCTAssertEqual((json(outline)["headings"] as? [[String: Any]])?.first?["text"] as? String, "Bank")
        let (_, stats) = await api.send("GET", "/api/library/stats")
        XCTAssertEqual(json(stats)["notes"] as? Int, 3)
        XCTAssertEqual(json(stats)["trashed"] as? Int, 1)
        let (_, renamed) = await api.post("/api/library/files/draft/rename", #"{"to": "Draft one"}"#)
        XCTAssertEqual(json(renamed)["name"] as? String, "Draft one")
        let (_, exists) = await api.send("GET", "/api/library/files/draft/exists")
        XCTAssertEqual(json(exists)["exists"] as? Bool, false)
        let (_, emptied) = await api.post("/api/library/trash/empty", "{}")
        XCTAssertEqual(json(emptied)["deleted"] as? Int, 1)

        // Switched off in the app: 503, and nothing done.
        settings.off = [.library]
        let (off, od) = await api.send("GET", "/api/library/files")
        XCTAssertEqual(off.status, 503)
        XCTAssertEqual(json(od)["code"] as? String, "endpoint_off")
        let (health, hd) = await api.send("GET", "/api/health")
        XCTAssertEqual(health.status, 200)
        XCTAssertEqual(json(hd)["library"] as? Bool, false, "the switch, by its name")
    }

    /// GET /api/endpoints lists every route in its groups, and every one of them is answered (not
    /// "no such route").
    func testEveryListedRouteIsARoute() async throws {
        let (r, d) = await api.send("GET", "/api/endpoints")
        XCTAssertEqual(r.status, 200)
        let groups = json(d)["groups"] as? [[String: Any]] ?? []
        XCTAssertEqual(groups.compactMap { $0["id"] as? String }, ["about", "scripts", "straw", "library", "memory", "mind", "system-docs", "screen", "browser", "web", "tools", "runs"])
        XCTAssertEqual(json(d)["count"] as? Int, APIRoutes.all.count)
        let (_, one) = await api.send("GET", "/api?group=library")
        XCTAssertEqual((json(one)["groups"] as? [[String: Any]])?.count, 1)
        let (unknown, _) = await api.send("GET", "/api/endpoints?group=nope")
        XCTAssertEqual(unknown.status, 400)

        let id = UUID().uuidString
        for route in APIRoutes.all {
            _ = await put("note", "text")
            let path = route.path.replacingOccurrences(of: "{name}", with: "note").replacingOccurrences(of: "{id}", with: id)
            let (resp, body) = await api.send(route.method, path, body: Data("{}".utf8), headers: ["Content-Type": "application/json"])
            let error = json(body)["error"] as? String ?? ""
            XCTAssertFalse(resp.status == 404 && error.hasPrefix("no such route"), "\(route.method) \(route.path): \(String(decoding: body, as: UTF8.self))")
            XCTAssertNotEqual(resp.status, 405, "\(route.method) \(route.path)")
        }
        let (none, nd) = await api.send("GET", "/api/nowhere")
        XCTAssertEqual(none.status, 404)
        XCTAssertTrue((json(nd)["error"] as? String)?.contains("/api/endpoints") == true)
        // The doc lists them, by group.
        let (_, doc) = await api.send("GET", "/api/doc")
        let text = String(decoding: doc, as: UTF8.self)
        for g in APIRoutes.groups { XCTAssertTrue(text.contains("### \(g.title)"), g.title) }
        XCTAssertTrue(text.contains("/api/library/files/{name}"))
    }

    func testStrawHasRoutesOfItsOwn() async throws {
        let (r, d) = await api.send("GET", "/api/straw")
        XCTAssertEqual(r.status, 200)
        let words = json(d)["words"] as? [[String: Any]] ?? []
        XCTAssertEqual(words.count, 25)
        XCTAssertEqual(words.first?["word"] as? String, "open")
        XCTAssertTrue((json(d)["scripts"] as? [[String: Any]])?.contains { $0["name"] as? String == "browser/hacker-news.straw" } == true)
        XCTAssertNotNil(json(d)["runner"] as? String)

        try XCTSkipIf(ShellEnvironment.shared.find("python3") == nil, "needs python3")
        let (ok, okd) = await api.post("/api/straw/check", #"{"source": "open example.com\nread title\n"}"#)
        XCTAssertEqual(ok.status, 200)
        XCTAssertEqual(json(okd)["ok"] as? Bool, true, "\(json(okd))")
        XCTAssertEqual(json(okd)["steps"] as? Int, 2)
        let (_, bad) = await api.send("POST", "/api/straw/check", body: Data("open example.com\nclik \"More\"\n".utf8), headers: ["Content-Type": "text/plain"])
        XCTAssertEqual(json(bad)["ok"] as? Bool, false)
        XCTAssertEqual(json(bad)["line"] as? Int, 2)
        XCTAssertEqual(json(bad)["fix"] as? String, "Did you mean click? The words: " + RunAPI.strawWords.map(\.word).joined(separator: ", "))
        XCTAssertTrue(host.asked.isEmpty, "a check asks nothing")

        // Run: a mistake is said before anything is asked; good code shows on the card in full.
        let (mistake, _) = await api.post("/api/straw/run", #"{"source": "clik \"x\""}"#)
        XCTAssertEqual(mistake.status, 400)
        XCTAssertTrue(host.asked.isEmpty)
        let (run, rd) = await api.post("/api/straw/run", #"{"source": "open news.ycombinator.com\nread all css \".titleline > a\"\n", "name": "HN titles", "client": "My App", "why": "Show the headlines"}"#)
        XCTAssertEqual(run.status, 200, "\(json(rd))")
        let asked = try XCTUnwrap(host.asked.last)
        XCTAssertEqual(asked.name, "HN titles")
        XCTAssertEqual(asked.source, "# Where: side by side\nopen news.ycombinator.com\nread all css \".titleline > a\"\n",
                       "the card shows the Straw code, and where it works: side by side, unless the app says otherwise")
        XCTAssertTrue(asked.itemID?.hasPrefix("browser/hn-titles-") == true, asked.itemID ?? "")
        XCTAssertEqual(json(rd)["request"] as? String, asked.id.uuidString)
        // Where the app says, or the code's own line.
        _ = await api.post("/api/straw/run", #"{"source": "open example.com", "where": "background"}"#)
        XCTAssertEqual(host.asked.last?.source, "# Where: background\nopen example.com")
        _ = await api.post("/api/straw/run", ##"{"source": "# Where: on screen\nopen example.com"}"##)
        XCTAssertEqual(host.asked.last?.source, "# Where: on screen\nopen example.com")
        let (badWhere, bw) = await api.post("/api/straw/run", #"{"source": "open example.com", "where": "upside down"}"#)
        XCTAssertEqual(badWhere.status, 400)
        XCTAssertEqual(json(bw)["code"] as? String, "bad_where")
        let (byName, _) = await api.post("/api/straw/run", #"{"script": "hacker-news"}"#)
        XCTAssertEqual(byName.status, 200)
        XCTAssertEqual(host.asked.last?.name, "browser/hacker-news.straw")
        XCTAssertNil(host.asked.last?.source, "a script of the folder's runs as it is")
        // Asked to work somewhere, a script of the folder's runs as a copy that says so.
        let (placed, pd) = await api.post("/api/straw/run", #"{"script": "hacker-news", "where": "side by side"}"#)
        XCTAssertEqual(placed.status, 200, "\(json(pd))")
        XCTAssertTrue(host.asked.last?.source?.hasPrefix("# Where: side by side\n") == true, host.asked.last?.source ?? "")
        let (notStraw, nd) = await api.post("/api/straw/run", #"{"script": "browser.sh"}"#)
        XCTAssertEqual(notStraw.status, 404, "\(json(nd))")
    }
}
