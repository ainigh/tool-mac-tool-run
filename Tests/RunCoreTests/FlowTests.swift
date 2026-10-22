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
    /// The answers to the flow's questions, in order (none left: no one to ask).
    var answers: [FlowAnswer] = []
    var asked: [FlowQuestion] = []
    func ask(_ question: FlowQuestion) -> FlowAnswer {
        lock.lock()
        defer { lock.unlock() }
        asked.append(question)
        return answers.isEmpty ? .unavailable : answers.removeFirst()
    }
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
        // Input ends with a line break, as output does, so a script reading lines gets the last one.
        XCTAssertEqual(host.calls.last?.2, "a|3|n=3\n")
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
        let rec fact n = if n <= 1 then 1 else n * fact (n - 1)
        print (fact 10)
        let rec countdown = fun n -> if n > 0 then countdown (n - 1) else "liftoff"
        print (countdown 3)
        """, host)
        XCTAssertEqual(host.said, ["3628800", "liftoff"])
    }

    func testOnlyLetRecSeesItsOwnName() throws {
        // A plain let that uses its own name means the one above it: no recursion, no crash.
        let host = FakeHost()
        try run("""
        let f x = x + 1
        let f x = f (x * 10)
        print (f 2)
        """, host)
        XCTAssertEqual(host.said, ["21"])
        // With nothing above it, it says how to make it call itself.
        for source in ["let f n = if n = 0 then 0 else f (n - 1)", "let f = fun n -> if n = 0 then 0 else f (n - 1)"] {
            let e = checkError(source)
            XCTAssertEqual(e?.stage, .type, source)
            XCTAssertTrue(e?.fix?.contains("let rec f") == true, e?.description ?? source)
        }
        // let rec needs a function.
        XCTAssertEqual(checkError("let rec x = 5")?.stage, .syntax)
        XCTAssertEqual(try types("let rec f = fun n -> if n = 0 then 0 else f (n - 1)")["f"], "int -> int")
    }

    func testRecursionWithoutEndStopsWithAMessage() {
        // Runs out of room (or reaches the call limit) and says so, rather than crashing.
        for source in ["let rec f n = if n = 0 then 0 else 1 + f (n - 1)\nprint (f 100000000)",
                       "let rec f n = f (n + 1)\nf 0 |> ignore",
                       // On parallel's own threads too.
                       "let rec f n = 1 + f (n - 1)\nparallel [ (fun () -> f 1); (fun () -> f 2) ] |> ignore",
                       "let f x = x + 1\nlet rec f x = f (x - 0)\nprint (f 2)"] {
            XCTAssertThrowsError(try run(source), source) { e in
                let fe = e as? FlowError
                XCTAssertEqual(fe?.stage, .run)
                XCTAssertTrue(fe?.message.contains("deep") == true, fe?.message ?? "")
                XCTAssertNotNil(fe?.fix)
            }
        }
    }

    func testDeepRecursionOnABigStackReachesTheCallLimit() throws {
        // On a thread with a big stack (as the app runs flows), a function can go thousands of
        // calls deep, and the limit stops one that never ends.
        let host = FakeHost()
        var outcome: Result<Value, Error>?
        onThread(stack: 512 << 20) {
            outcome = Result { try self.run("let rec f n = if n = 0 then 0 else 1 + f (n - 1)\nprint (f 5000)\nprint (f 100000000)", host) }
        }
        XCTAssertEqual(host.said, ["5000"])
        XCTAssertThrowsError(try outcome?.get()) { e in
            XCTAssertTrue((e as? FlowError)?.message.contains("went \(Interpreter.maxCallDepth + 1) deep") == true, "\(e)")
        }
    }

    func testSmallStacksStopWithAMessage() {
        // A thread with a small stack (512 KB, as GCD and Swift's tasks give): deep nesting and
        // endless recursion are both a FlowError, never a crash.
        var errors: [FlowError?] = []
        onThread(stack: 512 << 10) {
            for source in ["let rec f n = 1 + f (n - 1)\nprint (f 1)",
                           "print " + String(repeating: "(", count: 290) + "1" + String(repeating: ")", count: 290),
                           "print (" + Array(repeating: "1", count: 290).joined(separator: " + ") + ")"] {
                do {
                    try self.run(source)
                    errors.append(nil)
                } catch {
                    errors.append(error as? FlowError)
                }
            }
        }
        XCTAssertEqual(errors.count, 3)
        XCTAssertNotNil(errors[0])
        XCTAssertEqual(errors[0]?.stage, .run)
        // The other two may fit; if they don't, they say so.
        for e in errors.dropFirst() { if let e { XCTAssertTrue(e.message.contains("deep"), e.message) } }
    }

    /// Runs `body` on a thread of its own with this much stack, and waits for it.
    func onThread(stack: Int, _ body: @escaping () -> Void) {
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            body()
            done.signal()
        }
        thread.stackSize = stack
        thread.start()
        done.wait()
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
        XCTAssertNotNil(checkError("\"x\" |> attemptPipe \"helo\" []", scripts: ["hello.sh"]))
        XCTAssertNil(checkError("\"x\" |> attemptPipe \"hello\" []", scripts: ["hello.sh"]))
    }

    func testAnErrorAtTheEndPointsAtTheLastLine() {
        XCTAssertEqual(checkError("let x =\n")?.pos?.line, 1)
        XCTAssertEqual(checkError("print 1\nprint (1 +")?.pos?.line, 2)
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
        // As the guide's table says it.
        let e = checkError("print \"a\" \"b\"")
        XCTAssertTrue(e?.message.contains("`print` is a function given one value too many") == true, e?.message ?? "")
        XCTAssertEqual(e?.pos?.col, 11)
        let e2 = checkError("replace \"a\" \"b\" \"c\" \"d\"")
        XCTAssertTrue(e2?.message.contains("it takes 3, so \"d\" is left over") == true, e2?.message ?? "")
        // A value that was never a function still says what it is.
        let e3 = checkError("let n = 5\nprint (n 3)")
        XCTAssertTrue(e3?.message.contains("is a number (int), not a function") == true, e3?.message ?? "")
    }

    func testAStepMissingValues() {
        let e = checkError("map upper [\"a\"] |> ignore\nmap upper\nprint \"x\"")
        XCTAssertEqual(e?.pos?.line, 2)
        XCTAssertTrue(e?.message.contains("`map` is missing a value: it needs 1 more") == true, e?.message ?? "")
        XCTAssertTrue(checkError("print")?.message.contains("`print` is missing a value") == true)
        XCTAssertTrue(checkError("print \"a\"\nreplace \"a\"\nprint \"b\"")?.message.contains("needs 2 more") == true)
        // A function as a block's value (the last line) is what it gives back, which is fine.
        XCTAssertNil(checkError("let tidy =\n    let t = trim\n    t >> lower\nprint (tidy \" A \")"))
        // Steps that give back a value that isn't a function are still allowed.
        XCTAssertNil(checkError("run \"x\" []\nprint \"done\""))
    }

    func testAConstrainedValueUsedAsAFunction() {
        let e = checkError("let f x = (x + x) 1")
        XCTAssertTrue(e?.message.contains("number or text") == true, e?.message ?? "")
        XCTAssertFalse(e?.message.contains("itself") == true)
    }

    func testFunctionsCantBeComparedEvenInsideLists() {
        XCTAssertTrue(checkError("print (print = print)")?.message.contains("Functions can't be compared") == true)
        XCTAssertTrue(checkError("print ([print] = [print])")?.message.contains("Functions can't be compared") == true)
        XCTAssertTrue(checkError("let fs = [upper; lower]\nprint (fs <> [])")?.message.contains("Functions can't be compared") == true)
        // A function that compares its values stays generic, for anything but functions.
        let eq = "let eq a b = a = b\n"
        XCTAssertEqual(try types(eq)["eq"], "'a -> 'a -> bool")
        let host = FakeHost()
        XCTAssertNoThrow(try run(eq + "print (eq 1 1)\nprint (eq \"a\" \"b\")\nprint (eq [[1]] [[1]])", host))
        XCTAssertEqual(host.said, ["true", "false", "true"])
        let e = checkError(eq + "eq print print |> print")
        XCTAssertTrue(e?.message.contains("functions can't be compared") == true, e?.message ?? "")
        XCTAssertNotNil(checkError(eq + "print (eq [print] [print])"))
        XCTAssertNotNil(checkError("let has x xs = xs |> filter (fun y -> y = x) |> isEmpty |> not\nprint (has upper [lower])"))
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

    func testUnclosedTextSaysTextCanSpanLines() {
        let e = checkError("print \"abc\nprint 1")
        XCTAssertEqual(e?.message, "This text is never closed.")
        XCTAssertFalse(e?.fix?.contains("same line") == true)
        XCTAssertTrue(e?.fix?.contains("several lines") == true, e?.fix ?? "")
        // And text over several lines is fine.
        let host = FakeHost()
        XCTAssertNoThrow(try run("print \"a\nb\"", host))
        XCTAssertEqual(host.said, ["a\nb"])
    }

    // MARK: numbers

    func testWholeNumbersNeverOverflowQuietlyOrCrash() throws {
        let host = FakeHost()
        try run("""
        let m = -9223372036854775808
        print m
        print (m + 1)
        print (m % -1)
        print (9223372036854775807 - 1)
        print (range 9223372036854775806 9223372036854775807)
        print (sum [9223372036854775806; 1])
        print (- -5)
        print (-2 * 3)
        """, host)
        XCTAssertEqual(host.said, ["-9223372036854775808", "-9223372036854775807", "0", "9223372036854775806",
                                   "[9223372036854775806; 9223372036854775807]", "9223372036854775807", "5", "-6"])
        let m = "let m = -9223372036854775808\n"
        for source in [m + "print (- m)", m + "print (m / -1)", m + "print (m - 1)", m + "print (m * -1)",
                       "print (9223372036854775807 + 1)", "print (4611686018427387904 * 2)",
                       "print (sum [9223372036854775807; 1])"] {
            XCTAssertThrowsError(try run(source), source) { e in
                XCTAssertEqual((e as? FlowError)?.stage, .run, source)
                XCTAssertTrue((e as? FlowError)?.message.contains("too big a number") == true, "\(e)")
            }
        }
        // range's own size check can't overflow either.
        XCTAssertThrowsError(try run(m + "print (range m 9223372036854775807)")) { e in
            XCTAssertTrue((e as? FlowError)?.message.contains("over a million") == true, "\(e)")
        }
        XCTAssertThrowsError(try run("print (5 / 0)")) { e in XCTAssertEqual((e as? FlowError)?.message, "Divided by zero.") }
    }

    func testNumberLiterals() {
        // Only 0-9 are digits.
        XCTAssertEqual(checkError("print ²")?.stage, .syntax)
        XCTAssertFalse(checkError("print ²")?.message.contains("too big") == true)
        XCTAssertEqual(checkError("print ٣")?.stage, .syntax)
        // One past the largest, without its minus, is too big; so is anything past that.
        XCTAssertTrue(checkError("print 9223372036854775808")?.message.contains("too big a number") == true)
        XCTAssertTrue(checkError("print -9223372036854775809")?.message.contains("too big a number") == true)
        XCTAssertTrue(checkError("print 99999999999999999999999")?.message.contains("too big a number") == true)
        XCTAssertNil(checkError("print 1_000_000"))
    }

    // MARK: deep nesting, caught before anything runs

    func testDeepNestingIsAMistakeNotACrash() {
        let cases = [
            "parens": "print " + String(repeating: "(", count: 1000) + "1" + String(repeating: ")", count: 1000),
            "unclosed brackets": "print " + String(repeating: "[", count: 3000),
            "minus signs": "print (" + String(repeating: "- ", count: 5000) + "1)",
            "a long sum": "print (" + Array(repeating: "1", count: 20000).joined(separator: " + ") + ")",
            "elifs": "let x = 1\nprint (if x = 0 then 0 " + (1..<3000).map { "elif x = \($0) then \($0) " }.joined() + "else 1)",
            "appends": "print (" + Array(repeating: "[1]", count: 5000).joined(separator: " @ ") + ")",
            "pipes": "print (1 " + String(repeating: "|> (fun x -> x) ", count: 5000) + ")",
            "texts in texts": "print " + String(repeating: "$\"{", count: 2000) + "1" + String(repeating: "}\"", count: 2000),
            "blocks": (0..<400).map { String(repeating: "  ", count: $0) + "let a\($0) =\n" }.joined() + String(repeating: "  ", count: 400) + "1",
            "funs": "let f = " + String(repeating: "fun x -> ", count: 3000) + "1",
        ]
        for (name, source) in cases {
            let e = checkError(source)
            XCTAssertEqual(e?.stage, .syntax, name)
            XCTAssertTrue(e?.message.contains("nested too deeply") == true, "\(name): \(e?.description ?? "no error")")
        }
        // Just under the limit is fine, checked and run.
        let host = FakeHost()
        XCTAssertNoThrow(try run("print (" + Array(repeating: "1", count: 250).joined(separator: " + ") + ")", host))
        XCTAssertNoThrow(try run("print " + String(repeating: "(", count: 250) + "1" + String(repeating: ")", count: 250), host))
        XCTAssertEqual(host.said, ["250", "1"])
    }

    func testCheckingNeverCrashesOnJumbledInput() {
        // The editor checks on every key: whatever is typed gets an answer, never a crash.
        let pieces = ["(", ")", "[", "]", "{", "}", "\"", "$\"", "\\", "-", "+", "*", "/", "%", "=", "|>", ">>", "@", ";",
                      "let ", "rec ", "fun ", "->", "if ", "then ", "elif ", "else ", "x", "f", "print", "map", "1", "0",
                      "9223372036854775808", " ", " ", "\n", "\n    ", "\r\n", "\r", ".", "out", "//", "(*", "*)", "{{", "}}"]
        var seed: UInt64 = 42
        for _ in 0..<3000 {
            var source = ""
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            for _ in 0..<Int(seed >> 58) * 4 {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                source += pieces[Int(seed >> 33) % pieces.count]
            }
            _ = try? Flow.check(source)
        }
    }

    func testTypesBuiltOnTypesAreAMistakeNotACrash() {
        // Each let doubles how deep the type goes; then, how big it is.
        let deep = "let w0 x = [x]\n" + (1..<25).map { "let w\($0) = w\($0 - 1) >> w\($0 - 1)\n" }.joined() + "print (w24 1)"
        XCTAssertTrue(checkError(deep)?.message.contains("too big to work with") == true)
        let wide = "let p0 x = fun f -> f x x\n" + (1..<30).map { "let p\($0) x = p\($0 - 1) (p\($0 - 1) x)\n" }.joined()
        XCTAssertTrue(checkError(wide)?.message.contains("too big to work with") == true)
    }

    // MARK: the text of a flow

    func testWindowsAndOldMacLineEndings() throws {
        let host = FakeHost()
        try run("// a comment\r\nlet x = 1\r\nprint x\r\n// another\rprint (x + 1)\r\nlet s = \"a\r\nb\"\r\nprint s\r\n", host)
        XCTAssertEqual(host.said, ["1", "2", "a\nb"])
        let e = checkError("let x = 1\r\nlet y = 2\r\nprnt y\r\n")
        XCTAssertEqual(e?.pos?.line, 3)
    }

    func testBracesAndQuotesInsideInterpolationHoles() throws {
        let host = FakeHost()
        try run(#"""
        let name = "n"
        print $"a {"}"} b"
        print $"{ "{" }"
        print $"{name + \"!\"}"
        print $"x{ $"{ "}" + name }" }y"
        print $"{{literal}} {name}"
        print $"{ "\"" }"
        print $"{name + "!"}"
        """#, host)
        XCTAssertEqual(host.said, ["a } b", "{", "n!", "x}ny", "{literal} n", "\"", "n!"])
        XCTAssertEqual(checkError(#"print $"{ "}" "#)?.stage, .syntax)
        XCTAssertEqual(checkError(#"print $"{ 1 "#)?.message, "A { in this text is never closed.")
    }

    func testEveryExampleChecks() throws {
        let names = Examples.allScripts.map(\.0) + Examples.flows.map(\.0) + Examples.toolFlows.map(\.0)
        for (name, source) in Examples.flows + Examples.toolFlows {
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

    // MARK: asking, and for

    func testQuestionsWaitForTheirAnswers() throws {
        let host = FakeHost()
        host.answers = [.yes, .no, .text("Ada"), .text("large")]
        try run("""
        confirm "Go on?"
        print (askYesNo "Upload?")
        let who = ask "Who?"
        let size = choose "Size?" ["small"; "large"]
        print $"{who} {size}"
        """, host)
        XCTAssertEqual(host.said, ["false", "Ada large"])
        XCTAssertEqual(host.asked.map(\.kind), [.proceed, .yesNo, .text, .choice(["small", "large"])])
        XCTAssertEqual(host.asked.map(\.line), [1, 2, 3, 4])
    }

    func testShowResultShowsAndWaitsForDone() throws {
        let host = FakeHost()
        host.answers = [.yes]
        try run("showResult \"42 files\"\nprint \"after\"", host)
        XCTAssertEqual(host.said, ["42 files", "after"])
        XCTAssertEqual(host.asked.map(\.kind), [.result])
        XCTAssertEqual(host.asked.first?.prompt, "42 files")
    }

    func testShowResultWithNoOneToShowGoesOn() throws {
        // No window to show it in (a terminal, a pretend host): it's in the output, and the flow goes on.
        let host = FakeHost()
        try run("showResult \"done\"\nprint \"after\"", host)
        XCTAssertEqual(host.said, ["done", "after"])
    }

    func testStopAtAResultStopsTheFlow() {
        let host = FakeHost()
        host.answers = [.stop]
        XCTAssertThrowsError(try run("showResult \"x\"\nprint \"after\"", host)) { e in
            XCTAssertEqual((e as? FlowError)?.stage, .stopped)
        }
        XCTAssertEqual(host.said, ["x"])
    }

    func testStopAtAQuestionStopsTheFlowThere() {
        let host = FakeHost()
        host.answers = [.stop]
        XCTAssertThrowsError(try run("confirm \"Delete it all?\"\nprint \"deleted\"", host)) { e in
            XCTAssertEqual((e as? FlowError)?.stage, .stopped)
            XCTAssertTrue((e as? FlowError)?.message.contains("Delete it all?") == true)
        }
        XCTAssertEqual(host.said, [])
    }

    func testNoOneToAskSaysHow() {
        XCTAssertThrowsError(try run("confirm \"Go?\"")) { e in
            let f = e as? FlowError
            XCTAssertEqual(f?.stage, .run)
            XCTAssertTrue(f?.fix?.contains("flow run --yes") == true)
        }
        XCTAssertThrowsError(try run("let n = ask \"Name?\"")) { e in
            XCTAssertTrue((e as? FlowError)?.fix?.contains("arguments") == true)
        }
        XCTAssertThrowsError(try run("choose \"Pick\" [] |> print")) { e in
            XCTAssertTrue((e as? FlowError)?.message.contains("empty list") == true)
        }
    }

    func testForGoesThroughEachItem() throws {
        let host = FakeHost()
        try run("""
        for n in [1; 2; 3] do
            let twice = n * 2
            print twice
        for line in lines "a\nb" do print line
        for i in range 1 2 do
            for j in range 1 2 do
                print $"{i}{j}"
        """, host)
        XCTAssertEqual(host.said, ["2", "4", "6", "a", "b", "11", "12", "21", "22"])
        XCTAssertEqual(try types("let f xs = for x in xs do print x"), ["f": "'a list -> unit"])
    }

    func testForMistakesSayHowToWriteIt() {
        XCTAssertEqual(checkError("for x [1] do print x")?.stage, .syntax)
        XCTAssertTrue(checkError("for x in [1] print x")?.message.contains("`do`") == true)
        XCTAssertTrue(checkError("for 1 in [1] do print 1")?.fix?.contains("for line in") == true)
        let e = checkError("for x in 5 do print x")
        XCTAssertEqual(e?.stage, .type)
        XCTAssertTrue(e?.message.contains("`for`") == true, e?.message ?? "")
        // `$for` isn't a name a flow can write.
        XCTAssertEqual(checkError("$for")?.stage, .syntax)
    }

    // MARK: minus signs, pipes and >>

    func testANegativeNumberStartingALineIsAnItemOfItsOwn() throws {
        let host = FakeHost()
        try run("""
        let xs = [
            1
            -2
            3
        ]
        print xs
        print 1
        -2 |> print
        let a = 5
        let b =
            a
            - 1
        print b
        """, host)
        // A minus with a space after it still carries on the line above.
        XCTAssertEqual(host.said, ["[1; -2; 3]", "1", "-2", "4"])
    }

    func testANegativeNumberCanBeGivenToAFunction() throws {
        let host = FakeHost()
        try run("""
        let twice x = x * 2
        print (twice -3)
        print (range -1 1)
        let a = 5
        print (a-1)
        print (a - 1)
        print (a - -1)
        print [1;-2]
        print (-9223372036854775808 |> string |> size)
        """, host)
        XCTAssertEqual(host.said, ["-6", "[-1; 0; 1]", "4", "4", "6", "[1; -2]", "20"])
        // n -1 gives n the number -1, as in F#; the message says how to subtract.
        let e = checkError("let n = 5\nprint (n -1)")
        XCTAssertEqual(e?.stage, .type)
        XCTAssertTrue(e?.fix?.contains("- 1") == true, e?.description ?? "")
    }

    func testAPipeWorksOutItsValueFirst() throws {
        let host = FakeHost()
        host.scripts["a"] = FakeHost.ok("a")
        host.scripts["b"] = FakeHost.ok("a")
        try run("run \"a\" [] |> replace (run \"b\" []) \"x\" |> print", host)
        XCTAssertEqual(host.calls.map(\.0), ["a", "b"])
        XCTAssertEqual(host.said, ["x"])
    }

    func testAComposedFunctionWorksOutItsPartsOnce() throws {
        let host = FakeHost()
        host.scripts["word"] = FakeHost.ok("hi")
        try run("""
        let keep = contains (run "word" []) >> not
        ["hi"; "x"; "y"] |> filter keep |> print
        let loud = trim >> upper >> (fun s -> s + "!")
        print (loud " a ")
        """, host)
        XCTAssertEqual(host.calls.map(\.0), ["word"])
        XCTAssertEqual(host.said, ["[\"x\"; \"y\"]", "A!"])
    }

    // MARK: running scripts

    func testAttemptKeepsGoingWhenTheScriptCantRun() throws {
        let host = FakeHost()
        try run("""
        let r = attempt ("no" + "pe") []
        print $"{r.ok} {r.code}"
        let p = "text" |> attemptPipe "nope" []
        print p.ok
        let e = attemptEpa ["doctor"]
        print e.ok
        """, host)
        XCTAssertEqual(host.said, ["false 127", "false", "false"])
        // A stop still stops it.
        host.scripts["stops"] = { _, _ in
            host.cancelled = true
            return RunResult(code: 0, out: "", err: "", seconds: 0)
        }
        XCTAssertThrowsError(try run("attempt \"stops\" [] |> ignore", host)) { e in
            XCTAssertEqual((e as? FlowError)?.stage, .stopped)
        }
    }

    func testInputToAScriptEndsWithALineBreak() throws {
        let host = FakeHost()
        host.scripts["cat"] = { _, input in RunResult(code: 0, out: input ?? "", err: "", seconds: 0) }
        try run("""
        "a\\nb" |> pipe "cat" [] |> ignore
        "a\\n" |> pipe "cat" [] |> ignore
        "" |> attemptPipe "cat" [] |> ignore
        """, host)
        XCTAssertEqual(host.calls.map { $0.2 }, ["a\nb\n", "a\n", ""])
    }

    func testParallelRunsEveryStepAtOnce() throws {
        // Each step waits until all of them have started: more steps than processors still
        // finish together.
        let host = FakeHost()
        let count = 3 * ProcessInfo.processInfo.activeProcessorCount + 2
        let lock = NSLock()
        var started = 0
        host.scripts["meet"] = { _, _ in
            lock.lock()
            started += 1
            lock.unlock()
            let end = Date().addingTimeInterval(10)
            while Date() < end {
                lock.lock()
                let all = started == count
                lock.unlock()
                if all { return RunResult(code: 0, out: "met", err: "", seconds: 0) }
                Thread.sleep(forTimeInterval: 0.01)
            }
            return RunResult(code: 0, out: "alone", err: "", seconds: 0)
        }
        try run("""
        let step = fun () -> run "meet" []
        parallel (range 1 \(count) |> map (fun _ -> step)) |> unique |> print
        """, host)
        XCTAssertEqual(host.said, ["[\"met\"]"])
    }

    func testAStopInAParallelStepSaysStopped() {
        let host = FakeHost()
        host.scripts["stops"] = { _, _ in
            host.cancelled = true
            return RunResult(code: 0, out: "", err: "", seconds: 0)
        }
        XCTAssertThrowsError(try run("parallel [(fun () -> fail \"boom\"); (fun () -> run \"stops\" [])] |> ignore", host)) { e in
            XCTAssertEqual((e as? FlowError)?.stage, .stopped)
        }
    }

    func testScriptNamesAreOnlyCheckedForTheBuiltins() {
        let scripts = ["hello.sh"]
        XCTAssertNil(checkError("let run name xs = name + \"!\"\nprint (run \"nope\" [])", scripts: scripts))
        XCTAssertNil(checkError("let epa words = \"x\"\nprint (epa [\"conect\"])", scripts: scripts))
        XCTAssertNotNil(checkError("print (run \"nope\" [])", scripts: scripts))
        XCTAssertNotNil(checkError("print (epa [\"conect\"])", scripts: scripts))
    }

    // MARK: builtins

    func testUniqueIsQuickAndComparesOnlyWhatCanBeCompared() throws {
        let host = FakeHost()
        try run("""
        range 1 200000 |> map (fun n -> string (n % 100000)) |> unique |> length |> print
        [[1]; [2]; [1]] |> unique |> print
        """, host)
        XCTAssertEqual(host.said, ["100000", "[[1]; [2]]"])
        let e = checkError("print (unique [print; print])")
        XCTAssertEqual(e?.stage, .type)
        XCTAssertTrue(e?.message.contains("can't be compared") == true, e?.description ?? "")
    }

    func testTextSearchesAgree() throws {
        let host = FakeHost()
        host.scripts["crlf"] = FakeHost.ok("a\r\nb\r\nc")
        try run("""
        let t = run "crlf" []
        print (contains "" "abc")
        print (startsWith "" "abc")
        print (endsWith "" "abc")
        print (contains "\\n" t)
        print (split "\\n" t |> length)
        print (startsWith "e" "é")
        """, host)
        XCTAssertEqual(host.said, ["true", "true", "true", "true", "3", "false"])
    }

    // MARK: characters

    func testByteOrderMarksAndOtherSpacesAreFine() throws {
        let host = FakeHost()
        try run("\u{FEFF}print 1\u{00A0}\nprint\u{00A0}2", host)
        XCTAssertEqual(host.said, ["1", "2"])
        let e = checkError("print\u{200B}1")
        XCTAssertEqual(e?.stage, .syntax)
        XCTAssertTrue(e?.message.contains("U+200B") == true, e?.description ?? "")
    }
}
