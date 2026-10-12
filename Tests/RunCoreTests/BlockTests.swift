import XCTest
@testable import RunCore

/// The block editor's model: blocks are written as Flow and read back as the same blocks, a file
/// opened as blocks and not changed is written back exactly as it was, and nothing is ever lost.
final class BlockTests: XCTestCase {
    let scripts = ["hello.sh", "disk-space.sh", "count-lines.py", "shout.js", "big-files.sh"]

    private func block(_ type: BlockType, _ change: (inout FlowBlock) -> Void = { _ in }) -> FlowBlock {
        var b = FlowBlock(type)
        change(&b)
        return b
    }

    private func short(_ b: FlowBlock) -> String {
        "\(b.type) script=\(b.script) args=\(b.args) text=\(b.text) input=\(b.input) keep=\(b.keepGoing) name=\(b.name) cond=\(b.condition) number=\(b.number) subject=\(b.subject) eachLine=\(b.eachLine) other=\(b.hasOtherwise) children=[\(b.children.map(short).joined(separator: ", "))] otherwise=[\(b.otherwise.map(short).joined(separator: ", "))]"
    }

    /// Writes the blocks, checks the Flow they make, reads it back: the same blocks.
    private func roundTrip(_ doc: FlowDocument, file: StaticString = #filePath, line: UInt = #line) -> String {
        let text = doc.written().text
        do {
            _ = try Flow.check(text, scripts: scripts)
        } catch {
            XCTFail("\(error)\n---\n\(text)", file: file, line: line)
        }
        let back = FlowDocument.read(text)
        XCTAssertEqual(back.summary, doc.summary, file: file, line: line)
        XCTAssertEqual(back.blocks.count, doc.blocks.count, "\n---\n\(text)", file: file, line: line)
        for (x, y) in zip(back.blocks, doc.blocks) where x.content() != y.content() {
            XCTFail("read back as \(short(x))\nwritten from \(short(y))\n---\n\(text)", file: file, line: line)
        }
        // And written again: the same text.
        XCTAssertEqual(back.written().text, text, file: file, line: line)
        return text
    }

