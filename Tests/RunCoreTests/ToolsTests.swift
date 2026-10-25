import Foundation
@testable import RunCore
import XCTest

/// The tools a model calls by name (`/api/tools`), the web read from this Mac (`/api/web`), and
/// Chrome opening a page: what a client hands its model as is, and passes the calls of through.
final class ToolsTests: XCTestCase {
    var home: URL!
    var host: FakeRunHost!
    var settings = APISettings()
    var api: RunAPI!
    /// What the pretend web was asked for.
    let asked = ScreenLog()
    /// What the pretend Chrome was sent.
    let chromeAsked = ScreenLog()

    static let page = """
    <!doctype html><html><head><title>Hours &amp; admission | Louvre</title>
    <meta name="description" content="Plan your visit">
    <script>var x = "<p>not this</p>";</script><style>p { color: red }</style></head>
    <body><nav><a href="/en">Home</a></nav>
    <main><h1>Opening hours</h1>
    <p>The museum is open Monday, Thursday, Saturday and Sunday from 9&nbsp;am to 6&nbsp;pm.</p>
    <p>Closed on Tuesdays.</p>
    <ul><li>Wednesday: 9 am to 9 pm</li><li>Friday: 9 am to 9 pm</li></ul>
    <table><tr><td>Adults</td><td>€22</td></tr></table>
    <p><a href="/en/tickets">Buy tickets</a> or read the <a href="https://api.example.org/docs">API docs</a>.</p>
    <p>\(String(repeating: "More words about the museum and its collections. ", count: 12))</p>
    </main><footer>© Louvre</footer></body></html>
    """

