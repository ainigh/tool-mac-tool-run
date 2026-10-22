import AppKit
import Combine
import RunCore
import SwiftUI

/// The terminal icon in the menu bar, and the panel that drops down from it. The icon says
/// what's going on: a raised hand (and how many) when something waits for you, how many runs are
/// going, an arrow when an update is ready.
@MainActor
final class StatusBarController {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel = MenuPanel()
    private var monitors: [Any] = []
    private var watching: Set<AnyCancellable> = []
    private var refreshScheduled = false
    /// What the icon shows now (its symbol and count).
    private var shown = ""

    init() {
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.imagePosition = .imageLeading
        panel.setContent(PanelView(app: AppModel.shared, runs: AppModel.shared.runs, close: { [weak self] in self?.hide() },
                                   fit: { [weak self] height in self?.panel.fit(height: height) }))
        let app = AppModel.shared
        let changes: [AnyPublisher<Void, Never>] = [
            app.runs.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            PromptCenter.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            ApprovalCenter.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            app.updater.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            APIService.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(changes)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            }
            .store(in: &watching)
        refresh()
    }

    /// Once per turn of the main loop, after the change has happened (objectWillChange comes before it).
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshScheduled = false
                self?.refresh()
            }
        }
    }

    private func refresh() {
        let waiting = PromptCenter.shared.pending.count + ApprovalCenter.shared.pending.count
        let running = AppModel.shared.runs.runningCount
        let symbol: String
        var title = ""
        if waiting > 0 {
            symbol = "hand.raised.fill"
            title = "\(waiting)"
        } else if running > 0 {
            symbol = "terminal.fill"
            title = "\(running)"
        } else if AppModel.shared.updater.available != nil {
            symbol = "terminal"
            title = "⬇︎"
        } else {
            symbol = "terminal"
        }
        guard let button = item.button else { return }
        if shown != symbol + title {
            shown = symbol + title
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Tool Mac Tool Run")
            image?.isTemplate = true
            button.image = image
            button.title = title.isEmpty ? "" : " " + title
        }
        var tip = "Tool Mac Tool Run"
        if waiting > 0 { tip += ": \(waiting) waiting for you" } else if running > 0 { tip += ": \(running) running" }
        button.toolTip = tip
    }

    @objc private func toggle() {
        panel.isVisible ? hide() : show()
    }

    func show() {
        guard let button = item.button, let window = button.window else { return }
        AppModel.shared.refreshOpenAtLogin()
        AppModel.shared.reload()
        let spot = window.convertToScreen(button.convert(button.bounds, to: nil))
        panel.present(below: spot)
        // A click anywhere else closes it: in another app, or in one of this app's windows.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window !== self.panel, event.window !== self.item.button?.window { self.hide() }
            }
            return event
        }) { monitors.append(m) }
    }

    func hide() {
        panel.orderOut(nil)
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
    }
}

/// The panel that drops down from the menu bar icon: glass, rounded, with a shadow. It floats
/// above other windows, takes clicks without taking the focus from the app you're in, keeps its
/// top edge under the icon as what's in it grows or shrinks, and closes with Escape.
final class MenuPanel: NSPanel {
    private var hosting: NSView?

    convenience init() {
        self.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let glass = NSVisualEffectView()
        glass.material = .popover
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 16
        glass.layer?.masksToBounds = true
        contentView = glass
    }

    func setContent<V: View>(_ view: V) {
        hosting?.removeFromSuperview()
        let host = NSHostingView(rootView: view)
        host.frame = contentView?.bounds ?? .zero
        host.autoresizingMask = [.width, .height]
        contentView?.addSubview(host)
        hosting = host
    }

    override var canBecomeKey: Bool { true }

