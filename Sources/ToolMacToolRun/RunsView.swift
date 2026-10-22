import AppKit
import RunCore
import SwiftUI

/// Every run, newest first (a flow's steps under it), and the one picked: how it went, the
/// command to run it in a terminal, and everything it printed (live, while it runs).
struct RunsView: View {
    @ObservedObject var runs: RunStore
    @ObservedObject var selection: RunsSelection

    var body: some View {
        NavigationSplitView {
            List(selection: $selection.selected) {
                let records = runs.records
                let top = records.reversed().filter { $0.parent == nil }
                let steps = Self.stepsByParent(records)
                if top.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Image(systemName: "tray").font(.title2).foregroundStyle(.tertiary)
                        Text("No runs yet").font(.headline)
                        Text("Click a cell in a grid to run it.").foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 12)
                }
                ForEach(top) { run in
                    RunRow(run: run, indent: false).tag(run.id)
                    ForEach(steps[run.id] ?? []) { step in
                        RunRow(run: step, indent: true).tag(step.id)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 320)
            .toolbar {
                ToolbarItem {
                    Button { runs.clearFinished() } label: { Label("Clear Finished", systemImage: "trash") }
                        .help("Forget the finished runs (what's running stays)")
                        .disabled(runs.records.allSatisfy { $0.state == .running })
                }
            }
        } detail: {
            if let id = selection.selected, let run = runs.record(id) {
                // The same result as beside a grid and in the Result window.
                RunResultView(run: run, runs: runs, showRun: { selection.selected = $0 })
                    .id(run.id)
                    .controlSize(.large)
            } else {
                VStack(spacing: 14) {
                    IconTile(symbol: "list.bullet.rectangle.fill", size: 64)
                    Text("Pick a run to see what it printed")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("Every run of a script or a flow is kept here, live while it runs.")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        ForEach(GridKind.allCases, id: \.self) { kind in
                            Button { AppModel.shared.openGrid(kind) } label: { Label(kind.title, systemImage: kind.symbol) }
                                .help("Open the \(kind.title) grid")
                        }
                        Button { Windows.showAPIBoard() } label: { Label("API", systemImage: APIBoardView.symbol) }
                            .help("Open the API board: everything other apps can run, each a click away")
                        Button { Windows.showAutomationBoard() } label: { Label("Automation", systemImage: AutomationBoardView.symbol) }
                            .help("Open the Automation board: what runs by itself, by schedule or trigger")
                    }
                    .buttonStyle(SoftButtonStyle(large: true))
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Backdrop())
            }
        }
    }

    /// Each flow's steps, in order, gathered in one pass.
    static func stepsByParent(_ records: [RunRecord]) -> [UUID: [RunRecord]] {
        var steps: [UUID: [RunRecord]] = [:]
        for r in records {
            if let parent = r.parent { steps[parent, default: []].append(r) }
        }
        return steps
    }
}

struct RunRow: View {
    let run: RunRecord
    let indent: Bool
    @ObservedObject private var prompts = PromptCenter.shared

    var body: some View {
        let waiting = run.state == .running && prompts.pending(for: run.id) != nil
        let color = waiting ? Color.orange : Theme.color(run.state)
        HStack(spacing: 10) {
            if indent {
                // A flow's step hangs off its flow.
                Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 2).padding(.vertical, -4)
            }
            Image(systemName: waiting ? "hand.raised.fill" : Theme.symbol(run.state))
                .font(.system(size: indent ? 11 : 13, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: indent ? 22 : 28, height: indent ? 22 : 28)
                .background(Circle().fill(color.opacity(0.14)))
                .help(waiting ? "Waiting for your answer" : run.state.title)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(run.name + (run.arguments.isEmpty ? "" : " " + run.arguments.map(ShellEnvironment.quote).joined(separator: " ")))
                        .lineLimit(1)
                        .font(indent ? .callout : .body.weight(.medium))
                    if let by = run.requestedBy {
                        Image(systemName: run.isAutomated ? "clock.badge.checkmark" : "network")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help(run.isAutomated ? "Started by itself (\(by.dropFirst(RunRecord.automationPrefix.count + 2)))" : "Asked for over the HTTP API by \(by)")
                    }
                }
                HStack(spacing: 4) {
                    Text(run.started.formatted(date: .omitted, time: .shortened))
                    if run.state == .running {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text("· running \(RunRecord.duration(ctx.date.timeIntervalSince(run.started)))")
                        }
                    } else {
                        Text("· \(run.state.title.lowercased())" + (run.seconds.map { " in \(RunRecord.duration($0))" } ?? ""))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, indent ? 12 : 0)
        .padding(.vertical, indent ? 1 : 3)
    }
}

/// What a run printed, its errors in red, following the end while it runs. A lot of output
/// shows its end (the rest a click away), and is built once per change, not once per showing.
struct OutputText: View {
    let run: RunRecord
    /// Goes up each time the output changes (`RunStore.version`).
    let version: Int
    @State private var showAll = false

