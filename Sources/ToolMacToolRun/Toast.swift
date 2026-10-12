import AppKit
import SwiftUI

/// A banner of the app's own, top right of the screen, for when macOS won't show a notification
/// (they're off for the app). It doesn't take the keyboard from what you're doing, goes by itself
/// after a few seconds (not while the pointer is on it), and a click does what a click on the
/// notification would: shows the run, or installs the update.
@MainActor
enum Toast {
    private static var panels: [NSPanel] = []

    static func show(title: String, body: String, run: UUID?, update: Bool) {
        let width: CGFloat = 360
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 90),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let turnOn: (() -> Void)? = Notifier.Permission.shared.allowed == false ? { Notifier.openSettings() } : nil
        let view = ToastView(title: title, message: body, actionTitle: update ? "Install" : run != nil ? "Show" : nil,
                             action: {
                                 dismiss(panel)
                                 if update { AppModel.shared.installUpdate() } else if let run { Windows.showRuns(run) }
                             },
                             close: { dismiss(panel) },
                             settings: turnOn)
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        panel.contentView = host
        panel.setContentSize(NSSize(width: width, height: size.height))
        panels.append(panel)
        restack()
        panel.orderFrontRegardless()
        NSSound(named: "Glass")?.play()
        scheduleDismiss(panel, after: update ? 20 : 7)
    }

    /// The newest on top; the others below it.
    private static func restack() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        var top = screen.visibleFrame.maxY - 10
        for p in panels.reversed() {
            p.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.maxX - p.frame.width - 14, y: top))
            top -= p.frame.height + 8
        }
    }

    private static func scheduleDismiss(_ panel: NSPanel, after seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated {
                guard panels.contains(panel) else { return }
                // Not while it's being read.
                if panel.frame.contains(NSEvent.mouseLocation) {
                    scheduleDismiss(panel, after: 2)
                } else {
                    dismiss(panel)
                }
            }
        }
    }

    private static func dismiss(_ panel: NSPanel) {
        panel.orderOut(nil)
        panels.removeAll { $0 === panel }
        restack()
    }
}

struct ToastView: View {
    let title: String
    let message: String
    let actionTitle: String?
    let action: () -> Void
    let close: () -> Void
    /// Notifications are off: a way to turn them on.
    let settings: (() -> Void)?
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).lineLimit(2)
                Text(message).font(.callout).foregroundStyle(.secondary).lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    if let actionTitle {
                        Button(actionTitle, action: action).buttonStyle(.borderedProminent).controlSize(.small)
                    }
                    if let settings {
                        Button("Turn On Notifications…", action: settings).buttonStyle(.link).font(.caption)
                            .help("macOS isn't showing this app's notifications, so this banner stands in for them")
                    }
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
            Button(action: close) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain)
                .opacity(hover ? 1 : 0.4)
                .help("Close")
        }
        .padding(12)
        .frame(width: 360, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .contentShape(Rectangle())
        .onTapGesture { if actionTitle != nil { action() } }
        .onHover { hover = $0 }
    }
}
