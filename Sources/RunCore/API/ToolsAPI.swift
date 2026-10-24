import Foundation

/// Everything the API does, as a short list of tools a model calls by name (`/api/tools`): each
/// with what it's for, its arguments, and whether it waits for Run on the Mac, with a guide and
/// examples for the model's instructions. `POST /api/tools/{name}` calls one: its arguments are
/// read here (the names a model reaches for too), turned into the route it stands for, and that
/// route's answer comes back as it is. So a client hands the list to its model and passes its
/// calls through: it never knows the routes, and what's added here is there the day it ships.
public enum Tools {
    /// One argument: its name, its type (string, integer, boolean, list, object), whether it must
    /// be given, what it is, and other names a model gives it.
    public struct Arg: Sendable {
        public let name: String
        public let type: String
        public let required: Bool
        public let about: String
        public let aliases: [String]

        init(_ name: String, _ type: String, _ about: String, required: Bool = false, aliases: String = "") {
            self.name = name
            self.type = type
            self.required = required
            self.about = about
            self.aliases = aliases.split(separator: " ").map(String.init)
        }

        var json: [String: Any] { ["name": name, "type": type, "required": required, "about": about] }

        /// "url (string)", "max (integer, optional)".
        var said: String { "\(name) (\(type)\(required ? "" : ", optional")): \(about)" }
    }

    /// The route a call stands for.
    public struct Call {
        public var method: String
        public var path: String
        public var body: [String: Any]?
    }

    public struct Tool: @unchecked Sendable {
        public let name: String
        public let description: String
        public let args: [Arg]
        /// It waits for the person to click Run on the Mac.
        public let asks: Bool
        /// It runs something that prints as it goes: "stream": true follows it live.
        public let stream: Bool
        /// The switch that turns it off (nil: always on).
        public let endpoint: APIEndpoint?
        /// Other names a model calls it by; "name:op" also gives its op.
        public let aliases: [String]
        /// Words it's found by (`GET /api/search`), beyond its name and description.
        public let tags: String
        /// The route it calls, for a person reading the list.
        public let uses: String
        let build: @Sendable (LibraryAPI.Fields) throws -> Call

        init(_ name: String, _ description: String, args: [Arg] = [], asks: Bool = false, stream: Bool = false, endpoint: APIEndpoint? = nil,
             aliases: String = "", tags: String = "", uses: String, build: @escaping @Sendable (LibraryAPI.Fields) throws -> Call) {
            self.name = name
            self.description = description
            self.args = args
            self.asks = asks
            self.stream = stream
            self.endpoint = endpoint
            self.aliases = aliases.split(separator: " ").map(String.init)
            self.tags = tags
            self.uses = uses
            self.build = build
        }

        func json(_ s: APISettings) -> [String: Any] {
            var out: [String: Any] = [
                "name": name, "description": description, "args": args.map(\.json), "asks_on_the_mac": asks,
                "answers": asks ? "once the person clicks Run on the Mac (a card waits for them)" : "at once",
                "stream": stream, "on": endpoint.map(s.isOn) ?? true, "aliases": aliases.map { String($0.split(separator: ":")[0]) },
                "call": "POST /api/tools/\(name)", "uses": uses,
            ]
            if let e = endpoint { out["switch"] = e.rawValue }
            return out
        }

        /// What it takes, in a line: "q (string): a few words; in (string, optional): …".
        var takes: String { args.isEmpty ? "nothing" : args.map(\.said).joined(separator: "; ") }

        /// The first sentence of what it does.
        var gist: String {
            let d = description
            if let r = d.range(of: ". ") { return String(d[..<r.lowerBound]) + "." }
            return d
        }
    }

    // MARK: building the routes' requests

