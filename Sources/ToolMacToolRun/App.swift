import AppKit
import RunCore
import ServiceManagement
import SwiftUI

/// A terminal icon in the menu bar. Its menu opens the two grids (every script; the flows that
/// compose them), the runs, and the folder they all live in.
@main
struct ToolMacToolRunApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
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

    /// The runs (it reads the login shell's PATH as it's made, off the main thread, so the first
    /// run doesn't wait for it).
    let runs = RunStore()
    private var watchers: [DispatchSourceFileSystemObject] = []
    /// A watch on a folder that's gone (deleted, renamed) is made again shortly.
    private var rewatchScheduled = false
    /// Each read of the folder is numbered: only the latest one's result is used.
    private var scanGeneration = 0
    private var saveTasks: [GridKind: Task<Void, Never>] = [:]
    private var observers: [NSObjectProtocol] = []

    static let folderKey = "scriptsFolder"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private init() {
        for kind in GridKind.allCases { grids[kind] = GridSettings.load(kind) }
        if let path = UserDefaults.standard.string(forKey: Self.folderKey) {
            setFolder(URL(fileURLWithPath: path), remember: false)
        }
        // Start at login from the first launch; the menu has the switch to turn it off.
        let key = "didSetUpOpenAtLogin"
        if !UserDefaults.standard.bool(forKey: key), Bundle.main.bundleURL.pathExtension == "app" {
            UserDefaults.standard.set(true, forKey: key)
            setOpenAtLogin(true)
        }
        // "Open at Login" can be changed in System Settings: read it again when the menu opens
        // (or the app comes forward).
        for name in [NSMenu.didBeginTrackingNotification, NSApplication.didBecomeActiveNotification] {
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshOpenAtLogin() }
            }
            observers.append(token)
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
        scanGeneration += 1
        let generation = scanGeneration
        Task.detached(priority: .userInitiated) {
            let s = lib.scripts(), f = lib.flows()
            await MainActor.run {
                // A newer read was started meanwhile: its result is the one that counts.
                guard generation == self.scanGeneration, self.library?.root == lib.root else { return }
                if self.scripts != s { self.scripts = s }
                if self.flows != f { self.flows = f }
            }
        }
    }

    /// Reloads whenever something in the folder (or its composer folder) changes. A folder that's
    /// deleted, renamed or not there is watched again once it's back.
    private func watch() {
        watchers.forEach { $0.cancel() }
        watchers = []
        guard let library else { return }
        var missing = false
        for folder in [library.root, library.composerFolder] {
            let fd = open(folder.path, O_EVTONLY)
            guard fd >= 0 else {
                missing = true
                continue
            }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .attrib, .link, .rename, .delete], queue: .main)
            // The queue is the main one: the handler runs on the main actor.
            source.setEventHandler { [weak self] in
                let gone = !source.data.intersection([.delete, .rename]).isEmpty
                MainActor.assumeIsolated {
                    self?.reload()
                    if gone { self?.scheduleRewatch() }
                }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            watchers.append(source)
        }
        if missing { scheduleRewatch(after: 2) }
    }

    /// Watches the folders again in a moment (and reads them again).
    private func scheduleRewatch(after seconds: Double = 0.5) {
        guard !rewatchScheduled else { return }
        rewatchScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.rewatchScheduled = false
                self.watch()
                self.reload()
            }
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
            do {
                try self.settings(kind).save(kind)
                // Saved now: an earlier failure to save them is over.
                if self.problem?.hasPrefix(Self.settingsProblem) == true { self.problem = nil }
            } catch {
                self.problem = "\(Self.settingsProblem): \(error.localizedDescription)"
            }
        }
    }

    private static let settingsProblem = "Couldn't save the grid's settings"

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

    /// Reads whether it opens at login again (it can be changed in System Settings).
    func refreshOpenAtLogin() {
        let on = SMAppService.mainApp.status == .enabled
        if openAtLogin != on { openAtLogin = on }
    }

    /// Quits, saying first what's still running (it would be stopped). The stopping, and the
    /// saving of everything, is done as the app terminates (`AppDelegate`).
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
        }
        NSApp.terminate(nil)
    }
}

/// Quitting (from the menu, or as the Mac logs out): the editors save, what's running is stopped
/// and given a moment to end (a script that ignores the polite stop is ended for good two seconds
/// on), its last output is kept, and the runs are saved, before the app goes.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var quitting = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitting { return .terminateCancel }  // already on its way out
        let runs = AppModel.shared.runs
        Windows.saveEditors()
        runs.flush()
        guard runs.hasLiveRuns else {
            runs.saveNow()
            return .terminateNow
        }
        quitting = true
        runs.stopAll()
        // A little over the two seconds after which a stopped script is killed.
        waitForRuns(until: Date().addingTimeInterval(2.5))
        return .terminateLater
    }

    private func waitForRuns(until deadline: Date) {
        let runs = AppModel.shared.runs
        if runs.hasLiveRuns && Date() < deadline {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                MainActor.assumeIsolated { self?.waitForRuns(until: deadline) }
            }
            return
        }
        runs.saveNow()
        NSApp.reply(toApplicationShouldTerminate: true)
    }
}