    var body: some View {
        let shown = OutputCache.shared.shown(run, version: version, all: showAll)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if run.trimmed {
                        Text("(The earliest output was dropped: only the last \(RunRecord.maxOutput / 1000) KB is kept.)")
                            .foregroundStyle(Theme.terminalText.opacity(0.5))
                            .padding(.bottom, 6)
                    }
                    if shown.hiddenBytes > 0 {
                        HStack(spacing: 8) {
                            Text("(Showing the last \(OutputCache.tailBytes / 1000) KB.)")
                                .foregroundStyle(Theme.terminalText.opacity(0.5))
                            Button("Show All (\(max(1, (shown.hiddenBytes + OutputCache.tailBytes) / 1000)) KB)") { showAll = true }
                                .buttonStyle(.link)
                        }
                        .padding(.bottom, 6)
                    }
                    if run.output.isEmpty {
                        Text(run.state == .running ? "Nothing printed yet…" : "It printed nothing.")
                            .foregroundStyle(Theme.terminalText.opacity(0.5))
                    } else {
                        Text(shown.text)
                            .foregroundStyle(Theme.terminalText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if run.state == .running {
                        // A cursor: it's still going.
                        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                            Rectangle().fill(Theme.terminalText)
                                .frame(width: 7, height: 14)
                                .opacity(Int(ctx.date.timeIntervalSinceReferenceDate * 2) % 2 == 0 ? 0.8 : 0)
                        }
                        .padding(.top, 2)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .font(.system(size: 12.5, design: .monospaced))
                .lineSpacing(2)
                .padding(14)
            }
            .background(Theme.terminal)
            .environment(\.colorScheme, .dark)
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            // The version keeps going up even when the output is at its cap (its length the same).
            .onChange(of: version) { _, _ in
                if run.state == .running { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }
}

/// The output as shown, built once for each change of a run's output.
@MainActor
final class OutputCache {
    static let shared = OutputCache()
    /// How much of a long output shows until Show All.
    static let tailBytes = 64_000

    struct Shown {
        let text: AttributedString
        /// How much from the start isn't shown.
        let hiddenBytes: Int
    }

    private struct Entry {
        let version: Int
        let chunks: Int
        let all: Bool
        let shown: Shown
    }

    private var entries: [UUID: Entry] = [:]

    func shown(_ run: RunRecord, version: Int, all: Bool) -> Shown {
        if let e = entries[run.id], e.version == version, e.chunks == run.output.count, e.all == all { return e.shown }
        let shown = Self.build(run.output, all: all)
        if entries.count > 16 { entries.removeAll() }
        entries[run.id] = Entry(version: version, chunks: run.output.count, all: all, shown: shown)
        return shown
    }

    static func build(_ chunks: [RunRecord.Chunk], all: Bool) -> Shown {
        var total = 0
        for c in chunks { total += c.text.utf8.count }
        var s = AttributedString()
        if all || total <= tailBytes {
            for c in chunks { s += part(c.stream, c.text) }
            return Shown(text: s, hiddenBytes: 0)
        }
        // The end only: whole pieces from the last back, the first of them cut.
        var picked: [(RunCore.OutputStream, String)] = []
        var need = tailBytes
        for c in chunks.reversed() {
            let n = c.text.utf8.count
            if n <= need {
                picked.append((c.stream, c.text))
                need -= n
            } else {
                let utf8 = c.text.utf8
                var start = utf8.index(utf8.endIndex, offsetBy: -need)
                // Not in the middle of a character.
                while start < utf8.endIndex, utf8[start] & 0xC0 == 0x80 { utf8.formIndex(after: &start) }
                picked.append((c.stream, String(c.text[start...])))
                need = 0
            }
            if need == 0 { break }
        }
        var shownBytes = 0
        for (stream, text) in picked.reversed() {
            s += part(stream, text)
            shownBytes += text.utf8.count
        }
        return Shown(text: s, hiddenBytes: max(0, total - shownBytes))
    }

    private static func part(_ stream: RunCore.OutputStream, _ text: String) -> AttributedString {
        var p = AttributedString()
        // Links (a page EPA's next step names, the Atlas) open with a click.
        var at = text.startIndex
        for link in Links.find(in: text) {
            p += AttributedString(String(text[at..<link.range.lowerBound]))
            var l = AttributedString(String(text[link.range]))
            l.link = link.url
            p += l
            at = link.range.upperBound
        }
        p += AttributedString(String(text[at...]))
        if stream == .err { p.foregroundColor = Theme.terminalError }
        return p
    }
}

/// Under the editor: the latest run of what's being edited.
struct OutputPanel: View {
    let run: RunRecord
    @ObservedObject var runs: RunStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: Theme.symbol(run.state)).foregroundStyle(Theme.color(run.state))
                Text(StatusLine.summary(run)).fontWeight(.medium)
                if run.state == .running {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(RunRecord.duration(ctx.date.timeIntervalSince(run.started))).monospacedDigit()
                    }
                } else {
                    Text("· \(ago(run.ended ?? run.started))").foregroundStyle(.secondary)
                }
                Spacer()
                if run.state == .running {
                    Button { runs.stop(run.id) } label: { Label("Stop", systemImage: "stop.fill") }
                        .buttonStyle(SoftButtonStyle(tint: .red))
                }
                Button { Windows.showRuns(run.id) } label: { Label("Open in Runs", systemImage: "arrow.up.forward.app") }
                    .buttonStyle(SoftButtonStyle())
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            if let problem = run.problem {
                Text(problem)
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(Theme.color(run.state))
            }
            Divider()
            RunAttention(run: run, runs: runs)
            OutputText(run: run, version: runs.version(run.id))
                .id(run.id)
            if run.state == .running && runs.acceptsInput(run.id) {
                Divider()
                InputBar(run: run.id, runs: runs)
                    .id(run.id)  // what was typed for one run never goes to another
            }
        }
    }
}
