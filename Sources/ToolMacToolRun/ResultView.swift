import AppKit
import RunCore
import SwiftUI

/// A run's result, all in one place: how it went (big), what to do next (Run Again, or Stop), what
/// it printed (live while it runs), the question it's waiting on, and for a flow each step's own
/// output a click away (a failed step's is shown first). Beside a grid it's the grid's result
/// pane; elsewhere (a notice, the panel) it's the Result window.
struct RunResultView: View {
    let run: RunRecord
    @ObservedObject var runs: RunStore
    /// A new run was started from here (Run Again): the view should show it.
    var showRun: (UUID) -> Void = { _ in }
    /// The pane's close button (nil: none, in a window of its own).
    var close: (() -> Void)?

    /// Which output shows: the flow's own, or one of its steps'.
    private enum Choice: Hashable {
        case flow
        case step(UUID)
    }

    @State private var choice: Choice?

    var body: some View {
        let steps = run.kind == .flow ? runs.steps(of: run.id) : []
        let shown = shownRecord(steps)
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                header
                if let by = run.requestedBy {
                    Label("Asked for over the HTTP API by \(by), and allowed", systemImage: "network")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let problem = run.problem {
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 2).fill(Theme.color(run.state)).frame(width: 4)
                        Text(problem)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(10)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.color(run.state).opacity(0.1)))
                }
                if !steps.isEmpty { stepStrip(steps, shown: shown) }
            }
            .padding(16)
            Divider()
            RunAttention(run: run, runs: runs)
            OutputText(run: shown, version: runs.version(shown.id))
                .id(shown.id)
            if shown.state == .running && runs.acceptsInput(shown.id) {
                Divider()
                InputBar(run: shown.id, runs: runs)
                    .id(shown.id)  // what was typed for one run never goes to another
            }
            commandBar(shown)
        }
    }

    // MARK: the top

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            IconTile(symbol: Theme.symbol(run.state), color: Theme.color(run.state), size: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text(run.name)
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Pill(text: Self.headline(run), color: Theme.color(run.state), filled: true)
                    if run.state == .running {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text(RunRecord.duration(ctx.date.timeIntervalSince(run.started))).monospacedDigit()
                        }
                    } else {
                        if let s = run.seconds { Text("in \(RunRecord.duration(s)) ·") }
                        Text(ago(run.ended ?? run.started))
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            if run.state == .running {
                // A step is stopped by stopping its flow.
                Button { runs.stop(run.id) } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(ProminentButtonStyle(color: .red))
                    .keyboardShortcut(".")
                    .help("Stop it (⌘.)")
            } else if canRunAgain {
                Button { again() } label: { Label("Run Again", systemImage: "arrow.clockwise") }
                    .buttonStyle(ProminentButtonStyle())
                    .help("Run it again with the same arguments")
            }
            CopyButton(help: "Copy everything it printed", size: 30) { run.kind == .flow ? flowText : run.text }
                .disabled(run.output.isEmpty && !runs.steps(of: run.id).contains { !$0.output.isEmpty })
            Menu {
                if let item = item {
                    Button("Edit \(item.id)") { Windows.showEditor(item, kind: kind) }
                }
                Button("Copy Command for Terminal") { copy(run.command) }
                Button("Open in Runs") { Windows.showRuns(run.id) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
            if let close {
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(CircleIconButtonStyle(size: 30))
                    .help("Hide the result (Result, at the top, shows it again)")
            }
        }
    }

    /// The flow's own output, then a chip for each step: a click shows that step's output.
    private func stepStrip(_ steps: [RunRecord], shown: RunRecord) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                StepChip(title: "Flow", symbol: "point.3.connected.trianglepath.dotted", color: .accentColor,
                         selected: shown.id == run.id) { choice = .flow }
                    .help("What the flow itself printed: each step as it started and ended, and what it showed")
                ForEach(steps) { step in
                    StepChip(title: step.name, symbol: Theme.symbol(step.state), color: Theme.color(step.state),
                             detail: step.seconds.map { RunRecord.duration($0) }, selected: shown.id == step.id) { choice = .step(step.id) }
                        .help("\(step.name): \(step.state.title.lowercased())" + (step.ending.map { ", \($0.summary)" } ?? "") + ". Click to see what it printed.")
                }
            }
        }
    }

    /// What the output shows: what was picked, else a flow's failed step (where the reason is),
    /// else the run itself.
    private func shownRecord(_ steps: [RunRecord]) -> RunRecord {
        switch choice {
        case .flow:
            return run
        case let .step(id):
            return steps.first { $0.id == id } ?? run
        case nil:
            if run.state == .failed, let failed = steps.last(where: { $0.state == .failed || $0.state == .couldNotStart }) {
                return failed
            }
            return run
        }
    }

    private func commandBar(_ shown: RunRecord) -> some View {
        HStack(spacing: 8) {
            Text("$").foregroundStyle(.tertiary)
            Text(shown.command)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            CopyButton(help: "Copy the command, to run it in a terminal", size: 22) { shown.command }
        }
        .font(.caption.monospaced())
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.04))
    }

    // MARK: what it does

    /// "Succeeded", "Failed: exit code 3", "Couldn't start"…
    static func headline(_ r: RunRecord) -> String {
        switch r.state {
        case .failed: return "Failed" + (r.ending.map { ": \($0.summary)" } ?? "")
        default: return r.state.title
        }
    }

    private var kind: GridKind { run.kind == .flow ? .composer : .scripts }

    /// The script or flow it ran, when it's still in the folder.
    private var item: ScriptItem? {
        guard run.kind != .step, let file = run.file else { return nil }
        return AppModel.shared.items(kind).first { $0.id == file }
    }

    private var canRunAgain: Bool { item != nil }

    private func again() {
        guard let item else { return }
        let app = AppModel.shared
        GridActions(app: app, kind: kind).run(item, arguments: run.arguments.map(ShellEnvironment.quote).joined(separator: " ")) { id in
            showRun(id)
        }
    }

    /// A flow's output with each step's under it, as it would read in a terminal.
    private var flowText: String {
        var s = run.text
        for step in runs.steps(of: run.id) where !step.output.isEmpty {
            s += "\n── \(step.name) ──\n" + step.text
        }
        return s
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

/// One of a flow's steps (or the flow itself), to pick whose output shows.
private struct StepChip: View {
    let title: String
    let symbol: String
    let color: Color
    var detail: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).foregroundStyle(selected ? Color.white : color)
                Text(title).lineLimit(1)
                if let detail { Text(detail).opacity(0.7).monospacedDigit() }
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(Capsule().fill(selected ? color : Color.primary.opacity(0.06)))
            .overlay(Capsule().strokeBorder(color.opacity(selected ? 0 : 0.25)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Beside a grid: the result of the run started from it last (or of the cell whose result was
/// clicked), live while it runs. Nothing to open, nothing to pick.
struct ResultPane: View {
    let kind: GridKind
    let run: RunRecord?
    @ObservedObject var runs: RunStore
    let show: (UUID) -> Void
    let close: () -> Void

    var body: some View {
        Group {
            if let run {
                RunResultView(run: run, runs: runs, showRun: show, close: close)
                    .id(run.id)
            } else {
                VStack(spacing: 12) {
                    HStack {
                        Spacer()
                        Button(action: close) { Image(systemName: "xmark") }
                            .buttonStyle(CircleIconButtonStyle(size: 28))
                            .help("Hide the result pane")
                    }
                    Spacer()
                    IconTile(symbol: "text.alignleft", size: 52)
                    Text("Results show here")
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                    Text(kind == .scripts
                         ? "Click a cell to run it: what it prints shows here as it prints it, and how it went when it's done."
                         : "Click a flow to run it: what it prints, each step's output, and how it went show here.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.10), radius: 14, y: 5)
    }
}

/// The Result window: one run's result, for a run that ended (or is going) away from its grid.
struct ResultWindowView: View {
    @ObservedObject var runs: RunStore
    @ObservedObject var selection: RunsSelection

    var body: some View {
        Group {
            if let id = selection.selected, let run = runs.record(id) {
                RunResultView(run: run, runs: runs, showRun: { selection.selected = $0 })
                    .id(run.id)
            } else {
                VStack(spacing: 12) {
                    IconTile(symbol: "tray", size: 52)
                    Text("That run isn't kept any more").font(.system(size: 19, weight: .bold, design: .rounded))
                    Button("All Runs") { Windows.showRuns(nil) }.buttonStyle(SoftButtonStyle(large: true))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 560, minHeight: 380)
        .background(Backdrop())
        .controlSize(.large)
    }
}
