import Foundation

/// TOOL-MAC-RUN on the Desktop: the one folder that holds the app's own shelves, a folder each
/// (LIBRARY, MEMORY, SYSTEM-DOCS, MIND), so they're found together and moved together.
/// `TMR_HOME` puts it elsewhere (a test, or a home kept in the cloud); each shelf's own variable
/// (`TMR_LIBRARY`…) puts that one elsewhere.
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

    /// How a folder is said to the person: ~/Desktop/TOOL-MAC-RUN/MEMORY.
    public static func short(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
    }
}

/// The app's shelves of Markdown files, each a folder in TOOL-MAC-RUN, each known by its names
/// alone (as the library is): the LIBRARY (your notes), MEMORY (what's remembered, a file for each
/// kind of thing, each a node of the mind) and SYSTEM-DOCS (how the app works, for you and for
/// the models that use it; it can't be changed).
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

    public var root: URL { Home.folder(folderName, variable: variable) }

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
