import Foundation

/// A function every flow has: its name, its type (as F# writes it), what it does, an example, and
/// how it runs. The guide and the editor's list of functions read this table: it's the one place
/// they're written.
public struct Builtin: @unchecked Sendable {
    public let name: String
    public let signature: String
    public let group: String
    public let summary: String
    public let example: String
    let arity: Int
    let body: (Interpreter, [Value], Pos) throws -> Value

    init(_ name: String, _ signature: String, _ group: String, _ summary: String, _ example: String,
         arity: Int, _ body: @escaping (Interpreter, [Value], Pos) throws -> Value) {
        self.name = name
        self.signature = signature
        self.group = group
        self.summary = summary
        self.example = example
        self.arity = arity
        self.body = body
    }
}

extension Builtin {
    /// Every builtin, in the order the guide lists them.
    public static let all: [Builtin] = scripts + text + lists + logic + system

    static let byName: [String: Builtin] = Dictionary(all.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })

    // MARK: running scripts

    static let scripts: [Builtin] = [
        Builtin("run", "string -> string list -> string", "Scripts",
                "Runs a script from your folder with these arguments and gives back what it printed (trimmed). If it fails (exit code not 0), the flow stops there and says so.",
                "let files = run \"list-files.sh\" [\"~/Desktop\"]", arity: 2) { i, a, pos in
            let r = try i.script(a[0].string, args: a[1].strings, stdin: nil, pos: pos)
            try i.requireSuccess(r, name: a[0].string, pos: pos)
            return .str(r.out)
        },
        Builtin("attempt", "string -> string list -> Run", "Scripts",
                "Runs a script like `run`, but keeps going when it fails: you get its result, with .out, .err, .code and .ok.",
                "let r = attempt \"ping.sh\" [\"example.com\"]\nif r.ok then print \"up\" else print $\"down: {r.err}\"", arity: 2) { i, a, pos in
            .run(try i.script(a[0].string, args: a[1].strings, stdin: nil, pos: pos))
        },
        Builtin("pipe", "string -> string list -> string -> string", "Scripts",
                "Runs a script with text as its input (stdin) and gives back what it printed. Made for |>: text |> pipe \"sort.py\" [].",
                "run \"list.sh\" [] |> pipe \"count-lines.py\" []", arity: 3) { i, a, pos in
            let r = try i.script(a[0].string, args: a[1].strings, stdin: a[2].string, pos: pos)
            try i.requireSuccess(r, name: a[0].string, pos: pos)
            return .str(r.out)
        },
        Builtin("sh", "string -> string", "Scripts",
                "Runs one line of shell (bash) and gives back what it printed. For small things that don't need a script of their own.",
                "let today = sh \"date +%A\"", arity: 1) { i, a, pos in
            let r = try i.shell(a[0].string, stdin: nil, pos: pos)
            try i.requireSuccess(r, name: a[0].string, pos: pos)
            return .str(r.out)
        },
        Builtin("parallel", "(unit -> 'a) list -> 'a list", "Scripts",
                "Runs several steps at the same time and waits for all of them. Each step is a `fun () -> …`. The results come back in the same order.",
                "parallel [ (fun () -> run \"a.sh\" []); (fun () -> run \"b.sh\" []) ]", arity: 1) { i, a, pos in
            let thunks = a[0].items
            var results = [Result<Value, Error>?](repeating: nil, count: thunks.count)
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: thunks.count) { k in
                let r = Result { try i.forked().apply(thunks[k], .unit, pos: pos) }
                lock.lock()
                results[k] = r
                lock.unlock()
            }
            return .list(try results.map { try $0!.get() })
        },
        Builtin("retry", "int -> (unit -> 'a) -> 'a", "Scripts",
                "Tries a step up to this many times, waiting a little longer each time, until it doesn't fail.",
                "retry 3 (fun () -> run \"upload.sh\" [file])", arity: 2) { i, a, pos in
            let times = max(1, a[0].int)
            var last: Error?
            for k in 1...times {
                do { return try i.apply(a[1], .unit, pos: pos) } catch let e as FlowError where e.stage == .stopped {
                    throw e
                } catch {
                    last = error
                    if k < times {
                        i.host.say("⚠️  Attempt \(k) of \(times) failed; trying again in \(k) s…")
                        try i.pause(seconds: Double(k))
                    }
                }
            }
            throw last!
        },
    ]

    // MARK: text

    static let text: [Builtin] = [
        Builtin("print", "'a -> unit", "Text", "Shows a value in the run's output.", "print $\"Found {count} files\"", arity: 1) { i, a, _ in
            i.host.say(a[0].text)
            return .unit
        },
        Builtin("string", "'a -> string", "Text", "Turns any value into text.", "run \"wait.sh\" [string 5]", arity: 1) { _, a, _ in .str(a[0].text) },
        Builtin("int", "string -> int", "Text", "Reads a number from text. Stops the flow if it isn't one.", "let n = run \"count.sh\" [] |> int", arity: 1) { _, a, pos in
            let s = a[0].string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let n = Int(s) else {
                throw FlowError(.run, pos, "\"\(s.prefix(60))\" isn't a whole number, so `int` can't read it.",
                                fix: "Check what the step before printed: `int` needs just the digits.")
            }
            return .int(n)
        },
        Builtin("lines", "string -> string list", "Text", "Splits text into its lines (empty lines left out).", "run \"ls.sh\" [] |> lines", arity: 1) { _, a, _ in
            .list(a[0].string.split(whereSeparator: \.isNewline).map { String($0) }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { .str($0) })
        },
        Builtin("words", "string -> string list", "Text", "Splits text at spaces and new lines.", "\"a b  c\" |> words", arity: 1) { _, a, _ in
            .list(a[0].string.split(whereSeparator: { $0 == " " || $0 == "\t" || $0.isNewline }).map { .str(String($0)) })
        },
        Builtin("split", "string -> string -> string list", "Text", "Splits text wherever the separator (first) appears.", "\"a,b,c\" |> split \",\"", arity: 2) { _, a, _ in
            let sep = a[0].string
            guard !sep.isEmpty else { return .list(a[1].string.map { .str(String($0)) }) }
            return .list(a[1].string.components(separatedBy: sep).map { .str($0) })
        },
        Builtin("join", "string -> string list -> string", "Text", "Joins a list of text with a separator (first) between them.", "[\"a\"; \"b\"] |> join \", \"", arity: 2) { _, a, _ in
            .str(a[1].strings.joined(separator: a[0].string))
        },
        Builtin("trim", "string -> string", "Text", "Takes the spaces and new lines off both ends.", "\"  hi \" |> trim", arity: 1) { _, a, _ in
            .str(a[0].string.trimmingCharacters(in: .whitespacesAndNewlines))
        },
        Builtin("upper", "string -> string", "Text", "IN CAPITALS.", "\"hello\" |> upper", arity: 1) { _, a, _ in .str(a[0].string.uppercased()) },
        Builtin("lower", "string -> string", "Text", "in small letters.", "\"HELLO\" |> lower", arity: 1) { _, a, _ in .str(a[0].string.lowercased()) },
        Builtin("contains", "string -> string -> bool", "Text", "Whether the text (second) has this piece (first) in it.", "files |> filter (contains \".swift\")", arity: 2) { _, a, _ in
            .bool(a[1].string.contains(a[0].string))
        },
        Builtin("startsWith", "string -> string -> bool", "Text", "Whether the text (second) begins with this (first).", "lines |> filter (startsWith \"ERROR\")", arity: 2) { _, a, _ in
            .bool(a[1].string.hasPrefix(a[0].string))
        },
        Builtin("endsWith", "string -> string -> bool", "Text", "Whether the text (second) ends with this (first).", "files |> filter (endsWith \".log\")", arity: 2) { _, a, _ in
            .bool(a[1].string.hasSuffix(a[0].string))
        },
        Builtin("replace", "string -> string -> string -> string", "Text", "Replaces every `old` (first) with `new` (second) in the text (third).", "name |> replace \" \" \"-\"", arity: 3) { _, a, _ in
            .str(a[2].string.replacingOccurrences(of: a[0].string, with: a[1].string))
        },
        Builtin("size", "string -> int", "Text", "How many characters the text has.", "if size name > 20 then print \"long name\"", arity: 1) { _, a, _ in .int(a[0].string.count) },
    ]

    // MARK: lists

    static let lists: [Builtin] = [
        Builtin("map", "('a -> 'b) -> 'a list -> 'b list", "Lists", "Makes a new list by applying the function to each item.", "files |> map upper", arity: 2) { i, a, pos in
            .list(try a[1].items.map { try i.apply(a[0], $0, pos: pos) })
        },
        Builtin("filter", "('a -> bool) -> 'a list -> 'a list", "Lists", "Keeps the items the test says true for.", "files |> filter (endsWith \".py\")", arity: 2) { i, a, pos in
            .list(try a[1].items.filter { try i.apply(a[0], $0, pos: pos).bool })
        },
        Builtin("each", "('a -> 'b) -> 'a list -> unit", "Lists", "Does something with each item, one after another.", "files |> each (fun f -> run \"lint.sh\" [f])", arity: 2) { i, a, pos in
            for item in a[1].items { _ = try i.apply(a[0], item, pos: pos) }
            return .unit
        },
        Builtin("fold", "('a -> 'b -> 'a) -> 'a -> 'b list -> 'a", "Lists", "Goes through the list carrying a value along: starts with the second, the function makes the next from it and each item.", "numbers |> fold (fun total n -> total + n) 0", arity: 3) { i, a, pos in
            var acc = a[1]
            for item in a[2].items { acc = try i.apply(try i.apply(a[0], acc, pos: pos), item, pos: pos) }
            return acc
        },
        Builtin("length", "'a list -> int", "Lists", "How many items the list has.", "let count = files |> length", arity: 1) { _, a, _ in .int(a[0].items.count) },
        Builtin("isEmpty", "'a list -> bool", "Lists", "Whether the list has no items.", "if isEmpty files then print \"nothing to do\"", arity: 1) { _, a, _ in .bool(a[0].items.isEmpty) },
        Builtin("first", "'a list -> 'a", "Lists", "The first item. Stops the flow if the list is empty.", "let newest = files |> first", arity: 1) { _, a, pos in
            guard let v = a[0].items.first else { throw FlowError(.run, pos, "`first` was given an empty list.", fix: "Check with `isEmpty` before taking the first item.") }
            return v
        },
        Builtin("last", "'a list -> 'a", "Lists", "The last item. Stops the flow if the list is empty.", "let oldest = files |> last", arity: 1) { _, a, pos in
            guard let v = a[0].items.last else { throw FlowError(.run, pos, "`last` was given an empty list.", fix: "Check with `isEmpty` before taking the last item.") }
            return v
        },
        Builtin("take", "int -> 'a list -> 'a list", "Lists", "The first n items (or all, if there are fewer).", "files |> take 5", arity: 2) { _, a, _ in .list(Array(a[1].items.prefix(max(0, a[0].int)))) },
        Builtin("skip", "int -> 'a list -> 'a list", "Lists", "All but the first n items.", "lines |> skip 1", arity: 2) { _, a, _ in .list(Array(a[1].items.dropFirst(max(0, a[0].int)))) },
        Builtin("sort", "'a list -> 'a list", "Lists", "Numbers smallest first, text alphabetically.", "names |> sort", arity: 1) { _, a, _ in .list(a[0].items.sorted(by: Value.less)) },
        Builtin("reverse", "'a list -> 'a list", "Lists", "The list back to front.", "names |> sort |> reverse", arity: 1) { _, a, _ in .list(a[0].items.reversed()) },
        Builtin("unique", "'a list -> 'a list", "Lists", "Each item once (the first time it appears).", "words |> unique", arity: 1) { _, a, _ in
            var kept: [Value] = []
            for v in a[0].items where !kept.contains(where: { Value.equal($0, v) }) { kept.append(v) }
            return .list(kept)
        },
        Builtin("range", "int -> int -> int list", "Lists", "The whole numbers from the first to the second, both included.", "range 1 5 |> each (fun n -> print n)", arity: 2) { _, a, pos in
            let from = a[0].int, to = a[1].int
            guard from <= to else { return .list([]) }
            // to - from can itself be too big a number (range -9223372036854775808 9223372036854775807).
            let (span, overflow) = to.subtractingReportingOverflow(from)
            guard !overflow && span < 1_000_000 else { throw FlowError(.run, pos, "range \(from) \(to) is over a million numbers.") }
            return .list((from...to).map { .int($0) })
        },
        Builtin("sum", "int list -> int", "Lists", "All the numbers added up.", "sizes |> sum", arity: 1) { _, a, pos in
            .int(try a[0].items.reduce(0) { try Interpreter.arithmetic("+", $0, $1.int, pos) })
        },
    ]

    // MARK: logic

    static let logic: [Builtin] = [
        Builtin("not", "bool -> bool", "Logic", "true becomes false, false becomes true.", "if not (exists \"out.txt\") then run \"make.sh\" [] |> ignore", arity: 1) { _, a, _ in .bool(!a[0].bool) },
        Builtin("ignore", "'a -> unit", "Logic", "Throws a value away (for a step you run only for what it does).", "run \"backup.sh\" [] |> ignore", arity: 1) { _, _, _ in .unit },
        Builtin("fail", "string -> 'a", "Logic", "Stops the flow here with this message.", "if isEmpty files then fail \"No files to upload\"", arity: 1) { _, a, pos in
            throw FlowError(.run, pos, a[0].string)
        },
    ]

    // MARK: the system

    static let system: [Builtin] = [
        Builtin("env", "string -> string", "System", "An environment variable (empty when it isn't set).", "let home = env \"HOME\"", arity: 1) { i, a, _ in
            .str(i.host.environment[a[0].string] ?? "")
        },
        Builtin("exists", "string -> bool", "System", "Whether a file or folder is there (~ is your home folder).", "if exists \"~/Desktop/report.pdf\" then print \"ready\"", arity: 1) { _, a, _ in
            .bool(FileManager.default.fileExists(atPath: Builtin.expand(a[0].string)))
        },
        Builtin("read", "string -> string", "System", "What's in a text file.", "let notes = read \"~/notes.txt\"", arity: 1) { _, a, pos in
            let path = Builtin.expand(a[0].string)
            guard let s = try? String(contentsOfFile: path, encoding: .utf8) else {
                throw FlowError(.run, pos, "Couldn't read \(a[0].string).", fix: "Check the file is there and is text.")
            }
            return .str(s)
        },
        Builtin("write", "string -> string -> unit", "System", "Writes text into a file (first: where), replacing what was in it.", "write \"~/Desktop/report.txt\" summary", arity: 2) { i, a, pos in
            let path = Builtin.expand(a[0].string)
            do {
                try a[1].string.write(toFile: path, atomically: true, encoding: .utf8)
            } catch {
                throw FlowError(.run, pos, "Couldn't write \(a[0].string): \(error.localizedDescription)")
            }
            i.host.say("✅ Wrote \(a[0].string)")
            return .unit
        },
        Builtin("notify", "string -> unit", "System", "Shows a notification on the screen.", "notify \"Backup finished\"", arity: 1) { i, a, _ in
            i.host.notify(a[0].string)
            return .unit
        },
        Builtin("sleep", "int -> unit", "System", "Waits this many seconds.", "sleep 2", arity: 1) { i, a, _ in
            try i.pause(seconds: Double(max(0, a[0].int)))
            return .unit
        },
        Builtin("now", "unit -> string", "System", "The date and time now, as 2026-10-12 14:03:05.", "print $\"Started {now ()}\"", arity: 1) { _, _, _ in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return .str(f.string(from: Date()))
        },
    ]

    static func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }
}

/// Names every flow has that aren't functions.
enum Globals {
    /// `args`: what the flow was run with (`flow run x.flow a b`, or the cell's arguments).
    static let names: [(name: String, type: FType, doc: String)] = [
        ("args", .list(.string), "the arguments the flow was run with"),
    ]
}

extension Value {
    // The checker has made sure of the types; these read them.
    var string: String {
        if case let .str(s) = self { return s }
        return text
    }
    var int: Int {
        if case let .int(n) = self { return n }
        return 0
    }
    var bool: Bool {
        if case let .bool(b) = self { return b }
        return false
    }
    var items: [Value] {
        if case let .list(l) = self { return l }
        return []
    }
    var strings: [String] { items.map(\.string) }
}
