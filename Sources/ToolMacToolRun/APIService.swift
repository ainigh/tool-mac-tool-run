import AppKit
import Foundation
import RunCore

/// The HTTP API: its settings, the server, and whether it's serving. What the panel shows and
/// switches. Every run it's asked for waits for Run on the Mac (`ApprovalCenter`).
@MainActor
final class APIService: ObservableObject {
    static let shared = APIService()

    @Published private(set) var settings: APISettings
    @Published private(set) var server: APIServer.State = .stopped
    /// The person wants it serving (it's started at launch when so).
    @Published private(set) var wantsServing: Bool

    private let current: SettingsBox
    private var http: APIServer!

    private static let settingsKey = "apiSettings"
    private static let servingKey = "apiServing"

    private init() {
        let defaults = UserDefaults.standard
        var loaded = APISettings()
        if let data = defaults.data(forKey: Self.settingsKey), let saved = try? JSONDecoder().decode(APISettings.self, from: data) {
            loaded = saved
        }
        settings = loaded
        current = SettingsBox(loaded)
        wantsServing = defaults.object(forKey: Self.servingKey) as? Bool ?? true
        let box = current
        let api = RunAPI(host: AppRunHost(), version: AppModel.version) { box.value }
        http = APIServer(api: api)
        http.onState = { [weak self] state in
            MainActor.assumeIsolated { self?.server = state }
        }
    }

    /// At launch: serve if it was serving.
    func launch() {
        if wantsServing { http.start(port: settings.port, network: settings.allowNetwork) }
    }

    var isServing: Bool {
        if case .running = server { return true }
        return false
    }

    var baseURL: String { "http://127.0.0.1:\(settings.port)" }

    /// The API in one page, for another app: the same as `GET /api/doc`, with this Mac's address
    /// and, when sharing on the network is on, the token.
    var doc: String { APIDoc.text(baseURL: baseURL, token: settings.allowNetwork ? settings.token : nil, version: AppModel.version) }

    func startServing() {
        wantsServing = true
        UserDefaults.standard.set(true, forKey: Self.servingKey)
        http.start(port: settings.port, network: settings.allowNetwork)
    }

    func stopServing() {
        wantsServing = false
        UserDefaults.standard.set(false, forKey: Self.servingKey)
        http.stop()
    }

    /// Quitting: stop listening without forgetting that it was serving.
    func stopForQuit() {
        http.stop()
    }

    func change(_ edit: (inout APISettings) -> Void) {
        var s = settings
        edit(&s)
        if s.allowNetwork, s.token.isEmpty { s.token = APISettings.newToken() }
        guard s != settings else { return }
        let restart = s.port != settings.port || s.allowNetwork != settings.allowNetwork
        settings = s
        current.value = s
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: Self.settingsKey) }
        if restart, wantsServing { http.start(port: s.port, network: s.allowNetwork) }
    }

    func setEndpoint(_ e: APIEndpoint, on: Bool) {
        change { s in
            if on { s.off.remove(e) } else { s.off.insert(e) }
        }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The settings, for the server's threads.
final class SettingsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: APISettings

    init(_ s: APISettings) { stored = s }

    var value: APISettings {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}

/// The app, as the API sees it: the folder, the person's go-ahead, and the runs (the same runs
/// the cells and Runs show).
final class AppRunHost: RunHost, @unchecked Sendable {
    func catalog() async -> Catalog? {
        guard let lib = await MainActor.run(body: { AppModel.shared.library }) else { return nil }
        // Read afresh (off the main thread): a script added a moment ago can be asked for.
        return Catalog(folder: lib.root, scripts: lib.scripts(), flows: lib.flows())
    }

    func approve(_ request: RunRequest) async -> Approval {
        await ApprovalCenter.ask(request)
    }

    func start(_ request: RunRequest) async throws -> UUID {
        try await MainActor.run { () throws -> UUID in
            guard let lib = AppModel.shared.library else {
                throw HTTPError(status: 409, code: "no_folder", message: "the scripts folder was closed before it could run")
            }
            let runs = AppModel.shared.runs
            switch request.what {
            case let .script(item):
                return runs.run(script: item, arguments: request.arguments, folder: lib.root, stdin: request.stdin,
                                requestedBy: request.requestedBy, why: request.why)
            case let .flow(item):
                return runs.run(flow: item, arguments: request.arguments, library: lib, requestedBy: request.requestedBy, why: request.why)
            case let .source(code):
                return runs.run(flowSource: code, name: request.name, arguments: request.arguments, library: lib,
                                requestedBy: request.requestedBy, why: request.why)
            }
        }
    }

    func automations() async -> [AutomationEntry] {
        await MainActor.run { AutomationCenter.shared.entries() }
    }

    func automate(_ request: RunRequest) async throws -> AutomationEntry {
        try await MainActor.run { () throws -> AutomationEntry in
            guard let a = request.automation else { throw HTTPError(status: 400, code: "bad_request", message: "nothing to tag") }
            let item: ScriptItem
            switch request.what {
            case let .script(s), let .flow(s): item = s
            case .source: throw HTTPError(status: 400, code: "bad_request", message: "only a script or a flow from the folder can be automated")
            }
            let center = AutomationCenter.shared
            center.set(a, for: item)
            return AutomationEntry(id: item.id, grid: item.grid, title: item.title, automation: a, next: center.next(for: item.id, kind: item.grid)?.at)
        }
    }

    func record(_ id: UUID) async -> RunRecord? {
        await MainActor.run { AppModel.shared.runs.record(id) }
    }

    func steps(of id: UUID) async -> [RunRecord] {
        await MainActor.run { AppModel.shared.runs.steps(of: id) }
    }

    func recent(_ limit: Int) async -> [RunRecord] {
        await MainActor.run { AppModel.shared.runs.recent(limit) }
    }

    func stop(_ id: UUID) async -> Bool {
        await MainActor.run { () -> Bool in
            let runs = AppModel.shared.runs
            guard runs.isRunning(id) else { return false }
            runs.stop(id)
            return true
        }
    }
}
