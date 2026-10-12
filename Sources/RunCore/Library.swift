import Foundation

/// A script or a flow in the folder: its file, what it's written in, and the line describing it.
public struct ScriptItem: Identifiable, Equatable, Hashable, Sendable {
    /// Its file name (what the grid remembers it by).
    public var id: String { url.lastPathComponent }
    public var url: URL
    public var language: ScriptLanguage
    /// Its name without the extension, as shown on its cell.
    public var title: String { (url.lastPathComponent as NSString).deletingPathExtension }
    /// The first comment in it (after any #! line), as shown under the title.
    public var summary: String?
    public var modified: Date?
    /// What in it looks like it can't be undone (`Caution`): the app asks before running it.
    public var dangers: [String] = []
    /// It looks like it asks for a typed answer while it runs: its run keeps a way to type one.
    public var asksForInput = false

    public init(url: URL, language: ScriptLanguage, summary: String? = nil, modified: Date? = nil) {
        self.url = url
        self.language = language
        self.summary = summary
        self.modified = modified
    }

    /// The same, with what `Caution` reads in it.
    func cautioned() -> ScriptItem {
        var item = self
        let text = Caution.text(of: url)
        item.dangers = Caution.dangers(in: text)
        item.asksForInput = Caution.asksForInput(text)
        return item
    }
}

/// Which grid: every script, or the flows that compose them.
public enum GridKind: String, Codable, CaseIterable, Sendable {
    case scripts, composer

    public var title: String { self == .scripts ? "Scripts" : "Composer" }
}

/// The folder the scripts live in: the scripts at its top, the flows (`.flow`) in its `composer`
/// folder.
public struct Library: Sendable {
    public let root: URL
    public static let flowExtension = "flow"

    public init(root: URL) {
        self.root = root
    }

    public var composerFolder: URL { root.appendingPathComponent("composer", isDirectory: true) }

    /// Files at the top of the folder that aren't scripts.
    static let notScripts: Set<String> = ["md", "txt", "json", "yaml", "yml", "toml", "csv", "tsv", "log", "plist", "xml", "html", "css",
                                          "png", "jpg", "jpeg", "gif", "svg", "pdf", "zip", "gz", "tar", "dmg", "pkg", "env", "ini", "cfg",
                                          "conf", "lock", "flow", "mov", "mp4", "mp3", "wav", "doc", "docx", "xls", "xlsx", "key", "pem"]

    /// The scripts, by name.
    public func scripts() -> [ScriptItem] {
        files(in: root).compactMap { url in
            let ext = url.pathExtension.lowercased()
            if Self.notScripts.contains(ext) { return nil }
            let contents = Self.head(of: url)
            let executable = FileManager.default.isExecutableFile(atPath: url.path)
            let lang = ScriptLanguage.detect(fileName: url.lastPathComponent, contents: contents, executableBit: executable)
            // A file we can't run and that isn't marked executable isn't a script (a note, a picture).
            if lang == .unknown { return nil }
            return ScriptItem(url: url, language: lang, summary: contents.flatMap(Self.summary), modified: Self.modified(url)).cautioned()
        }
    }

    /// The flows, by name.
    public func flows() -> [ScriptItem] {
        files(in: composerFolder).filter { $0.pathExtension.lowercased() == Self.flowExtension }.map { url in
            var item = ScriptItem(url: url, language: .unknown, summary: Self.head(of: url).flatMap(Self.summary), modified: Self.modified(url))
            item.dangers = Caution.dangers(in: Caution.text(of: url))
            return item
        }
    }

    public func items(_ kind: GridKind) -> [ScriptItem] { kind == .scripts ? scripts() : flows() }

    /// The scripts' file names, as `run "…"` in a flow names them.
    public func scriptNames() -> [String] { scripts().map(\.id) }

    /// The script `run "name"` means: by file name, or by the name without its extension.
    public func script(named name: String) -> ScriptItem? {
        let all = scripts()
        guard let match = ScriptNames.match(name, in: all.map(\.id)) else { return nil }
        return all.first { $0.id == match }
    }

