import AppKit
import RunCore
import SwiftUI
import UniformTypeIdentifiers

/// A grid: a cell per script (or per flow), filling the window. A click runs it; the pencil
/// edits it. Across the top: how many cells, the pages, a new one, the runs. Beside the cells,
/// the result pane: the run started last (or the cell whose result was clicked), live, so a
/// result is never more than the click that ran it away.
struct GridView: View {
    let kind: GridKind
    @ObservedObject var app: AppModel
    @ObservedObject var runs: RunStore
    @ObservedObject var prompts = PromptCenter.shared
    @State private var askingArguments: ScriptItem?
    @State private var trashing: ScriptItem?
    /// The run the pane shows, when it isn't the latest (a cell's result was clicked).
    @State private var focus: UUID?
    @AppStorage("showsResultPane") private var showsResult = true

    var body: some View {
        Group {
            if app.library == nil {
                FolderSetupView(app: app, kind: kind)
            } else {
                content
            }
        }
        .frame(minWidth: 640, minHeight: 440)
        .background(Backdrop())
        .sheet(item: $askingArguments) { item in
            ArgumentsSheet(item: item, kind: kind, app: app) { askingArguments = nil }
        }
        .confirmationDialog(trashing.map { "Move \($0.id) to the Trash?" } ?? "", isPresented: Binding(get: { trashing != nil }, set: { if !$0 { trashing = nil } }),
                            presenting: trashing) { item in
            Button("Move to Trash", role: .destructive) { actions.trash(item) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It goes to the Trash, so you can get it back from there (Put Back).")
        }
    }

    private var actions: GridActions { GridActions(app: app, kind: kind) }
    private var settings: GridSettings { app.settings(kind) }
    private var items: [ScriptItem] { app.items(kind) }

    private var content: some View {
        let all = settings.arranged(items)
        let pages = settings.pageCount(for: all.count)
        let page = settings.currentPage(for: all.count)
        let latest = runs.latestTop(kind)
        return GeometryReader { geo in
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    GridHeader(kind: kind, app: app, runs: runs, count: all.count, page: page, pages: pages, showsResult: $showsResult)
                        .padding(.horizontal, 24)
                        .padding(.top, 34)
                        .padding(.bottom, 16)
                    ZStack {
                        cells(all: all, page: page)
                        if all.isEmpty { EmptyFolderCard(kind: kind, app: app) }
                    }
                    .padding(.horizontal, 24)
                    footer
                }
                if showsResult {
                    ResultPane(kind: kind, run: focus.flatMap { runs.record($0) } ?? latest, runs: runs,
                               show: { focus = $0 }, close: { withAnimation(.easeOut(duration: 0.2)) { showsResult = false } })
                        .frame(width: min(620, max(400, geo.size.width * 0.34)))
                        .padding(.top, 30)
                        .padding(.trailing, 20)
                        .padding(.bottom, 16)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        // The page showing is kept when it had to be brought back in range (fewer scripts than
        // before), so it doesn't jump to the old page when there are more again.
        .onAppear { keepPage(page, count: all.count) }
        .onChange(of: page) { _, shown in keepPage(shown, count: all.count) }
        // A new run from this grid (a click, Run Again, another app): the pane follows it.
        .onChange(of: latest?.id) { _, _ in focus = nil }
    }

    /// Shows a run in the pane (opening it).
    private func show(_ id: UUID) {
        focus = id
        if !showsResult { withAnimation(.easeOut(duration: 0.2)) { showsResult = true } }
    }

    private func keepPage(_ shown: Int, count: Int) {
        // With nothing read yet (or nothing there), the remembered page stays as it is.
        guard count > 0, settings.page != shown else { return }
        app.update(kind) { $0.page = shown }
    }

    private func cells(all: [ScriptItem], page: Int) -> some View {
        GeometryReader { geo in
            let count = settings.cells
            let gap = CGFloat(GridLayout.gutter(for: count))
            let rows = GridLayout.rows(for: count, width: geo.size.width, height: geo.size.height)
            let start = page * count
            VStack(spacing: gap) {
                ForEach(rows.indices, id: \.self) { r in
                    HStack(spacing: gap) {
                        ForEach(0..<rows[r], id: \.self) { c in
                            let slot = rows.prefix(r).reduce(0, +) + c
                            cell(at: start + slot, all: all, count: count)
                        }
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    @ViewBuilder
    private func cell(at index: Int, all: [ScriptItem], count: Int) -> some View {
        if index < all.count {
            let item = all[index]
            let run = runs.latest(file: item.id, kind: kind)
            ScriptCell(item: item, kind: kind, tint: settings.tint(for: item.id), arguments: settings.arguments[item.id],
                       run: run, lastLine: run.flatMap { runs.lastLine($0.id) }, count: count, actions: actions,
                       asksFirst: actions.asksFirst(item), waiting: run.map { prompts.pending(for: $0.id) != nil } ?? false,
                       shown: showsResult && run?.id == (focus ?? runs.latestTop(kind)?.id),
                       askArguments: { askingArguments = item }, askTrash: { trashing = item }, show: { show($0) })
        } else if index == all.count {
            NewCell(kind: kind, count: count, actions: actions)
        } else {
            RoundedRectangle(cornerRadius: Theme.radiusCell, style: .continuous)
                .fill(Color.primary.opacity(0.018))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusCell, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 6])))
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let problem = app.problem {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(problem).lineLimit(2)
                    Spacer(minLength: 8)
                    Button { app.problem = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(CircleIconButtonStyle(size: 22))
                        .help("Dismiss")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.orange.opacity(0.3)))
            } else {
                // The ways in, at a glance; the sentence is under the pointer.
                Pill(text: "Click to run", symbol: "play.fill")
                Pill(text: "Pencil to edit", symbol: "pencil")
                Pill(text: "Drag to reorder", symbol: "hand.draw")
                Pill(text: "Right-click for more", symbol: "contextualmenu.and.cursorarrow")
                if kind == .composer {
                    Pill(text: "Flows run your scripts by name, and EPA", symbol: "point.3.connected.trianglepath.dotted")
                }
                Spacer()
            }
        }
        .font(.callout)
        .help(kind == .scripts
              ? "Click a cell to run it. The pencil edits it. Drag a cell onto another to move it. Right-click for arguments, its color, the Finder and more."
              : "Click a flow to run it. The pencil edits it (its types are worked out as you type). Flows run the scripts from the Scripts grid by name, and EPA (menu bar icon → EPA).")
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }
}

/// The top of a grid: its name and folder, how many cells, the pages, a new one, the runs.
struct GridHeader: View {
    let kind: GridKind
    @ObservedObject var app: AppModel
    @ObservedObject var runs: RunStore
    let count: Int
    let page: Int
    let pages: Int
    @Binding var showsResult: Bool

    var body: some View {
        let s = app.settings(kind)
        HStack(spacing: 14) {
            IconTile(symbol: kind == .scripts ? "terminal.fill" : "point.3.connected.trianglepath.dotted", size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(kind == .scripts ? "Scripts" : "Composer")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                if let lib = app.library {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([kind == .scripts ? lib.root : lib.composerFolder])
                    } label: {
                        HStack(spacing: 4) {
                            Text("\(count) \(kind == .scripts ? (count == 1 ? "script" : "scripts") : (count == 1 ? "flow" : "flows")) in \(Self.short(kind == .scripts ? lib.root : lib.composerFolder))")
                            Image(systemName: "arrow.up.forward").font(.caption2.weight(.bold))
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Show the folder in the Finder")
                }
            }
            Spacer(minLength: 12)
            // The other grid, one click away (each has its own window).
            Picker("", selection: Binding(get: { kind }, set: { if $0 != kind { app.openGrid($0) } })) {
                Text("Scripts").tag(GridKind.scripts)
                Text("Composer").tag(GridKind.composer)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Switch grids (⌘1 Scripts, ⌘2 Composer, from the menu bar icon)")
            // How many cells at once.
            HStack(spacing: 2) {
                Button { app.update(kind) { $0.cells = max(GridSettings.minCells, $0.cells - 1) } } label: { Image(systemName: "minus") }
                    .buttonStyle(CircleIconButtonStyle(size: 24))
                    .disabled(s.cells <= GridSettings.minCells)
                    .help("Fewer cells")
                Menu {
                    ForEach([4, 6, 9, 12, 16, 20, 24, 30, 36, 48, 64], id: \.self) { n in
                        Button("\(n) cells") { app.update(kind) { $0.cells = n } }
                    }
                } label: {
                    Text("\(s.cells) cells").monospacedDigit()
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("How many cells the grid shows at once (more scripts than that go on further pages)")
                Button { app.update(kind) { $0.cells = min(GridSettings.maxCells, $0.cells + 1) } } label: { Image(systemName: "plus") }
                    .buttonStyle(CircleIconButtonStyle(size: 24))
                    .disabled(s.cells >= GridSettings.maxCells)
                    .help("More cells")
            }
            .capsuleGroup()
            if pages > 1 {
                HStack(spacing: 2) {
                    Button { app.update(kind) { $0.page = max(0, page - 1) } } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(CircleIconButtonStyle(size: 24))
                        .disabled(page == 0)
                        .keyboardShortcut(.leftArrow, modifiers: [.command])
                        .help("Previous page (⌘←)")
                    Text("\(page + 1) / \(pages)").monospacedDigit().font(.callout.weight(.medium))
                        .padding(.horizontal, 4)
                    Button { app.update(kind) { $0.page = min(pages - 1, page + 1) } } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(CircleIconButtonStyle(size: 24))
                        .disabled(page >= pages - 1)
                        .keyboardShortcut(.rightArrow, modifiers: [.command])
                        .help("Next page (⌘→)")
                }
                .capsuleGroup()
            }
            if kind == .composer {
                Button { Windows.showGuide() } label: { Label("Guide", systemImage: "book") }
                    .buttonStyle(SoftButtonStyle())
                    .help("How to write a flow: the language, every function, examples")
            }
            Button { Windows.showRuns(nil) } label: {
                HStack(spacing: 6) {
                    Label("Runs", systemImage: "list.bullet.rectangle")
                    if runs.runningCount > 0 {
                        Text("\(runs.runningCount)")
                            .font(.caption.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor))
                    }
                }
            }
            .buttonStyle(SoftButtonStyle())
            .help(runs.runningCount > 0 ? "Every run, with what it printed (\(runs.runningCount) running now)" : "Every run, with what it printed")
            Button { withAnimation(.easeOut(duration: 0.2)) { showsResult.toggle() } } label: {
                Label("Result", systemImage: showsResult ? "sidebar.right" : "sidebar.squares.right")
            }
            .buttonStyle(SoftButtonStyle(tint: showsResult ? .accentColor : .primary))
            .help(showsResult ? "Hide the result pane" : "Show the result pane: the latest run's output and how it went, beside the cells")
            NewButton(kind: kind, actions: GridActions(app: app, kind: kind))
        }
    }

    static func short(_ url: URL) -> String { (url.path as NSString).abbreviatingWithTildeInPath }
}

/// "New Script" (picking its language) or "New Flow".
struct NewButton: View {
    let kind: GridKind
    let actions: GridActions
    @State private var picking = false

    var body: some View {
        if kind == .scripts {
            Button { picking = true } label: { Label("New Script", systemImage: "plus") }
                .buttonStyle(ProminentButtonStyle())
                .help("A new script, in the language you pick")
                .popover(isPresented: $picking, arrowEdge: .bottom) {
                    LanguagePicker { lang in
                        picking = false
                        actions.newScript(lang)
                    }
                }
        } else {
            Button { actions.newFlow() } label: { Label("New Flow", systemImage: "plus") }
                .buttonStyle(ProminentButtonStyle())
                .help("A new flow, composing your scripts")
        }
    }
}

/// Picking a new script's language: a tile for each, its badge in its color.
struct LanguagePicker: View {
    let pick: (ScriptLanguage) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("A new script in…").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 8)], spacing: 8) {
                ForEach(ScriptLanguage.offered, id: \.self) { lang in
                    LanguageTile(lang: lang) { pick(lang) }
                }
            }
        }
        .padding(16)
        .frame(width: 440)
    }
}

