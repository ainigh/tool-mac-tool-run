import Foundation

/// `GET /api/search?q=…`: the routes, scripts and flows that match some words, the best first,
/// instead of every route at once (`/api/endpoints` is long for a small client). Each route is
/// found by its path, its summary, its group, and its tags (the words someone looking for it
/// would say: "remember", "birthday", "status", "job"); each script and flow by its name, what it
/// says it does, its topic, and the tags its header gives (`# Tags: weather forecast`).
public enum APISearch {
    public struct Hit {
        public var kind: String
        public var matched: [String]
        /// How many of the words it has where they count (its name, path, tags or summary; not
        /// only in its group's description).
        public var strong: Int
        public var score: Double
        /// Words of the search it says it isn't for (it's put lower for them).
        public var against: [String] = []
        /// Its place in the order things are listed in, to keep ties in that order.
        public var order: Int
        public var json: [String: Any]
    }

    /// What a search looks in.
    public enum Scope: String, CaseIterable, Sendable {
        case routes, scripts, flows
    }

    /// Words a question has that say nothing about what's wanted.
    static let stopWords: Set<String> = [
        "a", "an", "the", "to", "of", "for", "and", "or", "in", "on", "at", "by", "with", "from", "into", "about",
        "i", "me", "my", "we", "our", "you", "your", "it", "its", "this", "that", "these", "those", "there",
        "is", "are", "be", "was", "do", "does", "can", "could", "would", "should", "will", "want", "wants", "need",
        "how", "what", "which", "when", "where", "who", "why", "please", "some", "any", "all", "one", "get", "api",
    ]

    /// The words of a text as a search compares them: lowercased, accents aside, split at
    /// anything that isn't a letter or a digit, each cut to its stem ("notes", "noted": note).
    public static func words(_ text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return folded.split { !($0.isLetter || $0.isNumber) }.map { stem(String($0)) }.filter { !$0.isEmpty }
    }

    /// A word without its ending ("birthdays" birthday, "categories" category, "scheduled" and
    /// "schedules" schedul): not English, only close enough that the same word written two ways
    /// compares the same. The plural first, then -ing or -ed, then a last e.
    static func stem(_ w: String) -> String {
        var w = w
        if w.count > 4, w.hasSuffix("ies") { w = String(w.dropLast(3)) + "y" }
        else if w.count > 4, ["ses", "xes", "ches", "shes"].contains(where: w.hasSuffix) { w = String(w.dropLast(2)) }
        else if w.count > 3, w.hasSuffix("s"), !w.hasSuffix("ss") { w = String(w.dropLast()) }
        var cut = false
        if w.count > 5, w.hasSuffix("ing") { w = String(w.dropLast(3)); cut = true }
        else if w.count > 5, w.hasSuffix("ed") { w = String(w.dropLast(2)); cut = true }
        // "running" runn, "stopped" stopp: one of a doubled last letter (run, stop).
        if cut, let last = w.last, w.dropLast().last == last, !"aeiouls".contains(last) { w.removeLast() }
        if w.count > 4, w.hasSuffix("e") { w = String(w.dropLast()) }
        return w
    }

    /// The words to look for: the question's, without the ones that say nothing (unless that's
    /// all it has), each once.
    public static func query(_ q: String) -> [String] {
        // A letter alone ("what's": s) says nothing; a digit might.
        let all = words(q).filter { $0.count > 1 || $0.first?.isNumber == true }
        let kept = all.filter { !stopWords.contains($0) }
        var seen: Set<String> = []
        return (kept.isEmpty ? all : kept).filter { seen.insert($0).inserted }
    }

    /// One thing to find, as fields of words, each with its weight.
    struct Doc {
        var fields: [(words: Set<String>, weight: Int)]
        /// Words it's not for (a route's `!open` tags): a search with one puts it lower.
        var notFor: Set<String> = []

