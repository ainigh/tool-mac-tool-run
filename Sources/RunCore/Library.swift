import Foundation

/// A script or a flow in the folder: its file, what it's written in, and the line describing it.
public struct ScriptItem: Identifiable, Equatable, Hashable, Sendable {
    /// Its file name, after its grid's folder for a utility or a browser script
    /// (`utilities/play-sound.sh`): what the grid remembers it by, and what `run` names it by.
    public var id: String { grid.idPrefix + url.lastPathComponent }
    public var url: URL
    /// The grid it's a cell of.
    public var grid: GridKind
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
    /// It runs EPA (a flow with an `epa` step, or one of EPA's own scripts): its cell says so.
    public var usesEPA = false
    /// What its header says it asks for before it runs (`# Input: …`).
    public var inputs: [ScriptInput] = []
    /// The words its header says it's found by (`# Tags: weather forecast rain`): what
    /// `GET /api/search` finds it by, beside its name and what it does.
    public var tags: [String] = []

    public init(url: URL, language: ScriptLanguage, summary: String? = nil, modified: Date? = nil, grid: GridKind = .scripts) {
        self.url = url
        self.grid = grid
        self.language = language
        self.summary = summary
        self.modified = modified
    }

    /// The same, with what `Caution` reads in it.
    func cautioned() -> ScriptItem {
        var item = self
        let text = Caution.text(of: url)
        item.dangers = Caution.dangers(in: text)
        item.asksForInput = Caution.asksForInput(text, language: language)
        item.usesEPA = Examples.epaScripts.contains { $0.0 == id }
        return item
    }
}

/// Which grid: the scripts at the top of the folder, the flows that compose them, the small
/// reusable utilities, and the scripts that drive the browser. Utilities and browser scripts are
/// scripts like any other (they run, and flows run them, the same way): only their folder differs.
public enum GridKind: String, Codable, CaseIterable, Sendable {
    case scripts, composer, utilities, browser

    public var title: String {
        switch self {
        case .scripts: "Scripts"
        case .composer: "Composer"
        case .utilities: "Utilities"
        case .browser: "Browser"
        }
    }

    /// Its cells are flows (`.flow` files); every other grid's are scripts.
    public var isFlow: Bool { self == .composer }

    /// The grids whose cells are scripts, in the order `run` looks for a name.
    public static let scriptGrids: [GridKind] = [.scripts, .utilities, .browser]

    /// The folder its files are in, inside the scripts folder (nil: the scripts folder's top).
    public var subfolder: String? {
        switch self {
        case .scripts: nil
        case .composer: "composer"
        case .utilities: "utilities"
        case .browser: "browser"
        }
    }

    /// What goes before a file's name in its id: its folder, for a utility or a browser script
    /// (a flow is named by its file alone, as it always was).
    public var idPrefix: String {
        switch self {
        case .utilities, .browser: subfolder.map { $0 + "/" } ?? ""
        case .scripts, .composer: ""
        }
    }

    /// What one of its cells is, and more than one.
    public var noun: String {
        switch self {
        case .scripts: "script"
        case .composer: "flow"
        case .utilities: "utility"
        case .browser: "browser script"
        }
    }

    public var nouns: String { self == .utilities ? "utilities" : noun + "s" }

    /// "1 flow", "3 utilities".
    public func count(_ n: Int) -> String { "\(n) \(n == 1 ? noun : nouns)" }

    /// What it's for, in a line.
    public var purpose: String {
        switch self {
        case .scripts: "Every script, a click to run"
        case .composer: "Flows that compose your scripts"
        case .utilities: "Small reusable helpers: the weather, the news, cloud status, sounds, parsing data"
        case .browser: "Scripts that drive Chrome: Google, YouTube, YouTube Music, any page"
        }
    }

    /// The grid a script's id puts it in.
    public static func of(scriptID id: String) -> GridKind {
        scriptGrids.first { !$0.idPrefix.isEmpty && id.hasPrefix($0.idPrefix) } ?? .scripts
    }
}

/// The folder the scripts live in: the scripts at its top, the flows (`.flow`) in its `composer`
/// folder, the utilities in `utilities` and the browser scripts in `browser`.
public struct Library: Sendable {
    public let root: URL
    public static let flowExtension = "flow"