private struct LanguageTile: View {
    let lang: ScriptLanguage
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(lang.badge)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Theme.badge(lang)))
                Text(lang.title).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(hover ? 0.09 : 0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// What the cells' clicks and menus do.
@MainActor
struct GridActions {
    let app: AppModel
    let kind: GridKind

    /// Runs it with these arguments (nil: the ones remembered for its cell). One that asks first
    /// (it looks like it can't be undone, or it's set to) says what it'll do and waits for Run.
    /// `started`: told the run's id once it has started (not when Don't Run was chosen).
    func run(_ item: ScriptItem, arguments line: String? = nil, started: ((UUID) -> Void)? = nil) {
        guard let lib = app.library else { return }
        let argv = ShellEnvironment.split(line ?? app.settings(kind).arguments[item.id] ?? "")
        let go: () -> Void = {
            let id = kind == .scripts
                ? app.runs.run(script: item, arguments: argv, folder: lib.root)
                : app.runs.run(flow: item, arguments: argv, library: lib)
            started?(id)
        }
        if asksFirst(item) { confirm(item, argv: argv, then: go) } else { go() }
    }

    /// Whether it asks before running: as set on its cell, else when it looks like it can't be undone.
    func asksFirst(_ item: ScriptItem) -> Bool { app.settings(kind).ask[item.id] ?? !item.dangers.isEmpty }

    /// Why it asks, in a sentence.
    func askReason(_ item: ScriptItem) -> String {
        if app.settings(kind).ask[item.id] == true && item.dangers.isEmpty { return "You set it to ask before it runs." }
        return "It looks like it " + Self.list(item.dangers) + "."
    }

    func setAsksFirst(_ item: ScriptItem, _ on: Bool) {
        app.update(kind) { $0.ask[item.id] = on }
    }

    nonisolated static func list(_ parts: [String]) -> String {
        switch parts.count {
        case 0: return ""
        case 1: return parts[0]
        default: return parts.dropLast().joined(separator: ", ") + " and " + parts.last!
        }
    }

    /// The command it runs, as typed in a terminal.
    func command(_ item: ScriptItem, argv: [String]) -> String {
        if kind == .scripts {
            // Only the command is wanted: no environment (reading it can wait on the login shell).
            return ScriptProcess(script: item.url, language: item.language, arguments: argv, workingDirectory: app.library?.root, environment: [:]).commandLine
        }
        return (["flow", "run", item.url.path] + argv).map(ShellEnvironment.quote).joined(separator: " ")
    }

    /// Says what it's about to run and why it's asking, on the window in front (Return runs it,
    /// Escape doesn't). The box under it keeps asking, or stops asking for this one.
    private func confirm(_ item: ScriptItem, argv: [String], then go: @escaping () -> Void) {
        let alert = NSAlert()
        alert.alertStyle = item.dangers.isEmpty ? .informational : .warning
        alert.messageText = "Run \(item.id)?"
        alert.informativeText = askReason(item) + "\n\nIt will run:\n\(command(item, argv: argv))\n\nNothing has run yet."
        let run = alert.addButton(withTitle: "Run")
        run.hasDestructiveAction = !item.dangers.isEmpty
        alert.addButton(withTitle: "Don't Run")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Ask before running \(item.title) next time"
        alert.suppressionButton?.state = .on
        let kind = self.kind
        let app = self.app
        let done: (NSApplication.ModalResponse) -> Void = { response in
            // Unticked: it stops asking (said on its cell's menu, where it can be turned back on).
            if alert.suppressionButton?.state == .off { app.update(kind) { $0.ask[item.id] = false } }
            if response == .alertFirstButtonReturn { go() }
        }
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey }) {
            alert.beginSheetModal(for: window, completionHandler: done)
        } else {
            done(alert.runModal())
        }
    }

    func edit(_ item: ScriptItem) { Windows.showEditor(item, kind: kind) }

    func newScript(_ lang: ScriptLanguage) {
        guard let lib = app.library else { return }
        do {
            let url = try lib.newScript(name: "untitled", language: lang)
            app.problem = nil
            app.reload()
            Windows.showEditor(ScriptItem(url: url, language: lang, summary: nil, modified: Date()), kind: .scripts)
        } catch {
            app.problem = "Couldn't make a new script: \(error.localizedDescription)"
        }
    }

    func newFlow() {
        guard let lib = app.library else { return }
        do {
            let url = try lib.newFlow(name: "untitled")
            app.problem = nil
            app.reload()
            Windows.showEditor(ScriptItem(url: url, language: .unknown, summary: nil, modified: Date()), kind: .composer)
        } catch {
            app.problem = "Couldn't make a new flow: \(error.localizedDescription)"
        }
    }

    func addExamples() {
        guard let lib = app.library else { return }
        do {
            try lib.addExamples()
            app.problem = nil
            app.reload()
        } catch {
            app.problem = "Couldn't add the examples: \(error.localizedDescription)"
        }
    }

    /// Adds the EPA recipes (setup-epa, epa-keys and the epa-… flows; nothing there is changed).
    /// When EPA isn't set up on this Mac yet, setup-epa runs straight after, on its cell.
    func addEPARecipes() {
        guard let lib = app.library else { return }
        do {
            try lib.addEPARecipes()
            app.problem = nil
            app.reload()
        } catch {
            app.problem = "Couldn't add the EPA recipes: \(error.localizedDescription)"
            return
        }
        let app = self.app
        Task.detached {
            let found = EPA.find(path: ShellEnvironment.shared.environment["PATH"] ?? "") != nil
            await MainActor.run {
                if !found { GridActions(app: app, kind: .scripts).runFile(EPA.setupScript) }
            }
        }
    }

    /// Runs a script (or a flow) from the folder by its file name. False when it isn't there.
    @discardableResult
    func runFile(_ file: String, started: ((UUID) -> Void)? = nil) -> Bool {
        guard let lib = app.library else { return false }
        if let script = lib.script(named: file) {
            GridActions(app: app, kind: .scripts).run(script, started: started)
            return true
        }
        if let flow = lib.flows().first(where: { $0.id == file }) {
            GridActions(app: app, kind: .composer).run(flow, started: started)
            return true
        }
        return false
    }

    /// Moves it to the Trash. An editor open on it saves first (the Trash keeps the latest), then
    /// closes without saving again (which would make the file again).
    func trash(_ item: ScriptItem) {
        Windows.editor(for: item.url)?.save()
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            Windows.closeEditor(for: item.url, deleted: true)
            app.problem = nil
            app.reload()
        } catch {
            app.problem = "Couldn't move \(item.id) to the Trash: \(error.localizedDescription)"
        }
    }

    func setTint(_ item: ScriptItem, _ tint: Int?) {
        app.update(kind) { s in
            if let tint { s.tints[item.id] = tint } else { s.tints[item.id] = nil }
        }
    }

    func move(_ id: String, to target: String) {
        let items = app.items(kind)
        withAnimation(.easeInOut(duration: 0.2)) {
            app.update(kind) { $0.move(id, to: target, among: items) }
        }
    }

    func copyCommand(_ item: ScriptItem) {
        let argv = ShellEnvironment.split(app.settings(kind).arguments[item.id] ?? "")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command(item, argv: argv), forType: .string)
    }

    /// Opens it in the app that edits plain text (never runs it, as opening a .sh or .command
    /// in the Finder might).
    func openInEditor(_ item: ScriptItem) {
        let editor = NSWorkspace.shared.urlForApplication(toOpen: UTType.plainText)
            ?? URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        NSWorkspace.shared.open([item.url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
    }

    static var editorName: String {
        let url = NSWorkspace.shared.urlForApplication(toOpen: UTType.plainText)
        return url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? "TextEdit"
    }
}

/// A script's (or a flow's) cell: its language, its name, what it does, how its last run went.
struct ScriptCell: View {
    let item: ScriptItem
    let kind: GridKind
    let tint: Int
    let arguments: String?
    let run: RunRecord?
    /// While it runs: the last line it printed.
    let lastLine: String?
    let count: Int
    let actions: GridActions
    /// It asks before it runs (it looks like it can't be undone, or it's set to).
    let asksFirst: Bool
    /// Its flow is waiting for an answer.
    let waiting: Bool
    /// Its latest run is the one the result pane shows.
    let shown: Bool
    let askArguments: () -> Void
    let askTrash: () -> Void
    /// Shows one of its runs in the result pane.
    let show: (UUID) -> Void
    @State private var hover = false
    @State private var dropTarget = false

    private var running: Bool { run?.state == .running }
    private var titleSize: CGFloat { count <= 4 ? 28 : count <= 9 ? 22 : count <= 16 ? 19 : count <= 30 ? 16 : 13 }
    private var roomy: Bool { count <= 30 }

    /// The last run failed (or couldn't start): the cell's edge says so too.
    private var lastFailed: Bool { run?.state == .failed || run?.state == .couldNotStart }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.radiusCell, style: .continuous)
        VStack(alignment: .leading, spacing: roomy ? 7 : 3) {
            HStack(spacing: 6) {
                if kind == .scripts {
                    Text(item.language.badge)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Theme.badge(item.language)))
                        .shadow(color: Theme.badge(item.language).opacity(0.35), radius: 2, y: 1)
                        .help("\(item.language.title), told from \(item.url.lastPathComponent)")
                } else {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.black.opacity(0.55))
                }
                if asksFirst {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.orange.opacity(0.85))
                        .help("Asks before it runs. " + actions.askReason(item) + " (Right-click → Ask Before Running to change it.)")
                        .accessibilityLabel("Asks before it runs")
                }
                if item.usesEPA, roomy {
                    Label("EPA", systemImage: "bolt.horizontal.circle.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color(red: 0.70, green: 0.16, blue: 0.32))
                        .help("Runs EPA (Enter-Price Automation). EPA shows its plan and asks before it changes anything.")
                }
                if let arguments, !arguments.isEmpty, roomy {
                    Text(arguments)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.black.opacity(0.5))
                        .lineLimit(1)
                        .help("Runs with: \(arguments)")
                }
                Spacer(minLength: 4)
                Button { actions.edit(item) } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(hover ? 0.75 : 0.4))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.white.opacity(hover ? 0.75 : 0)))
                        .overlay(Circle().strokeBorder(Color.black.opacity(hover ? 0.08 : 0)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Edit \(item.id)")
                .accessibilityLabel("Edit \(item.id)")
            }
            Text(item.title)
                .font(.system(size: titleSize, weight: .bold, design: .rounded))
                .foregroundStyle(Color.black.opacity(0.86))
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            if let summary = item.summary, roomy {
                Text(summary)
                    .font(.system(size: max(11, titleSize * 0.55)))
                    .foregroundStyle(Color.black.opacity(0.6))
                    .lineLimit(count <= 9 ? 4 : 2)
            }
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: 6) {
                StatusLine(run: run, lastLine: lastLine, compact: !roomy, waiting: waiting, runs: actions.app.runs) {
                    if let run { show(run.id) }
                } stop: {
                    if let run { actions.app.runs.stop(run.id) }
                }
                Spacer(minLength: 0)
                if !running && !waiting && count <= 30 {
                    // What a click does, under the pointer: run it.
                    Image(systemName: "play.fill")
                        .font(.system(size: count <= 9 ? 15 : 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: count <= 9 ? 38 : 30, height: count <= 9 ? 38 : 30)
                        .background(Circle().fill(LinearGradient(colors: [Color.accentColor.opacity(0.85), Color.accentColor],
                                                                 startPoint: .top, endPoint: .bottom)))
                        .shadow(color: Color.accentColor.opacity(0.4), radius: 5, y: 2)
                        .opacity(hover ? 1 : 0)
                        .scaleEffect(hover ? 1 : 0.7)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(roomy ? 14 : 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            ZStack {
                shape.fill(Theme.tint(tint))
                // A sheen from the top, a little depth at the bottom.
                shape.fill(LinearGradient(colors: [Color.white.opacity(0.55), Color.white.opacity(0), Color.black.opacity(0.035)],
                                          startPoint: .top, endPoint: .bottom))
            }
        }
        .overlay {
            if running {
                RunningBorder(shape: shape)
            } else if dropTarget {
                shape.strokeBorder(Color.accentColor, lineWidth: 3)
            } else if shown {
                // Its result is the one beside the cells.
                shape.strokeBorder((lastFailed ? Theme.color(.failed) : Color.accentColor).opacity(0.75), lineWidth: 2)
            } else if lastFailed {
                shape.strokeBorder(Theme.color(.failed).opacity(hover ? 0.6 : 0.4), lineWidth: 1.5)
            } else {
                shape.strokeBorder(Color.black.opacity(hover ? 0.18 : 0.07), lineWidth: 1)
            }
        }
        .scaleEffect(hover && !running ? 1.015 : 1)
        .offset(y: hover && !running ? -1 : 0)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: hover)
        .shadow(color: running ? Color.accentColor.opacity(0.35) : .black.opacity(hover ? 0.16 : 0.06),
                radius: running ? 12 : hover ? 12 : 4, y: hover ? 6 : 2)
        .environment(\.colorScheme, .light)
        .contentShape(shape)
        .onHover { hover = $0 }
        .onTapGesture { primary() }
        .help(waiting ? "\(item.id) is waiting for your answer: click to answer it beside the cells"
              : running ? "\(item.id) is running: click to watch its output beside the cells"
              : "Click to run \(item.id)" + (arguments.map { $0.isEmpty ? "" : " \($0)" } ?? "") + (asksFirst ? " (it asks first)" : ""))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { primary() }
        .onDrag { NSItemProvider(object: item.id as NSString) }
        .onDrop(of: [UTType.text], isTargeted: $dropTarget) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: NSString.self) { obj, _ in
                guard let id = obj as? String, id != item.id else { return }
                DispatchQueue.main.async { actions.move(id, to: item.id) }
            }
            return true
        }
        .contextMenu { menu }
    }

    /// A click: runs it (its result shows beside the cells as it goes), or, while it's running,
    /// shows what it's printing (or the question it's waiting on) there.
    private func primary() {
        if (waiting || running), let run {
            show(run.id)
        } else {
            actions.run(item)
        }
    }

    @ViewBuilder
    private var menu: some View {
        if waiting { Button("Answer Its Question…") { Windows.showPrompt() } }
        Button(running ? "Watch Output" : "Run") { if running, let run { show(run.id) } else { actions.run(item) } }
        Button("Run with Arguments…") { askArguments() }
        if running, let run { Button("Stop") { actions.app.runs.stop(run.id) } }
        Button("Edit") { actions.edit(item) }
        Divider()
        if let run { Button("Show Last Result") { show(run.id) } }
        if let run { Button("Open in Runs") { Windows.showRuns(run.id) } }
        Button("Copy Command for Terminal") { actions.copyCommand(item) }
        Button("Open in \(GridActions.editorName)") { actions.openInEditor(item) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        Toggle("Ask Before Running", isOn: Binding(get: { asksFirst }, set: { actions.setAsksFirst(item, $0) }))
        Menu("Color") {
            ForEach(GridSettings.tints.indices, id: \.self) { k in
                Button(GridSettings.tints[k].name.capitalized) { actions.setTint(item, k) }
            }
            Divider()
            Button("Automatic") { actions.setTint(item, nil) }
        }
        Divider()
        Button("Move to Trash…") { askTrash() }
    }
}

