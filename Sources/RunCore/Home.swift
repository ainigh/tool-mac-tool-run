import Foundation

/// TOOL-MAC-RUN on the Desktop: the app's own folder, holding SYSTEM-DOCS (how it works). The
/// person's library, MEMORY and the mind are Storage Spaces' now (`StorageSpaces`), in its USER
/// space. `TMR_HOME` puts TOOL-MAC-RUN elsewhere (a test, or a home kept in the cloud); each
/// shelf's own variable (`TMR_LIBRARY`…) puts that one elsewhere.
public enum Home {
    public static let folderName = "TOOL-MAC-RUN"

    public static var root: URL {
        if let path = ProcessInfo.processInfo.environment["TMR_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    /// A folder in it, or where `variable` says.
    static func folder(_ name: String, variable: String) -> URL {
        if let path = ProcessInfo.processInfo.environment[variable], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return root.appendingPathComponent(name, isDirectory: true)
    }

    /// How a folder is said to the person: ~/Desktop/STORAGE-SPACES/USER/MEMORY.
    public static func short(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
    }
}

/// Storage Spaces (github.com/ainigh/tool-mac-tool-run-storage-spaces): the app that keeps what
/// the apps on this Mac keep, a space each. The person's space, USER, holds the library, MEMORY and
/// the mind that used to be in TOOL-MAC-RUN: this app reads and writes them there, the same files
/// Storage Spaces serves to the other apps on 127.0.0.1:8771 (and watches, so they hear of what
/// changed). `STORAGE_HOME` puts STORAGE-SPACES elsewhere, as it does for Storage Spaces.
public enum StorageSpaces {
    public static let folderName = "STORAGE-SPACES"
    public static let url = "http://127.0.0.1:8771"

    /// ~/Desktop/STORAGE-SPACES, or `STORAGE_HOME`.
    public static var root: URL {
        if let path = ProcessInfo.processInfo.environment["STORAGE_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    /// The person's space: LIBRARY, MEMORY and MIND.
    public static var user: URL { root.appendingPathComponent("USER", isDirectory: true) }

    /// A folder in the person's space, or where `variable` says.
    static func folder(_ name: String, variable: String) -> URL {
        if let path = ProcessInfo.processInfo.environment[variable], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return user.appendingPathComponent(name, isDirectory: true)
    }

    /// Brings LIBRARY, MEMORY and MIND over from TOOL-MAC-RUN, once: each one that's in
    /// TOOL-MAC-RUN and not in STORAGE-SPACES yet is moved there whole (a rename: the same files,
    /// nothing copied, nothing lost). One already in STORAGE-SPACES (Storage Spaces copied it in,
    /// or it was made there) is kept, and any note of TOOL-MAC-RUN's it doesn't have is copied
    /// into it (the mind isn't merged). A line in TOOL-MAC-RUN says where they went, and marks it
    /// done: it's never done again (a note deleted in STORAGE-SPACES stays deleted). Returns what
    /// was moved or copied ("LIBRARY", "MEMORY/PEOPLE").
    @discardableResult
    public static func moveIn(from home: URL = Home.root, to user: URL = StorageSpaces.user) -> [String] {
        let fm = FileManager.default
        let note = home.appendingPathComponent("WHERE-THE-LIBRARY-WENT.md")
        guard !fm.fileExists(atPath: note.path) else { return [] }
        var moved: [String] = []
        for name in ["LIBRARY", "MEMORY", "MIND"] {
            let old = home.appendingPathComponent(name, isDirectory: true), new = user.appendingPathComponent(name, isDirectory: true)
            guard fm.fileExists(atPath: old.path) else { continue }
            if !fm.fileExists(atPath: new.path) {
                do {
                    try fm.createDirectory(at: user, withIntermediateDirectories: true)
                    try fm.moveItem(at: old, to: new)
                    moved.append(name)
                } catch {}
                continue
            }
            guard name != "MIND" else { continue }
            let files = (try? fm.contentsOfDirectory(atPath: old.path)) ?? []
            for f in files.sorted() where f.hasSuffix(".md") && !f.hasPrefix(".") && !fm.fileExists(atPath: new.appendingPathComponent(f).path) {
                if (try? fm.copyItem(at: old.appendingPathComponent(f), to: new.appendingPathComponent(f))) != nil {
                    moved.append("\(name)/\(String(f.dropLast(3)))")
                }
            }
        }
        if !moved.isEmpty || ["LIBRARY", "MEMORY", "MIND"].contains(where: { fm.fileExists(atPath: user.appendingPathComponent($0).path) }) {
            let text = """
            # Where the library, MEMORY and the mind went

            The library, MEMORY and the mind are in \(Home.short(user)) now (Storage Spaces' USER space)\(moved.isEmpty ? "" : "; brought over: " + moved.joined(separator: ", ")). Tool Mac Tool Run reads and writes them there, and Storage Spaces serves them to the other apps (github.com/ainigh/tool-mac-tool-run-storage-spaces).

            """
            try? Data(text.utf8).write(to: note, options: .atomic)
        }
        return moved
    }
}

/// The app's shelves of Markdown files, each known by its names alone (as the library is): the
/// LIBRARY (your notes) and MEMORY (what's remembered, a file for each kind of thing, each a node
/// of the mind), in Storage Spaces' USER space; and SYSTEM-DOCS (how the app works, for you and
/// for the models that use it; it can't be changed), in TOOL-MAC-RUN.
public enum Shelf: String, CaseIterable, Sendable {
    case library
    case memory
    case systemDocs = "system-docs"

    public var folderName: String {
        switch self {
        case .library: "LIBRARY"
        case .memory: "MEMORY"
        case .systemDocs: "SYSTEM-DOCS"
        }
    }

    public var title: String {
        switch self {
        case .library: "Library"
        case .memory: "Memory"
        case .systemDocs: "System Docs"
        }
    }

    /// How it's named in a sentence: "the library", "MEMORY", "SYSTEM-DOCS".
    public var place: String { self == .library ? "the library" : folderName }

    /// What a file on it is called.
    public var noun: String {
        switch self {
        case .library: "note"
        case .memory: "memory file"
        case .systemDocs: "doc"
        }
    }

    var variable: String {
        switch self {
        case .library: "TMR_LIBRARY"
        case .memory: "TMR_MEMORY"
        case .systemDocs: "TMR_SYSTEM_DOCS"
        }
    }

    /// Its files can't be changed (SYSTEM-DOCS: the app writes them).
    public var readOnly: Bool { self == .systemDocs }

    /// Its routes: /api/library, /api/memory, /api/system-docs.
    public var apiPath: String { "/api/" + rawValue }

    public var root: URL {
        self == .systemDocs ? Home.folder(folderName, variable: variable) : StorageSpaces.folder(folderName, variable: variable)
    }

    /// It's Storage Spaces' (the library and MEMORY), not this app's own.
    public var inStorageSpaces: Bool { self != .systemDocs }

    /// The shelf a word means: library, memory, system-docs (or system docs, docs).
    public init?(word: String) {
        let w = word.lowercased().replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: " ", with: "-")
        switch w {
        case "library", "lib", "notes": self = .library
        case "memory", "memories": self = .memory
        case "system-docs", "systemdocs", "docs", "system": self = .systemDocs
        default: return nil
        }
    }
}
