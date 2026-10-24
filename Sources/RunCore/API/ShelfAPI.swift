import Foundation

/// MEMORY, the mind and SYSTEM-DOCS, as the API finds them (in TOOL-MAC-RUN, unless a test says
/// otherwise), and where the app keeps the docs it ships with.
public struct Shelves: Sendable {
    public var memory: Memory
    public var systemDocs: FileLibrary
    /// The app's own SYSTEM-DOCS (in its Resources), installed when the folder isn't there yet.
    public var shipped: URL?

    public init(memory: Memory = Memory(), systemDocs: FileLibrary = FileLibrary(shelf: .systemDocs), shipped: URL? = nil) {
        self.memory = memory
        self.systemDocs = systemDocs
        self.shipped = shipped
    }

    public var mind: MindStore { memory.mind }
}

/// MEMORY's own operations, beside the library's (which it has too: it's a library).
public enum MemoryAPI {
    public static let operations: [LibraryAPI.Operation] = [
        .init(name: "remember", summary: "remembers something: a line in a file (PEOPLE…) and, in the mind, the file linked to what it's about, with links and notes",
              fields: ["category: PEOPLE|ORGANIZATIONS|…", "about: the name", "text?", "links?: [{label?, to, category?}]", "notes?: [\"birthday 03-14\"]"], route: "POST /api/memory/remember", changes: true),
        .init(name: "recall", summary: "what's known about a name: its node in the mind (links, notes), the files it's filed under, the lines that mention it",
              fields: ["name"], route: "GET /api/memory/recall?name=…", changes: false),
        .init(name: "categories", summary: "every file, whether it's one MEMORY comes with, and how many things the mind files under it", fields: [], route: "GET /api/memory/categories", changes: false),
        .init(name: "members", summary: "what the mind files under a category (PEOPLE: the people)", fields: ["name"], route: "GET /api/memory/categories/{name}/members", changes: false),
        .init(name: "upcoming", summary: "the days coming up: dated notes in the mind, and lines in EVENT-DATES, BIRTHDAYS (any file) that start with a day",
              fields: ["days?: 30"], route: "GET /api/memory/upcoming", changes: false),
        .init(name: "sync", summary: "makes each file a node of the mind (the ones that aren't yet)", fields: [], route: "POST /api/memory/sync", changes: true),
        .init(name: "defaults", summary: "puts back any of the files MEMORY comes with that isn't there", fields: [], route: "POST /api/memory/defaults", changes: true),
    ]

    static let byName: [String: LibraryAPI.Operation] = Dictionary(uniqueKeysWithValues: operations.map { ($0.name, $0) })

