import Foundation

/// Showing something to the person, and putting text on their clipboard: `POST /api/present`
/// opens a window in front of everything (a file from a shelf, a node of the mind, or any text),
/// with copy buttons; `POST /api/clipboard` copies. Neither asks first: they change nothing but
/// what's on screen and on the clipboard. Any other answer can do the same with "present": true
/// or "copy": true.
extension RunAPI {
    func screenRoute(_ req: HTTPRequest, path: String, _ s: APISettings) async throws -> HTTPResponse {
        guard s.isOn(.screen) else {
            throw HTTPError(status: 503, code: "endpoint_off", message: "\(APIEndpoint.screen.title.lowercased()) is turned off in Tool Mac Tool Run")
        }
        let present = path == "/api/present"
        if req.method == "GET" || req.method == "HEAD" {
            return JSON.response(present ? [
                "ok": true,
                "what": "POST /api/present shows something on the Mac, in a window in front of everything, with copy buttons (the whole, each section, each code block)",
                "fields": [
                    "shelf + name": "a file: {\"shelf\": \"memory\", \"name\": \"PEOPLE\"} (library, memory, system-docs)",
                    "mind": "a node of the mind, all that's known about it: {\"mind\": \"ada lovelace\"}; {\"mind\": \"\"} the whole mind, one line a fact",
                    "text": "any text: {\"title\": \"Steps\", \"text\": \"…\", \"format\": \"markdown|text|json\"}",
                    "copy": "true: put it on the clipboard too",
                    "why": "a line on why it's shown (the window says it)",
                ],
                "also": "add \"present\": true to any library, memory, system-docs, mind or browser call to show its answer",
            ] as [String: Any] : [
                "ok": true,
                "what": "POST /api/clipboard puts text on the Mac's clipboard",
                "fields": [
                    "text": "{\"text\": \"…\"}",
                    "shelf + name": "a file's text: {\"shelf\": \"library\", \"name\": \"groceries\"}",
                    "mind": "what the mind knows about a node, as lines: {\"mind\": \"ada lovelace\"}",
                ],
                "also": "add \"copy\": true to any library, memory, system-docs, mind or browser call to copy its answer",
                "reading": "the clipboard isn't read over the API",
            ] as [String: Any])
        }
        guard req.method == "POST" else { throw HTTPError(status: 405, code: "bad_request", message: "\(path) takes POST (GET says what it takes)") }
        let fields = try self.fields(req)
        let f = LibraryAPI.Fields(values: fields)
        let client = Self.client(req, fields)
        let op = present ? "present" : "copy"
        return await logged(present ? "present" : "clipboard", op, f, req) {
            var p = try self.presentation(f, client: client)
            if present {
                try await self.host.present(p)
                var out: [String: Any] = ["shown": true, "title": p.title, "chars": p.text.count, "format": p.format.rawValue]
                if let source = p.source { out["source"] = source }
                if let name = p.name { out["name"] = name }
                if f.bool("copy") == true {
                    try await self.host.copy(p.text)
                    out["copied"] = true
                }
                return .json(out, summary: "showed \(p.title)")
            }
            p.title = p.title.isEmpty ? "text" : p.title
            try await self.host.copy(p.text)
            var out: [String: Any] = ["copied": true, "chars": p.text.count, "title": p.title]
            if let source = p.source { out["source"] = source }
            return .json(out, summary: "copied \(p.text.count) characters")
        }
    }

    /// What's asked to be shown (or copied): a file, a node of the mind, the mind, or text.
    func presentation(_ f: LibraryAPI.Fields, client: String) throws -> Presentation {
        let why = Self.why(f.values)
        if let shelfWord = f.text("shelf") ?? f.text("library") ?? f.text("from") {
            guard let shelf = Shelf(word: shelfWord) else {
                throw HTTPError(status: 400, code: "unknown_shelf", message: "there's no shelf called \(shelfWord); the shelves: \(Shelf.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            guard let name = f.text("name") ?? f.text("file") else {
                throw HTTPError(status: 400, code: "bad_request", message: "say which file: \"name\" (its name without .md)")
            }
            let lib = files(shelf)
            let r = try lib.read(name)
            return Presentation(title: r.note.title.map { $0 == r.note.name ? r.note.name : "\(r.note.name) — \($0)" } ?? r.note.name, text: r.text, format: .markdown,
                                source: "\(shelf.folderName)/\(r.note.url.lastPathComponent)", shelf: shelf, name: r.note.name, client: client, why: why)
        }
        if f.values.keys.contains("mind") {
            let memory = shelves().memory
            let g = memory.mind.graph()
            let wanted = f.text("mind") ?? ""
            if wanted.trimmingCharacters(in: .whitespaces).isEmpty || wanted == "true" {
                return Presentation(title: "The mind", text: g.canonical, format: .mind, source: "MIND/\(MindStore.logName), in its shortest form", client: client, why: why)
            }
            guard let id = MindQuery.lookup(wanted, in: g).first, let a = MindQuery.about(id, in: g) else {
                throw MindError(.notFound, "There's no node called \(wanted) in the mind.", fix: "GET /api/mind/find?q=\(wanted) finds the near ones.")
            }
            var md = "# \(id.description)\n\n"
            if !a.notes.isEmpty { md += a.notes.map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
            if !a.links.isEmpty {
                md += "## Linked\n\n" + a.links.map { l in
                    let arrow = l.direction == "out" ? "→" : l.direction == "in" ? "←" : l.direction == "both" ? "⇄" : "—"
                    return "- \(arrow) **\(l.node.description)**" + (l.labels.isEmpty ? "" : " (\(l.labels.joined(separator: ", ")))") + (l.notes.isEmpty ? "" : " · " + l.notes.joined(separator: " · "))
                }.joined(separator: "\n") + "\n\n"
            }
            md += "## In the notation\n\n```mm\n" + a.lines.joined(separator: "\n") + "\n```\n"
            if id.isRoot, let text = try? memory.files.read(id.name).text {
                md += "\n## MEMORY/\(id.name).md\n\n" + text
            }
            return Presentation(title: id.description, text: md, format: .markdown, source: "the mind", shelf: id.isRoot && memory.files.exists(id.name) ? .memory : nil,
                                name: id.isRoot && memory.files.exists(id.name) ? id.name : nil, client: client, why: why)
        }
        guard let text = f.text("text") ?? f.text("content") ?? f.text("result") else {
            throw HTTPError(status: 400, code: "bad_request", message: "say what: {\"text\": \"…\"}, a file ({\"shelf\": \"memory\", \"name\": \"PEOPLE\"}) or a node ({\"mind\": \"ada lovelace\"})")
        }
        let format = try f.choice("format", Presentation.Format.allCases.map(\.rawValue)).flatMap(Presentation.Format.init(rawValue:)) ?? .markdown
        var shown = text
        if format == .json, let data = text.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            shown = String(decoding: pretty, as: UTF8.self)
        }
        return Presentation(title: f.text("title").map { Self.clean($0, limit: 120) } ?? "From \(client)", text: shown, format: format, source: f.text("source").map { Self.clean($0, limit: 120) },
                            client: client, why: why)
    }
}