    func testEveryKindOfBlockReadsBackAsItself() {
        let doc = FlowDocument(summary: "Every block", blocks: [
            block(.comment) { $0.text = "First, the greeting\nover two lines" },
            block(.runScript) { $0.script = "hello"; $0.args = ["friend", "{args}"]; $0.name = "greeting" },
            block(.runScript) { $0.script = "count-lines"; $0.input = "{greeting}"; $0.name = "counted" },
            block(.runScript) { $0.script = "disk-space"; $0.keepGoing = true; $0.name = "disk" },
            block(.runScript) { $0.script = "shout"; $0.keepGoing = true; $0.input = "{disk.out} is used"; $0.name = "loud" },
            block(.runScript) { $0.script = "hello"; $0.name = "" },
            block(.shell) { $0.text = "date +%A"; $0.name = "today" },
            block(.show) { $0.text = "{greeting}" },
            block(.show) { $0.text = "Today is {today}, braces {{like this}}, \"quotes\" and a \\ backslash" },
            block(.show) { $0.text = "{length (lines greeting)}" },
            block(.notify) { $0.text = "{counted}" },
            block(.confirm) { $0.text = "Go on with {today}?" },
            block(.ask) { $0.text = "Who is it for?"; $0.name = "who" },
            block(.askYesNo) { $0.text = "Upload?"; $0.name = "upload" },
            block(.choose) { $0.text = "Which size?"; $0.args = ["small", "{who}"]; $0.name = "size" },
            block(.text) { $0.text = "Dear {who}"; $0.name = "letter" },
            block(.text) { $0.text = "{who}"; $0.name = "copy" },
            block(.readFile) { $0.text = "~/notes.txt"; $0.name = "notes" },
            block(.writeFile) { $0.input = "~/Desktop/{who}.txt"; $0.text = "{letter}" },
            block(.wait) { $0.number = "2" },
            block(.ifThen) {
                $0.condition = Condition(subject: "disk", test: .failed)
                $0.children = [block(.stop) { $0.text = "The disk check failed: {disk.err}" }]
            },
            block(.ifThen) {
                $0.condition = Condition(subject: "counted", test: .greater, value: "85", bare: true, asNumber: true)
                $0.children = [block(.show) { $0.text = "big" }, block(.comment) { $0.text = "inside" }]
                $0.hasOtherwise = true
                $0.otherwise = [block(.show) { $0.text = "small" }]
            },
            block(.repeatEach) {
                $0.subject = "greeting"
                $0.eachLine = true
                $0.name = "line"
                $0.children = [block(.show) { $0.text = "→ {line}" },
                               block(.ifThen) {
                                   $0.condition = Condition(subject: "line", test: .contains, value: "hi")
                                   $0.children = [block(.notify) { $0.text = "{line}" }]
                               }]
            },
            block(.repeatEach) {
                $0.subject = "args"
                $0.eachLine = false
                $0.name = "a"
                $0.children = [block(.show) { $0.text = "{a}" }]
            },
            block(.repeatCount) {
                $0.number = "3"
                $0.name = "i"
                $0.children = [block(.show) { $0.text = "Round {i}" }, block(.wait) { $0.number = "{i}" }]
            },
            block(.ifThen) { $0.condition = Condition(test: .answeredYes, value: "Clean up?") },
            block(.code) { $0.text = "let twice f x =\n    f (f x)" },
        ])
        let text = roundTrip(doc)
        XCTAssertTrue(text.hasPrefix("// Every block\n"))
        XCTAssertTrue(text.contains("let greeting = run \"hello\" [\"friend\"; $\"{args}\"]"), text)
        XCTAssertTrue(text.contains("let counted = greeting |> pipe \"count-lines\" []"), text)
        XCTAssertTrue(text.contains("let loud = $\"{disk.out} is used\" |> attemptPipe \"shout\" []"), text)
        XCTAssertTrue(text.contains("run \"hello\" [] |> ignore"), text)
        XCTAssertTrue(text.contains("print greeting\n"), text)
        XCTAssertTrue(text.contains("let copy = $\"{who}\""), text)
        XCTAssertTrue(text.contains("if int counted > 85 then"), text)
        XCTAssertTrue(text.contains("for line in lines greeting do"), text)
        XCTAssertTrue(text.contains("for i in range 1 3 do"), text)
        XCTAssertTrue(text.contains("if askYesNo \"Clean up?\" then\n    ()"), text)
    }

    func testEveryTestOfAnIfReadsBackAsItself() {
        let vars: [FlowBlock] = [
            block(.runScript) { $0.script = "hello"; $0.name = "t" },
            block(.runScript) { $0.script = "hello"; $0.keepGoing = true; $0.name = "r" },
            block(.askYesNo) { $0.text = "?"; $0.name = "b" },
            block(.code) { $0.text = "let n = 5" },
            block(.code) { $0.text = "let xs = [1; 2]" },
        ]
        let cases: [Condition] = [
            Condition(subject: "t", test: .equals, value: "hi"),
            Condition(subject: "t", test: .notEquals, value: "x {t}"),
            Condition(subject: "n", test: .equals, value: "5", bare: true),
            Condition(subject: "n", test: .notEquals, value: "{n}", bare: true),
            Condition(subject: "t", test: .contains, value: "h"),
            Condition(subject: "t", test: .notContains, value: "h"),
            Condition(subject: "t", test: .startsWith, value: "h"),
            Condition(subject: "t", test: .endsWith, value: "!"),
            Condition(subject: "n", test: .greater, value: "3", bare: true),
            Condition(subject: "n", test: .less, value: "-3", bare: true),
            Condition(subject: "t", test: .atLeast, value: "3", bare: true, asNumber: true),
            Condition(subject: "n", test: .atMost, value: "{n}", bare: true),
            Condition(subject: "t", test: .isEmpty),
            Condition(subject: "t", test: .notEmpty),
            Condition(subject: "xs", test: .isEmpty),
            Condition(subject: "xs", test: .notEmpty),
            Condition(subject: "r", test: .succeeded),
            Condition(subject: "r", test: .failed),
            Condition(subject: "b", test: .isTrue),
            Condition(subject: "b", test: .isFalse),
            Condition(test: .exists, value: "~/x.txt"),
            Condition(test: .notExists, value: "~/{t}.txt"),
            Condition(test: .answeredYes, value: "Sure?"),
            Condition(subject: "n > 1 && b", test: .code),
        ]
        for c in cases {
            let doc = FlowDocument(blocks: vars + [block(.ifThen) { $0.condition = c; $0.children = [block(.show) { $0.text = "yes" }] }])
            _ = roundTrip(doc)
        }
    }

