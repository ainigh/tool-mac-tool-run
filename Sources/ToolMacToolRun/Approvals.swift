import AppKit
import RunCore
import SwiftUI

/// Another app asking, over the API, to run a script or a flow: a large card near the top of the
/// screen saying who's asking, what would run (the exact command, or the Flow code in full) and
/// what it looks like it does, with Run and Don't Run. Nothing runs until Run is clicked. It never
/// takes the keyboard (Return can't say yes for you), it waits two minutes and then answers Don't
/// Run by itself, and a caller that hangs up takes its question away.
@MainActor
final class ApprovalCenter: ObservableObject {
    static let shared = ApprovalCenter()

    struct Pending: Identifiable {
        var id: UUID { request.id }
        let request: RunRequest
        let asked = Date()
        fileprivate let reply: ApprovalReply
    }

    /// How long a question waits for an answer, in seconds.
    static let wait: TimeInterval = 120

    @Published private(set) var pending: [Pending] = []
    private var panel: NoticePanel?

    /// Asks, from the API's request, and waits for the answer.
    nonisolated static func ask(_ request: RunRequest) async -> Approval {
        let reply = ApprovalReply()
        let id = request.id
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Approval, Never>) in
                reply.wait(c)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { ApprovalCenter.shared.add(Pending(request: request, reply: reply)) }
                }
            }
        } onCancel: {
            // The caller went: it's answered (nothing runs) and the card goes.
            reply.give(.denied)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { ApprovalCenter.shared.withdraw(id) }
            }
        }
    }

    private func add(_ p: Pending) {
        guard !p.reply.answered else { return }
        pending.append(p)
        NSSound(named: "Submarine")?.play()
        present()
        let id = p.id
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.wait) {
            MainActor.assumeIsolated {
                guard let still = ApprovalCenter.shared.pending.first(where: { $0.id == id }) else { return }
                ApprovalCenter.shared.answer(id, .unanswered)
                let r = still.request
                Notifier.post(title: r.isStop ? "\(r.name) kept running" : "\(r.name) didn't run",
                              body: r.isStop ? "\(r.client) asked to stop it, and it wasn't allowed in time. It can ask again."
                                  : "\(r.client) asked to run it, and it wasn't allowed in time. It can ask again.",
                              tone: .stopped)
            }
        }
    }

    func answer(_ id: UUID, _ a: Approval) {
        guard let i = pending.firstIndex(where: { $0.id == id }) else { return }
        let p = pending.remove(at: i)
        p.reply.give(a)
        if pending.isEmpty { hide() }
    }

    /// The caller hung up before it was answered.
    private func withdraw(_ id: UUID) {
        guard let i = pending.firstIndex(where: { $0.id == id }) else { return }
        pending.remove(at: i)
        if pending.isEmpty { hide() }
    }

    /// Brings the card forward again (the panel's banner, the menu bar icon).
    func show() {
        guard !pending.isEmpty else { return }
        present()
        panel?.orderFrontRegardless()
    }

    // MARK: the panel

    /// Wide enough for a command, high on the screen the pointer is on (notices go in its middle).
    private static func frame() -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let v = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: min(760, max(600, (v.width * 0.46).rounded())), height: min(v.height - 40, 560))
        return NSRect(x: v.midX - size.width / 2, y: v.maxY - size.height - v.height * 0.06, width: size.width, height: size.height)
    }

    private func present() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        guard !panel.isVisible else { return }
        panel.setFrame(Self.frame(), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                if ApprovalCenter.shared.pending.isEmpty { panel.orderOut(nil) } else { panel.alphaValue = 1 }
            }
        })
    }

    private func makePanel() -> NoticePanel {
        let panel = NoticePanel(contentRect: Self.frame(), styleMask: [.nonactivatingPanel, .borderless],
                                backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        // Over the notices: this one is waiting on you.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: ApprovalStackView(center: self))
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }
}

/// Where the request waits for its answer: given once (a click, the time running out, the caller
/// hanging up), whichever comes first.
final class ApprovalReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Approval, Never>?
    private var answer: Approval?

    var answered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return answer != nil
    }

    func wait(_ c: CheckedContinuation<Approval, Never>) {
        lock.lock()
        if let answer {
            lock.unlock()
            c.resume(returning: answer)
            return
        }
        continuation = c
        lock.unlock()
    }

    func give(_ a: Approval) {
        lock.lock()
        guard answer == nil else {
            lock.unlock()
            return
        }
        answer = a
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: a)
    }
}

