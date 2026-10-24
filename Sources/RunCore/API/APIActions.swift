import Foundation

/// One thing the HTTP API can run: a script (from the folder, its utilities or its browser
/// scripts), a flow, an EPA command, or one of Flow's functions. The API board shows each as a
/// tile that runs it; `request` and `curl` are what another app sends for the same run.
public struct APIAction: Identifiable, Equatable, Sendable {
    public enum Section: String, CaseIterable, Sendable {
        case scripts = "Scripts", utilities = "Utilities", browser = "Browser", library = "Library", flows = "Flows", epa = "EPA", functions = "Functions"

        /// The group of endpoints that runs it (the panel can switch each off).
        public var endpoint: APIEndpoint {
            switch self {
            case .scripts, .utilities, .browser: .run
            case .library: .library
            case .flows, .epa, .functions: .compose
            }
        }

        /// What it holds, in a line.
        public var about: String {
            switch self {
            case .scripts: "The scripts at the top of your folder (POST /api/run)"
            case .utilities: "Small reusable helpers, in the utilities folder (POST /api/run)"
            case .browser: "Scripts that drive Chrome, in the browser folder (POST /api/run; Straw's also POST /api/straw/run)"
            case .library: "The notes in LIBRARY (in TOOL-MAC-RUN on your Desktop), by name (POST /api/library: answered at once, nothing asked)"
            case .flows: "Your flows, from the composer folder (POST /api/compose)"
            case .epa: "EPA's commands, run as one line of Flow (POST /api/compose)"
            case .functions: "Flow's own functions, each run as one line of Flow (POST /api/compose)"
            }
        }
    }

    public enum Target: Equatable, Sendable {
        /// A script, by its id (`utilities/speak.sh`).
        case script(String)
        /// A flow, by its file name.
        case flow(String)
        /// One of Flow's functions, by name, called with the answers.
        case function(String)
        /// `epa` with this command and the words answered.
        case epa(String)
    }

    /// Unique among them all: "script:utilities/speak.sh", "flow:morning.flow", "function:upper"…
    public let id: String
    public let title: String
    public let summary: String
    public let section: Section
    public let inputs: [ScriptInput]
    public let target: Target
    /// What's shown beside the title: a script's language, a function's type.
    public let badge: String?
    /// An EPA command's own symbol.
    public let symbol: String?
    /// The part of its section it's in, on the board (a utility's topic, a function's group).
    public var group: String? = nil

    /// Whether it matches what's typed in the search (every word, anywhere in its words).
    public func matches(_ search: String) -> Bool {
        let words = search.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let hay = [title, summary, id, section.rawValue, badge ?? "", group ?? ""].joined(separator: " ").lowercased()
        return words.allSatisfy { hay.contains($0) }
    }

    // MARK: running it

    /// The Flow code that runs it (a function or an EPA command), from the answers. Throws when an
    /// answer can't be what the function takes (a number that isn't one).
    public func code(answers: [String]) throws -> String? {
        switch target {
        case .script, .flow:
            return nil
        case .epa(let name):
            let words = [name] + ShellEnvironment.split(answers.first ?? "")
            return "epa [" + words.map { Template.quote($0) }.joined(separator: "; ") + "] |> ignore"
        case .function(let name):
            let types = APICatalog.parameters(of: name)
            guard !types.isEmpty else { return "print (\(name) ())" }
            var literals: [String] = []
            for (k, type) in types.enumerated() {
                let answer = k < answers.count ? answers[k] : ""
                switch type {
                case "int":
                    guard let n = Int(answer.trimmingCharacters(in: .whitespaces)) else {
                        throw FlowError(.type, nil, "\(inputs[k].prompt): \"\(answer)\" isn't a whole number.", fix: "Type a number, such as 5.")
                    }
                    literals.append(n < 0 ? "(\(n))" : "\(n)")
                case "string list":
                    let items = answer.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
                    literals.append("[" + items.map { Template.quote($0) }.joined(separator: "; ") + "]")
                default:
                    literals.append(Template.quote(answer))
                }
            }
            let call = ([name] + literals).joined(separator: " ")
            return APICatalog.returnType(of: name) == "unit" ? call : "print (\(call))"
        }
    }

    /// The request another app sends to run it with these answers: method, path and JSON body.
    public func request(answers: [String]) throws -> (method: String, path: String, body: [String: Any]) {
        let given = ScriptInput.split(inputs, answers: answers)
        switch target {
        case .script(let id):
            var body: [String: Any] = ["script": id, "args": given.arguments]
            if let stdin = given.stdin { body["stdin"] = stdin }
            return ("POST", "/api/run", body)
        case .flow(let id):
            return ("POST", "/api/compose", ["flow": id, "args": given.arguments])
        case .function(let name):
            // The library's functions are its operations: the same, answered at once.
            if let op = APICatalog.libraryOps[name] {
                var body: [String: Any] = ["op": op.op]
                for (k, field) in op.fields.enumerated() {
                    let answer = k < answers.count ? answers[k] : ""
                    body[field] = field == "limit" ? (Int(answer.trimmingCharacters(in: .whitespaces)) ?? 10) as Any : answer
                }
                return ("POST", "/api/library", body)
            }
            return ("POST", "/api/compose", ["source": try code(answers: answers) ?? "", "name": title])
        case .epa:
            return ("POST", "/api/compose", ["source": try code(answers: answers) ?? "", "name": title])
        }
    }