/// The bottom of a cell: how the last run went (a click shows its output), or, while it runs,
/// how long it's been going, its last line, and Stop.
struct StatusLine: View {
    let run: RunRecord?
    let lastLine: String?
    let compact: Bool
    /// Its flow is waiting for an answer.
    var waiting = false
    /// For how long it's been quiet (read each second while it runs).
    var runs: RunStore?
    let show: () -> Void
    let stop: () -> Void

    var body: some View {
        if let run {
            HStack(spacing: 6) {
                Button(action: show) {
                    HStack(spacing: 5) {
                        if run.state == .running && waiting {
                            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                            Text(compact ? "Waiting" : "Waiting for your answer: click").lineLimit(1)
                        } else if run.state == .running {
                            Image(systemName: Theme.symbol(run.state))
                                .foregroundStyle(Theme.color(run.state))
                            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                                let quiet = runs?.quietFor(run.id, now: ctx.date) ?? 0
                                HStack(spacing: 5) {
                                    Text(RunRecord.duration(ctx.date.timeIntervalSince(run.started)))
                                        .monospacedDigit()
                                    if !compact && quiet >= 20 {
                                        // Silence reads as broken: say it's quiet, and what it may want.
                                        Text(runs?.acceptsInput(run.id) == true ? "· quiet: waiting for you to type?" : "· quiet for \(RunRecord.duration(quiet))")
                                            .lineLimit(1)
                                            .foregroundStyle(Color.orange.opacity(0.9))
                                    } else if !compact, let line = lastLine {
                                        Text(line).lineLimit(1).foregroundStyle(Color.black.opacity(0.55))
                                    }
                                }
                            }
                        } else {
                            Image(systemName: Theme.symbol(run.state))
                                .foregroundStyle(Theme.color(run.state))
                            Text(Self.summary(run)).lineLimit(1)
                            if !compact { Text("· \(ago(run.ended ?? run.started))").foregroundStyle(Color.black.opacity(0.45)) }
                        }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.black.opacity(0.7))
                    .padding(.horizontal, compact ? 6 : 9)
                    .padding(.vertical, compact ? 3 : 5)
                    .background(Capsule().fill(Color.white.opacity(0.6)))
                    .overlay(Capsule().strokeBorder(Color.black.opacity(0.05)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Show what it printed")
                Spacer(minLength: 0)
                if run.state == .running {
                    Button(action: stop) {
                        Label("Stop", systemImage: "stop.fill")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(SoftButtonStyle(tint: .red))
                    .help("Stop it")
                }
            }
        } else {
            Text(compact ? "Not run yet" : "Not run yet: click to run")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.black.opacity(0.4))
                .padding(.vertical, compact ? 0 : 5)
        }
    }

    static func summary(_ r: RunRecord) -> String {
        switch r.state {
        case .succeeded: return r.seconds.map { RunRecord.duration($0) } ?? "Done"
        case .failed: return "Failed" + (r.ending.map { ", \($0.summary)" } ?? "")
        case .stopped: return "Stopped"
        case .couldNotStart: return "Couldn't start: click to see why"
        case .running: return "Running"
        }
    }
}

/// The border of a cell whose script is running: a dashed line going round.
struct RunningBorder: View {
    let shape: RoundedRectangle

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let phase = ctx.date.timeIntervalSinceReferenceDate * 30
            ZStack {
                shape.strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 3)
                shape.strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [14, 10],
                                                                         dashPhase: -phase.truncatingRemainder(dividingBy: 24)))
            }
        }
    }
}

