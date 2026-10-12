import AppKit
import RunCore
import SwiftUI
import UniformTypeIdentifiers

/// A grid: a cell per script (or per flow), filling the window. A click runs it; the pencil
/// edits it. Across the top: how many cells, the pages, a new one, the runs.
struct GridView: View {
    let kind: GridKind
    @ObservedObject var app: AppModel
    @ObservedObject var runs: RunStore
    @ObservedObject var prompts = PromptCenter.shared
    @State private var askingArguments: ScriptItem?
    @State private var trashing: ScriptItem?

    var body: some View {
        Group {
            if app.library == nil {
                FolderSetupView(app: app, kind: kind)
            } else {
                content
            }
        }
        .frame(minWidth: 640, minHeight: 440)
        .background(Color(nsColor: .windowBackgroundColor))
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
        return VStack(spacing: 0) {
            GridHeader(kind: kind, app: app, runs: runs, count: all.count, page: page, pages: pages)
                .padding(.horizontal, 20)
                .padding(.top, 30)
                .padding(.bottom, 12)
            ZStack {
                cells(all: all, page: page)
                if all.isEmpty { EmptyFolderCard(kind: kind, app: app) }
            }
            .padding(.horizontal, 20)
            footer
        }
        // The page showing is kept when it had to be brought back in range (fewer scripts than
        // before), so it doesn't jump to the old page when there are more again.
        .onAppear { keepPage(page, count: all.count) }
        .onChange(of: page) { _, shown in keepPage(shown, count: all.count) }
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
                       askArguments: { askingArguments = item }, askTrash: { trashing = item })
        } else if index == all.count {
            NewCell(kind: kind, count: count, actions: actions)
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let problem = app.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                Button { app.problem = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Dismiss")
            } else {
                Text(kind == .scripts
                     ? "Click a cell to run it. The pencil edits it. Drag a cell onto another to move it. Right-click for arguments, its color, the Finder and more."
                     : "Click a flow to run it. The pencil edits it (its types are worked out as you type). Flows run the scripts from the Scripts grid by name.")
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
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

    var body: some View {
        let s = app.settings(kind)
        HStack(spacing: 14) {
            Image(systemName: kind == .scripts ? "terminal" : "point.3.connected.trianglepath.dotted")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind == .scripts ? "Scripts" : "Composer").font(.title2.weight(.semibold))
                if let lib = app.library {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([kind == .scripts ? lib.root : lib.composerFolder])
                    } label: {
                        Text("\(count) \(kind == .scripts ? (count == 1 ? "script" : "scripts") : (count == 1 ? "flow" : "flows")) in \(Self.short(kind == .scripts ? lib.root : lib.composerFolder))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Show the folder in the Finder")
                }
            }
            Spacer()
            // How many cells at once.
            HStack(spacing: 6) {
                Button { app.update(kind) { $0.cells = max(GridSettings.minCells, $0.cells - 1) } } label: { Image(systemName: "minus") }
                    .disabled(s.cells <= GridSettings.minCells)
                    .help("Fewer cells")
                Menu("\(s.cells) cells") {
                    ForEach([4, 6, 9, 12, 16, 20, 24, 30, 36, 48, 64], id: \.self) { n in
                        Button("\(n) cells") { app.update(kind) { $0.cells = n } }
                    }
                }
                .fixedSize()
                .help("How many cells the grid shows at once (more scripts than that go on further pages)")
                Button { app.update(kind) { $0.cells = min(GridSettings.maxCells, $0.cells + 1) } } label: { Image(systemName: "plus") }
                    .disabled(s.cells >= GridSettings.maxCells)
                    .help("More cells")
            }
            if pages > 1 {
                HStack(spacing: 6) {
                    Button { app.update(kind) { $0.page = max(0, page - 1) } } label: { Image(systemName: "chevron.left") }
                        .disabled(page == 0)
                        .keyboardShortcut(.leftArrow, modifiers: [.command])
                    Text("Page \(page + 1) of \(pages)").monospacedDigit()
                    Button { app.update(kind) { $0.page = min(pages - 1, page + 1) } } label: { Image(systemName: "chevron.right") }
                        .disabled(page >= pages - 1)
                        .keyboardShortcut(.rightArrow, modifiers: [.command])
                }
            }
            if kind == .composer {
                Button { Windows.showGuide() } label: { Label("Guide", systemImage: "book") }
                    .help("How to write a flow: the language, every function, examples")
            }
            Button { Windows.showRuns(nil) } label: {
                Label(runs.runningCount > 0 ? "Runs (\(runs.runningCount) running)" : "Runs", systemImage: "list.bullet.rectangle")
            }
            .help("Every run, with what it printed")
            NewButton(kind: kind, actions: GridActions(app: app, kind: kind))
        }
        .controlSize(.large)
    }

    static func short(_ url: URL) -> String { (url.path as NSString).abbreviatingWithTildeInPath }
}

