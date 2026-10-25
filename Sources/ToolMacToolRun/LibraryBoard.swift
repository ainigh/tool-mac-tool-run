import AppKit
import Combine
import RunCore
import SwiftUI

/// What a shelf's board shows and does: the files in its folder in STORAGE-SPACES/USER (by name, without
/// .md), the one open, a search across them all, and its own Trash. The Library is your notes;
/// MEMORY is what's remembered (each file a node of the mind, kept so as the files change); SYSTEM-
/// DOCS is how the app works, read only. The same shelves the API serves (`/api/library`,
/// `/api/memory`, `/api/system-docs`), so they're read again often: another app may have just
/// written a file.
@MainActor
final class LibraryBoardModel: ObservableObject {
    let shelf: Shelf
    let library: FileLibrary
    /// MEMORY's files and the mind (on MEMORY's board).
    let memory: Memory?

    @Published private(set) var notes: [FileLibrary.Note] = []
    @Published private(set) var trash: [FileLibrary.Trashed] = []
    /// The search's results (nil: no search).
    @Published private(set) var hits: [FileLibrary.Hit]?
    @Published var search = "" { didSet { find() } }
    /// The file open on the right.
    @Published private(set) var open: String?
    /// Its text as it's being edited, and as it was last read or saved.
    @Published var text = ""
    @Published private(set) var saved = ""
    @Published var problem: String?
    /// On MEMORY: how many things the mind files under each file.
    @Published private(set) var members: [String: Int] = [:]

    init(shelf: Shelf) {
        self.shelf = shelf
        library = FileLibrary(shelf: shelf)
        memory = shelf == .memory ? Memory(files: FileLibrary(shelf: .memory)) : nil
    }

    var changed: Bool { open != nil && text != saved && !shelf.readOnly }

    /// Reads the folder again (and the open file, unless it's being edited).
    func reload() {
        notes = shelf == .systemDocs ? library.list(sort: .name) : library.list(sort: .modified)
        trash = shelf.readOnly ? [] : library.trash()
        if let memory, folderExists {
            // A file dropped in the folder from the Finder becomes a node too.
            _ = try? memory.mind.index(library, who: "the Memory board")
            members = Dictionary(uniqueKeysWithValues: notes.map { ($0.name, memory.members(of: $0.name).count) })
        }
        if let name = open {
            if library.find(name) == nil {
                // Deleted or renamed elsewhere: its text stays here, to save again if wanted.
                if !changed { open = nil }
            } else if !changed, let now = try? library.read(name).text, now != saved {
                text = now
                saved = now
            }
        }
        if !search.isEmpty { find() }
    }

    func select(_ name: String) {
        if changed { save() }
        do {
            let r = try library.read(name)
            open = r.note.name
            text = r.text
            saved = r.text
            problem = nil
        } catch {
            problem = "\(error)"
        }
    }

    func close() {
        if changed { save() }
        open = nil
        text = ""
        saved = ""
    }

    func save() {
        guard let name = open, !shelf.readOnly else { return }
        do {
            try library.write(name, text)
            saved = text
            notes = library.list(sort: .modified)
            if let memory { _ = try memory.mind.index(library, who: "the Memory board") }
        } catch {
            problem = "\(error)"
        }
    }

    func revert() { text = saved }

    /// A new file, opened: its name as its heading.
    func create(_ name: String) {
        do {
            let key = try library.key(name)
            try library.write(key, "# \(key)\n\n", mode: .create)
            if let memory { _ = try memory.mind.index(library, who: "the Memory board") }
            reload()
            select(key)
        } catch {
            problem = "\(error)"
        }
    }

    func rename(_ name: String, to new: String) {
        if open == name, changed { save() }
        do {
            let n = try library.rename(name, to: new)
            if let memory { _ = try memory.mind.renamed(name, to: n.name, who: "the Memory board") }
            if open == name { open = n.name }
            reload()
        } catch {
            problem = "\(error)"
        }
    }

    func duplicate(_ name: String) {
        var copy = "\(name) copy"
        var k = 2
        while library.exists(copy) {
            copy = "\(name) copy \(k)"
            k += 1
        }
        do {
            try library.copy(name, to: copy)
            reload()
        } catch {
            problem = "\(error)"
        }
    }

    func delete(_ name: String) {
        do {
            try library.delete(name)
            if open == name {
                open = nil
                text = ""
                saved = ""
            }
            reload()
        } catch {
            problem = "\(error)"
        }
    }