    func testTheExamplesOpenAsBlocksAndAreWrittenBackUnchanged() {
        for (name, source) in Examples.flows + [("new.flow", Examples.newFlow)] {
            let doc = FlowDocument.read(source)
            XCTAssertEqual(doc.written().text, source, name)
            XCTAssertEqual(doc.blocks.isEmpty, name == "new.flow", name)
        }
        XCTAssertEqual(FlowDocument.read(Examples.blocksFlow.1).blocks.map(\.type), [.runScript, .confirm, .repeatEach, .notify])
        let morning = FlowDocument.read(Examples.flows[0].1)
        XCTAssertEqual(morning.summary, "Says hello, checks the disk, and warns when it's getting full")
        XCTAssertEqual(morning.blocks.map(\.type), [.runScript, .show, .code, .show, .ifThen])
        let ifBlock = morning.blocks[4]
        XCTAssertEqual(ifBlock.condition, Condition(subject: "used", test: .greater, value: "85", bare: true))
        XCTAssertEqual(ifBlock.children.map(\.type), [.notify])
        XCTAssertEqual(ifBlock.otherwise.map(\.type), [.show])
    }

    func testChangingOneBlockLeavesTheRestAsTheyWere() {
        let source = """
        // Tidy
        let greeting = run "hello" ["friend"]   // who to greet
        print   greeting

        # a hash comment
        if greeting <> "" then
            // say it twice
            print greeting
            print   greeting
        let x = (1 + 2) * 3
        """
        var doc = FlowDocument.read(source)
        XCTAssertEqual(doc.written().text, source + "\n")
        XCTAssertEqual(doc.blocks.map(\.type), [.code, .show, .comment, .ifThen, .code])
        XCTAssertEqual(doc.blocks[3].children.map(\.type), [.comment, .show, .show])
        // Change the first Show: only its line changes.
        doc.update(doc.blocks[1].id) { $0.text = "{greeting}!" }
        let changed = doc.written().text
        XCTAssertEqual(changed, source.replacingOccurrences(of: "print   greeting\n\n", with: "print $\"{greeting}!\"\n\n") + "\n")
        // Change a block inside the If: the If is written again, its other blocks as they were.
        doc.update(doc.blocks[3].children[1].id) { $0.text = "once" }
        let again = doc.written().text
        XCTAssertTrue(again.contains("    // say it twice\n    print \"once\"\n    print   greeting\n"), again)
        XCTAssertNoThrow(try Flow.check(again, scripts: scripts))
    }

    func testCommentsInsideBlocksAreKept() {
        let doc = FlowDocument(blocks: [
            block(.repeatCount) {
                $0.number = "2"
                $0.name = "i"
                $0.children = [block(.comment) { $0.text = "first" }, block(.show) { $0.text = "{i}" }, block(.comment) { $0.text = "last" }]
            },
            block(.ifThen) {
                $0.condition = Condition(test: .answeredYes, value: "?")
                $0.children = [block(.comment) { $0.text = "only a comment" }]
                $0.hasOtherwise = true
                $0.otherwise = [block(.comment) { $0.text = "and here" }]
            },
        ])
        _ = roundTrip(doc)
    }

