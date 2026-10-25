import AppKit
import RunCore
import SwiftUI

/// The boards that aren't grids, in the order the panel and the switcher show them, each with its
/// title, look and key: API ⌘5, Library ⌘6, Memory ⌘7, Mind ⌘8, System Docs ⌘9.
enum Board: String, CaseIterable {
    case api, library, memory, mind, systemDocs

    var title: String {
        switch self {
        case .api: "API"
        case .library: "Library"
        case .memory: "Memory"
        case .mind: "Mind"
        case .systemDocs: "System Docs"
        }
    }

    /// Its name on the switcher (kept short: ten of them share a line).
    var short: String { self == .systemDocs ? "Docs" : title }

    @MainActor var symbol: String {
        switch self {
        case .api: APIBoardView.symbol
        case .library: "books.vertical.fill"
        case .memory: "brain.head.profile"
        case .mind: "point.3.filled.connected.trianglepath.dotted"
        case .systemDocs: "book.closed.fill"
        }
    }

    @MainActor var colors: [Color] {
        switch self {
        case .api: APIBoardView.colors
        case .library: [Color(red: 0.36, green: 0.55, blue: 0.27), Color(red: 0.16, green: 0.50, blue: 0.47)]
        case .memory: [Color(red: 0.85, green: 0.38, blue: 0.55), Color(red: 0.62, green: 0.30, blue: 0.80)]
        case .mind: [Color(red: 0.42, green: 0.36, blue: 0.92), Color(red: 0.20, green: 0.62, blue: 0.86)]
        case .systemDocs: [Color(red: 0.45, green: 0.47, blue: 0.52), Color(red: 0.27, green: 0.33, blue: 0.45)]
        }
    }

    /// Its key, with ⌘: after the grids' (⌘0 for the tenth).
    var key: Character {
        let n = GridKind.allCases.count + (Board.allCases.firstIndex(of: self) ?? 0) + 1
        return Character(String(n % 10))
    }

    /// The shelf it shows, for the boards that show one.
    var shelf: Shelf? {
        switch self {
        case .library: .library
        case .memory: .memory
        case .systemDocs: .systemDocs
        default: nil
        }
    }

    @MainActor func show() {
        switch self {
        case .api: Windows.showAPIBoard()
        case .library, .memory, .systemDocs: Windows.showShelfBoard(shelf!)
        case .mind: Windows.showMindBoard()
        }
    }

    static func of(_ shelf: Shelf) -> Board {
        switch shelf {
        case .library: .library
        case .memory: .memory
        case .systemDocs: .systemDocs
        }
    }
}
