import Foundation
@testable import RunCore
import XCTest

/// Straw scripts (`.straw`): a language of their own on the cells, run by the browser folder's
/// straw.py, every mistake caught before anything runs, and what they read is their output.
final class StrawTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("straw-\(UUID().uuidString)", isDirectory: true)
        try Library(root: folder).ensure()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var python: Bool { ShellEnvironment.shared.find("python3") != nil }

    private func write(_ path: String, _ text: String) throws -> URL {
        let url = folder.appendingPathComponent(path)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private var runner: String { try! XCTUnwrap(Examples.browser.first { $0.0 == "browser/straw.py" }?.1) }

    func testItsALanguageOfItsOwn() throws {
        XCTAssertEqual(ScriptLanguage.detect(fileName: "hacker-news.straw", contents: "open news.ycombinator.com\n"), .straw)
        XCTAssertEqual(ScriptLanguage.straw.title, "Straw")
        XCTAssertEqual(ScriptLanguage.straw.fileExtension, "straw")
        XCTAssertTrue(ScriptLanguage.offered.contains(.straw))
        _ = try write("browser/look.straw", "# Looks at the page\nread title\n")
        let item = try XCTUnwrap(Library(root: folder).scripts(in: .browser).first)
        XCTAssertEqual(item.language, .straw)
        XCTAssertEqual(item.summary, "Looks at the page")
        XCTAssertFalse(item.asksForInput, "its read reads the page, not the keyboard")
    }

    /// It's run by the straw.py beside it, or in the browser folder above it; with none, it says
    /// how to put it back before trying.
    func testItsRunByStrawPyFromTheBrowserFolder() throws {
        let script = try write("browser/look.straw", "read title\n")
        let top = try write("top.straw", "read url\n")
        let none = ScriptProcess(script: script, language: .straw, workingDirectory: folder)
        XCTAssertThrowsError(try none.runToEnd()) { error in
            XCTAssertTrue("\(error)".contains("straw.py"), "\(error)")
            XCTAssertTrue((error as? LaunchError)?.fix?.contains("Add the Examples") == true, "\(error)")
        }
        let helper = try write("browser/straw.py", runner)
        let beside = ScriptProcess(script: script, language: .straw, arguments: ["a b"], workingDirectory: folder)
        XCTAssertEqual(beside.invocation, "python3 -u \(helper.path) \(script.path) 'a b'")
        XCTAssertEqual(Straw.runner(for: top)?.path, helper.path, "a .straw at the top uses the browser folder's")
    }

    func testEveryExampleChecksAndTheGuideHasEveryWord() throws {
        // The words are straw.py's WORDS table: the checker, its help and this guide read the one list.
        let table = try XCTUnwrap(runner.range(of: "WORDS = {").flatMap { start in runner[start.upperBound...].range(of: "\n}\n").map { runner[start.upperBound..<$0.lowerBound] } })
        let text = String(table)
        let words = try NSRegularExpression(pattern: #"^    "([a-z]+)": +\("#, options: .anchorsMatchLines)
        let names = words.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
        XCTAssertEqual(names.count, 25, "\(names)")
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let guide = try String(contentsOf: repo.appendingPathComponent("docs/STRAW-GUIDE.md"), encoding: .utf8)
        for word in names { XCTAssertTrue(guide.contains("`\(word)"), "the guide has \(word)") }

        try XCTSkipIf(!python, "needs python3")
        try Library(root: folder).addExamples(for: .browser)
        let straws = Examples.browser.filter { $0.0.hasSuffix(".straw") }
        XCTAssertGreaterThanOrEqual(straws.count, 5)
        for (id, _) in straws {
            let r = try ScriptProcess(shell: "python3 browser/straw.py --check \(ShellEnvironment.quote(id))", workingDirectory: folder).runToEnd()
            XCTAssertEqual(r.code, 0, "\(id): \(r.err)")
            XCTAssertTrue(r.out.contains("no mistakes"), r.out)
        }
        // Run with nothing: every word, with an example.
        let help = try ScriptProcess(shell: "python3 browser/straw.py", workingDirectory: folder).runToEnd()
        XCTAssertEqual(help.code, 0)
        for word in names { XCTAssertTrue(help.out.contains("  \(word)"), word) }
    }

    /// A mistake says its line and the fix, and nothing runs (Chrome isn't touched).
    func testAMistakeStopsItBeforeAnythingRuns() throws {
        try XCTSkipIf(!python, "needs python3")
        _ = try write("browser/straw.py", runner)
        let log = folder.appendingPathComponent("calls.log")
        let fake = try write("fake-browser.sh", "#!/bin/bash\necho \"$1\" >> \(ShellEnvironment.quote(log.path))\necho '{\"ok\": true}'\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let script = try write("browser/bad.straw", "open example.com\nclik \"More\"\n")
        var env = ShellEnvironment.shared.environment
        env["STRAW_BROWSER"] = fake.path
        let r = try ScriptProcess(script: script, language: .straw, workingDirectory: folder, environment: env).runToEnd()
        XCTAssertEqual(r.code, 2)
        XCTAssertTrue(r.err.contains("bad.straw, line 2: Straw doesn't know \"clik\"."), r.err)
        XCTAssertTrue(r.err.contains("Fix: Did you mean click?"), r.err)
        XCTAssertTrue(r.err.contains("Nothing ran."), r.err)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path), "Chrome wasn't touched")

        for (source, said) in [
            ("print \"{who}\"\n", "{who} has no value yet here"),
            ("if see \"Cookies\"\nclick \"OK\"\n", "Nothing is indented under this if"),
            ("click Sign\n", "click needs the thing's name in quotes"),
            ("  read title\n", "indented more than the one above it"),
            ("type \"Search\"\n", "type takes what to put in it"),
        ] {
            let bad = try write("browser/bad.straw", source)
            let r = try ScriptProcess(script: bad, language: .straw, workingDirectory: folder, environment: env).runToEnd()
            XCTAssertEqual(r.code, 2, source)
            XCTAssertTrue(r.err.contains(said), "\(source): \(r.err)")
        }
    }

    /// Run through a stand-in for browser.sh: each step asks the page, what's read is the output,
    /// what it's doing goes beside it, and if/else go the way the page says.
    func testItRunsStepByStepThroughBrowserSh() throws {
        try XCTSkipIf(!python || ShellEnvironment.shared.find("bash") == nil, "needs python3 and bash")
        _ = try write("browser/straw.py", runner)
        let log = folder.appendingPathComponent("calls.log")
        // The page has one thing on it, called "Here"; reading anything gives "Fake Page".
        let fake = try write("fake-browser.sh", """
        #!/bin/bash
        printf '%s\\n' "$1" >> \(ShellEnvironment.quote(log.path))
        case "$1" in
          open) echo "Opened $2" ;;
          wait) ;;
          js)
            case "$2" in
              *'DO.count(P)'*) case "$2" in *'"name": "Here"'*) echo '{"ok": true, "count": 1}' ;; *) echo '{"ok": true, "count": 0}' ;; esac ;;
              *'DO.read(P)'*) echo '{"ok": true, "text": "Fake Page"}' ;;
              *'DO.click(P)'*) case "$2" in *'"name": "Here"'*) echo '{"ok": true}' ;; *) echo '{"ok": false, "why": "not_found", "near": ["Here", "There"]}' ;; esac ;;
              *) echo '{"ok": true}' ;;
            esac ;;
        esac
        """ + "\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let script = try write("browser/walk.straw", """
        # Walks a fake page
        # Input: A word
        open "example.com/search?q={1}"
        see "Here"
        see no "Gone"
        if see "Here"
          read title into t
        else
          print "never"
        if no "Here"
          print "never either"
        else
          print "Got {t} for {1}, {2|nothing else}"
        click "Here"
        """ + "\n")
        var env = ShellEnvironment.shared.environment
        env["STRAW_BROWSER"] = fake.path
        let r = try ScriptProcess(script: script, language: .straw, arguments: ["a&b c"], workingDirectory: folder, environment: env).runToEnd()
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertEqual(r.out, "Got Fake Page for a&b c, nothing else\n", "only what it reads and prints is its output")
        XCTAssertTrue(r.err.contains("→ open \"example.com/search?q=a&b c\""), r.err)
        XCTAssertTrue(r.err.contains("  Opened example.com/search?q=a%26b+c"), "{1} after the ? is made safe for an address: \(r.err)")
        XCTAssertTrue(r.err.hasSuffix("✅ Done.\n"), r.err)

        // Something that isn't there stops it, naming what's near.
        let missing = try write("browser/miss.straw", "click \"Ther\"\nprint \"never\"\n")
        let m = try ScriptProcess(script: missing, language: .straw, workingDirectory: folder, environment: env).runToEnd()
        XCTAssertEqual(m.code, 1)
        XCTAssertEqual(m.out, "")
        XCTAssertTrue(m.err.contains("❌ Nothing on the page is called \"Ther\". Near it on the page: \"There\""), m.err)
        // {1} that wasn't given stops it before it's used, saying what it is.
        let r2 = try ScriptProcess(script: script, language: .straw, workingDirectory: folder, environment: env).runToEnd()
        XCTAssertEqual(r2.code, 1)
        XCTAssertTrue(r2.err.contains("needs {1} (A word): run it with an argument."), r2.err)
    }

    /// first takes the highest of several, read links THING the links among what it names, a js
    /// list comes back a line each, and a backslash before anything but the quote stays (\t, \s).
    func testFirstLinksListsAndBackslashes() throws {
        try XCTSkipIf(!python || ShellEnvironment.shared.find("bash") == nil, "needs python3 and bash")
        _ = try write("browser/straw.py", runner)
        let log = folder.appendingPathComponent("page.log")
        let fake = try write("fake-browser.sh", """
        #!/bin/bash
        [ "$1" = js ] && printf '%s\\n' "$2" | tail -n 2 >> \(ShellEnvironment.quote(log.path))
        case "$2" in
          *'DO.click(P)'*) echo '{"ok": true}' ;;
          *'DO.read(P)'*) printf '%s\\n' '{"ok": true, "text": "One\\thttps://one.example"}' ;;
          *) echo '["a", "b", 3]' ;;
        esac
        """ + "\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let script = try write("browser/results.straw", #"""
        click first css "h3 a"
        read links css "h3 a"
        js "[1].map(n => 'x\ty'.replace(/\s/g, ' \"quoted\"'))"
        """# + "\n")
        var env = ShellEnvironment.shared.environment
        env["STRAW_BROWSER"] = fake.path
        let r = try ScriptProcess(script: script, language: .straw, workingDirectory: folder, environment: env).runToEnd()
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertEqual(r.out, "One\thttps://one.example\na\nb\n3\n")
        let sent = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(sent.contains(#""thing": {"kind": "css", "name": "h3 a", "first": true}"#), sent)
        XCTAssertTrue(sent.contains(#""mode": "links", "thing": {"kind": "css", "name": "h3 a"}"#), sent)
        XCTAssertTrue(sent.contains(#"[1].map(n => 'x\ty'.replace(/\s/g, ' "quoted"'))"#), "\\t and \\s stay, \\\" is a quote: \(sent)")
        XCTAssertTrue(Caution.dangers(in: "click first \"Delete\"").count == 1)
        let check = try ScriptProcess(script: write("browser/bad.straw", "click first\n"), language: .straw, workingDirectory: folder, environment: env).runToEnd()
        XCTAssertEqual(check.code, 2)
        XCTAssertTrue(check.err.contains("first needs the thing after it."), check.err)
    }

    /// Check Setup says when straw.py is missing, and which Straw script has a mistake (and where).
    func testCheckSetupLooksAtThem() throws {
        _ = try write("browser/fine.straw", "# Fine\nread title\n")
        _ = try write("browser/broken.straw", "# Broken\nclik \"More\"\n")
        let lib = Library(root: folder)
        var titles = Doctor.check(lib).map(\.title)
        XCTAssertTrue(titles.contains("Straw (2): straw.py not found"), "\(titles)")
        try XCTSkipIf(!python, "needs python3")
        _ = try write("browser/straw.py", runner)
        let lines = Doctor.check(lib)
        titles = lines.map(\.title)
        XCTAssertFalse(titles.contains { $0.contains("straw.py not found") }, "\(titles)")
        let broken = try XCTUnwrap(lines.first { $0.title == "browser/broken.straw has a mistake" }, "\(titles)")
        XCTAssertTrue(broken.detail?.contains("line 2: Straw doesn't know \"clik\"") == true, broken.detail ?? "")
        XCTAssertFalse(titles.contains("browser/fine.straw has a mistake"))
    }

    /// A flow runs a Straw script by its name, as any script.
    func testAFlowRunsOneByName() throws {
        let names = Examples.allScripts.map(\.0)
        XCTAssertNoThrow(try Flow.check(#"run "hacker-news" [] |> lines |> take 5 |> each print"#, scripts: names))
        XCTAssertNoThrow(try Flow.check(#"run "browser/wikipedia-article.straw" ["Ada Lovelace"] |> print"#, scripts: names))
    }
}