    func testWhatIsNotABlockIsKeptAsCodeWordForWord() {
        let sources = [
            "let rec fact n =\n    if n = 0 then 1 else n * fact (n - 1)\nprint (fact 5)\n",
            "let f = trim >> lower\nprint (f \" A \")\n",
            "run \"hello\" [] |> lines |> each (fun l ->\n    print l\n)\n",
            "let broken = (\n",
            "if true then print 1 // inline\n",
            "let xs = [\n    \"one\"\n    \"two\"\n]\nprint xs\n",
        ]
        for s in sources {
            let doc = FlowDocument.read(s)
            XCTAssertEqual(doc.written().text, s, s)
        }
        // The unreadable one is a single Code block.
        XCTAssertEqual(FlowDocument.read("let broken = (\n").blocks.map(\.type), [.code])
        // each (fun …) is a Repeat.
        XCTAssertEqual(FlowDocument.read(sources[2]).blocks.map(\.type), [.repeatEach])
    }

    func testElifIsAnIfInsideOtherwise() {
        let source = "let n = 5\nif n > 10 then\n    print \"big\"\nelif n > 3 then\n    print \"medium\"\nelse\n    print \"small\"\n"
        let doc = FlowDocument.read(source)
        XCTAssertEqual(doc.written().text, source)
        let top = doc.blocks[1]
        XCTAssertEqual(top.type, .ifThen)
        XCTAssertEqual(top.otherwise.map(\.type), [.ifThen])
        XCTAssertEqual(top.otherwise[0].otherwise.map(\.type), [.show])
        var changed = doc
        changed.update(top.otherwise[0].otherwise[0].id) { $0.text = "tiny" }
        XCTAssertNoThrow(try Flow.check(changed.written().text))
    }

