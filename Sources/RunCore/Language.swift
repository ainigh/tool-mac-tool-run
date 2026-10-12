import Foundation

/// The language a script is written in, told from its first line (`#!`), else its extension, else
/// what's in it. Each knows how it's run: the program and the arguments that go before the
/// script's path.
public enum ScriptLanguage: String, Codable, CaseIterable, Sendable {
    case bash, zsh, sh, fish
    case python, node, typescript, deno, ruby, perl, php, lua
    case swift, go, r, applescript, powershell
    /// A file that's run as it is (a compiled program, or one marked executable we can't place).
    case executable
    /// Not something we know how to run.
    case unknown

    /// The name shown on a cell.
    public var title: String {
        switch self {
        case .bash: "Bash"
        case .zsh: "Zsh"
        case .sh: "Shell"
        case .fish: "Fish"
        case .python: "Python"
        case .node: "JavaScript"
        case .typescript: "TypeScript"
        case .deno: "Deno"
        case .ruby: "Ruby"
        case .perl: "Perl"
        case .php: "PHP"
        case .lua: "Lua"
        case .swift: "Swift"
        case .go: "Go"
        case .r: "R"
        case .applescript: "AppleScript"
        case .powershell: "PowerShell"
        case .executable: "Program"
        case .unknown: "Unknown"
        }
    }

    /// A short tag for the cell's corner.
    public var badge: String {
        switch self {
        case .bash, .zsh, .sh, .fish: "sh"
        case .python: "py"
        case .node: "js"
        case .typescript: "ts"
        case .deno: "deno"
        case .ruby: "rb"
        case .perl: "pl"
        case .php: "php"
        case .lua: "lua"
        case .swift: "swift"
        case .go: "go"
        case .r: "R"
        case .applescript: "scpt"
        case .powershell: "ps1"
        case .executable: "bin"
        case .unknown: "?"
        }
    }

    /// The extension a new script in this language is saved with.
    public var fileExtension: String {
        switch self {
        case .bash, .sh: "sh"
        case .zsh: "zsh"
        case .fish: "fish"
        case .python: "py"
        case .node: "js"
        case .typescript, .deno: "ts"
        case .ruby: "rb"
        case .perl: "pl"
        case .php: "php"
        case .lua: "lua"
        case .swift: "swift"
        case .go: "go"
        case .r: "R"
        case .applescript: "applescript"
        case .powershell: "ps1"
        case .executable, .unknown: ""
        }
    }

    /// The program that runs it, and what goes before the script's path. `executable` runs the
    /// file itself; `unknown` has none.
    public var command: (program: String, leading: [String])? {
        switch self {
        case .bash: ("bash", [])
        case .zsh: ("zsh", [])
        case .sh: ("sh", [])
        case .fish: ("fish", [])
        case .python: ("python3", ["-u"])  // -u: its output arrives as it's printed, not at the end
        case .node: ("node", [])
        case .typescript: ("npx", ["--yes", "tsx"])
        case .deno: ("deno", ["run", "--allow-all"])
        case .ruby: ("ruby", [])
        case .perl: ("perl", [])
        case .php: ("php", [])
        case .lua: ("lua", [])
        case .swift: ("swift", [])
        case .go: ("go", ["run"])
        case .r: ("Rscript", [])
        case .applescript: ("osascript", [])
        case .powershell: ("pwsh", ["-File"])
        case .executable: nil
        case .unknown: nil
        }
    }

    /// The languages offered for a new script, most used first.
    public static let offered: [ScriptLanguage] = [.bash, .zsh, .python, .node, .typescript, .ruby, .perl, .php,
                                                   .lua, .swift, .go, .r, .applescript, .powershell, .fish]

