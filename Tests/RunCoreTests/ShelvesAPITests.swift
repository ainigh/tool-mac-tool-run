import Foundation
@testable import RunCore
import XCTest

/// MEMORY, the mind, SYSTEM-DOCS, showing and copying, and Chrome's page, over HTTP: answered at
/// once (nothing asked on the Mac), each call with an id.
final class ShelvesAPITests: XCTestCase {
    var home: URL!
    var host: FakeRunHost!
    var settings = APISettings()
    var api: RunAPI!
    var memory: Memory!
    /// What the pretend Chrome was asked: the scripts' arguments.
    let chromeAsked = ScreenLog()

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("shelves-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        host = FakeRunHost(folder: home)
        let h = home!
        let m = Memory(files: FileLibrary(root: h.appendingPathComponent("MEMORY"), shelf: .memory), mind: MindStore(root: h.appendingPathComponent("MIND")))
        memory = m
        let shipped = h.appendingPathComponent("shipped", isDirectory: true)
        try FileManager.default.createDirectory(at: shipped, withIntermediateDirectories: true)
        try "# Prompt for an assistant\n\nRead START-HERE, then remember what matters.\n".write(to: shipped.appendingPathComponent("PROMPT-ASSISTANT.md"), atomically: true, encoding: .utf8)
        let asked = chromeAsked
        let chrome = ChromePage { script, args in
            asked.copy(args.first ?? "")
            if script.contains("execute active tab") {
                let js = args.first ?? ""
                if js.contains("present: shownCount > 0") { return #"{"text": "Compute", "present": true, "count": 2, "hidden": 0, "lines": ["Compute", "Workers & Compute"], "url": "https://dash.cloudflare.com"}"# }
                if js.contains("const want = fold(") {
                    return #"{"text": "Compute", "count": 1, "found": [{"text": "Compute", "kind": "link", "clickable": true, "exact": true, "shown": true, "where": "in view", "side": "the top left", "in": ["navigation “Sidebar”"]}], "highlighted": true}"#
                }
                return #"{"title": "Cloudflare", "url": "https://dash.cloudflare.com", "text": "Account Home\nCompute", "chars": 20, "truncated": false}"#
            }
            if script.contains("tabs of win") { return "1\t1\t1\tCloudflare\thttps://dash.cloudflare.com\n1\t2\t0\tDocs\thttps://developers.cloudflare.com" }
            return "Cloudflare\nhttps://dash.cloudflare.com\nfalse\n1"
        }
        api = RunAPI(host: host, version: "0.2.0", library: { FileLibrary(root: h.appendingPathComponent("LIBRARY")) },
                     shelves: { Shelves(memory: m, systemDocs: FileLibrary(root: h.appendingPathComponent("SYSTEM-DOCS"), shelf: .systemDocs), shipped: shipped) },
                     chrome: chrome) { [unowned self] in self.settings }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    func testMemoryComesReadyAndKeepsTheMindInStep() async throws {
        let (r, d) = await api.send("GET", "/api/memory")
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(json(d)["notes"] as? Int, 9, "its nine files, there from the first call")
        XCTAssertTrue((json(d)["operations"] as? [[String: Any]])?.contains { $0["op"] as? String == "remember" } == true)
        let (_, names) = await api.send("GET", "/api/memory/names")
        XCTAssertEqual(Set(json(names)["names"] as? [String] ?? []), Set(Memory.defaultNames))

        // A new file is a node of the mind; renamed, its node follows.
        let (w, wd) = await api.send("PUT", "/api/memory/files/RECIPES", body: Data("# Recipes\n".utf8), headers: ["Content-Type": "text/markdown"])
        XCTAssertEqual(w.status, 200, "\(json(wd))")
        XCTAssertEqual(json(wd)["mind"] as? [String], ["| RECIPES"])
        let (_, rn) = await api.post("/api/memory/files/RECIPES/rename", #"{"to": "COOKING"}"#)
        XCTAssertEqual(json(rn)["mind"] as? [String], ["| RECIPES = COOKING"])
        XCTAssertNotNil(memory.mind.graph().node(MindNodeID("COOKING")))
        let (bad, bd) = await api.send("PUT", "/api/memory/files/me@home", body: Data("x".utf8), headers: ["Content-Type": "text/plain"])
        XCTAssertEqual(bad.status, 400, "a name the mind can't have")
        XCTAssertNotNil(json(bd)["fix"])

        // Remembering, and recalling.
        let (rem, remd) = await api.post("/api/memory/remember", #"{"category": "people", "about": "Ada Lovelace", "text": "Met at the conference", "links": [{"label": "works at", "to": "Acme", "category": "ORGANIZATIONS"}], "notes": ["birthday 03-14"], "client": "Assistant"}"#)
        XCTAssertEqual(rem.status, 200, "\(json(remd))")
        XCTAssertEqual(json(remd)["file"] as? String, "PEOPLE")
        XCTAssertTrue((json(remd)["added_to_mind"] as? [String])?.contains("| ada lovelace - works at | acme") == true)
        let (_, rec) = await api.send("GET", "/api/memory/recall?name=ada")
        XCTAssertEqual(json(rec)["found"] as? Bool, true)
        XCTAssertEqual(json(rec)["categories"] as? [String], ["PEOPLE"])
        let (_, members) = await api.send("GET", "/api/memory/categories/PEOPLE/members")
        XCTAssertEqual(json(members)["members"] as? [String], ["ada lovelace"])
        let (_, cats) = await api.send("GET", "/api/memory/categories")
        XCTAssertEqual((json(cats)["categories"] as? [[String: Any]])?.first { $0["name"] as? String == "ORGANIZATIONS" }?["members"] as? Int, 1)
        let (up, _) = await api.send("GET", "/api/memory/upcoming?days=400")
        XCTAssertEqual(up.status, 200)
        XCTAssertTrue(host.asked.isEmpty, "nothing asked on the Mac")
    }

    func testTheMindAnswersWithoutTheNotation() async throws {
        let (a, ad) = await api.post("/api/mind/add", #"{"facts": [{"from": "Sam", "label": "writes", "to": "the Paper"}, {"from": "ana", "label": "reviews", "to": "the paper", "notes": ["date 2026-11-03 - by friday"]}], "client": "Notes"}"#)
        XCTAssertEqual(a.status, 200, "\(json(ad))")
        XCTAssertEqual(json(ad)["added"] as? [String], ["| sam - writes | the paper", "| ana - reviews @date 2026-11-03 – by friday | the paper"])
        XCTAssertEqual(json(ad)["rewritten"] as? [String], ["date 2026-11-03 - by friday → date 2026-11-03 – by friday"])
        XCTAssertTrue(memory.mind.log().contains("— "), "stamped with when and who")
        XCTAssertTrue(memory.mind.log().contains("· Notes"))

        let (_, about) = await api.send("GET", "/api/mind/nodes/The%20Paper")
        XCTAssertEqual(json(about)["name"] as? String, "the paper", "looked up as a person means it")
        XCTAssertEqual((json(about)["links"] as? [Any])?.count, 2)
        let (_, missing) = await api.send("GET", "/api/mind/nodes/nobody")
        XCTAssertEqual(json(missing)["code"] as? String, "not_found")
        let (_, nb) = await api.send("GET", "/api/mind/nodes/sam/neighbors?depth=2")
        XCTAssertEqual(json(nb)["names"] as? [String], ["the paper", "ana"])
        let (_, path) = await api.send("GET", "/api/mind/path?from=sam&to=ana")
        XCTAssertEqual(json(path)["nodes"] as? [String], ["sam", "the paper", "ana"])
        let (_, find) = await api.send("GET", "/api/mind/find?q=paper")
        XCTAssertEqual((json(find)["names"] as? [String])?.first, "the paper")
        let (_, edges) = await api.send("GET", "/api/mind/edges?label=reviews")
        XCTAssertEqual(json(edges)["count"] as? Int, 1)
        let (_, notes) = await api.send("GET", "/api/mind/notes?kind=date")
        XCTAssertEqual(json(notes)["count"] as? Int, 1)
        let (_, q) = await api.post("/api/mind/query", #"{"q": "| x - reviews | y"}"#)
        XCTAssertEqual(json(q)["lines"] as? [String], ["| ana - reviews @date 2026-11-03 – by friday | the paper"])
        let (_, ctx) = await api.post("/api/mind/context", #"{"text": "Has Sam finished?"}"#)
        XCTAssertEqual(json(ctx)["lines"] as? [String], ["| sam - writes | the paper"])
        let (_, prompt) = await api.post("/api/mind/prompt", #"{"messages": "user: Sam moved to Lagos"}"#)
        XCTAssertTrue((json(prompt)["prompt"] as? String)?.contains("Existing nodes: sam, the paper") == true)
        XCTAssertNotNil(json(prompt)["grammar"])

        // A model's reply, appended: only its ```mm lines, checked; what's known is left out.
        let reply = "Sure.\n```mm\n| sam - moved to | lagos\n| sam - writes | the paper\n```"
        let body = String(decoding: try JSONSerialization.data(withJSONObject: ["text": reply]), as: UTF8.self)
        let (_, check) = await api.post("/api/mind/check", body)
        XCTAssertEqual(json(check)["would_add"] as? [String], ["| sam - moved to | lagos"])
        XCTAssertEqual(json(check)["known"] as? [String], ["| sam - writes | the paper"])
        XCTAssertFalse(memory.mind.log().contains("lagos"), "a check adds nothing")
        let (_, ap) = await api.post("/api/mind/append", body)
        XCTAssertEqual(json(ap)["added"] as? [String], ["| sam - moved to | lagos"])
        let (bad, bd) = await api.post("/api/mind/append", #"{"lines": ["| fine | line", "| broken -"]}"#)
        XCTAssertEqual(bad.status, 400)
        XCTAssertEqual(json(bd)["code"] as? String, "bad_lines")
        XCTAssertEqual((json(bd)["problems"] as? [[String: Any]])?.count, 1)
        let (scope, _) = await api.post("/api/mind/append", #"{"lines": ["| @ talk", "| @ talk ="]}"#)
        XCTAssertEqual(scope.status, 400, "a scope delete is the person's")

        let (_, rn) = await api.post("/api/mind/rename", #"{"name": "the paper", "to": "thesis"}"#)
        XCTAssertEqual(json(rn)["added"] as? [String], ["| the paper = thesis"])
        let (_, fg) = await api.post("/api/mind/forget", #"{"name": "lagos"}"#)
        XCTAssertEqual(json(fg)["added"] as? [String], ["| lagos ="])
        XCTAssertNil(memory.mind.graph().node(MindNodeID("lagos")))
        XCTAssertTrue(memory.mind.log().contains("| sam - moved to | lagos"), "still in the log's history")
        let (_, nt) = await api.post("/api/mind/note", #"{"name": "sam", "note": "todo call back"}"#)
        XCTAssertEqual(json(nt)["added"] as? [String], ["| sam @todo call back"])

        let (log, logd) = await api.send("GET", "/api/mind/log")
        XCTAssertTrue(log.headers.contains { $0.0 == "Content-Type" && $0.1.hasPrefix("text/plain") })
        XCTAssertTrue(String(decoding: logd, as: UTF8.self).hasPrefix("The mind:"))
        let (_, canon) = await api.send("GET", "/api/mind/canonical?format=json")
        XCTAssertTrue((json(canon)["lines"] as? [String])?.contains("| sam @todo call back") == true)
        let (_, any) = await api.post("/api/mind", #"{"op": "stats"}"#)
        XCTAssertGreaterThan(json(any)["nodes"] as? Int ?? 0, 9)
        let (_, layout) = await api.send("GET", "/api/mind/layout")
        XCTAssertEqual((json(layout)["positions"] as? [Any])?.count, memory.mind.graph().nodes.count)
        let (unknown, _) = await api.post("/api/mind", #"{"op": "nope"}"#)
        XCTAssertEqual(unknown.status, 400)
        XCTAssertTrue(host.asked.isEmpty)
    }

    func testSystemDocsReadButNeverWritten() async throws {
        let (r, d) = await api.send("GET", "/api/system-docs")
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(json(d)["read_only"] as? Bool, true)
        XCTAssertFalse((json(d)["operations"] as? [[String: Any]] ?? []).contains { $0["changes"] as? Bool == true })
        let (_, start) = await api.send("GET", "/api/system-docs/files/START-HERE")
        XCTAssertTrue((json(start)["text"] as? String)?.contains("PROMPT-ASSISTANT") == true)
        let (_, prompt) = await api.send("GET", "/api/system-docs/files/prompt-assistant?format=text")
        XCTAssertTrue(String(decoding: prompt, as: UTF8.self).hasPrefix("# Prompt for an assistant"))
        let (w, wd) = await api.send("PUT", "/api/system-docs/files/START-HERE", body: Data("mine".utf8), headers: ["Content-Type": "text/plain"])
        XCTAssertEqual(w.status, 403)
        XCTAssertEqual(json(wd)["code"] as? String, "read_only")
        let (del, _) = await api.send("DELETE", "/api/system-docs/files/START-HERE")
        XCTAssertEqual(del.status, 403)
        let (op, _) = await api.post("/api/system-docs", #"{"op": "write", "name": "x", "text": "y"}"#)
        XCTAssertEqual(op.status, 403)
        let (_, s) = await api.send("GET", "/api/system-docs/search?q=remember")
        XCTAssertTrue((json(s)["results"] as? [[String: Any]])?.contains { $0["name"] as? String == "PROMPT-ASSISTANT" } == true)
    }

    func testPresentAndCopyAnything() async throws {
        let (r, d) = await api.post("/api/present", #"{"shelf": "memory", "name": "people", "why": "So you can check it", "client": "Assistant"}"#)
        XCTAssertEqual(r.status, 200, "\(json(d))")
        XCTAssertEqual(json(d)["shown"] as? Bool, true)
        let shown = try XCTUnwrap(host.screen.shown.last)
        XCTAssertEqual(shown.name, "PEOPLE")
        XCTAssertEqual(shown.shelf, .memory)
        XCTAssertEqual(shown.source, "MEMORY/PEOPLE.md")
        XCTAssertEqual(shown.client, "Assistant")
        XCTAssertEqual(shown.why, "So you can check it")

        let (_, t) = await api.post("/api/present", #"{"title": "Steps", "text": "{\"a\": 1}", "format": "json", "copy": true}"#)
        XCTAssertEqual(json(t)["copied"] as? Bool, true)
        XCTAssertEqual(host.screen.shown.last?.text, "{\n  \"a\" : 1\n}")
        let (_, c) = await api.post("/api/clipboard", #"{"text": "hello"}"#)
        XCTAssertEqual(json(c)["copied"] as? Bool, true)
        XCTAssertEqual(host.screen.copied.last, "hello")
        let (none, _) = await api.post("/api/clipboard", #"{}"#)
        XCTAssertEqual(none.status, 400)

        // Any answer: "copy": true, "present": true.
        _ = await api.post("/api/mind/add", #"{"from": "sam", "label": "writes", "to": "paper"}"#)
        let (_, q) = await api.post("/api/mind/query", #"{"q": "| sam | x", "copy": true, "present": true}"#)
        XCTAssertEqual(json(q)["copied"] as? Bool, true)
        XCTAssertEqual(json(q)["presented"] as? Bool, true)
        XCTAssertEqual(host.screen.copied.last, "| sam - writes | paper")
        XCTAssertEqual(host.screen.shown.last?.format, .mind)
        let (_, read) = await api.send("GET", "/api/memory/files/IDEAS?copy=true")
        XCTAssertEqual(json(read)["copied"] as? Bool, true)
        XCTAssertTrue(host.screen.copied.last?.hasPrefix("# IDEAS") == true)
        let (_, node) = await api.post("/api/present", #"{"mind": "sam"}"#)
        XCTAssertEqual(json(node)["title"] as? String, "sam")
        XCTAssertTrue(host.screen.shown.last?.text.contains("```mm\n| sam - writes | paper") == true)
        XCTAssertTrue(host.asked.isEmpty)
    }

    func testChromesPageForGuidingThePerson() async throws {
        let (st, std) = await api.send("GET", "/api/browser")
        XCTAssertEqual(st.status, 200)
        XCTAssertEqual(json(std)["chrome"] as? String, "open")
        XCTAssertEqual(json(std)["javascript"] as? Bool, true)
        let (_, url) = await api.send("GET", "/api/browser/url")
        XCTAssertEqual(json(url)["url"] as? String, "https://dash.cloudflare.com")
        XCTAssertEqual(json(url)["title"] as? String, "Cloudflare")
        let (_, tabs) = await api.send("GET", "/api/browser/tabs")
        XCTAssertEqual((json(tabs)["tabs"] as? [[String: Any]])?.map { $0["active"] as? Bool }, [true, false])
        let (_, page) = await api.send("GET", "/api/browser/page")
        XCTAssertEqual(json(page)["text"] as? String, "Account Home\nCompute")
        let (_, has) = await api.send("GET", "/api/browser/has?text=Compute")
        XCTAssertEqual(json(has)["present"] as? Bool, true)
        XCTAssertEqual(json(has)["answer"] as? String, "yes")
        XCTAssertTrue(chromeAsked.copied.last?.contains(#""Compute""#) == true, "the words go in as a JavaScript string, not pasted into code")
        let (_, find) = await api.send("GET", "/api/browser/find?text=compute")
        XCTAssertEqual(json(find)["lines"] as? [String], ["The link “Compute” is in view, at the top left, in navigation “Sidebar”."])
        let (hl, _) = await api.post("/api/browser/highlight", #"{"text": "Compute"}"#)
        XCTAssertEqual(hl.status, 200)
        let (wrong, _) = await api.send("GET", "/api/browser/highlight")
        XCTAssertEqual(wrong.status, 405)
        let (noText, _) = await api.send("GET", "/api/browser/has")
        XCTAssertEqual(noText.status, 400)

        // Chrome closed: said so, with the fix (never opened).
        let closed = RunAPI(host: host, version: "0.2.0", chrome: ChromePage { _, _ in "TMR_NOT_RUNNING" }) { APISettings() }
        let (c, cd) = await closed.send("GET", "/api/browser/page")
        XCTAssertEqual(c.status, 409)
        XCTAssertEqual(json(cd)["code"] as? String, "chrome_not_open")
        XCTAssertNotNil(json(cd)["fix"])
        // JavaScript off in Chrome: the error osascript gives, explained.
        let e = ChromePage.explain("execution error: Google Chrome got an error: Executing JavaScript through AppleScript is turned off. (12)")
        XCTAssertEqual(e.code, .javascriptOff)
        XCTAssertTrue(e.fix?.contains("Allow JavaScript from Apple Events") == true)

        // Switched off in the panel.
        settings.off = [.browser]
        let (off, _) = await api.send("GET", "/api/browser/url")
        XCTAssertEqual(off.status, 503)
    }
}
