import AppKit
import SwiftUI

/// What the app tells you (a run ended, one is taking long, a flow is waiting, an update is
/// ready): a large card in the middle of the screen, half its width and height, that can't be
/// missed. It doesn't take the keyboard from what you're typing, goes by itself after a while (a
/// bar shows how long is left; not while the pointer is on it), and a click does the obvious
/// thing: shows the run's result, answers the question, installs the update. More arriving at once wait
/// behind it, and say how many.
struct Notice: Identifiable, Equatable {
    enum Tone: Equatable {
        case success, failure, stopped, warning, info, running, waiting, update

        var color: Color {
            switch self {
            case .success: .green
            case .failure: .red
            case .stopped: .gray
            case .warning: .orange
            case .info: .accentColor
            case .running: .blue
            case .waiting: .orange
            case .update: .purple
            }
        }

        var symbol: String {
            switch self {
            case .success: "checkmark"
            case .failure: "xmark"
            case .stopped: "stop.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .info: "bell.fill"
            case .running: "hourglass"
            case .waiting: "hand.raised.fill"
            case .update: "arrow.down"
            }
        }

        /// What it says above the title.
        var eyebrow: String {
            switch self {
            case .success: "Done"
            case .failure: "Failed"
            case .stopped: "Stopped"
            case .warning: "Heads up"
            case .info: "Message"
            case .running: "Still running"
            case .waiting: "Waiting for you"
            case .update: "Update"
            }
        }

        /// How long it stays (seconds): longer for what needs you.
        var seconds: Double {
            switch self {
            case .success, .stopped: 8
            case .info, .running: 10
            case .warning: 12
            case .failure: 15
            case .waiting: 20
            case .update: 25
            }
        }

        var sound: String {
            switch self {
            case .failure, .warning: "Basso"
            case .waiting, .update: "Submarine"
            default: "Glass"
            }
        }
    }

    let id = UUID()
    let tone: Tone
    let title: String
    let body: String
    let run: UUID?
    let update: Bool
    let posted = Date()

    /// What a click does, in words (nil: nothing more than closing it).
    @MainActor var actionTitle: String? {
        if update { return "Install Update" }
        guard let run else { return nil }
        return PromptCenter.shared.pending(for: run) != nil ? "Answer" : "Show Result"
    }
}

/// The notices: the one showing, the ones waiting behind it, and how long the front one has left.
@MainActor
final class NoticeCenter: ObservableObject {
    static let shared = NoticeCenter()

    @Published private(set) var queue: [Notice] = []
    /// The pointer is on it: its time stands still.
    @Published var hovering = false {
        didSet {
            guard hovering != oldValue else { return }
            if hovering { pause() } else { resume() }
        }
    }

    /// At most this many wait behind the one showing (the oldest go first).
    private static let maxWaiting = 6
    private var panel: NoticePanel?
    private var timer: Timer?
    /// The front notice's time used before the latest resume, and when it resumed.
    private var used: TimeInterval = 0
    private var since: Date?

    var front: Notice? { queue.first }

