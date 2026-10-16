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
    /// It compares what it's given with = (`unique`), so its 'a can't be a function, as for =.
    let compares: Bool
    let body: (Interpreter, [Value], Pos) throws -> Value

    init(_ name: String, _ signature: String, _ group: String, _ summary: String, _ example: String,
         arity: Int, compares: Bool = false, _ body: @escaping (Interpreter, [Value], Pos) throws -> Value) {
        self.name = name
        self.signature = signature
        self.group = group
        self.summary = summary
        self.example = example
        self.arity = arity
        self.compares = compares
        self.body = body
    }
}

extension Builtin {
    /// Every builtin, in the order the guide lists them.
    public static let all: [Builtin] = scripts + epa + asking + text + lists + logic + system

    /// What `for x in xs do …` is made of (`each`, by a name a flow can't write or hide).
    static let forName = "$for"

    /// Builtins a flow can't name, only use through the language (`for`).
    static let hidden: [Builtin] = [
        Builtin(forName, "('a -> 'b) -> 'a list -> unit", "Lists", "for x in xs do …", "for f in files do print f", arity: 2) { i, a, pos in
            for item in a[1].items { _ = try i.apply(a[0], item, pos: pos) }
            return .unit
        },
    ]

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
            .run(try i.attempt(a[0].string, args: a[1].strings, stdin: nil, pos: pos))
        },
        Builtin("pipe", "string -> string list -> string -> string", "Scripts",
                "Runs a script with text as its input (stdin) and gives back what it printed. Made for |>: text |> pipe \"sort.py\" [].",
                "run \"list.sh\" [] |> pipe \"count-lines.py\" []", arity: 3) { i, a, pos in
            let r = try i.script(a[0].string, args: a[1].strings, stdin: Builtin.input(a[2].string), pos: pos)
            try i.requireSuccess(r, name: a[0].string, pos: pos)
            return .str(r.out)
        },
        Builtin("attemptPipe", "string -> string list -> string -> Run", "Scripts",
                "Runs a script with text as its input, like `pipe`, but keeps going when it fails: you get its result, with .out, .err, .code and .ok.",
                "let r = report |> attemptPipe \"upload.sh\" []", arity: 3) { i, a, pos in
            .run(try i.attempt(a[0].string, args: a[1].strings, stdin: Builtin.input(a[2].string), pos: pos))
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
            // A thread of its own for each step, so they all run at once however many there are
            // (they mostly wait on scripts, not the processor).
            let thunks = a[0].items
            let results = Builtin.Results(count: thunks.count)
            let group = DispatchGroup()
            for (k, thunk) in thunks.enumerated() {
                group.enter()
                let thread = Thread {
                    results.set(k, Result { try i.forked().apply(thunk, .unit, pos: pos) })
                    group.leave()
                }
                thread.stackSize = Builtin.parallelStackSize
                thread.start()
            }
            group.wait()
            return .list(try results.values())
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

    /// Room for each of `parallel`'s steps to call functions deeply (only what's used is taken).
    static let parallelStackSize = 64 << 20

    /// What `parallel`'s steps gave, filled in from their threads.
    final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [Result<Value, Error>?]

        init(count: Int) { results = Array(repeating: nil, count: count) }

        func set(_ k: Int, _ r: Result<Value, Error>) {
            lock.lock()
            results[k] = r
            lock.unlock()
        }

        /// The values in order; or, when a step failed, its error (a stop first, so a stopped
        /// flow says it was stopped).
        func values() throws -> [Value] {
            lock.lock()
            defer { lock.unlock() }
            let errors = results.compactMap { r -> Error? in
                if case let .failure(e)? = r { return e }
                return nil
            }
            if let stop = errors.first(where: { ($0 as? FlowError)?.stage == .stopped }) { throw stop }
            if let first = errors.first { throw first }
            return results.compactMap { r -> Value? in
                if case let .success(v)? = r { return v }
                return nil
            }
        }
    }

    /// Text handed to a script as its input ends with a line break, as a script's output does
    /// (`run` trims it off): a script reading line by line would miss a last line without one.
    static func input(_ text: String) -> String {
        text.isEmpty || text.hasSuffix("\n") ? text : text + "\n"
    }

    // MARK: asking

    // MARK: EPA (the kit for Cloudflare and the services around it)

    static let epa: [Builtin] = [
        Builtin("epa", "string list -> string", "EPA",
                "Runs EPA's `epa` command with these words, in your scripts folder (its keys are in .env there), and gives back what it showed. Before changing anything EPA asks, in a window here, naming what will change. If it fails, the flow stops with EPA's own sentence and its next step.",
                "epa [\"connect\"; \"resend\"; \"--domain\"; domain]", arity: 1) { i, a, pos in
            let o = try i.epa(a[0].strings, pos: pos)
            guard o.ok else {
                throw FlowError(.run, pos, "EPA: " + (o.failure ?? "epa \(a[0].strings.first ?? "") didn't finish."),
                                fix: o.next ?? "Its output above says what happened. `attemptEpa` keeps the flow going instead.")
            }
            return .str(o.text.trimmingCharacters(in: .whitespacesAndNewlines))
        },
        Builtin("attemptEpa", "string list -> Run", "EPA",
                "Runs `epa` like `epa`, but keeps going when it fails: .ok says whether it worked, .out what it showed, .err EPA's sentence for what failed and its next step.",
                "let check = attemptEpa [\"doctor\"]\nif not check.ok then notify check.err", arity: 1) { i, a, pos in
            // Keeps going whatever happens, as `attempt` does: EPA not set up is a failed result too.
            do {
                return .run(Interpreter.runValue(try i.epa(a[0].strings, pos: pos)))
            } catch let e as FlowError where e.stage != .stopped {
                return .run(RunValue(out: "", err: e.message + (e.fix.map { "\nNext: \($0)" } ?? ""), code: 127))
            }
        },
    ]

    static let asking: [Builtin] = [
        Builtin("confirm", "string -> unit", "Asking",
                "Asks before going on: Continue carries on, Stop ends the flow there (nothing after it runs). Put it before a step that deletes, sends or costs something.",
                "confirm \"Delete the old backups?\"\nrun \"clean-backups\" [] |> print", arity: 1) { i, a, pos in
            _ = try i.ask(FlowQuestion(kind: .proceed, prompt: a[0].string, line: pos.line), pos: pos)
            return .unit
        },
        Builtin("askYesNo", "string -> bool", "Asking",
                "Asks a yes-or-no question and gives back true for Yes, false for No (Stop ends the flow).",
                "if askYesNo \"Upload it too?\" then run \"upload\" [] |> print", arity: 1) { i, a, pos in
            .bool(try i.ask(FlowQuestion(kind: .yesNo, prompt: a[0].string, line: pos.line), pos: pos) == .yes)
        },
        Builtin("ask", "string -> string", "Asking",
                "Asks for a line of text and gives back what's typed (Stop ends the flow).",
                "let name = ask \"Who is it for?\"", arity: 1) { i, a, pos in
            if case let .text(t) = try i.ask(FlowQuestion(kind: .text, prompt: a[0].string, line: pos.line), pos: pos) { return .str(t) }
            return .str("")
        },
        Builtin("choose", "string -> string list -> string", "Asking",
                "Asks to pick one of a list and gives back the one picked (Stop ends the flow).",
                "let size = choose \"Which size?\" [\"small\"; \"large\"]", arity: 2) { i, a, pos in
            let options = a[1].strings
            guard !options.isEmpty else {
                throw FlowError(.run, pos, "`choose` was given an empty list, so there's nothing to pick.", fix: "Check the list with `isEmpty` first.")
            }
            if case let .text(t) = try i.ask(FlowQuestion(kind: .choice(options), prompt: a[0].string, line: pos.line), pos: pos) { return .str(t) }
            return .str(options[0])
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
            return .list(Builtin.split(a[1].string, at: sep).map { .str($0) })
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
            .bool(a[0].string.isEmpty || !Builtin.occurrences(of: a[0].string, in: a[1].string, first: true).isEmpty)
        },
        Builtin("startsWith", "string -> string -> bool", "Text", "Whether the text (second) begins with this (first).", "lines |> filter (startsWith \"ERROR\")", arity: 2) { _, a, _ in
            .bool(a[1].string.unicodeScalars.starts(with: a[0].string.unicodeScalars))
        },
        Builtin("endsWith", "string -> string -> bool", "Text", "Whether the text (second) ends with this (first).", "files |> filter (endsWith \".log\")", arity: 2) { _, a, _ in
            .bool(a[1].string.unicodeScalars.reversed().starts(with: a[0].string.unicodeScalars.reversed()))
        },
        Builtin("replace", "string -> string -> string -> string", "Text", "Replaces every `old` (first) with `new` (second) in the text (third).", "name |> replace \" \" \"-\"", arity: 3) { _, a, _ in
            .str(Builtin.split(a[2].string, at: a[0].string).joined(separator: a[1].string))
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
        Builtin("unique", "'a list -> 'a list", "Lists", "Each item once (the first time it appears).", "words |> unique", arity: 1, compares: true) { i, a, pos in
            // Numbers, text and the like are looked up in a set, so a long list takes no time;
            // lists and results are compared one by one.
            var kept: [Value] = []
            var seen = Set<Value.Key>()
            for (k, v) in a[0].items.enumerated() {
                if k % 4096 == 0 { try i.checkStop(pos) }
                if let key = v.key {
                    if seen.insert(key).inserted { kept.append(v) }
                } else if !kept.contains(where: { Value.equal($0, v) }) {
                    kept.append(v)
                }
            }
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
        Builtin("showResult", "string -> unit", "System",
                "Shows text in a window of its own (like Shortcuts' Show Result) and waits for Done; it's in the run's output too. Stop ends the flow there.",
                "showResult $\"The disk is {used}% full\"", arity: 1) { i, a, pos in
            i.host.say(a[0].string)
            try i.checkStop(pos)
            if i.host.ask(FlowQuestion(kind: .result, prompt: a[0].string, line: pos.line)) == .stop {
                throw FlowError(.stopped, pos, "Stopped: you chose Stop at the result.")
            }
            try i.checkStop(pos)
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

    /// Whether `piece` is in `text` (where `options` say): the same search `replace` and `split`
    /// do, so they all agree, and the empty text is in every text.
    // The text searches (contains, startsWith, endsWith, split, replace) go by Unicode scalar,
    // as grep and the scripts see text: "\n" is found inside a "\r\n" (one Character to Swift,
    // and to Foundation's search on a Mac), and they agree with each other on every system.

    /// Where `piece` is in `text`, left to right, not overlapping (`first`: stop at the first).
    static func occurrences(of piece: String, in text: String, first: Bool = false) -> [Range<String.Index>] {
        let s = text.unicodeScalars, p = Array(piece.unicodeScalars)
        guard !p.isEmpty else { return [] }
        var found: [Range<String.Index>] = []
        var i = s.startIndex
        while i != s.endIndex {
            var j = i, k = 0
            while k < p.count, j != s.endIndex, s[j] == p[k] {
                s.formIndex(after: &j)
                k += 1
            }
            if k == p.count {
                found.append(i..<j)
                if first { break }
                i = j
            } else {
                s.formIndex(after: &i)
            }
        }
        return found
    }

    /// The pieces of `text` between each `separator` (all of it, when there's none).
    static func split(_ text: String, at separator: String) -> [String] {
        guard !separator.isEmpty else { return [text] }
        let s = text.unicodeScalars
        var pieces: [String] = []
        var from = s.startIndex
        for r in occurrences(of: separator, in: text) {
            pieces.append(String(String.UnicodeScalarView(s[from..<r.lowerBound])))
            from = r.upperBound
        }
        pieces.append(String(String.UnicodeScalarView(s[from...])))
        return pieces
    }
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
