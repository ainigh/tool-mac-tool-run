import Foundation
@testable import RunCore
import XCTest

/// The Utilities and Browser grids: scripts like any other, kept in folders of their own, named
/// by that folder and their file (`utilities/speak.sh`), run by flows and the API by name.
final class GridGroupTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("groups-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func write(_ id: String, _ text: String) throws {
        let url = folder.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testEachGridHasItsFolderAndItsScripts() throws {
        let lib = Library(root: folder)
        let made = try lib.ensure()
        XCTAssertEqual(Set(made), Set([folder, lib.composerFolder, lib.folder(.utilities), lib.folder(.browser)].map(\.path)))
        try write("hello.sh", "#!/bin/bash\n# Says hello\necho hello\n")
        try write("utilities/speak.sh", "#!/bin/bash\n# Says it out loud\nsay \"$@\"\n")
        try write("utilities/notes.md", "# not a script\n")
        try write("browser/page-info.sh", "#!/bin/bash\n# The page in front\necho page\n")
        try write("composer/greet.flow", "// Greets\nprint \"hi\"\n")

        XCTAssertEqual(lib.scripts().map(\.id), ["hello.sh", "utilities/speak.sh", "browser/page-info.sh"])
        XCTAssertEqual(lib.items(.scripts).map(\.id), ["hello.sh"])
        XCTAssertEqual(lib.items(.utilities).map(\.id), ["utilities/speak.sh"])
        XCTAssertEqual(lib.items(.browser).map(\.id), ["browser/page-info.sh"])
        XCTAssertEqual(lib.items(.composer).map(\.id), ["greet.flow"])
        let speak = try XCTUnwrap(lib.items(.utilities).first)
        XCTAssertEqual(speak.title, "speak")
        XCTAssertEqual(speak.summary, "Says it out loud")
        XCTAssertEqual(speak.grid, .utilities)
        XCTAssertEqual(lib.items(.composer).first?.grid, .composer)
        XCTAssertEqual(GridKind.of(scriptID: speak.id), .utilities)
        XCTAssertEqual(GridKind.of(scriptID: "browser/page-info.sh"), .browser)
        XCTAssertEqual(GridKind.of(scriptID: "hello.sh"), .scripts)
        // A file at the top whose name starts like a folder's is still the Scripts grid's.
        XCTAssertEqual(GridKind.of(scriptID: "utilities.sh"), .scripts)
    }

    func testANewScriptGoesInItsGridsFolder() throws {
        let lib = Library(root: folder)
        let url = try lib.newScript(name: "untitled", language: .python, in: .utilities)
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "utilities")
        XCTAssertEqual(lib.items(.utilities).map(\.id), ["utilities/untitled.py"])
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url.path))
        XCTAssertEqual(try lib.newScript(name: "x", language: .bash).deletingLastPathComponent().standardizedFileURL, folder.standardizedFileURL)
    }

    func testRunFindsAScriptByItsIdOrItsNameAlone() throws {
        let lib = Library(root: folder)
        try write("hello.sh", "#!/bin/bash\necho top\n")
        try write("utilities/hello.sh", "#!/bin/bash\necho utility\n")
        try write("utilities/speak.sh", "#!/bin/bash\necho said\n")
        try write("browser/page-info.sh", "#!/bin/bash\necho page\n")
        // The folder's own script wins a shared name; the folder in front picks the other.
        XCTAssertEqual(lib.script(named: "hello")?.id, "hello.sh")
        XCTAssertEqual(lib.script(named: "utilities/hello")?.id, "utilities/hello.sh")
        XCTAssertEqual(lib.script(named: "utilities/hello.sh")?.id, "utilities/hello.sh")
        // A name of its own needs no folder.
        XCTAssertEqual(lib.script(named: "speak")?.id, "utilities/speak.sh")
        XCTAssertEqual(lib.script(named: "speak.sh")?.id, "utilities/speak.sh")
        XCTAssertEqual(lib.script(named: "page-info")?.id, "browser/page-info.sh")
        // A folder that's wrong isn't guessed past.
        XCTAssertNil(lib.script(named: "browser/speak"))
        XCTAssertNil(lib.script(named: "nothing"))

        // The check before running knows them too, and a flow runs them.
        let names = LocalFlowHost.names(in: lib)
        XCTAssertNoThrow(try Flow.check("run \"speak\" [] |> print\nrun \"utilities/hello\" [] |> print", scripts: names))
        XCTAssertThrowsError(try Flow.check("run \"speek\" [] |> print", scripts: names))
        let said = Locked<[String]>([])
        let host = LocalFlowHost(library: lib) { event in
            if case let .say(t) = event { said.mutate { $0.append(t) } }
        }
        try Flow.run("run \"speak\" [] |> print\nrun \"utilities/hello\" [] |> print\nrun \"hello\" [] |> print",
                     host: host, scripts: names)
        XCTAssertEqual(said.value, ["said", "utility", "top"])
    }

    func testEachGridsExamplesAndTheFlowsThatNeedThemAll() throws {
        let lib = Library(root: folder)
        // The weather, news and cloud flows need only utilities: they come with them. The rest
        // wait for the browser scripts they run.
        let utilityFlows = ["weather-now.flow", "news-briefing.flow", "urgent-news.flow", "cloud-check.flow", "morning-briefing.flow"]
        let utilities = try lib.addExamples(for: .utilities)
        XCTAssertEqual(utilities.count, Examples.utilities.count + utilityFlows.count)
        XCTAssertEqual(Set(lib.items(.utilities).map(\.id)), Set(Examples.utilities.map(\.0)))
        XCTAssertTrue(lib.items(.scripts).isEmpty, "the Utilities grid's examples are its own")
        XCTAssertEqual(Set(lib.flows().map(\.id)), Set(utilityFlows))

        let browser = try lib.addExamples(for: .browser)
        XCTAssertEqual(browser.count, Examples.browser.count + Examples.toolFlows.count - utilityFlows.count)
        XCTAssertEqual(Set(lib.flows().map(\.id)), Set(Examples.toolFlows.map(\.0)))
        XCTAssertTrue(try lib.addExamples(for: .browser).isEmpty)

        // The Scripts grid's examples are the ones it always had.
        XCTAssertEqual(try lib.addExamples(for: .scripts).count, Examples.scripts.count + Examples.flows.count)
        for kind in GridKind.scriptGrids {
            for item in lib.items(kind) {
                XCTAssertNotNil(item.summary, "\(item.id) says what it does on its cell")
                XCTAssertTrue(FileManager.default.isExecutableFile(atPath: item.url.path), item.id)
                XCTAssertEqual(item.dangers, [], item.id)
            }
        }
        XCTAssertEqual(Library.examplesSummary(for: .utilities), "\(Examples.utilities.count) utilities")
        XCTAssertEqual(Library.examplesSummary(for: .browser), "\(Examples.browser.count) browser scripts")
        XCTAssertEqual(Library.examplesSummary(for: .composer), "5 scripts and 4 flows")
    }

    /// An example still exactly as an earlier version wrote it is brought up to date; one someone
    /// changed is left alone.
    func testEarlierExamplesAreBroughtUpToDate() throws {
        XCTAssertEqual(Examples.fingerprint(""), 0xcbf2_9ce4_8422_2325)
        XCTAssertEqual(Examples.fingerprint("a"), 0xaf63_dc4c_8601_ec8c)
        for (id, source) in Examples.utilities + Examples.browser + Examples.toolFlows {
            XCTAssertFalse(Examples.earlierTools[id]?.contains(Examples.fingerprint(source)) == true, "\(id) is still its earlier version")
        }
        let lib = Library(root: folder)
        try lib.ensure()
        let helper = folder.appendingPathComponent("browser/browser.sh")
        let flow = lib.composerFolder.appendingPathComponent("page-aloud.flow")
        let old = "#!/bin/bash\n# the old one\n"
        try old.write(to: helper, atomically: true, encoding: .utf8)
        try "// mine, changed\n".write(to: flow, atomically: true, encoding: .utf8)
        let earlier = ["browser/browser.sh": [Examples.fingerprint(old)], "page-aloud.flow": [Examples.fingerprint(old)]]
        XCTAssertEqual(lib.updateExamples(earlier: earlier).map(\.lastPathComponent), ["browser.sh"])
        XCTAssertEqual(try String(contentsOf: helper, encoding: .utf8), Examples.browser.first { $0.0 == "browser/browser.sh" }?.1)
        XCTAssertEqual(try String(contentsOf: flow, encoding: .utf8), "// mine, changed\n")
        XCTAssertEqual(lib.updateExamples(earlier: earlier), [], "safe to run again")
    }

    func testGridWords() {
        XCTAssertEqual(GridKind.allCases.map(\.title), ["Scripts", "Composer", "Utilities", "Browser"])
        XCTAssertEqual(GridKind.utilities.count(1), "1 utility")
        XCTAssertEqual(GridKind.utilities.count(3), "3 utilities")
        XCTAssertEqual(GridKind.browser.count(2), "2 browser scripts")
        XCTAssertEqual(GridKind.composer.count(0), "0 flows")
        XCTAssertEqual(GridKind.allCases.filter(\.isFlow), [.composer])
        // Each grid's settings are kept apart.
        XCTAssertEqual(Set(GridKind.allCases.map { GridSettings.url(for: $0).lastPathComponent }).count, 4)
    }

    func testCheckSetupCountsThemAmongTheScripts() throws {
        let lib = Library(root: folder)
        try write("hello.sh", "#!/bin/bash\necho hi\n")
        try write("utilities/a.sh", "#!/bin/bash\necho a\n")
        try write("utilities/b.sh", "#!/bin/bash\necho b\n")
        try write("browser/c.sh", "#!/bin/bash\necho c\n")
        let titles = Doctor.check(lib, environment: ShellEnvironment.shared).map(\.title)
        XCTAssertTrue(titles.contains("4 scripts (2 utilities, 1 browser script among them), 0 flows"), "\(titles)")
    }

    // MARK: the examples themselves

    private func run(_ id: String, _ args: [String] = [], stdin: String? = nil, path: String? = nil) throws -> RunResult {
        let lib = Library(root: folder)
        let item = try XCTUnwrap(lib.script(named: id), id)
        var env = ShellEnvironment.shared.environment
        if let path { env["PATH"] = path }
        return try ScriptProcess(script: item.url, language: item.language, arguments: args, stdin: stdin,
                                 workingDirectory: folder, environment: env).runToEnd()
    }

    func testEveryExampleShellScriptParses() throws {
        try XCTSkipIf(ShellEnvironment.shared.find("bash") == nil, "needs bash")
        try Library(root: folder).addExamples()
        for (id, source) in Examples.allScripts where source.hasPrefix("#!/bin/bash") {
            let r = try ScriptProcess(shell: "bash -n \(ShellEnvironment.quote(folder.appendingPathComponent(id).path))",
                                      workingDirectory: folder).runToEnd()
            XCTAssertEqual(r.code, 0, "\(id): \(r.err)")
        }
    }

    func testTheDataUtilitiesWorkTogether() throws {
        try XCTSkipIf(ShellEnvironment.shared.find("python3") == nil, "the data utilities need python3")
        let lib = Library(root: folder)
        try lib.addExamples(for: .utilities)
        let csv = "name,email\nAda,ada@example.com\nGrace,grace@example.com\n"
        let json = try run("csv-to-json", stdin: csv)
        XCTAssertEqual(json.code, 0, json.err)
        XCTAssertEqual(try run("json-get", ["*.email"], stdin: json.out).out, "ada@example.com\ngrace@example.com\n")
        XCTAssertEqual(try run("json-get", ["1.name"], stdin: json.out).out, "Grace\n")
        let missing = try run("json-get", ["nope"], stdin: json.out)
        XCTAssertEqual(missing.code, 1)
        XCTAssertTrue(missing.err.contains("Nothing at nope"), missing.err)
        XCTAssertTrue(try run("json-get", ["a"], stdin: "{oops").err.contains("That isn't JSON"))
        let urls = try run("extract-urls", stdin: "See https://a.example/x. Or (https://b.example/y), https://a.example/x again")
        XCTAssertEqual(urls.out, "https://a.example/x\nhttps://b.example/y\n")

        // And from a flow, by their names alone.
        let said = Locked<[String]>([])
        let host = LocalFlowHost(library: lib) { event in
            if case let .say(t) = event { said.mutate { $0.append(t) } }
        }
        try Flow.run(#""a,b\n1,2\n3,4" |> pipe "csv-to-json" [] |> pipe "json-get" ["*.b"] |> lines |> each print"#,
                     host: host, scripts: LocalFlowHost.names(in: lib))
        XCTAssertEqual(said.value, ["2", "4"])
    }

    /// browser.sh with a stand-in for osascript: Chrome's answers, what it says when JavaScript
    /// isn't allowed yet, and the scripts made of it.
    func testTheBrowserHelperDrivesChromeAndExplainsWhatsMissing() throws {
        try XCTSkipIf(ShellEnvironment.shared.find("bash") == nil || ShellEnvironment.shared.find("python3") == nil, "needs bash and python3")
        let lib = Library(root: folder)
        try lib.addExamples(for: .browser)
        let bin = folder.appendingPathComponent("fakebin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let fake = bin.appendingPathComponent("osascript")
        let log = folder.appendingPathComponent("osascript.log")
        try #"""
        #!/bin/bash
        script="$*
        $(cat)"
        case "$script" in
          *encodeURIComponent*) python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$4" ;;
          *"path to application id"*) echo "/Applications/Google Chrome.app/" ;;
          *"is running"*) echo true ;;
          *'javascript "1+1"'*) echo 2 ;;
          *"execute t javascript"*)
            if [ -n "${FAKE_NO_JS:-}" ]; then echo "execution error: Executing JavaScript through AppleScript is turned off. (12)" >&2; exit 1; fi
            echo "js $4" >> "$FAKE_LOG"
            echo "${FAKE_JS_OUT:-ran $4}" ;;
          *"if wanted is"*) echo 11 ;;
          *"make new tab"*) echo "opened $3 $4" >> "$FAKE_LOG"; echo 22 ;;
          *"loading of t"*) echo false ;;
          *"close t"*) echo "closed $3" >> "$FAKE_LOG" ;;
          *"title of t"*) echo "Example Domain" ;;
          *) echo "?" ;;
        esac
        """#.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        func browse(_ id: String, _ args: [String], _ extra: [String: String] = [:]) throws -> RunResult {
            let item = try XCTUnwrap(lib.script(named: id), id)
            var env = ShellEnvironment.shared.environment
            env["PATH"] = bin.path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
            env["FAKE_LOG"] = log.path
            env.merge(extra) { _, b in b }
            return try ScriptProcess(script: item.url, language: item.language, arguments: args, workingDirectory: folder, environment: env).runToEnd()
        }

        let status = try browse("browser.sh", [])
        XCTAssertEqual(status.code, 0, status.err)
        XCTAssertTrue(status.out.hasPrefix("Google Chrome: /Applications/Google Chrome.app/"), status.out)
        XCTAssertTrue(status.out.contains("✅ JavaScript from Apple Events is on"), status.out)
        XCTAssertEqual(try browse("browser.sh", ["title"]).out, "Example Domain\n")
        XCTAssertEqual(try browse("browser.sh", ["encode", "a b&c"]).out, "a%20b%26c\n")

        // An expression is given back (its ; dropped); statements keep their own return.
        let js = try browse("browser.sh", ["js", "document.title;"])
        XCTAssertTrue(js.out.contains("return (\ndocument.title\n);"), js.out)
        let statements = try browse("browser.sh", ["js", "const t = document.title\nreturn t"])
        XCTAssertFalse(statements.out.contains("return (\nconst"), statements.out)
        let nested = try browse("browser.sh", ["js", "[1].map(x => { return x })"])
        XCTAssertTrue(nested.out.contains("return (\n[1].map"), "a return inside a function is still one expression: \(nested.out)")

        // Reading a page: a tab of its own behind the one in front, closed after.
        try? FileManager.default.removeItem(at: log)
        let read = try browse("browser.sh", ["read", "example.com"])
        XCTAssertEqual(read.code, 0, read.err)
        let steps = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(steps.contains("opened https://example.com behind"), steps)
        XCTAssertTrue(steps.contains("closed 22"), steps)

        // Google: the question in the address, and Google's robot check said as such.
        let google = try browse("google", ["how tall", "is it"])
        XCTAssertEqual(google.code, 0, google.err)
        XCTAssertTrue(try String(contentsOf: log, encoding: .utf8).contains("q=how%20tall%20is%20it"))
        let robot = try browse("google", ["anything"], ["FAKE_JS_OUT": "TMR_ROBOT_CHECK"])
        XCTAssertEqual(robot.code, 1)
        XCTAssertTrue(robot.err.contains("Google wants to check this isn't a robot"), robot.err)
        let none = try browse("youtube", [])
        XCTAssertEqual(none.code, 1)
        XCTAssertTrue(none.err.contains("What should YouTube be searched for?"), none.err)

        let unknown = try browse("browser.sh", ["fly"])
        XCTAssertEqual(unknown.code, 1)
        XCTAssertTrue(unknown.err.contains("It knows: open, read"), unknown.err)

        // JavaScript not allowed yet: the one setting that allows it, by name.
        let links = try browse("page-links", [], ["FAKE_NO_JS": "1"])
        XCTAssertEqual(links.code, 1)
        XCTAssertTrue(links.err.contains("View > Developer > Allow JavaScript from Apple Events"), links.err)
    }

    /// The weather, the news and the cloud services need the internet; what they say before
    /// reaching for it doesn't.
    func testTheInfoUtilitiesSayWhatTheyTake() throws {
        try XCTSkipIf(ShellEnvironment.shared.find("python3") == nil, "they need python3")
        try Library(root: folder).addExamples(for: .utilities)
        let services = try run("cloud-status", ["--list"])
        XCTAssertEqual(services.code, 0, services.err)
        XCTAssertTrue(services.out.hasPrefix("AWS\nGoogle Cloud\nAzure\n"), services.out)
        XCTAssertTrue(services.out.contains("GitHub\n") && services.out.contains("Claude\n"), services.out)
        XCTAssertTrue(try run("weather", ["--days", "x"]).err.contains("--days takes a number"))
        XCTAssertTrue(try run("news", ["--count", "x"]).err.contains("--count takes a number"))
    }
}
