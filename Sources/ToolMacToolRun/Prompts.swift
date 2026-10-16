import AppKit
import RunCore
import SwiftUI

/// The questions running flows are waiting on (`confirm`, `askYesNo`, `ask`, `choose`). A flow
/// asks from its own thread and waits there; the question shows in a small window that comes
/// forward, on the flow's cell, under the editor and in Runs, and any of them answers it. Stopping
/// the flow answers Stop. A question left a while gets a notification.
@MainActor
final class PromptCenter: ObservableObject {
    static let shared = PromptCenter()

    struct Pending: Identifiable {
        let id = UUID()
        /// The run asking.
        let run: UUID
        /// What's asking (the flow's file name).
        let source: String
        let question: FlowQuestion
        let asked = Date()
        fileprivate let reply: Reply
    }

    /// Where the flow's thread waits for its answer.
    final class Reply: @unchecked Sendable {
        private let lock = NSLock()
        private var answer: FlowAnswer?
        private let done = DispatchSemaphore(value: 0)

        func give(_ a: FlowAnswer) {
            lock.lock()
            guard answer == nil else {
                lock.unlock()
                return
            }
            answer = a
            lock.unlock()
            done.signal()
        }

        func wait() -> FlowAnswer {
            done.wait()
            lock.lock()
            defer { lock.unlock() }
            return answer ?? .stop
        }
    }

    @Published private(set) var pending: [Pending] = []

    /// Asks, from a flow's thread, and waits for the answer.
    nonisolated static func ask(run: UUID, from source: String, _ question: FlowQuestion) -> FlowAnswer {
        let reply = Reply()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                PromptCenter.shared.add(Pending(run: run, source: source, question: question, reply: reply))
            }
        }
        return reply.wait()
    }

    private func add(_ p: Pending) {
        // Stopped while the question was on its way: it's answered at once.
        guard AppModel.shared.runs.isRunning(p.run), !AppModel.shared.runs.isStopping(p.run) else {
            p.reply.give(.stop)
            return
        }
        pending.append(p)
        // A result is in the output already.
        if p.question.kind != .result { AppModel.shared.runs.note(p.run, "❓ \(p.question.prompt)") }
        Windows.showPrompt()
        // Not answered in a while (the window went behind something): a notification.
        let id = p.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            MainActor.assumeIsolated {
                guard let still = PromptCenter.shared.pending.first(where: { $0.id == id }) else { return }
                Notifier.post(title: "\(still.source) is waiting for you", body: still.question.prompt, run: still.run, tone: .waiting)
            }
        }
    }

    /// Answers a question: the flow goes on (or stops).
    func answer(_ id: UUID, _ a: FlowAnswer) {
        guard let i = pending.firstIndex(where: { $0.id == id }) else { return }
        let p = pending.remove(at: i)
        if p.question.kind != .result || a == .stop { AppModel.shared.runs.note(p.run, "   → " + Self.describe(a, p.question)) }
        p.reply.give(a)
        if pending.isEmpty { Windows.close("prompt") }
    }

    /// The run stopped: what it was asking is answered Stop.
    func cancel(run: UUID) {
        for p in pending where p.run == run { p.reply.give(.stop) }
        pending.removeAll { $0.run == run }
        if pending.isEmpty { Windows.close("prompt") }
    }

    func pending(for run: UUID) -> Pending? { pending.first { $0.run == run } }

    static func describe(_ a: FlowAnswer, _ q: FlowQuestion) -> String {
        switch a {
        case .yes: q.kind == .proceed ? (q.destructive ? "Go Ahead" : "Continue") : q.kind == .result ? "Done" : "Yes"
        case .no: "No"
        // A secret (a key EPA asked for) is never written into the run's history.
        case let .text(t): q.secret ? "(typed, not shown)" : t.isEmpty ? "(nothing typed)" : t
        case .stop: "Stop"
        case .unavailable: "No one to answer"
        }
    }
}

/// The question window: the first question waiting (and how many more).
struct PromptWindowView: View {
    @ObservedObject var center: PromptCenter