    /// Shows it under `spot` (the icon, in screen coordinates), kept on that screen.
    func present(below spot: NSRect) {
        let size = hosting?.fittingSize ?? frame.size
        let screen = NSScreen.screens.first { $0.frame.contains(spot.origin) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var x = spot.midX - size.width / 2
        x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
        let y = spot.minY - size.height - 6
        setFrame(NSRect(x: x, y: max(screen.minY + 8, y), width: size.width, height: size.height), display: true)
        makeKeyAndOrderFront(nil)
    }

    /// What's in it changed height: the top edge stays where it is.
    func fit(height: CGFloat) {
        guard height > 0, abs(frame.height - height) > 0.5 else { return }
        let top = frame.maxY
        setFrame(NSRect(x: frame.minX, y: top - height, width: frame.width, height: height), display: true)
    }

    /// Escape closes it.
    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}

private struct PanelHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// What drops down from the menu bar icon: what needs you, the grids and runs as tiles, the
/// latest runs, EPA, the HTTP API with a switch for each endpoint, and the settings.
struct PanelView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var runs: RunStore
    @ObservedObject var prompts = PromptCenter.shared
    @ObservedObject var approvals = ApprovalCenter.shared
    @ObservedObject var updater = AppModel.shared.updater
    @ObservedObject var api = APIService.shared
    var close: () -> Void
    var fit: (CGFloat) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            attention
            if app.library == nil {
                chooseFolder
            }
            tiles
            recent
            if let lib = app.library { EPASection(app: app, library: lib, close: close) }
            Divider().opacity(0.5)
            APISection(api: api)
            Divider().opacity(0.5)
            footer
        }
        .padding(16)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { g in Color.clear.preference(key: PanelHeight.self, value: g.size.height) })
        .onPreferenceChange(PanelHeight.self) { fit($0) }
        .background(shortcuts)
    }

    private func go(_ action: @escaping () -> Void) {
        close()
        action()
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            IconTile(symbol: "terminal.fill", size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text("Tool Mac Tool Run").font(.system(size: 15, weight: .semibold))
                HStack(spacing: 5) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    Text(statusText).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Text(Updater.currentVersion)
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
                .help(updater.versionLine)
        }
    }

    private var statusColor: Color {
        if app.library == nil { return .orange }
        if !prompts.pending.isEmpty || !approvals.pending.isEmpty { return .orange }
        if runs.runningCount > 0 { return .accentColor }
        return .green
    }

    private var statusText: String {
        guard let lib = app.library else { return "Choose your scripts folder to begin" }
        let n = runs.runningCount
        let counts = "\(GridKind.scripts.count(app.scripts.count)), \(GridKind.composer.count(app.flows.count)) in \(GridHeader.short(lib.root))"
        return n > 0 ? "\(n) running · \(counts)" : counts
    }

    // MARK: What needs you

    @ViewBuilder
    private var attention: some View {
        if let first = approvals.pending.first {
            let n = approvals.pending.count
            Banner(symbol: "hand.raised.fill", color: first.request.dangers.isEmpty ? .orange : .red,
                   text: n == 1 ? "\(first.request.client) wants to run \(first.request.name)" : "\(n) requests to run are waiting for you",
                   action: "Show") { go { ApprovalCenter.shared.show() } }
        }
        if !prompts.pending.isEmpty {
            let n = prompts.pending.count
            Banner(symbol: "questionmark.bubble.fill", color: .orange,
                   text: n == 1 ? "\(prompts.pending[0].source) is waiting for your answer" : "\(n) flows are waiting for your answer",
                   action: "Answer") { go { Windows.showPrompt() } }
        }
        if let plan = updater.available {
            Banner(symbol: "arrow.down.circle.fill", color: .purple, text: plan.title, action: "Install") { go { app.installUpdate() } }
        }
        if let problem = app.problem {
            Banner(symbol: "exclamationmark.triangle.fill", color: .orange, text: problem, action: "Dismiss") { app.problem = nil }
        }
    }

    private var chooseFolder: some View {
        Button { go { app.openGrid(.scripts) } } label: {
            HStack(spacing: 12) {
                IconTile(symbol: "folder.fill.badge.plus", color: .orange, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Choose Your Scripts Folder…").font(.system(size: 14, weight: .semibold))
                    Text("~/Scripts in one click, with examples to start from").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.orange.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.orange.opacity(0.35)))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .help("The grids need a folder: pick one, or use ~/Scripts")
    }

    // MARK: Tiles

    private var tiles: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(GridKind.allCases, id: \.self) { kind in
                ToolTile(title: kind.title, detail: gridDetail(kind), symbol: kind.symbol, colors: kind.colors,
                         shortcut: "⌘\(kind.key)") { go { app.openGrid(kind) } }
            }
            ToolTile(title: "Runs", detail: runs.runningCount > 0 ? "\(runs.runningCount) running now" : "Everything they printed",
                     symbol: "list.bullet.rectangle.fill", colors: [Color(red: 0.18, green: 0.70, blue: 0.72), Color(red: 0.20, green: 0.72, blue: 0.42)],
                     shortcut: "⌘R") { go { Windows.showRuns(nil) } }
            ToolTile(title: "Flow Guide", detail: "The language, every function",
                     symbol: "book.fill", colors: [Color(red: 0.98, green: 0.58, blue: 0.24), Color(red: 0.90, green: 0.30, blue: 0.26)],
                     shortcut: nil) { go { Windows.showGuide() } }
        }
    }

    /// What a grid's tile says under its name: what's on it, or (with no folder yet) what it's for.
    private func gridDetail(_ kind: GridKind) -> String {
        guard app.library != nil else { return kind.purpose }
        let n = app.items(kind).count
        switch kind {
        case .scripts: return "\(n) to click and run"
        case .composer: return "\(kind.count(n)) composing them"
        case .utilities: return n == 0 ? "Sounds, the clipboard, parsing data" : "\(kind.count(n)) to reuse"
        case .browser: return n == 0 ? "Drive your default browser" : "\(kind.count(n)) for your browser"
        }
    }

    // MARK: Recent runs

    @ViewBuilder
    private var recent: some View {
        let latest = runs.recent(3)
        if !latest.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    SectionTitle("Latest runs")
                    Spacer()
                    Button("All Runs") { go { Windows.showRuns(nil) } }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                }
                ForEach(latest) { run in
                    RecentRunRow(run: run, waiting: prompts.pending(for: run.id) != nil) { go { Windows.showResult(run.id) } }
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                if let lib = app.library {
                    Button(GridHeader.short(lib.root)) { go { NSWorkspace.shared.activateFileViewerSelecting([lib.root]) } }
                        .buttonStyle(.borderless)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help("Show the folder in the Finder")
                } else {
                    Text("No folder yet").foregroundStyle(.secondary)
                }
                Spacer()
                Button(app.library == nil ? "Choose…" : "Change…") { go { app.chooseFolder() } }
                    .buttonStyle(PillButton(tint: .secondary, filled: false))
                Button("Check Setup") { go { Windows.showDoctor() } }
                    .buttonStyle(PillButton(tint: .secondary, filled: false))
                    .help("Looks at the folder, each language's program and each flow, changing nothing")
            }
            .font(.system(size: 12))
            HStack(spacing: 10) {
                Menu {
                    Picker("Notify me when a run takes over", selection: Binding(get: { app.slowAfter }, set: { app.slowAfter = $0 })) {
                        Text("30 seconds").tag(30)
                        Text("1 minute").tag(60)
                        Text("5 minutes").tag(300)
                        Text("15 minutes").tag(900)
                        Divider()
                        Text("Never").tag(0)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(app.slowAfter == 0 ? "Long runs: no notice" : "Notice after \(Self.after(app.slowAfter))", systemImage: "bell")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("A run still going after this long gets a notice (with what it last printed)")
                Spacer()
                Toggle("Open at login", isOn: Binding(get: { app.openAtLogin }, set: { app.setOpenAtLogin($0) }))
                    .toggleStyle(.checkbox)
            }
            .font(.system(size: 11))
            HStack(spacing: 10) {
                UpdateControl(updater: updater) { go { app.installUpdate() } }
                Spacer()
                Button("Quit") { go { app.quit() } }
                    .buttonStyle(PillButton(tint: .secondary, filled: false))
                    .help(runs.runningCount > 0 ? "Quit (it asks first: \(runs.runningCount) running would stop)" : "Quit Tool Mac Tool Run (⌘Q)")
            }
        }
    }

    static func after(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min"
    }

    /// The menu's keys, while the panel is up: ⌘1 to ⌘4 the grids, ⌘R the runs, ⌘Q quits.
    private var shortcuts: some View {
        ZStack {
            ForEach(GridKind.allCases, id: \.self) { kind in
                Button("") { go { app.openGrid(kind) } }.keyboardShortcut(KeyEquivalent(kind.key))
            }
            Button("") { go { Windows.showRuns(nil) } }.keyboardShortcut("r")
            Button("") { go { app.quit() } }.keyboardShortcut("q")
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A row for something that needs you, in its color, with the one thing to do.
private struct Banner: View {
    let symbol: String
    let color: Color
    let text: String
    let action: String
    let perform: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color).font(.system(size: 14, weight: .semibold))
            Text(text).font(.system(size: 12, weight: .medium)).lineLimit(2)
            Spacer(minLength: 6)
            Button(action, action: perform).buttonStyle(PillButton(tint: color, filled: true))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(color.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(color.opacity(0.3)))
    }
}

