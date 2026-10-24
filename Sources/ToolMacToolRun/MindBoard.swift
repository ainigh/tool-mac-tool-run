import AppKit
import Combine
import RunCore
import SwiftUI

/// What the Mind board shows and does: the mind (MIND/mind.txt in TOOL-MAC-RUN) compiled, laid
/// out as a picture, or as its text (the log as written, or its shortest form); a node picked, with
/// all that's known about it; and lines being written to add, checked as they're typed. Adding is
/// appending: nothing above is ever changed. Read again often: another app may have just added.
@MainActor
final class MindBoardModel: ObservableObject {
    static let shared = MindBoardModel()

    enum Mode: String, CaseIterable {
        case picture, log, canonical

        var title: String {
            switch self {
            case .picture: "Picture"
            case .log: "As Written"
            case .canonical: "Shortest"
            }
        }
    }

    let store = MindStore()
    let memoryFiles = FileLibrary(shelf: .memory)

    @Published private(set) var graph = MindGraph()
    @Published private(set) var log = ""
    @Published private(set) var positions: [MindNodeID: MindLayout.Point] = [:]
    /// Where the person dragged nodes to (they stay there).
    @Published private(set) var pinned: [MindNodeID: MindLayout.Point] = [:]
    @Published var selected: MindNodeID?
    @Published var search = ""
    @Published var mode: Mode = .picture
    /// Lines being written, to add.
    @Published var draft = "" { didSet { checkDraft() } }
    /// What they'd add (a check, nothing written).
    @Published private(set) var checked: MindStore.Appended?
    @Published private(set) var draftProblem: String?
    @Published var problem: String?
    /// MEMORY's files (each a node in the root scope).
    @Published private(set) var memoryNames: Set<String> = []

    private var stamp = ""
    private var layoutKey = ""

    var exists: Bool { store.exists }

    /// Reads the mind again when its file has changed.
    func reload() {
        memoryNames = Set(memoryFiles.names())
        let values = try? store.file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let now = "\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)/\(values?.fileSize ?? -1)"
        guard now != stamp else { return }
        stamp = now
        graph = store.graph()
        log = store.log()
        if let s = selected, graph.node(s) == nil { selected = nil }
        layOut()
    }

    /// Lays the picture out again when the nodes or edges changed (off the main thread).
    func layOut(force: Bool = false) {
        let g = graph
        let key = g.nodeList.map(\.id.description).joined(separator: "\u{1}") + "\u{2}" + g.edgeList.map { "\($0.a)>\($0.b)" }.joined(separator: "\u{1}")
        guard force || key != layoutKey else { return }
        layoutKey = key
        let fixed = pinned.filter { g.node($0.key) != nil }
        Task.detached(priority: .userInitiated) {
            let at = MindLayout.positions(g, fixed: fixed)
            await MainActor.run { MindBoardModel.shared.positions = at }
        }
    }

    /// Lays it all out afresh, letting go of the nodes dragged.
    func relayOut() {
        pinned = [:]
        layOut(force: true)
    }

    func move(_ id: MindNodeID, to p: MindLayout.Point) {
        let clamped = MindLayout.Point(x: min(1, max(0, p.x)), y: min(1, max(0, p.y)))
        pinned[id] = clamped
        positions[id] = clamped
    }

    func select(named name: String) {
        reload()
        if let id = MindQuery.lookup(name, in: graph).first {
            selected = id
            mode = .picture
        }
    }

    var about: MindQuery.About? { selected.flatMap { MindQuery.about($0, in: graph) } }

    /// The nodes the search finds (empty: no search).
    var found: Set<MindNodeID> {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return Set(MindQuery.find(q, in: graph, all: true).map(\.id))
    }

    func isMemory(_ id: MindNodeID) -> Bool { id.isRoot && memoryNames.contains(id.name) }

    // MARK: adding