    /// The same, as a line to paste in a terminal (with the token, when the API takes calls from
    /// other devices).
    public func curl(answers: [String], baseURL: String, token: String? = nil) throws -> String {
        let r = try request(answers: answers)
        let data = try JSONSerialization.data(withJSONObject: r.body, options: [.sortedKeys, .withoutEscapingSlashes])
        var words = ["curl", "-s", baseURL + r.path, "-H", "Content-Type: application/json"]
        if let token, !token.isEmpty { words += ["-H", "Authorization: Bearer \(token)"] }
        words += ["-d", String(decoding: data, as: UTF8.self)]
        return words.map(ShellEnvironment.quote).joined(separator: " ")
    }
}

/// Everything the API can run, in the order the API board shows it.
public enum APICatalog {
    public static func actions(scripts: [ScriptItem], flows: [ScriptItem]) -> [APIAction] {
        var all: [APIAction] = []
        let sections: [(GridKind, APIAction.Section)] = [(.scripts, .scripts), (.utilities, .utilities), (.browser, .browser)]
        for (grid, section) in sections {
            var these: [APIAction] = []
            for s in scripts where s.grid == grid {
                these.append(APIAction(id: "script:" + s.id, title: s.title, summary: s.summary ?? "A \(s.language.title) script",
                                       section: section, inputs: s.inputs, target: .script(s.id), badge: s.language.badge, symbol: nil,
                                       group: topic(of: s)))
            }
            // A section's tiles by their topic, in the topics' order (the rest after them).
            all += these.enumerated().sorted { a, b in
                let ta = topicOrder.firstIndex(of: a.element.group ?? "") ?? topicOrder.count
                let tb = topicOrder.firstIndex(of: b.element.group ?? "") ?? topicOrder.count
                return ta != tb ? ta < tb : a.offset < b.offset
            }.map(\.element)
        }
        for b in Builtin.library where libraryOps[b.name] != nil {
            let op = libraryOps[b.name]!
            let inputs = op.prompts.map { ScriptInput(prompt: $0, kind: .argument) }
            all.append(APIAction(id: "library:" + op.op, title: op.title, summary: b.summary, section: .library,
                                 inputs: inputs, target: .function(b.name), badge: op.op, symbol: nil))
        }
        for f in flows {
            all.append(APIAction(id: "flow:" + f.id, title: f.title, summary: f.summary ?? "A flow", section: .flows,
                                 inputs: f.inputs, target: .flow(f.id), badge: "flow", symbol: nil))
        }
        for c in EPA.commands {
            let input = ScriptInput(prompt: "The words after epa \(c.name) (an example: \(c.args.isEmpty ? "none" : c.args.joined(separator: " ")))", optional: true)
            all.append(APIAction(id: "epa:" + c.title, title: c.title, summary: c.summary, section: .epa,
                                 inputs: [input], target: .epa(c.name), badge: c.changes ? nil : "read-only", symbol: c.symbol))
        }
        for b in functions where libraryOps[b.name] == nil {
            all.append(APIAction(id: "function:" + b.name, title: b.name, summary: b.summary, section: .functions,
                                 inputs: inputs(of: b.name), target: .function(b.name), badge: b.signature, symbol: nil, group: b.group))
        }
        return all
    }

    /// The library's Flow functions, each one of /api/library's operations: its op, the fields
    /// its answers go in (in order), what each answer is, and the tile's title.
    public struct LibraryOp: Sendable {
        public let op: String
        public let fields: [String]
        public let prompts: [String]
        public let title: String
    }

    public static let libraryOps: [String: LibraryOp] = [
        "libraryNames": LibraryOp(op: "names", fields: [], prompts: [], title: "Every note"),
        "libraryRecent": LibraryOp(op: "recent", fields: ["limit"], prompts: ["How many (the latest changed first)"], title: "Latest notes"),
        "libraryRead": LibraryOp(op: "read", fields: ["name"], prompts: ["The note's name (without .md)"], title: "Read a note"),
        "librarySearch": LibraryOp(op: "search", fields: ["q"], prompts: ["The words to look for (a \"phrase\" in quotes)"], title: "Search every note"),
        "libraryFind": LibraryOp(op: "find", fields: ["q"], prompts: ["The words to look for"], title: "Find notes (names only)"),
        "libraryWrite": LibraryOp(op: "write", fields: ["name", "text"], prompts: ["The note's name", "What goes in it (it replaces what's there)"], title: "Write a note"),
        "libraryAppend": LibraryOp(op: "append", fields: ["name", "text"], prompts: ["The note's name", "The line to add at its end"], title: "Add to a note"),
        "libraryRename": LibraryOp(op: "rename", fields: ["name", "to"], prompts: ["The note's name", "Its new name"], title: "Rename a note"),
        "libraryDelete": LibraryOp(op: "delete", fields: ["name"], prompts: ["The note's name (it goes to the library's Trash)"], title: "Delete a note"),
        "libraryRestore": LibraryOp(op: "restore", fields: ["name"], prompts: ["The note's name, as it was"], title: "Restore a note"),
        "libraryExists": LibraryOp(op: "exists", fields: ["name"], prompts: ["The note's name"], title: "Is it there?"),
    ]