    func post(_ notice: Notice) {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
            queue.append(notice)
            while queue.count > Self.maxWaiting + 1 { queue.remove(at: 1) }
        }
        NSSound(named: notice.tone.sound)?.play()
        if queue.count == 1 { startClock() }
        present()
    }

    /// How much of the front notice's time has gone, 0–1.
    func progress(at now: Date) -> Double {
        guard let front else { return 0 }
        let t = used + (since.map { now.timeIntervalSince($0) } ?? 0)
        return min(1, max(0, t / front.tone.seconds))
    }

    /// Closes the front one; the next comes forward.
    func dismissFront() {
        guard !queue.isEmpty else { return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { _ = queue.removeFirst() }
        if queue.isEmpty {
            stopClock()
            hide()
        } else {
            startClock()
        }
    }

    func dismissAll() {
        withAnimation(.easeOut(duration: 0.2)) { queue.removeAll() }
        stopClock()
        hide()
    }

    /// A click on it: what it's about, then it goes.
    func act() {
        guard let n = front else { return }
        dismissFront()
        if n.update {
            AppModel.shared.installUpdate()
        } else if let run = n.run {
            if PromptCenter.shared.pending(for: run) != nil { Windows.showPrompt() } else { Windows.showResult(run) }
        }
    }

    // MARK: the clock

    private func startClock() {
        used = 0
        since = hovering ? nil : Date()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated { NoticeCenter.shared.tick() }
        }
    }

    /// The last one went (the panel hides): the pointer isn't on a notice any more, though no
    /// card said so (a card that's taken away never hears the pointer leave).
    private func stopClock() {
        timer?.invalidate()
        timer = nil
        since = nil
        used = 0
        hovering = false
    }

    private func pause() {
        if let since { used += Date().timeIntervalSince(since) }
        since = nil
    }

    private func resume() {
        guard !queue.isEmpty, since == nil else { return }
        since = Date()
    }

    private func tick() {
        if progress(at: Date()) >= 1 { dismissFront() }
    }

    // MARK: the panel

    /// Half the screen the pointer is on, in its middle.
    private static func frame() -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let v = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: max(560, (v.width * 0.5).rounded()), height: max(380, (v.height * 0.5).rounded()))
        return NSRect(x: v.midX - size.width / 2, y: v.midY - size.height / 2, width: size.width, height: size.height)
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
                // Something new came in while it faded: it stays.
                if NoticeCenter.shared.queue.isEmpty { panel.orderOut(nil) } else { panel.alphaValue = 1 }
            }
        })
    }

    private func makePanel() -> NoticePanel {
        let panel = NoticePanel(contentRect: Self.frame(), styleMask: [.nonactivatingPanel, .borderless],
                                backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // The card draws its own shadow.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: NoticeStackView(center: self))
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }
}

/// The notice window: never the key window, so what you're typing elsewhere keeps going there.
final class NoticePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The front notice, and the ones waiting showing as cards behind it.
struct NoticeStackView: View {
    @ObservedObject var center: NoticeCenter

