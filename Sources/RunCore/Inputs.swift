import Foundation

/// What a script (or a flow) asks for before it runs, as its header says, one line each:
///
///     # Input: What should Google be asked?            an argument, needed
///     # Input (optional): A place (empty: where you are) an argument, may be left empty
///     # Input text: The JSON to pick from               text handed to it as its input (stdin)
///     # Why: It's typed into Google's search box as is  why the one before is asked for (optional)
///
/// (`//` or `--` in front, for a flow or a language that comments that way.) The API board asks
/// for each before a click runs it, with its `Why:` under the field, so the person knows what
/// the answer is for before typing it; `GET /api/scripts` lists them for other apps.
public struct ScriptInput: Equatable, Hashable, Sendable, Codable {
    public enum Kind: String, Equatable, Hashable, Sendable, Codable {
        /// One argument (the whole answer, spaces and all).
        case argument
        /// Text handed to it as its input (stdin).
        case text
    }

    public var prompt: String
    public var kind: Kind
    public var optional: Bool
    /// Why it's asked for, or what the answer is used for (the `Why:` line under its `Input:` line).
    public var why: String?

    public init(prompt: String, kind: Kind = .argument, optional: Bool = false, why: String? = nil) {
        self.prompt = prompt
        self.kind = kind
        self.optional = optional
        self.why = why
    }

    /// The inputs a script's header declares, in order. Only the comment lines at its top count.
    public static func declared(in contents: String) -> [ScriptInput] {
        var found: [ScriptInput] = []
        for raw in contents.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).prefix(60) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#!") { continue }
            guard let marker = ["//", "#", "--"].first(where: { line.hasPrefix($0) }) else { break }
            let said = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            if let input = parse(said) {
                found.append(input)
            } else if let why = parseWhy(said), !found.isEmpty, found[found.count - 1].why == nil {
                // A "Why:" line goes with the Input: line just above it.
                found[found.count - 1].why = why
            }
        }
        return found
    }

    /// The words a header's `Tags:` lines give (`# Tags: weather, forecast rain`), in order,
    /// lowercased, each once. Only the comment lines at its top count.
    public static func declaredTags(in contents: String) -> [String] {
        var found: [String] = []
        for raw in contents.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).prefix(60) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#!") { continue }
            guard let marker = ["//", "#", "--"].first(where: { line.hasPrefix($0) }) else { break }
            for tag in parseTags(line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)) ?? [] where !found.contains(tag) {
                found.append(tag)
            }
        }
        return found
    }

    /// "Tags: weather, forecast rain" → ["weather", "forecast", "rain"], or nil.
    public static func parseTags(_ said: String) -> [String]? {
        guard let colon = said.firstIndex(of: ":"), said[..<colon].lowercased().trimmingCharacters(in: .whitespaces) == "tags" else { return nil }
        let tags = said[said.index(after: colon)...].lowercased().split { $0 == "," || $0.isWhitespace }.map(String.init)
        return tags.isEmpty ? nil : tags
    }

    /// "Why: …" (the line explaining the input above it), or nil.
    public static func parseWhy(_ said: String) -> String? {
        guard let colon = said.firstIndex(of: ":"), said[..<colon].lowercased().trimmingCharacters(in: .whitespaces) == "why" else { return nil }
        let text = said[said.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// "Input: …", "Input (optional): …", "Input text: …", "Input text (optional): …".
    static func parse(_ said: String) -> ScriptInput? {
        guard let colon = said.firstIndex(of: ":") else { return nil }
        let head = said[..<colon].lowercased().split(separator: " ").joined(separator: " ")
        let prompt = said[said.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !prompt.isEmpty else { return nil }
        switch head {
        case "input": return ScriptInput(prompt: prompt)
        case "input (optional)": return ScriptInput(prompt: prompt, optional: true)
        case "input text": return ScriptInput(prompt: prompt, kind: .text)
        case "input text (optional)": return ScriptInput(prompt: prompt, kind: .text, optional: true)
        default: return nil
        }
    }

    /// The arguments and the input text the answers make (an empty optional argument is left out).
    public static func split(_ inputs: [ScriptInput], answers: [String]) -> (arguments: [String], stdin: String?) {
        var arguments: [String] = []
        var stdin: String?
        for (input, answer) in zip(inputs, answers) {
            switch input.kind {
            case .argument:
                if !(input.optional && answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { arguments.append(answer) }
            case .text:
                stdin = (stdin.map { $0 + "\n" } ?? "") + answer
            }
        }
        return (arguments, stdin)
    }

    /// Why these answers can't run it yet (a needed one is empty), or nil.
    public static func missing(_ inputs: [ScriptInput], answers: [String]) -> String? {
        for (k, input) in inputs.enumerated() where !input.optional {
            let answer = k < answers.count ? answers[k] : ""
            if answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "\(input.prompt) — this one is needed." }
        }
        return nil
    }
}