        /// How well one word matches: the weight of the best field it's in, or (a word of three
        /// letters or more) a field word it begins, one less.
        func score(_ q: String) -> Int {
            var best = 0
            for f in fields {
                if f.words.contains(q) { best = max(best, f.weight) }
                else if q.count >= 3, f.words.contains(where: { $0.count > q.count && $0.hasPrefix(q) }) { best = max(best, f.weight - 1) }
            }
            return best
        }
    }

    static func set(_ texts: [String]) -> Set<String> { Set(texts.flatMap(words)) }

    static let methodWords: [String: String] = [
        "GET": "read list show see look view", "POST": "send create do make", "PUT": "write replace update save set",
        "DELETE": "delete remove clear",
    ]

    static func doc(_ r: APIRoutes.Route, in g: APIRoutes.Group) -> Doc {
        let path = r.path.split(separator: "/").filter { !$0.hasPrefix("{") }.map(String.init)
        let (tags, notFor) = split(r.tags), (groupTags, groupNotFor) = split(g.tags)
        // The group's about says what it isn't for, in words ("never opens a page"): not matched on.
        return Doc(fields: [
            (set(tags + path), 4),
            (set([r.summary] + groupTags + [g.id]), 3),
            (set([g.title, groupNotFor.isEmpty ? g.about : "", methodWords[r.method] ?? ""]), 1),
        ], notFor: set(notFor + groupNotFor))
    }

    /// Tags, and the words written `!word` (what it's not for).
    static func split(_ tags: [String]) -> (tags: [String], notFor: [String]) {
        (tags.filter { !$0.hasPrefix("!") }, tags.filter { $0.hasPrefix("!") }.map { String($0.dropFirst()) })
    }

    /// Words the examples that ship with the app are found by, beyond what their headers say
    /// (their files can't change without making them look edited): what someone would ask for.
    static let exampleTags: [String: String] = [
        "browser/open-page.sh": "open go goto navigate visit load url address website link browse web page",
        "browser/google.sh": "google search web online internet look up question answer browse open",
        "browser/site-search.sh": "search web website site youtube amazon github wikipedia reddit online",
        "browser/browser.sh": "open navigate url javascript",
        "browser/find-tab.sh": "switch tab go",
        "browser/youtube.sh": "video search watch",
        "utilities/weather.py": "forecast rain temperature",
    ]

    static func doc(_ s: ScriptItem) -> Doc {
        Doc(fields: [
            (set([s.title] + s.tags + [APICatalog.topic(of: s) ?? "", exampleTags[s.id] ?? ""]), 4),
            (set([s.summary ?? "", s.grid.rawValue, s.language.title, s.language.rawValue, s.grid.isFlow ? "flow" : "script"]), 3),
            (set(s.inputs.map(\.prompt)), 1),
        ])
    }