    private var draftLines: [String] {
        draft.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func checkDraft() {
        let lines = draftLines
        guard !lines.isEmpty else {
            checked = nil
            draftProblem = nil
            return
        }
        do {
            checked = try store.append(lines, partial: true, scopeChanges: true, dryRun: true)
            draftProblem = nil
        } catch {
            checked = nil
            draftProblem = "\(error)"
        }
    }

    /// Whether the draft deletes or merges a scope (asked about first).
    var draftChangesScopes: Bool {
        draftLines.contains { line in
            if case .statement(.deleteScope) = try? MindNotation.parse(line) { return true }
            if case .statement(.mergeScope) = try? MindNotation.parse(line) { return true }
            return false
        }
    }

    /// Appends the draft (it's the person's own: scope changes allowed).
    func add() {
        let lines = draftLines
        guard !lines.isEmpty else { return }
        do {
            let r = try store.append(lines, stamp: MindStore.stamp("on the Mind board"), scopeChanges: true)
            draft = ""
            problem = r.added.isEmpty ? "Nothing new: the mind knew all of that already." : nil
            reload()
        } catch {
            problem = "\(error)"
        }
    }

    /// Appends one line the board made (a rename, a forget, a note).
    func append(_ line: String) {
        do {
            try store.append([line], stamp: MindStore.stamp("on the Mind board"))
            reload()
        } catch {
            problem = "\(error)"
        }
    }

    func compact() {
        do {
            let archived = try store.compact()
            problem = "Compacted: the old log is in MIND/Archive/\(archived.lastPathComponent)."
            reload()
        } catch {
            problem = "\(error)"
        }
    }

    func make() {
        do {
            try Memory().ensure()
            reload()
        } catch {
            problem = "\(error)"
        }
    }
}

/// The Mind board: the mind as a picture to move around in (or as its text), the node picked
/// beside it with everything known about it, and a box to add lines in the notation, checked as
/// they're typed. It fills 90% of the screen, as the other boards do.
struct MindBoardView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var model: MindBoardModel
    @State private var confirmCompact = false
    @State private var confirmScopes = false
    @State private var forgetting: MindNodeID?
    @State private var renaming: MindNodeID?
    @State private var newName = ""
    @State private var note = ""