    var body: some View {
        GeometryReader { geo in
            // Room round the card for its shadow and the cards behind it.
            let inset: CGFloat = 28
            let size = CGSize(width: geo.size.width - inset * 2, height: geo.size.height - inset * 2)
            ZStack {
                let behind = min(2, max(0, center.queue.count - 1))
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
                if let front = center.queue.first {
                    NoticeCard(notice: front, center: center, size: size)
                        .frame(width: size.width, height: size.height)
                        .id(front.id)
                        .transition(.asymmetric(insertion: .scale(scale: 0.9).combined(with: .opacity),
                                                removal: .scale(scale: 1.04).combined(with: .opacity)))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

/// One notice: a big mark in its color, what it's about, the actions, and the time left.
struct NoticeCard: View {
    let notice: Notice
    @ObservedObject var center: NoticeCenter
    let size: CGSize
    @State private var appeared = false

    /// Everything scales with the card (a big screen, a big notice).
    private var unit: CGFloat { min(1.7, max(0.75, min(size.width / 700, size.height / 420))) }
    private var tone: Notice.Tone { notice.tone }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.radiusNotice, style: .continuous)
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                HStack(spacing: 8) {
                    Image(systemName: "terminal.fill")
                    Text("Tool Mac Tool Run")
                    Text("·")
                    Text(ago(notice.posted))
                }
                .font(.system(size: 13 * unit, weight: .medium))
                .foregroundStyle(.secondary)
                Spacer()
                if center.queue.count > 1 {
                    Pill(text: "\(center.queue.count - 1) more", symbol: "square.stack.fill", color: .secondary)
                        .padding(.trailing, 8 * unit)
                }
                Button { center.dismissFront() } label: { Image(systemName: "xmark") }
                    .buttonStyle(CircleIconButtonStyle(size: 30 * unit))
                    .help("Close")
            }
            Spacer(minLength: 8)
            badge
            Spacer(minLength: 10)
            VStack(spacing: 10 * unit) {
                Text(tone.eyebrow.uppercased())
                    .font(.system(size: 13 * unit, weight: .bold))
                    .tracking(1.6)
                    .foregroundStyle(tone.color)
                Text(notice.title)
                    .font(.system(size: 34 * unit, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                if !notice.body.isEmpty {
                    Text(notice.body)
                        .font(.system(size: 18 * unit))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(5)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: size.width * 0.8)
                }
            }
            Spacer(minLength: 14)
            HStack(spacing: 12 * unit) {
                if center.queue.count > 1 {
                    Button("Close All") { center.dismissAll() }
                        .buttonStyle(SoftButtonStyle(large: true))
                }
                Button(notice.actionTitle == nil ? "Close" : "Dismiss") { center.dismissFront() }
                    .buttonStyle(SoftButtonStyle(large: true))
                if let action = notice.actionTitle {
                    Button { center.act() } label: {
                        Label(action, systemImage: notice.update ? "arrow.down.circle.fill" : action == "Answer" ? "hand.raised.fill" : "arrow.up.forward.app.fill")
                    }
                    .buttonStyle(ProminentButtonStyle(color: tone == .stopped ? .accentColor : tone.color, large: true))
                }
            }
            Spacer(minLength: 12)
            countdown
        }
        .padding(.horizontal, 28 * unit)
        .padding(.top, 22 * unit)
        .padding(.bottom, 20 * unit)
        .background {
            ZStack {
                shape.fill(.ultraThickMaterial)
                // A glow of its color from behind the mark.
                RadialGradient(colors: [tone.color.opacity(0.22), tone.color.opacity(0)], center: UnitPoint(x: 0.5, y: 0.28),
                               startRadius: 0, endRadius: max(size.width, size.height) * 0.6)
                    .clipShape(shape)
            }
        }
        .overlay(shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.35), tone.color.opacity(0.25)],
                                                   startPoint: .top, endPoint: .bottom), lineWidth: 1.2))
        .shadow(color: .black.opacity(0.28), radius: 26, y: 12)
        .contentShape(shape)
        .onTapGesture { if notice.actionTitle != nil { center.act() } }
        .onHover { center.hovering = $0 }
        .help(notice.actionTitle.map { "Click: \($0)" } ?? "")
        .scaleEffect(appeared ? 1 : 0.94)
        .onAppear { withAnimation(.spring(response: 0.45, dampingFraction: 0.72)) { appeared = true } }
    }

    /// The big round mark, ringed; a pulse while it's waiting on you.
    private var badge: some View {
        let d = 96 * unit
        return ZStack {
            Circle().fill(tone.color.opacity(0.14)).frame(width: d * 1.45, height: d * 1.45)
            if tone == .waiting || tone == .running {
                TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                    Circle().strokeBorder(tone.color.opacity(0.5 * (1 - t)), lineWidth: 3)
                        .frame(width: d * (1 + 0.6 * t), height: d * (1 + 0.6 * t))
                }
            }
            Circle()
                .fill(LinearGradient(colors: [tone.color.opacity(0.8), tone.color], startPoint: .top, endPoint: .bottom))
                .frame(width: d, height: d)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.3), lineWidth: 1.5))
                .shadow(color: tone.color.opacity(0.45), radius: 16 * unit, y: 6 * unit)
            Image(systemName: tone.symbol)
                .font(.system(size: d * 0.44, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(height: d * 1.45)
    }

    /// How long it has left, as a draining bar (still while the pointer is on it).
    private var countdown: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let left = 1 - center.progress(at: ctx.date)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(tone.color.opacity(center.hovering ? 0.45 : 0.85))
                        .frame(width: g.size.width * left)
                }
            }
            .frame(height: 5)
        }
        .padding(.horizontal, size.width * 0.18)
        .help(center.hovering ? "Stays while the pointer is on it" : "Goes by itself; the pointer on it keeps it")
    }
}