    static func perform(_ op: String, _ f: LibraryAPI.Fields, memory: Memory, client: String) throws -> [String: Any] {
        switch op {
        case "remember":
            guard let category = f.text("category") ?? f.text("file") ?? f.text("in") else {
                throw MindError(.badRequest, "remember takes \"category\": the file it goes in (\(Memory.defaultNames.joined(separator: ", "))).")
            }
            guard let about = f.text("about") ?? f.text("name") ?? f.text("node") else {
                throw MindError(.badRequest, "remember takes \"about\": who or what it's about (\"Ada Lovelace\").")
            }
            var links: [(label: String?, to: String, category: String?)] = []
            for l in (f.values["links"] as? [Any]) ?? [] {
                if let d = l as? [String: Any], let to = RunAPI.text(d["to"]) {
                    links.append((RunAPI.text(d["label"]), to, RunAPI.text(d["category"])))
                } else if let to = RunAPI.text(l) {
                    links.append((nil, to, nil))
                }
            }
            let r = try memory.remember(category: category, about: about, text: f.text("text"), links: links, notes: f.list("notes") ?? f.list("note") ?? [], who: client)
            return ["name": r.file, "file": r.file, "node": r.node, "added_to_file": r.text, "added_to_mind": r.mind]
        case "recall":
            let name = try f.name()
            let r = memory.recall(name)
            let files = Set(memory.files.names())
            return ["name": name, "found": !r.nodes.isEmpty || !r.mentions.isEmpty, "nodes": r.nodes.map { MindAPI.nodeJSON($0, files: files) },
                    "about": r.about.map { MindAPI.aboutJSON($0, files: files) }, "categories": r.categories,
                    "mentions": r.mentions.map(LibraryAPI.hitJSON),
                    "lines": r.about.flatMap(\.lines) + r.mentions.flatMap { h in h.lines.map { "\(h.note.name), line \($0.number): \($0.text)" } }]
        case "categories":
            return ["categories": memory.files.list().map { n -> [String: Any] in
                ["name": n.name, "default": Memory.isDefault(n.name), "members": memory.members(of: n.name).count, "size": n.size, "modified": JSON.date(n.modified)]
            }]
        case "members":
            let name = try f.name()
            guard let file = memory.files.find(name) else {
                throw LibraryError(.notFound, "There's no memory file called \(name).", fix: "The files: " + memory.files.names().joined(separator: ", "))
            }
            let ids = memory.members(of: file.name)
            return ["name": file.name, "count": ids.count, "members": ids.map(\.description)]
        case "upcoming":
            let days = max(0, min(3660, f.int("days") ?? 30))
            let list = memory.upcoming(days: days)
            return ["days": days, "count": list.count, "upcoming": list.map { ["day": JSON.day($0.day), "in_days": $0.days, "what": $0.what, "source": $0.source, "yearly": $0.yearly] as [String: Any] },
                    "lines": list.map { "\(JSON.day($0.day)) (in \($0.days) day\($0.days == 1 ? "" : "s")): \($0.what) — \($0.source)" }]
        case "sync":
            let added = try memory.mind.index(memory.files, who: client)
            return ["added_to_mind": added, "count": added.count]
        case "defaults":
            let added = try memory.addDefaults()
            return ["added": added, "count": added.count]
        default:
            throw LibraryError(.badName, "There's no memory operation called \(op).")
        }
    }
}

extension JSON {
    /// A day, as 2026-11-03.
    static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}

extension RunAPI {
    // MARK: the shelves

    /// The shelf's files, made ready when they aren't there yet: MEMORY with its files (and the
    /// mind), SYSTEM-DOCS from what the app ships with.
    func files(_ shelf: Shelf) -> FileLibrary {
        switch shelf {
        case .library: return library()
        case .memory:
            let m = shelves().memory
            if !m.folderExists || !m.mind.exists { _ = try? m.ensure() }
            return m.files
        case .systemDocs:
            let sh = shelves()
            if !FileManager.default.fileExists(atPath: sh.systemDocs.root.appendingPathComponent("START-HERE.md").path) {
                _ = try? SystemDocs.install(into: sh.systemDocs, shipped: sh.shipped, baseURL: "http://127.0.0.1:\(settingsNow().port)", version: version)
            }
            return sh.systemDocs
        }
    }

    static func endpoint(_ shelf: Shelf) -> APIEndpoint {
        switch shelf {
        case .library: .library
        case .memory: .memory
        case .systemDocs: .systemDocs
        }
    }

    /// The operations a shelf has: the library's (only those that read, on SYSTEM-DOCS), and MEMORY's own.
    static func operations(_ shelf: Shelf) -> [LibraryAPI.Operation] {
        switch shelf {
        case .library: LibraryAPI.operations
        case .memory: LibraryAPI.operations + MemoryAPI.operations
        case .systemDocs: LibraryAPI.operations.filter { !$0.changes && $0.name != "trash" }
        }
    }

