import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The translator: a model whose only job is to read what a client said to `POST /api/say` into
/// the adapter's own templates, when the words alone don't settle it (nothing matched closely,
/// two templates fit about as well, or the closest fit only loosely). It's stateless: each call
/// is what was said, why it's asked, and the templates there are; no conversation, no history,
/// no tools. It never answers the request and never does anything: it says which templates it
/// thinks were meant, filled in, and how sure it is. The adapter reads what it filled back
/// through its own matcher (a title it doesn't have, or a filling that isn't one of its
/// templates, is dropped), and the person's OK on the Mac is untouched.
///
/// Any model behind an OpenAI-style chat completions address (Ollama, LM Studio, llama.cpp, vLLM,
/// OpenAI, OpenRouter…) or Anthropic's Messages API. Its settings are a file of their own
/// (`say-translator.json` in the app's Application Support folder, or where `TMR_TRANSLATOR`
/// says), changed with `POST /api/say/translator`. When the model can't be reached, the adapter
/// answers as it did without one.
public actor SayTranslator {
    /// How to reach the model, and how sure it must be to be acted on.
    public struct Settings: Codable, Equatable, Sendable {
        /// Asked at all.
        public var on = true
        /// "openai" (a chat completions address) or "anthropic" (the Messages API).
        public var api = "openai"
        public var url = Settings.ollama
        public var model = "llama3.2"
        /// Sent as a bearer token (openai) or `x-api-key` (anthropic); empty: none, or the
        /// provider's own environment variable when the address is the provider's.
        public var key = ""
        /// Seconds to wait for an answer.
        public var timeout: Double = 20
        /// How sure the model must be for its reading to be acted on without a list.
        public var sure: Double = 0.75
        /// openai: "json_object" (the default), "json_schema", or "none" (for a server that takes neither).
        public var format = "json_object"
        /// anthropic: `output_config.effort` ("low" by default; empty: not sent).
        public var effort = "low"

        public static let ollama = "http://127.0.0.1:11434/v1/chat/completions"
        public static let anthropicURL = "https://api.anthropic.com/v1/messages"
        public static let anthropicModel = "claude-opus-5-5"
        public static let anthropicVersion = "2026-10-21"

        public init() {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Settings()
            on = try c.decodeIfPresent(Bool.self, forKey: .on) ?? d.on
            api = try c.decodeIfPresent(String.self, forKey: .api) ?? d.api
            url = try c.decodeIfPresent(String.self, forKey: .url) ?? d.url
            model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
            key = try c.decodeIfPresent(String.self, forKey: .key) ?? d.key
            timeout = try c.decodeIfPresent(Double.self, forKey: .timeout) ?? d.timeout
            sure = try c.decodeIfPresent(Double.self, forKey: .sure) ?? d.sure
            format = try c.decodeIfPresent(String.self, forKey: .format) ?? d.format
            effort = try c.decodeIfPresent(String.self, forKey: .effort) ?? d.effort
        }

        var isAnthropic: Bool { api.lowercased() == "anthropic" }

        /// The settings changed by what was sent (`{"on", "api", "url", "model", "key", "timeout",
        /// "sure", "format", "effort"}`); a new `api` without a `url` or `model` takes that api's own.
        public func changed(by f: [String: Any]) throws -> Settings {
            var s = self
            func string(_ k: String) -> String? {
                if let v = f[k] as? String { return v.trimmingCharacters(in: .whitespacesAndNewlines) }
                return nil
            }
            func number(_ k: String) -> Double? {
                if let n = f[k] as? NSNumber { return n.doubleValue }
                return (f[k] as? String).flatMap(Double.init)
            }
            if let v = f["on"] as? Bool { s.on = v } else if let v = string("on") { s.on = ["1", "true", "yes", "on"].contains(v.lowercased()) }
            if let api = string("api")?.lowercased() {
                guard ["openai", "anthropic"].contains(api) else { throw SayTranslatorError("api is \"openai\" (a chat completions address: Ollama, LM Studio, OpenAI…) or \"anthropic\"") }
                if api != s.api.lowercased() {
                    s.api = api
                    if f["url"] == nil { s.url = api == "anthropic" ? Self.anthropicURL : Self.ollama }
                    if f["model"] == nil { s.model = api == "anthropic" ? Self.anthropicModel : Settings().model }
                }
            }
            if let v = string("url") {
                guard let u = URL(string: v), ["http", "https"].contains(u.scheme?.lowercased() ?? ""), u.host != nil else {
                    throw SayTranslatorError("url is the model's address, like \(Self.ollama)")
                }
                s.url = v
            }
            if let v = string("model") {
                guard !v.isEmpty else { throw SayTranslatorError("model is the model's name, like llama3.2 or \(Self.anthropicModel)") }
                s.model = v
            }
            if let v = string("key") { s.key = v }
            if let v = number("timeout") { s.timeout = max(1, min(300, v)) }
            if let v = number("sure") { s.sure = max(0, min(1, v)) }
            if let v = string("format")?.lowercased() {
                guard ["json_object", "json_schema", "none"].contains(v) else { throw SayTranslatorError("format is json_object, json_schema or none") }
                s.format = v
            }
            if let v = string("effort")?.lowercased() { s.effort = v }
            return s
        }

        /// As `GET /api/say/translator` shows them: the key only as whether there is one.
        public var json: [String: Any] {
            ["on": on, "api": api, "url": url, "model": model, "key": key.isEmpty ? (envKey == nil ? "" : "from the environment") : "set",
             "timeout": timeout, "sure": sure, "format": format, "effort": effort]
        }

        /// The provider's own key from the environment, only for the provider's own address.
        var envKey: String? {
            let host = URL(string: url)?.host?.lowercased() ?? ""
            let env = ProcessInfo.processInfo.environment
            if isAnthropic, host == "api.anthropic.com" { return env["ANTHROPIC_API_KEY"].flatMap { $0.isEmpty ? nil : $0 } }
            if !isAnthropic, host == "api.openai.com" { return env["OPENAI_API_KEY"].flatMap { $0.isEmpty ? nil : $0 } }
            return nil
        }
    }

    /// Why the translator is asked.
    public enum Why: Sendable, Equatable {
        /// Nothing matched the words closely.
        case nothing
        /// Two (or more) templates fit about as well.
        case between([String])
        /// One fit, but only loosely.
        case weak(String)

        public var key: String {
            switch self {
            case .nothing: "nothing"
            case .between: "between"
            case .weak: "weak"
            }
        }

        /// As the model reads it.
        var line: String {
            switch self {
            case .nothing: return "Nothing matched these words closely."
            case let .between(t): return "These fit about as well, and the words don't say which: " + t.joined(separator: "; ") + "."
            case let .weak(t): return "The closest was \(t), but not closely."
            }
        }
    }

    /// One template the model thinks was meant, filled in.
    public struct Suggestion: Sendable, Equatable {
        public var title: String
        /// The template filled in, as a client would say it back.
        public var say: String
        public var confidence: Double
    }

    /// What the model said, and what it was given.
    public struct Translation: Sendable {
        public var meaning = ""
        public var question = ""
        public var suggestions: [Suggestion] = []
        /// What the model answered, as it came.
        public var raw = ""
        public var seconds = 0.0
        /// Why there's nothing: it's off, it couldn't be reached, its answer wasn't JSON.
        public var error: String?
        public var model = ""
        public var system = ""
        public var user = ""
    }

    /// One call, kept for `GET /api/say/translator` (the latest 50).
    public struct Call: Sendable {
        public let at: Date
        public let text: String
        public let why: String
        public let translation: Translation
    }

    /// Sends one request to the model: its body and status.
    public typealias Send = @Sendable (URLRequest) async throws -> (Data, Int)

    public static var defaultFile: URL {
        if let path = ProcessInfo.processInfo.environment["TMR_TRANSLATOR"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("Tool Mac Tool Run", isDirectory: true).appendingPathComponent("say-translator.json")
    }

    let file: URL?
    let send: Send
    public private(set) var settings: Settings
    public private(set) var calls: [Call] = []
    /// After the model couldn't be reached, it isn't asked again for a while (each say would wait).
    var resting: Date?
    static let rest: TimeInterval = 30

    /// Settings from `file` (nil: kept in memory only), or as given.
    public init(file: URL? = SayTranslator.defaultFile, settings: Settings? = nil, send: @escaping Send = SayTranslator.live) {
        self.file = file
        self.send = send
        if let settings {
            self.settings = settings
        } else if let file, let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Settings.self, from: data) {
            self.settings = saved
        } else {
            self.settings = Settings()
        }
    }

    /// One that's never asked (for tests, and a client that wants the templates alone).
    public static func off() -> SayTranslator {
        var s = Settings()
        s.on = false
        return SayTranslator(file: nil, settings: s)
    }

    /// Changes the settings, and keeps them (the file only its owner can read: it may hold a key).
    @discardableResult
    public func change(_ f: [String: Any]) throws -> Settings {
        let changed = try settings.changed(by: f)
        guard changed != settings else { return settings }
        settings = changed
        resting = nil
        if let file {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(settings).write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        return settings
    }

    /// Whether it would be asked now.
    public var ready: Bool { settings.on && (resting.map { Date() >= $0 } ?? true) }

    /// What the model makes of what was said, given the templates (the closest first). `using`
    /// asks with other settings (a benchmark trying models), leaving the kept ones as they are.
    public func translate(_ text: String, why: Why, forms: [SayForm], closest: Int, using: Settings? = nil, dry: Bool = false) async -> Translation {
        let s = using ?? settings
        var t = Translation()
        t.model = s.model
        (t.system, t.user) = Self.prompt(text, why: why, forms: forms, closest: closest)
        if dry { return t }
        guard s.on else {
            t.error = "the translator is off"
            return t
        }
        if using == nil, let r = resting, Date() < r {
            t.error = "the model couldn't be reached a moment ago; it's asked again after \(Int(Self.rest)) seconds"
            return t
        }
        let started = Date()
        do {
            let request = try Self.request(s, system: t.system, user: t.user)
            let (data, status) = try await send(request)
            t.seconds = Date().timeIntervalSince(started)
            guard (200..<300).contains(status) else {
                t.error = "the model answered \(status): " + String(decoding: data.prefix(300), as: UTF8.self)
                record(text, why, t)
                return t
            }
            guard let raw = Self.content(data, anthropic: s.isAnthropic) else {
                t.error = "the model's answer had no text: " + String(decoding: data.prefix(300), as: UTF8.self)
                record(text, why, t)
                return t
            }
            t.raw = raw
            guard let parsed = Self.parse(raw) else {
                t.error = "the model's answer wasn't the JSON asked for"
                record(text, why, t)
                return t
            }
            t.meaning = parsed.meaning
            t.question = parsed.question
            t.suggestions = parsed.suggestions
            if using == nil { resting = nil }
        } catch {
            t.seconds = Date().timeIntervalSince(started)
            t.error = "the model couldn't be reached at \(s.url): \(error.localizedDescription)"
            if using == nil { resting = Date().addingTimeInterval(Self.rest) }
        }
        record(text, why, t)
        return t
    }

    func record(_ text: String, _ why: Why, _ t: Translation) {
        calls.append(Call(at: Date(), text: text, why: why.key, translation: t))
        if calls.count > 50 { calls.removeFirst(calls.count - 50) }
    }

    // MARK: what the model sees

    /// The instructions: the same every call (so a server can cache them).
    public static let system = """
    You translate what a client said into the templates of Tool Mac Tool Run, an app on a Mac that runs the person's scripts and flows, searches and reads the web, keeps notes and a memory, and opens pages in Chrome. You only translate. You never answer the request yourself, never do it, and remember nothing between messages.

    You are given what the client said, why it needs translating, and the templates there are. In a template, {…} is a blank to fill, [a | b] is a choice of exactly one, and a line marked (optional) may be left out. A template is either one sentence (fill its blanks in place) or a title followed by "- label: value" lines (keep the title and every label, fill the values; a value of several lines goes in a fenced block under its label).

    Answer with JSON only, in this shape:
    {"meaning": "what the client wants, in a few plain words", "suggestions": [{"title": "a template's title, exactly as listed", "say": "that template filled in with the client's own words", "confidence": 0.9}], "question": ""}

    Rules:
    - At most 3 suggestions, the best first, and only templates from the list. Copy each title exactly.
    - Fill a blank only with what the client said or plainly meant ("rain in Lagos tomorrow" gives the place Lagos). Never invent a value. Leave a blank you can't fill as it is, like {a place}, and ask for it in "question".
    - Keep a template's fixed words as they are. Change only the blanks and the choices.
    - confidence is from 0 to 1: how sure you are that this template, filled this way, is what the client wants. Above 0.8 only when it plainly is.
    - A question about the world that no other template answers is "Search the web".
    - If nothing fits, give no suggestions and put a short question in "question". Otherwise "question" is "".

    For example, said: "will it rain in Lagos tomorrow", with a Weather template and Search the web among the templates:
    {"meaning": "the weather in Lagos tomorrow", "suggestions": [{"title": "Weather", "say": "what's the weather in Lagos", "confidence": 0.85}, {"title": "Search the web", "say": "search the web for rain in Lagos tomorrow", "confidence": 0.6}], "question": ""}
    """

    /// The answer's shape, for a server that takes a JSON schema.
    public static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "meaning": ["type": "string"],
            "suggestions": ["type": "array", "items": [
                "type": "object",
                "properties": ["title": ["type": "string"], "say": ["type": "string"], "confidence": ["type": "number"]],
                "required": ["title", "say", "confidence"], "additionalProperties": false,
            ] as [String: Any]],
            "question": ["type": "string"],
        ] as [String: Any],
        "required": ["meaning", "suggestions", "question"],
        "additionalProperties": false,
    ]

    /// At most this many templates are given.
    static let maxForms = 300

    /// The instructions and the one message: what was said, why it's asked, and the templates:
    /// the `closest` first, each with what it's for, then the rest, a line or two each (a folder
    /// of scripts can hold hundreds, and a small model's context is small).
    public static func prompt(_ text: String, why: Why, forms: [SayForm], closest: Int) -> (system: String, user: String) {
        let said = text.count > 2000 ? String(text.prefix(2000)) + "…" : text
        let given = Array(forms.prefix(maxForms))
        let near = given.prefix(closest), rest = given.dropFirst(closest)
        var out = "Said: \"\(said)\"\nWhy: \(why.line)\n"
        if !near.isEmpty { out += "\nThe closest templates by their words:\n" + near.map { "\n" + entry($0, about: true) + "\n" }.joined() }
        if !rest.isEmpty { out += "\n\(near.isEmpty ? "The templates" : "All the other templates"):\n\n" + rest.map { entry($0, about: false) }.joined(separator: "\n") + "\n" }
        return (system, out)
    }

    /// One template as the model reads it: its title (and whether it changes something or waits
    /// for the person at the Mac), how it's said, and (`about`) what it's for.
    static func entry(_ f: SayForm, about: Bool) -> String {
        let mark = f.asks ? " (runs on the Mac once the person there OKs it)" : f.changes ? " (changes something)" : ""
        var lines = [f.title + mark]
        if let s = f.sentences.first {
            lines.append("  " + s)
        } else {
            lines += f.fields.map(\.shown)
        }
        if about, !f.about.isEmpty { lines.append("  for: " + f.about) }
        return lines.joined(separator: "\n")
    }

    // MARK: asking

    static func request(_ s: Settings, system: String, user: String) throws -> URLRequest {
        guard let url = URL(string: s.url) else { throw SayTranslatorError("\(s.url) isn't an address") }
        var r = URLRequest(url: url, timeoutInterval: s.timeout)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = s.key.isEmpty ? s.envKey ?? "" : s.key
        var body: [String: Any]
        if s.isAnthropic {
            r.setValue(Settings.anthropicVersion, forHTTPHeaderField: "anthropic-version")
            if !key.isEmpty { r.setValue(key, forHTTPHeaderField: "x-api-key") }
            var config: [String: Any] = ["format": ["type": "json_schema", "schema": schema] as [String: Any]]
            if !s.effort.isEmpty { config["effort"] = s.effort }
            body = ["model": s.model, "max_tokens": 4096, "system": system,
                    "messages": [["role": "user", "content": user]], "output_config": config]
        } else {
            if !key.isEmpty { r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            body = ["model": s.model, "temperature": 0, "stream": false, "max_tokens": 1024,
                    "messages": [["role": "system", "content": system], ["role": "user", "content": user]]]
            switch s.format {
            case "json_schema": body["response_format"] = ["type": "json_schema", "json_schema": ["name": "translation", "strict": true, "schema": schema] as [String: Any]]
            case "none": break
            default: body["response_format"] = ["type": "json_object"]
            }
        }
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        return r
    }

    /// The text of the model's answer: a chat completion's message, or the Messages API's text blocks.
    static func content(_ data: Data, anthropic: Bool) -> String? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if anthropic {
            guard o["stop_reason"] as? String != "refusal", let blocks = o["content"] as? [[String: Any]] else { return nil }
            let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
            return text.isEmpty ? nil : text
        }
        let message = ((o["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])
        return (message?["content"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The JSON in what the model answered: forgiving of a fence or words around it, of a lone
    /// suggestion instead of a list, and of a confidence given as text or out of 100.
    public static func parse(_ raw: String) -> (meaning: String, question: String, suggestions: [Suggestion])? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
              let o = (try? JSONSerialization.jsonObject(with: Data(raw[start...end].utf8))) as? [String: Any] else { return nil }
        func text(_ v: Any?) -> String { (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        func number(_ v: Any?) -> Double {
            let d = (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap { Double($0.trimmingCharacters(in: CharacterSet(charactersIn: " %"))) } ?? 0.5
            return max(0, min(1, d > 1 ? d / 100 : d))
        }
        let list = (o["suggestions"] ?? o["matches"] ?? o["templates"]) as? [[String: Any]] ?? (o["title"] != nil ? [o] : [])
        let suggestions = list.compactMap { s -> Suggestion? in
            let title = text(s["title"])
            guard !title.isEmpty else { return nil }
            return Suggestion(title: title, say: text(s["say"] ?? s["filled"] ?? s["template"]), confidence: number(s["confidence"] ?? s["score"]))
        }
        return (text(o["meaning"]), text(o["question"]), Array(suggestions.prefix(3)))
    }

    /// The model asked over the network.
    public static let live: Send = { request in
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<(Data, Int), Error>) in
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error { return done.resume(throwing: error) }
                done.resume(returning: (data ?? Data(), (response as? HTTPURLResponse)?.statusCode ?? 0))
            }.resume()
        }
    }
}

public struct SayTranslatorError: Error, CustomStringConvertible, Sendable {
    public let description: String
    init(_ d: String) { description = d }
}