    static func esc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? s }

    static func query(_ pairs: [(String, String?)]) -> String {
        let kept = pairs.compactMap { k, v in v.map { "\(k)=\(esc($0))" } }
        return kept.isEmpty ? "" : "?" + kept.joined(separator: "&")
    }

    /// The fields given, as a body (nothing of the call's own: why, client, stream are added after).
    static func body(_ f: LibraryAPI.Fields, _ keys: [String]? = nil) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in f.values where keys?.contains(k) ?? true { out[k] = v }
        return out
    }

    static func need(_ f: LibraryAPI.Fields, _ key: String, _ what: String) throws -> String {
        guard let v = f.text(key), !v.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw HTTPError(status: 400, code: "missing_argument", message: what)
        }
        return v
    }

    /// A list of strings from what was given: a list, or one string (as one item, never split).
    static func strings(_ v: Any?) -> [String]? {
        switch v {
        case let l as [Any]: return l.compactMap { RunAPI.text($0) ?? (JSONSerialization.isValidJSONObject($0) ? String(decoding: JSON.data($0), as: UTF8.self) : nil) }
        case let s as String: return s.trimmingCharacters(in: .whitespaces).isEmpty ? [] : [s]
        case let n as NSNumber: return [RunAPI.text(n) ?? n.stringValue]
        default: return nil
        }
    }

    /// An op as a model writes it ("Read", "read-page"), and what it means among `ops`.
    static func op(_ f: LibraryAPI.Fields, _ aliases: [String: String] = [:], default fallback: String? = nil) -> String? {
        guard let raw = f.text("op") ?? f.text("action") ?? f.text("operation") ?? fallback else { return nil }
        let o = raw.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
        return aliases[o] ?? o
    }

    static let browserOps = ["open", "page", "find", "has", "highlight", "tabs", "url", "outline", "status"]
    static let browserOpAliases: [String: String] = [
        "read": "page", "text": "page", "content": "page", "read_page": "page", "get_page": "page", "get_text": "page", "links": "page",
        "title": "url", "address": "url", "current": "url", "current_url": "url", "get_url": "url", "tab": "url",
        "list_tabs": "tabs", "windows": "tabs",
        "contains": "has", "check": "has", "exists": "has", "is_there": "has",
        "search": "find", "locate": "find", "where": "find", "find_text": "find", "look_for": "find",
        "show": "highlight", "point": "highlight", "ring": "highlight", "mark": "highlight", "show_where": "highlight",
        "headings": "outline", "structure": "outline", "layout": "outline", "map": "outline",
        "go": "open", "goto": "open", "go_to": "open", "navigate": "open", "visit": "open", "load": "open", "open_url": "open", "open_page": "open", "new_tab": "open",
        "state": "status", "is_open": "status", "chrome": "status",
    ]
    static let browserActs: Set<String> = ["click", "press", "tap", "type", "fill", "enter", "input", "submit", "scroll", "select", "choose", "hover", "back", "forward", "refresh", "reload", "download", "upload", "close"]

    // MARK: the tools

    public static let all: [Tool] = [
        Tool("find", "Finds the tools, scripts and flows for something by a few words (\"weather\", \"play a song\", \"rename a note\"), best first, each with what it does and takes. Use it when unsure what fits or what something takes, and before ever saying you can't.",
             args: [Arg("q", "string", "a few words of what you want to do", required: true, aliases: "query words text what"),
                    Arg("in", "string", "only tools, scripts, flows or routes (several with commas)", aliases: "kind kinds scope")],
             aliases: "search search_tools find_tool find_script search_scripts search_api lookup_tool which_tool",
             tags: "discover which how lookup", uses: "GET /api/search") { f in
            let q = try need(f, "q", "find takes q: a few words of what you want to do (\"weather\", \"rename a note\").")
            return Call(method: "GET", path: "/api/search" + query([("q", q), ("in", f.text("in") ?? "tools,scripts,flows"), ("limit", "8")]))
        },
        Tool("say", "Everything here in plain words, with no other tool: say what you want and get words back. If it answers with templates, fill one in (its {blanks}, one of each [choice]) and say it back. It keeps track of what you asked for and says what changed at the start of its next answer.",
             args: [Arg("text", "string", "what you want, in words, or one of its templates filled in", required: true, aliases: "words message said sentence q query")],
             aliases: "talk ask speak tell chat converse", tags: "talk words plain text sentence template conversation", uses: "POST /api/say") { f in
            Call(method: "POST", path: "/api/say", body: ["text": try need(f, "text", "say takes text: what you want, in words.")])
        },
        Tool("run_script", "Runs one of the person's scripts by its name (find says what each does and takes): a card goes up on the Mac and waits for them to click Run, then it gives back what the script printed (or that they didn't click Run).",
             args: [Arg("script", "string", "its name, as find or the list gives it (utilities/weather.py)", required: true, aliases: "name file"),
                    Arg("args", "list", "one string per input it takes, in order", aliases: "arguments argv inputs"),
                    Arg("stdin", "string", "for an input it reads as text", aliases: "input"),
                    Arg("why", "string", "why the person wants it, in their words: shown on the card", aliases: "reason")],
             asks: true, stream: true, endpoint: .run, aliases: "run script execute run_tool use_tool call_script run_command",
             tags: "script run execute program shell", uses: "POST /api/run") { f in
            let script = try need(f, "script", "run_script takes script: the script's name (find gives it).")
            var b: [String: Any] = ["script": script]
            if let a = strings(f.values["args"]) { b["args"] = a }
            if let stdin = f.text("stdin") { b["stdin"] = stdin }
            return Call(method: "POST", path: "/api/run", body: b)
        },
        Tool("run_flow", "Runs one of the person's flows (their scripts put together) by its name: a card waits for them to click Run on the Mac, then it gives back how it went.",
             args: [Arg("flow", "string", "its name", required: true, aliases: "name"), Arg("args", "list", "its inputs, in order", aliases: "arguments inputs"),
                    Arg("why", "string", "shown on the card", aliases: "reason")],
             asks: true, stream: true, endpoint: .compose, aliases: "flow compose run_composer", tags: "flow composer", uses: "POST /api/compose") { f in
            let flow = try need(f, "flow", "run_flow takes flow: the flow's name (find gives it).")
            var b: [String: Any] = ["flow": flow]
            if let a = strings(f.values["args"]) { b["args"] = a }
            return Call(method: "POST", path: "/api/compose", body: b)
        },
        Tool("run_flow_code", "Runs Flow code you write to chain scripts and functions (run \"utilities/weather.py\" [\"Paris\"] gives what it printed); a card waits for Run on the Mac. check_flow it first; the Flow guide is docs' FLOW-GUIDE.",
             args: [Arg("source", "string", "the Flow code", required: true, aliases: "code flow_code"), Arg("name", "string", "a name for it"),
                    Arg("why", "string", "shown on the card", aliases: "reason")],
             asks: true, stream: true, endpoint: .compose, aliases: "run_code flow_code", tags: "flow code program chain", uses: "POST /api/compose") { f in
            let source = try need(f, "source", "run_flow_code takes source: the Flow code.")
            return Call(method: "POST", path: "/api/compose", body: ["source": source, "name": f.text("name") ?? "Flow code"])
        },
        Tool("check_flow", "Checks Flow code for mistakes without running anything: what it defines, or the mistake's line and fix.",
             args: [Arg("source", "string", "the Flow code", required: true, aliases: "code")],
             endpoint: .compose, aliases: "check_code validate_flow", tags: "check validate lint", uses: "POST /api/check") { f in
            Call(method: "POST", path: "/api/check", body: ["source": try need(f, "source", "check_flow takes source: the Flow code.")])
        },
        Tool("runs", "The runs on the Mac: the latest (list), one in full with what it printed (read), or stopping one still going (stop; one the person started asks them first).",
             args: [Arg("op", "string", "list, read or stop", required: true, aliases: "action"), Arg("id", "string", "the run's id, for read and stop", aliases: "run run_id"),
                    Arg("limit", "integer", "for list (10)")],
             endpoint: .runs, aliases: "list_runs:list read_run:read get_run:read run_status:read stop_run:stop stop:stop cancel_run:stop",
             tags: "run runs output history stop cancel status", uses: "GET /api/runs") { f in
            let op = Tools.op(f, ["latest": "list", "recent": "list", "get": "read", "show": "read", "output": "read", "cancel": "stop", "kill": "stop"],
                              default: f.text("id") == nil ? "list" : "read") ?? "list"
            switch op {
            case "list": return Call(method: "GET", path: "/api/runs" + query([("limit", f.text("limit") ?? "10")]))
            case "read", "stop":
                let id = try need(f, "id", "runs \(op) takes id: the run's id (runs list gives them).")
                return op == "read" ? Call(method: "GET", path: "/api/runs/\(esc(id))") : Call(method: "POST", path: "/api/runs/\(esc(id))/stop", body: [:])
            default: throw HTTPError(status: 400, code: "unknown_op", message: "runs has no op called \(op): list, read or stop.")
            }
        },
        Tool("web_search", "Searches the web from this Mac, at once (no Chrome, nothing to click): each result's title, address and a few words. Then read the one that fits with web_fetch: an answer is in the page, not in the list.",
             args: [Arg("q", "string", "what to search for, as you'd type it into a search engine", required: true, aliases: "query words text question"),
                    Arg("limit", "integer", "how many results (8)")],
             endpoint: .web, aliases: "google search_web websearch web internet_search search_online look_up_online bing duckduckgo search_google",
             tags: "internet online google lookup news price weather fact answer question", uses: "GET /api/web/search") { f in
            Call(method: "GET", path: "/api/web/search" + query([("q", try need(f, "q", "web_search takes q: what to search for.")), ("limit", f.text("limit"))]))
        },
        Tool("web_fetch", "Reads any web address from this Mac, at once (no Chrome): a page's title, its text and its links, or a JSON API's answer. With find (words), the lines that have them, for a long page. Follow a link, or call a JSON API a page or its docs point to, the same way.",
             args: [Arg("url", "string", "the address (https://…), with any ?parameters an API takes", required: true, aliases: "address link page href uri"),
                    Arg("find", "string", "words: only the lines that have them", aliases: "q query look_for search"),
                    Arg("max", "integer", "characters of text at most (8000)", aliases: "limit")],
             endpoint: .web, aliases: "fetch open_url get_url read_url fetch_url http_get curl download read_webpage read_website visit_url browse_url wget get_page",
             tags: "internet online page website site link api json http read download", uses: "GET /api/web/fetch") { f in
            Call(method: "GET", path: "/api/web/fetch" + query([("url", try need(f, "url", "web_fetch takes url: the address (https://…).")), ("find", f.text("find")), ("max", f.text("max"))]))
        },
        Tool("browser", "The person's own Chrome, at once: open a page there in a new tab (it's read back to you), read the page in front of them, find where a thing is on it, and ring it in red to show them. It never clicks or types (straw does): tell them what to click, then read again. To find something out yourself, web_search and web_fetch are quicker.",
             args: [Arg("op", "string", "open, page (its text and links), find, has, highlight, tabs, url or outline", required: true, aliases: "action what"),
                    Arg("url", "string", "for open: the address", aliases: "address link"),
                    Arg("text", "string", "for find, has and highlight: the words on the page", aliases: "q query words label find"),
                    Arg("max", "integer", "for page and open: characters of text at most (8000)")],
             endpoint: .browser, aliases: "chrome chrome_page page web_page read_page:page open_page:open open_in_chrome:open navigate:open goto:open open_tab:open highlight:highlight",
             tags: "chrome browser tab page site guide show open navigate visit ring url address link website", uses: "/api/browser/…") { f in
            let given = Tools.op(f, browserOpAliases)
            let text = f.text("text")
            let op = given ?? (f.text("url") != nil ? "open" : text != nil ? "find" : "url")
            if browserActs.contains(op) || browserActs.contains(String(op.split(separator: "_").first ?? "")) {
                throw HTTPError(status: 400, code: "browser_reads_only",
                                message: "browser can't \(op.replacingOccurrences(of: "_", with: " ")): it opens and reads pages, and rings things. Tell the person what to do on the page (find, then highlight, shows them where), then read it again; or, to do it yourself, straw (it waits for Run on the Mac).")
            }
            switch op {
            case "open":
                let url = try need(f, "url", "browser open takes url: the address to open.")
                return Call(method: "POST", path: "/api/browser/open", body: ["url": url, "max": f.int("max") ?? 8000])
            case "highlight":
                return Call(method: "POST", path: "/api/browser/highlight", body: ["text": try need(f, "text", "browser highlight takes text: the words of the thing to ring.")])
            case "find", "has":
                return Call(method: "GET", path: "/api/browser/\(op)" + query([("text", try need(f, "text", "browser \(op) takes text: the words to look for."))]))
            case "page": return Call(method: "GET", path: "/api/browser/page" + query([("max", String(f.int("max") ?? 8000))]))
            case "tabs", "url", "outline": return Call(method: "GET", path: "/api/browser/\(op)")
            case "status": return Call(method: "GET", path: "/api/browser")
            default: throw HTTPError(status: 400, code: "unknown_op", message: "browser has no op called \(op): \(browserOps.joined(separator: ", ")).")
            }
        },
        Tool("straw", "Drives Chrome by what's on the page, a plain line a step (open example.com / click \"Sign in\" / type \"Search\" \"cats\" / read all css \"h2\"): for clicking, typing and filling in, which browser can't. A card waits for Run on the Mac. Its words: docs' STRAW-GUIDE.",
             args: [Arg("source", "string", "the Straw code, a line a step", aliases: "code steps"), Arg("script", "string", "or a Straw script's name, instead"),
                    Arg("why", "string", "shown on the card", aliases: "reason")],
             asks: true, stream: true, endpoint: .run, aliases: "click type fill automate_browser run_straw straw_run",
             tags: "chrome click type fill press submit form automate drive", uses: "POST /api/straw/run") { f in
            if let script = f.text("script") { return Call(method: "POST", path: "/api/straw/run", body: ["script": script]) }
            return Call(method: "POST", path: "/api/straw/run", body: ["source": try need(f, "source", "straw takes source: the Straw code, a line a step (open example.com).")])
        },
        Tool("library", "The person's notes (Markdown, each known by its name), at once. Ops: read, find (names by words), search (their text), list, recent, append (a line at the end), write (replaces it all), create, rename, copy, delete (to its Trash), restore. Find or read a note before you write to it.",
             args: [Arg("op", "string", "read, find, search, list, recent, append, write, create, rename, copy, delete or restore", required: true, aliases: "action"),
                    Arg("name", "string", "the note's name (no .md)", aliases: "note title file key"),
                    Arg("text", "string", "for write, create and append", aliases: "content body line"),
                    Arg("q", "string", "words, for find and search", aliases: "query words"),
                    Arg("to", "string", "the new name, for rename and copy", aliases: "new_name as")],
             endpoint: .library, aliases: "notes note file_library library_op notebook",
             tags: "note notes list lists shopping todo journal text save keep write", uses: "POST /api/library") { f in
            var b = body(f)
            b["op"] = Tools.op(f, ["get": "read", "open": "read", "add": "append", "save": "write", "replace": "write", "new": "create", "remove": "delete", "undelete": "restore", "ls": "list"])
            return Call(method: "POST", path: "/api/library", body: b)
        },
        Tool("remember", "Keeps something the person told you about their world (who someone is, a birthday or a date, a place, a preference, a plan), in MEMORY and the mind, at once. Only what they said, never a guess.",
             args: [Arg("category", "string", "PEOPLE, ORGANIZATIONS, EVENT-DATES, BIRTHDAYS, LOCATIONS, IDEAS, LEVERAGE, STRATEGIES or OTHERS", required: true, aliases: "file kind type in"),
                    Arg("about", "string", "who or what (\"Ada\", \"the dentist\")", required: true, aliases: "name who what node"),
                    Arg("text", "string", "what they said, briefly", aliases: "fact details note"),
                    Arg("links", "list", "each {\"label\": \"works at\", \"to\": \"Acme\", \"category\": \"ORGANIZATIONS\"}"),
                    Arg("notes", "list", "short notes: \"birthday 03-14\", \"date 2026-11-03 dentist\", \"pref mornings\"")],
             endpoint: .memory, aliases: "memorize memorise save_memory add_memory store save_fact keep remember_this",
             tags: "remember save keep person people birthday date fact preference", uses: "POST /api/memory/remember") { f in
            var b = body(f, ["category", "about", "text", "links", "notes"])
            b["category"] = (f.text("category") ?? "OTHERS").uppercased().replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "_", with: "-")
                .replacingOccurrences(of: "ORGANISATIONS", with: "ORGANIZATIONS")
            if let notes = strings(f.values["notes"]) { b["notes"] = notes }
            if let l = f.values["links"], !(l is [Any]) { b["links"] = [l] }
            return Call(method: "POST", path: "/api/memory/remember", body: b)
        },
        Tool("recall", "What's remembered about a name, at once: its links, notes and dates, and the lines that mention it. Recall before you answer anything about a person, place, organization or date.",
             args: [Arg("name", "string", "as the person says it", required: true, aliases: "about who what q query")],
             endpoint: .memory, aliases: "lookup look_up who_is get_memory search_memory what_do_i_know recall_memory",
             tags: "recall know who what person people birthday", uses: "GET /api/memory/recall") { f in
            Call(method: "GET", path: "/api/memory/recall" + query([("name", try need(f, "name", "recall takes name: who or what to recall."))]))
        },
        Tool("memory", "The rest of MEMORY, at once: what's coming up (upcoming, with days), who or what is filed under a category (members), and its files (read, search, append, write).",
             args: [Arg("op", "string", "upcoming, members, categories, read, search, append or write", required: true, aliases: "action"),
                    Arg("days", "integer", "for upcoming (30)"), Arg("name", "string", "a category or file (PEOPLE…)", aliases: "category file"),
                    Arg("q", "string", "words, for search", aliases: "query"), Arg("text", "string", "for append and write")],
             endpoint: .memory, aliases: "upcoming:upcoming birthdays:upcoming coming_up:upcoming memories",
             tags: "upcoming soon calendar week birthday categories files", uses: "POST /api/memory") { f in
            var b = body(f)
            b["op"] = Tools.op(f, ["coming_up": "upcoming", "soon": "upcoming", "who": "members", "list": "members"])
            return Call(method: "POST", path: "/api/memory", body: b)
        },
        Tool("mind", "What links to what (people, places, things), at once; only ever added to. Ask it (about, find, path, neighbors, query, dates), or add to it (add a link, note a node). Rename and forget only when the person asks.",
             args: [Arg("op", "string", "about, find, path, neighbors, query, dates, add, note, rename or forget", required: true, aliases: "action"),
                    Arg("name", "string", "a node", aliases: "node about"),
                    Arg("q", "string", "words for find; for query, lines in its notation (\"| x - works at | acme\": who works at Acme)", aliases: "query"),
                    Arg("from", "string", "for add and path"), Arg("label", "string", "for add: a short verb (\"works at\")"),
                    Arg("to", "string", "for add, path and rename"), Arg("note", "string", "for note (\"todo call back Friday\")")],
             endpoint: .mind, aliases: "link:add relate:add connect:add mind_add:add mind_query:query graph knowledge",
             tags: "link links relation relationship connect graph node", uses: "POST /api/mind") { f in
            var b = body(f)
            b["op"] = Tools.op(f, ["neighbours": "neighbors", "link": "add", "connect": "add", "who": "query"],
                               default: f.text("from") != nil || f.values["facts"] != nil ? (f.text("label") == nil && f.values["facts"] == nil && f.text("to") != nil ? "path" : "add") : nil)
            if let notes = f.values["notes"] as? String { b["notes"] = [notes] }
            return Call(method: "POST", path: "/api/mind", body: b)
        },
        Tool("show", "Shows the person something in a window in front of everything, with copy buttons, at once: text you write (Markdown), a note or file (shelf and name), or what the mind knows of something. For anything long or to check; then say it in a sentence.",
             args: [Arg("title", "string", "the window's title"), Arg("text", "string", "Markdown", aliases: "content body markdown"),
                    Arg("shelf", "string", "library, memory or system-docs, with name: a file, instead of text"), Arg("name", "string", "with shelf"),
                    Arg("mind", "string", "a node of the mind, instead of text"), Arg("why", "string", "a line on why", aliases: "reason")],
             endpoint: .screen, aliases: "present display show_window window",
             tags: "show display window present screen", uses: "POST /api/present") { f in
            var b = body(f, ["title", "text", "format", "shelf", "name", "mind", "copy"])
            if let t = f.values["text"], !(t is String) { b["text"] = String(decoding: (try? JSONSerialization.data(withJSONObject: t, options: [.prettyPrinted])) ?? Data(), as: UTF8.self) }
            if b["text"] == nil && b["mind"] == nil && b["name"] == nil {
                throw HTTPError(status: 400, code: "missing_argument", message: "show takes text (Markdown), or shelf and name (a file), or mind (a node).")
            }
            return Call(method: "POST", path: "/api/present", body: b)
        },
        Tool("copy", "Puts text on the person's clipboard, to paste, at once. Say that you did.",
             args: [Arg("text", "string", "what to copy", required: true, aliases: "content")],
             endpoint: .screen, aliases: "clipboard copy_to_clipboard paste", tags: "clipboard copy paste", uses: "POST /api/clipboard") { f in
            Call(method: "POST", path: "/api/clipboard", body: body(f, ["text", "shelf", "name", "mind"]))
        },
        Tool("docs", "How Tool Mac Tool Run works, read only, at once: guides (FLOW-GUIDE, STRAW-GUIDE, BROWSER-GUIDE, MEMORY-GUIDE, MIND-GUIDE), RECIPES, prompts. read a doc by its name, search them by words, or list them.",
             args: [Arg("op", "string", "read, search or list", aliases: "action"), Arg("name", "string", "for read: the doc's name (START-HERE first)", aliases: "doc file"),
                    Arg("q", "string", "for search: words", aliases: "query words")],
             endpoint: .systemDocs, aliases: "help guide system_docs read_docs documentation manual",
             tags: "docs help guide how manual flow straw", uses: "/api/system-docs/…") { f in
            let op = Tools.op(f, ["get": "read", "open": "read", "find": "search", "ls": "list"], default: f.text("q") != nil ? "search" : f.text("name") != nil ? "read" : "list") ?? "list"
            switch op {
            case "read": return Call(method: "GET", path: "/api/system-docs/files/\(esc(try need(f, "name", "docs read takes name: the doc's name (docs list gives them).")))?format=text")
            case "search": return Call(method: "GET", path: "/api/system-docs/search" + query([("q", try need(f, "q", "docs search takes q: words."))]))
            case "list": return Call(method: "GET", path: "/api/system-docs/names")
            default: throw HTTPError(status: 400, code: "unknown_op", message: "docs has no op called \(op): read, search or list.")
            }
        },
        Tool("call_api", "Calls any route of Tool Mac Tool Run's API that no tool covers (find with in \"routes\" gives them, with what they take). One that asks on the Mac waits for the click.",
             args: [Arg("method", "string", "GET, POST, PUT or DELETE (GET)"), Arg("path", "string", "the route, {name} filled in, ?query added (/api/straw)", required: true, aliases: "route url endpoint"),
                    Arg("body", "object", "the JSON it takes", aliases: "json data")],
             aliases: "api http request call_route", tags: "route endpoint api http", uses: "any route") { f in
            let method = (f.text("method") ?? "GET").uppercased()
            guard ["GET", "POST", "PUT", "DELETE"].contains(method) else { throw HTTPError(status: 400, code: "bad_request", message: "call_api's method is GET, POST, PUT or DELETE.") }
            var path = try need(f, "path", "call_api takes path: the route (/api/straw).")
            if let u = URL(string: path), u.scheme != nil { path = u.path + (u.query.map { "?" + $0 } ?? "") }
            if !path.hasPrefix("/") { path = "/" + path }
            guard path.hasPrefix("/api"), !path.hasPrefix("/api/tools") else {
                throw HTTPError(status: 400, code: "bad_request", message: "call_api is for the routes under /api/ (a tool is called by its own name).")
            }
            var body = f.values["body"] as? [String: Any]
            if let s = f.values["body"] as? String { body = JSON.object(Data(s.utf8)) }
            return Call(method: method, path: path, body: method == "GET" || method == "DELETE" ? nil : body ?? [:])
        },
    ]

    /// For a model's instructions: how to use the tools well, a line each.
    public static let guide: [String] = [
        "Every tool answers in JSON. An error has \"error\", often \"fix\", and \"tools\": what to call instead. Follow them; never repeat a call unchanged.",
        "Not sure what fits, or what something takes? find it by a few words before you guess, and before ever saying you can't.",
        "To find something out from the web (a fact, a price, opening hours, the weather, the news, how something works): web_search, then web_fetch the result that fits, with find for the lines you need. Pages and their docs often point to a JSON API: web_fetch calls those too, with the parameters they say. Never say what a page says without reading it.",
        "browser is the person's own Chrome: open a page there when they want to see it or use it, read the page in front of them, find where a thing is and highlight it to guide them, a step at a time. It never clicks or types: tell them what to do, or use straw.",
        "run_script, run_flow, run_flow_code and straw put a card on the Mac and wait for the person to click Run: say so when you send one. If they click Don't Run, leave it unless they ask again. Every other tool answers at once.",
        "Notes are library's: find or read one before you write to it. What the person tells you about their world goes to remember; before you answer about a person, place, organization or date, recall it. Only ever write what they said.",
        "Something long (steps, a list, a result to check) is for show; something they'll paste is for copy.",
        "A small model can use say alone: it takes words and answers in words, offers templates to fill when it isn't sure, and follows runs itself.",
    ]

    /// Exchanges that show the tools at work, for the shape of a call (not to copy).
    public static let examples: [[String: Any]] = [
        ["user": "When does the Louvre open on Sunday?",
         "steps": [["call": ["tool": "web_search", "arguments": ["q": "Louvre opening hours"]],
                    "result": "1. Hours, admission and directions | Louvre Museum — https://www.louvre.fr/en/visit/hours-admission"],
                   ["call": ["tool": "web_fetch", "arguments": ["url": "https://www.louvre.fr/en/visit/hours-admission", "find": "Sunday"]],
                    "result": "{\"lines\": [\"Open Monday, Thursday, Saturday and Sunday from 9 am to 6 pm\"], …}"]],
         "answer": "On Sundays the Louvre is open from 9 in the morning to 6 in the evening."],
        ["user": "What's one euro in yen right now?",
         "steps": [["call": ["tool": "web_search", "arguments": ["q": "free exchange rate api json no key"]],
                    "result": "1. Frankfurter: free currency API — https://frankfurter.dev/ …"],
                   ["call": ["tool": "web_fetch", "arguments": ["url": "https://frankfurter.dev/", "find": "latest"]],
                    "result": "{\"lines\": [\"curl -s https://api.frankfurter.dev/v1/latest?base=EUR&symbols=JPY\"], …}"],
                   ["call": ["tool": "web_fetch", "arguments": ["url": "https://api.frankfurter.dev/v1/latest?base=EUR&symbols=JPY"]],
                    "result": "{\"kind\": \"json\", \"json\": {\"base\": \"EUR\", \"date\": \"2026-10-23\", \"rates\": {\"JPY\": 163.2}}, …}"]],
         "answer": "One euro is about 163 yen, at yesterday's rate."],
        ["user": "My sister Ada's birthday is the 14th of March",
         "steps": [["call": ["tool": "remember", "arguments": ["category": "PEOPLE", "about": "Ada", "text": "The person's sister", "notes": ["birthday 03-14"]]],
                    "result": "{\"file\": \"PEOPLE\", \"node\": \"ada\", …}"]],
         "answer": "I'll remember Ada's birthday, the 14th of March."],
        ["user": "Where's the billing page on this site?",
         "steps": [["call": ["tool": "browser", "arguments": ["op": "find", "text": "Billing"]],
                    "result": "{\"lines\": [\"The link “Billing” is inside “Account”, which is closed: open it first.\"], …}"],
                   ["call": ["tool": "browser", "arguments": ["op": "highlight", "text": "Billing"]],
                    "result": "{\"said\": \"It’s inside “Account”, which is closed: that’s ringed in red, to open first.\", …}"]],
         "answer": "It's under Account, which I've ringed in red: open it and Billing is inside."],
    ]

    /// The tool a name means: its own name, another it's called by (with the op that one gives).
    public static func named(_ raw: String) -> (tool: Tool, op: String?)? {
        let n = raw.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
        if let t = all.first(where: { $0.name == n }) { return (t, nil) }
        for t in all {
            for a in t.aliases {
                let parts = a.split(separator: ":").map(String.init)
                if parts[0] == n { return (t, parts.count > 1 ? parts[1] : nil) }
            }
        }
        return nil
    }

    /// The fields a call was given, its arguments under their own names (from the names a model gives them).
    static func normalized(_ given: [String: Any], for tool: Tool) -> [String: Any] {
        var out = given
        for a in tool.args where out[a.name] == nil {
            if let alias = a.aliases.first(where: { out[$0] != nil }) {
                out[a.name] = out[alias]
                out[alias] = nil
            }
        }
        return out
    }
}