    /// What a new script in this language starts as.
    public var template: String {
        switch self {
        case .bash: "#!/bin/bash\nset -euo pipefail\n\necho \"Hello from bash\"\n"
        case .zsh: "#!/bin/zsh\nset -euo pipefail\n\necho \"Hello from zsh\"\n"
        case .sh: "#!/bin/sh\nset -eu\n\necho \"Hello from sh\"\n"
        case .fish: "#!/usr/bin/env fish\n\necho \"Hello from fish\"\n"
        case .python: "#!/usr/bin/env python3\nimport sys\n\nprint(\"Hello from Python\", *sys.argv[1:])\n"
        case .node: "#!/usr/bin/env node\n\nconsole.log(\"Hello from JavaScript\", ...process.argv.slice(2));\n"
        case .typescript: "const args: string[] = process.argv.slice(2);\nconsole.log(\"Hello from TypeScript\", ...args);\n"
        case .deno: "#!/usr/bin/env -S deno run --allow-all\n\nconsole.log(\"Hello from Deno\", ...Deno.args);\n"
        case .ruby: "#!/usr/bin/env ruby\n\nputs \"Hello from Ruby #{ARGV.join(' ')}\"\n"
        case .perl: "#!/usr/bin/env perl\nuse strict;\nuse warnings;\n\nprint \"Hello from Perl @ARGV\\n\";\n"
        case .php: "<?php\n\necho \"Hello from PHP \" . implode(' ', array_slice($argv, 1)) . \"\\n\";\n"
        case .lua: "#!/usr/bin/env lua\n\nprint(\"Hello from Lua\", ...)\n"
        case .swift: "#!/usr/bin/env swift\nimport Foundation\n\nprint(\"Hello from Swift\", CommandLine.arguments.dropFirst().joined(separator: \" \"))\n"
        case .go: "package main\n\nimport (\n\t\"fmt\"\n\t\"os\"\n)\n\nfunc main() {\n\tfmt.Println(\"Hello from Go\", os.Args[1:])\n}\n"
        case .r: "#!/usr/bin/env Rscript\n\ncat(\"Hello from R\", commandArgs(trailingOnly = TRUE), \"\\n\")\n"
        case .applescript: "display notification \"Hello from AppleScript\" with title \"Tool Mac Tool Run\"\nreturn \"Hello from AppleScript\"\n"
        case .powershell: "#!/usr/bin/env pwsh\n\nWrite-Output \"Hello from PowerShell $args\"\n"
        case .executable, .unknown: ""
        }
    }

    /// The language of a script: its `#!` line first (what the system would use), then its
    /// extension, then a look at what's in it. `executableBit`: the file is marked executable
    /// (a file with nothing else to go on is then run as it is).
    public static func detect(fileName: String, contents: String?, executableBit: Bool = false) -> ScriptLanguage {
        if let contents, let lang = fromShebang(contents) { return lang }
        let ext = (fileName as NSString).pathExtension.lowercased()
        if let lang = byExtension[ext] { return lang }
        if let contents, let lang = sniff(contents) { return lang }
        return executableBit ? .executable : .unknown
    }

    static let byExtension: [String: ScriptLanguage] = [
        "sh": .bash, "bash": .bash, "command": .bash, "tool": .bash,
        "zsh": .zsh, "fish": .fish,
        "py": .python, "py3": .python, "pyw": .python,
        "js": .node, "mjs": .node, "cjs": .node,
        "ts": .typescript, "mts": .typescript,
        "rb": .ruby, "pl": .perl, "pm": .perl, "php": .php, "lua": .lua,
        "swift": .swift, "go": .go, "r": .r,
        "applescript": .applescript, "scpt": .applescript,
        "ps1": .powershell,
    ]

    /// The language a `#!` line names (`#!/bin/bash`, `#!/usr/bin/env python3`, `#!/usr/bin/env -S deno run`).
    static func fromShebang(_ contents: String) -> ScriptLanguage? {
        guard contents.hasPrefix("#!") else { return nil }
        let line = contents.prefix { $0 != "\n" }.dropFirst(2).trimmingCharacters(in: .whitespaces)
        var words = line.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return nil }
        var program = (words.removeFirst() as NSString).lastPathComponent
        if program == "env" {
            // env's own options (-S, -i, NAME=value) come before the program.
            while let w = words.first, w.hasPrefix("-") || w.contains("=") { words.removeFirst() }
            guard let next = words.first else { return nil }
            program = (next as NSString).lastPathComponent
        }
        return byProgram(program)
    }

    static func byProgram(_ program: String) -> ScriptLanguage? {
        let p = program.lowercased()
        switch p {
        case "bash": return .bash
        case "zsh": return .zsh
        case "sh", "dash", "ksh": return .sh
        case "fish": return .fish
        case "node", "nodejs", "bun": return .node
        case "tsx", "ts-node": return .typescript
        case "deno": return .deno
        case "ruby": return .ruby
        case "perl": return .perl
        case "php": return .php
        case "swift": return .swift
        case "rscript": return .r
        case "osascript": return .applescript
        case "pwsh", "powershell": return .powershell
        default: break
        }
        if p.hasPrefix("python") { return .python }
        if p.hasPrefix("lua") { return .lua }
        return nil
    }

    /// A guess from what's in a file with no `#!` and no extension we know.
    static func sniff(_ contents: String) -> ScriptLanguage? {
        let head = String(contents.prefix(2000))
        if head.hasPrefix("<?php") { return .php }
        if head.contains("package main") && head.contains("func main()") { return .go }
        if head.range(of: #"(?m)^\s*(import \w+|from \w+ import|def \w+\(.*\):)"#, options: .regularExpression) != nil { return .python }
        if head.range(of: #"(?m)^\s*(const|let|var) \w+ = require\(|console\.log\("#, options: .regularExpression) != nil { return .node }
        if head.range(of: #"(?m)^\s*(echo |set -e|export \w+=|if \[)"#, options: .regularExpression) != nil { return .bash }
        if head.range(of: #"(?m)^\s*(display (dialog|notification)|tell application)"#, options: .regularExpression) != nil { return .applescript }
        return nil
    }
}