/// The cell after the last script: a new one.
struct NewCell: View {
    let kind: GridKind
    let count: Int
    let actions: GridActions
    @State private var hover = false
    @State private var picking = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.radiusCell, style: .continuous)
        VStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: count <= 9 ? 22 : 15, weight: .semibold))
                .foregroundStyle(hover ? Color.white : Color.accentColor)
                .frame(width: count <= 9 ? 48 : 34, height: count <= 9 ? 48 : 34)
                .background(Circle().fill(hover ? Color.accentColor : Color.accentColor.opacity(0.12)))
            if count <= 30 { Text(kind == .scripts ? "New script" : "New flow").font(.headline) }
        }
        .foregroundStyle(hover ? Color.accentColor : Color.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(shape.fill(Color.accentColor.opacity(hover ? 0.07 : 0.025)))
        .overlay(shape.strokeBorder(hover ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.28),
                                    style: StrokeStyle(lineWidth: 1.5, dash: [7, 6])))
        .animation(.easeOut(duration: 0.15), value: hover)
        .contentShape(shape)
        .onHover { hover = $0 }
        .onTapGesture {
            if kind == .scripts { picking = true } else { actions.newFlow() }
        }
        .help(kind == .scripts ? "A new script: pick its language" : "A new flow")
        .accessibilityAddTraits(.isButton)
        .popover(isPresented: $picking, arrowEdge: .bottom) {
            LanguagePicker { lang in
                picking = false
                actions.newScript(lang)
            }
        }
    }
}

