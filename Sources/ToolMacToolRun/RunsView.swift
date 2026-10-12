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
                let top = runs.records.reversed().filter { $0.parent == nil }
                if top.isEmpty {
                    Text("No runs yet. Click a cell in a grid to run it.")
                        .foregroundStyle(.secondary)
                }
                ForEach(top) { run in
                    RunRow(run: run, indent: false).tag(run.id)
                    ForEach(runs.steps(of: run.id)) { step in
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
                            if let code = run.code, run.state != .running { Text("· exit code \(code)") }
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
                        Button { runs.stop(run.id) } label: { Label("Stop", systemImage: "stop.fill") }
                            .keyboardShortcut(".")
                            .help("Stop it (⌘.)")
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
            OutputText(run: run)
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

/// What a run printed, its errors in red, following the end while it runs.
struct OutputText: View {
    let run: RunRecord

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if run.trimmed {
                        Text("(The earliest output was dropped: only the last \(RunRecord.maxOutput / 1000) KB is kept.)")
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 6)
                    }
                    if run.output.isEmpty {
                        Text(run.state == .running ? "Nothing printed yet…" : "It printed nothing.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(Self.attributed(run.output))
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
            .onChange(of: run.text.utf8.count) { _, _ in
                if run.state == .running { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    static func attributed(_ chunks: [RunRecord.Chunk]) -> AttributedString {
        var s = AttributedString()
        for c in chunks {
            var part = AttributedString(c.text)
            if c.stream == .err { part.foregroundColor = .red }
            s += part
        }
        return s
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
            OutputText(run: run)
        }
    }
}
