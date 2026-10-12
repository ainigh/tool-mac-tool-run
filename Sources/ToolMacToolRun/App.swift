import AppKit
import RunCore
import ServiceManagement
import SwiftUI

/// A terminal icon in the menu bar. Its menu opens the two grids (every script; the flows that
/// compose them), the runs, and the folder they all live in.
@main
struct ToolMacToolRunApp: App {
    @StateObject private var app = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(app: app, runs: app.runs)
        } label: {
            MenuBarLabel(runs: app.runs)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// The icon, and beside it how many runs are going (when any are).
struct MenuBarLabel: View {
    @ObservedObject var runs: RunStore

    var body: some View {
        let n = runs.runningCount
        if n > 0 {
            HStack(spacing: 2) {
                Image(systemName: "terminal.fill")
                Text("\(n)")
            }
        } else {
            Image(systemName: "terminal")
        }
    }
}

/// The menu. With no folder chosen yet, choosing one comes first (the grids need it).
struct MenuContent: View {
    @ObservedObject var app: AppModel
    @ObservedObject var runs: RunStore

    var body: some View {
        if app.library == nil {
            Button("Choose Your Scripts Folder…") { app.openGrid(.scripts) }
            Divider()
        }
        Button("Scripts Grid") { app.openGrid(.scripts) }
            .keyboardShortcut("1")
        Button("Composer Grid") { app.openGrid(.composer) }
            .keyboardShortcut("2")
        Divider()
        Button(runs.runningCount > 0 ? "Runs — \(runs.runningCount) running" : "Runs") { Windows.showRuns(nil) }
            .keyboardShortcut("r")
        let recent = runs.recent(5)
        if !recent.isEmpty {
            ForEach(recent) { run in
                Button(MenuContent.title(run)) { Windows.showRuns(run.id) }
            }
        }
        Divider()
        if let lib = app.library {
            Text("Folder: \((lib.root.path as NSString).abbreviatingWithTildeInPath)")
            Button("Open Folder in Finder") { NSWorkspace.shared.activateFileViewerSelecting([lib.root]) }
        }
        Button(app.library == nil ? "Choose Folder…" : "Change Folder…") { app.chooseFolder() }
        Button("Check Setup…") { Windows.showDoctor() }
        Button("Flow Guide") { Windows.showGuide() }
        Divider()
        Toggle("Open at Login", isOn: Binding(get: { app.openAtLogin }, set: { app.setOpenAtLogin($0) }))
        Text("Tool Mac Tool Run \(AppModel.version)")
        Button("Quit") { app.quit() }
            .keyboardShortcut("q")
    }

    static func title(_ run: RunRecord) -> String {
        var s = "\(run.state.mark) \(run.name)"
        if run.state == .running {
            s += " · running"
        } else if let secs = run.seconds {
            s += " · \(RunRecord.duration(secs))"
        }
        return s
    }
}

/// What the app holds: the folder, the scripts and flows in it, the grids' settings, the runs.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var library: Library?
    @Published private(set) var scripts: [ScriptItem] = []
    @Published private(set) var flows: [ScriptItem] = []
    @Published var grids: [GridKind: GridSettings] = [:]
    @Published var openAtLogin = SMAppService.mainApp.status == .enabled
    /// Something went wrong that the person should see (a save that failed), shown on the grid.
    @Published var problem: String?

    let runs = RunStore()
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var saveTasks: [GridKind: Task<Void, Never>] = [:]

    static let folderKey = "scriptsFolder"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private init() {
        for kind in GridKind.allCases { grids[kind] = GridSettings.load(kind) }
        if let path = UserDefaults.standard.string(forKey: Self.folderKey) {
            setFolder(URL(fileURLWithPath: path), remember: false)
        }
        // Read the login shell's PATH now, off the main thread, so the first run doesn't wait for it.
        DispatchQueue.global(qos: .utility).async { _ = ShellEnvironment.shared.environment }
        // Start at login from the first launch; the menu has the switch to turn it off.
        let key = "didSetUpOpenAtLogin"
        if !UserDefaults.standard.bool(forKey: key), Bundle.main.bundleURL.pathExtension == "app" {
            UserDefaults.standard.set(true, forKey: key)
            setOpenAtLogin(true)
        }
    }

    // MARK: the folder

    /// Uses this folder from now on (making it, and its composer folder, if they aren't there).
    func setFolder(_ url: URL, remember: Bool = true) {
        let lib = Library(root: url)
        do {
            try lib.ensure()
            problem = nil
        } catch {
            problem = "Couldn't use \(url.path): \(error.localizedDescription)"
        }
        library = lib
        if remember { UserDefaults.standard.set(url.path, forKey: Self.folderKey) }
        reload()
        watch()
    }

    /// The suggested folder: ~/Scripts.
    static var suggestedFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Scripts", isDirectory: true)
    }

    /// Asks for a folder (the Finder's chooser), and uses it.
    func chooseFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Choose your scripts folder"
        panel.message = "Your scripts go at the top of this folder; flows go in a \"composer\" folder inside it (made for you)."
        panel.prompt = "Use This Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = library?.root ?? FileManager.default.homeDirectoryForCurrentUser
        if panel.runModal() == .OK, let url = panel.url { setFolder(url) }
    }

    /// Reads the folder again.
    func reload() {
        guard let library else {
            scripts = []
            flows = []
            return
        }
        let lib = library
        Task.detached(priority: .userInitiated) {
            let s = lib.scripts(), f = lib.flows()
            await MainActor.run {
                guard self.library?.root == lib.root else { return }
                if self.scripts != s { self.scripts = s }
                if self.flows != f { self.flows = f }
            }
        }
    }

    /// Reloads whenever something in the folder (or its composer folder) changes.
    private func watch() {
        watchers.forEach { $0.cancel() }
        watchers = []
        guard let library else { return }
        for folder in [library.root, library.composerFolder] {
            let fd = open(folder.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            // The queue is the main one: the handler runs on the main actor.
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.reload() } }
            source.setCancelHandler { close(fd) }
            source.resume()
            watchers.append(source)
        }
    }

    func items(_ kind: GridKind) -> [ScriptItem] { kind == .scripts ? scripts : flows }

    // MARK: the grids' settings

    func settings(_ kind: GridKind) -> GridSettings { grids[kind] ?? GridSettings() }

    /// Changes a grid's settings and saves them a moment later.
    func update(_ kind: GridKind, _ change: (inout GridSettings) -> Void) {
        var s = settings(kind)
        change(&s)
        guard s != grids[kind] else { return }
        grids[kind] = s
        saveTasks[kind]?.cancel()
        saveTasks[kind] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            do { try self.settings(kind).save(kind) } catch { self.problem = "Couldn't save the grid's settings: \(error.localizedDescription)" }
        }
    }

    /// A script renamed: its place, color and arguments go with it.
    func renamed(_ kind: GridKind, from old: String, to new: String) {
        update(kind) { s in
            s.order = s.order.map { $0 == old ? new : $0 }
            if let t = s.tints.removeValue(forKey: old) { s.tints[new] = t }
            if let a = s.arguments.removeValue(forKey: old) { s.arguments[new] = a }
        }
    }

    // MARK: windows

    func openGrid(_ kind: GridKind) {
        reload()
        Windows.showGrid(kind)
    }

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("open at login: \(error)")
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Quits, saying first what's still running (it would be stopped).
    func quit() {
        let n = runs.runningCount
        if n > 0 {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Stop \(n) running \(n == 1 ? "script" : "scripts") and quit?"
            alert.informativeText = "Quitting stops what's running now. Its output so far is kept in Runs."
            alert.addButton(withTitle: "Keep Running")
            alert.addButton(withTitle: "Stop and Quit")
            if alert.runModal() == .alertFirstButtonReturn { return }
            runs.stopAll()
        }
        runs.saveNow()
        NSApp.terminate(nil)
    }
}
