import Foundation

/// SYSTEM-DOCS: how the app works, for the person and for the models that use it, as a shelf of
/// Markdown files like the library, but one the app writes and nobody changes. Its docs come from
/// two places: the ones the app ships with (docs/system and the guides, copied into the app as
/// SYSTEM-DOCS by scripts/build-app.sh), and the ones made from the app itself, so they can't
/// disagree with it: the API reference, every route, every Flow function and every Straw word.
/// Installing it again (each launch) puts back what's changed and leaves out what's gone.
public enum SystemDocs {
    /// A doc made from the app itself.
    public static func generated(baseURL: String, version: String?) -> [(name: String, text: String)] {
        [
            ("API-REFERENCE", APIDoc.text(baseURL: baseURL, version: version)),
            ("API-ROUTES", "# Every API route\n\nEvery route the API answers at \(baseURL), in its groups (GET /api/endpoints gives the same as JSON). Routes marked [asks on the Mac] wait for the person's click.\n\n" + APIRoutes.text + "\n"),
            ("FLOW-FUNCTIONS", flowFunctions),
            ("STRAW-WORDS", strawWords),
        ]
    }

    static var flowFunctions: String {
        var out = "# Every Flow function\n\nFlow's own functions, by group, each with its type and an example (the Flow guide, FLOW-GUIDE, says how the language goes).\n"
        var groups: [String] = []
        for b in Builtin.all where !groups.contains(b.group) { groups.append(b.group) }
        for g in groups {
            out += "\n## \(g)\n\n"
            for b in Builtin.all where b.group == g {
                out += "- `\(b.name) : \(b.signature)` — \(b.summary)\n  `\(b.example)`\n"
            }
        }
        return out
    }

    static var strawWords: String {
        var out = "# Every Straw word\n\nStraw drives Chrome by what's on the page, a plain line a step (the Straw guide, STRAW-GUIDE, says how it goes).\n\n"
        for w in RunAPI.strawWords {
            out += "- **\(w.word)** \(w.takes) — \(w.does)\n  `\(w.example)`\n"
        }
        return out
    }

    /// The index: every doc, with its first line, and where to start.
    static func index(_ docs: [(name: String, text: String)]) -> String {
        var out = """
        # Start here

        SYSTEM-DOCS is how Tool Mac Tool Run works, written for you and for the models (and other apps) that use it. It can't be changed: the app writes it, from what it ships with, each time it starts. Read any doc over the API too: GET /api/system-docs/files/{name}.

        If you're a model using this Mac through the app, read PROMPT-ASSISTANT first, then RECIPES and EXCHANGES. A small model, or one that should only talk: PROMPT-SMALL-MODEL (Peter, Tool Mac Agent, and plain words).

        ## The docs

        """
        for d in docs.sorted(by: { $0.name < $1.name }) {
            let first = d.text.components(separatedBy: "\n").first { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                return !t.isEmpty && !t.hasPrefix("#")
            } ?? ""
            let short = first.count > 160 ? String(first.prefix(159)) + "…" : first
            out += "- **\(d.name)**" + (short.isEmpty ? "" : " — \(short)") + "\n"
        }
        return out
    }

    public struct Installed: Sendable, Equatable {
        public var written: [String]
        public var unchanged: [String]
        public var removed: [String]
    }

    private static let manifestName = ".installed.json"

    /// Writes the docs into the shelf's folder: each from `shipped` (a folder of .md files, the
    /// app's SYSTEM-DOCS), the generated ones, and the index (START-HERE). A doc already the same
    /// isn't touched; one the app wrote before that's gone now is removed. Each file is read-only
    /// on disk, so an editor says so.
    @discardableResult
    public static func install(into shelf: FileLibrary, shipped: URL?, baseURL: String, version: String?) throws -> Installed {
        let fm = FileManager.default
        var docs: [(name: String, text: String)] = []
        if let shipped, let files = try? fm.contentsOfDirectory(at: shipped, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for f in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where f.pathExtension.lowercased() == shelf.ext {
                guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
                docs.append((f.deletingPathExtension().lastPathComponent, text))
            }
        }
        for g in generated(baseURL: baseURL, version: version) where !docs.contains(where: { $0.name == g.name }) { docs.append(g) }
        docs.append(("START-HERE", index(docs)))

        do {
            try fm.createDirectory(at: shelf.root, withIntermediateDirectories: true)
        } catch {
            throw LibraryError(.failed, "Couldn't make SYSTEM-DOCS (\(shelf.root.path)): \(error.localizedDescription)")
        }
        var result = Installed(written: [], unchanged: [], removed: [])
        for d in docs {
            let url = shelf.root.appendingPathComponent(d.name + "." + shelf.ext)
            if let now = try? String(contentsOf: url, encoding: .utf8), now == d.text {
                result.unchanged.append(d.name)
                continue
            }
            do {
                if fm.fileExists(atPath: url.path) {
                    try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
                    try fm.removeItem(at: url)
                }
                try Data(d.text.utf8).write(to: url)
                try? fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
                result.written.append(d.name)
            } catch {
                throw LibraryError(.failed, "Couldn't write \(d.name) into SYSTEM-DOCS: \(error.localizedDescription)")
            }
        }
        // What the app wrote last time and doesn't now: gone.
        let manifest = shelf.root.appendingPathComponent(manifestName)
        let before = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: manifest))) ?? []
        let now = docs.map(\.name)
        for old in before where !now.contains(old) {
            let url = shelf.root.appendingPathComponent(old + "." + shelf.ext)
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            if (try? fm.removeItem(at: url)) != nil { result.removed.append(old) }
        }
        if let data = try? JSONEncoder().encode(now.sorted()) { try? data.write(to: manifest, options: .atomic) }
        return result
    }
}