    /// The request's fields: its query, then its JSON body (or its text, as "text").
    func fields(_ req: HTTPRequest, textAs field: String = "text") throws -> [String: Any] {
        var fields: [String: Any] = [:]
        for (k, v) in req.query { fields[k] = v }
        if !req.body.isEmpty {
            if req.contentType.hasPrefix("text/") {
                fields[field] = String(decoding: req.body, as: UTF8.self)
            } else if let body = JSON.object(req.body) {
                fields.merge(body) { _, b in b }
            } else {
                throw HTTPError(status: 400, code: "bad_request", message: "send a JSON object (Content-Type: application/json), or text as text/plain")
            }
        }
        return fields
    }

    /// /api/library, /api/memory, /api/system-docs and everything under them.
    func shelfRoute(_ shelf: Shelf, _ req: HTTPRequest, path: String, _ s: APISettings) async throws -> HTTPResponse {
        let endpoint = Self.endpoint(shelf)
        guard s.isOn(endpoint) else {
            throw HTTPError(status: 503, code: "endpoint_off", message: "\(endpoint.title.lowercased()) is turned off in Tool Mac Tool Run")
        }
        let rest = Array(path.split(separator: "/").map(String.init).dropFirst(2))  // after "api", "<shelf>"
        var fields = try self.fields(req)
        let method = req.method == "HEAD" ? "GET" : req.method
        let base = shelf.apiPath
        let op: String
        switch (method, rest.first, rest.count) {
        case ("GET", nil, _):
            return JSON.response(shelfOverview(shelf))
        case ("POST", nil, _):
            let names = Self.operations(shelf).map(\.name).joined(separator: ", ")
            guard let named = RunAPI.text(fields["op"] ?? fields["operation"]), !named.isEmpty else {
                throw HTTPError(status: 400, code: "missing_op", message: "send {\"op\": \"<one of \(names)>\", …} (GET \(base) says what each takes)")
            }
            op = named.lowercased().replacingOccurrences(of: "-", with: "_")
        case ("GET", "files", 1): op = "list"
        case ("POST", "files", 1): op = "create"
        case (_, "files", 2):
            fields["name"] = rest[1]
            switch method {
            case "GET": op = req.query["format"] == "text" || req.query["format"] == "raw" ? "raw" : "read"
            case "PUT": op = "write"
            case "DELETE": op = "delete"
            case "POST": op = "create"
            default: throw HTTPError(status: 405, code: "bad_request", message: "a \(shelf.noun) takes GET (read), PUT (write) or DELETE (to the Trash)")
            }
        case (_, "files", 3):
            fields["name"] = rest[1]
            let action = rest[2]
            let reads = ["outline", "backlinks", "exists"]
            guard ["append", "rename", "copy"].contains(action) || reads.contains(action) else {
                throw HTTPError(status: 404, code: "not_found", message: "no such route: \(req.path) (a \(shelf.noun)'s routes: append, rename, copy, outline, backlinks, exists)")
            }
            guard method == (reads.contains(action) ? "GET" : "POST") else {
                throw HTTPError(status: 405, code: "bad_request", message: "\(req.path) takes \(reads.contains(action) ? "GET" : "POST")")
            }
            op = action
        case ("GET", "names", 1): op = "names"
        case ("GET", "search", 1): op = "search"
        case ("GET", "find", 1): op = "find"
        case ("GET", "recent", 1): op = "recent"
        case ("GET", "stats", 1): op = "stats"
        case ("GET", "trash", 1): op = "trash"
        case ("POST", "trash", 2) where rest[1] == "restore": op = "restore"
        case ("POST", "trash", 2) where rest[1] == "empty": op = "empty_trash"
        case ("GET", "operations", 1):
            let limit = min(500, max(1, Int(req.query["limit"] ?? "") ?? 20))
            return JSON.response(["operations": await libraryLog.recent(500).filter { $0.kind == shelf.rawValue }.prefix(limit).map(LibraryLog.json)])
        case ("GET", "operations", 2):
            guard let id = UUID(uuidString: rest[1]), let e = await libraryLog.entry(id) else {
                throw HTTPError(status: 404, code: "unknown_request", message: "no operation \(rest[1]) (the latest \(libraryLog.capacity) are kept while the app runs)")
            }
            return JSON.response(LibraryLog.json(e), headers: [("X-Request-Id", id.uuidString)])
        // MEMORY's own.
        case ("POST", "remember", 1) where shelf == .memory: op = "remember"
        case ("GET", "recall", 1) where shelf == .memory, ("POST", "recall", 1) where shelf == .memory: op = "recall"
        case ("GET", "categories", 1) where shelf == .memory: op = "categories"
        case ("GET", "categories", 3) where shelf == .memory && rest[2] == "members":
            fields["name"] = rest[1]
            op = "members"
        case ("GET", "upcoming", 1) where shelf == .memory: op = "upcoming"
        case ("POST", "sync", 1) where shelf == .memory: op = "sync"
        case ("POST", "defaults", 1) where shelf == .memory: op = "defaults"
        default:
            throw HTTPError(status: 404, code: "not_found", message: "no such route: \(req.method) \(req.path) (GET \(base) lists \(shelf.place)'s routes)")
        }
        return await shelfOperation(shelf, op, LibraryAPI.Fields(values: fields), req)
    }

