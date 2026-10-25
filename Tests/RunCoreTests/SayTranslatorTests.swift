import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import RunCore
import XCTest

/// A pretend model: answers what it's told to, and keeps what it was asked.
final class FakeModel: @unchecked Sendable {
    private let lock = NSLock()
    private var _answer = ""
    private var _status = 200
    private var _fails = false
    private(set) var asked: [URLRequest] = []

    var answer: String { get { lock.withLock { _answer } } set { lock.withLock { _answer = newValue } } }
    var status: Int { get { lock.withLock { _status } } set { lock.withLock { _status = newValue } } }
    var fails: Bool { get { lock.withLock { _fails } } set { lock.withLock { _fails = newValue } } }
    var count: Int { lock.withLock { asked.count } }

    /// What it says, as a chat completion.
    func says(_ json: String) { answer = json }

    var send: SayTranslator.Send {
        { [self] request in
            let (fails, status, answer) = lock.withLock { () -> (Bool, Int, String) in
                asked.append(request)
                return (_fails, _status, _answer)
            }
            if fails { throw URLError(.cannotConnectToHost) }
            let body: [String: Any] = ["choices": [["message": ["role": "assistant", "content": answer]]]]
            return (try JSONSerialization.data(withJSONObject: body), status)
        }
    }

    /// The prompt it was last given.
    var lastUser: String {
        guard let r = lock.withLock({ asked.last }), let body = r.httpBody,
              let o = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let messages = o["messages"] as? [[String: Any]] else { return "" }
        return messages.last?["content"] as? String ?? ""
    }
}

/// The translator: a stateless model asked only when the words don't settle on one template.
/// What it fills in is read back through the adapter's own matcher; a reading it's sure of is
/// done (said how it was taken), one it isn't is offered, and without it nothing changes.
final class SayTranslatorTests: XCTestCase {
    var home: URL!
    var host: FakeRunHost!
    var settings = APISettings()
    var api: RunAPI!
    var model: FakeModel!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("translate-\(UUID().uuidString)", isDirectory: true)
        let lib = Library(root: home.appendingPathComponent("Scripts"))
        _ = try lib.ensure()
        try "#!/bin/bash\n# Backs up the folder every night\necho done\n".write(to: lib.root.appendingPathComponent("nightly-backup.sh"), atomically: true, encoding: .utf8)
        try "#!/usr/bin/env python3\n# The weather now\n# Input (optional): A place (where you are unless set)\nprint('sunny')\n"
            .write(to: lib.folder(.utilities).appendingPathComponent("weather.py"), atomically: true, encoding: .utf8)
        host = FakeRunHost(folder: lib.root, scripts: lib.scripts(), flows: lib.flows())
        let h = home!
        let m = Memory(files: FileLibrary(root: h.appendingPathComponent("MEMORY"), shelf: .memory), mind: MindStore(root: h.appendingPathComponent("MIND")))
        let web = Web { url in
            if url.absoluteString.contains("duckduckgo") { return .init(data: Data(ToolsTests.duck.utf8), status: 200, contentType: "text/html", url: url) }
            return .init(data: Data(ToolsTests.page.utf8), status: 200, contentType: "text/html; charset=utf-8", url: url)
        }
        api = RunAPI(host: host, version: "0.3.0", library: { FileLibrary(root: h.appendingPathComponent("LIBRARY")) },
                     shelves: { Shelves(memory: m, systemDocs: FileLibrary(root: h.appendingPathComponent("SYSTEM-DOCS"), shelf: .systemDocs)) },
                     web: web) { [unowned self] in self.settings }
        api.poll = 5_000_000
        model = FakeModel()
        api.translator = SayTranslator(file: home.appendingPathComponent("say-translator.json"), settings: SayTranslator.Settings(), send: model.send)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    @discardableResult
    func say(_ text: String) async -> String {
        let (r, d) = await api.send("POST", "/api/say?client=Tester", body: Data(text.utf8), headers: ["Content-Type": "text/plain"])
        XCTAssertEqual(r.status, 200)
        let out = String(decoding: d, as: UTF8.self)
        XCTAssertFalse(out.contains("/api/"), out)
        XCTAssertFalse(out.contains("{\""), out)
        return out
    }

