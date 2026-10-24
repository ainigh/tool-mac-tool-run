import Foundation

/// What a script looks like it does before it's run: something that can't be undone (so the app
/// asks first), or asking for typed input (so its run keeps a way to type an answer). Read from
/// its text, the same way every time; comment lines don't count. Behavior as data: a new danger is
/// a row in `dangers`, a new way of reading the keyboard a row in `prompts`.
public enum Caution {
    /// What each danger looks like, and what it does, in plain words.
    static let dangers: [(pattern: String, what: String)] = [
        (#"(^|[\s;&|("'`])rm\s+(-[A-Za-z]*[rRf][A-Za-z]*\s+|--(recursive|force)\s+)+"#, "deletes files for good (rm -r / rm -f)"),
        (#"(^|[\s;&|("'`])sudo\s"#, "runs commands as the administrator (sudo)"),
        (#"(^|[\s;&|("'`])dd\s+.*\bof="#, "writes straight onto a disk or file (dd)"),
        (#"(^|[\s;&|("'`])(mkfs|newfs_\w+)\b|diskutil\s+(erase\w*|partitionDisk|zeroDisk|secureErase|reformat)"#, "erases a disk"),
        (#"git\s+push\s+.*(--force|-f\b|--mirror)"#, "force-pushes with git (it can overwrite others' work)"),
        (#"git\s+(reset\s+--hard|clean\s+-[A-Za-z]*f)"#, "throws away git changes"),
        (#"(^|[\s;&|("'`])(shutdown|reboot|halt)\b"#, "shuts down or restarts the Mac"),
        (#"(^|[\s;&|("'`])(killall|pkill)\s"#, "quits running programs"),
        (#"(?i)\b(drop\s+(table|database|schema)|truncate\s+table)\b"#, "deletes database data"),
        (#"shutil\.rmtree|os\.(remove|unlink|rmdir)\(|fs\.(rmSync|rm|unlinkSync|rmdirSync)\(|FileUtils\.(rm_rf|rm_r|remove)|Remove-Item|File\.delete|unlink\("#, "deletes files"),
        (#"(curl|wget)\s[^|#]*\|\s*(sudo\s+)?(ba|z)?sh\b"#, "runs a script downloaded from the internet"),
        (#"(chmod|chown)\s+-R\b"#, "changes the permissions of many files at once"),
        (#"kubectl\s+delete|terraform\s+destroy|aws\s+\S+\s+(rm|delete|terminate)\S*|gcloud\s+.*\bdelete\b"#, "deletes cloud resources"),
        (#"(npm|yarn|pnpm)\s+publish|gem\s+push|twine\s+upload|cargo\s+publish"#, "publishes a package for everyone"),
        (#"osascript\s+.*empty\s+(the\s+)?trash|empty\s+the\s+trash"#, "empties the Trash"),
        // A Straw script's click on a button whose name says it can't be taken back.
        (#"(?i)^\s*click\s+(?:first\s+)?"[^"]*\b(delete|remove|send|buy|pay|purchase|place order|order now|checkout|publish|post|submit|transfer|unsubscribe|cancel subscription|close account)\b"#,
         "clicks a button on a web page that can't be taken back (Delete, Send, Buy, Publish…)"),
    ]

    /// How a script asks for a typed answer while it runs. The shell's `read` and `select` count in
    /// a shell script only (in Python, "read the page" is just words).
    static let shellPrompts: [String] = [
        #"(^|[\s;&|(!])read\s+(-[a-zA-Z]+\s+)*(-p\s+|[A-Za-z_])"#,  // bash, zsh: read -p "…" answer
        #"(^|[\s;&|("'`])select\s+\w+\s+in\b"#,                        // bash select menus
    ]
    static let pipedRead = #"\|\s*while\s+(IFS=\S*\s+)?read\b"#
    static let shells: Set<ScriptLanguage> = [.bash, .zsh, .sh, .fish, .executable, .unknown]

    static let prompts: [String] = [
        #"\binput\s*\("#, #"getpass"#,                                // Python
        #"\bgets\b"#,                                                 // Ruby
        #"\.question\s*\(|readline-sync|prompts?\s*\(\s*\{"#,         // Node
        #"Read-Host"#,                                                // PowerShell
        #"<STDIN>"#,                                                  // Perl
        #"fgets\s*\(\s*STDIN|readline\s*\("#,                         // PHP, R
        #"io\.read"#,                                                 // Lua
        #"readLine\s*\("#,                                            // Swift
        #"fmt\.Scan|bufio\.NewReader\(os\.Stdin\)"#,                  // Go
    ]

    /// The lines that are code (not comments, not the #! line).
    private static func code(_ contents: String) -> [Substring] {
        contents.split(whereSeparator: \.isNewline).filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return !(t.isEmpty || t.hasPrefix("#") || t.hasPrefix("//") || t.hasPrefix("--") || t.hasPrefix(";") || t.hasPrefix("'") || t.hasPrefix("REM "))
        }
    }

    private static func matches(_ pattern: String, _ line: Substring) -> Bool {
        line.range(of: pattern, options: .regularExpression) != nil
    }

    /// What in it looks like it can't be undone, each once, in the order they're listed (empty: nothing).
    public static func dangers(in contents: String) -> [String] {
        let lines = code(contents)
        return dangers.filter { d in lines.contains { matches(d.pattern, $0) } }.map(\.what)
    }

    /// Whether it looks like it asks for a typed answer while it runs. `language`: what it's
    /// written in (nil: anything). A Straw script never does: its `ask` is a question on the Mac.
    public static func asksForInput(_ contents: String, language: ScriptLanguage? = nil) -> Bool {
        if language == .straw { return false }
        // A read fed by a pipe (ls | while read -r f) reads the pipe, not the keyboard.
        let lines = code(contents).filter { !matches(pipedRead, $0) }
        let shell = language.map { shells.contains($0) } ?? true
        let rows = shell ? shellPrompts + prompts : prompts
        return rows.contains { p in lines.contains { matches(p, $0) } }
    }

    /// The script's text (its first 64 KB), for these.
    public static func text(of url: URL) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        let data = (try? h.read(upToCount: 64 * 1024)) ?? Data()
        if data.contains(0) { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