    /// The best matches, best first, at most `limit`, and how many matched in all. Only the
    /// ones that match as many of the words (where they count) as the best does (one fewer, for
    /// three words or more) are kept, so a long question doesn't bring back everything that has one of them.
    /// A word few things have counts for more than one most things have ("cancel a running
    /// script": cancel says the most).
    public static func search(_ q: String, scopes: Set<Scope> = Set(Scope.allCases), group: String? = nil,
                              catalog: Catalog?, limit: Int = 10) -> (hits: [Hit], total: Int) {
        let terms = query(q)
        guard !terms.isEmpty else { return ([], 0) }
        // Each thing's score for each word, then how rare each word is among them all.
        var scored: [(scores: [Int], hit: Hit)] = []
        var docs = 0
        func consider(_ d: Doc, kind: String, order: Int, json: @autoclosure () -> [String: Any]) {
            docs += 1
            let scores = terms.map(d.score)
            guard scores.contains(where: { $0 > 0 }) else { return }
            let matched = zip(terms, scores).filter { $0.1 > 0 }.map(\.0)
            var strong = scores.filter { $0 >= 2 }.count
            // Asked for something it says it isn't for: lower (a word fewer, half the score).
            let against = terms.filter(d.notFor.contains)
            if !against.isEmpty { strong = max(0, strong - 1) }
            var hit = Hit(kind: kind, matched: matched, strong: strong, score: 0, order: order, json: json())
            hit.against = against
            scored.append((scores, hit))
        }
        var order = 0
        if scopes.contains(.routes) {
            for g in APIRoutes.groups where group == nil || g.id == group {
                for r in g.routes {
                    order += 1
                    consider(doc(r, in: g), kind: "route", order: order, json: routeJSON(r, g))
                }
            }
        }
        if let c = catalog, group == nil || group == "scripts" {
            if scopes.contains(.scripts) {
                for s in c.scripts {
                    order += 1
                    consider(doc(s), kind: "script", order: order, json: scriptJSON(s))
                }
            }
            if scopes.contains(.flows) {
                for f in c.flows {
                    order += 1
                    consider(doc(f), kind: "flow", order: order, json: flowJSON(f))
                }
            }
        }
        let rarity: [Double] = terms.indices.map { k in
            let having = scored.filter { $0.scores[k] > 0 }.count
            return 1 + log(Double(max(docs, 1)) / Double(max(having, 1)))
        }
        let hits: [Hit] = scored.map { s in
            var h = s.hit
            let raw = zip(s.scores, rarity).reduce(0) { $0 + Double($1.0) * $1.1 } * (h.against.isEmpty ? 1 : 0.5)
            h.score = (raw * 100).rounded() / 100
            return h
        }
        let most = hits.map(\.strong).max() ?? 0
        let floor = max(most > 0 ? 1 : 0, most - (terms.count >= 3 ? 1 : 0))
        let kept = hits.filter { $0.strong >= floor }.sorted { a, b in
            if a.strong != b.strong { return a.strong > b.strong }
            if a.score != b.score { return a.score > b.score }
            return a.order < b.order
        }
        return (Array(kept.prefix(limit)), kept.count)
    }

    // MARK: what each hit says

    static func routeJSON(_ r: APIRoutes.Route, _ g: APIRoutes.Group) -> [String: Any] {
        var out: [String: Any] = ["method": r.method, "path": r.path, "summary": r.summary, "group": g.id, "asks_on_the_mac": r.asks,
                                  "tags": split(r.tags).tags, "call": r.key]
        let notFor = split(r.tags).notFor + split(g.tags).notFor
        if !notFor.isEmpty { out["not_for"] = notFor }
        return out
    }

    /// A script, with the request that runs it (its inputs as placeholder arguments).
    static func scriptJSON(_ s: ScriptItem) -> [String: Any] {
        var out = RunAPI.scriptJSON(s)
        var body: [String: Any] = ["script": s.id, "async": true, "client": "<your app's name>", "why": "<why, in a sentence the person reads before clicking Run>"]
        let args = s.inputs.filter { $0.kind == .argument }.map { "<\($0.prompt)>" }
        if !args.isEmpty { body["args"] = args }
        if let text = s.inputs.first(where: { $0.kind == .text }) { body["stdin"] = "<\(text.prompt)>" }
        out["run"] = ["method": "POST", "path": "/api/run", "body": body, "asks_on_the_mac": true]
        return out
    }

    static func flowJSON(_ f: ScriptItem) -> [String: Any] {
        var out = RunAPI.flowJSON(f)
        var body: [String: Any] = ["flow": f.id, "async": true, "client": "<your app's name>", "why": "<why, in a sentence the person reads before clicking Run>"]
        let args = f.inputs.map { "<\($0.prompt)>" }
        if !args.isEmpty { body["args"] = args }
        out["run"] = ["method": "POST", "path": "/api/compose", "body": body, "asks_on_the_mac": true]
        return out
    }

    /// The groups alone, each with how many routes it has and its words: a map small enough for
    /// any client, to look deeper with `?group=` or a search.
    static func brief(settings: APISettings) -> [[String: Any]] {
        APIRoutes.groups.map { g in
            var out: [String: Any] = ["id": g.id, "title": g.title, "about": g.about, "routes": g.routes.count, "tags": split(g.tags).tags,
                                      "list": "/api/endpoints?group=\(g.id)"]
            if let e = g.endpoint { out["on"] = settings.isOn(e) }
            return out
        }
    }
}