    /// The files in `folder`, by name. A symbolic link to a file counts as a file (it keeps its own
    /// name and place: that's the script's identity); one to a folder, or to nothing, doesn't.
    private func files(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isHiddenKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        return urls.filter { url in
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
            if values.isSymbolicLink == true {
                return (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
            return values.isRegularFile == true
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func head(of url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let data = (try? h.read(upToCount: 4096)) ?? Data()
        // Not text (a compiled program, a picture): nothing to read.
        if data.contains(0) { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// When the file (for a symbolic link, the file it points to) last changed.
    static func modified(_ url: URL) -> Date? {
        (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// The first comment line in a script (not the #! line, not an editor's settings line).
    public static func summary(_ contents: String) -> String? {
        for raw in contents.split(separator: "\n", omittingEmptySubsequences: false).prefix(15) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#!") || line.hasPrefix("<?php") || line.isEmpty { continue }
            for marker in ["//", "#", "--", "\"\"\"", "'", ";"] where line.hasPrefix(marker) {
                var text = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
                if text.hasPrefix("-*-") || text.lowercased().hasPrefix("vim:") || text.lowercased().hasPrefix("shellcheck") { break }
                text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if !text.isEmpty { return String(text.prefix(140)) }
            }
            // The first line that isn't a comment: there's no description.
            if !line.hasPrefix("#") && !line.hasPrefix("//") && !line.hasPrefix("--") && !line.hasPrefix("set ") && !line.hasPrefix("import ")
                && !line.hasPrefix("use ") && !line.hasPrefix("package ") { return nil }
        }
        return nil
    }

    // MARK: making things (each says what it did)

    /// Makes the folder and its `composer` folder when they aren't there. Returns what it made.
    @discardableResult
    public func ensure() throws -> [String] {
        var made: [String] = []
        let fm = FileManager.default
        for folder in [root, composerFolder] where !fm.fileExists(atPath: folder.path) {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            made.append(folder.path)
        }
        return made
    }

    /// A name not taken yet in `folder`: `name.ext`, else `name-2.ext`, `name-3.ext`…
    public static func freeName(_ name: String, ext: String, in folder: URL) -> URL {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        let base = clean.isEmpty ? "untitled" : clean
        func url(_ n: String) -> URL { folder.appendingPathComponent(ext.isEmpty ? n : "\(n).\(ext)") }
        var candidate = url(base)
        var k = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url("\(base)-\(k)")
            k += 1
        }
        return candidate
    }

    /// A new script, from its language's template, marked executable.
    public func newScript(name: String, language: ScriptLanguage, contents: String? = nil) throws -> URL {
        try ensure()
        let url = Self.freeName(name, ext: language.fileExtension, in: root)
        try (contents ?? language.template).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// A new flow.
    public func newFlow(name: String, contents: String? = nil) throws -> URL {
        try ensure()
        let url = Self.freeName(name, ext: Self.flowExtension, in: composerFolder)
        try (contents ?? Examples.newFlow).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Puts the examples in the folder, leaving any already there as they are. Returns the ones added.
    @discardableResult
    public func addExamples() throws -> [URL] {
        try ensure()
        var added: [URL] = []
        for (name, contents) in Examples.scripts {
            let url = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { continue }
            try contents.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            added.append(url)
        }
        for (name, contents) in Examples.flows {
            let url = composerFolder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { continue }
            try contents.write(to: url, atomically: true, encoding: .utf8)
            added.append(url)
        }
        return added
    }
}

/// The examples a new folder can start with: one in each common language, and flows that compose them.
public enum Examples {
    public static let scripts: [(String, String)] = [
        ("hello.sh", """
        #!/bin/bash
        # Says hello, with the date, to whoever is named (or the world)
        set -euo pipefail

        echo "Hello, ${1:-world}! It's $(date '+%A %H:%M')."
        """ + "\n"),
        ("disk-space.sh", """
        #!/bin/bash
        # How full the main disk is, as a percentage
        set -euo pipefail

        df -h / | awk 'NR==2 { print $5 }'
        """ + "\n"),
        ("count-lines.py", """
        #!/usr/bin/env python3
        # Counts the lines and words in its input (or in the files named)
        import sys

        text = "".join(open(p).read() for p in sys.argv[1:]) if sys.argv[1:] else sys.stdin.read()
        print(f"{len(text.splitlines())} lines, {len(text.split())} words")
        """ + "\n"),
        ("shout.js", """
        #!/usr/bin/env node
        // Repeats its arguments (or its input) in capitals
        const fromArgs = process.argv.slice(2).join(" ");
        if (fromArgs) {
          console.log(fromArgs.toUpperCase() + "!");
        } else {
          let input = "";
          process.stdin.on("data", (d) => (input += d));
          process.stdin.on("end", () => console.log(input.trim().toUpperCase() + "!"));
        }
        """ + "\n"),
        ("big-files.sh", """
        #!/bin/bash
        # Lists the five biggest files in a folder (your Downloads unless one is named)
        set -eu

        dir="${1:-$HOME/Downloads}"
        if [ ! -d "$dir" ]; then
          echo "There's no folder $dir" >&2
          exit 1
        fi
        find "$dir" -maxdepth 1 -type f -exec du -h {} + 2>/dev/null | sort -rh | head -5
        """ + "\n"),
    ]

    public static let flows: [(String, String)] = [
        ("morning.flow", """
        // Says hello, checks the disk, and warns when it's getting full
        let greeting = run "hello" ["friend"]
        print greeting

        let used = run "disk-space" [] |> replace "%" "" |> int
        print $"The disk is {used}% full."

        if used > 85 then
            notify $"Disk is {used}% full: time to tidy up"
        else
            print "Plenty of room."
        """ + "\n"),
        ("loud-summary.flow", """
        // Counts the biggest downloads' names, then shouts the count
        let biggest = run "big-files" [] |> lines
        print $"{length biggest} big files:"
        biggest |> each print

        biggest
        |> join "\\n"
        |> pipe "count-lines" []
        |> pipe "shout" []
        |> print
        """ + "\n"),
        ("keep-going.flow", """
        // Shows attempt (keep going when a step fails), functions, and parallel steps
        let check name =
            let r = attempt name []
            if r.ok then $"✅ {name}: {r.out}" else $"❌ {name} failed ({r.code})"

        [ "hello"; "disk-space" ]
        |> map check
        |> each print

        let results =
            parallel [ (fun () -> run "hello" ["parallel one"]); (fun () -> run "hello" ["parallel two"]) ]
        results |> each print
        """ + "\n"),
        blocksFlow,
    ]

    public static let blocksFlow = ("big-downloads.flow", """
    // Asks before going on, then shows each of the biggest downloads on a line of its own
    let bigFiles = run "big-files" []

    confirm "Show the biggest files in your Downloads?"

    for line in lines bigFiles do
        print $"→ {line}"

    notify "Done: the list is in the run's output"
    """ + "\n")

    /// A new flow: only the line saying what it does (the block editor offers the first step).
    public static let newFlow = "// What this flow does, in one line (it's shown on its cell)\n"
}