    func restore(_ t: FileLibrary.Trashed) {
        do {
            // Under its own name, else "name (restored)", "name (restored 2)"…
            var name = t.name
            var k = 1
            while library.exists(name) {
                name = k == 1 ? "\(t.name) (restored)" : "\(t.name) (restored \(k))"
                k += 1
            }
            let n = try library.restore(t.name, number: t.number, as: name)
            reload()
            select(n.name)
        } catch {
            problem = "\(error)"
        }
    }

    func emptyTrash() {
        do {
            try library.emptyTrash()
            reload()
        } catch {
            problem = "\(error)"
        }
    }

    /// Makes the folder (the board's first run): MEMORY with its files, SYSTEM-DOCS from the app.
    func makeFolder() {
        do {
            switch shelf {
            case .library: try library.ensure()
            case .memory: try memory?.ensure()
            case .systemDocs: try AppModel.installSystemDocs()
            }
            reload()
        } catch {
            problem = "\(error)"
        }
    }

    /// Puts back MEMORY's own files that aren't there.
    func addDefaults() {
        do {
            let added = try memory?.addDefaults() ?? []
            problem = added.isEmpty ? "Every file MEMORY comes with is there already." : nil
            reload()
        } catch {
            problem = "\(error)"
        }
    }

    var folderExists: Bool { FileManager.default.fileExists(atPath: library.root.path) }

    private func find() {
        let q = search.trimmingCharacters(in: .whitespaces)
        hits = q.isEmpty ? nil : library.search(q, .init(lines: 3))
    }
}

/// A shelf's board: every file, a tile each (the latest changed first; SYSTEM-DOCS A to Z), the
/// one open beside them (to edit; on SYSTEM-DOCS, to read, with copy buttons), a search across
/// every file's text, and the shelf's own Trash (deleted files wait there, numbered, to be
/// restored). It looks like the other boards on purpose, and fills 90% of the screen as they do.
struct LibraryBoardView: View {
    @ObservedObject var app: AppModel
    @StateObject private var model: LibraryBoardModel
    @State private var naming = false
    @State private var newName = ""
    @State private var renaming: String?
    @State private var showTrash = false
    @State private var confirmEmpty = false
    /// On SYSTEM-DOCS: the open doc as it's written, not laid out.
    @State private var raw = false

    static let symbol = Board.library.symbol
    static let colors = Board.library.colors

    init(app: AppModel, shelf: Shelf = .library) {
        self.app = app
        _model = StateObject(wrappedValue: LibraryBoardModel(shelf: shelf))
    }

    private var shelf: Shelf { model.shelf }
    private var board: Board { Board.of(shelf) }
    private var colors: [Color] { board.colors }
    private var noun: String { shelf.noun }