/// A big colored button for a grid, the runs or the guide.
private struct ToolTile: View {
    let title: String
    let detail: String
    let symbol: String
    let colors: [Color]
    let shortcut: String?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Image(systemName: symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .shadow(color: colors[0].opacity(0.35), radius: 4, y: 2)
                    Spacer()
                    if let shortcut {
                        Text(shortcut).font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(hover ? 0.09 : 0.05)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(colors[0].opacity(hover ? 0.5 : 0.15), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

/// One of the latest runs: how it went, when, and a click to see it.
private struct RecentRunRow: View {
    let run: RunRecord
    let waiting: Bool
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        let color = waiting ? Color.orange : Theme.color(run.state)
        Button(action: open) {
            HStack(spacing: 9) {
                Image(systemName: waiting ? "hand.raised.fill" : Theme.symbol(run.state))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(color.opacity(0.14)))
                Text(run.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                if run.requestedBy != nil {
                    Image(systemName: "network").font(.system(size: 10)).foregroundStyle(.secondary)
                        .help("Asked for over the API by \(run.requestedBy ?? "")")
                }
                Spacer(minLength: 4)
                Group {
                    if run.state == .running {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text(waiting ? "waiting for you" : "running \(RunRecord.duration(ctx.date.timeIntervalSince(run.started)))")
                        }
                    } else {
                        Text(StatusLine.summary(run) + " · " + ago(run.ended ?? run.started))
                    }
                }
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hover ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Show its result: how it went and what it printed")
    }
}

/// EPA's everyday recipes a click away, or the one step that puts them in the folder.
private struct EPASection: View {
    @ObservedObject var app: AppModel
    let library: Library
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionTitle("EPA")
                Spacer()
                Button("In the Guide") { close(); Windows.showGuide() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
            }
            if library.hasAnyEPARecipe {
                FlowLayout(spacing: 6) {
                    chip("Check Connections", "checkmark.shield") { run("epa-check-connections.flow") }
                    chip("Connect a Service…", "link") { run("epa-connect-service.flow") }
                    chip("Open the Atlas", "map") { run("epa-atlas.flow") }
                    chip("Keys (.env)…", "key") { run("epa-keys.sh") }
                    chip("Set Up or Update EPA", "arrow.down.circle") { run(EPA.setupScript) }
                    if !library.hasEPARecipes {
                        chip("Add the Missing Recipes", "plus") { GridActions(app: app, kind: .composer).addEPARecipes() }
                    }
                }
            } else {
                chip("Add the EPA Recipes", "bolt.horizontal.circle") {
                    GridActions(app: app, kind: .composer).addEPARecipes()
                    app.openGrid(.composer)
                }
                .help("Adds EPA's recipes (nothing in the folder is changed); if EPA isn't on this Mac yet, setup-epa then installs it")
            }
        }
    }

    private func chip(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button { close(); action() } label: { Label(title, systemImage: symbol) }
            .buttonStyle(Chip(selected: false))
    }

    private func run(_ file: String) {
        // Run from here, away from its grid: its result opens where you're looking.
        if !GridActions(app: app, kind: .scripts).runFile(file, started: { Windows.showResult($0) }) {
            app.problem = "\(file) isn't in your folder any more: EPA → Add the EPA Recipes puts it back."
            app.openGrid(file.hasSuffix(".flow") ? .composer : .scripts)
        }
    }
}

/// The HTTP API: whether it's serving, where, each endpoint's switch, and sharing on the network.
private struct APISection: View {
    @ObservedObject var api: APIService
    /// The doc was just copied: the button says so for a moment.
    @State private var copiedDoc = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                SectionTitle("HTTP API")
                Circle().fill(statusColor).frame(width: 6, height: 6)
                Spacer()
                Button {
                    api.copy(api.doc)
                    copiedDoc = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.5))
                        copiedDoc = false
                    }
                } label: {
                    Label(copiedDoc ? "Copied" : "Copy API Doc", systemImage: copiedDoc ? "checkmark" : "doc.on.doc").font(.system(size: 11))
                }
                    .buttonStyle(.borderless)
                    .help("Copy the whole API in one page (every endpoint, field and error, at \(api.baseURL)), to paste into another app's code, a README or a chat")
                Button { NSWorkspace.shared.open(URL(string: api.baseURL)!) } label: { Label("Try it", systemImage: "safari").font(.system(size: 11)) }
                    .buttonStyle(.borderless)
                    .disabled(!api.isServing)
                    .help("Open the API's own page: every endpoint, and a place to try running a script")
                Button(api.wantsServing ? "Stop" : "Start") { api.wantsServing ? api.stopServing() : api.startServing() }
                    .buttonStyle(PillButton(tint: api.wantsServing ? .secondary : .green, filled: !api.wantsServing))
                    .help(api.wantsServing ? "Stop serving the API (the app keeps working)" : "Serve the API at \(api.baseURL)")
            }
            Text(statusText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(APIEndpoint.allCases, id: \.self) { e in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(e.title).font(.system(size: 12, weight: .medium))
                        Text(e.routes).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { api.settings.isOn(e) }, set: { api.setEndpoint(e, on: $0) }))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                }
                .help(e.help)
                .opacity(api.wantsServing ? 1 : 0.5)
            }
            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Allow other devices").font(.system(size: 12, weight: .medium))
                    Text("Listen on the network; callers need the token").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { api.settings.allowNetwork }, set: { on in api.change { $0.allowNetwork = on } }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            .opacity(api.wantsServing ? 1 : 0.5)
            if api.settings.allowNetwork {
                HStack(spacing: 6) {
                    Text("Token").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(api.settings.token).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    CopyButton(help: "Copy the token", size: 20) { api.settings.token }
                    Button { api.change { $0.token = APISettings.newToken() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("Make a new token (the old one stops working)")
                }
            }
        }
    }

    private var statusColor: Color {
        switch api.server {
        case .running: .green
        case .starting: .orange
        case .failed: .red
        case .stopped: .gray
        }
    }

    private var statusText: String {
        switch api.server {
        case .running:
            let at = api.settings.allowNetwork ? "port \(api.settings.port), on the network" : api.baseURL
            return "Serving at \(at). Other apps can ask to run your scripts and flows; each run waits for you to click Run."
        case .starting: return "Starting…"
        case .failed(let why): return why
        case .stopped: return "Not serving: other apps can't reach your scripts."
        }
    }
}

