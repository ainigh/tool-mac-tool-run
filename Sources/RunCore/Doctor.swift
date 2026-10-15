import Foundation

/// "Is everything OK?": a look at the folder and the programs the scripts need, changing nothing.
public enum Doctor {
    public struct Line: Identifiable, Equatable, Sendable {
        public enum Status: String, Sendable {
            case ok, warning, problem
            public var mark: String { self == .ok ? "✅" : self == .warning ? "⚠️" : "❌" }
        }
        public var id: String { title }
        public var status: Status
        public var title: String
        public var detail: String?
        public var fix: String?
        /// A script in the folder that does the fix (Check Setup offers to run it).
        public var run: String? = nil
    }

    /// The folder (there, writable, its composer folder) and, for each language used in it, the
    /// program that runs it. `library` nil: no folder chosen yet.
    public static func check(_ library: Library?, environment: ShellEnvironment = .shared) -> [Line] {
        var lines: [Line] = []
        guard let library else {
            return [Line(status: .problem, title: "No scripts folder chosen yet", detail: nil,
                         fix: "Open a grid and pick a folder (or use ~/Scripts, which it makes for you).")]
        }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: library.root.path, isDirectory: &isDir), isDir.boolValue {
            let writable = fm.isWritableFile(atPath: library.root.path)
            lines.append(Line(status: writable ? .ok : .warning, title: "Scripts folder: \(library.root.path)",
                              detail: writable ? nil : "It can't be written to, so new scripts can't be saved there.",
                              fix: writable ? nil : "Pick a folder of your own, or change its permissions in the Finder (Get Info)."))
        } else {
            lines.append(Line(status: .problem, title: "Scripts folder missing: \(library.root.path)",
                              detail: "It may have been moved, renamed or be on a disk that isn't connected.",
                              fix: "Choose the folder again (Change folder…), or make it: mkdir -p \(ShellEnvironment.quote(library.root.path))"))
            return lines
        }
        let scripts = library.scripts()
        let flows = library.flows()
        lines.append(Line(status: .ok, title: "\(scripts.count) script\(scripts.count == 1 ? "" : "s"), \(flows.count) flow\(flows.count == 1 ? "" : "s")",
                          detail: nil, fix: nil))
        // Each language, and each program its scripts are run by: the one their #! line names, or
        // the language's own.
        struct Need: Hashable { var language: ScriptLanguage; var program: String }
        var used: [Need: (count: Int, found: String?)] = [:]
        let path = environment.environment["PATH"] ?? ""
        for s in scripts {
            guard let need = ScriptProcess.requirement(script: s.url, language: s.language, path: path) else { continue }
            let key = Need(language: s.language, program: need.program)
            used[key] = ((used[key]?.count ?? 0) + 1, need.found)
        }
        let order = ScriptLanguage.allCases
        for (need, use) in used.sorted(by: { a, b in
            a.key.language == b.key.language ? a.key.program < b.key.program
                : order.firstIndex(of: a.key.language)! < order.firstIndex(of: b.key.language)!
        }) {
            let n = use.count
            if let found = use.found {
                lines.append(Line(status: .ok, title: "\(need.language.title) (\(n)): \(need.program)", detail: found, fix: nil))
            } else {
                lines.append(Line(status: .problem, title: "\(need.language.title) (\(n)): \(need.program) not found",
                                  detail: "\(n) script\(n == 1 ? "" : "s") can't run until it's installed.",
                                  fix: need.program.hasPrefix("/") ? Remedy.interpreter(need.program) : Remedy.install(need.program)))
            }
        }
        lines += epa(library, flows: flows, path: path)
        for flow in flows {
            guard let source = try? String(contentsOf: flow.url, encoding: .utf8) else { continue }
            do {
                _ = try Flow.check(source, scripts: LocalFlowHost.names(in: library))
            } catch let e as FlowError {
                lines.append(Line(status: .warning, title: "\(flow.id) has a mistake", detail: e.description, fix: "Open it with the pencil on its cell."))
            } catch {}
        }
        return lines
    }

    /// EPA: whether `epa` is there (and runs), and where its keys are. Only when it's in use or
    /// about to be: the recipes are in the folder, or a flow runs it.
    static func epa(_ library: Library, flows: [ScriptItem], path: String) -> [Line] {
        let using = flows.filter(\.usesEPA)
        guard !using.isEmpty || library.hasAnyEPARecipe || EPA.find(path: path) != nil else { return [] }
        var lines: [Line] = []
        let n = using.count
        let uses = n == 0 ? "" : " (\(n) flow\(n == 1 ? "" : "s") use\(n == 1 ? "s" : "") it)"
        if let program = EPA.find(path: path) {
            let p = ScriptProcess(shell: "exec \(ShellEnvironment.quote(program)) --version", workingDirectory: library.root)
            let r = try? p.runToEnd()
            let said = r?.out.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let r, r.ok, said.hasPrefix("epa v") {
                lines.append(Line(status: .ok, title: "EPA: \(said)\(uses)", detail: program, fix: nil))
            } else {
                lines.append(Line(status: .problem, title: "EPA is there but doesn't start\(uses)",
                                  detail: [said, r?.err.trimmingCharacters(in: .whitespacesAndNewlines)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"),
                                  fix: "Run setup-epa on the Scripts grid: it installs what EPA needs (Node.js 22 or newer) and updates it.",
                                  run: EPA.setupScript))
            }
        } else {
            lines.append(Line(status: n > 0 ? .problem : .warning, title: "EPA isn't set up yet\(uses)",
                              detail: "Flows run it as `epa`, which isn't on the scripts' PATH.", fix: EPA.setupFix, run: EPA.setupScript))
        }
        let keys = library.root.appendingPathComponent(EPA.keysFile)
        if let text = try? String(contentsOf: keys, encoding: .utf8) {
            let count = text.split(whereSeparator: \.isNewline).filter { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                return !t.hasPrefix("#") && t.contains("=")
            }.count
            lines.append(Line(status: .ok, title: "EPA keys: \(count) in \(keys.path)", detail: nil, fix: nil))
        } else {
            lines.append(Line(status: .warning, title: "No EPA keys yet (\(keys.path))",
                              detail: "EPA reads the keys for each service from there. Check Connections says which each one needs.",
                              fix: "Run epa-keys on the Scripts grid to make and open it.", run: "epa-keys.sh"))
        }
        return lines
    }
}
