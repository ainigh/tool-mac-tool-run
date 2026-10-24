import AppKit
import Combine
import RunCore
import SwiftUI

/// What the Library board shows and does: the notes in LIBRARY on the Desktop (by name, without
/// .md), the one open, a search across them all, and the library's own Trash. The same library
/// the API serves (`/api/library`) and flows reach (`libraryRead`…), so it's read again often:
/// another app may have just written a note.
@MainActor
final class LibraryBoardModel: ObservableObject {
    let library = FileLibrary()

    @Published private(set) var notes: [FileLibrary.Note] = []
    @Published private(set) var trash: [FileLibrary.Trashed] = []
    /// The search's results (nil: no search).
    @Published private(set) var hits: [FileLibrary.Hit]?
    @Published var search = "" { didSet { find() } }
    /// The note open on the right.
    @Published private(set) var open: String?
    /// Its text as it's being edited, and as it was last read or saved.
    @Published var text = ""
    @Published private(set) var saved = ""
    @Published var problem: String?

    var changed: Bool { open != nil && text != saved }

    /// Reads the folder again (and the open note, unless it's being edited).
    func reload() {
        notes = library.list(sort: .modified)
        trash = library.trash()
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
        guard let name = open else { return }
        do {
            try library.write(name, text)
            saved = text
            notes = library.list(sort: .modified)
        } catch {
            problem = "\(error)"
        }
    }

    func revert() { text = saved }

