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
    /// The run the Result window shows.
    static let resultSelection = RunsSelection()

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
        show(id, title: kind.title, size: frame.size, minSize: NSSize(width: 640, height: 440), autosave: false) {
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

    /// The API board: everything the HTTP API can run, a tile each. It fills 90% of the screen,
    /// as a grid does, and the folder is read again each time it comes forward.
    static func showAPIBoard() {
        let id = "api-board"
        let frame = ninetyPercent
        let isNew = windows[id] == nil
        AppModel.shared.reload()
        show(id, title: "API", size: frame.size, minSize: NSSize(width: 640, height: 440), autosave: false) {
            APIBoardView(app: AppModel.shared, runs: AppModel.shared.runs)
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

    /// The Library board: the notes in LIBRARY, a tile each, one open to edit. It fills 90% of
    /// the screen, as the other boards do.
    static func showLibraryBoard() { showShelfBoard(.library) }

    /// A shelf's board (Library, Memory, System Docs): its files, a tile each, one open.
    static func showShelfBoard(_ shelf: Shelf) {
        let id = "\(shelf.rawValue)-board"
        let frame = ninetyPercent
        show(id, title: shelf.title, size: frame.size, minSize: NSSize(width: 720, height: 460), autosave: false) {
            LibraryBoardView(app: AppModel.shared, shelf: shelf)
        }
        windows[id]?.setFrame(frame, display: true, animate: false)
    }

    /// The Mind board: the mind as a picture (or as text), a node picked to see all about it.
    static func showMindBoard(select name: String? = nil) {
        let id = "mind-board"
        let frame = ninetyPercent
        let isNew = windows[id] == nil
        show(id, title: "Mind", size: frame.size, minSize: NSSize(width: 760, height: 480), autosave: false) {
            MindBoardView(app: AppModel.shared, model: MindBoardModel.shared)
        }
        if isNew { windows[id]?.setFrame(frame, display: true, animate: false) }
        if let name { MindBoardModel.shared.select(named: name) }
    }

    /// What another app (or you) asked to show: a window in front of everything, near the pointer.
    static func showPresent() {
        if let w = windows["present"] {
            w.orderFrontRegardless()
            bringForward(w)
            return
        }
        let size = NSSize(width: 760, height: 640)
        let w = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Shown to You"
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        // In front of everything, on whichever Space the person is on, until they close it.
        w.level = .floating
        w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        w.hidesOnDeactivate = false
        w.becomesKeyOnlyIfNeeded = false
        w.minSize = NSSize(width: 480, height: 320)
        w.contentViewController = NSHostingController(rootView: PresentView(center: PresentCenter.shared))
        w.setContentSize(size)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let v = screen?.visibleFrame {
            w.setFrameOrigin(NSPoint(x: v.midX - size.width / 2, y: v.midY - size.height / 2))
        } else {
            w.center()
        }
        w.setFrameAutosaveName("ToolMacToolRun.present")
        windows["present"] = w
        w.orderFrontRegardless()
        bringForward(w)
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
        // A flow's block editor has its library beside it: a little more room.
        let size = kind.isFlow ? NSSize(width: 1120, height: 760) : NSSize(width: 1000, height: 680)
        let w = makeWindow(title: item.id, size: size, minSize: NSSize(width: 720, height: 440))
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

    /// One run's result in a window of its own: from a notice, the panel, a question's window,
    /// or a recipe run from the panel (the result is where you're looking, not behind a list).
    static func showResult(_ id: UUID) {
        resultSelection.selected = id
        show("result", title: "Result", size: NSSize(width: 860, height: 620), minSize: NSSize(width: 560, height: 380)) {
            ResultWindowView(runs: AppModel.shared.runs, selection: resultSelection)
        }
    }

    static func showDoctor() {
        show("doctor", title: "Check Setup", size: NSSize(width: 640, height: 520)) {
            DoctorView(app: AppModel.shared)
        }
    }

    /// The question a flow is waiting on: a small window that floats over the others, near the pointer.
    static func showPrompt() {
        if let w = windows["prompt"] {
            bringForward(w)
            return
        }
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 240),
                        styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "A Flow Is Asking"
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.hidesOnDeactivate = false
        w.becomesKeyOnlyIfNeeded = false
        let host = NSHostingController(rootView: PromptWindowView(center: PromptCenter.shared))
        host.sizingOptions = [.preferredContentSize]
        w.contentViewController = host
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let v = screen?.visibleFrame {
            w.setFrameTopLeftPoint(NSPoint(x: v.midX - 260, y: v.maxY - v.height * 0.22))
        } else {
            w.center()
        }
        windows["prompt"] = w
        bringForward(w)
    }

    static func showGuide() {
        show("guide", title: "Guides", size: NSSize(width: 880, height: 760)) {
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