    static var colors: [Color] { Board.mind.colors }

    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 34)
                .padding(.bottom, 12)
            if let problem = model.problem { problemBar(problem) }
            if !model.exists {
                firstRun
            } else {
                HStack(spacing: 14) {
                    main
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
                    side
                        .frame(width: 380)
                }
                .padding(.horizontal, 24)
            }
            footer
        }
        .frame(minWidth: 760, minHeight: 480)
        .background(Backdrop())
        .onAppear { model.reload() }
        .onReceive(tick) { _ in model.reload() }
        .alert("Compact the mind?", isPresented: $confirmCompact) {
            Button("Compact") { model.compact() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The log is rewritten in its shortest form: the same mind, one line a fact. The log as it is now is kept in MIND/Archive, with every edit's history.")
        }
        .alert("Delete or merge a scope?", isPresented: $confirmScopes) {
            Button("Add the Lines", role: .destructive) { model.add() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A line you're adding deletes or merges a scope: everything in it goes (or moves). The log keeps what was there before, but the mind won't have it.")
        }
        .alert("Forget \(forgetting?.description ?? "")?", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } })) {
            Button("Forget It", role: .destructive) {
                if let id = forgetting { model.append("| \(MindNotation.written(id, current: model.graph.current)) =") }
                forgetting = nil
            }
            Button("Cancel", role: .cancel) { forgetting = nil }
        } message: {
            Text("It and its links go from the mind (a line is added: \(forgetting.map { MindNotation.written($0, current: model.graph.current) } ?? "") =). The log keeps that it was there.")
        }
        .sheet(isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) { renameSheet }
    }

    // MARK: the top

    private var header: some View {
        HStack(spacing: 14) {
            IconTile(symbol: Board.mind.symbol, color: Self.colors[0], size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text("Mind")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find in the mind", text: $model.search)
                    .textFieldStyle(.plain)
                if !model.search.isEmpty {
                    Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(minWidth: 140, idealWidth: 220, maxWidth: 240)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.06)))
            .help("Rings the nodes with every one of your words in their name, notes or links' labels")
            Picker("", selection: $model.mode) {
                ForEach(MindBoardModel.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("The mind as a picture, as its log is written, or in its shortest form (one line a fact)")
            BoardSwitcher(current: Board.mind.rawValue, app: app)
        }
    }

    private var subtitle: String {
        let g = model.graph
        guard model.exists else { return "\(Home.short(model.store.file)) isn't there yet" }
        let scopes = g.scopes.isEmpty ? "" : ", \(g.scopes.count) scope\(g.scopes.count == 1 ? "" : "s")"
        let problems = g.problems.isEmpty ? "" : " · \(g.problems.count) line\(g.problems.count == 1 ? "" : "s") it can't read"
        return "\(g.nodes.count) things, \(g.edges.count) links\(scopes), from \(g.lines) lines; only ever added to\(problems)"
    }

    private func problemBar(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle.fill").foregroundStyle(.orange)
            Text(text).lineLimit(4)
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

    private var firstRun: some View {
        VStack(spacing: 14) {
            Spacer()
            IconTile(symbol: Board.mind.symbol, color: Self.colors[0], size: 64)
            Text("A mind: what links to what").font(.title2.weight(.semibold))
            Text("It's a text file of lines like | ada lovelace - works at | acme, only ever added to, that make a picture of what's known. Each file in MEMORY is a thing in it. Other apps ask it and add to it through the API (/api/mind).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
            Button("Make the Mind (and MEMORY)") { model.make() }
                .buttonStyle(ProminentButtonStyle(color: Self.colors[0], large: true))
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    // MARK: the middle

    @ViewBuilder
    private var main: some View {
        switch model.mode {
        case .picture:
            MindCanvas(model: model)
                .background(Color(nsColor: .textBackgroundColor))
        case .log:
            MindText(lines: model.log.components(separatedBy: "\n"), problems: Dictionary(model.graph.problems.map { ($0.line, $0) }, uniquingKeysWith: { a, _ in a }), copyAll: model.log)
        case .canonical:
            MindText(lines: model.graph.canonicalLines(), problems: [:], copyAll: model.graph.canonical)
        }
    }

    // MARK: the side

    private var side: some View {
        VStack(spacing: 12) {
            if let a = model.about {
                nodePanel(a)
            } else {
                hint
            }
            addPanel
        }
    }

    private var hint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Click a thing to see all about it").font(.headline)
            Text("Drag the picture to move around; pinch, or + and −, to zoom; drag a thing to put it somewhere. MEMORY's files are the larger ones; each scope has its color.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if !model.graph.problems.isEmpty {
                Button { model.mode = .log } label: { Label("\(model.graph.problems.count) line\(model.graph.problems.count == 1 ? "" : "s") it can't read: see them", systemImage: "exclamationmark.triangle.fill") }
                    .buttonStyle(SoftButtonStyle(tint: .orange))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func nodePanel(_ a: MindQuery.About) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(MindCanvas.color(a.id.scope, scopes: model.graph.scopes)).frame(width: 12, height: 12)
                Text(a.id.name).font(.title3.weight(.semibold)).lineLimit(2).textSelection(.enabled)
                if !a.id.isRoot { Pill(text: "@\(a.id.scope)") }
                if model.isMemory(a.id) { Pill(text: "MEMORY file", symbol: Board.memory.symbol, color: Board.memory.colors[0]) }
                Spacer()
                Button { model.selected = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(CircleIconButtonStyle(size: 22))
                    .help("Close")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if !a.notes.isEmpty {
                        Text("Notes").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(a.notes, id: \.self) { n in
                            Text("@" + n).font(.callout).textSelection(.enabled)
                        }
                    }
                    if !a.links.isEmpty {
                        Text("Linked (\(a.links.count))").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(Array(a.links.enumerated()), id: \.offset) { _, l in
                            Button { model.selected = l.node } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(arrow(l.direction)).foregroundStyle(.secondary)
                                    Text(l.node.description).font(.callout.weight(.medium))
                                    if !l.labels.isEmpty { Text(l.labels.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
                                    if !l.notes.isEmpty { Text("@" + l.notes.joined(separator: " @")).font(.caption).foregroundStyle(.tertiary) }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Show \(l.node.description)")
                        }
                    }
                    Text("In the notation").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    CodeBlock(text: a.lines.joined(separator: "\n"))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 6) {
                TextField("Add a note: date 2026-11-03, todo call back…", text: $note)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addNote(a.id) }
                Button("Add") { addNote(a.id) }
                    .disabled(note.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack(spacing: 6) {
                if model.isMemory(a.id) {
                    Button { Windows.showShelfBoard(.memory) } label: { Label("Its File", systemImage: "doc.text") }
                        .buttonStyle(SoftButtonStyle())
                        .help("MEMORY/\(a.id.name).md, on the Memory board")
                }
                Button { present(a) } label: { Image(systemName: "macwindow") }
                    .buttonStyle(CircleIconButtonStyle(size: 26))
                    .help("Show all about it in a window, in front, with copy buttons")
                Button {
                    newName = a.id.name
                    renaming = a.id
                } label: { Image(systemName: "pencil") }
                    .buttonStyle(CircleIconButtonStyle(size: 26))
                    .help("Call it something else from here on (adds a line: old = new)")
                Button { forgetting = a.id } label: { Image(systemName: "eraser") }
                    .buttonStyle(CircleIconButtonStyle(size: 26))
                    .help("Forget it and its links (adds a line: name =; the log keeps its history)")
                Spacer()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }

    private func arrow(_ direction: String) -> String {
        switch direction {
        case "out": "→"
        case "in": "←"
        case "both": "⇄"
        default: "—"
        }
    }

    private func addNote(_ id: MindNodeID) {
        let safe = MindNotation.safeText(note)
        guard !safe.text.isEmpty else { return }
        model.append("| \(MindNotation.written(id, current: model.graph.current)) @\(safe.text)")
        note = ""
    }

    private func present(_ a: MindQuery.About) {
        var md = "# \(a.id.description)\n\n"
        if !a.notes.isEmpty { md += a.notes.map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
        if !a.links.isEmpty {
            md += "## Linked\n\n" + a.links.map { "- \(arrow($0.direction)) **\($0.node.description)**" + ($0.labels.isEmpty ? "" : " (\($0.labels.joined(separator: ", ")))") }.joined(separator: "\n") + "\n\n"
        }
        md += "## In the notation\n\n```mm\n" + a.lines.joined(separator: "\n") + "\n```\n"
        PresentCenter.shared.show(Presentation(title: a.id.description, text: md, source: "the mind", shelf: model.isMemory(a.id) ? .memory : nil,
                                               name: model.isMemory(a.id) ? a.id.name : nil, client: "You"))
    }

    private var addPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Add to the mind").font(.headline)
                Spacer()
                Menu {
                    Text("| name | name — a step or direction")
                    Text("| name - verb | name — a link with a label")
                    Text("| name - | name — linked, no direction")
                    Text("| name @kind text — a note (date, todo, pref, src)")
                    Text("| old = new — the same thing: merge")
                    Text("| old = — forget it")
                    Text("| @ scope — what follows is in that scope")
                } label: { Image(systemName: "questionmark.circle") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("The lines the notation has (SYSTEM-DOCS/MIND-GUIDE says it all)")
            }
            TextEditor(text: $model.draft)
                .font(.system(size: 12.5, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 70, maxHeight: 120)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(alignment: .topLeading) {
                    if model.draft.isEmpty {
                        Text("| ada lovelace - works at | acme")
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
            if let c = model.checked {
                VStack(alignment: .leading, spacing: 3) {
                    if !c.added.isEmpty { Label("Adds \(c.added.count) line\(c.added.count == 1 ? "" : "s")", systemImage: "plus.circle.fill").foregroundStyle(.green) }
                    if !c.known.isEmpty { Label("\(c.known.count) known already (left out)", systemImage: "equal.circle").foregroundStyle(.secondary) }
                    ForEach(Array(c.problems.enumerated()), id: \.offset) { _, p in
                        Label("\(p.text): \(p.message) \(p.fix)", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .lineLimit(3)
                    }
                }
                .font(.caption)
            } else if let p = model.draftProblem {
                Text(p).font(.caption).foregroundStyle(.orange).lineLimit(3)
            }
            HStack {
                Text("Lines are only ever added at the end.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Add") {
                    if model.draftChangesScopes { confirmScopes = true } else { model.add() }
                }
                .buttonStyle(ProminentButtonStyle(color: Self.colors[0]))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.checked.map { $0.added.isEmpty || !$0.problems.isEmpty } ?? true)
                .help("Adds the lines at the end of the log (⌘↩)")
            }
        }
        .padding(14)
        .card()
    }

    private var renameSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Call \(renaming?.description ?? "") something else").font(.title3.weight(.semibold))
            Text("From here on it's the new name (merging into a thing of that name, if there is one). A line is added: old = new.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Its new name", text: $newName)
                .textFieldStyle(.roundedBorder)
            if let why = MindNotation.nameProblem(newName), !newName.isEmpty {
                Text(why).font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { renaming = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") {
                    if let id = renaming {
                        model.append("| \(MindNotation.written(id, current: model.graph.current)) = \(MindNotation.collapse(newName))")
                    }
                    renaming = nil
                }
                .keyboardShortcut(.defaultAction)
                .disabled(MindNotation.nameProblem(newName) != nil || newName == renaming?.name)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    // MARK: the bottom

    private var footer: some View {
        HStack(spacing: 8) {
            Button { model.relayOut() } label: { Label("Lay Out Again", systemImage: "circle.hexagongrid") }
                .buttonStyle(SoftButtonStyle())
                .help("Lays the picture out afresh (the things you dragged go back too)")
            Button { confirmCompact = true } label: { Label("Compact…", systemImage: "arrow.down.right.and.arrow.up.left") }
                .buttonStyle(SoftButtonStyle())
                .help("Rewrites the log in its shortest form, keeping the old one in MIND/Archive")
                .disabled(!model.exists)
            Button { PresentCenter.shared.show(Presentation(title: "The mind", text: model.graph.canonical, format: .mind, source: "MIND/mind.txt, in its shortest form", client: "You")) } label: {
                Label("Show in a Window", systemImage: "macwindow")
            }
            .buttonStyle(SoftButtonStyle())
            Button { NSWorkspace.shared.activateFileViewerSelecting([model.store.file]) } label: { Label("Show in Finder", systemImage: "folder") }
                .buttonStyle(SoftButtonStyle())
                .disabled(!model.exists)
            Button { Windows.showShelfBoard(.memory) } label: { Label("Memory", systemImage: Board.memory.symbol) }
                .buttonStyle(SoftButtonStyle())
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(APIService.shared.baseURL)/api/mind", forType: .string)
            } label: { Label("Copy the API's Address", systemImage: "link") }
                .buttonStyle(SoftButtonStyle())
                .help("Other apps ask the mind and add to it at /api/mind, without asking you each time (GET /api/mind/nodes/ada, POST /api/mind/add {\"from\", \"label\", \"to\"})")
        }
        .font(.callout)
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }
}

/// The log (or its shortest form) as text: a line each, numbered; comments quieter; a line the
/// mind can't read in orange, with what's wrong.
private struct MindText: View {
    let lines: [String]
    let problems: [Int: MindGraph.Problem]
    let copyAll: String

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { k, line in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text("\(k + 1)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 40, alignment: .trailing)
                                Text(line.isEmpty ? " " : line)
                                    .font(.system(size: 12.5, design: .monospaced))
                                    .foregroundStyle(problems[k + 1] != nil ? Color.orange : line.trimmingCharacters(in: .whitespaces).hasPrefix("|") ? Color.primary : Color.secondary)
                                    .textSelection(.enabled)
                            }
                            if let p = problems[k + 1] {
                                Text("\(p.message) \(p.fix)")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .padding(.leading, 50)
                            }
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            CopyButton(help: "Copy all of it", size: 26) { copyAll }
                .padding(10)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// The mind as a picture: things as dots (MEMORY's files larger), links as lines (an arrow where
/// they have a direction, their labels at the middle), each scope its color. Drag to move around,
/// pinch or the buttons to zoom, drag a thing to put it somewhere, click one to pick it.
struct MindCanvas: View {
    @ObservedObject var model: MindBoardModel
    @State private var scale: CGFloat = 1
    @State private var zoomBase: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var panBase: CGSize = .zero
    /// What a drag started on: a node (moving it), or nothing (moving the picture).
    @State private var dragging: MindNodeID?
    @State private var dragStarted = false

    static let palette: [Color] = [Color(red: 0.42, green: 0.36, blue: 0.92), Color(red: 0.95, green: 0.55, blue: 0.20), Color(red: 0.20, green: 0.66, blue: 0.52),
                                   Color(red: 0.90, green: 0.33, blue: 0.45), Color(red: 0.20, green: 0.55, blue: 0.90), Color(red: 0.62, green: 0.48, blue: 0.30)]

    static func color(_ scope: String, scopes: [String]) -> Color {
        guard !scope.isEmpty, let k = scopes.firstIndex(of: scope) else { return palette[0] }
        return palette[1 + k % (palette.count - 1)]
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let g = model.graph
            let found = model.found
            let picked = model.selected
            let near: Set<MindNodeID> = picked.map { p in Set(g.edges(at: p).map { $0.other(p) }).union([p]) } ?? []
            ZStack(alignment: .bottomTrailing) {
                Canvas { context, _ in
                    // The links first, under the things.
                    for e in g.edgeList {
                        guard let a = model.positions[e.a], let b = model.positions[e.b] else { continue }
                        let pa = point(a, size), pb = point(b, size)
                        let lit = picked == nil || e.a == picked || e.b == picked
                        var path = Path()
                        path.move(to: pa)
                        path.addLine(to: pb)
                        context.stroke(path, with: .color(Color.primary.opacity(lit ? 0.35 : 0.08)), lineWidth: lit && picked != nil ? 1.8 : 1)
                        if e.forward { arrowhead(&context, from: pa, to: pb, radius: radius(e.b), lit: lit) }
                        if e.backward { arrowhead(&context, from: pb, to: pa, radius: radius(e.a), lit: lit) }
                        if !e.labels.isEmpty, lit, scale >= 0.7 || picked != nil {
                            let mid = CGPoint(x: (pa.x + pb.x) / 2, y: (pa.y + pb.y) / 2)
                            context.draw(Text(e.labels.joined(separator: ", ")).font(.system(size: 10)).foregroundStyle(Color.secondary), at: mid)
                        }
                    }
                    for n in g.nodeList {
                        guard let at = model.positions[n.id] else { continue }
                        let p = point(at, size)
                        let r = radius(n.id)
                        let faded = picked != nil && !near.contains(n.id)
                        let color = Self.color(n.id.scope, scopes: g.scopes)
                        let dot = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
                        context.fill(dot, with: .color(color.opacity(faded ? 0.25 : 1)))
                        if n.id == picked {
                            context.stroke(Path(ellipseIn: CGRect(x: p.x - r - 4, y: p.y - r - 4, width: r * 2 + 8, height: r * 2 + 8)), with: .color(color), lineWidth: 2.5)
                        }
                        if found.contains(n.id) {
                            context.stroke(Path(ellipseIn: CGRect(x: p.x - r - 7, y: p.y - r - 7, width: r * 2 + 14, height: r * 2 + 14)), with: .color(.orange), lineWidth: 3)
                        }
                        if !faded || scale >= 1.2 {
                            let memory = model.isMemory(n.id)
                            context.draw(Text(n.id.name).font(.system(size: memory ? 12 : 11, weight: memory ? .bold : .regular))
                                .foregroundStyle(Color.primary.opacity(faded ? 0.35 : 0.9)), at: CGPoint(x: p.x, y: p.y + r + 3), anchor: .top)
                        }
                    }
                }
                .contentShape(Rectangle())
                .gesture(drag(size).simultaneously(with: zoom))
                if g.nodes.isEmpty {
                    Text("Nothing in the mind yet: add lines on the right, or let an app add them (POST /api/mind/add).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                HStack(spacing: 4) {
                    Button { scale = min(4, scale * 1.25); zoomBase = scale } label: { Image(systemName: "plus") }
                        .help("Zoom in")
                    Button { scale = max(0.3, scale / 1.25); zoomBase = scale } label: { Image(systemName: "minus") }
                        .help("Zoom out")
                    Button {
                        scale = 1; zoomBase = 1; offset = .zero; panBase = .zero
                    } label: { Image(systemName: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left") }
                        .help("All of it, in view")
                }
                .buttonStyle(CircleIconButtonStyle(size: 28))
                .capsuleGroup()
                .padding(10)
            }
        }
    }

    private func radius(_ id: MindNodeID) -> CGFloat {
        (model.isMemory(id) ? 10 : 6.5) * min(1.6, max(0.7, scale))
    }

    /// A place (0…1) on the screen.
    private func point(_ p: MindLayout.Point, _ size: CGSize) -> CGPoint {
        let margin: CGFloat = 50
        let x = CGFloat(p.x) * max(1, size.width - margin * 2) + margin
        let y = CGFloat(p.y) * max(1, size.height - margin * 2) + margin
        return CGPoint(x: (x - size.width / 2) * scale + size.width / 2 + offset.width,
                       y: (y - size.height / 2) * scale + size.height / 2 + offset.height)
    }

    /// The place (0…1) a point on the screen is.
    private func place(_ q: CGPoint, _ size: CGSize) -> MindLayout.Point {
        let margin: CGFloat = 50
        let x = (q.x - offset.width - size.width / 2) / scale + size.width / 2
        let y = (q.y - offset.height - size.height / 2) / scale + size.height / 2
        return MindLayout.Point(x: Double((x - margin) / max(1, size.width - margin * 2)), y: Double((y - margin) / max(1, size.height - margin * 2)))
    }

    private func hit(_ q: CGPoint, _ size: CGSize) -> MindNodeID? {
        var best: (MindNodeID, CGFloat)?
        for (id, at) in model.positions {
            let p = point(at, size)
            let d = hypot(p.x - q.x, p.y - q.y)
            if d <= radius(id) + 6, d < (best?.1 ?? .infinity) { best = (id, d) }
        }
        return best?.0
    }

    private func arrowhead(_ context: inout GraphicsContext, from a: CGPoint, to b: CGPoint, radius r: CGFloat, lit: Bool) {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(0.001, hypot(dx, dy))
        guard len > r * 2 + 6 else { return }
        let ux = dx / len, uy = dy / len
        let tip = CGPoint(x: b.x - ux * (r + 2), y: b.y - uy * (r + 2))
        let size: CGFloat = 7
        var head = Path()
        head.move(to: tip)
        head.addLine(to: CGPoint(x: tip.x - ux * size - uy * size * 0.55, y: tip.y - uy * size + ux * size * 0.55))
        head.addLine(to: CGPoint(x: tip.x - ux * size + uy * size * 0.55, y: tip.y - uy * size - ux * size * 0.55))
        head.closeSubpath()
        context.fill(head, with: .color(Color.primary.opacity(lit ? 0.5 : 0.12)))
    }

    private func drag(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if !dragStarted {
                    dragStarted = true
                    dragging = hit(v.startLocation, size)
                }
                if let id = dragging {
                    if hypot(v.translation.width, v.translation.height) > 3 { model.move(id, to: place(v.location, size)) }
                } else {
                    offset = CGSize(width: panBase.width + v.translation.width, height: panBase.height + v.translation.height)
                }
            }
            .onEnded { v in
                let moved = hypot(v.translation.width, v.translation.height) > 3
                if !moved {
                    // A click: pick what's there (or nothing).
                    model.selected = hit(v.startLocation, size)
                }
                if dragging == nil { panBase = offset }
                dragging = nil
                dragStarted = false
            }
    }

    private var zoom: some Gesture {
        MagnificationGesture()
            .onChanged { v in scale = min(4, max(0.3, zoomBase * v)) }
            .onEnded { _ in zoomBase = scale }
    }
}
