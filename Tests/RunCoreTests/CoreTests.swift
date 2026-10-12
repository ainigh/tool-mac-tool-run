import Foundation
@testable import RunCore
import XCTest

final class LanguageTests: XCTestCase {
    func testShebangWins() {
        XCTAssertEqual(ScriptLanguage.detect(fileName: "x.txt", contents: "#!/bin/bash\necho"), .bash)
        XCTAssertEqual(ScriptLanguage.detect(fileName: "x", contents: "#!/usr/bin/env python3\n"), .python)
        XCTAssertEqual(ScriptLanguage.detect(fileName: "x", contents: "#!/usr/bin/env -S deno run --allow-all\n"), .deno)
        XCTAssertEqual(ScriptLanguage.detect(fileName: "x.sh", contents: "#!/usr/bin/env node\n"), .node)
        XCTAssertEqual(ScriptLanguage.detect(fileName: "x", contents: "#!/opt/homebrew/bin/python3.12\n"), .python)
        XCTAssertEqual(ScriptLanguage.detect(fileName: "x", contents: "#!/bin/zsh -f\n"), .zsh)
    }

    func testExtensions() {
        XCTAssertEqual(ScriptLanguage.detect(fileName: "a.py", contents: "print(1)"), .python)
        XCTAssertEqual(ScriptLanguage.detect(fileName: "a.js", contents: ""), .node)
        XCTAssertEqual(ScriptLanguage.detect(fileName: "a.ts", contents: ""), .typescript)
        XCTAssertEqual(ScriptLanguage.detect(fileName: "a.rb", contents: ""), .ruby)
        XCTAssertEqual(ScriptLanguage.detect(fileName: "A.SH", contents: ""), .bash)
        XCTAssertEqual(ScriptLanguage.detect(fileName: "a.applescript", contents: ""), .applescript)
    }

    func testSniffing() {
        XCTAssertEqual(ScriptLanguage.detect(fileName: "tool", contents: "import os\nprint(os.getcwd())"), .python)
        XCTAssertEqual(ScriptLanguage.detect(fileName: "tool", contents: "set -e\necho hi"), .bash)
        XCTAssertEqual(ScriptLanguage.detect(fileName: "tool", contents: "<?php echo 1;"), .php)
        XCTAssertEqual(ScriptLanguage.detect(fileName: "tool", contents: "console.log(1)"), .node)
        XCTAssertEqual(ScriptLanguage.detect(fileName: "notes", contents: "just some words"), .unknown)
        XCTAssertEqual(ScriptLanguage.detect(fileName: "prog", contents: nil, executableBit: true), .executable)
    }

    func testTemplatesDetectAsTheirLanguage() {
        for lang in ScriptLanguage.offered {
            let name = "new." + lang.fileExtension
            let detected = ScriptLanguage.detect(fileName: name, contents: lang.template)
            XCTAssertEqual(detected, lang == .sh ? .sh : lang, "\(lang)")
        }
    }
}

