import Foundation
@testable import RunCore
import XCTest

/// The template adapter (`POST /api/say`): a client says what it wants in words and gets words
/// back. Templates are offered when nothing matches, read back when filled, the real routes
/// called, and the requests followed by the adapter itself.
final class SayTests: XCTestCase {
    var home: URL!
    var host: FakeRunHost!
    var settings = APISettings()
    var api: RunAPI!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("say-\(UUID().uuidString)", isDirectory: true)
        let lib = Library(root: home.appendingPathComponent("Scripts"))
        _ = try lib.ensure()
        try "#!/bin/bash\n# Backs up the folder every night\necho done\n".write(to: lib.root.appendingPathComponent("nightly-backup.sh"), atomically: true, encoding: .utf8)
        try "#!/usr/bin/env python3\n# The weather now\n# Input (optional): A place (where you are unless set)\nprint('sunny')\n"
            .write(to: lib.folder(.utilities).appendingPathComponent("weather.py"), atomically: true, encoding: .utf8)
        try "#!/bin/bash\n# Says hello to someone\n# Say: greet {a name}\n# Input: A name\necho hello \"$1\"\n".write(to: lib.root.appendingPathComponent("greet.sh"), atomically: true, encoding: .utf8)
        try "#!/bin/bash\n# Sends a postcard\n# Input: To whom\n# Input: The message\n# Why: It's printed on the card\necho sent\n".write(to: lib.root.appendingPathComponent("postcard.sh"), atomically: true, encoding: .utf8)
        host = FakeRunHost(folder: lib.root, scripts: lib.scripts(), flows: lib.flows())
        let h = home!
        let m = Memory(files: FileLibrary(root: h.appendingPathComponent("MEMORY"), shelf: .memory), mind: MindStore(root: h.appendingPathComponent("MIND")))
        let web = Web { url in
            let s = url.absoluteString
            if s.contains("duckduckgo") { return .init(data: Data(ToolsTests.duck.utf8), status: 200, contentType: "text/html", url: url) }
            return .init(data: Data(ToolsTests.page.utf8), status: 200, contentType: "text/html; charset=utf-8", url: url)
        }
        api = RunAPI(host: host, version: "0.3.0", library: { FileLibrary(root: h.appendingPathComponent("LIBRARY")) },
                     shelves: { Shelves(memory: m, systemDocs: FileLibrary(root: h.appendingPathComponent("SYSTEM-DOCS"), shelf: .systemDocs)) },
                     web: web) { [unowned self] in self.settings }
        api.poll = 5_000_000
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    /// Says something as a client, and gives back the words it got.
    @discardableResult
    func say(_ text: String, client: String = "Tester") async -> String {
        let (r, d) = await api.send("POST", "/api/say?client=\(client.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? client)",
                                    body: Data(text.utf8), headers: ["Content-Type": "text/plain"])
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.header("Content-Type"), "text/plain; charset=utf-8")
        let out = String(decoding: d, as: UTF8.self)
        // Never JSON, routes or ids.
        XCTAssertFalse(out.contains("/api/"), out)
        XCTAssertFalse(out.contains("{\""), out)
        XCTAssertNil(out.range(of: #"[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-"#, options: .regularExpression), out)
        return out
    }

    /// Waits for the pretend Mac to have been asked `n` times.
    func waitForAsks(_ n: Int) async throws {
        for _ in 0..<400 where host.asked.count < n { try await Task.sleep(nanoseconds: 5_000_000) }
    }

    // MARK: the grammar

    func testAnInlineTemplateTakesItsValueExactlyAndForgivesItsOwnWords() throws {
        let form = try XCTUnwrap(SayForms.tools.first { $0.title == "Search the web" })
        let (filled, score) = try XCTUnwrap(SayMatch.inline("search the web for flights to Lagos", form))
        XCTAssertEqual(filled.at(0), "flights to Lagos", "a fixed word inside a value stays in it")
        XCTAssertEqual(score, 1, accuracy: 0.001)
        // A misspelt fixed word, a missing small one: still it, less sure.
        let (typo, typoScore) = try XCTUnwrap(SayMatch.inline("serch web for \"Café Kranzler\"?", form))
        XCTAssertEqual(typo.at(0), "Café Kranzler", "quotes and the sentence's end are taken off")
        XCTAssertLessThan(typoScore, 1)
        XCTAssertGreaterThanOrEqual(typoScore, SayMatch.floor)
        XCTAssertNil(SayMatch.inline("search my notes for milk", form).flatMap { $0.1 >= SayMatch.floor ? $0 : nil })
        // A choice with a blank in one of its options.
        let asked = try XCTUnwrap(SayForms.builtins.first { $0.title == "What have I asked for" })
        let (since, _) = try XCTUnwrap(SayMatch.inline("what have I asked for since 9:30", asked))
        XCTAssertEqual(since.chose, ["since {a time}"])
        XCTAssertEqual(since.at(0), "9:30")
        XCTAssertEqual(SayMatch.inline("what have I asked for today", asked)?.0.chose, ["today"])
    }

    func testTheLabeledShapeTakesLinesInAnyOrderFencesAndCorrectsChoices() throws {
        let form = try XCTUnwrap(SayForms.tools.first { $0.title == "Remember something" })
        let lines = try XCTUnwrap(SayMatch.lines("remember somethin\n- fact: rain: likely\n- about: Lagos trip\n- Category: event date"))
        XCTAssertEqual(lines.title, "remember somethin")
        guard case let .filled(f, score) = SayMatch.labeled(lines, form, titleScore: SayMatch.titleScore("remember somethin", form)) else { return XCTFail("not filled") }
        XCTAssertEqual(f["category"], "EVENT-DATES")
        XCTAssertEqual(f["fact"], "rain: likely", "a colon in a value stays")
        XCTAssertEqual(f.corrections, ["taken as EVENT-DATES"])
        XCTAssertLessThan(score, 1)
        let note = try XCTUnwrap(SayForms.tools.first { $0.title == "Write a note" })
        let fenced = try XCTUnwrap(SayMatch.lines("Write a note\n- name: groceries\n- text:\n```\n- eggs\n- milk: 2\n```"))
        guard case let .filled(n, _) = SayMatch.labeled(fenced, note, titleScore: 1) else { return XCTFail("not filled") }
        XCTAssertEqual(n["text"], "- eggs\n- milk: 2")
        guard case let .incomplete(_, missing, _) = SayMatch.labeled(SayMatch.lines("Write a note\n- name: x")!, note, titleScore: 1) else { return XCTFail() }
        XCTAssertEqual(missing.map(\.label), ["text"])
        guard case .badChoice = SayMatch.labeled(SayMatch.lines("Remember something\n- category: zebras\n- about: a\n- fact: b")!, form, titleScore: 1) else { return XCTFail() }
    }

    func testEveryTemplateHasItsOwnTitleAndWhatFollowsIsThere() {
        let forms = SayForms.all(catalog: host.catalogValue, settings: settings)
        let titles = forms.map { $0.title.lowercased() }
        XCTAssertEqual(Set(titles).count, titles.count, "each title once")
        for f in forms {
            for n in f.next { XCTAssertTrue(forms.contains { $0.title == n }, "\(f.title) → \(n)") }
            if case let .tool(name, _) = f.action { XCTAssertNotNil(Tools.named(name), name) }
            XCTAssertTrue(f.isInline || !f.fields.isEmpty || f.kind == "builtin", f.title)
        }
        XCTAssertTrue(forms.contains { $0.title == "Greet" && $0.short == "greet {a name}" }, "a script's # Say: line")
        XCTAssertTrue(forms.contains { $0.title == "Postcard" && $0.fields.count == 2 }, "two inputs: the labeled shape")
        // A switch turned off takes its templates away.
        settings.off = [.web]
        XCTAssertFalse(SayForms.all(catalog: host.catalogValue, settings: settings).contains { $0.title == "Search the web" })
    }

    func testASayLineIsReadFromTheHeaderAndIsntTheSummary() {
        let head = "#!/bin/bash\n# Say: greet {a name}\n# Says hello\n# Input: A name\n"
        XCTAssertEqual(ScriptInput.declaredSay(in: head), ["greet {a name}"])
        XCTAssertEqual(Library.summary(head), "Says hello", "a Say: line is passed over, as an Input: line is")
        XCTAssertEqual(Library.summary("#!/bin/bash\n# Says hello\n# Say: greet {a name}\n"), "Says hello")
    }

    // MARK: talking

    func testSomethingNotATemplateYetIsAnsweredWithTheTemplatesThatWouldDoIt() async {
        let out = await say("I need to know if it'll rain in Lagos tomorrow")
        XCTAssertTrue(out.hasPrefix("These can do that:"), out)
        XCTAssertTrue(out.contains("1. Weather\n     what's the weather in {a place}"), out)
        XCTAssertTrue(out.contains("search the web for {what to look for}"), out)
        // A number picks one: it's shown alone, to fill.
        let one = await say("1")
        XCTAssertTrue(one.contains("Fill in the blanks"), one)
        XCTAssertTrue(one.contains("what's the weather in {a place}"), one)
        // A title alone: its template.
        let title = await say("Remember something")
        XCTAssertTrue(title.contains("- category: [PEOPLE | ORGANIZATIONS"), title)
    }

    func testAFilledTemplateIsDoneAtOnceAndSaidInWords() async throws {
        let found = await say("search the web for louvre hours")
        XCTAssertTrue(found.contains("1. Hours, admission | Louvre\n   https://www.louvre.fr/en/visit/hours"), found)
        XCTAssertTrue(found.contains("You can also say:"), found)
        let remembered = await say("Remember something\n- category: people\n- about: Ada\n- fact: my sister\n- date: 03-14")
        XCTAssertTrue(remembered.hasPrefix("Remembered under PEOPLE: Ada."), remembered)
        let recalled = await say("what do you know about Ada")
        XCTAssertTrue(recalled.contains("ada: birthday 03-14"), recalled)
        let written = await say("Write a note\n- name: groceries\n- text:\n```\n- eggs\n- milk\n```")
        XCTAssertTrue(written.hasPrefix("Wrote a new note, groceries."), written)
        let read = await say("read the note groceries")
        XCTAssertTrue(read.hasPrefix("The note groceries:\n- eggs\n- milk"), read)
        // A failure is a sentence, and the template that fixes it.
        let missing = await say("read the note nope")
        XCTAssertTrue(missing.contains("There's no note called nope."), missing)
        XCTAssertTrue(missing.contains("You can also say: read the note {its name}"), missing)
    }

    func testARunWaitsForTheMacAndTheNewsSaysWhenItsDone() async throws {
        host.holdApprovals = true
        let asked = await say("run the nightly backup")
        XCTAssertTrue(asked.hasPrefix("This needs the person at the Mac to click Run. I'll tell you when they do."), asked)
        try await waitForAsks(1)
        XCTAssertEqual(host.asked.first?.name, "nightly-backup.sh")
        XCTAssertEqual(host.asked.first?.client, "Tester")
        XCTAssertEqual(host.asked.first?.why, "Tester asked in words: “run the nightly backup”", "the card says what was said")
        let waiting = await say("what happened to the backup")
        XCTAssertTrue(waiting.hasPrefix("The nightly backup is waiting for the person at the Mac"), waiting)
        host.holdApprovals = false
        for _ in 0..<200 where host.started.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        try await Task.sleep(nanoseconds: 20_000_000)
        let news = await say("what have I asked for today")
        XCTAssertTrue(news.hasPrefix("Meanwhile: The nightly backup finished (it worked). Say \"show me the nightly backup\" to see what it printed."), news)
        XCTAssertTrue(news.contains("Today you asked for:\n1. run the nightly backup (it worked; not shown yet: say \"show me the nightly backup\")"), news)
        // The adapter collected it: the system's open list doesn't have it.
        let (_, open) = await api.send("GET", "/api/requests/open")
        XCTAssertEqual(json(open)["count"] as? Int, 0)
        // Told once.
        let again = await say("show me the first one")
        XCTAssertFalse(again.contains("Meanwhile"), again)
        XCTAssertTrue(again.hasPrefix("The nightly backup worked at "), again)
        XCTAssertTrue(again.hasSuffix("It printed:\nhi\n"), again)
        let listed = await say("what have I asked for today")
        XCTAssertTrue(listed.contains("1. run the nightly backup (it worked)"), listed)
    }

    func testAScriptsInputsComeFromItsTemplate() async throws {
        _ = await say("greet Ada Lovelace")
        try await waitForAsks(1)
        XCTAssertEqual(host.asked.last?.name, "greet.sh")
        XCTAssertEqual(host.asked.last?.arguments, ["Ada Lovelace"])
        let postcard = await say("Postcard\n- the message: Wish you were here\n- to whom: Sam")
        XCTAssertTrue(postcard.contains("click Run"), postcard)
        try await waitForAsks(2)
        XCTAssertEqual(host.asked.last?.arguments, ["Sam", "Wish you were here"])
        let weather = await say("what's the weather")
        XCTAssertTrue(weather.contains("click Run"), weather)
        try await waitForAsks(3)
        XCTAssertEqual(host.asked.last?.arguments, [], "an optional input left out")
        // Don't Run is news too.
        host.answer = .denied
        _ = await say("what's the weather in Lagos")
        try await waitForAsks(4)
        try await Task.sleep(nanoseconds: 20_000_000)
        let news = await say("what can you do")
        XCTAssertTrue(news.contains("didn't go ahead: the person at the Mac said no."), news)
    }

    func testAnUncertainChangeIsAskedAboutFirstAndReadsAreNot() async throws {
        _ = await say("Write a note\n- name: list\n- text: a")
        let asked = await say("delete note list")
        XCTAssertEqual(asked, "Did you mean: Delete a note (list)? Say yes to go ahead, or no.\n")
        let no = await say("no")
        XCTAssertTrue(no.hasPrefix("All right: nothing was done."), no)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("LIBRARY/list.md").path))
        _ = await say("delete note list")
        let yes = await say("yes")
        XCTAssertTrue(yes.hasPrefix("Moved the note list to the library's Trash."), yes)
        // A read, as unsure, is answered at once.
        let read = await say("serch web for louvre")
        XCTAssertTrue(read.hasPrefix("The web has these"), read)
    }

    func testStopTakesBackWhatsStillWaiting() async throws {
        host.holdApprovals = true
        _ = await say("run the nightly backup")
        try await waitForAsks(1)
        let stopped = await say("stop the backup")
        XCTAssertTrue(stopped.hasPrefix("Taken back: the card is gone from the Mac, and nothing ran."), stopped)
        host.holdApprovals = false
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(host.started.isEmpty)
        let story = await say("what happened to it")
        XCTAssertTrue(story.contains("was taken back before anyone answered"), story)
        let unknown = await say("what happened to the zeppelin")
        XCTAssertTrue(unknown.contains("I can't tell which request"), unknown)
    }

    func testMoreGivesTheRestOfALongAnswer() async throws {
        let text = (1...45).map { "line \($0)" }.joined(separator: "\n")
        _ = await say("Write a note\n- name: long\n- text:\n```\n\(text)\n```")
        let first = await say("read the note long")
        XCTAssertTrue(first.contains("line 19\n(26 more lines: say \"more\" for the rest.)"), first)
        let second = await say("more")
        XCTAssertTrue(second.hasPrefix("line 20"), second)
        XCTAssertTrue(second.contains("say \"more\""), second)
        let third = await say("more")
        XCTAssertTrue(third.hasSuffix("line 45\n"), third)
        let none = await say("more")
        XCTAssertEqual(none, "There's no more.\n")
    }

    func testEachClientHasItsOwnConversation() async throws {
        _ = await say("search the web for louvre", client: "One")
        let other = await say("what have I asked for today", client: "Two")
        XCTAssertTrue(other.contains("You haven't asked me for anything yet."), other)
        let (r, d) = await api.send("GET", "/api/say/log?client=One")
        XCTAssertEqual(r.status, 200)
        let entries = json(d)["entries"] as? [[String: Any]] ?? []
        XCTAssertEqual(entries.first?["what"] as? String, "search the web for louvre")
        XCTAssertEqual(entries.first?["state"] as? String, "answered")
        let (reset, _) = await api.post("/api/say/reset", #"{"client": "One", "forget": true}"#)
        XCTAssertEqual(reset.status, 200)
        let (_, after) = await api.send("GET", "/api/say/log?client=One")
        XCTAssertEqual(json(after)["count"] as? Int, 0)
    }

    func testReferences() {
        let now = Date()
        var c = SayLog.Conversation()
        func entry(_ n: Int, _ what: String, _ short: String, ago: TimeInterval) -> SayLog.Entry {
            SayLog.Entry(number: n, asked: now.addingTimeInterval(-ago), said: what, form: "x", what: what, short: short, state: .answered)
        }
        c.entries = [entry(1, "run the nightly backup", "the nightly backup", ago: 3600), entry(2, "search the web for flights", "search the web for flights", ago: 60)]
        XCTAssertEqual(SayRefs.resolve("the last one", in: c, now: now)?.number, 2)
        XCTAssertEqual(SayRefs.resolve("the backup", in: c, now: now)?.number, 1)
        XCTAssertEqual(SayRefs.resolve("the first one", in: c, now: now)?.number, 1)
        c.list = [2, 1]
        XCTAssertEqual(SayRefs.resolve("2", in: c, now: now)?.number, 1, "a number is from the last list")
        XCTAssertNil(SayRefs.resolve("the zeppelin", in: c, now: now))
        XCTAssertEqual(SayRefs.ordinal("the second one"), 2)
        XCTAssertEqual(SayRefs.ordinal("#3"), 3)
        XCTAssertNil(SayRefs.ordinal("the backup"))
        let cal = Calendar.current
        let four = cal.date(bySettingHour: 16, minute: 0, second: 0, of: now)!
        XCTAssertEqual(cal.component(.hour, from: SayRefs.time("3", now: four)!), 15, "3 at four in the afternoon is 3 pm")
        XCTAssertEqual(cal.component(.hour, from: SayRefs.time("9:30am", now: four)!), 9)
        XCTAssertEqual(cal.component(.minute, from: SayRefs.time("9:30am", now: four)!), 30)
    }

    // MARK: the routes

    func testTheRoutesAndTheTool() async throws {
        let (r, d) = await api.send("GET", "/api/say")
        XCTAssertEqual(r.status, 200)
        XCTAssertTrue(String(decoding: d, as: UTF8.self).contains("To use the Mac's tools, use say."))
        let (fr, fd) = await api.send("GET", "/api/say/forms?format=json")
        XCTAssertEqual(fr.status, 200)
        XCTAssertGreaterThan(json(fd)["count"] as? Int ?? 0, 30)
        let (_, some) = await api.send("GET", "/api/say/forms?q=remember%20a%20birthday")
        XCTAssertTrue(String(decoding: some, as: UTF8.self).hasPrefix("Remember something"))
        // A JSON body works too.
        let (jr, jd) = await api.post("/api/say", #"{"text": "what can you do", "client": "Json App"}"#)
        XCTAssertEqual(jr.status, 200)
        XCTAssertTrue(String(decoding: jd, as: UTF8.self).hasPrefix("Say what you want"))
        // The one tool a model needs.
        let (tr, td) = await api.post("/api/tools/say", #"{"arguments": {"text": "what can you do"}, "client": "Model"}"#)
        XCTAssertEqual(tr.status, 200)
        XCTAssertTrue(String(decoding: td, as: UTF8.self).hasPrefix("Say what you want"))
        XCTAssertEqual(tr.header("Content-Type"), "text/plain; charset=utf-8")
        let (_, search) = await api.send("GET", "/api/search?q=talk%20in%20plain%20words")
        XCTAssertTrue(String(decoding: search, as: UTF8.self).contains("/api/say"))
    }
}
