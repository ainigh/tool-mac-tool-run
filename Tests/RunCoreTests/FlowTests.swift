import Foundation
@testable import RunCore
import XCTest

/// A pretend world for flows: scripts are Swift closures, output is collected.
final class FakeHost: FlowHost, @unchecked Sendable {
    var scripts: [String: ([String], String?) -> RunResult] = [:]
    var said: [String] = []
    var notified: [String] = []
    var calls: [(String, [String], String?)] = []
    var cancelled = false
    private let lock = NSLock()

    func runScript(_ name: String, args: [String], stdin: String?, pos: Pos) throws -> RunResult {
        lock.lock()
        calls.append((name, args, stdin))
        let script = scripts[name]
        lock.unlock()
        guard let script else { throw FlowError(.run, pos, "no script \(name)") }
        return script(args, stdin)
    }

    func runShell(_ command: String, stdin: String?, pos: Pos) throws -> RunResult {
        RunResult(code: 0, out: "shell:\(command)\n", err: "", seconds: 0)
    }

    func say(_ text: String) {
        lock.lock()
        said.append(text)
        lock.unlock()
    }

    func notify(_ text: String) { notified.append(text) }
    var environment: [String: String] { ["HOME": "/home/me"] }
    var isCancelled: Bool { cancelled }

    static func ok(_ out: String) -> ([String], String?) -> RunResult {
        { _, _ in RunResult(code: 0, out: out, err: "", seconds: 0) }
    }
}

final class FlowTests: XCTestCase {
    @discardableResult
    func run(_ source: String, _ host: FakeHost = FakeHost(), args: [String] = []) throws -> Value {
        try Flow.run(source, host: host, args: args)
    }

    func types(_ source: String) throws -> [String: String] {
        Dictionary(try Flow.check(source).bindings.map { ($0.name, $0.type) }, uniquingKeysWith: { _, b in b })
    }

    func checkError(_ source: String, scripts: [String]? = nil) -> FlowError? {
        do {
            _ = try Flow.check(source, scripts: scripts)
            return nil
        } catch let e as FlowError {
            return e
        } catch {
            return nil
        }
    }

    // MARK: inference

    func testInfersSimpleTypes() throws {
        let t = try types("""
        let n = 1 + 2
        let s = "a" + "b"
        let b = n > 2
        let xs = [1; 2; 3]
        let r = attempt "x" []
        """)
        XCTAssertEqual(t["n"], "int")
        XCTAssertEqual(t["s"], "string")
        XCTAssertEqual(t["b"], "bool")
        XCTAssertEqual(t["xs"], "int list")
        XCTAssertEqual(t["r"], "Run")
    }

    func testInfersFunctionsAndGenerics() throws {
        let t = try types("""
        let shout s = upper s + "!"
        let twice f x = f (f x)
        let id x = x
        let add a b = a + b
        let firstOr d xs = if isEmpty xs then d else first xs
        """)
        XCTAssertEqual(t["shout"], "string -> string")
        XCTAssertEqual(t["twice"], "('a -> 'a) -> 'a -> 'a")
        XCTAssertEqual(t["id"], "'a -> 'a")
        // An unpinned + is on numbers, as in F#.
        XCTAssertEqual(t["add"], "int -> int -> int")
        XCTAssertEqual(t["firstOr"], "'a -> 'a list -> 'a")
    }

    func testGenericFunctionUsedAtTwoTypes() throws {
        let host = FakeHost()
        try run("""
        let id x = x
        print (id 3)
        print (id "three")
        """, host)
        XCTAssertEqual(host.said, ["3", "three"])
    }

    func testPipelinesAndComposition() throws {
        let host = FakeHost()
        host.scripts["list.sh"] = FakeHost.ok("b.swift\na.txt\nc.swift\n")
        try run("""
        let swiftFiles =
            run "list.sh" []
            |> lines
            |> filter (endsWith ".swift")
            |> sort
        swiftFiles |> join ", " |> print
        let loud = trim >> upper
        print (loud "  hi ")
        """, host)
        XCTAssertEqual(host.said, ["b.swift, c.swift", "HI"])
    }

