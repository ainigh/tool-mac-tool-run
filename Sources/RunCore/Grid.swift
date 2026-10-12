import Foundation

/// How a grid is set up: how many cells it shows at once, the order you put the scripts in, their
/// colors and the arguments each is run with. Kept per grid, in Application Support.
public struct GridSettings: Codable, Equatable, Sendable {
    /// Cells shown at once (a page); more scripts than that go on further pages.
    public var cells: Int
    /// File names in the order you arranged them; scripts not in it come after, by name.
    public var order: [String]
    /// The color each cell wears (an index into `GridSettings.tints`).
    public var tints: [String: Int]
    /// The arguments each script is run with when its cell is clicked, as typed in a terminal.
    public var arguments: [String: String]
    /// The page showing.
    public var page: Int

    public static let minCells = 1
    public static let maxCells = 64
    public static let defaultCells = 12

    public init(cells: Int = GridSettings.defaultCells, order: [String] = [], tints: [String: Int] = [:],
                arguments: [String: String] = [:], page: Int = 0) {
        self.cells = cells
        self.order = order
        self.tints = tints
        self.arguments = arguments
        self.page = page
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cells = min(max((try? c.decode(Int.self, forKey: .cells)) ?? Self.defaultCells, Self.minCells), Self.maxCells)
        order = (try? c.decode([String].self, forKey: .order)) ?? []
        tints = (try? c.decode([String: Int].self, forKey: .tints)) ?? [:]
        arguments = (try? c.decode([String: String].self, forKey: .arguments)) ?? [:]
        page = max(0, (try? c.decode(Int.self, forKey: .page)) ?? 0)
    }

    /// The light colors a cell can wear (as on the boards of Tool Mac Tool), red, green, blue 0–1.
    public static let tints: [(name: String, red: Double, green: Double, blue: Double)] = [
        ("paper", 0.98, 0.98, 0.97), ("butter", 1.00, 0.96, 0.76), ("sky", 0.84, 0.93, 1.00), ("mint", 0.85, 0.96, 0.85),
        ("rose", 1.00, 0.88, 0.89), ("lavender", 0.92, 0.88, 1.00), ("peach", 1.00, 0.91, 0.80), ("aqua", 0.84, 0.96, 0.95),
        ("pink", 1.00, 0.84, 0.94), ("lime", 0.93, 0.97, 0.80), ("ice", 0.80, 0.90, 0.98), ("sand", 0.98, 0.93, 0.86),
    ]

    /// The color a script wears: the one picked, else one from its name (the same every time).
    public func tint(for id: String) -> Int {
        if let t = tints[id], Self.tints.indices.contains(t) { return t }
        return Self.stableTint(id)
    }

    /// A color from a name that's the same on every run and every Mac (not Swift's hashValue, which isn't).
    public static func stableTint(_ id: String) -> Int {
        var h: UInt32 = 2166136261
        for b in id.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return 1 + Int(h % UInt32(tints.count - 1))
    }

    /// The scripts in your order.
    public func arranged(_ items: [ScriptItem]) -> [ScriptItem] {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        var result: [ScriptItem] = []
        for id in order { if let item = byID[id], seen.insert(id).inserted { result.append(item) } }
        for item in items where !seen.contains(item.id) { result.append(item) }
        return result
    }

    /// Moves a script to another's place (the ones between shift along).
    public mutating func move(_ id: String, to target: String, among items: [ScriptItem]) {
        var ids = arranged(items).map(\.id)
        guard let from = ids.firstIndex(of: id), let to = ids.firstIndex(of: target), from != to else { return }
        ids.remove(at: from)
        ids.insert(id, at: to)
        order = ids
    }

    /// How many pages `count` scripts take, with a cell left for a new one on the last.
    public func pageCount(for count: Int) -> Int {
        max(1, Int((Double(count + 1) / Double(max(cells, 1))).rounded(.up)))
    }

    /// The page actually showing (the remembered one, if there are still that many).
    public func currentPage(for count: Int) -> Int { min(page, pageCount(for: count) - 1) }

    /// The scripts on the page showing.
    public func pageItems(_ items: [ScriptItem]) -> [ScriptItem] {
        let all = arranged(items)
        let start = currentPage(for: all.count) * cells
        guard start < all.count else { return [] }
        return Array(all[start..<min(start + cells, all.count)])
    }

    /// The setting's file for a grid.
    public static func url(for kind: GridKind) -> URL {
        AppPaths.support.appendingPathComponent("grid-\(kind.rawValue).json")
    }

    public static func load(_ kind: GridKind) -> GridSettings {
        guard let data = try? Data(contentsOf: url(for: kind)),
              let s = try? JSONDecoder().decode(GridSettings.self, from: data) else { return GridSettings() }
        return s
    }

    public func save(_ kind: GridKind) throws {
        try FileManager.default.createDirectory(at: AppPaths.support, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: Self.url(for: kind), options: .atomic)
    }
}

/// How the cells fill the grid: rows of cells closest to square, the gutter narrowing as there are more.
public enum GridLayout {
    /// How many cells go in each row, top to bottom: the layout whose cells come closest to
    /// square, with no row more than one cell shorter than the others.
    public static func rows(for count: Int, width: Double, height: Double) -> [Int] {
        let n = max(count, 1)
        let w = max(width, 1), h = max(height, 1)
        var best: (rows: Int, score: Double) = (1, .infinity)
        for rows in 1...n {
            let columns = Int((Double(n) / Double(rows)).rounded(.up))
            if (rows - 1) * columns >= n { continue }  // leaves a row empty: same as fewer rows
            // Cells a little wider than tall read best (a title and a line under it).
            let aspect = (w / Double(columns)) / (h / Double(rows)) / 1.4
            let score = abs(log(aspect))
            if score < best.score - 1e-9 { best = (rows, score) }
        }
        let base = n / best.rows, extra = n % best.rows
        return (0..<best.rows).map { $0 < extra ? base + 1 : base }
    }

    /// The space between cells, in points: wide with a few, narrow with many.
    public static func gutter(for count: Int) -> Double {
        max(4, 16 - 2 * Double(max(count, 1)).squareRoot())
    }
}

/// Where the app keeps its own things (not your scripts).
public enum AppPaths {
    public static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("ToolMacToolRun", isDirectory: true)
    }
}