    func testEachBlockKnowsItsLines() {
        let doc = FlowDocument(blocks: [
            block(.show) { $0.text = "a" },
            block(.ifThen) {
                $0.condition = Condition(test: .answeredYes, value: "?")
                $0.children = [block(.show) { $0.text = "b" }, block(.show) { $0.text = "c" }]
            },
            block(.show) { $0.text = "d" },
        ])
        let w = doc.written()
        let lines = w.text.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "print \"a\"")
        XCTAssertEqual(w.block(atLine: 1), doc.blocks[0].id)
        XCTAssertEqual(w.block(atLine: 3), doc.blocks[1].id)
        XCTAssertEqual(lines[3], "    print \"b\"")
        XCTAssertEqual(w.block(atLine: 4), doc.blocks[1].children[0].id)
        XCTAssertEqual(w.block(atLine: 5), doc.blocks[1].children[1].id)
        XCTAssertEqual(w.block(atLine: 7), doc.blocks[2].id)
        // Read from a file and not changed: the lines are the file's.
        let read = FlowDocument.read(w.text)
        let again = read.written()
        XCTAssertEqual(again.block(atLine: 4), read.blocks[1].children[0].id)
        XCTAssertEqual(again.block(atLine: 5), read.blocks[1].children[1].id)
    }

    func testMovingInsertingAndRemoving() {
        var doc = FlowDocument(blocks: [
            block(.show) { $0.text = "a" },
            block(.ifThen) { $0.condition = Condition(test: .answeredYes, value: "?") },
            block(.show) { $0.text = "c" },
        ])
        let a = doc.blocks[0].id, i = doc.blocks[1].id, c = doc.blocks[2].id
        XCTAssertTrue(doc.move(c, to: BlockSlot(parent: nil, index: 0)))
        XCTAssertEqual(doc.blocks.map(\.id), [c, a, i])
        XCTAssertTrue(doc.move(a, to: BlockSlot(parent: i, index: 0)))
        XCTAssertEqual(doc.blocks.map(\.id), [c, i])
        XCTAssertEqual(doc.block(i)?.children.map(\.id), [a])
        XCTAssertTrue(doc.move(c, to: BlockSlot(parent: i, branch: .otherwise, index: 0)))
        XCTAssertEqual(doc.block(i)?.hasOtherwise, true)
        // Not into itself.
        XCTAssertFalse(doc.move(i, to: BlockSlot(parent: i, index: 0)))
        // To where it is: nothing.
        XCTAssertFalse(doc.move(i, to: BlockSlot(parent: nil, index: 1)))
        let copy = doc.duplicate(i)
        XCTAssertNotNil(copy)
        XCTAssertEqual(doc.blocks.count, 2)
        XCTAssertNotEqual(doc.blocks[1].children.first?.id, a)
        XCTAssertEqual(doc.remove(i)?.0.children.map(\.id), [a])
        XCTAssertEqual(doc.blocks.count, 1)
    }

    func testNamesAndWhatEachStepCanUse() {
        XCTAssertEqual(FlowDocument.variableName(for: "disk-space"), "diskSpace")
        XCTAssertEqual(FlowDocument.variableName(for: "count_lines.py"), "countLines")
        XCTAssertEqual(FlowDocument.variableName(for: "2fa"), "s2fa")
        XCTAssertEqual(FlowDocument.variableName(for: "print"), "printOutput")
        XCTAssertEqual(FlowDocument.identifier("myList"), "myList")
        XCTAssertEqual(FlowDocument.identifier("my list"), "myList")
        XCTAssertEqual(FlowDocument.identifier("for"), "forOutput")
        XCTAssertEqual(FlowDocument.identifier("café"), "caf")
        var doc = FlowDocument()
        let first = doc.newBlock(.runScript, script: "hello", at: BlockSlot(parent: nil, index: 0))
        XCTAssertEqual(first.name, "hello")
        doc.insert(first, at: BlockSlot(parent: nil, index: 0))
        let second = doc.newBlock(.runScript, script: "hello", at: BlockSlot(parent: nil, index: 1))
        XCTAssertEqual(second.name, "hello2")
        doc.insert(second, at: BlockSlot(parent: nil, index: 1))
        // A Show after them shows the last one.
        XCTAssertEqual(doc.newBlock(.show, at: BlockSlot(parent: nil, index: 2)).text, "{hello2}")
        var loop = doc.newBlock(.repeatEach, at: BlockSlot(parent: nil, index: 2))
        XCTAssertEqual(loop.subject, "hello2")
        XCTAssertEqual(loop.name, "line")
        loop.children = [block(.show)]
        doc.insert(loop, at: BlockSlot(parent: nil, index: 2))
        let inside = doc.variables(before: loop.children[0].id).map(\.name)
        XCTAssertEqual(inside, ["args", "hello", "hello2", "line"])
        XCTAssertEqual(doc.variables(at: BlockSlot(parent: nil, index: 3)).map(\.name), ["args", "hello", "hello2"])
        // Renaming a step's output renames where it's used.
        doc.update(loop.id) { $0.subject = "hello" }
        doc.update(loop.children[0].id) { $0.text = "{hello} and {hello2} and \"{hello}\" and hello" }
        doc.rename("hello", to: "greeting")
        XCTAssertEqual(doc.block(loop.id)?.subject, "greeting")
        XCTAssertEqual(doc.block(loop.children[0].id)?.text, "{greeting} and {hello2} and \"{greeting}\" and hello")
    }

    func testTemplates() {
        XCTAssertEqual(Template.parts("a {b} c"), [.text("a "), .hole("b"), .text(" c")])
        XCTAssertEqual(Template.parts("{{x}}"), [.text("{x}")])
        XCTAssertEqual(Template.parts("{ \"}\" }"), [.hole("\"}\"")])
        XCTAssertEqual(Template.parts("open {"), [.text("open {")])
        XCTAssertEqual(Template.parts("{}"), [.text("{}")])
        let never: (Expr) -> Bool = { _ in false }
        XCTAssertEqual(Template.string("plain", level: 10, known: never), "\"plain\"")
        XCTAssertEqual(Template.string("a \"q\" {x}", level: 10, known: never), "$\"a \\\"q\\\" {x}\"")
        XCTAssertEqual(Template.string("{x}", level: 10, known: { _ in true }), "x")
        XCTAssertEqual(Template.string("{upper x}", level: 10, known: { _ in true }), "(upper x)")
        XCTAssertEqual(Template.string("", level: 10, known: never), "\"\"")
    }

    func testThePrinterWritesWhatTheParserReads() throws {
        let sources = [
            "f a (g b) c", "a + b * c", "(a + b) * c", "a - (b - c)", "a @ b @ c", "(a @ b) @ c",
            "x |> f", "fun x -> x + 1", "trim >> lower", "if a then b else c", "-x", "- -3", "f (-3)",
            "r.out", "(f x).ok", "[1; 2; 3]", "$\"a {b + 1} {\"c\"}\"", "not (a && b) || c", "a = b", "(fun x -> x) 1",
            "for x in xs do print x", "f (if a then b else c)",
        ]
        for s in sources {
            let e = try Template.parseExpr(s)
            let shown = try XCTUnwrap(ExprPrinter.show(e, 0), s)
            let again = try Template.parseExpr(shown)
            XCTAssertEqual(ExprPrinter.show(again, 0), shown, s)
        }
        XCTAssertEqual(ExprPrinter.show(try Template.parseExpr("x |> f |> g 1"), 0), "g 1 (f x)")
        XCTAssertEqual(ExprPrinter.show(try Template.parseExpr("a - (b - c)"), 0), "a - (b - c)")
    }

    /// Every block written fresh (nothing kept from the file) does what the file did.
    func testBlocksWrittenFreshDoWhatTheFileDid() throws {
        func forget(_ list: inout [FlowBlock]) {
            for k in list.indices {
                list[k].original = nil
                list[k].canonical = nil
                forget(&list[k].children)
                forget(&list[k].otherwise)
            }
        }
        func host() -> FakeHost {
            let h = FakeHost()
            h.scripts["hello"] = { args, _ in RunResult(code: 0, out: "Hello, \(args.first ?? "world")!\nsecond line\n", err: "", seconds: 0) }
            h.scripts["disk-space"] = FakeHost.ok("87%\n")
            h.scripts["big-files"] = FakeHost.ok("a 1\nb 2\n")
            h.scripts["count-lines"] = { _, input in RunResult(code: 0, out: "\((input ?? "").split(separator: "\n").count) lines", err: "", seconds: 0) }
            h.scripts["shout"] = { _, input in RunResult(code: 0, out: (input ?? "").uppercased(), err: "", seconds: 0) }
            h.scripts["fails"] = { _, _ in RunResult(code: 3, out: "", err: "nope", seconds: 0) }
            h.answers = [.yes, .text("Ada"), .text("large"), .no, .yes]
            return h
        }
        let corpus = Examples.flows.map(\.1) + [
            """
            let greeting = run "hello" ["you"]
            for line in lines greeting do
                print $"→ {line}"
            let r = attempt "fails" []
            if not r.ok then
                print $"failed with {r.code}: {r.err}"
            else
                print "fine"
            confirm "Go on?"
            let who = ask "Who?"
            let size = choose "Size?" ["small"; "large"]
            if askYesNo $"Send to {who}?" then
                print "sent"
            elif contains "l" size then
                print $"{who} gets {size}"
            else
                print "nothing"
            let n = run "disk-space" [] |> replace "%" "" |> int
            if n >= 80 then print "full" else print "ok"
            for i in range 1 3 do
                if i = 2 then
                    print "two"
                sleep 0
            let ok = askYesNo "Again?"
            if ok then print "again"
            """,
        ]
        for source in corpus {
            var doc = FlowDocument.read(source)
            forget(&doc.blocks)
            let fresh = doc.written().text
            let a = host(), b = host()
            try Flow.run(source, host: a)
            try Flow.run(fresh, host: b)
            XCTAssertEqual(a.said, b.said, fresh)
            XCTAssertEqual(a.notified, b.notified, fresh)
            XCTAssertEqual(a.asked.map { "\($0.kind) \($0.prompt)" }, b.asked.map { "\($0.kind) \($0.prompt)" }, fresh)
        }
    }
}