    func testArgumentsAndStdinReachScripts() throws {
        let host = FakeHost()
        host.scripts["echo.sh"] = { args, _ in RunResult(code: 0, out: args.joined(separator: "|"), err: "", seconds: 0) }
        host.scripts["upper.py"] = { _, input in RunResult(code: 0, out: (input ?? "").uppercased(), err: "", seconds: 0) }
        try run("""
        let n = 3
        let out = run "echo.sh" ["a"; string n; $"n={n}"]
        out |> pipe "upper.py" [] |> print
        """, host)
        XCTAssertEqual(host.said, ["A|3|N=3"])
        XCTAssertEqual(host.calls.last?.2, "a|3|n=3")
    }

    func testRunStopsOnFailureAttemptKeepsGoing() throws {
        let host = FakeHost()
        host.scripts["bad.sh"] = { _, _ in RunResult(code: 2, out: "", err: "boom\n", seconds: 0) }
        try run("""
        let r = attempt "bad.sh" []
        print $"{r.ok} {r.code} {r.err}"
        """, host)
        XCTAssertEqual(host.said, ["false 2 boom"])
        XCTAssertThrowsError(try run("run \"bad.sh\" [] |> print", host)) { e in
            let fe = e as? FlowError
            XCTAssertEqual(fe?.stage, .run)
            XCTAssertEqual(fe?.pos?.line, 1)
            XCTAssertTrue(fe?.message.contains("exit code 2") == true)
            XCTAssertTrue(fe?.fix?.contains("attempt") == true)
        }
    }

    func testIfElifElseAndBlocks() throws {
        let host = FakeHost()
        try run("""
        let grade n =
            if n > 90 then "A"
            elif n > 80 then "B"
            else
                let low = "C"
                low
        [95; 85; 10] |> map grade |> join "" |> print
        if true then
            print "one"
            print "two"
        """, host)
        XCTAssertEqual(host.said, ["ABC", "one", "two"])
    }

    func testMultiLineLambdaInsideParens() throws {
        let host = FakeHost()
        try run("""
        [1; 2] |> each (fun n ->
            let doubled = n * 2
            print doubled)
        print "done"
        """, host)
        XCTAssertEqual(host.said, ["2", "4", "done"])
    }

    func testRecursion() throws {
        let host = FakeHost()
        try run("""
        let fact n = if n <= 1 then 1 else n * fact (n - 1)
        print (fact 10)
        """, host)
        XCTAssertEqual(host.said, ["3628800"])
    }

    func testFoldRangeSumAndLists() throws {
        let host = FakeHost()
        try run("""
        let total = range 1 4 |> fold (fun acc n -> acc + n) 0
        print total
        print (sum [1; 2; 3])
        print ([1; 2] @ [3])
        print (["b"; "a"; "b"] |> unique |> sort)
        print (length (take 2 [1; 2; 3]))
        """, host)
        XCTAssertEqual(host.said, ["10", "6", "[1; 2; 3]", "[\"a\"; \"b\"]", "2"])
    }

    func testListOnSeparateLines() throws {
        let host = FakeHost()
        try run("""
        let xs = [
            "one"
            "two"
        ]
        print (length xs)
        """, host)
        XCTAssertEqual(host.said, ["2"])
    }

    func testParallelKeepsOrder() throws {
        let host = FakeHost()
        host.scripts["a"] = FakeHost.ok("A")
        host.scripts["b"] = FakeHost.ok("B")
        try run("""
        parallel [ (fun () -> run "a" []); (fun () -> run "b" []) ] |> join "" |> print
        """, host)
        XCTAssertEqual(host.said, ["AB"])
    }

    func testRetry() throws {
        let host = FakeHost()
        var tries = 0
        host.scripts["flaky"] = { _, _ in
            tries += 1
            return RunResult(code: tries < 2 ? 1 : 0, out: "ok", err: "", seconds: 0)
        }
        try run("retry 3 (fun () -> run \"flaky\" []) |> print", host)
        XCTAssertEqual(tries, 2)
        XCTAssertEqual(host.said.last, "ok")
    }

    func testArgsAndShell() throws {
        let host = FakeHost()
        try run("""
        print (args |> join "+")
        print (sh "date")
        print (env "HOME")
        """, host, args: ["x", "y"])
        XCTAssertEqual(host.said, ["x+y", "shell:date", "/home/me"])
    }