    /// The topics a section's tiles are shown under, in order.
    public static let topicOrder = ["Library", "Finding files", "Date and time", "Looking things up", "This Mac", "Sound and speech",
                                    "Text and data", "Network and code", "Straw", "Searching sites", "Chrome", "Your own"]

    /// What a script is about, for the board: the examples' topics; a Straw script is Straw.
    public static func topic(of s: ScriptItem) -> String? {
        let name = s.title
        switch s.grid {
        case .browser:
            if s.language == .straw { return "Straw" }
            return ["site-search", "google", "youtube", "youtube-music", "maps", "translate"].contains(name) ? "Searching sites" : "Chrome"
        case .utilities:
            if s.language == .straw { return "Straw" }
            if name == "library" || name.hasPrefix("library-") { return "Library" }
            return utilityTopics.first { $0.1.contains(name) }?.0 ?? "Your own"
        case .scripts, .composer:
            return nil
        }
    }

    static let utilityTopics: [(String, Set<String>)] = [
        ("Finding files", ["find-file", "spotlight", "find-text", "file-info", "recent-downloads", "screenshots", "large-files", "find-duplicates", "open-file"]),
        ("Date and time", ["today", "now", "format-date", "days-until", "month", "stopwatch", "sunrise", "holidays", "world-clock", "timer", "alarm"]),
        ("Looking things up", ["weather", "news", "cloud-status", "wikipedia", "define", "currency", "public-ip", "site-check"]),
        ("This Mac", ["battery", "system-info", "notify", "screenshot", "volume", "lock-screen", "keep-awake", "dark-mode", "open-app", "quit-app", "front-app", "running-apps"]),
        ("Sound and speech", ["play-sound", "play-song", "speak"]),
        ("Text and data", ["clipboard", "copy-to-clipboard", "json-get", "csv-to-json", "extract-urls", "json-format", "text-case", "encode", "hash", "new-id", "pick", "password", "calc", "convert", "qr-code"]),
        ("Network and code", ["network", "speed-test", "port-check", "git-status-all"]),
    ]

    /// The functions a tile can run on its own: each takes only text, numbers or lists of text
    /// (or nothing), and isn't one of the ways to run a script or EPA (they have their own tiles).
    public static let functions: [Builtin] = Builtin.all.filter { b in
        guard !["run", "attempt", "pipe", "attemptPipe", "epa", "attemptEpa"].contains(b.name) else { return false }
        let simple: Set<String> = ["string", "int", "string list"]
        let params = parameters(of: b.name)
        let result = returnType(of: b.name)
        return params.allSatisfy(simple.contains) && !(result.contains("'") || result.contains("->"))
    }

    /// A function's parameter types, from its signature (`string -> int -> string`: string, int).
    /// Nothing for one that takes `unit`.
    static func parameters(of name: String) -> [String] {
        guard let b = Builtin.byName[name] else { return [] }
        let parts = topLevel(b.signature)
        let params = Array(parts.dropLast())
        return params == ["unit"] ? [] : params
    }

    static func returnType(of name: String) -> String {
        guard let b = Builtin.byName[name] else { return "" }
        return topLevel(b.signature).last ?? ""
    }

    /// A signature split at its top-level arrows ("(unit -> 'a) list -> 'a list": two parts).
    static func topLevel(_ signature: String) -> [String] {
        var parts: [String] = []
        var depth = 0
        var current = ""
        let chars = Array(signature)
        var k = 0
        while k < chars.count {
            let c = chars[k]
            if c == "(" { depth += 1 }
            if c == ")" { depth -= 1 }
            if depth == 0, c == "-", k + 1 < chars.count, chars[k + 1] == ">" {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                k += 2
                continue
            }
            current.append(c)
            k += 1
        }
        parts.append(current.trimmingCharacters(in: .whitespaces))
        return parts
    }

    /// What a function's tile asks for: one answer per parameter, in order.
    static func inputs(of name: String) -> [ScriptInput] {
        let params = parameters(of: name)
        let ordinals = ["First", "Second", "Third", "Fourth"]
        return params.enumerated().map { k, type in
            let what: String
            switch type {
            case "int": what = "a whole number"
            case "string list": what = "a list, one item per line"
            default: what = "text"
            }
            let prompt = params.count == 1 ? what.prefix(1).uppercased() + what.dropFirst()
                : "\(ordinals[min(k, ordinals.count - 1)]): \(what)"
            return ScriptInput(prompt: prompt, kind: type == "string list" ? .text : .argument)
        }
    }
}
