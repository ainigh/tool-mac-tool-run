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
        XCTAssertEqual(ShellEnvironment.quote("--name=value"), "--name=value")
        XCTAssertEqual(ShellEnvironment.quote("/a/b-c_d.sh"), "/a/b-c_d.sh")
        // zsh expands a leading = (=ls is the path of ls) and ~: quoted.
        XCTAssertEqual(ShellEnvironment.quote("=ls"), "'=ls'")
        XCTAssertEqual(ShellEnvironment.quote("~"), "'~'")
        XCTAssertEqual(ShellEnvironment.quote("~/x"), "'~/x'")
        XCTAssertEqual(ShellEnvironment.quote(""), "''")
        for risky in ["a*", "a?", "$HOME", "a;b", "a|b", "a&b", "(a)", "a`b`", "!x", "a#b", "{a,b}", "[a]", "é", "a\tb", "a\nb", "\"q\""] {
            XCTAssertEqual(ShellEnvironment.quote(risky).first, "'", risky)
        }
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
        """, host: host, scripts: LocalFlowHost.names(in: lib))
        let first = try XCTUnwrap(lines.value.first, "the flow printed nothing")
        XCTAssertTrue(first.hasPrefix("Hello, tests!"), first)
    }

    func testExamplePipesIntoPython() throws {
        // count-lines.py needs python3: skipped before anything runs when it isn't there.
        try XCTSkipIf(ShellEnvironment.shared.find("python3") == nil, "count-lines.py needs python3")
        let lib = Library(root: folder)
        try lib.addExamples()
        let lines = Locked<[String]>([])
        let host = LocalFlowHost(library: lib) { event in
            if case let .say(t) = event { lines.mutate { $0.append(t) } }
        }
        try Flow.run(#""a\nb\n" |> pipe "count-lines" [] |> print"#, host: host, scripts: LocalFlowHost.names(in: lib))
        XCTAssertEqual(lines.value, ["2 lines, 2 words"])
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
        XCTAssertLessThanOrEqual(r.text.utf8.count, RunRecord.maxOutput)
        XCTAssertEqual(r.text.utf8.count, r.outputBytes)
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

/// Running scripts for real: broken pipes, stopping, how a run ended, #! lines.
final class ProcessTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tmr-process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A script in the folder (not marked executable unless asked).
    func script(_ name: String, _ body: String, executable: Bool = false) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        return url
    }

    func process(_ url: URL, _ args: [String] = [], stdin: String? = nil) -> ScriptProcess {
        let lang = ScriptLanguage.detect(fileName: url.lastPathComponent, contents: Library.head(of: url),
                                         executableBit: FileManager.default.isExecutableFile(atPath: url.path))
        return ScriptProcess(script: url, language: lang, arguments: args, stdin: stdin)
    }

    /// Ends what a test left in the background (its pid written to `file`).
    func killPid(in file: URL) {
        if let s = try? String(contentsOf: file, encoding: .utf8), let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
            kill(pid, SIGKILL)
        }
    }

    // MARK: SIGPIPE

    func testInputToAScriptThatDoesntReadIt() throws {
        // A script that never reads its input, handed 2 MB: the write fails with EPIPE, which must
        // neither raise SIGPIPE (it would end the test run) nor count as a failure.
        let url = try script("hi.sh", "#!/bin/sh\necho hi\n")
        let big = String(repeating: "0123456789abcdef\n", count: 128 * 1024)
        for _ in 0..<5 {
            let r = try process(url, stdin: big).runToEnd()
            XCTAssertEqual(r.code, 0)
            XCTAssertEqual(r.out, "hi\n")
            XCTAssertNil(r.signal)
        }
    }

    func testWriteToAClosedPipeIsNoSignal() throws {
        let p = Pipe()
        try p.fileHandleForReading.close()
        XCTAssertFalse(writeAll(Data("lost".utf8), to: p.fileHandleForWriting.fileDescriptor))
        // Still here: no SIGPIPE.
    }

    func testScriptsStillGetTheDefaultSIGPIPE() throws {
        // `yes | head -1` ends quietly only when SIGPIPE isn't ignored in the script: running one
        // mustn't ignore it for the whole process (scripts would inherit that).
        let before = signal(SIGPIPE, SIG_DFL)
        defer { signal(SIGPIPE, before) }
        let url = try script("yes.sh", "#!/bin/bash\nyes | head -1\n")
        let r = try process(url).runToEnd()
        XCTAssertEqual(r.out, "y\n")
        XCTAssertEqual(r.err, "")
    }

    // MARK: stopping

    func testStopEndsAChildThatIgnoresTERM() throws {
        // The child ignores SIGTERM and holds the output open: SIGKILL must reach it too.
        let url = try script("stubborn.sh", "#!/bin/bash\ntrap '' TERM\necho started\nsleep 20\necho never\n")
        let p = process(url)
        p.killGrace = 0.5
        let started = Date()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { p.stop() }
        let r = try p.runToEnd()
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
        XCTAssertEqual(r.out, "started\n")
        XCTAssertTrue(r.stopped)
        XCTAssertTrue(p.wasStopped)
        XCTAssertEqual(r.ending.summary, "stopped")
        XCTAssertFalse(r.ok)
    }

    func testStopAgainKillsAtOnce() throws {
        let url = try script("stubborn.sh", "#!/bin/bash\ntrap '' TERM\necho started\nsleep 20\n")
        let p = process(url)
        p.killGrace = 60
        let started = Date()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { p.stop() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { p.stop() }
        let r = try p.runToEnd()
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
        XCTAssertTrue(r.stopped)
    }

    func testABackgroundChildHoldingOutputDoesntKeepTheRunGoing() throws {
        let pidFile = folder.appendingPathComponent("bg.pid")
        let url = try script("bg.sh", "#!/bin/bash\necho start\nsleep 60 &\necho $! > \(ShellEnvironment.quote(pidFile.path))\necho done\n")
        defer { killPid(in: pidFile) }
        let p = process(url)
        p.drainGrace = 0.5
        let started = Date()
        let r = try p.runToEnd()
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
        XCTAssertEqual(r.out, "start\ndone\n")
        XCTAssertEqual(r.code, 0)
        XCTAssertTrue(r.err.contains("still running"), r.err)
    }

    func testStopAfterTheScriptEndedStopsWhatItLeft() throws {
        let pidFile = folder.appendingPathComponent("bg.pid")
        let url = try script("bg.sh", "#!/bin/bash\nsleep 60 &\necho $! > \(ShellEnvironment.quote(pidFile.path))\necho done\n")
        defer { killPid(in: pidFile) }
        let p = process(url)
        p.drainGrace = 60
        let started = Date()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { p.stop() }
        let r = try p.runToEnd()
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
        XCTAssertEqual(r.out, "done\n")
        XCTAssertTrue(r.stopped)
        // The background sleep was in its group: it's gone.
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertFalse(isRunning(pid), "the background child is still running")
    }

    /// A process is running (a zombie, ended but not yet reaped, isn't).
    func isRunning(_ pid: Int32) -> Bool {
        if let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
           let close = stat.lastIndex(of: ")") {
            return !stat[stat.index(after: close)...].trimmingCharacters(in: .whitespaces).hasPrefix("Z")
        }
        return kill(pid, 0) == 0
    }

    // MARK: how it ended

    func testEndedBySignal() throws {
        let url = try script("crash.sh", "#!/bin/bash\necho before\nkill -SEGV $$\necho after\n")
        let p = process(url)
        let r = try p.runToEnd()
        XCTAssertEqual(r.out, "before\n")
        XCTAssertEqual(r.signal, SIGSEGV)
        XCTAssertEqual(r.code, 128 + SIGSEGV)
        XCTAssertFalse(r.ok)
        XCTAssertFalse(r.stopped)
        XCTAssertEqual(r.ending.summary, "killed by signal \(SIGSEGV) (SIGSEGV)")
        XCTAssertEqual(p.ending, r.ending)

        var rec = RunRecord(kind: .script, name: "crash.sh", file: "crash.sh", command: "x")
        rec.finish(r.ending)
        XCTAssertEqual(rec.state, .failed)
        XCTAssertEqual(rec.ending?.summary, "killed by signal \(SIGSEGV) (SIGSEGV)")
    }

    func testExitCodeEnding() throws {
        let url = try script("three.sh", "#!/bin/sh\nexit 3\n")
        let r = try process(url).runToEnd()
        XCTAssertEqual(r.code, 3)
        XCTAssertNil(r.signal)
        XCTAssertEqual(r.ending.summary, "exit code 3")
        var rec = RunRecord(kind: .script, name: "x", file: nil, command: "x")
        rec.finish(r.ending)
        XCTAssertEqual(rec.state, .failed)
        rec.finish(RunEnding(code: 143, signal: SIGTERM, stopped: true))
        XCTAssertEqual(rec.state, .stopped)
        XCTAssertEqual(rec.ending?.summary, "stopped")
    }

    // MARK: #! lines

    func testShebangParsing() {
        XCTAssertEqual(Shebang.parse("#!/bin/sh -e\necho"), Shebang(interpreter: "/bin/sh", arguments: ["-e"]))
        XCTAssertEqual(Shebang.parse("#! /bin/bash\r\n"), Shebang(interpreter: "/bin/bash", arguments: []))
        let deno = Shebang.parse("#!/usr/bin/env -S deno run --allow-read\n")
        XCTAssertEqual(deno?.arguments, ["-S", "deno", "run", "--allow-read"])
        XCTAssertEqual(deno?.program, "deno")
        XCTAssertEqual(Shebang.parse("#!/usr/bin/env -i PATH=/x python3 -u\n")?.program, "python3")
        XCTAssertEqual(Shebang.parse("#!/usr/bin/env -u HOME node\n")?.program, "node")
        XCTAssertNil(Shebang.parse("#!/usr/bin/env -S\n")?.program)
        XCTAssertNil(Shebang.parse("#!\n"))
        XCTAssertNil(Shebang.parse("echo hi\n"))
        XCTAssertEqual(ScriptLanguage.detect(fileName: "x", contents: "#!/usr/bin/env bun\n"), .node)
    }

    func testShebangFlagsAreKept() throws {
        // `sh -e` stops at the first failing command; plain `sh` would go on.
        let url = try script("strict.sh", "#!/bin/sh -e\necho one\nfalse\necho two\n")
        let r = try process(url).runToEnd()
        XCTAssertEqual(r.out, "one\n")
        XCTAssertNotEqual(r.code, 0)
    }

    func testShebangInterpreterArgumentsAndPathInOrder() throws {
        let url = try script("echoes", "#!/bin/echo first second\n")
        let p = process(url, ["a b"])
        XCTAssertEqual(try p.runToEnd().out, "first second \(url.path) a b\n")
        XCTAssertEqual(p.commandLine, "cd \(ShellEnvironment.quote(folder.path)) && /bin/echo first second \(ShellEnvironment.quote(url.path)) 'a b'")
    }

    func testEnvSplitShebang() throws {
        let url = try script("split.sh", "#!/usr/bin/env -S sh -e\necho one\nfalse\necho two\n")
        let r = try process(url).runToEnd()
        XCTAssertEqual(r.out, "one\n")
    }

    func testShebangInterpreterWinsOverTheLanguage() throws {
        // Like a virtual environment's python: a .py file whose #! names a program by its path.
        let bin = folder.appendingPathComponent("venv/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent("mysh").path, withDestinationPath: "/bin/sh")
        let url = try script("tool.py", "#!\(bin.path)/mysh\necho \"ran by sh: $1\"\n")
        XCTAssertEqual(ScriptLanguage.detect(fileName: "tool.py", contents: try String(contentsOf: url, encoding: .utf8)), .python)
        let p = ScriptProcess(script: url, language: .python, arguments: ["x"])
        XCTAssertEqual(try p.runToEnd().out, "ran by sh: x\n")
        XCTAssertTrue(p.invocation.hasPrefix(bin.path + "/mysh "), p.invocation)
    }

    func testPlainEnvShebangReadsAsTheProgram() throws {
        let url = try script("e.sh", "#!/usr/bin/env sh\necho ok\n")
        let p = process(url, ["--flag"])
        XCTAssertEqual(p.invocation, "sh \(ShellEnvironment.quote(url.path)) --flag")
        XCTAssertEqual(try p.runToEnd().out, "ok\n")
    }

    func testMissingShebangInterpreterSaysHowToFix() throws {
        let gone = try script("gone.py", "#!/nowhere/.venv/bin/python\nprint(1)\n")
        XCTAssertThrowsError(try process(gone).runToEnd()) { e in
            let e = e as? LaunchError
            XCTAssertTrue(e?.message.contains("/nowhere/.venv/bin/python") == true, "\(String(describing: e))")
            XCTAssertTrue(e?.fix?.contains("#!/usr/bin/env python") == true, "\(String(describing: e))")
        }
        let missing = try script("m.lua", "#!/usr/bin/env lua\nprint(1)\n")
        let p = ScriptProcess(script: missing, language: .lua, environment: ["PATH": "/nonexistent"])
        XCTAssertThrowsError(try p.runToEnd()) { e in
            XCTAssertTrue((e as? LaunchError)?.fix?.contains("brew install lua") == true, "\(e)")
        }
        let lib = Library(root: folder)
        let doctor = Doctor.check(lib)
        XCTAssertTrue(doctor.contains { $0.status == .problem && $0.title.contains("/nowhere/.venv/bin/python") }, "\(doctor)")
    }

    func testTextExecutableWithoutShebangRunsWithSh() throws {
        let url = try script("plain", "printf 'plain %s\\n' \"$1\"\n", executable: true)
        XCTAssertEqual(ScriptLanguage.detect(fileName: "plain", contents: Library.head(of: url), executableBit: true), .executable)
        let p = process(url, ["arg"])
        XCTAssertEqual(try p.runToEnd().out, "plain arg\n")
        XCTAssertTrue(p.invocation.hasPrefix("sh "), p.invocation)
    }

    // MARK: the folder

    func testSymlinkedScriptsAndFlowsAppear() throws {
        let elsewhere = folder.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let real = elsewhere.appendingPathComponent("real-tool.sh")
        try "#!/bin/sh\n# Linked in\necho linked\n".write(to: real, atomically: true, encoding: .utf8)
        let realFlow = elsewhere.appendingPathComponent("real.flow")
        try "print \"hi\"\n".write(to: realFlow, atomically: true, encoding: .utf8)

        let lib = Library(root: folder.appendingPathComponent("scripts"))
        try lib.ensure()
        let fm = FileManager.default
        try fm.createSymbolicLink(at: lib.root.appendingPathComponent("linked.sh"), withDestinationURL: real)
        try fm.createSymbolicLink(at: lib.composerFolder.appendingPathComponent("linked.flow"), withDestinationURL: realFlow)
        try fm.createSymbolicLink(at: lib.root.appendingPathComponent("dangling.sh"), withDestinationURL: elsewhere.appendingPathComponent("nope.sh"))
        try fm.createSymbolicLink(at: lib.root.appendingPathComponent("a-folder"), withDestinationURL: elsewhere)

        let scripts = lib.scripts()
        XCTAssertEqual(scripts.map(\.id), ["linked.sh"])
        XCTAssertEqual(scripts.first?.url.lastPathComponent, "linked.sh")
        XCTAssertEqual(scripts.first?.summary, "Linked in")
        XCTAssertEqual(lib.flows().map(\.id), ["linked.flow"])
        let item = try XCTUnwrap(scripts.first)
        XCTAssertEqual(try ScriptProcess(script: item.url, language: item.language).runToEnd().out, "linked\n")
    }

    // MARK: the login shell's PATH

    func testLoginShellPathDoesntWaitForWhatTheProfileLeftRunning() throws {
        // A fake login shell whose startup leaves a child holding stdout, as some profiles do.
        let shell = try script("fakeshell", """
        #!/bin/sh
        ( sleep 15 ) &
        while [ $# -gt 0 ]; do
          if [ "$1" = -c ]; then PATH="/fake/login/bin:$PATH"; eval "$2"; exit; fi
          shift
        done
        """ + "\n", executable: true)
        let started = Date()
        let path = ShellEnvironment.loginShellPath(shell: shell.path, timeout: 6)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertTrue(path?.hasPrefix("/fake/login/bin:") == true, String(describing: path))
    }

    func testLoginShellPathFallsBackWithoutInteractive() throws {
        // A shell that fails when asked to be interactive: the login-only PATH is used.
        let shell = try script("fakeshell", """
        #!/bin/sh
        for a in "$@"; do [ "$a" = -i ] && exit 1; done
        while [ $# -gt 0 ]; do
          if [ "$1" = -c ]; then PATH="/login/only:$PATH"; eval "$2"; exit; fi
          shift
        done
        """ + "\n", executable: true)
        XCTAssertTrue(ShellEnvironment.loginShellPath(shell: shell.path, timeout: 4)?.hasPrefix("/login/only:") == true)
    }

    func testLoginShellPathGivesUpOnAStuckShell() throws {
        let shell = try script("stuck", "#!/bin/sh\nsleep 30\n", executable: true)
        let started = Date()
        XCTAssertNil(ShellEnvironment.loginShellPath(shell: shell.path, timeout: 1))
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    }
}

final class RunRecordTests: XCTestCase {
    func testTrimsOnCharacterBoundaries() {
        var r = RunRecord(kind: .script, name: "x", file: "x", command: "x")
        // "é" is 2 bytes: an odd number of bytes over the limit puts the cut inside one.
        r.append(.out, String(repeating: "é", count: RunRecord.maxOutput / 2))
        r.append(.out, "ab\n")  // over: trimmed to 270,000, a cut that falls inside an "é"
        XCTAssertEqual(r.outputBytes, RunRecord.maxOutput - RunRecord.maxOutput / 10 - 1)
        XCTAssertEqual(r.outputBytes, r.text.utf8.count)
        r.append(.err, "✅ done\n")
        XCTAssertTrue(r.trimmed)
        XCTAssertLessThanOrEqual(r.text.utf8.count, RunRecord.maxOutput)
        XCTAssertEqual(r.outputBytes, r.text.utf8.count)
        XCTAssertEqual(r.receivedBytes, RunRecord.maxOutput + 3 + "✅ done\n".utf8.count)
        XCTAssertTrue(r.text.hasPrefix("é"))
        XCTAssertEqual(r.lastLine, "✅ done")
        // Many small pieces: the kept size is tracked, not added up each time.
        for _ in 0..<20_000 { r.append(.out, "ü\n") }
        XCTAssertEqual(r.outputBytes, r.text.utf8.count)
        XCTAssertLessThanOrEqual(r.outputBytes, RunRecord.maxOutput)
        XCTAssertEqual(r.lastLine, "ü")
    }

    func testLastLine() {
        var r = RunRecord(kind: .script, name: "x", file: "x", command: "x")
        XCTAssertNil(r.lastLine)
        r.append(.out, "first\nsec")
        r.append(.err, "ond part")
        XCTAssertEqual(r.lastLine, "second part")
        r.append(.out, "\n\n")
        XCTAssertEqual(r.lastLine, "second part")
        r.append(.out, "  \n")
        XCTAssertNil(r.lastLine)
        r.append(.out, "50%\r60%\r")
        XCTAssertEqual(r.lastLine, "60%")
    }

    func testHistoryKeepsFractionsOfASecondAndReadsOldFiles() throws {
        var r = RunRecord(kind: .script, name: "x", file: "x", command: "x", started: Date(timeIntervalSince1970: 1_700_000_000.25))
        r.append(.out, "hi\n")
        r.finish(RunEnding(code: 0), at: Date(timeIntervalSince1970: 1_700_000_001.5))
        let back = try RunHistory.decode(RunHistory.encode([r]))
        XCTAssertEqual(try XCTUnwrap(back.first?.seconds), 1.25, accuracy: 0.002)
        XCTAssertEqual(back.first?.text, "hi\n")
        XCTAssertEqual(back.first?.outputBytes, 3)

        // As saved before: whole seconds, and no signal or byte count.
        let old = #"""
        [{"id":"6F1B5F7A-1D2B-4C3D-8E9F-0A1B2C3D4E5F","kind":"script","name":"x","file":"x","arguments":[],"command":"x",
          "started":"2024-05-01T10:00:00Z","ended":"2024-05-01T10:00:02Z","code":0,"state":"succeeded",
          "output":[{"stream":"out","text":"héllo\n"}],"trimmed":false}]
        """#
        let runs = try RunHistory.decode(Data(old.utf8))
        XCTAssertEqual(runs.first?.seconds, 2)
        XCTAssertEqual(runs.first?.receivedBytes, "héllo\n".utf8.count)
        XCTAssertNil(runs.first?.signal)
    }

    func testHistoryCountsOnlyTopLevelRunsAndCapsSavedOutput() throws {
        var runs: [RunRecord] = []
        for k in 0..<5 {
            var flow = RunRecord(kind: .flow, name: "f\(k)", file: "f\(k)", command: "flow")
            flow.finish(code: 0, state: .succeeded)
            runs.append(flow)
            for s in 0..<10 {
                var step = RunRecord(kind: .step, name: "s\(s)", file: nil, command: "s", parent: flow.id)
                step.finish(code: 0, state: .succeeded)
                runs.append(step)
            }
        }
        let going = RunRecord(kind: .script, name: "old but going", file: "g", command: "g")
        runs.insert(going, at: 0)
        let kept = RunHistory.trimmed(runs, keep: 2)
        XCTAssertEqual(kept.filter { $0.parent == nil }.map(\.name), ["old but going", "f3", "f4"])
        XCTAssertEqual(kept.filter { $0.parent != nil }.count, 20)

        var big = RunRecord(kind: .script, name: "big", file: "big", command: "big")
        big.append(.out, String(repeating: "x", count: 200_000))
        big.finish(code: 0, state: .succeeded)
        let saved = try RunHistory.decode(RunHistory.encode([big]))
        XCTAssertEqual(saved.first?.outputBytes, RunHistory.savedOutput)
        XCTAssertEqual(saved.first?.trimmed, true)
        XCTAssertEqual(saved.first?.receivedBytes, 200_000)
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
