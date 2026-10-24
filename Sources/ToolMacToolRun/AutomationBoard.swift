import AppKit
import RunCore
import SwiftUI

/// The Automation board: everything that runs by itself, a tile each, grouped by what makes it
/// run (every morning, when the API is called…), with when it next runs and how it last went;
/// then, under "Not automated", everything else, by its grid, ready to be tagged. A click runs a tile now
/// (as its cell would); right-click → Automation tags it. Its result shows beside the tiles, as
/// on the API board. It looks like the API board on purpose: the same tiles, grouped differently.
struct AutomationBoardView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var runs: RunStore
    @ObservedObject var center = AutomationCenter.shared
    @State private var search = ""
    /// One tag only (nil: all of them; `notAutomated`: the untagged).
    @State private var only: String?
    /// The run the result panel shows.
    @State private var shown: UUID?

    static let symbol = "clock.badge.checkmark"
    static let colors = [Color(red: 0.93, green: 0.42, blue: 0.24), Color(red: 0.80, green: 0.22, blue: 0.40)]
    static let notAutomated = "not-automated"
    /// The top of the tiles, scrolled back to when the chip changes.
    private static let top = "top"

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
    }

    /// Every script and flow, in the grids' order.
    private var items: [ScriptItem] { GridKind.allCases.flatMap { app.items($0) } }

    private func automation(_ item: ScriptItem) -> Automation { app.settings(item.grid).automation(for: item.id) }

    private func matches(_ item: ScriptItem) -> Bool {
        let words = search.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let hay = [item.title, item.id, item.summary ?? "", item.grid.title, automation(item).summary].joined(separator: " ").lowercased()
        return words.allSatisfy { hay.contains($0) }
    }

    private var content: some View {
        let all = items
        let found = all.filter(matches)
        let automated = found.filter { !automation($0).isEmpty }
        let rest = found.filter { automation($0).isEmpty }
        let tagged = all.filter { !automation($0).isEmpty }.count
        let filter = selected(automated: automated)
        return GeometryReader { geo in
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    header(count: tagged, of: all.count)
                        .padding(.horizontal, 24)
                        .padding(.top, 34)
                        .padding(.bottom, 12)
                    chips(automated: automated, rest: rest, selected: filter)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 8)
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 0) {
                                Color.clear.frame(height: 0).id(Self.top)
                                board(found: found, automated: automated, rest: rest, tagged: tagged, filter: filter)
                                    .padding(.horizontal, 24)
                                    .padding(.bottom, 24)
                            }
                        }
                        // A new chip starts at its top, not wherever the last one was scrolled to.
                        .onChange(of: only) { _, _ in proxy.scrollTo(Self.top, anchor: .top) }
                        .onChange(of: search) { _, _ in proxy.scrollTo(Self.top, anchor: .top) }
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

    /// The tiles the chip that's on (`filter`) shows: each tag's, then the untagged, by grid.
    private func board(found: [ScriptItem], automated: [ScriptItem], rest: [ScriptItem], tagged: Int, filter: String?) -> some View {
        LazyVStack(alignment: .leading, spacing: 22) {
            if tagged == 0 && search.isEmpty && filter == nil { emptyCard }
            ForEach(AutomationTag.allCases, id: \.self) { tag in
                let tiles = automated.filter { automation($0).tags.contains(tag) }
                if (filter == nil || filter == tag.rawValue) && !tiles.isEmpty {
                    section(title: tag.title, about: tag.about, symbol: tag.symbol, color: tag.kind == .schedule ? Self.colors[0] : Self.colors[1], tiles)
                }
            }
            if (filter == nil || filter == Self.notAutomated) && !rest.isEmpty {
                untagged(rest)
            }
            if found.isEmpty {
                note("Nothing matches “\(search)”.")
            } else if filter == Self.notAutomated && rest.isEmpty {
                note(search.isEmpty ? "Everything runs by itself: nothing is left to tag." : "Everything that matches “\(search)” runs by itself.")
            }
        }
    }

    /// The chip that's on: the one picked, while it still has tiles. Untagging the last item of a
    /// tag takes its chip away, and the board goes back to All rather than showing nothing.
    private func selected(automated: [ScriptItem]) -> String? {
        guard let picked = only, picked != Self.notAutomated else { return only }
        return automated.contains { item in automation(item).tags.contains { $0.rawValue == picked } } ? picked : nil
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.title3)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
    }

    // MARK: the top

    private func header(count: Int, of total: Int) -> some View {
        HStack(spacing: 14) {
            IconTile(symbol: Self.symbol, color: Self.colors[0], size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text("Automation")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text(count == 0
                     ? "Nothing runs by itself yet: right-click any of the \(total) below → Automation"
                     : "\(count) of \(total) run by \(count == 1 ? "itself" : "themselves"): on a schedule, or when something happens")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            searchField
            BoardSwitcher(current: BoardSwitcher.automation, app: app)
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
            .help("Every run, with what it printed (runs started by the automation are marked)")
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search by name, or by tag", text: $search)
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
        .help("Finds a tile by any of its words: its name, what it does, its grid, its tags")
    }

    private func chips(automated: [ScriptItem], rest: [ScriptItem], selected: String?) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip("All", count: automated.count + rest.count, color: .accentColor, value: nil, on: selected == nil, help: "Every tile")
                ForEach(AutomationTag.allCases, id: \.self) { tag in
                    let n = automated.filter { automation($0).tags.contains(tag) }.count
                    if n > 0 {
                        chip(tag.title, count: n, color: tag.kind == .schedule ? Self.colors[0] : Self.colors[1], value: tag.rawValue,
                             on: selected == tag.rawValue, help: tag.about)
                    }
                }
                chip("Not automated", count: rest.count, color: .secondary, value: Self.notAutomated, on: selected == Self.notAutomated,
                     help: "Everything that runs only when clicked, or asked for, by its grid")
            }
        }
    }

    private func chip(_ title: String, count: Int, color: Color, value: String?, on: Bool, help: String) -> some View {
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
        .help(help)
    }

    /// With nothing tagged yet: what this board is, and the first step.
    private var emptyCard: some View {
        HStack(alignment: .top, spacing: 14) {
            IconTile(symbol: Self.symbol, color: Self.colors[0], size: 40)
            VStack(alignment: .leading, spacing: 6) {
                Text("Make something run by itself").font(.headline)
                Text("Right-click any tile below (or any cell on a grid) → Automation, and tick when it should run: a schedule (every morning, every 10 minutes…) or a trigger (when the API is called, after another item…). It then shows up here under that tag, with its next time. Other apps can tag one too, over the API (\"automation\" in their request), and you're asked first.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Self.colors[0].opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Self.colors[0].opacity(0.25)))
    }

    // MARK: the tiles

    private func section(title: String, about: String, symbol: String, color: Color, _ tiles: [ScriptItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            heading(title: title, about: about, symbol: symbol, color: color)
            tileGrid(tiles)
        }
    }

    /// Everything not tagged yet, under its grid (Scripts, Composer, Utilities, Browser).
    private func untagged(_ tiles: [ScriptItem]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            heading(title: "Not automated", about: "Right-click one → Automation, and pick when it runs", symbol: "circle.dashed", color: .secondary)
            ForEach(GridKind.allCases, id: \.self) { kind in
                let mine = tiles.filter { $0.grid == kind }
                if !mine.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: kind.symbol)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(kind.colors[0])
                            Text("\(kind.title) · \(mine.count)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        tileGrid(mine)
                    }
                }
            }
        }
    }

    private func heading(title: String, about: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color).font(.caption.weight(.bold))
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            Text(about)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    private func tileGrid(_ tiles: [ScriptItem]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 460), spacing: 10)], spacing: 10) {
            ForEach(tiles) { item in
                let last = runs.latest(file: item.id, kind: item.grid)
                AutomationTile(item: item, automation: automation(item), next: center.next(for: item.id, kind: item.grid)?.at,
                               last: last, shown: last?.id != nil && last?.id == shown) { run(item) }
                    .contextMenu { menu(item, last: last) }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Pill(text: "Right-click → Automation to tag", symbol: "contextualmenu.and.cursorarrow")
            Pill(text: "Click to run now", symbol: "play.fill")
            Pill(text: "Runs by itself with its cell's arguments", symbol: "clock")
            Pill(text: "Asks first if the cell would", symbol: "hand.raised")
            Spacer()
        }
        .font(.callout)
        .help("A tile here runs by itself as its tags say, with the arguments remembered for its cell (right-click it on its grid → Run with Arguments…). One that asks before it runs asks on a card, as another app's request would. Click a tile to run it now; right-click → Automation to change its tags.")
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func menu(_ item: ScriptItem, last: RunRecord?) -> some View {
        Button("Run Now") { run(item) }
        if let last { Button("Show Last Result") { show(last.id) } }
        Divider()
        AutomationMenu(item: item, app: app)
        Divider()
        Button("Edit") { Windows.showEditor(item, kind: item.grid) }
        Button("Show on Its Grid") { app.openGrid(item.grid) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
    }

    /// A click: runs it now, as its cell would (asking first when its cell would).
    private func run(_ item: ScriptItem) {
        GridActions(app: app, kind: item.grid).run(item) { show($0) }
    }

    private func show(_ id: UUID) {
        withAnimation(.easeOut(duration: 0.2)) { shown = id }
    }
}

/// A tile: its grid's icon, its name, what it does, its tags, when it next runs, how it last went.
struct AutomationTile: View {
    let item: ScriptItem
    let automation: Automation
    let next: Date?
    let last: RunRecord?
    /// Its run is the one the result panel shows.
    let shown: Bool
    let run: () -> Void
    @State private var hover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.grid.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(item.grid.colors[0]))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(item.grid.isFlow ? "flow" : item.language.badge)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if !item.dangers.isEmpty {
                        Image(systemName: "hand.raised.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.orange)
                            .help("It looks like it \(GridActions.list(item.dangers)): it asks on a card before each run, even by itself")
                    }
                }
                Text(item.summary ?? (item.grid.isFlow ? "A flow" : "A \(item.language.title) script"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if automation.isEmpty {
                    Label("Right-click → Automation", systemImage: "circle.dashed")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                } else {
                    AutomationBadge(automation: automation, next: next)
                    if let next {
                        TimelineView(.periodic(from: .now, by: 30)) { ctx in
                            Label("Next: \(AutomationCenter.when(next, now: ctx.date))", systemImage: "arrow.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
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

    private var tooltip: String {
        var s = "Click to run \(item.id) now."
        if let summary = item.summary { s += "\n\n" + summary }
        if !automation.isEmpty {
            s += "\n\nRuns by itself: " + automation.summary + "."
            if let next { s += " Next: \(AutomationCenter.when(next))." }
        } else {
            s += "\n\nIt doesn't run by itself: right-click → Automation to tag it."
        }
        if let last { s += "\n\nLast run: \(last.state.title), \(RunRecord.ago(last.ended ?? last.started))" + (last.isAutomated ? " (by itself)" : "") + "." }
        return s
    }

    @ViewBuilder
    private var status: some View {
        if let last, last.state == .running {
            ProgressView().controlSize(.small)
        } else if let last {
            Image(systemName: Theme.symbol(last.state))
                .foregroundStyle(Theme.color(last.state))
                .help("Last run: \(last.state.title), \(RunRecord.ago(last.ended ?? last.started))")
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
