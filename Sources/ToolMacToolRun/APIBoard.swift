import AppKit
import RunCore
import SwiftUI

/// The API board: everything the HTTP API can run, a tile each, filling the window: the scripts,
/// the utilities, the browser scripts, the flows, EPA's commands and Flow's own functions. A
/// click runs one (asking first for what its header says it needs); its result shows beside the
/// tiles as it goes, and stays when it ends, whether it printed anything or not. A tile drags
/// into a flow's block editor, as the editor's own library does. Right-click: the request another
/// app sends for the same run.
struct APIBoardView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var runs: RunStore
    @ObservedObject var api = APIService.shared
    @State private var search = ""
    /// One section only (nil: all of them).
    @State private var only: APIAction.Section?
    /// The tile whose answers are being asked for.
    @State private var asking: APIAction?
    /// The run the result panel shows.
    @State private var shown: UUID?
    @State private var problem: String?

    static let symbol = "point.3.filled.connected.trianglepath.dotted"
    static let colors = [Color(red: 0.12, green: 0.62, blue: 0.56), Color(red: 0.13, green: 0.42, blue: 0.80)]

    /// The answers last given to each tile (offered again next time).
    @AppStorage("apiBoardAnswers") private var savedAnswers = Data()

    var body: some View {
        Group {
            if app.library == nil {
                FolderSetupView(app: app, kind: .scripts)
            } else {
                content
            }
        }
        .frame(minWidth: 640, minHeight: 440)
        .background(Backdrop())
        .sheet(item: $asking) { action in
            InputsSheet(action: action, given: answers(for: action)) { typed in
                asking = nil
                remember(typed, for: action)
                // The sheet goes first: a question before running (Ask Before Running) shows on the board.
                DispatchQueue.main.async { run(action, answers: typed) }
            } cancel: {
                asking = nil
            }
        }
    }

    private var actions: [APIAction] { APICatalog.actions(scripts: app.scripts, flows: app.flows) }

    private var content: some View {
        let all = actions
        let found = all.filter { $0.matches(search) }
        return GeometryReader { geo in
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    header(count: all.count)
                        .padding(.horizontal, 24)
                        .padding(.top, 34)
                        .padding(.bottom, 12)
                    chips(found)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 8)
                    if let problem { problemBar(problem) }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 22) {
                            ForEach(APIAction.Section.allCases, id: \.self) { section in
                                let tiles = found.filter { $0.section == section }
                                if (only == nil || only == section) && !tiles.isEmpty {
                                    sectionView(section, tiles)
                                }
                            }
                            if found.isEmpty {
                                Text("Nothing the API can run matches “\(search)”.")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 60)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                    }
                    footer
                }
                if let id = shown, let run = runs.record(id) {
                    RunResultView(run: run, runs: runs, showRun: { shown = $0 }, close: { withAnimation(.easeOut(duration: 0.2)) { shown = nil } })
                        .id(run.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
                        .shadow(color: .black.opacity(0.10), radius: 14, y: 5)
                        .frame(width: min(620, max(400, geo.size.width * 0.36)))
                        .padding(.top, 30)
                        .padding(.trailing, 20)
                        .padding(.bottom, 16)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
    }

    // MARK: the top

    private func header(count: Int) -> some View {
        HStack(spacing: 14) {
            IconTile(symbol: Self.symbol, color: Self.colors[0], size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text("API")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                HStack(spacing: 6) {
                    Circle().fill(api.isServing ? Color.green : Color.orange).frame(width: 7, height: 7)
                    Text(api.isServing
                         ? "\(count) things other apps can run, at \(api.baseURL)"
                         : "\(count) things the API can run (it's stopped: menu bar icon → HTTP API starts it)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            searchField
            BoardSwitcher(current: BoardSwitcher.api, app: app)
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
            .help("Every run, with what it printed")
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search what the API can run", text: $search)
                .textFieldStyle(.plain)
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .help("Clear the search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(width: 280)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.06)))
        .help("Finds a tile by any of its words: its name, what it does, its section")
    }

    private func chips(_ found: [APIAction]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip("All", count: found.count, color: .accentColor, value: nil)
                ForEach(APIAction.Section.allCases, id: \.self) { s in
                    chip(s.rawValue, count: found.filter { $0.section == s }.count, color: s.color, value: s)
                }
            }
        }
    }

    private func chip(_ title: String, count: Int, color: Color, value: APIAction.Section?) -> some View {
        let on = only == value
        return Button { withAnimation(.easeOut(duration: 0.12)) { only = value } } label: {
            HStack(spacing: 5) {
                Text(title)
                Text("\(count)").monospacedDigit().opacity(0.7)
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(on ? Color.white : Color.primary.opacity(0.8))
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Capsule().fill(on ? color : Color.primary.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .help(value?.about ?? "Every section")
    }

    private func problemBar(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).lineLimit(3)
            Spacer(minLength: 8)
            Button { problem = nil } label: { Image(systemName: "xmark") }
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

    // MARK: the tiles

    private func sectionView(_ section: APIAction.Section, _ tiles: [APIAction]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(section.color).frame(width: 8, height: 8)
                Text(section.rawValue.uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(section.about)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                if !api.settings.isOn(section.endpoint) {
                    Label("Off in the API: other apps can't run these (menu bar icon → HTTP API)", systemImage: "nosign")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 460), spacing: 10)], spacing: 10) {
                ForEach(tiles) { action in
                    let last = latest(action)
                    APITile(action: action, last: last, shown: last?.id != nil && last?.id == shown) { start(action) }
                        .modifier(Dragged(payload: payload(action), action: action))
                        .contextMenu { menu(action, last: last) }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Pill(text: "Click to run", symbol: "play.fill")
            Pill(text: "It asks for what it needs", symbol: "keyboard")
            Pill(text: "Drag into a flow", symbol: "hand.draw")
            Pill(text: "Right-click for its API call", symbol: "contextualmenu.and.cursorarrow")
            Spacer()
        }
        .font(.callout)
        .help("A click runs a tile (asking first for what it needs); its result shows beside the tiles. Drag a tile into a flow's block editor to add it there. Right-click for the curl command another app would send for the same run.")
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func menu(_ action: APIAction, last: RunRecord?) -> some View {
        Button("Run") { start(action) }
        if !action.inputs.isEmpty { Button("Run with…") { asking = action } }
        if let last { Button("Show Last Result") { show(last.id) } }
        Divider()
        Button("Copy curl Command") { copy(action, asCurl: true) }
        Button("Copy API Request") { copy(action, asCurl: false) }
        if let target = self.item(action) {
            Divider()
            Button("Edit") { Windows.showEditor(target, kind: target.grid) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([target.url]) }
        }
    }

    // MARK: running

    /// A click: runs it now, or asks first for what it needs.
    private func start(_ action: APIAction) {
        if action.inputs.isEmpty { run(action, answers: []) } else { asking = action }
    }

    private func run(_ action: APIAction, answers: [String]) {
        guard let lib = app.library else { return }
        problem = nil
        let given = ScriptInput.split(action.inputs, answers: answers)
        switch action.target {
        case .script, .flow:
            guard let target = self.item(action) else {
                problem = "\(action.title) isn't in your folder any more."
                return
            }
            GridActions(app: app, kind: target.grid).run(target, argv: given.arguments, stdin: given.stdin) { show($0) }
        case .function, .epa:
            do {
                let code = try action.code(answers: answers) ?? ""
                show(app.runs.run(flowSource: code, name: action.title, arguments: [], library: lib, requestedBy: nil,
                                  command: code, fix: "Change what you typed (right-click the tile → Run with…) and run it again."))
            } catch let e as FlowError {
                problem = e.message + (e.fix.map { " " + $0 } ?? "")
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func show(_ id: UUID) {
        withAnimation(.easeOut(duration: 0.2)) { shown = id }
    }

    /// The script or flow a tile runs, when it's still in the folder.
    private func item(_ action: APIAction) -> ScriptItem? {
        switch action.target {
        case .script(let id): app.scripts.first { $0.id == id }
        case .flow(let id): app.flows.first { $0.id == id }
        case .function, .epa: nil
        }
    }

    /// Its latest run, to show how it went on its tile.
    private func latest(_ action: APIAction) -> RunRecord? {
        switch action.target {
        case .script(let id): runs.latest(file: id, kind: .scripts)
        case .flow(let id): runs.latest(file: id, kind: .composer)
        case .function, .epa: shown.flatMap { runs.record($0) }.flatMap { $0.file == nil && $0.name == action.title ? $0 : nil }
        }
    }

    /// What a drag into a flow's block editor adds (the same as the editor's own library).
    private func payload(_ action: APIAction) -> String? {
        switch action.target {
        case .script, .flow: item(action).map { "script:" + app.runName($0) }
        case .epa: "epa:" + action.title
        case .function: nil
        }
    }

    private func copy(_ action: APIAction, asCurl: Bool) {
        // The answers last given, or what each one is, in brackets.
        let filled = self.answers(for: action).enumerated().map { k, a in
            a.isEmpty ? (action.inputs[k].prompt.contains("number") ? "1" : "<\(action.inputs[k].prompt)>") : a
        }
        do {
            let text: String
            if asCurl {
                text = try action.curl(answers: filled, baseURL: api.baseURL, token: api.settings.allowNetwork ? api.settings.token : nil)
            } else {
                let r = try action.request(answers: filled)
                let body = try JSONSerialization.data(withJSONObject: r.body, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                text = "\(r.method) \(api.baseURL)\(r.path)\n\(String(decoding: body, as: UTF8.self))"
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } catch {
            problem = "Couldn't make its API call: \((error as? FlowError)?.message ?? error.localizedDescription)"
        }
    }

    // MARK: the answers it remembers

    private var remembered: [String: [String]] {
        (try? JSONDecoder().decode([String: [String]].self, from: savedAnswers)) ?? [:]
    }

    private func answers(for action: APIAction) -> [String] {
        let given = remembered[action.id] ?? []
        return action.inputs.indices.map { $0 < given.count ? given[$0] : "" }
    }

    private func remember(_ answers: [String], for action: APIAction) {
        var all = remembered
        all[action.id] = answers
        if let data = try? JSONEncoder().encode(all) { savedAnswers = data }
    }
}

extension APIAction.Section {
    var color: Color {
        switch self {
        case .scripts: GridKind.scripts.colors[0]
        case .utilities: GridKind.utilities.colors[0]
        case .browser: GridKind.browser.colors[0]
        case .flows: GridKind.composer.colors[0]
        case .epa: BlockStyle.color(BlockGroup.epa)
        case .functions: BlockStyle.color(BlockGroup.values)
        }
    }

    var symbol: String {
        switch self {
        case .scripts: GridKind.scripts.symbol
        case .utilities: GridKind.utilities.symbol
        case .browser: GridKind.browser.symbol
        case .flows: GridKind.composer.symbol
        case .epa: "bolt.horizontal.circle.fill"
        case .functions: "function"
        }
    }
}

/// A tile: its section's icon, its name, what it does, what it asks for, how it last went.
struct APITile: View {
    let action: APIAction
    let last: RunRecord?
    /// Its run is the one the result panel shows.
    let shown: Bool
    let run: () -> Void
    @State private var hover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: action.symbol ?? action.section.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(action.section.color))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(action.title).font(.callout.weight(.semibold)).lineLimit(1)
                    if let badge = action.badge {
                        Text(badge)
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Text(action.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if !action.inputs.isEmpty {
                    Label(asks, systemImage: "keyboard")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            status
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
        .background(shape.fill(Color.primary.opacity(hover ? 0.08 : 0.035)))
        .overlay(border(shape))
        .scaleEffect(hover ? 1.01 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: hover)
        .contentShape(shape)
        .onHover { hover = $0 }
        .onTapGesture { run() }
        .help(tooltip)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { run() }
    }

    /// What it asks for, in a line.
    private var asks: String {
        action.inputs.count == 1 ? "Asks: " + action.inputs[0].prompt : "Asks for \(action.inputs.count) things"
    }

    private var tooltip: String {
        let asking = action.inputs.isEmpty ? "" : "\n\nIt asks first for: " + action.inputs.map { $0.prompt + ($0.optional ? " (optional)" : "") }.joined(separator: "; ")
        return "Click to run \(action.title).\n\n\(action.summary)" + asking
    }

    @ViewBuilder
    private var status: some View {
        if let last, last.state == .running {
            ProgressView().controlSize(.small)
        } else if let last {
            Image(systemName: Theme.symbol(last.state))
                .foregroundStyle(Theme.color(last.state))
                .help("Last run: \(last.state.title)")
        } else {
            Image(systemName: "play.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(Color.accentColor)
                .opacity(hover ? 1 : 0)
        }
    }

    @ViewBuilder
    private func border(_ shape: RoundedRectangle) -> some View {
        if last?.state == .running {
            RunningBorder(shape: shape)
        } else if shown {
            shape.strokeBorder(Color.accentColor.opacity(0.75), lineWidth: 2)
        } else {
            shape.strokeBorder(Color.primary.opacity(hover ? 0.16 : 0.07), lineWidth: 1)
        }
    }
}

/// A tile that can be dragged into a flow's block editor (one for a script, a flow or an EPA
/// command; a function's tile has no step of its own to become).
private struct Dragged: ViewModifier {
    let payload: String?
    let action: APIAction

    @ViewBuilder
    func body(content: Content) -> some View {
        if let payload {
            content.draggable(payload) {
                Label(action.title, systemImage: action.symbol ?? action.section.symbol)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(action.section.color.opacity(0.2)))
            }
        } else {
            content
        }
    }
}

/// What a tile asks for before it runs: a field for each (a box for text it's handed), the last
/// answers already in.
struct InputsSheet: View {
    let action: APIAction
    let given: [String]
    let run: ([String]) -> Void
    let cancel: () -> Void
    @State private var answers: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: action.symbol ?? action.section.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(action.section.color))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Run \(action.title)").font(.title3.weight(.semibold))
                    Text(action.summary).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            ForEach(action.inputs.indices, id: \.self) { k in
                field(k)
            }
            Text(missing.map { "Run needs: \($0)" } ?? "Return runs it.")
                .font(.caption)
                .foregroundStyle(missing == nil ? Color.secondary : Color.orange)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(action: go) { Label("Run", systemImage: "play.fill") }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(ProminentButtonStyle())
                    .disabled(missing != nil)
            }
        }
        .padding(22)
        .frame(width: 560)
        .onAppear { answers = action.inputs.indices.map { $0 < given.count ? given[$0] : "" } }
    }

    @ViewBuilder
    private func field(_ k: Int) -> some View {
        let input = action.inputs[k]
        VStack(alignment: .leading, spacing: 5) {
            Text(input.prompt + (input.optional ? " (optional)" : ""))
                .font(.callout.weight(.medium))
            if input.kind == .text {
                TextEditor(text: binding(k))
                    .font(Theme.mono)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 110)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
            } else {
                TextField("", text: binding(k))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(go)
            }
        }
    }

    private var missing: String? {
        guard answers.count == action.inputs.count else { return nil }
        for (k, input) in action.inputs.enumerated() where !input.optional
            && answers[k].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return input.prompt
        }
        return nil
    }

    private func binding(_ k: Int) -> Binding<String> {
        Binding(get: { k < answers.count ? answers[k] : "" }, set: { value in
            if k < answers.count { answers[k] = value }
        })
    }

    private func go() {
        guard missing == nil else { return }
        run(answers)
    }
}
