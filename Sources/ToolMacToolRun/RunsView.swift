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
                    Text("No runs yet. Click a cell in a grid to run it.")
                        .foregroundStyle(.secondary)
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
                RunDetail(run: run, runs: runs)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "list.bullet.rectangle").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("Pick a run on the left to see what it printed.").foregroundStyle(.secondary)
                    HStack {
                        Button("Open the Scripts Grid") { AppModel.shared.openGrid(.scripts) }
                        Button("Open the Composer Grid") { AppModel.shared.openGrid(.composer) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: Theme.symbol(run.state))
                .foregroundStyle(Theme.color(run.state))
            VStack(alignment: .leading, spacing: 1) {
                Text(run.name + (run.arguments.isEmpty ? "" : " " + run.arguments.map(ShellEnvironment.quote).joined(separator: " ")))
                    .lineLimit(1)
                    .font(indent ? .callout : .body)
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
        .padding(.leading, indent ? 18 : 0)
    }
}

struct RunDetail: View {
    let run: RunRecord
    @ObservedObject var runs: RunStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: Theme.symbol(run.state))
                        .font(.title)
                        .foregroundStyle(Theme.color(run.state))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(run.name).font(.title2.weight(.semibold)).lineLimit(1)
                        HStack(spacing: 6) {
                            Text(run.state.title)
                            if let ending = run.ending, run.state == .failed { Text("· \(ending.summary)") }
                            Text("· started \(run.started.formatted(date: .abbreviated, time: .standard))")
                            if run.state == .running {
                                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                                    Text("· \(RunRecord.duration(ctx.date.timeIntervalSince(run.started)))").monospacedDigit()
                                }
                            } else if let s = run.seconds {
                                Text("· took \(RunRecord.duration(s))")
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if run.state == .running {
                        // A step is stopped by stopping its flow.
                        Button { runs.stop(run.id) } label: { Label(run.kind == .step ? "Stop Flow" : "Stop", systemImage: "stop.fill") }
                            .keyboardShortcut(".")
                            .help(run.kind == .step ? "Stop the flow this step is part of (⌘.)" : "Stop it (⌘.)")
                    } else if run.kind != .step {
                        Button { again() } label: { Label("Run Again", systemImage: "arrow.clockwise") }
                            .help("Run it again with the same arguments")
                    }
                    Button { copy(run.text) } label: { Label("Copy Output", systemImage: "doc.on.doc") }
                        .disabled(run.output.isEmpty)
                }
                HStack(spacing: 6) {
                    Text(run.command)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .foregroundStyle(.secondary)
                    Button { copy(run.command) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .help("Copy the command, to run it in a terminal")
                }
                if let problem = run.problem {
                    Text(problem)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.color(run.state).opacity(0.1)))
                }
            }
            .padding(16)
            Divider()
            OutputText(run: run, version: runs.version(run.id))
                .id(run.id)
        }
        .controlSize(.large)
    }

    private func again() {
        let app = AppModel.shared
        let kind: GridKind = run.kind == .flow ? .composer : .scripts
        guard let item = app.items(kind).first(where: { $0.id == run.file }) else { return }
        GridActions(app: app, kind: kind).run(item, arguments: run.arguments.map(ShellEnvironment.quote).joined(separator: " "))
        if let latest = app.runs.latest(file: item.id, kind: kind) { Windows.runsSelection.selected = latest.id }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
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
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 6)
                    }
                    if shown.hiddenBytes > 0 {
                        HStack(spacing: 8) {
                            Text("(Showing the last \(OutputCache.tailBytes / 1000) KB.)")
                                .foregroundStyle(.secondary)
                            Button("Show All (\(max(1, (shown.hiddenBytes + OutputCache.tailBytes) / 1000)) KB)") { showAll = true }
                                .buttonStyle(.link)
                        }
                        .padding(.bottom, 6)
                    }
                    if run.output.isEmpty {
                        Text(run.state == .running ? "Nothing printed yet…" : "It printed nothing.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(shown.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .font(.system(size: 12, design: .monospaced))
                .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor))
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
        var p = AttributedString(text)
        if stream == .err { p.foregroundColor = Color.red }
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
                Text(StatusLine.summary(run))
                if run.state == .running {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(RunRecord.duration(ctx.date.timeIntervalSince(run.started))).monospacedDigit()
                    }
                } else {
                    Text("· \(ago(run.ended ?? run.started))").foregroundStyle(.secondary)
                }
                Spacer()
                if run.state == .running {
                    Button("Stop") { runs.stop(run.id) }
                }
                Button("Open in Runs") { Windows.showRuns(run.id) }
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
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
            OutputText(run: run, version: runs.version(run.id))
                .id(run.id)
        }
    }
}