    func testStopsWhenCancelled() {
        let host = FakeHost()
        host.cancelled = true
        XCTAssertThrowsError(try run("print 1", host)) { e in
            XCTAssertEqual((e as? FlowError)?.stage, .stopped)
        }
        XCTAssertTrue(host.said.isEmpty)
    }

    func testComments() throws {
        let host = FakeHost()
        try run("""
        #!/usr/bin/env flow
        // a comment
        (* a comment
           over lines *)
        print "x" // trailing
        """, host)
        XCTAssertEqual(host.said, ["x"])
    }

    // MARK: mistakes, caught before anything runs

    func testIntWhereTextIsNeeded() {
        let e = checkError("let n = 5\nrun \"x\" [n]")
        XCTAssertEqual(e?.stage, .type)
        XCTAssertEqual(e?.pos?.line, 2)
        XCTAssertTrue(e?.message.contains("needs") == true, e?.message ?? "")
        XCTAssertTrue(e?.fix?.contains("string") == true, e?.fix ?? "")
    }

    func testUnknownNameSuggestsNearest() {
        let e = checkError("prnt \"hi\"")
        XCTAssertEqual(e?.message, "I don't know `prnt`.")
        XCTAssertEqual(e?.fix, "Did you mean `print`?")
    }

    func testUnknownScript() {
        let e = checkError("run \"helo\" []", scripts: ["hello.sh", "other.py"])
        XCTAssertTrue(e?.message.contains("no script called \"helo\"") == true)
        XCTAssertTrue(e?.fix?.contains("hello.sh") == true)
        XCTAssertNil(checkError("run \"hello\" []", scripts: ["hello.sh"]))
        XCTAssertNil(checkError("run \"hello.sh\" []", scripts: ["hello.sh"]))
    }

    func testIfBranchesMustAgree() {
        let e = checkError("let x = if true then 1 else \"one\"")
        XCTAssertTrue(e?.message.contains("Both sides of an `if`") == true, e?.message ?? "")
    }

    func testIfWithoutElseMustDoSomething() {
        let e = checkError("let x = if true then 1")
        XCTAssertTrue(e?.message.contains("without `else`") == true, e?.message ?? "")
    }

    func testTooManyArguments() {
        let e = checkError("print \"a\" \"b\"")
        XCTAssertTrue(e?.message.contains("not a function") == true, e?.message ?? "")
    }

    func testFieldOnlyOnRun() {
        let e = checkError("let r = run \"x\" []\nprint r.out")
        XCTAssertTrue(e?.message.contains("Only a script's result") == true, e?.message ?? "")
    }

    func testMixedList() {
        let e = checkError("let xs = [1; \"two\"]")
        XCTAssertTrue(e?.message.contains("same type") == true, e?.message ?? "")
    }

    func testAddingBools() {
        let e = checkError("let x = true + false")
        XCTAssertTrue(e?.message.contains("+ adds numbers or joins text") == true, e?.message ?? "")
    }

    func testSyntaxErrors() {
        XCTAssertEqual(checkError("let = 5")?.stage, .syntax)
        XCTAssertEqual(checkError("print \"open")?.stage, .syntax)
        XCTAssertEqual(checkError("let x = (1 + 2")?.stage, .syntax)
        XCTAssertEqual(checkError("if true print 1")?.stage, .syntax)
        let e = checkError("print 1\n    print 2")
        XCTAssertNotNil(e)
    }

    func testEveryExampleChecks() throws {
        let names = Examples.scripts.map(\.0) + Examples.flows.map(\.0)
        for (name, source) in Examples.flows {
            XCTAssertNoThrow(try Flow.check(source, scripts: names), name)
        }
        XCTAssertNoThrow(try Flow.check(Examples.newFlow, scripts: names))
    }

    func testEveryBuiltinSignatureReads() throws {
        // Each signature reads back as written (the guide and the checker agree).
        for b in Builtin.all {
            var next = 0
            var vars: [String: FType] = [:]
            let t = SignatureReader.read(b.signature) { name in
                if let v = vars[name] { return v }
                next += 1
                let v = FType.v(TVar(id: next, level: 0))
                vars[name] = v
                return v
            }
            XCTAssertEqual(TypePrinter.show(t), b.signature, b.name)
        }
    }

    func testEveryBuiltinExampleParses() throws {
        for b in Builtin.all {
            XCTAssertNoThrow(try Parser.parse(b.example), b.name)
        }
    }
}