/// Shown over an empty grid: what goes here, and the ways to start.
struct EmptyFolderCard: View {
    let kind: GridKind
    @ObservedObject var app: AppModel

    @State private var picking = false

    var body: some View {
        let actions = GridActions(app: app, kind: kind)
        VStack(spacing: 16) {
            IconTile(symbol: kind == .scripts ? "terminal.fill" : "point.3.connected.trianglepath.dotted", size: 64)
            Text(kind == .scripts ? "No scripts in this folder yet" : "No flows yet")
                .font(.system(size: 26, weight: .bold, design: .rounded))
            Text(kind == .scripts
                 ? "Each script in your folder gets a cell here: bash, zsh, Python, JavaScript, Ruby and more (the language is told from its first line or its name). Start with the examples, or write one."
                 : "A flow composes your scripts: it runs them by name, passes what one prints to the next, and decides what to do with the results. Start with the examples (they use the example scripts), or write one.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button { actions.addExamples() } label: { Label("Add the Examples", systemImage: "sparkles") }
                    .buttonStyle(ProminentButtonStyle(large: true))
                    .keyboardShortcut(.defaultAction)
                    .help("Adds 5 example scripts and 4 flows to the folder (nothing there is changed)")
                Button { actions.addEPARecipes() } label: { Label("Add the EPA Recipes", systemImage: "bolt.horizontal.circle") }
                    .buttonStyle(SoftButtonStyle(large: true))
                    .help("Adds EPA's recipes: setup-epa, epa-keys, and flows to connect services, secure a site, onboard and offboard people… (nothing there is changed). If EPA isn't on this Mac yet, setup-epa then runs to install it.")
            }
            HStack(spacing: 8) {
                if kind == .scripts {
                    Button { picking = true } label: { Label("New Script", systemImage: "plus") }
                        .popover(isPresented: $picking, arrowEdge: .bottom) {
                            LanguagePicker { lang in
                                picking = false
                                actions.newScript(lang)
                            }
                        }
                } else {
                    Button { actions.newFlow() } label: { Label("New Flow", systemImage: "plus") }
                    Button { Windows.showGuide() } label: { Label("Read the Guide", systemImage: "book") }
                }
                Button {
                    if let lib = app.library { NSWorkspace.shared.activateFileViewerSelecting([kind == .scripts ? lib.root : lib.composerFolder]) }
                } label: { Label("Show Folder", systemImage: "folder") }
            }
            .buttonStyle(SoftButtonStyle())
        }
        .padding(36)
        .frame(maxWidth: 600)
        .card(radius: 24)
    }
}