    /// A new note, opened: its name as its heading.
    func create(_ name: String) {
        do {
            let key = try FileLibrary.key(name)
            try library.write(key, "# \(key)\n\n", mode: .create)
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

    /// Makes LIBRARY on the Desktop (the board's first run).
    func makeFolder() {
        do {
            try library.ensure()
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

/// The Library board: every note in LIBRARY on the Desktop, a tile each (the latest changed
/// first), the one open beside them to read and edit, a search across every note's text, and the
/// library's own Trash (deleted notes wait there, numbered, to be restored). It looks like the
/// other boards on purpose, and fills 90% of the screen as they do.
struct LibraryBoardView: View {
    @ObservedObject var app: AppModel
    @StateObject private var model = LibraryBoardModel()
    @State private var naming = false
    @State private var newName = ""
    @State private var renaming: String?
    @State private var showTrash = false
    @State private var confirmEmpty = false

    static let symbol = "books.vertical.fill"
    static let colors = [Color(red: 0.36, green: 0.55, blue: 0.27), Color(red: 0.16, green: 0.50, blue: 0.47)]

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
                    editor
                        .frame(width: min(720, max(420, geo.size.width * 0.42)))
                        .padding(.top, 30)
                        .padding(.trailing, 20)
                        .padding(.bottom, 16)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        .background(Backdrop())
        .onAppear { model.reload() }
        .onReceive(tick) { _ in model.reload() }
        .sheet(isPresented: $naming) { nameSheet }
        .sheet(item: Binding(get: { renaming.map(RenameTarget.init) }, set: { renaming = $0?.id })) { target in
            RenameSheet(name: target.id) { new in
                renaming = nil
                model.rename(target.id, to: new)
            } cancel: {
                renaming = nil
            }
        }
        .alert("Empty the library's Trash?", isPresented: $confirmEmpty) {
            Button("Empty the Trash", role: .destructive) { model.emptyTrash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The \(model.trash.count) note\(model.trash.count == 1 ? "" : "s") in it are deleted for good: they can't be restored after.")
        }
    }

    // MARK: the top

    private var header: some View {
        HStack(spacing: 14) {
            IconTile(symbol: Self.symbol, color: Self.colors[0], size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text("Library")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            searchField
            Button {
                newName = ""
                naming = true
            } label: { Label("New Note", systemImage: "plus") }
                .buttonStyle(ProminentButtonStyle(color: Self.colors[0]))
                .help("A new note in the library (⌘N)")
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!model.folderExists)
            BoardSwitcher(current: BoardSwitcher.library, app: app)
        }
    }

    private var subtitle: String {
        let n = model.notes.count
        let place = "~/Desktop/\(FileLibrary.folderName)"
        guard model.folderExists else { return "\(place) isn't there yet" }
        return "\(n) note\(n == 1 ? "" : "s") in \(place), by name; other apps reach them over the API without asking"
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search every note", text: $model.search)
                .textFieldStyle(.plain)
            if !model.search.isEmpty {
                Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .help("Clear the search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(width: 280)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.06)))
        .help("Finds the notes with every one of your words in their name or text (a \"phrase\" in quotes); accents and case don't matter")
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

    /// With no LIBRARY folder yet: what it is, and the one click that makes it.
    private var firstRun: some View {
        VStack(spacing: 14) {
            Spacer()
            IconTile(symbol: Self.symbol, color: Self.colors[0], size: 64)
            Text("A library of notes, on your Desktop")
                .font(.title2.weight(.semibold))
            Text("A folder called \(FileLibrary.folderName) holds them: Markdown files, each known by its name alone (groceries is \(FileLibrary.folderName)/groceries.md). Write them here, in any editor, or from other apps through the API (/api/library), which answers without asking you each time. Deleting one moves it to the library's own Trash.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            Button("Make the LIBRARY Folder") { model.makeFolder() }
                .buttonStyle(ProminentButtonStyle(color: Self.colors[0], large: true))
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    // MARK: the notes

    private var tiles: some View {
        ScrollView {
            if let hits = model.hits {
                hitList(hits)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            } else if model.notes.isEmpty {
                VStack(spacing: 8) {
                    Text("No notes yet").font(.title3.weight(.semibold))
                    Text("New Note makes one; so does any app writing to the API, or a file you drop in the folder.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 420), spacing: 10)], spacing: 10) {
                    ForEach(model.notes, id: \.name) { note in
                        NoteTile(note: note, open: model.open == note.name) { model.select(note.name) }
                            .contextMenu { menu(note.name) }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }

    private func hitList(_ hits: [FileLibrary.Hit]) -> some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            Text(hits.isEmpty ? "No note has “\(model.search)” in it." : "\(hits.count) note\(hits.count == 1 ? "" : "s") with “\(model.search)”, the best first")
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
        Button("Rename…") { renaming = name }
        Button("Duplicate") { model.duplicate(name) }
        Divider()
        Button("Open in Its App") { if let n = model.library.find(name) { NSWorkspace.shared.open(n.url) } }
        Button("Show in Finder") { if let n = model.library.find(name) { NSWorkspace.shared.activateFileViewerSelecting([n.url]) } }
        Button("Copy Its Name") { copy(name) }
        Divider()
        Button("Move to the Library's Trash") { model.delete(name) }
    }

    // MARK: the Trash

    private var trashList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(model.trash.isEmpty ? "The library's Trash is empty." : "Deleted notes wait here, numbered, the latest first; Restore brings one back.")
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
                            .help(model.library.exists(t.name) ? "There's a note called \(t.name) now: it comes back as \(t.name) (restored)" : "Back into the library as \(t.name)")
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.035)))
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    // MARK: the note open

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.fill").foregroundStyle(Self.colors[0])
                Text(model.open ?? "")
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                if model.changed {
                    Text("edited")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                Spacer()
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
                    .buttonStyle(ProminentButtonStyle(color: Self.colors[0]))
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!model.changed)
                Button("Revert") { model.revert() }
                    .buttonStyle(SoftButtonStyle())
                    .disabled(!model.changed)
                Spacer()
                if let name = model.open {
                    Button { renaming = name } label: { Image(systemName: "pencil") }
                        .buttonStyle(CircleIconButtonStyle(size: 26))
                        .help("Rename it")
                    Button { if let n = model.library.find(name) { NSWorkspace.shared.open(n.url) } } label: { Image(systemName: "arrow.up.forward.app") }
                        .buttonStyle(CircleIconButtonStyle(size: 26))
                        .help("Open it in its app (your Markdown editor)")
                    Button { model.delete(name) } label: { Image(systemName: "trash") }
                        .buttonStyle(CircleIconButtonStyle(size: 26))
                        .help("Move it to the library's Trash (Restore brings it back)")
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

    private var wordCount: String {
        let words = model.text.split(whereSeparator: \.isWhitespace).count
        let name = model.open ?? ""
        return "\(words) word\(words == 1 ? "" : "s") · \(FileLibrary.folderName)/\(name).\(model.library.ext) · GET /api/library/files/\(name)"
    }

    // MARK: the bottom

    private var footer: some View {
        HStack(spacing: 8) {
            Button { showTrash.toggle() } label: {
                Label(showTrash ? "Back to the Notes" : "Trash (\(model.trash.count))", systemImage: showTrash ? "chevron.left" : "trash")
            }
            .buttonStyle(SoftButtonStyle())
            .help("Deleted notes wait in the library's own Trash, numbered, to be restored")
            Button { NSWorkspace.shared.activateFileViewerSelecting([model.library.root]) } label: { Label("Show in Finder", systemImage: "folder") }
                .buttonStyle(SoftButtonStyle())
                .disabled(!model.folderExists)
            Pill(text: "Click a note to open it", symbol: "cursorarrow.click")
            Pill(text: "Right-click: rename, duplicate, delete", symbol: "contextualmenu.and.cursorarrow")
            Spacer()
            Button { copy("\(APIService.shared.baseURL)/api/library") } label: { Label("Copy the API's Address", systemImage: "link") }
                .buttonStyle(SoftButtonStyle())
                .help("Other apps list, read, write and search the notes at /api/library, without asking you each time (POST {\"op\": \"read\", \"name\": \"groceries\"})")
        }
        .font(.callout)
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    // MARK: naming

    private var nameSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Note").font(.title3.weight(.semibold))
            Text("Its name is its file's name, without .md: any words but / and :.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("groceries, Trip to Lagos, 2026-10-24…", text: $newName)
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
        .frame(width: 420)
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
            let key = try FileLibrary.key(name)
            return model.library.exists(key) ? "There's already a note called \(key)." : nil
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

/// A note, for the rename sheet (an item for `.sheet(item:)`).
private struct RenameTarget: Identifiable {
    let id: String
}

private struct RenameSheet: View {
    let name: String
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

    private var ok: Bool { (try? FileLibrary.key(typed)) != nil && typed != name }
}

/// A note's tile: its name, its title (or first line), when it changed and how big it is.
private struct NoteTile: View {
    let note: FileLibrary.Note
    let open: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text.fill")
                        .foregroundStyle(LibraryBoardView.colors[0])
                    Text(note.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
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
            .overlay(shape.strokeBorder(open ? LibraryBoardView.colors[0].opacity(0.8) : Color.primary.opacity(hover ? 0.16 : 0.07), lineWidth: open ? 2 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(note.url.path)
    }
}