    /// Does it, logs it under a new id, and answers (copying it, or showing it, when asked).
    private func shelfOperation(_ shelf: Shelf, _ op: String, _ fields: LibraryAPI.Fields, _ req: HTTPRequest) async -> HTTPResponse {
        let lib = files(shelf)
        let client = Self.client(req, fields.values)
        return await logged(shelf.rawValue, op, fields, req) {
            if op == "raw" {
                let r = try lib.read(try fields.name())
                return .raw(HTTPResponse(status: 200, contentType: "text/markdown; charset=utf-8", data: Data(r.text.utf8)), name: r.note.name, summary: "read \(r.note.name)")
            }
            let known = Self.operations(shelf).map(\.name)
            guard known.contains(op) else {
                if shelf.readOnly, LibraryAPI.byName[op]?.changes == true { try lib.writable() }
                throw LibraryError(.badName, "There's no \(shelf.rawValue) operation called \(op).", fix: "The operations: \(known.joined(separator: ", "))")
            }
            var out: [String: Any]
            if MemoryAPI.byName[op] != nil {
                out = try MemoryAPI.perform(op, fields, memory: self.shelves().memory, client: client)
            } else {
                // A memory file renamed: its node follows (by the name it had).
                let before = op == "rename" ? (try? fields.name()).flatMap { lib.find($0)?.name } : nil
                out = try LibraryAPI.perform(op, fields, library: lib)
                if shelf == .memory {
                    let mind = self.shelves().mind
                    if op == "rename", let before, let now = out["name"] as? String {
                        out["mind"] = try mind.renamed(before, to: now, who: client)
                    }
                    if ["write", "create", "append", "copy", "restore", "rename"].contains(op) {
                        let added = try mind.index(lib, who: client)
                        if !added.isEmpty { out["mind"] = ((out["mind"] as? [String]) ?? []) + added }
                    }
                }
            }
            let summary = MemoryAPI.byName[op] != nil ? Self.memorySummary(op, out) : LibraryAPI.summary(op, out)
            return .json(out, summary: summary)
        }
    }

    static func memorySummary(_ op: String, _ out: [String: Any]) -> String {
        switch op {
        case "remember": return "remembered \(out["node"] ?? "") in \(out["file"] ?? "")"
        case "recall": return "recalled \(out["name"] ?? "")"
        case "members": return "\(out["count"] ?? 0) in \(out["name"] ?? "")"
        case "upcoming": return "\(out["count"] ?? 0) in the next \(out["days"] ?? 30) days"
        case "sync": return "\(out["count"] ?? 0) files made nodes"
        case "defaults": return "put back \(out["count"] ?? 0) files"
        default: return op
        }
    }