    func json(_ d: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:] }

    // MARK: what it reads

    func testItsAnswerIsReadForgivingly() throws {
        let fenced = try XCTUnwrap(SayTranslator.parse("Sure!\n```json\n{\"meaning\": \"the weather\", \"suggestions\": [{\"title\": \"Weather\", \"say\": \"what's the weather in Lagos\", \"confidence\": 85}], \"question\": \"\"}\n```"))
        XCTAssertEqual(fenced.meaning, "the weather")
        XCTAssertEqual(fenced.suggestions, [.init(title: "Weather", say: "what's the weather in Lagos", confidence: 0.85)], "out of 100 is taken as out of 1")
        let lone = try XCTUnwrap(SayTranslator.parse(#"{"title": "Search the web", "say": "search the web for cats", "confidence": "0.7"}"#))
        XCTAssertEqual(lone.suggestions.first?.confidence, 0.7)
        XCTAssertNil(SayTranslator.parse("I'm not sure what you mean."))
    }

    func testTheModelSeesWhatWasSaidWhyAndTheTemplatesTheClosestFirst() async throws {
        let forms = SayForms.all(catalog: await host.catalog(), settings: settings)
        let (given, closest) = RunAPI.translatorForms("will it rain in Lagos tomorrow", .between(["Weather", "Search the web"]), forms, used: [:])
        XCTAssertFalse(given.contains { $0.title == "Yes" || $0.title == "No" })
        XCTAssertEqual(given.count, forms.count - 2, "every template but yes and no")
        XCTAssertEqual(given.prefix(2).map(\.title), ["Weather", "Search the web"], "the ones it was between first")
        XCTAssertGreaterThanOrEqual(closest, 2)
        let (system, user) = SayTranslator.prompt("will it rain in Lagos tomorrow", why: .between(["Weather", "Search the web"]), forms: given, closest: closest)
        XCTAssertTrue(system.contains("Answer with JSON only"))
        XCTAssertTrue(user.hasPrefix("Said: \"will it rain in Lagos tomorrow\"\nWhy: These fit about as well"), user)
        XCTAssertTrue(user.contains("The closest templates by their words:\n\nWeather (runs on the Mac once the person there OKs it)\n  what's the weather in {a place}\n  for: The weather now"), user)
        XCTAssertTrue(user.contains("All the other templates:"), user)
        XCTAssertTrue(user.contains("Remember something (changes something)\n- category: [PEOPLE"), user)
        // Nothing of the conversation's state: stateless.
        await say("search the web for cats")
        let again = SayTranslator.prompt("x", why: .nothing, forms: given, closest: 0)
        XCTAssertEqual(again.system, system)
    }

    func testAFillingIsReadBackThroughTheAdaptersOwnMatcher() async throws {
        let forms = SayForms.all(catalog: await host.catalog(), settings: settings)
        let weather = try XCTUnwrap(RunAPI.reading(.init(title: "weather", say: "what's the weather in Lagos", confidence: 0.9), forms))
        XCTAssertEqual(weather.form.title, "Weather")
        XCTAssertTrue(weather.complete)
        XCTAssertEqual(weather.filled.at(0), "Lagos")
        let blank = try XCTUnwrap(RunAPI.reading(.init(title: "Weather", say: "what's the weather in {a place}", confidence: 0.9), forms))
        XCTAssertFalse(blank.complete, "a blank left as it was isn't a value")
        let here = try XCTUnwrap(RunAPI.reading(.init(title: "Weather", say: "what's the weather", confidence: 0.9), forms))
        XCTAssertTrue(here.complete, "a way of saying it that takes nothing")
        let labeled = try XCTUnwrap(RunAPI.reading(.init(title: "Remember something", say: "Remember something\n- category: people\n- about: Ada\n- fact: likes tea", confidence: 0.9), forms))
        XCTAssertTrue(labeled.complete)
        XCTAssertEqual(labeled.filled["category"], "PEOPLE")
        let missing = try XCTUnwrap(RunAPI.reading(.init(title: "Remember something", say: "Remember something\n- about: Ada", confidence: 0.9), forms))
        XCTAssertFalse(missing.complete)
        XCTAssertNil(RunAPI.reading(.init(title: "Order a pizza", say: "order a pizza", confidence: 0.99), forms), "a template there isn't")
        let loose = try XCTUnwrap(RunAPI.reading(.init(title: "Search the web", say: "look for cats please", confidence: 0.95), forms))
        XCTAssertFalse(loose.complete, "a filling that isn't the template's: the template, to fill")
    }

    // MARK: in the conversation

    func testAReadingItsSureOfIsDoneAndSaysHowItWasTaken() async throws {
        model.says(#"{"meaning": "the Louvre's Sunday hours", "suggestions": [{"title": "Search the web", "say": "search the web for Louvre opening hours Sunday", "confidence": 0.9}], "question": ""}"#)
        let out = await say("I wonder whether the louvre opens on sundays")
        XCTAssertEqual(model.count, 1)
        XCTAssertTrue(out.hasPrefix("Taken as: search the web for Louvre opening hours Sunday\n\n"), out)
        XCTAssertTrue(model.lastUser.contains("Why: Nothing matched these words closely."), model.lastUser)
        let (_, d) = await api.send("GET", "/api/say/log?client=Tester")
        let entry = try XCTUnwrap((json(d)["entries"] as? [[String: Any]])?.first)
        XCTAssertEqual(entry["template"] as? String, "Search the web")
        XCTAssertEqual(entry["said"] as? String, "I wonder whether the louvre opens on sundays", "the client's own words are kept")
    }

    func testARunItsSureOfIsAskedForOnTheMacInTheClientsOwnWords() async throws {
        model.says(#"{"meaning": "tomorrow's weather in Lagos", "suggestions": [{"title": "Weather", "say": "what's the weather in Lagos", "confidence": 0.88}], "question": ""}"#)
        let out = await say("gonna need an umbrella in Lagos?")
        XCTAssertTrue(out.contains("Taken as: what's the weather in Lagos"), out)
        XCTAssertTrue(out.contains("Asked for"), out)
        for _ in 0..<400 where host.asked.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        let ask = try XCTUnwrap(host.asked.first)
        XCTAssertEqual(ask.arguments, ["Lagos"])
        XCTAssertEqual(ask.why, "Tester asked in words: “gonna need an umbrella in Lagos?”", "the card says what the client said, not the model's reading")
    }

    func testAChangeItsSureOfIsAskedAboutFirst() async throws {
        model.says(#"{"meaning": "get rid of the shopping note", "suggestions": [{"title": "Delete a note", "say": "delete the note shopping", "confidence": 0.95}], "question": ""}"#)
        let out = await say("bin my shopping list")
        XCTAssertTrue(out.contains("Did you mean: Delete a note (shopping)? Say yes"), out)
        let yes = await say("yes")
        XCTAssertFalse(yes.contains("Did you mean"), yes)
    }

    func testAReadingItIsntSureOfIsOfferedNumberedAndFilledIn() async throws {
        model.says(#"{"meaning": "something about rain", "suggestions": [{"title": "Weather", "say": "what's the weather in {a place}", "confidence": 0.5}, {"title": "Search the web", "say": "search the web for rain tomorrow", "confidence": 0.4}], "question": "Where?"}"#)
        let out = await say("rain tomorrow??")
        XCTAssertTrue(out.contains("It sounds like: something about rain.\nYou might mean:\n1. Weather\n     what's the weather in {a place}\n2. Search the web\n     search the web for rain tomorrow"), out)
        XCTAssertTrue(out.contains("Where?"), out)
        // One with a blank: shown to fill. One filled: done.
        let first = await say("1")
        XCTAssertTrue(first.hasPrefix("Fill in the blanks and say it back:\n\nWeather\n  what's the weather in {a place}"), first)
        await say("rain tomorrow??")
        let second = await say("2")
        XCTAssertFalse(second.contains("Fill in the blanks"), second)
        XCTAssertTrue(second.contains("Louvre"), second)
    }

    func testWithNothingUsefulFromItTheAdapterAnswersAsItDidWithoutOne() async throws {
        // A template there isn't.
        model.says(#"{"meaning": "pizza", "suggestions": [{"title": "Order a pizza", "say": "order a pizza", "confidence": 0.99}], "question": ""}"#)
        var out = await say("remember to buy a birthday cake")
        XCTAssertTrue(out.contains("These can do that:"), out)
        // Not JSON.
        model.says("No idea.")
        out = await say("remember to buy a birthday cake")
        XCTAssertTrue(out.contains("These can do that:"), out)
        // Out of reach: not asked again for a while.
        model.fails = true
        out = await say("remember to buy a birthday cake")
        XCTAssertTrue(out.contains("These can do that:"), out)
        let count = model.count
        await say("remember to buy a birthday cake")
        XCTAssertEqual(model.count, count, "resting after it couldn't be reached")
    }

    func testAClearMatchNeverAsksIt() async throws {
        await say("search the web for cats")
        await say("what's the weather in Lagos")
        await say("what have I asked for today")
        XCTAssertEqual(model.count, 0)
        api.translator = .off()
        await say("I wonder whether the louvre opens on sundays")
        XCTAssertEqual(model.count, 0)
    }

    // MARK: the routes

    func testTranslateAloneSaysWhatTheModelSawAndWhatCameOfIt() async throws {
        model.says(#"{"meaning": "the weather in Lagos", "suggestions": [{"title": "Weather", "say": "what's the weather in Lagos", "confidence": 0.9}], "question": ""}"#)
        let (r, d) = await api.post("/api/say/translate", #"{"text": "will it rain in Lagos tomorrow"}"#)
        XCTAssertEqual(r.status, 200)
        let o = json(d)
        XCTAssertEqual(o["ok"] as? Bool, true)
        XCTAssertEqual(o["top"] as? String, "Weather")
        let prompt = try XCTUnwrap(o["prompt"] as? [String: Any])
        XCTAssertEqual(prompt["system"] as? String, SayTranslator.system)
        XCTAssertTrue((prompt["user"] as? String ?? "").hasPrefix("Said: \"will it rain in Lagos tomorrow\""))
        let s = try XCTUnwrap((o["suggestions"] as? [[String: Any]])?.first)
        XCTAssertEqual(s["template"] as? String, "Weather")
        XCTAssertEqual(s["complete"] as? Bool, true)
        XCTAssertEqual(s["taken"] as? String, "what's the weather in Lagos")
        // Dry: the prompt alone, the model not asked.
        let before = model.count
        let (_, dry) = await api.post("/api/say/translate", #"{"text": "will it rain", "dry": true}"#)
        XCTAssertEqual(json(dry)["dry"] as? Bool, true)
        XCTAssertEqual(model.count, before)
        // Another model to try, for this call only.
        _ = await api.post("/api/say/translate", #"{"text": "will it rain", "model": "qwen2.5:7b"}"#)
        let body = try XCTUnwrap(model.asked.last?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertEqual(body["model"] as? String, "qwen2.5:7b")
        let kept = await api.translator.settings.model
        XCTAssertEqual(kept, "llama3.2", "kept as it was")
    }

    func testItsSettingsChangeFromThisMacAndTheKeyIsNeverShown() async throws {
        let (r, d) = await api.post("/api/say/translator", #"{"api": "anthropic", "key": "sk-secret"}"#)
        XCTAssertEqual(r.status, 200)
        let s = try XCTUnwrap(json(d)["settings"] as? [String: Any])
        XCTAssertEqual(s["api"] as? String, "anthropic")
        XCTAssertEqual(s["url"] as? String, SayTranslator.Settings.anthropicURL)
        XCTAssertEqual(s["model"] as? String, SayTranslator.Settings.anthropicModel)
        XCTAssertEqual(s["key"] as? String, "set")
        XCTAssertFalse(String(decoding: d, as: UTF8.self).contains("sk-secret"))
        // Kept in its file.
        let saved = try JSONDecoder().decode(SayTranslator.Settings.self, from: Data(contentsOf: home.appendingPathComponent("say-translator.json")))
        XCTAssertEqual(saved.key, "sk-secret")
        // The Messages API's shape.
        let request = try SayTranslator.request(saved, system: "s", user: "u")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2026-10-21")
        let body = try XCTUnwrap(request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertEqual(body["system"] as? String, "s")
        XCTAssertNil(body["temperature"])
        XCTAssertEqual(((body["output_config"] as? [String: Any])?["format"] as? [String: Any])?["type"] as? String, "json_schema")
        // Not from elsewhere, and not nonsense.
        let (far, _) = await api.send("POST", "/api/say/translator", body: Data(#"{"model": "x"}"#.utf8), headers: ["Content-Type": "application/json"], fromLoopback: false)
        XCTAssertNotEqual(far.status, 200)
        let (bad, _) = await api.post("/api/say/translator", #"{"api": "telepathy"}"#)
        XCTAssertEqual(bad.status, 400)
    }
}