    public init(root: URL) {
        self.root = root
    }

    /// The folder a grid's files are in.
    public func folder(_ kind: GridKind) -> URL {
        kind.subfolder.map { root.appendingPathComponent($0, isDirectory: true) } ?? root
    }

    public var composerFolder: URL { folder(.composer) }

    /// Files at the top of the folder that aren't scripts.
    static let notScripts: Set<String> = ["md", "txt", "json", "yaml", "yml", "toml", "csv", "tsv", "log", "plist", "xml", "html", "css",
                                          "png", "jpg", "jpeg", "gif", "svg", "pdf", "zip", "gz", "tar", "dmg", "pkg", "env", "ini", "cfg",
                                          "conf", "lock", "flow", "mov", "mp4", "mp3", "wav", "doc", "docx", "xls", "xlsx", "key", "pem"]

    /// Every script: the ones at the top of the folder, then the utilities, then the browser
    /// scripts, each by name.
    public func scripts() -> [ScriptItem] { GridKind.scriptGrids.flatMap(scripts(in:)) }

    /// The scripts of one grid, by name.
    public func scripts(in kind: GridKind) -> [ScriptItem] {
        guard !kind.isFlow else { return [] }
        return files(in: folder(kind)).compactMap { url in
            let ext = url.pathExtension.lowercased()
            if Self.notScripts.contains(ext) { return nil }
            let contents = Self.head(of: url)
            let executable = FileManager.default.isExecutableFile(atPath: url.path)
            let lang = ScriptLanguage.detect(fileName: url.lastPathComponent, contents: contents, executableBit: executable)
            // A file we can't run and that isn't marked executable isn't a script (a note, a picture).
            if lang == .unknown { return nil }
            var item = ScriptItem(url: url, language: lang, summary: contents.flatMap(Self.summary), modified: Self.modified(url), grid: kind).cautioned()
            item.inputs = contents.map(ScriptInput.declared) ?? []
            item.tags = contents.map(ScriptInput.declaredTags) ?? []
            return item
        }
    }

    /// The flows, by name.
    public func flows() -> [ScriptItem] {
        files(in: composerFolder).filter { $0.pathExtension.lowercased() == Self.flowExtension }.map { url in
            let head = Self.head(of: url)
            var item = ScriptItem(url: url, language: .unknown, summary: head.flatMap(Self.summary), modified: Self.modified(url), grid: .composer)
            item.inputs = head.map(ScriptInput.declared) ?? []
            item.tags = head.map(ScriptInput.declaredTags) ?? []
            let text = Caution.text(of: url)
            item.dangers = Caution.dangers(in: text)
            item.usesEPA = EPA.isUsed(in: text)
            return item
        }
    }

    public func items(_ kind: GridKind) -> [ScriptItem] { kind.isFlow ? flows() : scripts(in: kind) }

    /// The scripts' names, as `run "…"` in a flow names them.
    public func scriptNames() -> [String] { scripts().map(\.id) }