/// Checking for, and installing, a new version, in one control.
private struct UpdateControl: View {
    @ObservedObject var updater: Updater
    let install: () -> Void

    var body: some View {
        if Updater.canUpdate {
            switch updater.state {
            case .idle, .upToDate:
                Button(updater.state == .upToDate ? "Up to date: check again" : "Check for updates") { updater.check(userInitiated: true) }
                    .buttonStyle(PillButton(tint: .secondary, filled: false))
                    .help(updater.versionLine)
            case .checking:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Checking…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            case let .available(plan):
                Button("Install update and restart", action: install)
                    .buttonStyle(PillButton(tint: .purple, filled: true))
                    .help(plan.title)
            case let .installing(step):
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(step).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            case let .failed(message):
                HStack(spacing: 6) {
                    Button("Try again") { updater.check(userInitiated: true) }
                        .buttonStyle(PillButton(tint: .secondary, filled: false))
                        .help(message)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Updater.report(message), forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .help("Copy what went wrong: \(message)")
                }
            }
        } else {
            Text(updater.versionLine).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).kerning(0.6)
    }
}

/// A small rounded button, selectable.
struct Chip: ButtonStyle {
    var selected: Bool
    var tint: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: selected ? .semibold : .medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(Capsule().fill(selected ? tint : Color.primary.opacity(configuration.isPressed ? 0.14 : 0.07)))
            .contentShape(Capsule())
    }
}

/// A capsule button, filled or outlined.
struct PillButton: ButtonStyle {
    var tint: Color
    var filled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .foregroundStyle(filled ? Color.white : Color.primary)
            .background(Capsule().fill(filled ? tint : Color.primary.opacity(0.07)))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

/// Lays its views out in rows, as many to a row as fit (the EPA chips).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += row + spacing
                x = 0
                row = 0
            }
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(width, widest), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += row + spacing
                x = bounds.minX
                row = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}
