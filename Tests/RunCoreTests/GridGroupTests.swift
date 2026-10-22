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
        let utilities = try lib.addExamples(for: .utilities)
        XCTAssertEqual(utilities.count, Examples.utilities.count)
        XCTAssertEqual(Set(lib.items(.utilities).map(\.id)), Set(Examples.utilities.map(\.0)))
        XCTAssertTrue(lib.items(.scripts).isEmpty, "the Utilities grid's examples are its own")
        XCTAssertTrue(lib.flows().isEmpty, "the flows wait for the browser scripts they run")

        let browser = try lib.addExamples(for: .browser)
        XCTAssertEqual(browser.count, Examples.browser.count + Examples.toolFlows.count)
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

    /// browser.sh with a stand-in for osascript: what it says when the browser can't be driven
    /// yet, and what it hands back when it can.
    func testTheBrowserHelperExplainsWhatsMissing() throws {
        try XCTSkipIf(ShellEnvironment.shared.find("bash") == nil, "needs bash")
        let lib = Library(root: folder)
        try lib.addExamples(for: .browser)
        let bin = folder.appendingPathComponent("fakebin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let fake = bin.appendingPathComponent("osascript")
        try #"""
        #!/bin/bash
        script=$(cat)
        case "$script" in
          *ObjC.import*) printf 'com.google.Chrome\tGoogle Chrome\n' ;;
          *"execute active tab"*)
            if [ -n "${FAKE_NO_JS:-}" ]; then echo "execution error: Executing JavaScript through AppleScript is turned off. (12)" >&2; exit 1; fi
            printf 'ran %s\n' "$3" ;;
          *"title of t"*) echo "Example Domain" ;;
          *) echo "?" ;;
        esac
        """#.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let path = bin.path + ":/usr/bin:/bin"

        let which = try run("browser.sh", path: path)
        XCTAssertEqual(which.code, 0, which.err)
        XCTAssertTrue(which.out.hasPrefix("Your browser: Google Chrome (com.google.Chrome)"), which.out)
        XCTAssertEqual(try run("browser.sh", ["title"], path: path).out, "Example Domain\n")
        let js = try run("browser.sh", ["js", "document.title;"], path: path)
        XCTAssertTrue(js.out.hasPrefix("ran (() =>"), js.out)
        XCTAssertTrue(js.out.contains("return (\ndocument.title\n);"), "an expression is given back, its ; dropped: \(js.out)")
        let unknown = try run("browser.sh", ["fly"], path: path)
        XCTAssertEqual(unknown.code, 1)
        XCTAssertTrue(unknown.err.contains("It knows: which, open URL"), unknown.err)

        // JavaScript not allowed yet: the one setting that allows it, by name.
        var env = ShellEnvironment.shared.environment
        env["PATH"] = path
        env["FAKE_NO_JS"] = "1"
        let item = try XCTUnwrap(lib.script(named: "page-links"))
        let links = try ScriptProcess(script: item.url, language: item.language, workingDirectory: folder, environment: env).runToEnd()
        XCTAssertEqual(links.code, 1)
        XCTAssertTrue(links.err.contains("View > Developer > Allow JavaScript from Apple Events"), links.err)
    }
}