extension RunAPI {
    /// Keys a tool call carries for itself, not as an argument.
    static let toolCallKeys: Set<String> = ["arguments", "args_json", "client", "stream", "async", "wait", "next"]

    /// /api/tools and /api/tools/{name}.
    func toolsRoute(_ req: HTTPRequest, path: String, _ s: APISettings) async throws -> HTTPResponse {
        let rest = path.split(separator: "/").map(String.init).dropFirst(2)
        let method = req.method == "HEAD" ? "GET" : req.method
        guard let name = rest.first else {
            guard method == "GET" else { throw HTTPError(status: 405, code: "bad_request", message: "/api/tools takes GET (POST /api/tools/{name} calls one)") }
            let tools = Tools.all.filter { Self.flag(req.query["all"]) || ($0.endpoint.map(s.isOn) ?? true) }
            return JSON.response([
                "ok": true, "version": version, "count": tools.count,
                "about": "Tools for a model: hand the list to it as is. Call one with POST /api/tools/{name} {\"arguments\": {…}, \"client\": \"<your app>\", \"why\": \"…\"}; the answer is the JSON of the route it calls. One with \"stream\": true runs something: send \"stream\": true to follow it live (NDJSON, as POST /api/run). Turned-off tools are left out (?all=true: them too, with \"on\": false).",
                "guide": Tools.guide, "examples": Tools.examples, "tools": tools.map { $0.json(s) },
            ])
        }
        guard rest.count == 1 else { throw HTTPError(status: 404, code: "not_found", message: "no such route: \(req.path) (GET /api/tools lists the tools)") }
        if method == "GET" {
            guard let (tool, _) = Tools.named(name) else { throw await unknownTool(name, req) }
            return JSON.response(tool.json(s))
        }
        guard method == "POST" else { throw HTTPError(status: 405, code: "bad_request", message: "\(path) takes GET (the tool) or POST (a call)") }
        let fields = try self.fields(req)
        var given: [String: Any] = fields["arguments"] as? [String: Any] ?? [:]
        if let s = fields["arguments"] as? String, let o = JSON.object(Data(s.utf8)) { given = o }
        for (k, v) in fields where !Self.toolCallKeys.contains(k) && given[k] == nil { given[k] = v }

        // The tool it means: by its name, another it's called by, or a script's or flow's name.
        var found = Tools.named(name)
        if found == nil, s.isOn(.catalog), let c = await host.catalog() {
            if let item = Self.item(named: name, in: c.scripts) {
                found = (Tools.named("run_script")!.tool, nil)
                given = ["script": item.id, "args": given["args"] ?? given["arguments"] ?? given.filter { $0.key != "why" && $0.value is String }.map(\.value), "why": given["why"] as Any]
            } else if let item = Self.item(named: name, in: c.flows) {
                found = (Tools.named("run_flow")!.tool, nil)
                given["flow"] = item.id
            }
        }
        guard let (tool, impliedOp) = found else { throw await unknownTool(name, req) }
        if let e = tool.endpoint, !s.isOn(e) {
            throw HTTPError(status: 503, code: "endpoint_off", message: "\(tool.name) is turned off in Tool Mac Tool Run (\(e.title)); the person switches it on in its panel")
        }
        given = Tools.normalized(given, for: tool)
        if let impliedOp, given["op"] == nil { given["op"] = impliedOp }
        for a in tool.args where a.required && a.name != "op" {
            if given[a.name] == nil || (given[a.name] as? String)?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                return toolError(tool, HTTPError(status: 400, code: "missing_argument", message: "\(tool.name) takes \(a.name): \(a.about)."))
            }
        }
        let call: Tools.Call
        do {
            call = try tool.build(LibraryAPI.Fields(values: given))
        } catch let e as HTTPError {
            return toolError(tool, e)
        }
        // The route it stands for, asked as the caller asked (who, from where, why, how).
        var body = call.body
        if body != nil {
            for k in ["client", "why", "stream", "async", "wait"] where body?[k] == nil {
                if let v = fields[k] ?? given[k] { body?[k] = v }
            }
            if tool.asks, body?["why"] == nil, let why = RunAPI.text(given["reason"]) { body?["why"] = why }
        }
        var headers = req.headers
        headers["content-type"] = "application/json"
        headers["content-length"] = nil
        var inner = HTTPRequest(method: call.method, target: call.path, headers: headers, body: body.map { JSON.data($0) } ?? Data(),
                                fromLoopback: req.fromLoopback, peer: req.peer)
        inner.query.merge(req.query.filter { ["next"].contains($0.key) }) { a, _ in a }
        var response: HTTPResponse
        do {
            response = try await route(inner, s)
        } catch let e as HTTPError {
            response = JSON.response(["ok": false, "code": e.code, "error": e.message], status: e.status)
        }
        APINext.add(to: &response, for: inner)
        response.headers.append(("X-Tool", tool.name))
        guard let data = response.bodyData, var out = JSON.object(data) else { return response }
        out["tool"] = tool.name
        if response.status >= 400 {
            out["takes"] = tool.takes
            let words = ([tool.name] + given.values.compactMap { RunAPI.text($0) }).joined(separator: " ")
            let suggestions = await toolSuggestions(words, excluding: tool.name)
            if !suggestions.isEmpty, out["tools"] == nil { out["tools"] = suggestions }
        }
        response.body = .data(JSON.data(out))
        return response
    }

    /// A refusal before the route was asked, as a tool's answer: what it takes, and what else fits.
    private func toolError(_ tool: Tools.Tool, _ e: HTTPError) -> HTTPResponse {
        JSON.response(["ok": false, "tool": tool.name, "code": e.code, "error": e.message, "takes": tool.takes], status: e.status, headers: [("X-Tool", tool.name)])
    }

    private func unknownTool(_ name: String, _ req: HTTPRequest) async -> HTTPError {
        let suggestions = await toolSuggestions(name.replacingOccurrences(of: "_", with: " "), excluding: nil)
        var message = "there's no tool called \(name). The tools: \(Tools.all.map(\.name).joined(separator: ", "))."
        if !suggestions.isEmpty { message += " For \"\(name)\": " + suggestions.prefix(3).joined(separator: "; ") }
        return HTTPError(status: 404, code: "unknown_tool", message: message)
    }

    /// What fits some words: a line each, the tools first (and the scripts and flows).
    func toolSuggestions(_ words: String, excluding: String?) async -> [String] {
        let s = settingsNow()
        let catalog = s.isOn(.catalog) ? await host.catalog() : nil
        let (hits, _) = APISearch.search(words, scopes: [.tools, .scripts, .flows], catalog: catalog, settings: s, limit: 6)
        return hits.filter { $0.json["name"] as? String != excluding }.prefix(4).map(Self.line)
    }

    /// A script or flow by the name a model gives it: as listed, without its extension, or by its last part.
    static func item(named raw: String, in items: [ScriptItem]) -> ScriptItem? {
        let bare = { (s: String) in s.lowercased().replacingOccurrences(of: #"\.[a-z0-9]+$"#, with: "", options: .regularExpression) }
        let n = bare(raw)
        return items.first { $0.id.lowercased() == raw.lowercased() } ?? items.first { bare($0.id) == n }
            ?? items.first { bare(String($0.id.split(separator: "/").last ?? "")) == bare(String(raw.split(separator: "/").last ?? "")) }
    }

    /// A search hit in a line a model reads: "tool web_fetch: Reads … | takes: url (string): …".
    static func line(_ h: APISearch.Hit) -> String {
        let j = h.json
        switch h.kind {
        case "tool":
            return "tool \(j["name"] as? String ?? ""): \(j["description"] as? String ?? "") | takes: \(j["takes"] as? String ?? "nothing")"
        case "script", "flow":
            var l = "\(h.kind) \(j["name"] as? String ?? ""): \(j["summary"] as? String ?? "")"
            let inputs = (j["inputs"] as? [[String: Any]] ?? []).map { "\($0["kind"] as? String == "stdin" ? "stdin " : "")\($0["prompt"] as? String ?? "")\($0["optional"] as? Bool == true ? " (optional)" : "")" }
            if !inputs.isEmpty { l += " | takes: " + inputs.joined(separator: "; ") }
            if let d = j["dangers"] as? [String], !d.isEmpty { l += " | can't be undone: " + d.joined(separator: ", ") }
            return l + " | \(h.kind == "script" ? "run_script" : "run_flow") runs it (it waits for Run on the Mac)"
        default:
            return "route \(j["method"] as? String ?? "") \(j["path"] as? String ?? ""): \(j["summary"] as? String ?? "")\(j["asks_on_the_mac"] as? Bool == true ? " [asks on the Mac]" : "") | call_api calls it"
        }
    }
}