    var body: some View {
        Group {
            if let p = center.pending.first {
                PromptCard(pending: p, more: center.pending.count - 1, showRun: true)
                    .id(p.id)
                    .padding(.top, 14)
            } else {
                Text("Nothing's waiting for an answer.")
                    .foregroundStyle(.secondary)
                    .padding(30)
            }
        }
        .frame(width: 520)
        .background(Backdrop())
    }
}

/// One question: what's asking, the question, and its answers. Return gives the main answer,
/// Escape stops the flow.
struct PromptCard: View {
    let pending: PromptCenter.Pending
    var more = 0
    /// In its own window: a link to the run's output.
    var showRun = false
    var compact = false
    @State private var text = ""
    @State private var choice: String?
    @FocusState private var focused: Bool

    private var q: FlowQuestion { pending.question }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 14) {
            HStack(alignment: .top, spacing: 12) {
                IconTile(symbol: symbol, color: q.destructive ? .red : q.kind == .result ? .accentColor : .orange, size: compact ? 28 : 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text((q.kind == .result ? "\(pending.source) shows you" : "\(pending.source) is waiting for you").uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(q.destructive ? Color.red : .secondary)
                    if q.kind != .result {
                        Text(q.prompt)
                            .font(compact ? .headline : .system(size: 19, weight: .semibold, design: .rounded))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
            answerField
            if q.link != nil || q.savedAs != nil {
                // Where the answer comes from (EPA opened it in the browser too), and where it's kept.
                HStack(spacing: 10) {
                    if let link = q.link {
                        Button { NSWorkspace.shared.open(link) } label: { Label("Open the Page", systemImage: "safari") }
                            .help("Where it's made: \(link.absoluteString)")
                    }
                    if let saved = q.savedAs {
                        Text("EPA checks it, then saves it to .env as \(saved).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if more > 0 { Text("\(more) more waiting").font(.caption).foregroundStyle(.secondary) }
                if showRun {
                    Button("Show Output") { Windows.showRuns(pending.run) }
                        .buttonStyle(.link)
                }
                Spacer()
                Button("Stop Flow") { answer(.stop) }
                    .buttonStyle(SoftButtonStyle(large: !compact))
                    .shortcut(compact ? nil : .cancelAction)
                    .help("End the flow here: nothing after this question runs (Escape)")
                if q.kind == .yesNo {
                    Button("No") { answer(.no) }
                        .buttonStyle(SoftButtonStyle(large: !compact))
                }
                // What can't be undone isn't on Return: it takes a click on the button that says so.
                Button(primaryTitle) { primary() }
                    .buttonStyle(ProminentButtonStyle(color: q.destructive ? .red : .accentColor, large: !compact))
                    .shortcut(compact || q.destructive ? nil : .defaultAction)
                    .disabled(primaryDisabled)
            }
        }
        .padding(compact ? 12 : 24)
        .onAppear {
            if case let .choice(options) = q.kind { choice = options.first }
            focused = true
        }
    }

    private var symbol: String {
        if q.destructive { return "exclamationmark.triangle.fill" }
        return switch q.kind {
        case .proceed: "hand.raised.fill"
        case .yesNo: "questionmark.circle.fill"
        case .text: "character.cursor.ibeam"
        case .choice: "list.bullet.circle.fill"
        case .result: "text.bubble.fill"
        }
    }

    private var note: String {
        if q.destructive { return "Going ahead can't be undone. Go Ahead carries on (Return doesn't, on purpose); Stop Flow ends it here, and nothing is changed." }
        if q.secret { return "What you type goes straight to it: it isn't shown, and isn't kept in the run's output. Stop Flow ends it here." }
        return switch q.kind {
        case .proceed: "The flow has stopped here to ask. Continue carries on; Stop Flow ends it, and nothing after this runs."
        case .yesNo: "The flow goes on either way: it decides what to do with Yes or No. Stop Flow ends it here."
        case .text: "What you type goes to the flow. Stop Flow ends it here."
        case .choice: "Pick one; the flow goes on with it. Stop Flow ends it here."
        case .result: "Done carries on with the flow; Stop Flow ends it here. It's in the run's output too."
        }
    }

    private var primaryTitle: String {
        switch q.kind {
        case .proceed: q.destructive ? "Go Ahead" : "Continue"
        case .yesNo: "Yes"
        case .text: "OK"
        case .choice: "Choose"
        case .result: "Done"
        }
    }

    private var primaryDisabled: Bool {
        if case .choice = q.kind { return choice == nil }
        return false
    }

    @ViewBuilder
    private var answerField: some View {
        switch q.kind {
        case .text where q.secret:
            SecureField("Paste or type it (it isn't shown)", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { primary() }
        case .text:
            TextField("Your answer", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { primary() }
        case let .choice(options):
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                        Button {
                            choice = option
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: choice == option ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(choice == option ? Color.accentColor : .secondary)
                                Text(option)
                                Spacer()
                            }
                            .padding(.vertical, 7)
                            .padding(.horizontal, 10)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(choice == option ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04)))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(choice == option ? Color.accentColor.opacity(0.5) : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(TapGesture(count: 2).onEnded { answer(.text(option)) })
                    }
                }
            }
            .frame(maxHeight: 220)
        case .result:
            ScrollView {
                Text(q.prompt)
                    .font(compact ? .callout : .body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: compact ? 140 : 340)
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
            HStack {
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(q.prompt, forType: .string)
                } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help("Copy the text")
            }
        default:
            EmptyView()
        }
    }

    private func primary() {
        switch q.kind {
        case .proceed, .yesNo, .result: answer(.yes)
        case .text: answer(.text(text))
        case .choice: if let choice { answer(.text(choice)) }
        }
    }

    private func answer(_ a: FlowAnswer) {
        PromptCenter.shared.answer(pending.id, a)
    }
}

/// Under a run's output: a line to type into a script that asks for typed answers, sent with
/// Return (shown in its output, as a terminal would, unless hidden for a password).
struct InputBar: View {
    let run: UUID
    @ObservedObject var runs: RunStore
    @State private var line = ""
    @State private var hidden = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "keyboard")
                .foregroundStyle(.secondary)
                .help("It looks like it asks for typed answers: type them here")
            Group {
                if hidden {
                    SecureField("Type an answer for it, then Return", text: $line)
                } else {
                    TextField("Type an answer for it, then Return", text: $line)
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(Theme.mono)
            .focused($focused)
            .onSubmit(send)
            Button { hidden.toggle() } label: { Image(systemName: hidden ? "eye.slash" : "eye") }
                .buttonStyle(.borderless)
                .help(hidden ? "What's typed is hidden (for a password), and isn't shown in the output" : "Hide what's typed (for a password)")
            Button("Send", action: send)
                .disabled(line.isEmpty)
            Button("End Input") { runs.endInput(run) }
                .help("Tell it there's nothing more to type (Control-D in a terminal)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.07))
        .onAppear { focused = true }
    }

    private func send() {
        runs.send(run, line, echo: !hidden)
        line = ""
        focused = true
    }
}

/// What's waiting on a run, above its output: its question to answer, or a hint when it's gone quiet.
struct RunAttention: View {
    let run: RunRecord
    @ObservedObject var runs: RunStore
    @ObservedObject var prompts = PromptCenter.shared

    var body: some View {
        if run.state == .running {
            if let p = prompts.pending(for: run.id) {
                PromptCard(pending: p, compact: true)
                    .id(p.id)  // a new question (or another run's) starts with nothing typed
                    .background(Color.orange.opacity(0.08))
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let quiet = runs.quietFor(run.id, now: ctx.date)
                    if quiet >= 20 {
                        Label(runs.acceptsInput(run.id)
                              ? "Nothing printed for \(RunRecord.duration(quiet)): it may be waiting for you to type something below."
                              : "Nothing printed for \(RunRecord.duration(quiet)). It's still running; Stop ends it.",
                              systemImage: "hourglass")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}

extension View {
    /// A keyboard shortcut, or none.
    @ViewBuilder
    func shortcut(_ s: KeyboardShortcut?) -> some View {
        if let s { keyboardShortcut(s) } else { self }
    }
}