/// The front question, and a card behind it for each more waiting (up to two).
struct ApprovalStackView: View {
    @ObservedObject var center: ApprovalCenter

    var body: some View {
        GeometryReader { geo in
            let inset: CGFloat = 28
            let size = CGSize(width: geo.size.width - inset * 2, height: geo.size.height - inset * 2)
            ZStack {
                let behind = min(2, max(0, center.pending.count - 1))
                ForEach(0..<behind, id: \.self) { i in
                    let depth = CGFloat(behind - i)
                    RoundedRectangle(cornerRadius: Theme.radiusNotice, style: .continuous)
                        .fill(.regularMaterial)
                        .overlay(RoundedRectangle(cornerRadius: Theme.radiusNotice, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
                        .frame(width: size.width, height: size.height)
                        .scaleEffect(1 - depth * 0.04)
                        .offset(y: depth * 12)
                        .opacity(0.9 - Double(depth) * 0.25)
                }
                if let front = center.pending.first {
                    ApprovalCard(pending: front, more: center.pending.count - 1, center: center)
                        .frame(width: size.width, height: size.height)
                        .id(front.id)
                        .transition(.asymmetric(insertion: .scale(scale: 0.92).combined(with: .opacity),
                                                removal: .scale(scale: 1.04).combined(with: .opacity)))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(.spring(response: 0.4, dampingFraction: 0.82), value: center.pending.map(\.id))
        }
    }
}

/// One request: who's asking, what would run, and the two answers.
struct ApprovalCard: View {
    let pending: ApprovalCenter.Pending
    let more: Int
    @ObservedObject var center: ApprovalCenter
    @State private var appeared = false

    private var r: RunRequest { pending.request }
    private var risky: Bool { !r.dangers.isEmpty }
    private var color: Color { risky ? .red : .orange }

    private var what: String {
        if let a = r.automation {
            return a.isEmpty ? "wants to stop this running by itself" : "wants this to run by itself, \(a.summary)"
        }
        return switch r.what {
        case .script: "wants to run a script"
        case .flow: "wants to run a flow"
        case .source: "wants to run Flow code it sent"
        case .stop: "wants to stop a run you started"
        }
    }

    /// Why the asker wants it, in its words, or that it didn't say (so the person knows that too).
    private var why: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: r.why == nil ? "questionmark.bubble" : "text.quote")
                .foregroundStyle(r.why == nil ? Color.orange : .secondary)
            Text(r.why.map { "Why, in \(r.client)'s words: \($0)" } ?? "\(r.client) gave no reason for this. \(r.isStop ? "Stop it" : "Run it") only if you expected it.")
                .font(.system(size: 13.5, weight: r.why == nil ? .semibold : .regular))
                .foregroundStyle(r.why == nil ? Color.orange : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    /// What allowing an automation does, exactly.
    private var automationLine: String? {
        guard let a = r.automation else { return nil }
        if a.isEmpty { return "Allow takes its automation tags off: it stops running by itself. Nothing runs now." }
        var s = "Allow tags \(r.name) to run by itself: " + a.tags.map { $0.title.lowercased() + " (" + $0.about + ")" }.joined(separator: "; ")
        if !a.after.isEmpty { s += " After: " + a.after.joined(separator: ", ") + "." }
        if a.once { s += " One time only." }
        return s + " Nothing runs now; the Automation board shows it, and right-click → Automation changes it."
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.radiusNotice, style: .continuous)
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "terminal.fill")
                Text("Tool Mac Tool Run · HTTP API")
                Spacer()
                if more > 0 {
                    Pill(text: "\(more) more waiting", symbol: "square.stack.fill", color: .secondary)
                }
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            HStack(alignment: .center, spacing: 18) {
                badge
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(r.client) \(what)".uppercased())
                        .font(.system(size: 12, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(color)
                        .lineLimit(2)
                    Text(r.name)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text("Asked by “\(r.client)”, from \(r.from) · \(ago(pending.asked))")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            details
            Group {
                why
                if let automationLine {
                    Label(automationLine, systemImage: "clock.badge.checkmark")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if risky {
                Label("It looks like it \(GridActions.list(r.dangers)).", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            Text(r.isStop
                 ? "It's still running. Stop It stops it, as ⌘. would; Keep Running tells \(r.client) no and leaves it be."
                 : r.automation == nil
                 ? "Nothing has run yet. Run lets it run this once, as if you'd clicked its cell; Don't Run tells \(r.client) no."
                 : "Nothing runs now. Allow tags it as asked; Don't Allow tells \(r.client) no and changes nothing.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button(noWord) { center.answer(pending.id, .denied) }
                    .buttonStyle(SoftButtonStyle(large: true))
                    .help(r.isStop ? "It keeps running; \(r.client) hears that you said no" : "Nothing runs; \(r.client) hears that you said no")
                Button { center.answer(pending.id, .allowed) } label: {
                    Label(r.isStop ? "Stop It" : r.automation == nil ? "Run" : "Allow",
                          systemImage: r.isStop ? "stop.fill" : r.automation == nil ? "play.fill" : "clock.badge.checkmark")
                }
                    .buttonStyle(ProminentButtonStyle(color: risky ? .red : .accentColor, large: true))
                    .help(r.isStop
                          ? "Stop the run now (Runs keeps what it printed)"
                          : r.automation == nil
                          ? "Run it now, this once (it shows on its cell and in Runs, and \(r.client) gets what it prints)"
                          : "Tag it as asked (the Automation board shows it; nothing runs now)")
            }
            countdown
        }
        .padding(.horizontal, 28)
        .padding(.top, 20)
        .padding(.bottom, 18)
        .background {
            ZStack {
                shape.fill(.ultraThickMaterial)
                RadialGradient(colors: [color.opacity(0.2), color.opacity(0)], center: UnitPoint(x: 0.12, y: 0.2),
                               startRadius: 0, endRadius: 520)
                    .clipShape(shape)
            }
        }
        .overlay(shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.35), color.opacity(0.3)],
                                                   startPoint: .top, endPoint: .bottom), lineWidth: 1.2))
        .shadow(color: .black.opacity(0.28), radius: 26, y: 12)
        .scaleEffect(appeared ? 1 : 0.94)
        .onAppear { withAnimation(.spring(response: 0.45, dampingFraction: 0.72)) { appeared = true } }
    }

    /// The answer that says no, in the words of what was asked.
    private var noWord: String { r.isStop ? "Keep Running" : r.automation == nil ? "Don't Run" : "Don't Allow" }

    /// What would run: the command, or the Flow code itself (all of it: it's what you're allowing).
    @ViewBuilder
    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let code = r.source {
                ScrollView {
                    Text(code)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(Theme.terminalText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 190)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.terminal))
                .environment(\.colorScheme, .dark)
                if !r.arguments.isEmpty { argumentsLine }
            } else {
                // All of it, scrolling when it's long: a cut-off command could hide what it does.
                ViewThatFits(in: .vertical) {
                    commandText
                    ScrollView { commandText }
                }
                .frame(maxHeight: 150)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.terminal))
                .environment(\.colorScheme, .dark)
                if let stdin = r.stdin {
                    Text("With \(stdin.utf8.count) bytes of input: \(stdin.prefix(80).replacingOccurrences(of: "\n", with: "⏎"))\(stdin.count > 80 ? "…" : "")")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var commandText: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("$").foregroundStyle(Theme.terminalText.opacity(0.5))
            Text(r.command)
                .foregroundStyle(Theme.terminalText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 13, design: .monospaced))
        .padding(12)
    }

    private var argumentsLine: some View {
        Text("With: " + r.arguments.map(ShellEnvironment.quote).joined(separator: " "))
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }

    private var badge: some View {
        let d: CGFloat = 76
        return ZStack {
            Circle().fill(color.opacity(0.14)).frame(width: d * 1.3, height: d * 1.3)
            TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                Circle().strokeBorder(color.opacity(0.5 * (1 - t)), lineWidth: 3)
                    .frame(width: d * (1 + 0.5 * t), height: d * (1 + 0.5 * t))
            }
            Circle()
                .fill(LinearGradient(colors: [color.opacity(0.8), color], startPoint: .top, endPoint: .bottom))
                .frame(width: d, height: d)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.3), lineWidth: 1.5))
                .shadow(color: color.opacity(0.45), radius: 14, y: 5)
            Image(systemName: risky ? "exclamationmark.triangle.fill" : "hand.raised.fill")
                .font(.system(size: d * 0.42, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: d * 1.3, height: d * 1.3)
    }

    /// How long until it answers Don't Run by itself.
    private var countdown: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let left = max(0, ApprovalCenter.wait - ctx.date.timeIntervalSince(pending.asked))
            VStack(spacing: 6) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(color.opacity(0.8)).frame(width: g.size.width * left / ApprovalCenter.wait)
                    }
                }
                .frame(height: 5)
                Text("Answers \(noWord) by itself in \(RunRecord.duration(left))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 60)
        }
    }
}