    /// The script `run "name"` means: by its id, or that without the extension; else a utility or
    /// a browser script by its file name alone (the first, in `scriptGrids`' order).
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
        // A byte-order mark first isn't text; any line end ends a line (\r\n is one Character,
        // so splitting on \n alone would leave a Windows file one long line).
        var contents = contents
        if contents.unicodeScalars.first == "\u{FEFF}" { contents = String(contents.unicodeScalars.dropFirst()) }
        for raw in contents.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).prefix(15) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#!") || line.hasPrefix("<?php") || line.isEmpty { continue }
            for marker in ["//", "#", "--", "\"\"\"", "'''", ";"] where line.hasPrefix(marker) {
                var text = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
                if text.hasPrefix("-*-") || text.lowercased().hasPrefix("vim:") || text.lowercased().hasPrefix("shellcheck") { break }
                text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                // An "Input: …" line (and the "Why: …" under it) says what it asks for, not what it does.
                if ScriptInput.parse(text) != nil || ScriptInput.parseWhy(text) != nil || ScriptInput.parseTags(text) != nil { break }
                if !text.isEmpty { return String(text.prefix(140)) }
            }
            // The first line that isn't a comment: there's no description.
            if !line.hasPrefix("#") && !line.hasPrefix("//") && !line.hasPrefix("--") && !line.hasPrefix("set ") && !line.hasPrefix("import ")
                && !line.hasPrefix("use ") && !line.hasPrefix("package ") { return nil }
        }
        return nil
    }

    // MARK: making things (each says what it did)

    /// A name as typed, made into a file's: no `/` (it would be a folder), and no `.` first
    /// (that would hide it, from the grid too).
    public static func fileName(_ typed: String) -> String {
        let clean = typed.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        return String(clean.drop { $0 == "." }).trimmingCharacters(in: .whitespaces)
    }

    /// Makes the folder and its grids' folders (`composer`, `utilities`, `browser`) when they
    /// aren't there. Returns what it made.
    @discardableResult
    public func ensure() throws -> [String] {
        var made: [String] = []
        let fm = FileManager.default
        let folders = [root] + GridKind.allCases.filter { $0.subfolder != nil }.map(folder)
        for folder in folders where !fm.fileExists(atPath: folder.path) {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            made.append(folder.path)
        }
        return made
    }

    /// A name not taken yet in `folder`: `name.ext`, else `name-2.ext`, `name-3.ext`…
    public static func freeName(_ name: String, ext: String, in folder: URL) -> URL {
        let clean = fileName(name)
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

    /// A new script on a grid (the Scripts grid unless another is named), from its language's
    /// template, marked executable.
    public func newScript(name: String, language: ScriptLanguage, contents: String? = nil, in kind: GridKind = .scripts) throws -> URL {
        try ensure()
        let url = Self.freeName(name, ext: language.fileExtension, in: folder(kind.isFlow ? .scripts : kind))
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

    /// Puts examples in the folder, leaving any already there as they are: a grid's own (the
    /// Scripts and Composer grids share theirs), or, for no grid, every one. Then the flows that
    /// use the utilities and browser scripts, once every script they run is there. Returns the
    /// ones added.
    @discardableResult
    public func addExamples(for kind: GridKind? = nil) throws -> [URL] {
        updateExamples()
        var added: [URL]
        switch kind {
        case nil: added = try add(scripts: Examples.allScripts, flows: Examples.flows)
        case .scripts?, .composer?: added = try add(scripts: Examples.scripts, flows: Examples.flows)
        // The Straw utilities are run by the browser folder's straw.py (and browser.sh, which it drives Chrome with).
        case .utilities?: added = try add(scripts: Examples.utilities + Examples.strawRunner, flows: [])
        case .browser?: added = try add(scripts: Examples.browser, flows: [])
        }
        let names = LocalFlowHost.names(in: self)
        added += try add(scripts: [], flows: Examples.toolFlows.filter { (try? Flow.check($0.1, scripts: names)) != nil })
        return added
    }

    /// Brings each example (script, utility, browser script or flow) that is exactly an earlier version
    /// this app wrote up to date (one someone changed, or that isn't there, is left alone).
    /// Returns the ones updated.
    @discardableResult
    public func updateExamples(earlier: [String: [UInt64]] = Examples.earlierTools) -> [URL] {
        var updated: [URL] = []
        for (id, contents) in Examples.allScripts + Examples.flows + Examples.toolFlows {
            guard let hashes = earlier[id] else { continue }
            let url = id.hasSuffix("." + Self.flowExtension) ? composerFolder.appendingPathComponent(id) : root.appendingPathComponent(id)
            guard let now = try? String(contentsOf: url, encoding: .utf8), hashes.contains(Examples.fingerprint(now)) else { continue }
            if (try? contents.write(to: url, atomically: true, encoding: .utf8)) != nil { updated.append(url) }
        }
        return updated
    }

    /// What `addExamples(for:)` puts in a grid, in words ("7 utilities", "5 scripts and 4 flows").
    public static func examplesSummary(for kind: GridKind) -> String {
        switch kind {
        case .scripts, .composer: "\(GridKind.scripts.count(Examples.scripts.count)) and \(GridKind.composer.count(Examples.flows.count))"
        case .utilities: GridKind.utilities.count(Examples.utilities.count)
        case .browser: GridKind.browser.count(Examples.browser.count)
        }
    }

    /// Puts these scripts (marked executable) and flows in the folder, leaving any already there
    /// as they are. A script's name is its id (`utilities/speak.sh` goes in `utilities`).
    /// Returns the ones added.
    func add(scripts: [(String, String)], flows: [(String, String)]) throws -> [URL] {
        try ensure()
        var added: [URL] = []
        for (name, contents) in scripts {
            let url = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { continue }
            try contents.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            added.append(url)
        }
        for (name, contents) in flows {
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
    /// Earlier versions of the examples this app wrote (scripts, utilities, browser scripts, flows), by id,
    /// as their `fingerprint`s: a file still exactly one of them is brought up to date by
    /// `updateExamples`.
    public static let earlierTools: [String: [UInt64]] = [
        // browser.sh, 1st: it drove the default browser (Safari, Chrome and its kin); now it's
        // Chrome alone, with read (a tab of its own, behind), js-in, focus, go and encode, which
        // the Google and YouTube scripts use. 2nd: its AppleScript named Chrome only as it ran
        // (tell application id (item 1 of argv)), so Chrome's words (active tab, execute) were a
        // syntax error as it compiled. 3rd: it took JavaScript with a "; return" anywhere in it for statements,
        // so items.map(v => { const t = …; return t }) gave back nothing. 5th: it had no page,
        // has or find (the page as JSON; whether words are on it; where a thing named is).
        "browser/browser.sh": [0xc47a_ff9c_213a_2f07, 0x050a_0b97_2fcd_f82f, 0x47a8_ec9e_ea51_4d96, 0xb4dd_15b2_0cb4_cc78, 0x6652_9c19_11bc_9e7b],
        // straw.py, 1st: before first (the first of several), read links THING and js's lists a line each;
        // it dropped every backslash in a text, so JavaScript's \n and \s lost theirs.
        "browser/straw.py": [0xb9f9_b023_4e1a_783f],
        "browser/open-page.sh": [0x2bf6_5de2_2cd6_c476, 0x1933_3b85_00a1_6c01],
        "browser/page-info.sh": [0xd722_e7fa_24b6_5454],
        "browser/page-text.sh": [0xaba1_e6d4_52c4_9b85],
        "browser/page-links.sh": [0xe5ff_f745_d256_dbeb],
        "page-aloud.flow": [0xea4e_3455_ab47_3b9f],
        "page-addresses.flow": [0x05eb_fa99_bd66_88f1],
        // 3rd (and the 2nd of the others below): before their `Input:` lines, which say what the
        // API board asks for before it runs them; google.sh had no --answer, browser.sh no
        // close-duplicates or tabs --all, cloud-status.py read "github aws" as one service.
        "hello.sh": [0xbb98_1239_6a0d_3ed3],
        "count-lines.py": [0x0566_99de_2cd5_3fcb],
        "shout.js": [0x87f0_e3c4_648e_75bf],
        "big-files.sh": [0x8ea0_909a_ad99_f9b2],
        "browser/google.sh": [0xcf38_1d1a_826a_d507],
        "browser/youtube.sh": [0x6095_a4b6_10c4_aa93],
        "browser/youtube-music.sh": [0x8b2f_cf83_a09b_7daf],
        "ask-google.flow": [0xbb9c_1422_ec74_ead5],
        "cloud-check.flow": [0xdb73_cd37_7af7_7965],
        "play-music.flow": [0xb225_32c5_c315_8bd8],
        "urgent-news.flow": [0x8de9_861d_b339_b4eb],
        "weather-now.flow": [0x8848_8a35_32ff_eabe],
        "youtube-search.flow": [0x1529_de0d_ed58_6876],
        "utilities/clipboard.sh": [0x4dca_b392_e2b7_9450],
        "utilities/cloud-status.py": [0x5fb0_c9e4_46cd_2c86],
        "utilities/csv-to-json.py": [0x62e7_6926_5fa7_fb58],
        "utilities/extract-urls.py": [0x27cf_fa22_ba9f_9b47],
        "utilities/json-get.py": [0xd16f_4abf_71bd_b177],
        "utilities/news.py": [0xb77d_6f02_904c_1140],
        "utilities/play-song.sh": [0x4a57_d55a_4c0c_f94a],
        "utilities/play-sound.sh": [0xf8dc_3726_fa03_41eb],
        "utilities/speak.sh": [0x71ed_80b1_e7f9_8080],
        "utilities/weather.py": [0xf533_9f5f_7124_5d71],
    ]

    /// A file's text, boiled down to a number (FNV-1a, 64 bits): the same text always gives the
    /// same number, on any Mac.
    public static func fingerprint(_ text: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in text.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return h
    }

    public static let scripts: [(String, String)] = [
        ("hello.sh", """
        #!/bin/bash
        # Says hello, with the date, to whoever is named (or the world)
        #
        # Input (optional): Who to greet (the world unless set)
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
        #
        # Input text: The text to count
        import sys

        text = "".join(open(p).read() for p in sys.argv[1:]) if sys.argv[1:] else sys.stdin.read()
        print(f"{len(text.splitlines())} lines, {len(text.split())} words")
        """ + "\n"),
        ("shout.js", """
        #!/usr/bin/env node
        // Repeats its arguments (or its input) in capitals
        //
        // Input: Words to shout
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
        #
        # Input (optional): A folder (your Downloads unless set)
        set -eu

        dir="${1:-$HOME/Downloads}"
        if [ ! -d "$dir" ]; then
          echo "There's no folder $dir" >&2
          exit 1
        fi
        find "$dir" -maxdepth 1 -type f -exec du -h {} + 2>/dev/null | sort -rh | head -5
        """ + "\n"),
        ("backup-folder.sh", #"""
        #!/bin/bash
        # Zips a folder (your Documents unless one is named) into ~/Backups, dated, and says how big it came out
        #
        # Input (optional): A folder to back up (your Documents unless set)
        set -euo pipefail

        src="${1:-$HOME/Documents}"
        src="${src%/}"
        if [ ! -d "$src" ]; then echo "There's no folder $src" >&2; exit 1; fi
        mkdir -p "$HOME/Backups"
        name="$(basename "$src") $(date '+%Y-%m-%d %H.%M').zip"
        dest="$HOME/Backups/$name"
        echo "Zipping ${src}…" >&2
        (cd "$(dirname "$src")" && zip -qr -y "$dest" "$(basename "$src")" -x '*.DS_Store')
        size=$(du -h "$dest" | cut -f1)
        echo "Backed up to ~/Backups/$name ($size)."
        """# + "\n"),
        ("top-processes.sh", #"""
        #!/bin/bash
        # What's working this Mac hardest right now: the five programs using the most CPU, and the five using the most memory
        set -euo pipefail

        echo "Most CPU:"
        ps -Ao pcpu=,comm= | sort -rn | head -5 | awk '{ cpu=$1; $1=""; sub(/^ +/, ""); n=split($0, p, "/"); printf "  %5.1f%%  %s\n", cpu, p[n] }'
        echo "Most memory:"
        ps -Ao rss=,comm= | sort -rn | head -5 | awk '{ mb=$1/1024; $1=""; sub(/^ +/, ""); n=split($0, p, "/"); printf "  %6.0f MB  %s\n", mb, p[n] }'
        """# + "\n"),
        ("recent-files.sh", #"""
        #!/bin/bash
        # The files you changed most recently (the last day unless you say how many days), newest first, in your home folder
        #
        # Input (optional): How many days back (1 unless set)
        set -euo pipefail

        days="${1:-1}"
        case "$days" in *[!0-9]*|"") echo "Give a number of days: recent-files 3" >&2; exit 1 ;; esac
        # Library, hidden folders and node_modules are skipped (what apps keep for themselves, not what you changed).
        find "$HOME" \( -path "$HOME/Library" -o -name '.*' -o -name node_modules \) -prune -o -type f -mtime "-$days" -print 2>/dev/null \
          | head -2000 \
          | tr '\n' '\0' | xargs -0 stat -f '%m %N' 2>/dev/null \
          | sort -rn | head -20 | cut -d' ' -f2- | sed "s|^$HOME|~|"
        """# + "\n"),
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
