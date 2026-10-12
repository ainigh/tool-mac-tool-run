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
        var used: [ScriptLanguage: Int] = [:]
        for s in scripts { used[s.language, default: 0] += 1 }
        for lang in ScriptLanguage.allCases where used[lang] != nil {
            guard let cmd = lang.command else { continue }
            let n = used[lang] ?? 0
            if let path = environment.find(cmd.program) {
                lines.append(Line(status: .ok, title: "\(lang.title) (\(n)): \(cmd.program)", detail: path, fix: nil))
            } else {
                lines.append(Line(status: .problem, title: "\(lang.title) (\(n)): \(cmd.program) not found",
                                  detail: "\(n) script\(n == 1 ? "" : "s") can't run until it's installed.",
                                  fix: Remedy.install(cmd.program)))
            }
        }
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
}