    static let duck = """
    <div class="result results_links"><a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.louvre.fr%2Fen%2Fvisit%2Fhours&amp;rut=abc">Hours, admission | <b>Louvre</b></a>
    <a class="result__snippet" href="x">Open <b>9 am</b> to 6 pm, closed Tuesdays.</a></div>
    <div class="result result--ad"><a class="result__a" href="https://duckduckgo.com/y.js?ad_domain=ads.example">An ad</a></div>
    <div class="result"><a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fen.wikipedia.org%2Fwiki%2FLouvre">Louvre - Wikipedia</a>
    <a class="result__snippet">The Louvre is the world's most-visited museum.</a></div>
    """

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("tools-\(UUID().uuidString)", isDirectory: true)
        let lib = Library(root: home.appendingPathComponent("Scripts"))
        _ = try lib.ensure()
        try "#!/bin/bash\n# What the sky will do\n# Input: A city\necho sunny\n".write(to: lib.folder(.utilities).appendingPathComponent("sky.sh"), atomically: true, encoding: .utf8)
        host = FakeRunHost(folder: lib.root, scripts: lib.scripts(), flows: lib.flows())
        let h = home!
        let m = Memory(files: FileLibrary(root: h.appendingPathComponent("MEMORY"), shelf: .memory), mind: MindStore(root: h.appendingPathComponent("MIND")))
        let seen = asked
        let web = Web { url in
            seen.copy(url.absoluteString)
            let s = url.absoluteString
            func answer(_ text: String, _ type: String, status: Int = 200) -> Web.Fetched { .init(data: Data(text.utf8), status: status, contentType: type, url: url) }
            if s.contains("html.duckduckgo.com") { return answer(s.contains("nothing") ? "<html>no results</html>" : Self.duck, "text/html; charset=utf-8") }
            if s.contains("bing.com") {
                return answer(#"<ol><li class="b_algo"><h2><a href="https://example.com/found">Found <strong>it</strong></a></h2><div><p>From Bing.</p></div></li></ol>"#, "text/html")
            }
            if s.contains("api.example.org/rates") { return answer(#"{"base": "EUR", "rates": {"JPY": 163.2}}"#, "application/json") }
            if s.contains("missing") { return answer("<html><title>Not found</title><body>No such page</body></html>", "text/html", status: 404) }
            return answer(Self.page, "text/html; charset=utf-8")
        }
        let chromeSeen = chromeAsked
        let chrome = ChromePage { script, args in
            chromeSeen.copy((script.contains("make new tab") ? "open " : "") + args.joined(separator: " | "))
            // One window of the person's; one screen; the app's own window, once made, is 7.
            if script.hasPrefix("// JavaScript") { return #"[{"frame": {"left": 0, "top": 0, "right": 1440, "bottom": 900}, "visible": {"left": 0, "top": 25, "right": 1440, "bottom": 860}}]"# }
            if script.contains("minimized of w") { return "1\t100,100,1300,800\tfalse" }
            if script.contains("on bounds4") { return "7" }
            if script.contains("make new tab") { return "Example Domain\n\(args.first ?? "")\nfalse\n2" }
            if script.contains("execute active tab") {
                return #"{"title": "Example Domain", "url": "https://example.com/", "text": "Example Domain\nMore information...", "chars": 30, "truncated": false, "links": [{"text": "More information...", "url": "https://www.iana.org/domains/example"}]}"#
            }
            return "Example Domain\nhttps://example.com/\nfalse\n1"
        }
        api = RunAPI(host: host, version: "0.3.0", library: { FileLibrary(root: h.appendingPathComponent("LIBRARY")) },
                     shelves: { Shelves(memory: m, systemDocs: FileLibrary(root: h.appendingPathComponent("SYSTEM-DOCS"), shelf: .systemDocs)) },
                     chrome: chrome, web: web) { [unowned self] in self.settings }
        api.poll = 5_000_000
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    func call(_ tool: String, _ arguments: String, extra: String = "") async -> (HTTPResponse, [String: Any]) {
        let (r, d) = await api.post("/api/tools/\(tool)", #"{"arguments": \#(arguments), "client": "Tester"\#(extra)}"#)
        return (r, json(d))
    }

    // MARK: the list

    func testTheToolsAreListedWithAGuideAndExamplesForAModel() async {
        let (r, d) = await api.send("GET", "/api/tools")
        XCTAssertEqual(r.status, 200)
        let tools = json(d)["tools"] as? [[String: Any]] ?? []
        let names = tools.compactMap { $0["name"] as? String }
        for n in ["find", "run_script", "web_search", "web_fetch", "browser", "straw", "library", "remember", "recall", "memory", "mind", "show", "copy", "docs", "call_api"] {
            XCTAssertTrue(names.contains(n), n)
        }
        XCTAssertEqual(Set(names).count, names.count, "each name once")
        let fetch = tools.first { $0["name"] as? String == "web_fetch" }
        XCTAssertEqual(fetch?["asks_on_the_mac"] as? Bool, false)
        XCTAssertEqual(fetch?["answers"] as? String, "at once")
        XCTAssertEqual((fetch?["args"] as? [[String: Any]])?.first?["name"] as? String, "url")
        XCTAssertEqual((fetch?["args"] as? [[String: Any]])?.first?["required"] as? Bool, true)
        let run = tools.first { $0["name"] as? String == "run_script" }
        XCTAssertEqual(run?["asks_on_the_mac"] as? Bool, true)
        XCTAssertEqual(run?["stream"] as? Bool, true)
        XCTAssertFalse((json(d)["guide"] as? [String] ?? []).isEmpty)
        let examples = json(d)["examples"] as? [[String: Any]] ?? []
        XCTAssertFalse(examples.isEmpty)
        // Every example calls a tool there is, with the arguments it takes.
        for e in examples {
            for step in e["steps"] as? [[String: Any]] ?? [] {
                let call = step["call"] as? [String: Any]
                let tool = Tools.named(call?["tool"] as? String ?? "")?.tool
                XCTAssertNotNil(tool, "\(call ?? [:])")
                for k in (call?["arguments"] as? [String: Any] ?? [:]).keys { XCTAssertTrue(tool?.args.contains { $0.name == k } == true, "\(tool?.name ?? ""): \(k)") }
            }
        }
        // A switch turned off takes its tools off the list.
        settings.off = [.web]
        let (_, off) = await api.send("GET", "/api/tools")
        XCTAssertFalse((json(off)["tools"] as? [[String: Any]] ?? []).contains { $0["name"] as? String == "web_fetch" })
        let (_, all) = await api.send("GET", "/api/tools?all=true")
        XCTAssertEqual((json(all)["tools"] as? [[String: Any]] ?? []).first { $0["name"] as? String == "web_fetch" }?["on"] as? Bool, false)
        let (o, od) = await call("web_fetch", #"{"url": "https://example.com"}"#)
        XCTAssertEqual(o.status, 503)
        XCTAssertEqual(od["code"] as? String, "endpoint_off")
    }

    // MARK: calling them

    func testACallIsTheRouteItStandsFor() async throws {
        let (w, wd) = await call("library", #"{"op": "append", "name": "Shopping", "text": "- eggs"}"#)
        XCTAssertEqual(w.status, 200, "\(wd)")
        XCTAssertEqual(wd["tool"] as? String, "library")
        XCTAssertEqual(w.header("X-Tool"), "library")
        let (_, rd) = await call("library", #"{"op": "Read", "name": "Shopping"}"#)
        XCTAssertTrue((rd["text"] as? String ?? "").contains("eggs"), "\(rd)")
        // The names a model gives: a tool's other name, an op it implies, an argument's other name.
        let (n, nd) = await call("notes", #"{"op": "find", "query": "Shopping"}"#)
        XCTAssertEqual(n.status, 200, "\(nd)")
        let (rm, rmd) = await call("memorize", #"{"category": "people", "name": "Ada", "text": "The person's sister", "notes": "birthday 03-14"}"#)
        XCTAssertEqual(rm.status, 200, "\(rmd)")
        XCTAssertEqual(rmd["file"] as? String, "PEOPLE")
        let (_, rc) = await call("recall", #"{"name": "Ada"}"#)
        XCTAssertEqual(rc["found"] as? Bool, true, "\(rc)")
        let (_, up) = await call("birthdays", "{}")
        XCTAssertEqual(up["op"] as? String, "upcoming", "\(up)")
        let (l, ld) = await call("list_runs", "{}")
        XCTAssertEqual(l.status, 200, "\(ld)")
        XCTAssertNotNil(ld["runs"])
        // Flat arguments, without "arguments", are taken too.
        let (f, fd) = await api.post("/api/tools/find", #"{"q": "what the sky will do"}"#)
        XCTAssertEqual(f.status, 200)
        XCTAssertTrue((json(fd)["lines"] as? [String] ?? []).contains { $0.hasPrefix("script utilities/sky.sh") && $0.contains("takes: A city") }, "\(json(fd))")
    }

    func testAMissedCallSaysWhatItTakesAndWhatFits() async {
        // No such tool: the tools there are, and what fits its words.
        let (u, ud) = await call("fly_to_mars", "{}")
        XCTAssertEqual(u.status, 404)
        XCTAssertEqual(ud["code"] as? String, "unknown_tool")
        XCTAssertTrue((ud["error"] as? String ?? "").contains("web_fetch"))
        let (g, gd) = await call("search_the_internet", #"{"q": "cats"}"#)
        XCTAssertEqual(g.status, 404)
        XCTAssertTrue((gd["error"] as? String ?? "").contains("tool web_search"), "\(gd)")
        // An argument missing: what it takes.
        let (m, md) = await call("web_fetch", "{}")
        XCTAssertEqual(m.status, 400)
        XCTAssertEqual(md["code"] as? String, "missing_argument")
        XCTAssertTrue((md["takes"] as? String ?? "").contains("url (string)"))
        // An op there isn't: the route says which there are, and the tool what it takes.
        let (o, od) = await call("library", #"{"op": "fly"}"#)
        XCTAssertEqual(o.status, 400, "\(od)")
        XCTAssertNotNil(od["takes"])
        // Asking the browser to click: straw.
        let (c, cd) = await call("browser", #"{"op": "click", "text": "Sign in"}"#)
        XCTAssertEqual(c.status, 400)
        XCTAssertTrue((cd["error"] as? String ?? "").contains("straw"))
    }

    func testAScriptsNameIsRunAsItIsAndARunStreams() async throws {
        let (r, d) = await call("sky", #"{"args": ["Leeds"]}"#, extra: #", "why": "The person asked""#)
        XCTAssertEqual(r.status, 200, "\(d)")
        XCTAssertEqual(d["tool"] as? String, "run_script")
        XCTAssertEqual(host.asked.last?.name, "utilities/sky.sh")
        XCTAssertEqual(host.asked.last?.arguments, ["Leeds"])
        XCTAssertEqual(host.asked.last?.why, "The person asked")
        XCTAssertEqual(host.asked.last?.client, "Tester")
        // Streamed: the run's own events.
        let (s, sd) = await api.post("/api/tools/run_script", #"{"arguments": {"script": "utilities/sky.sh", "args": "Paris, France"}, "stream": true, "why": "x"}"#)
        XCTAssertEqual(s.status, 200)
        XCTAssertEqual(host.asked.last?.arguments, ["Paris, France"], "one string is one argument")
        let types = events(sd).compactMap { $0["type"] as? String }
        XCTAssertEqual(types.first, "waiting")
        XCTAssertEqual(types.last, "done")
    }

    // MARK: the web

    func testAPageIsReadAsTextWithItsLinks() async throws {
        let (r, d) = await call("web_fetch", #"{"url": "louvre.fr/en/visit"}"#)
        XCTAssertEqual(r.status, 200, "\(d)")
        XCTAssertEqual(d["url"] as? String, "https://louvre.fr/en/visit")
        XCTAssertEqual(d["kind"] as? String, "page")
        XCTAssertEqual(d["title"] as? String, "Hours & admission | Louvre")
        XCTAssertEqual(d["description"] as? String, "Plan your visit")
        let text = d["text"] as? String ?? ""
        XCTAssertTrue(text.hasPrefix("Opening hours\nThe museum is open Monday, Thursday, Saturday and Sunday from 9 am to 6 pm.\nClosed on Tuesdays.\n- Wednesday: 9 am to 9 pm"), text)
        XCTAssertTrue(text.contains("Adults | €22"), text)
        XCTAssertFalse(text.contains("not this") || text.contains("color: red") || text.contains("© Louvre"), "only its main part, no scripts or styles: \(text)")
        let links = d["links"] as? [[String: Any]] ?? []
        XCTAssertEqual(links.first?["url"] as? String, "https://louvre.fr/en/tickets")
        XCTAssertEqual(links.last?["text"] as? String, "API docs")
        // The lines with some words, for a long page.
        let (_, f) = await call("web_fetch", #"{"url": "https://louvre.fr/en/visit", "find": "Sunday hours"}"#)
        XCTAssertEqual(f["lines"] as? [String], ["Opening hours", "The museum is open Monday, Thursday, Saturday and Sunday from 9 am to 6 pm."], "in the page's order")
        // Cut at max, and said so.
        let (_, short) = await call("web_fetch", #"{"url": "https://louvre.fr", "max": 200}"#)
        XCTAssertEqual(short["truncated"] as? Bool, true)
        XCTAssertNotNil(short["more"])
        // A JSON API's answer, as JSON.
        let (_, j) = await call("web_fetch", #"{"url": "https://api.example.org/rates?base=EUR"}"#)
        XCTAssertEqual(j["kind"] as? String, "json")
        XCTAssertEqual(((j["json"] as? [String: Any])?["rates"] as? [String: Any])?["JPY"] as? Double, 163.2)
        // A page that isn't there says so.
        let (_, m) = await call("web_fetch", #"{"url": "https://example.com/missing"}"#)
        XCTAssertEqual(m["status"] as? Int, 404)
        XCTAssertTrue((m["problem"] as? String ?? "").contains("404"))
    }

    func testTheWebNeverReachesThisMacOrItsNetwork() async {
        for url in ["http://127.0.0.1:8768/api/health", "localhost:3000", "http://192.168.1.1", "http://10.0.0.2/admin", "http://printer.local",
                    "http://[::1]/", "http://169.254.169.254/latest", "file:///etc/passwd", "http://2130706433/"] {
            let (r, d) = await call("web_fetch", #"{"url": "\#(url)"}"#)
            XCTAssertTrue([400, 403].contains(r.status), "\(url): \(r.status) \(d)")
        }
        XCTAssertTrue(asked.copied.isEmpty, "nothing was fetched: \(asked.copied)")
        XCTAssertFalse(Web.isLocal("example.com"))
        XCTAssertFalse(Web.isLocal("8.8.8.8"))
        XCTAssertFalse(Web.isLocal("172.32.0.1"))
        XCTAssertTrue(Web.isLocal("172.20.0.1"))
    }

    func testASearchGivesTheResultsAndFallsBackToBing() async {
        let (r, d) = await call("web_search", #"{"q": "Louvre opening hours"}"#)
        XCTAssertEqual(r.status, 200, "\(d)")
        XCTAssertEqual(d["engine"] as? String, "duckduckgo")
        let results = d["results"] as? [[String: Any]] ?? []
        XCTAssertEqual(results.map { $0["url"] as? String ?? "" }, ["https://www.louvre.fr/en/visit/hours", "https://en.wikipedia.org/wiki/Louvre"], "no ads")
        XCTAssertEqual(results.first?["title"] as? String, "Hours, admission | Louvre")
        XCTAssertEqual(results.first?["snippet"] as? String, "Open 9 am to 6 pm, closed Tuesdays.")
        XCTAssertTrue((d["lines"] as? [String])?.first?.hasPrefix("1. Hours, admission | Louvre — https://www.louvre.fr") == true)
        XCTAssertTrue((d["next"] as? [[String: Any]] ?? []).contains { ($0["path"] as? String ?? "").hasPrefix("/api/web/fetch") })
        // Nothing from the first: the second.
        let (_, b) = await call("google", #"{"query": "nothing at all"}"#)
        XCTAssertEqual(b["engine"] as? String, "bing", "\(b)")
        XCTAssertEqual((b["results"] as? [[String: Any]])?.first?["title"] as? String, "Found it")
    }

    // MARK: Chrome

    func testChromeOpensAPageSideBySideAndReadsIt() async {
        let (r, d) = await call("browser", #"{"op": "open", "url": "example.com"}"#)
        XCTAssertEqual(r.status, 200, "\(d)")
        XCTAssertEqual(d["opened"] as? Bool, true)
        XCTAssertEqual(d["where"] as? String, "side_by_side", "side by side unless asked otherwise")
        XCTAssertEqual(d["new_tab"] as? Bool, false, "its own window goes to the page")
        XCTAssertEqual(d["title"] as? String, "Example Domain")
        XCTAssertTrue((d["text"] as? String ?? "").contains("More information"))
        XCTAssertEqual((d["links"] as? [[String: Any]])?.first?["url"] as? String, "https://www.iana.org/domains/example")
        XCTAssertTrue(chromeAsked.copied.contains(" | 720,25,1440,860 | 1 | 0,25,720,860 |  | 1"), "its own on the right half, the person's on the left: \(chromeAsked.copied)")
        XCTAssertTrue(chromeAsked.copied.contains { $0.hasPrefix("open https://example.com | front | 7") }, "\(chromeAsked.copied)")
        // On the person's screen when asked: a new tab of their own window, as before.
        let (_, mine) = await call("browser", #"{"op": "open", "url": "example.org", "where": "on screen"}"#)
        XCTAssertEqual(mine["where"] as? String, "on_screen", "\(mine)")
        XCTAssertTrue(chromeAsked.copied.contains("open https://example.org | new |  | 7"), "\(chromeAsked.copied)")
        // Words, not an address: a search, opened.
        let (_, s) = await call("navigate", #"{"url": "louvre opening hours"}"#)
        XCTAssertEqual(s["searched"] as? String, "louvre opening hours", "\(s)")
        XCTAssertTrue(chromeAsked.copied.contains { $0.hasPrefix("open https://www.google.com/search?q=louvre%20opening%20hours") }, "\(chromeAsked.copied)")
        // The page in front, read, with its links.
        let (_, p) = await call("browser", #"{"op": "read"}"#)
        XCTAssertNotNil(p["links"])
    }
}