    /// Reads the folder again every few seconds (another app may be writing in it).
    private let tick = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    header
                        .padding(.horizontal, 24)
                        .padding(.top, 34)
                        .padding(.bottom, 12)
                    if let problem = model.problem { problemBar(problem) }
                    if !model.folderExists {
                        firstRun
                    } else if showTrash {
                        trashList
                    } else {
                        tiles
                    }
                    footer
                }
                if model.open != nil {
                    Group {
                        if shelf.readOnly { reader } else { editor }
                    }
                    .frame(width: min(shelf.readOnly ? 860 : 720, max(420, geo.size.width * (shelf.readOnly ? 0.55 : 0.42))))
                    .padding(.top, 30)
                    .padding(.trailing, 20)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        .background(Backdrop())
        .onAppear {
            model.reload()
            // SYSTEM-DOCS opens on where to start.
            if shelf == .systemDocs, model.open == nil, model.library.exists("START-HERE") { model.select("START-HERE") }
        }
        .onReceive(tick) { _ in model.reload() }
        .sheet(isPresented: $naming) { nameSheet }
        .sheet(item: Binding(get: { renaming.map(RenameTarget.init) }, set: { renaming = $0?.id })) { target in
            RenameSheet(name: target.id, library: model.library) { new in
                renaming = nil
                model.rename(target.id, to: new)
            } cancel: {
                renaming = nil
            }
        }
        .alert("Empty \(shelf.place)'s Trash?", isPresented: $confirmEmpty) {
            Button("Empty the Trash", role: .destructive) { model.emptyTrash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The \(model.trash.count) \(noun)\(model.trash.count == 1 ? "" : "s") in it are deleted for good: they can't be restored after.")
        }
    }

    // MARK: the top

    private var header: some View {
        HStack(spacing: 14) {
            IconTile(symbol: board.symbol, color: colors[0], size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(board.title)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            searchField
            if !shelf.readOnly {
                Button {
                    newName = ""
                    naming = true
                } label: { Label(shelf == .library ? "New Note" : "New File", systemImage: "plus") }
                    .buttonStyle(ProminentButtonStyle(color: colors[0]))
                    .help("A new \(noun) in \(shelf.place) (⌘N)")
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(!model.folderExists)
            }
            BoardSwitcher(current: board.rawValue, app: app)
        }
    }

    private var subtitle: String {
        let n = model.notes.count
        let place = Home.short(model.library.root)
        guard model.folderExists else { return "\(place) isn't there yet" }
        let count = "\(n) \(noun)\(n == 1 ? "" : "s") in \(place)"
        switch shelf {
        case .library: return count + ", by name; other apps reach them over the API without asking"
        case .memory: return count + ", each a node of the mind; other apps remember and recall through the API"
        case .systemDocs: return count + ": how the app works, for you and for models; read only"
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(shelf == .systemDocs ? "Search the docs" : "Search every \(noun)", text: $model.search)
                .textFieldStyle(.plain)
            if !model.search.isEmpty {
                Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .help("Clear the search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(minWidth: 160, idealWidth: 240, maxWidth: 280)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.06)))
        .help("Finds the \(noun)s with every one of your words in their name or text (a \"phrase\" in quotes); accents and case don't matter")
    }

    private func problemBar(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).lineLimit(3)
            Spacer(minLength: 8)
            Button { model.problem = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(CircleIconButtonStyle(size: 22))
                .help("Dismiss")
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.12)))
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
    }

    /// With no folder yet: what it is, and the one click that makes it.
    private var firstRun: some View {
        VStack(spacing: 14) {
            Spacer()
            IconTile(symbol: board.symbol, color: colors[0], size: 64)
            Text(firstRunTitle)
                .font(.title2.weight(.semibold))
            Text(firstRunText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
            Button("Make \(shelf.folderName)") { model.makeFolder() }
                .buttonStyle(ProminentButtonStyle(color: colors[0], large: true))
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    private var firstRunTitle: String {
        switch shelf {
        case .library: "A library of notes, on your Desktop"
        case .memory: "A memory, on your Desktop"
        case .systemDocs: "How the app works, on your Desktop"
        }
    }

    private var firstRunText: String {
        let place = Home.short(model.library.root)
        switch shelf {
        case .library:
            return "\(place) holds them: Markdown files, each known by its name alone (groceries is \(FileLibrary.folderName)/groceries.md). Write them here, in any editor, or from other apps through the API (/api/library), which answers without asking you each time. Deleting one moves it to the library's own Trash."
        case .memory:
            return "\(place) comes with a file for each kind of thing worth remembering: \(Memory.defaultNames.joined(separator: ", ")). Each is a node of the mind, which links what's in them. Other apps remember and recall through the API (/api/memory), without asking you each time."
        case .systemDocs:
            return "\(place) holds the app's guides, its API, and prompts and recipes for the models that use it. The app writes it (each time it starts); nobody changes it."
        }
    }

    // MARK: the files

    private var tiles: some View {
        ScrollView {
            if let hits = model.hits {
                hitList(hits)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            } else if model.notes.isEmpty {
                VStack(spacing: 8) {
                    Text("No \(noun)s yet").font(.title3.weight(.semibold))
                    Text(shelf.readOnly ? "They're written when the app starts." : "New makes one; so does any app writing to the API, or a file you drop in the folder.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 420), spacing: 10)], spacing: 10) {
                    ForEach(model.notes, id: \.name) { note in
                        NoteTile(note: note, open: model.open == note.name, color: colors[0], badge: badge(note.name)) { model.select(note.name) }
                            .contextMenu { menu(note.name) }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }

    /// What a tile says beside its name: on MEMORY, how many things the mind files under it.
    private func badge(_ name: String) -> String? {
        guard shelf == .memory else { return nil }
        let n = model.members[name] ?? 0
        return n == 0 ? (Memory.isDefault(name) ? "built in" : nil) : "\(n) in the mind"
    }

    private func hitList(_ hits: [FileLibrary.Hit]) -> some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            Text(hits.isEmpty ? "No \(noun) has “\(model.search)” in it." : "\(hits.count) \(noun)\(hits.count == 1 ? "" : "s") with “\(model.search)”, the best first")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(hits, id: \.note.name) { hit in
                Button { model.select(hit.note.name) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(hit.note.name).font(.headline)
                            Spacer()
                            Text(RunRecord.ago(hit.note.modified)).font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(Array(hit.lines.enumerated()), id: \.offset) { _, line in
                            HStack(alignment: .top, spacing: 6) {
                                Text("\(line.number)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 30, alignment: .trailing)
                                Text(line.text)
                                    .font(.callout)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(model.open == hit.note.name ? 0.09 : 0.035)))
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .contextMenu { menu(hit.note.name) }
            }
        }
    }

    @ViewBuilder
    private func menu(_ name: String) -> some View {
        Button("Open") { model.select(name) }
        Button("Show in a Window") { presentFile(name) }
        if !shelf.readOnly {
            Button("Rename…") { renaming = name }
            Button("Duplicate") { model.duplicate(name) }
        }
        if shelf == .memory {
            Button("Show in the Mind") { Windows.showMindBoard(select: name) }
        }
        Divider()
        Button("Open in Its App") { if let n = model.library.find(name) { NSWorkspace.shared.open(n.url) } }
        Button("Show in Finder") { if let n = model.library.find(name) { NSWorkspace.shared.activateFileViewerSelecting([n.url]) } }
        Button("Copy Its Text") { if let t = try? model.library.read(name).text { copy(t) } }
        Button("Copy Its Name") { copy(name) }
        if !shelf.readOnly {
            Divider()
            Button("Move to \(shelf == .library ? "the Library's" : shelf.folderName + "'s") Trash") { model.delete(name) }
        }
    }

    private func presentFile(_ name: String) {
        guard let r = try? model.library.read(name) else { return }
        PresentCenter.shared.show(Presentation(title: r.note.name, text: r.text, source: "\(shelf.folderName)/\(r.note.url.lastPathComponent)",
                                               shelf: shelf, name: r.note.name, client: "You"))
    }

    // MARK: the Trash

    private var trashList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(model.trash.isEmpty ? "\(shelf.folderName)'s Trash is empty." : "Deleted \(noun)s wait here, numbered, the latest first; Restore brings one back.")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !model.trash.isEmpty {
                        Button("Empty the Trash…") { confirmEmpty = true }
                            .buttonStyle(SoftButtonStyle(tint: .red))
                    }
                }
                ForEach(model.trash, id: \.url) { t in
                    HStack(spacing: 10) {
                        Image(systemName: "doc.text").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(t.name) (\(t.number))").font(.callout.weight(.semibold))
                            Text("deleted \(RunRecord.ago(t.deleted)) · \(ByteCountFormatter.string(fromByteCount: Int64(t.size), countStyle: .file))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Restore") { model.restore(t) }
                            .buttonStyle(SoftButtonStyle())
                            .help(model.library.exists(t.name) ? "There's a \(noun) called \(t.name) now: it comes back as \(t.name) (restored)" : "Back as \(t.name)")
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.035)))
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    // MARK: the file open

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.fill").foregroundStyle(colors[0])
                Text(model.open ?? "")
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                if model.changed {
                    Text("edited")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                Spacer()
                CopyButton(help: "Copy its text", size: 24) { model.text }
                Button { model.close() } label: { Image(systemName: "xmark") }
                    .buttonStyle(CircleIconButtonStyle(size: 24))
                    .help("Close it (saving what you changed)")
            }
            TextEditor(text: $model.text)
                .font(.system(size: 13, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
            HStack(spacing: 8) {
                Button("Save") { model.save() }
                    .buttonStyle(ProminentButtonStyle(color: colors[0]))
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!model.changed)
                Button("Revert") { model.revert() }
                    .buttonStyle(SoftButtonStyle())
                    .disabled(!model.changed)
                Spacer()
                if let name = model.open {
                    if shelf == .memory {
                        Button { Windows.showMindBoard(select: name) } label: { Image(systemName: Board.mind.symbol) }
                            .buttonStyle(CircleIconButtonStyle(size: 26))
                            .help("Show it in the mind: what's filed under it, and what it links to")
                    }
                    Button { presentFile(name) } label: { Image(systemName: "macwindow") }
                        .buttonStyle(CircleIconButtonStyle(size: 26))
                        .help("Show it in a window of its own, in front, with copy buttons")
                    Button { renaming = name } label: { Image(systemName: "pencil") }
                        .buttonStyle(CircleIconButtonStyle(size: 26))
                        .help("Rename it")
                    Button { if let n = model.library.find(name) { NSWorkspace.shared.open(n.url) } } label: { Image(systemName: "arrow.up.forward.app") }
                        .buttonStyle(CircleIconButtonStyle(size: 26))
                        .help("Open it in its app (your Markdown editor)")
                    Button { model.delete(name) } label: { Image(systemName: "trash") }
                        .buttonStyle(CircleIconButtonStyle(size: 26))
                        .help("Move it to \(shelf.place)'s Trash (Restore brings it back)")
                }
            }
            Text(wordCount)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.10), radius: 14, y: 5)
    }

    /// A doc open on SYSTEM-DOCS: laid out (or as written), with copy buttons for the whole, each
    /// section and each piece of code.
    private var reader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "book.closed.fill").foregroundStyle(colors[0])
                Text(model.open ?? "")
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Pill(text: "read only", symbol: "lock.fill")
                Spacer()
                Picker("", selection: $raw) {
                    Text("Laid Out").tag(false)
                    Text("As Written").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                CopyButton(help: "Copy the whole doc", size: 24) { model.text }
                Button { model.close() } label: { Image(systemName: "xmark") }
                    .buttonStyle(CircleIconButtonStyle(size: 24))
                    .help("Close it")
            }
            ScrollView {
                if raw {
                    Text(model.text)
                        .font(.system(size: 12.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                } else {
                    MarkdownDocument(text: model.text)
                        .padding(14)
                }
            }
            .id(model.open)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
            HStack(spacing: 8) {
                if let name = model.open {
                    Button { presentFile(name) } label: { Label("Show in a Window", systemImage: "macwindow") }
                        .buttonStyle(SoftButtonStyle())
                        .help("Show it in a window of its own, in front, with copy buttons")
                    Button { copy("\(APIService.shared.baseURL)/api/system-docs/files/\(name)") } label: { Label("Copy Its Address", systemImage: "link") }
                        .buttonStyle(SoftButtonStyle())
                        .help("Its address on the API, for an app or a model to read it")
                }
                Spacer()
                Text(wordCount)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.10), radius: 14, y: 5)
    }

    private var wordCount: String {
        let words = model.text.split(whereSeparator: \.isWhitespace).count
        let name = model.open ?? ""
        return "\(words) word\(words == 1 ? "" : "s") · \(shelf.folderName)/\(name).\(model.library.ext) · GET \(shelf.apiPath)/files/\(name)"
    }

    // MARK: the bottom

    private var footer: some View {
        HStack(spacing: 8) {
            if !shelf.readOnly {
                Button { showTrash.toggle() } label: {
                    Label(showTrash ? "Back to the \(noun.capitalized)s" : "Trash (\(model.trash.count))", systemImage: showTrash ? "chevron.left" : "trash")
                }
                .buttonStyle(SoftButtonStyle())
                .help("Deleted \(noun)s wait in \(shelf.place)'s own Trash, numbered, to be restored")
            }
            Button { NSWorkspace.shared.activateFileViewerSelecting([model.library.root]) } label: { Label("Show in Finder", systemImage: "folder") }
                .buttonStyle(SoftButtonStyle())
                .disabled(!model.folderExists)
            if shelf == .memory {
                Button { Windows.showMindBoard() } label: { Label("Open the Mind", systemImage: Board.mind.symbol) }
                    .buttonStyle(SoftButtonStyle())
                    .help("The mind links what's in these files: each file is a node of it")
                Button { model.addDefaults() } label: { Label("Put Back Its Files", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(SoftButtonStyle())
                    .help("Puts back any of the files MEMORY comes with (\(Memory.defaultNames.joined(separator: ", "))) that isn't there; changes nothing else")
            }
            Pill(text: "Click a \(noun) to open it", symbol: "cursorarrow.click")
            if !shelf.readOnly { Pill(text: "Right-click: rename, duplicate, delete", symbol: "contextualmenu.and.cursorarrow") }
            Spacer()
            Button { copy("\(APIService.shared.baseURL)\(shelf.apiPath)") } label: { Label("Copy the API's Address", systemImage: "link") }
                .buttonStyle(SoftButtonStyle())
                .help(apiHelp)
        }
        .font(.callout)
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var apiHelp: String {
        switch shelf {
        case .library: "Other apps list, read, write and search the notes at /api/library, without asking you each time (POST {\"op\": \"read\", \"name\": \"groceries\"})"
        case .memory: "Other apps remember and recall at /api/memory, without asking you each time (POST /api/memory/remember {\"category\": \"PEOPLE\", \"about\": \"Ada\"})"
        case .systemDocs: "Other apps and models read the docs at /api/system-docs (GET /api/system-docs/files/START-HERE)"
        }
    }

    // MARK: naming

    private var nameSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(shelf == .library ? "New Note" : "New File").font(.title3.weight(.semibold))
            Text(shelf == .memory ? "Its name is its file's name, without .md, and a node of the mind: words, with no @ and no -, | or = after a space."
                                  : "Its name is its file's name, without .md: any words but / and :.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField(shelf == .memory ? "RECIPES, PROJECTS, HEALTH…" : "groceries, Trip to Lagos, 2026-10-24…", text: $newName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { makeNote() }
            if let why = nameProblem(newName) {
                Text(why).font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { naming = false }
                    .keyboardShortcut(.cancelAction)
                Button("Make It") { makeNote() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(nameProblem(newName) != nil)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func makeNote() {
        guard nameProblem(newName) == nil else { return }
        naming = false
        model.create(newName)
    }

    /// Why a name can't be one (nil: it can).
    private func nameProblem(_ name: String) -> String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "" }
        do {
            let key = try model.library.key(name)
            return model.library.exists(key) ? "There's already a \(noun) called \(key)." : nil
        } catch let e as LibraryError {
            return e.message
        } catch {
            return "\(error)"
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A file, for the rename sheet (an item for `.sheet(item:)`).
private struct RenameTarget: Identifiable {
    let id: String
}

private struct RenameSheet: View {
    let name: String
    let library: FileLibrary
    let done: (String) -> Void
    let cancel: () -> Void
    @State private var typed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename \(name)").font(.title3.weight(.semibold))
            TextField("Its new name", text: $typed)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if ok { done(typed) } }
            HStack {
                Spacer()
                Button("Cancel") { cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { done(typed) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ok)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear { typed = name }
    }

    private var ok: Bool { (try? library.key(typed)) != nil && typed != name }
}

/// A file's tile: its name, its title (or first line), when it changed and how big it is.
private struct NoteTile: View {
    let note: FileLibrary.Note
    let open: Bool
    let color: Color
    var badge: String?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text.fill")
                        .foregroundStyle(color)
                    Text(note.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let badge {
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(color)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(color.opacity(0.12)))
                    }
                }
                if let title = note.title, title != note.name {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text("\(RunRecord.ago(note.modified)) · \(ByteCountFormatter.string(fromByteCount: Int64(note.size), countStyle: .file))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
            .background(shape.fill(Color.primary.opacity(open ? 0.10 : hover ? 0.07 : 0.035)))
            .overlay(shape.strokeBorder(open ? color.opacity(0.8) : Color.primary.opacity(hover ? 0.16 : 0.07), lineWidth: open ? 2 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(note.url.path)
    }
}

/// A Markdown document laid out, with copy buttons: each section (its heading's button copies the
/// heading and everything under it) and each piece of code.
struct MarkdownDocument: View {
    let text: String

    var body: some View {
        let sections = Self.sections(text)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(sections.indices), id: \.self) { s in
                SectionView(text: sections[s])
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The text cut at each heading of level 2 or more (outside code): a section each.
    static func sections(_ text: String) -> [String] {
        var out: [String] = []
        var current: [String] = []
        var fence = ""
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if fence.isEmpty, t.hasPrefix("```") || t.hasPrefix("~~~") {
                fence = String(t.prefix { $0 == t.first })
            } else if let c = fence.first, t.count >= fence.count, t.allSatisfy({ $0 == c }) {
                fence = ""
            }
            if fence.isEmpty, t.hasPrefix("##"), !current.isEmpty {
                out.append(current.joined(separator: "\n"))
                current = []
            }
            current.append(line)
        }
        if !current.isEmpty { out.append(current.joined(separator: "\n")) }
        return out
    }

    /// One section: its heading with a button that copies the whole section, then the rest.
    private struct SectionView: View {
        let text: String

        var body: some View {
            let blocks = MarkdownBlocks.parse(text)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(blocks.indices), id: \.self) { i in
                    if i == 0, Self.isSubheading(blocks[i]) {
                        HStack(alignment: .firstTextBaseline) {
                            BlockView(block: blocks[i])
                            Spacer(minLength: 8)
                            CopyButton(help: "Copy this section", size: 22) { text }
                        }
                    } else {
                        BlockView(block: blocks[i])
                    }
                }
            }
        }

        static func isSubheading(_ b: MarkdownBlocks.Block) -> Bool {
            if case let .heading(level, _) = b { return level >= 2 }
            return false
        }
    }
}
