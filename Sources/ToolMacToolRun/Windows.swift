import AppKit
import RunCore
import SwiftUI

/// The app's windows, each made once and brought back when asked for again.
@MainActor
enum Windows {
    private static var windows: [String: NSWindow] = [:]
    /// The run the Runs window shows.
    static let runsSelection = RunsSelection()

    /// A window holding a SwiftUI view: made the first time, brought forward after.
    static func show<Content: View>(_ id: String, title: String, size: NSSize, minSize: NSSize = NSSize(width: 520, height: 360),
                                    autosave: Bool = true, content: () -> Content) {
        if let w = windows[id] {
            bringForward(w)
            return
        }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = title
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.minSize = minSize
        w.contentViewController = NSHostingController(rootView: content())
        w.setContentSize(size)
        w.center()
        if autosave { w.setFrameAutosaveName("ToolMacToolRun.\(id)") }
        windows[id] = w
        bringForward(w)
    }

    static func bringForward(_ w: NSWindow) {
        // A menu bar app isn't frontmost by itself: come forward, or the window opens behind others.
        NSApp.activate(ignoringOtherApps: true)
        if w.isMiniaturized { w.deminiaturize(nil) }
        w.makeKeyAndOrderFront(nil)
    }

    static func close(_ id: String) {
        windows[id]?.close()
    }

    static func forget(_ id: String) {
        windows[id]?.close()
        windows[id] = nil
    }

    static func isVisible(_ id: String) -> Bool { windows[id]?.isVisible == true }

    /// 90% of the screen the pointer is on, centred on it.
    static var ninetyPercent: NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let v = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: (v.width * 0.9).rounded(), height: (v.height * 0.9).rounded())
        return NSRect(x: v.midX - size.width / 2, y: v.midY - size.height / 2, width: size.width, height: size.height)
    }

    // MARK: the windows

    /// A grid fills 90% of the screen, every time it's opened.
    static func showGrid(_ kind: GridKind) {
        let id = "grid-\(kind.rawValue)"
        let frame = ninetyPercent
        show(id, title: kind == .scripts ? "Scripts" : "Composer", size: frame.size, minSize: NSSize(width: 640, height: 440), autosave: false) {
            GridView(kind: kind, app: AppModel.shared, runs: AppModel.shared.runs)
        }
        windows[id]?.setFrame(frame, display: true, animate: false)
    }

    static func showEditor(_ item: ScriptItem, kind: GridKind) {
        let id = "edit-\(item.url.path)"
        show(id, title: item.id, size: NSSize(width: 1000, height: 680), minSize: NSSize(width: 640, height: 400)) {
            EditorView(model: EditorModel(item: item, kind: kind, app: AppModel.shared), windowID: id)
        }
    }

    static func showRuns(_ select: UUID?) {
        if let select { runsSelection.selected = select }
        show("runs", title: "Runs", size: NSSize(width: 1000, height: 640), minSize: NSSize(width: 640, height: 360)) {
            RunsView(runs: AppModel.shared.runs, selection: runsSelection)
        }
    }

    static func showDoctor() {
        show("doctor", title: "Check Setup", size: NSSize(width: 640, height: 520)) {
            DoctorView(app: AppModel.shared)
        }
    }

    static func showGuide() {
        show("guide", title: "Flow Guide", size: NSSize(width: 880, height: 760)) {
            GuideView()
        }
    }
}

/// Which run the Runs window shows.
@MainActor
final class RunsSelection: ObservableObject {
    @Published var selected: UUID?
}