    /// GET /api/<shelf>: where it is, what's in it, and every operation with what it takes.
    func shelfOverview(_ shelf: Shelf) -> [String: Any] {
        let lib = files(shelf)
        var out: [String: Any] = [
            "ok": true, "shelf": shelf.rawValue, "folder": lib.root.path, "extension": lib.ext, "exists": FileManager.default.fileExists(atPath: lib.root.path),
            "notes": lib.list().count, "trashed": lib.trash().count, "read_only": shelf.readOnly,
            "approval": shelf.readOnly ? "none: it's read only" : "none: \(shelf.place)'s calls answer at once, without asking on the Mac (a delete moves the \(shelf.noun) to \(shelf.place)'s Trash)",
            "names": "a \(shelf.noun)'s name is its file's name without .\(lib.ext): \(shelf == .memory ? "PEOPLE is MEMORY/PEOPLE" : shelf == .systemDocs ? "START-HERE is SYSTEM-DOCS/START-HERE" : "groceries is \(FileLibrary.folderName)/groceries").\(lib.ext)",
            "how": "POST \(shelf.apiPath) {\"op\": \"<operation>\", …its fields}, or the operation's own route",
            "copy_and_show": "add \"copy\": true to any operation to put its answer on the clipboard, \"present\": true to show it in a window on the Mac",
            "operations": Self.operations(shelf).map { o -> [String: Any] in
                var d: [String: Any] = ["op": o.name, "summary": o.summary, "fields": o.fields, "changes": o.changes]
                if let r = o.route { d["route"] = r.replacingOccurrences(of: "/api/library", with: shelf.apiPath) }
                return d
            },
        ]
        if shelf == .memory {
            out["mind"] = "each file is a node of the mind (GET /api/mind/nodes/PEOPLE); remember links what's learnt to them"
            out["defaults"] = Memory.defaultNames
        }
        if shelf == .systemDocs { out["start"] = "GET /api/system-docs/files/START-HERE" }
        return out
    }

    // MARK: doing an operation, and saying how it went

    enum Done {
        case json([String: Any], summary: String)
        case raw(HTTPResponse, name: String?, summary: String)
    }

    /// Does `work`, logs it under a new id (as `kind`), and answers: the JSON with "ok", "op" and
    /// "request", or the mistake with its code and fix. "copy": true puts the answer on the
    /// clipboard too; "present": true shows it in a window on the Mac.
    func logged(_ kind: String, _ op: String, _ fields: LibraryAPI.Fields, _ req: HTTPRequest, _ work: () async throws -> Done) async -> HTTPResponse {
        let id = UUID()
        let started = Date()
        let client = Self.client(req, fields.values)
        let from = Self.from(req)
        let tagged: [(String, String)] = [("X-Request-Id", id.uuidString)]
        do {
            switch try await work() {
            case .raw(var response, let name, let summary):
                await libraryLog.add(.init(id: id, kind: kind, op: op == "raw" ? "read" : op, name: name, client: client, from: from, at: started,
                                           seconds: Date().timeIntervalSince(started), ok: true, status: 200, code: nil, error: nil, summary: summary))
                response.headers += tagged
                return response
            case .json(var out, let summary):
                await libraryLog.add(.init(id: id, kind: kind, op: op, name: out["name"] as? String ?? fields.text("name"), client: client, from: from, at: started,
                                           seconds: Date().timeIntervalSince(started), ok: true, status: 200, code: nil, error: nil, summary: summary))
                out["ok"] = true
                out["op"] = op
                out["request"] = id.uuidString
                await deliver(&out, kind: kind, op: op, fields, client: client)
                return JSON.response(out, headers: tagged)
            }
        } catch {
            let (status, code, message, fix, extra) = Self.mistake(error, op: op)
            await libraryLog.add(.init(id: id, kind: kind, op: op == "raw" ? "read" : op, name: fields.text("name"), client: client, from: from, at: started,
                                       seconds: Date().timeIntervalSince(started), ok: false, status: status, code: code, error: message, summary: "\(op): \(message)"))
            var out: [String: Any] = ["ok": false, "op": op, "code": code, "error": message, "request": id.uuidString]
            if let fix { out["fix"] = fix }
            out.merge(extra) { a, _ in a }
            return JSON.response(out, status: status, headers: tagged)
        }
    }

