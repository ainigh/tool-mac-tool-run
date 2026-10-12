import AppKit
import RunCore
import SwiftUI

/// The app's windows. The grids, Runs, Check Setup and the guide are made once and brought back
/// when asked for again; an editor is made for each opening of a file (it reads the file afresh)
/// and let go when it's closed.
@MainActor
enum Windows {
    private static var windows: [String: NSWindow] = [:]
    /// The open editors: one per file, found by the file it edits now (it follows a rename).
    private static var editors: [EditorEntry] = []
    private static var observers: [NSObjectProtocol] = []
    /// The run the Runs window shows.
    static let runsSelection = RunsSelection()

    private static func makeWindow(title: String, size: NSSize, minSize: NSSize) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = title
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.minSize = minSize
        return w
    }

    /// A window holding a SwiftUI view: made the first time, brought forward after.
    static func show<Content: View>(_ id: String, title: String, size: NSSize, minSize: NSSize = NSSize(width: 520, height: 360),
                                    autosave: Bool = true, content: () -> Content) {
        if let w = windows[id] {
            bringForward(w)
            return
        }
        let w = makeWindow(title: title, size: size, minSize: minSize)
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

    /// A grid fills 90% of the screen, every time it's opened. The folder is read again each time
    /// it comes forward (a script edited elsewhere shows its new description).
    static func showGrid(_ kind: GridKind) {
        let id = "grid-\(kind.rawValue)"
        let frame = ninetyPercent
        let isNew = windows[id] == nil
        show(id, title: kind == .scripts ? "Scripts" : "Composer", size: frame.size, minSize: NSSize(width: 640, height: 440), autosave: false) {
            GridView(kind: kind, app: AppModel.shared, runs: AppModel.shared.runs)
        }
        guard let w = windows[id] else { return }
        w.setFrame(frame, display: true, animate: false)
        if isNew {
            let token = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: w, queue: .main) { _ in
                MainActor.assumeIsolated { AppModel.shared.reload() }
            }
            observers.append(token)
        }
    }

    // MARK: editors

    private static func standardPath(_ url: URL) -> String { url.standardizedFileURL.path }

    private static func entry(for url: URL) -> EditorEntry? {
        let path = standardPath(url)
        return editors.first { !$0.closed && standardPath($0.model.item.url) == path }
    }

    /// The open editor of a file, if there's one.
    static func editor(for url: URL) -> EditorModel? { entry(for: url)?.model }

    /// Edits a file: its open editor if it has one (even one renamed since), else a new editor
    /// that reads it afresh.
    static func showEditor(_ item: ScriptItem, kind: GridKind) {
        if let e = entry(for: item.url) {
            bringForward(e.window)
            return
        }
        let model = EditorModel(item: item, kind: kind, app: AppModel.shared)
        let size = NSSize(width: 1000, height: 680)
        let w = makeWindow(title: item.id, size: size, minSize: NSSize(width: 640, height: 400))
        w.contentViewController = NSHostingController(rootView: EditorView(model: model))
        w.setContentSize(size)
        w.center()
        w.setFrameAutosaveName("ToolMacToolRun.edit-\(item.url.path)")
        let opened = EditorEntry(window: w, model: model)
        let id = ObjectIdentifier(w)
        // Closed: it saves (when there's something to save) and is let go.
        opened.observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated { Windows.editorClosing(id) }
        }
        editors.append(opened)
        bringForward(w)
    }

    private static func editorClosing(_ id: ObjectIdentifier) {
        guard let i = editors.firstIndex(where: { !$0.closed && ObjectIdentifier($0.window) == id }) else { return }
        let e = editors[i]
        e.closed = true
        e.model.windowWillClose()
        if let o = e.observer { NotificationCenter.default.removeObserver(o) }
        e.observer = nil
        // Let go of it once it has finished closing.
        DispatchQueue.main.async {
            MainActor.assumeIsolated { Windows.editors.removeAll { $0 === e } }
        }
    }

    /// An editor's file was renamed: its window's title follows.
    static func editorRenamed(_ model: EditorModel) {
        if let e = editors.first(where: { $0.model === model }) { e.window.title = model.item.id }
    }

    /// Closes the editor of a file that was moved to the Trash: it doesn't save again.
    static func closeEditor(for url: URL, deleted: Bool) {
        guard let e = entry(for: url) else { return }
        if deleted { e.model.markDeleted() }
        e.window.close()
    }

    /// Closes an editor (its own Move to Trash).
    static func closeEditor(_ model: EditorModel) {
        if let e = editors.first(where: { !$0.closed && $0.model === model }) { e.window.close() }
    }

    /// Saves every open editor (before quitting).
    static func saveEditors() {
        for e in editors where !e.closed { e.model.save() }
    }

    // MARK: the rest

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

/// An open editor: its window and what it edits.
@MainActor
private final class EditorEntry {
    let window: NSWindow
    let model: EditorModel
    var observer: NSObjectProtocol?
    /// Closing: it's let go in a moment, and a new opening of the file makes a new editor.
    var closed = false

    init(window: NSWindow, model: EditorModel) {
        self.window = window
        self.model = model
    }
}

/// Which run the Runs window shows.
@MainActor
final class RunsSelection: ObservableObject {
    @Published var selected: UUID?
}