final class ShellTests: XCTestCase {
    func testSplit() {
        XCTAssertEqual(ShellEnvironment.split(#"a "b c" 'd e' f\ g"#), ["a", "b c", "d e", "f g"])
        XCTAssertEqual(ShellEnvironment.split("  "), [])
        XCTAssertEqual(ShellEnvironment.split(#"--name="two words" """#), ["--name=two words", ""])
    }

    func testQuote() {
        XCTAssertEqual(ShellEnvironment.quote("simple"), "simple")
        XCTAssertEqual(ShellEnvironment.quote("two words"), "'two words'")
        XCTAssertEqual(ShellEnvironment.quote("it's"), #"'it'\''s'"#)
    }

    func testUTF8Chunker() {
        let c = UTF8Chunker()
        let data = Array("héllo ✅".utf8)
        var out = ""
        for b in data { out += c.feed(Data([b])) }
        out += c.finish()
        XCTAssertEqual(out, "héllo ✅")
    }
}

final class RunnerTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tmr-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testRunsAScriptWithArgsAndInput() throws {
        let url = folder.appendingPathComponent("t.sh")
        try "#!/bin/bash\necho \"args: $*\"\ncat\necho oops >&2\nexit 3\n".write(to: url, atomically: true, encoding: .utf8)
        let p = ScriptProcess(script: url, language: .bash, arguments: ["a", "b c"], stdin: "from stdin\n")
        let r = try p.runToEnd()
        XCTAssertEqual(r.code, 3)
        XCTAssertEqual(r.out, "args: a b c\nfrom stdin\n")
        XCTAssertEqual(r.err, "oops\n")
    }

    func testMissingInterpreterSaysHowToFix() {
        let url = folder.appendingPathComponent("t.lua")
        try? "print(1)".write(to: url, atomically: true, encoding: .utf8)
        let p = ScriptProcess(script: url, language: .lua, environment: ["PATH": "/nonexistent"])
        XCTAssertThrowsError(try p.runToEnd()) { e in
            XCTAssertTrue((e as? LaunchError)?.fix?.contains("brew install lua") == true)
        }
    }

    func testStop() throws {
        let url = folder.appendingPathComponent("slow.sh")
        try "#!/bin/bash\necho started\nsleep 30\n".write(to: url, atomically: true, encoding: .utf8)
        let p = ScriptProcess(script: url, language: .bash)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { p.stop() }
        let started = Date()
        let r = try p.runToEnd()
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        XCTAssertNotEqual(r.code, 0)
        XCTAssertTrue(p.wasStopped)
    }

    func testLibraryAndExamplesEndToEnd() throws {
        let lib = Library(root: folder)
        let added = try lib.addExamples()
        XCTAssertEqual(added.count, Examples.scripts.count + Examples.flows.count)
        // Again: nothing new, nothing lost.
        XCTAssertTrue(try lib.addExamples().isEmpty)
        let scripts = lib.scripts()
        XCTAssertEqual(Set(scripts.map(\.id)), Set(Examples.scripts.map(\.0)))
        XCTAssertEqual(scripts.first { $0.id == "hello.sh" }?.summary, "Says hello, with the date, to whoever is named (or the world)")
        XCTAssertEqual(lib.flows().count, Examples.flows.count)
        XCTAssertEqual(lib.script(named: "hello")?.id, "hello.sh")

        let lines = Locked<[String]>([])
        let host = LocalFlowHost(library: lib) { event in
            if case let .say(t) = event { lines.mutate { $0.append(t) } }
        }
        try Flow.run("""
        let r = run "hello" ["tests"]
        print r
        "a\\nb\\n" |> pipe "count-lines" [] |> print
        """, host: host, scripts: LocalFlowHost.names(in: lib))
        XCTAssertTrue(lines.value[0].hasPrefix("Hello, tests!"))
        if ShellEnvironment.shared.find("python3") != nil {
            XCTAssertEqual(lines.value[1], "2 lines, 2 words")
        }
    }

    func testFlowRunsAFlow() throws {
        let lib = Library(root: folder)
        try lib.ensure()
        _ = try lib.newFlow(name: "inner", contents: "print \"from inner\"\n")
        let lines = Locked<[String]>([])
        let host = LocalFlowHost(library: lib) { event in
            if case let .say(t) = event { lines.mutate { $0.append(t) } }
        }
        try Flow.run("run \"inner\" [] |> upper |> print", host: host, scripts: LocalFlowHost.names(in: lib))
        XCTAssertEqual(lines.value, ["FROM INNER"])
    }

    func testNewScriptNamesDontClash() throws {
        let lib = Library(root: folder)
        let a = try lib.newScript(name: "tool", language: .python)
        let b = try lib.newScript(name: "tool", language: .python)
        XCTAssertEqual(a.lastPathComponent, "tool.py")
        XCTAssertEqual(b.lastPathComponent, "tool-2.py")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: a.path))
    }

    func testDoctor() throws {
        let lib = Library(root: folder)
        try lib.addExamples()
        let lines = Doctor.check(lib)
        XCTAssertEqual(lines.first?.status, .ok)
        XCTAssertTrue(lines.contains { $0.title.hasPrefix("Bash") })
        XCTAssertEqual(Doctor.check(nil).first?.status, .problem)
        XCTAssertEqual(Doctor.check(Library(root: folder.appendingPathComponent("nope"))).first?.status, .problem)
    }
}

final class GridTests: XCTestCase {
    func item(_ name: String) -> ScriptItem {
        ScriptItem(url: URL(fileURLWithPath: "/s/\(name)"), language: .bash, summary: nil, modified: nil)
    }

    func testRowsFillTheSpace() {
        XCTAssertEqual(GridLayout.rows(for: 1, width: 1000, height: 600), [1])
        XCTAssertEqual(GridLayout.rows(for: 12, width: 1600, height: 900).reduce(0, +), 12)
        // Wide screens get more across than down.
        let rows = GridLayout.rows(for: 12, width: 1600, height: 900)
        XCTAssertGreaterThan(rows[0], rows.count)
        // No row more than one shorter than another.
        for n in 1...64 {
            let r = GridLayout.rows(for: n, width: 1400, height: 800)
            XCTAssertEqual(r.reduce(0, +), n)
            XCTAssertLessThanOrEqual((r.max() ?? 0) - (r.min() ?? 0), 1)
        }
    }

    func testOrderAndMove() {
        var g = GridSettings(order: ["c.sh", "gone.sh"])
        let items = ["a.sh", "b.sh", "c.sh"].map(item)
        XCTAssertEqual(g.arranged(items).map(\.id), ["c.sh", "a.sh", "b.sh"])
        g.move("b.sh", to: "c.sh", among: items)
        XCTAssertEqual(g.arranged(items).map(\.id), ["b.sh", "c.sh", "a.sh"])
    }

    func testPages() {
        var g = GridSettings(cells: 4)
        let items = (1...9).map { item("s\($0).sh") }
        // 9 scripts and a cell for a new one: 3 pages of 4.
        XCTAssertEqual(g.pageCount(for: items.count), 3)
        g.page = 2
        XCTAssertEqual(g.pageItems(items).map(\.id), ["s9.sh"])
        g.page = 7
        XCTAssertEqual(g.currentPage(for: items.count), 2)
    }

    func testStableTint() {
        XCTAssertEqual(GridSettings.stableTint("hello.sh"), GridSettings.stableTint("hello.sh"))
        for name in ["a", "b", "hello.sh", "x.py"] {
            XCTAssertTrue((1..<GridSettings.tints.count).contains(GridSettings.stableTint(name)))
        }
    }

    func testSettingsDecodeTolerantly() throws {
        let g = try JSONDecoder().decode(GridSettings.self, from: Data(#"{"cells": 999}"#.utf8))
        XCTAssertEqual(g.cells, GridSettings.maxCells)
        XCTAssertEqual(g.order, [])
    }

    func testRunRecordTrimsOutput() {
        var r = RunRecord(kind: .script, name: "x", file: "x", command: "x")
        r.append(.out, String(repeating: "a", count: RunRecord.maxOutput - 1) + "\n")
        r.append(.err, "tail\n")
        XCTAssertTrue(r.trimmed)
        XCTAssertEqual(r.text.utf8.count, RunRecord.maxOutput)
        XCTAssertEqual(r.lastLine, "tail")
    }

    func testSummary() {
        XCTAssertEqual(Library.summary("#!/bin/bash\n# Backs up photos\nset -e"), "Backs up photos")
        XCTAssertEqual(Library.summary("#!/usr/bin/env python3\n\"\"\"Sorts things\"\"\""), "Sorts things")
        XCTAssertEqual(Library.summary("// A flow\nprint 1"), "A flow")
        XCTAssertNil(Library.summary("#!/bin/bash\necho hi\n# later"))
    }

    func testDuration() {
        XCTAssertEqual(RunRecord.duration(0.42), "0.4 s")
        XCTAssertEqual(RunRecord.duration(42), "42 s")
        XCTAssertEqual(RunRecord.duration(185), "3 min 05 s")
    }
}

final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }
    func mutate(_ f: (inout T) -> Void) {
        lock.lock()
        f(&_value)
        lock.unlock()
    }
}
