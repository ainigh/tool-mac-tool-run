import Foundation

/// The API's endpoint groups, each of which can be switched off in the menu bar panel.
public enum APIEndpoint: String, CaseIterable, Codable, Sendable {
    case run, compose, catalog, runs, library

    public var title: String {
        switch self {
        case .run: return "Run scripts"
        case .compose: return "Run flows"
        case .catalog: return "List scripts and flows"
        case .runs: return "Runs and their output"
        case .library: return "File library"
        }
    }

    public var routes: String {
        switch self {
        case .run: return "POST /api/run"
        case .compose: return "POST /api/compose · /api/check"
        case .catalog: return "GET /api/scripts · /api/flows"
        case .runs: return "GET /api/runs · /api/requests"
        case .library: return "/api/library (no asking)"
        }
    }

    /// What it does, in a sentence (under the pointer, in the panel).
    public var help: String {
        switch self {
        case .run: return "Other apps can ask to run a script from your folder. Each run waits for you to click Run on this Mac."
        case .compose: return "Other apps can ask to run a flow, or send Flow code to run. Each run waits for you to click Run on this Mac."
        case .catalog: return "Other apps can see the names, languages and descriptions of your scripts and flows (not what's in them)."
        case .runs: return "Other apps can read the runs and their requests (how they went and what they printed) and stop one (a run you started asks you first)."
        case .library: return "Other apps can list, read, write, search and delete the notes in LIBRARY (in TOOL-MAC-RUN on your Desktop), without asking you each time. A delete moves the note to the library's own Trash, where it can be restored."
        }
    }
}

/// What the person has set that the API answers by.
public struct APISettings: Equatable, Codable, Sendable {
    public var off: Set<APIEndpoint> = []
    /// Listen on every interface, not just this Mac (callers from elsewhere need the token).
    public var allowNetwork = false
    public var token = ""
    /// Browser origins allowed besides this machine's pages ("https://app.example.com", globs).
    public var origins: [String] = []
    public var port = APISettings.defaultPort

    /// Super Voice is 8767; this is the one after it.
    public static let defaultPort = 8768

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // An endpoint a newer version added (or an older one dropped) doesn't lose the rest.
        off = Set((try c.decodeIfPresent([String].self, forKey: .off) ?? []).compactMap(APIEndpoint.init(rawValue:)))
        allowNetwork = try c.decodeIfPresent(Bool.self, forKey: .allowNetwork) ?? false
        token = try c.decodeIfPresent(String.self, forKey: .token) ?? ""
        origins = try c.decodeIfPresent([String].self, forKey: .origins) ?? []
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? Self.defaultPort
    }

    public func isOn(_ e: APIEndpoint) -> Bool { !off.contains(e) }

    /// A fresh token for sharing on the network.
    public static func newToken() -> String {
        let chars = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<32).map { _ in chars.randomElement()! })
    }
}

/// Who may call: programs on this Mac always; browsers only from allowed origins; other machines
/// only when sharing on the network is on, and with the token. (Whoever calls, nothing runs until
/// it's allowed on the Mac: that's `RunAPI`'s.)
public enum Access {
    /// Why a request is refused, or nil to let it through.
    public static func refusal(_ req: HTTPRequest, settings: APISettings) -> HTTPError? {
        // A website pointing its own name at 127.0.0.1 (DNS rebinding) says that name here.
        let otherHost = req.header("host").map { !isLoopbackHost($0) } ?? false
        if !settings.allowNetwork, otherHost {
            return HTTPError(status: 403, code: "forbidden", message: "requests for another host are refused")
        }
        if let origin = req.header("origin"), !originAllowed(origin, settings: settings) {
            return HTTPError(status: 403, code: "forbidden", message: "cross-site request refused (\(origin) isn't allowed)")
        }
        // A browser's preflight never carries the token; it only gets the CORS headers back.
        if req.method == "OPTIONS" {
            return req.fromLoopback || settings.allowNetwork ? nil
                : HTTPError(status: 403, code: "forbidden", message: "only this Mac may call")
        }
        // From another machine, or by a name that isn't this Mac's (so maybe a rebinding website,
        // even though it comes from this Mac): the token.
        if !req.fromLoopback || otherHost {
            guard settings.allowNetwork, !settings.token.isEmpty else {
                return HTTPError(status: 403, code: "forbidden", message: "only this Mac may call")
            }
            if bearer(req) != settings.token {
                return HTTPError(status: 401, code: "unauthorized", message: "send Authorization: Bearer <token> (the token is in Tool Mac Tool Run's panel)")
            }
        }
        return nil
    }

    static func bearer(_ req: HTTPRequest) -> String? {
        guard let auth = req.header("authorization") else { return nil }
        let parts = auth.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        return parts[1].trimmingCharacters(in: .whitespaces)
    }

    /// Where the caller reached the API, for a doc it can paste: its `Host` header
    /// (`http://192.168.1.5:8768` from another device), else this Mac's loopback address.
    public static func baseURL(_ req: HTTPRequest, settings: APISettings) -> String {
        let fallback = "http://127.0.0.1:\(settings.port)"
        guard let host = req.header("host")?.trimmingCharacters(in: .whitespaces), !host.isEmpty,
              host.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || ".:[]-_".unicodeScalars.contains($0) })
        else { return fallback }
        return "http://\(host)"
    }

    /// localhost, 127.0.0.1, [::1], with or without a port.
    public static func isLoopbackHost(_ host: String) -> Bool {
        var h = host.lowercased().trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("[") {
            h = String(h.dropFirst().prefix { $0 != "]" })
        } else if let colon = h.lastIndex(of: ":") {
            h = String(h[..<colon])
        }
        if h == "localhost" || h == "::1" || h.hasSuffix(".localhost") { return true }
        // 127.x.x.x, as an address (not a name like 127.0.0.1.example.com).
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts[0] == "127" && parts.allSatisfy { UInt8($0) != nil }
    }

    public static func originAllowed(_ origin: String, settings: APISettings) -> Bool {
        if let url = URL(string: origin), url.scheme == "http", let host = url.host,
           isLoopbackHost(host.contains(":") ? "[\(host)]" : host) {
            return true
        }
        return settings.origins.contains { glob($0, matches: origin) }
    }

    /// `*` matches anything (including nothing).
    public static func glob(_ pattern: String, matches s: String) -> Bool {
        let p = Array(pattern.lowercased()), t = Array(s.lowercased())
        var pi = 0, ti = 0, star = -1, mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] == t[ti] {
                pi += 1
                ti += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi
                mark = ti
                pi += 1
            } else if star >= 0 {
                pi = star + 1
                mark += 1
                ti = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    /// CORS headers for an allowed origin.
    public static func cors(_ req: HTTPRequest, settings: APISettings) -> [(String, String)] {
        guard let origin = req.header("origin"), originAllowed(origin, settings: settings) else { return [] }
        return [
            ("Access-Control-Allow-Origin", origin),
            ("Vary", "Origin"),
            ("Access-Control-Allow-Methods", "GET, POST, OPTIONS"),
            ("Access-Control-Allow-Headers", "Content-Type, Authorization, X-Client"),
            ("Access-Control-Max-Age", "600"),
        ]
    }
}