/// "New Script" (picking its language) or "New Flow".
struct NewButton: View {
    let kind: GridKind
    let actions: GridActions

    var body: some View {
        if kind == .scripts {
            Menu {
                ForEach(ScriptLanguage.offered, id: \.self) { lang in
                    Button(lang.title) { actions.newScript(lang) }
                }
            } label: {
                Label("New Script", systemImage: "plus")
            }
            .fixedSize()
            .help("A new script, in the language you pick")
        } else {
            Button { actions.newFlow() } label: { Label("New Flow", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
                .help("A new flow, composing your scripts")
        }
    }
}

/// What the cells' clicks and menus do.
@MainActor
struct GridActions {
    let app: AppModel
    let kind: GridKind

    /// Runs it with these arguments (nil: the ones remembered for its cell). One that asks first
    /// (it looks like it can't be undone, or it's set to) says what it'll do and waits for Run.
    func run(_ item: ScriptItem, arguments line: String? = nil) {
        guard let lib = app.library else { return }
        let argv = ShellEnvironment.split(line ?? app.settings(kind).arguments[item.id] ?? "")
        let go = {
            if kind == .scripts {
                app.runs.run(script: item, arguments: argv, folder: lib.root)
            } else {
                app.runs.run(flow: item, arguments: argv, library: lib)
            }
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

    static func list(_ parts: [String]) -> String {
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
    let askArguments: () -> Void
    let askTrash: () -> Void
    @State private var hover = false
    @State private var dropTarget = false

    private var running: Bool { run?.state == .running }
    private var titleSize: CGFloat { count <= 4 ? 28 : count <= 9 ? 22 : count <= 16 ? 19 : count <= 30 ? 16 : 13 }
    private var roomy: Bool { count <= 30 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: roomy ? 6 : 3) {
            HStack(spacing: 6) {
                if kind == .scripts {
                    Text(item.language.badge)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.badge(item.language)))
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
                        .frame(width: 28, height: 24)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(hover ? 0.08 : 0)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Edit \(item.id)")
                .accessibilityLabel("Edit \(item.id)")
            }
            Text(item.title)
                .font(.system(size: titleSize, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.85))
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            if let summary = item.summary, roomy {
                Text(summary)
                    .font(.system(size: max(11, titleSize * 0.55)))
                    .foregroundStyle(Color.black.opacity(0.6))
                    .lineLimit(count <= 9 ? 4 : 2)
            }
            Spacer(minLength: 0)
            StatusLine(run: run, lastLine: lastLine, compact: !roomy, waiting: waiting, runs: actions.app.runs) {
                if waiting { Windows.showPrompt() } else if let run { Windows.showRuns(run.id) }
            } stop: {
                if let run { actions.app.runs.stop(run.id) }
            }
        }
        .padding(roomy ? 12 : 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(shape.fill(Theme.tint(tint)))
        .overlay {
            if running {
                RunningBorder(shape: shape)
            } else {
                shape.strokeBorder(dropTarget ? Color.accentColor : Color.black.opacity(hover ? 0.25 : 0.08), lineWidth: dropTarget ? 3 : 1)
            }
        }
        .scaleEffect(hover && !running ? 1.01 : 1)
        .animation(.easeOut(duration: 0.12), value: hover)
        .shadow(color: .black.opacity(hover ? 0.18 : 0.08), radius: hover ? 6 : 3, y: 2)
        .environment(\.colorScheme, .light)
        .contentShape(shape)
        .onHover { hover = $0 }
        .onTapGesture { primary() }
        .help(waiting ? "\(item.id) is waiting for your answer: click to answer"
              : running ? "\(item.id) is running: click to watch its output"
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

    /// A click: runs it, or, while it's running, shows what it's printing (or the question it's waiting on).
    private func primary() {
        if waiting {
            Windows.showPrompt()
        } else if running, let run {
            Windows.showRuns(run.id)
        } else {
            actions.run(item)
        }
    }

    @ViewBuilder
    private var menu: some View {
        if waiting { Button("Answer Its Question…") { Windows.showPrompt() } }
        Button(running ? "Watch Output" : "Run") { if running, let run { Windows.showRuns(run.id) } else { actions.run(item) } }
        Button("Run with Arguments…") { askArguments() }
        if running, let run { Button("Stop") { actions.app.runs.stop(run.id) } }
        Button("Edit") { actions.edit(item) }
        Divider()
        if let run { Button("Show Last Output") { Windows.showRuns(run.id) } }
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
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show what it printed")
                Spacer(minLength: 0)
                if run.state == .running {
                    Button(action: stop) {
                        Label("Stop", systemImage: "stop.fill")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Stop it")
                }
            }
        } else {
            Text("Not run yet: click to run")
                .font(.system(size: 12))
                .foregroundStyle(Color.black.opacity(0.4))
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
            shape.strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6], dashPhase: -phase.truncatingRemainder(dividingBy: 16)))
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
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(spacing: 6) {
            Image(systemName: "plus.circle")
                .font(.system(size: count <= 9 ? 30 : 20, weight: .light))
            if count <= 30 { Text(kind == .scripts ? "New script" : "New flow").font(.headline) }
        }
        .foregroundStyle(hover ? Color.accentColor : Color.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(shape.fill(Color.secondary.opacity(hover ? 0.1 : 0.04)))
        .overlay(shape.strokeBorder(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
        .contentShape(shape)
        .onHover { hover = $0 }
        .onTapGesture {
            if kind == .scripts { picking = true } else { actions.newFlow() }
        }
        .help(kind == .scripts ? "A new script: pick its language" : "A new flow")
        .accessibilityAddTraits(.isButton)
        .popover(isPresented: $picking, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("A new script in…").font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], spacing: 6) {
                    ForEach(ScriptLanguage.offered, id: \.self) { lang in
                        Button(lang.title) {
                            picking = false
                            actions.newScript(lang)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(14)
            .frame(width: 400)
        }
    }
}

/// Shown over an empty grid: what goes here, and the ways to start.
struct EmptyFolderCard: View {
    let kind: GridKind
    @ObservedObject var app: AppModel

    var body: some View {
        let actions = GridActions(app: app, kind: kind)
        VStack(alignment: .leading, spacing: 12) {
            Text(kind == .scripts ? "No scripts in this folder yet" : "No flows yet").font(.title2.weight(.semibold))
            Text(kind == .scripts
                 ? "Each script in your folder gets a cell here: bash, zsh, Python, JavaScript, Ruby and more (the language is told from its first line or its name). Start with the examples, or write one."
                 : "A flow composes your scripts: it runs them by name, passes what one prints to the next, and decides what to do with the results. Start with the examples (they use the example scripts), or write one.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button { actions.addExamples() } label: { Label("Add the Examples", systemImage: "sparkles") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .help("Adds 5 example scripts and 3 flows to the folder (nothing there is changed)")
                if kind == .scripts {
                    Menu("New Script") {
                        ForEach(ScriptLanguage.offered, id: \.self) { lang in Button(lang.title) { actions.newScript(lang) } }
                    }
                    .fixedSize()
                } else {
                    Button("New Flow") { actions.newFlow() }
                    Button("Read the Guide") { Windows.showGuide() }
                }
                Button("Show Folder") {
                    if let lib = app.library { NSWorkspace.shared.activateFileViewerSelecting([kind == .scripts ? lib.root : lib.composerFolder]) }
                }
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(maxWidth: 560)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial))
        .shadow(color: .black.opacity(0.15), radius: 20, y: 6)
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
            Text("Run \(item.id) with…").font(.title3.weight(.semibold))
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
                Button("Run", action: run)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { line = app.settings(kind).arguments[item.id] ?? "" }
    }

    private func run() {
        if remember {
            app.update(kind) { s in s.arguments[item.id] = line.trimmingCharacters(in: .whitespaces).isEmpty ? nil : line }
        }
        GridActions(app: app, kind: kind).run(item, arguments: line)
        done()
    }
}