/// Run with arguments: typed as in a terminal, kept for the cell when asked.
struct ArgumentsSheet: View {
    let item: ScriptItem
    let kind: GridKind
    @ObservedObject var app: AppModel
    let done: () -> Void
    @State private var line = ""
    @State private var remember = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IconTile(symbol: "terminal.fill", size: 34)
                Text("Run \(item.id) with…").font(.title3.weight(.semibold))
            }
            TextField("Arguments, as you'd type them in a terminal", text: $line)
                .font(Theme.mono)
                .textFieldStyle(.roundedBorder)
                .onSubmit(run)
            let parts = ShellEnvironment.split(line)
            Text(parts.isEmpty ? "No arguments." : "\(parts.count) argument\(parts.count == 1 ? "" : "s"): " + parts.map { "‹\($0)›" }.joined(separator: " "))
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Use these every time its cell is clicked", isOn: $remember)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: done)
                    .keyboardShortcut(.cancelAction)
                Button(action: run) { Label("Run", systemImage: "play.fill") }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(ProminentButtonStyle())
            }
        }
        .padding(22)
        .frame(width: 520)
        .onAppear { line = app.settings(kind).arguments[item.id] ?? "" }
    }

    private func run() {
        if remember {
            app.update(kind) { s in s.arguments[item.id] = line.trimmingCharacters(in: .whitespaces).isEmpty ? nil : line }
        }
        // The sheet goes first: a question before running (Ask Before Running) shows on the grid.
        let actions = GridActions(app: app, kind: kind)
        let what = item, typed = line
        done()
        DispatchQueue.main.async { actions.run(what, arguments: typed) }
    }
}