    /// Any mistake as (status, code, message, fix, more fields).
    static func mistake(_ error: Error, op: String) -> (Int, String, String, String?, [String: Any]) {
        switch error {
        case let e as LibraryError:
            let unknown = e.code == .badName && e.message.hasPrefix("There's no") && e.message.contains("operation called")
            return (unknown ? 400 : e.status, unknown ? "unknown_op" : e.code.rawValue, e.message, e.fix, [:])
        case let e as MindError:
            var extra: [String: Any] = [:]
            if !e.problems.isEmpty { extra["problems"] = e.problems.map(MindAPI.problemJSON) }
            return (e.status, e.code.rawValue, e.message, e.problems.isEmpty ? e.fix : "Each problem says its fix.", extra)
        case let e as ChromeError:
            return (e.status, e.code.rawValue, e.message, e.fix, [:])
        case let e as WebError:
            return (e.status, e.code.rawValue, e.message, e.fix, [:])
        case let e as HTTPError:
            return (e.status, e.code, e.message, nil, [:])
        default:
            return (500, "failed", "\(error)", nil, [:])
        }
    }

    /// "copy": true and "present": true, on any answer.
    func deliver(_ out: inout [String: Any], kind: String, op: String, _ fields: LibraryAPI.Fields, client: String) async {
        let copy = fields.bool("copy") == true || fields.bool("clipboard") == true
        let show = fields.bool("present") == true || fields.bool("show") == true
        guard copy || show else { return }
        let text = Self.resultText(out)
        if copy {
            do {
                try await host.copy(text)
                out["copied"] = true
                out["copied_chars"] = text.count
            } catch {
                out["copied"] = false
                out["copy_error"] = Self.mistake(error, op: op).2
            }
        }
        if show {
            let shelf = Shelf(rawValue: kind)
            let name = out["name"] as? String
            let title = op == "read" ? (name ?? "A file") : "\(shelf?.title ?? kind.capitalized): \(op)" + (name.map { " · \($0)" } ?? "")
            let format: Presentation.Format = (out["text"] is String && shelf != nil) ? .markdown : (out["lines"] != nil && kind == "mind" ? .mind : .text)
            let source = shelf.flatMap { s in name.map { "\(s.folderName)/\($0).md" } }
            let p = Presentation(title: title, text: text, format: format, source: source ?? (kind == "mind" ? "the mind" : nil),
                                 shelf: op == "read" ? shelf : nil, name: op == "read" ? name : nil, client: client, why: Self.why(fields.values))
            do {
                try await host.present(p)
                out["presented"] = true
            } catch {
                out["presented"] = false
                out["present_error"] = Self.mistake(error, op: op).2
            }
        }
    }

    /// An answer as text, for the clipboard or a window: a file's text, the lines it found, the
    /// names, or else the JSON.
    static func resultText(_ out: [String: Any]) -> String {
        if let t = out["text"] as? String, out["op"] as? String != "has" { return t }
        if let lines = out["lines"] as? [String] { return lines.joined(separator: "\n") }
        if let hits = out["results"] as? [[String: Any]] {
            return hits.map { h in
                let name = h["name"] as? String ?? ""
                let lines = (h["lines"] as? [[String: Any]] ?? []).map { "  line \($0["line"] ?? ""): \($0["text"] ?? "")" }
                return ([name] + lines).joined(separator: "\n")
            }.joined(separator: "\n")
        }
        if let names = out["names"] as? [String] { return names.joined(separator: "\n") }
        var shown = out
        for k in ["ok", "op", "request"] { shown[k] = nil }
        let data = (try? JSONSerialization.data(withJSONObject: shown, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
