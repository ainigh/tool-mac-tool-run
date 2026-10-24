import Foundation

/// Straw over HTTP (`/api/straw…`): the words, the Straw scripts in the folder, checking Straw
/// code without running it, and running a Straw script, or Straw code an app sends. A run drives
/// Chrome, so it waits for Run on the Mac, as any run does (and the card shows the code in full).
extension RunAPI {
    /// One of Straw's words: what it takes, what it does, an example.
    public struct StrawWord: Sendable, Equatable {
        public let word: String
        public let takes: String
        public let does: String
        public let example: String
    }

    /// The words, from the straw.py this app writes (its WORDS table: the one list the checker,
    /// its help and the guide read).
    public static let strawWords: [StrawWord] = {
        guard let runner = Examples.browser.first(where: { $0.0 == "browser/\(Straw.runnerName)" })?.1,
              let re = try? NSRegularExpression(pattern: #"^    "([a-z]+)": +\("((?:[^"\\]|\\.)*)", "((?:[^"\\]|\\.)*)", '((?:[^'\\]|\\.)*)'\),$"#, options: .anchorsMatchLines)
        else { return [] }
        return re.matches(in: runner, range: NSRange(runner.startIndex..., in: runner)).compactMap { m in
            let part = { (k: Int) in Range(m.range(at: k), in: runner).map { String(runner[$0]).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\'", with: "'") } }
            guard let w = part(1), let t = part(2), let d = part(3), let e = part(4) else { return nil }
            return StrawWord(word: w, takes: t, does: d, example: e)
        }
    }()

    /// /api/straw, /api/straw/check, /api/straw/run.
    func strawRoute(_ req: HTTPRequest, path: String, _ s: APISettings) async throws -> HTTPResponse {
        switch path {
        case "/api/straw":
            try allowMethod(req, "GET", path)
            try need(.catalog, s)
            let c = try await catalog()
            let scripts = c.scripts.filter { $0.language == .straw }
            return JSON.response([
                "about": "Straw drives Google Chrome by what's on the page, a plain line a step (open, click \"Sign in\", type \"Search\" \"cats\", read all css \"h2\"). The Straw guide: docs/STRAW-GUIDE.md.",
                "runner": (Straw.runner(for: c.folder.appendingPathComponent("browser/x.straw"))?.path as Any?) ?? NSNull(),
                "words": Self.strawWords.map { ["word": $0.word, "takes": $0.takes, "does": $0.does, "example": $0.example] },
                "scripts": scripts.map(Self.scriptJSON),
                "check": "POST /api/straw/check {\"source\"}: its mistakes, or what it would do (nothing runs, nothing is asked)",
                "run": "POST /api/straw/run {\"script\": \"<name>\"} or {\"source\": \"<Straw code>\"}, with \"args\", \"why\", \"wait\", \"async\", \"stream\" as /api/run (waits for Run on the Mac)",
            ])
        case "/api/straw/check":
            try allowMethod(req, "POST", path)
            try need(.catalog, s)
            let fields = try body(req, plainTextAs: "source")
            guard let code = Self.text(fields["source"]) ?? Self.text(fields["code"]), !code.isEmpty else {
                throw HTTPError(status: 400, code: "missing_source", message: "send {\"source\": \"<Straw code>\"} (or the code itself, as text/plain)")
            }
            let checked = try await strawCheck(code, folder: await host.catalog()?.folder)
            return JSON.response(checked, status: 200)
        case "/api/straw/run":
            try allowMethod(req, "POST", path)
            try need(.run, s)
            return try await strawRun(req)
        default:
            throw HTTPError(status: 404, code: "not_found", message: "no such route: \(req.path) (Straw's: /api/straw, /api/straw/check, /api/straw/run)")
        }
    }

    private func allowMethod(_ req: HTTPRequest, _ method: String, _ path: String) throws {
        guard req.method == method || (method == "GET" && req.method == "HEAD") else {
            throw HTTPError(status: 405, code: "bad_request", message: "\(path) takes \(method)")
        }
    }

    /// Runs straw.py --check on the code: {"ok": true, "steps", "plan"} or {"ok": false, "code":
    /// "straw_mistake", "line", "error", "fix"}.
    func strawCheck(_ code: String, folder: URL?, name: String = "sent.straw") async throws -> [String: Any] {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("straw-check-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let file = work.appendingPathComponent(name)
        try Data(code.utf8).write(to: file)
        // The folder's straw.py, else the one this app writes (a check needs no Chrome).
        var runner = folder.flatMap { Straw.runner(for: $0.appendingPathComponent("browser/x.straw")) }
        if runner == nil, let bundled = Examples.browser.first(where: { $0.0 == "browser/\(Straw.runnerName)" })?.1 {
            let r = work.appendingPathComponent(Straw.runnerName)
            try Data(bundled.utf8).write(to: r)
            runner = r
        }
        guard let runner else { throw HTTPError(status: 500, code: "failed", message: "there's no straw.py to check it with") }
        let command = ["python3", runner.path, "--check", file.path].map(ShellEnvironment.quote).joined(separator: " ")
        let result = try await Task.detached { try ScriptProcess(shell: command, workingDirectory: work).runToEnd() }.value
        if result.code == 0 {
            let lines = result.out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let plan = lines.dropFirst().filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let steps = lines.first.flatMap { first -> Int? in
                guard let r = first.range(of: #"(\d+) steps?"#, options: .regularExpression) else { return nil }
                return Int(first[r].split(separator: " ").first ?? "")
            }
            return ["ok": true, "steps": steps ?? plan.count, "plan": plan, "message": lines.first ?? ""]
        }
        if result.code == 2 {
            let err = result.err.split(separator: "\n").map(String.init)
            var out: [String: Any] = ["ok": false, "code": "straw_mistake"]
            if let first = err.first, let r = first.range(of: #", line (\d+): "#, options: .regularExpression) {
                out["line"] = Int(first[r].filter(\.isNumber)) ?? 0
                out["error"] = String(first[r.upperBound...])
            } else {
                out["error"] = err.first ?? "it has a mistake"
            }
            if let fix = err.first(where: { $0.hasPrefix("Fix: ") }) { out["fix"] = String(fix.dropFirst(5)) }
            return out
        }
        let why = (result.err + result.out).trimmingCharacters(in: .whitespacesAndNewlines)
        throw HTTPError(status: 500, code: "failed", message: why.isEmpty ? "straw.py couldn't check it (exit \(result.code)); is python3 installed?" : why)
    }

    /// A Straw script from the folder, or Straw code sent (checked first, then kept in the browser
    /// folder's .api folder, where straw.py finds it), run as a script once Run is clicked.
    private func strawRun(_ req: HTTPRequest) async throws -> HTTPResponse {
        let fields = try body(req, plainTextAs: "source")
        let c = try await catalog()
        let straws = c.scripts.filter { $0.language == .straw }
        let item: ScriptItem
        let name: String
        var code: String?
        if let source = Self.text(fields["source"]) ?? Self.text(fields["code"]), !source.isEmpty {
            let checked = try await strawCheck(source, folder: c.folder)
            if checked["ok"] as? Bool != true { return JSON.response(checked, status: 400) }
            let browser = c.folder.appendingPathComponent("browser", isDirectory: true)
            guard Straw.runner(for: browser.appendingPathComponent("x.straw")) != nil else {
                throw HTTPError(status: 409, code: "no_runner", message: "there's no straw.py in the browser folder to run it: \(Straw.fixMissingRunner)")
            }
            let given = Self.clean(Self.text(fields["name"]) ?? "", limit: 60)
            name = given.isEmpty ? "Straw sent by \(Self.client(req, fields))" : given
            let url = try Self.keepStraw(source, name: name, in: browser)
            item = ScriptItem(url: url, language: .straw, summary: name, grid: .browser).cautioned()
            code = source
        } else if let wanted = Self.text(fields["script"]) ?? Self.text(fields["name"]), !wanted.isEmpty {
            guard let match = ScriptNames.match(wanted, in: straws.map(\.id)), let found = straws.first(where: { $0.id == match }) else {
                throw HTTPError(status: 404, code: "unknown_script",
                                message: "no Straw script named \(wanted); the Straw scripts: \(straws.isEmpty ? "(none)" : straws.map(\.id).joined(separator: ", "))")
            }
            item = found
            name = found.id
        } else {
            throw HTTPError(status: 400, code: "missing_script", message: "send {\"script\": \"<a Straw script's name>\"} (GET /api/straw lists them), or {\"source\": \"<Straw code>\"}")
        }
        let args = try Self.arguments(fields)
        let command = ScriptProcess(script: item.url, language: .straw, arguments: args, workingDirectory: c.folder, environment: [:]).commandLine
        var request = RunRequest(what: .script(item), name: name, arguments: args, client: Self.client(req, fields), from: Self.from(req),
                                 command: command, dangers: item.dangers, why: Self.why(fields))
        request.shownCode = code
        return try await execute(request, fields, via: "straw")
    }

    /// Writes Straw code sent over the API where straw.py finds it (browser/.api/, hidden from the
    /// grid); the ones kept more than a day are cleared first.
    static func keepStraw(_ code: String, name: String, in browser: URL) throws -> URL {
        let fm = FileManager.default
        let folder = browser.appendingPathComponent(".api", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        if let old = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for url in old where ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) < Date().addingTimeInterval(-86400) {
                try? fm.removeItem(at: url)
            }
        }
        let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce(into: "") { s, c in if !(c == "-" && s.hasSuffix("-")) { s.append(c) } }
        let base = String(slug.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(40))
        let url = folder.appendingPathComponent("\(base.isEmpty ? "straw" : base)-\(UUID().uuidString.prefix(8).lowercased()).straw")
        try Data(code.utf8).write(to: url)
        return url
    }
}
