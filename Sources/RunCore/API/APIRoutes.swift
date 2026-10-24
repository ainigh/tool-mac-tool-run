import Foundation

/// Every route the HTTP API answers, in its groups: what `GET /api/endpoints` (and `GET /api`)
/// lists, what the doc's list of endpoints is made of, and what a route that isn't one points to.
/// One table, so the list and the routes can't drift apart (a test calls each one).
public enum APIRoutes {
    public struct Route: Sendable {
        public let method: String
        public let path: String
        public let summary: String
        /// It waits for a click on the Mac (Run, Allow, Stop It) before it does anything.
        public let asks: Bool

        init(_ method: String, _ path: String, _ summary: String, asks: Bool = false) {
            self.method = method
            self.path = path
            self.summary = summary
            self.asks = asks
        }
    }

    public struct Group: Sendable {
        public let id: String
        public let title: String
        public let about: String
        /// The switch in the app that turns it off (nil: it's always on).
        public let endpoint: APIEndpoint?
        public let routes: [Route]
    }

    public static let groups: [Group] = [
        Group(id: "about", title: "About the API", about: "What's here, whether it's up, and the doc", endpoint: nil, routes: [
            Route("GET", "/api/endpoints", "every route, in its groups (this list; GET /api too; ?group=library for one group)"),
            Route("GET", "/api/health", "is it up, which groups are on, the folder, how many scripts, flows and notes"),
            Route("GET", "/api/doc", "the whole API in one page (text/markdown), with this server's address"),
            Route("GET", "/", "a status page in a browser, with a place to try a script or Flow code"),
        ]),
        Group(id: "scripts", title: "Scripts and flows", about: "The scripts and flows in the folder, and running them", endpoint: nil, routes: [
            Route("GET", "/api/scripts", "the scripts (?group=scripts, utilities or browser: one grid's)"),
            Route("GET", "/api/flows", "the flows"),
            Route("POST", "/api/run", "run a script {\"script\", \"args\"?, \"stdin\"?, \"why\"?, \"wait\"?, \"async\"?, \"stream\"?}", asks: true),
            Route("POST", "/api/compose", "run a flow {\"flow\"}, or Flow code {\"source\"}", asks: true),
            Route("POST", "/api/check", "check Flow code without running it {\"source\"}"),
        ]),
        Group(id: "straw", title: "Straw: Chrome by what's on the page", about: "Straw's words and scripts, checking Straw code, and running it in Chrome", endpoint: nil, routes: [
            Route("GET", "/api/straw", "Straw's words (what each takes and does, with an example) and the Straw scripts in the folder"),
            Route("POST", "/api/straw/check", "check Straw code without running it {\"source\"}: what it would do, or its mistake, line and fix"),
            Route("POST", "/api/straw/run", "run a Straw script {\"script\"}, or Straw code you send {\"source\", \"name\"?}, in Chrome", asks: true),
        ]),
        Group(id: "library", title: "File library", about: "The notes in LIBRARY (in TOOL-MAC-RUN on the Desktop), by name (no extension): answered at once, without asking on the Mac",
              endpoint: .library, routes: [
            Route("GET", "/api/library", "where it is, how many notes, and every operation with what it takes"),
            Route("POST", "/api/library", "any operation, by name: {\"op\": \"read\", \"name\": \"groceries\"} (list, read, write, create, append, rename, copy, delete, search, find…)"),
            Route("GET", "/api/library/files", "every note (?sort=name|modified|created|size, ?order, ?q=words in the name, ?limit, ?offset, ?content=true)"),
            Route("POST", "/api/library/files", "a new note {\"name\", \"text\"?}; 409 if the name is taken"),
            Route("GET", "/api/library/files/{name}", "a note's text and details (?format=text: the text alone, as Markdown)"),
            Route("PUT", "/api/library/files/{name}", "write it: created, or its text replaced {\"text\"} (or the text itself, as text/plain); \"new\" says which"),
            Route("DELETE", "/api/library/files/{name}", "move it to the library's Trash, as name (1), name (2)…"),
            Route("POST", "/api/library/files/{name}/append", "add text at its end {\"text\"} (created if it isn't there)"),
            Route("POST", "/api/library/files/{name}/rename", "another name {\"to\", \"overwrite\"?}"),
            Route("POST", "/api/library/files/{name}/copy", "a copy under another name {\"to\"}"),
            Route("GET", "/api/library/files/{name}/exists", "whether it's there"),
            Route("GET", "/api/library/files/{name}/outline", "its headings"),
            Route("GET", "/api/library/files/{name}/backlinks", "the notes that link to it"),
            Route("GET", "/api/library/names", "the names alone"),
            Route("GET", "/api/library/search", "full text: ?q=words (a \"phrase\" in quotes), ?match=all|any, ?case_sensitive, ?whole_words, ?lines, ?limit"),
            Route("GET", "/api/library/find", "the same search, only the names, the best first"),
            Route("GET", "/api/library/recent", "the latest changed (?limit)"),
            Route("GET", "/api/library/stats", "how many notes, bytes, words, in the Trash"),
            Route("GET", "/api/library/trash", "what's in the library's Trash"),
            Route("POST", "/api/library/trash/restore", "bring one back {\"name\", \"number\"?, \"as\"?}"),
            Route("POST", "/api/library/trash/empty", "delete what's in the library's Trash for good {\"older_than_days\"?}"),
            Route("GET", "/api/library/operations", "the latest library operations, each with its id (?limit)"),
            Route("GET", "/api/library/operations/{id}", "one operation: what it was, who asked, how it went"),
        ]),
        Group(id: "memory", title: "Memory", about: "What's remembered, in MEMORY (in TOOL-MAC-RUN on the Desktop): a file for each kind of thing (PEOPLE, ORGANIZATIONS, EVENT-DATES, BIRTHDAYS, LOCATIONS, IDEAS, LEVERAGE, STRATEGIES, OTHERS), each a node of the mind. Every library route works here too (/api/memory/files/…); answered at once",
              endpoint: .memory, routes: [
            Route("GET", "/api/memory", "where it is, its files, and every operation (the library's, and memory's own) with what it takes"),
            Route("POST", "/api/memory", "any operation, by name: {\"op\": \"remember\", …} (list, read, write, append, search, remember, recall, upcoming…)"),
            Route("GET", "/api/memory/files", "every file (as /api/library/files)"),
            Route("GET", "/api/memory/files/{name}", "a file's text (?format=text: the text alone)"),
            Route("PUT", "/api/memory/files/{name}", "write a file (it becomes a node of the mind)"),
            Route("POST", "/api/memory/files/{name}/append", "add text at its end {\"text\"}"),
            Route("DELETE", "/api/memory/files/{name}", "move it to MEMORY's Trash (its node stays in the mind)"),
            Route("GET", "/api/memory/search", "full text: ?q=words"),
            Route("POST", "/api/memory/remember", "remember something {\"category\": \"PEOPLE\", \"about\": \"Ada Lovelace\", \"text\"?, \"links\"?: [{\"label\", \"to\", \"category\"?}], \"notes\"?}: a line in the file, and links in the mind"),
            Route("GET", "/api/memory/recall", "what's known about a name: ?name=Ada (its node, its links and notes, the files it's under, the lines that mention it)"),
            Route("GET", "/api/memory/categories", "every file, and how many things the mind files under it"),
            Route("GET", "/api/memory/categories/{name}/members", "what the mind files under one (PEOPLE: the people)"),
            Route("GET", "/api/memory/upcoming", "the days coming up (?days=30): dated notes in the mind, dated lines in the files"),
            Route("POST", "/api/memory/sync", "make each file a node of the mind"),
            Route("POST", "/api/memory/defaults", "put back any of the files MEMORY comes with"),
            Route("GET", "/api/memory/operations", "the latest memory operations, each with its id"),
        ]),
        Group(id: "mind", title: "The mind", about: "What's linked to what, in the text mind-map notation (MIND/mind.txt in TOOL-MAC-RUN): ask it in plain fields or in its query lines, add to it in plain fields or in the notation. Append only; answered at once",
              endpoint: .mind, routes: [
            Route("GET", "/api/mind", "how big it is, the scope it's in, and every operation with what it takes"),
            Route("POST", "/api/mind", "any operation, by name: {\"op\": \"about\", \"name\": \"ada\"}"),
            Route("GET", "/api/mind/stats", "how many nodes, edges, scopes, lines, problems"),
            Route("GET", "/api/mind/nodes", "every node (?scope, ?q, ?memory=true)"),
            Route("GET", "/api/mind/nodes/{name}", "a node: its notes and links (looked up as a person means it: case, plurals, near spellings)"),
            Route("GET", "/api/mind/nodes/{name}/neighbors", "the nodes around it (?depth=1, ?direction=out|in|both)"),
            Route("GET", "/api/mind/path", "the way from one node to another: ?from=…&to=…"),
            Route("GET", "/api/mind/find", "nodes by words in their names, notes, links' labels: ?q=…"),
            Route("GET", "/api/mind/edges", "every edge (?label=works at)"),
            Route("GET", "/api/mind/notes", "the notes of a kind: ?kind=date"),
            Route("GET", "/api/mind/dates", "the days coming up in its notes (?days=30)"),
            Route("POST", "/api/mind/query", "the notation's own queries {\"q\": \"| sam | x\"} (a name not in the mind is a variable)"),
            Route("POST", "/api/mind/context", "the part of the mind some text touches {\"text\"}: lines to give a model"),
            Route("POST", "/api/mind/prompt", "the notation's prompt for a model, filled in {\"messages\"}, with its grammar"),
            Route("GET", "/api/mind/scopes", "the scopes"),
            Route("GET", "/api/mind/graph", "everything, as JSON (?scope)"),
            Route("GET", "/api/mind/layout", "where each node goes in a picture"),
            Route("GET", "/api/mind/log", "the log, as written (text/plain)"),
            Route("GET", "/api/mind/canonical", "the mind in its shortest form (text/plain)"),
            Route("GET", "/api/mind/problems", "lines of the log that couldn't be read, with their fixes"),
            Route("POST", "/api/mind/check", "what lines would add, without adding {\"lines\"} or {\"text\"}"),
            Route("POST", "/api/mind/add", "add facts in plain fields {\"from\", \"to\"?, \"label\"?, \"notes\"?} or {\"facts\": [...]}"),
            Route("POST", "/api/mind/append", "append lines of the notation {\"lines\": [...]} or a model's reply {\"text\"}; a mistake adds nothing"),
            Route("POST", "/api/mind/note", "a note on a node {\"name\", \"note\": \"date 2026-11-03\"}"),
            Route("POST", "/api/mind/rename", "the node is called something else from here on {\"name\", \"to\"}"),
            Route("POST", "/api/mind/forget", "the node and its edges are gone from the mind (the log keeps its history) {\"name\"}"),
            Route("POST", "/api/mind/comment", "a comment line {\"text\"}"),
            Route("POST", "/api/mind/compact", "the log rewritten in its shortest form (the old one archived)"),
            Route("GET", "/api/mind/operations", "the latest mind operations, each with its id"),
        ]),
        Group(id: "system-docs", title: "System docs", about: "How this app works, for people and for models: guides, the API, prompts, recipes and example exchanges, in SYSTEM-DOCS (in TOOL-MAC-RUN). Read only",
              endpoint: .systemDocs, routes: [
            Route("GET", "/api/system-docs", "where they are, and the operations (the library's that read)"),
            Route("POST", "/api/system-docs", "any reading operation, by name: {\"op\": \"search\", \"q\": \"remember\"}"),
            Route("GET", "/api/system-docs/files", "every doc"),
            Route("GET", "/api/system-docs/files/{name}", "a doc (START-HERE first; ?format=text: the text alone)"),
            Route("GET", "/api/system-docs/files/{name}/outline", "a doc's headings"),
            Route("GET", "/api/system-docs/search", "full text: ?q=words"),
            Route("GET", "/api/system-docs/names", "the docs' names"),
        ]),
        Group(id: "screen", title: "Show and copy", about: "Show the person something in a window in front of everything, with copy buttons; put text on their clipboard. (\"present\": true and \"copy\": true do the same on any answer.)",
              endpoint: .screen, routes: [
            Route("GET", "/api/present", "what it takes"),
            Route("POST", "/api/present", "show a file {\"shelf\", \"name\"}, a node {\"mind\": \"ada\"}, or text {\"title\", \"text\", \"format\"?}"),
            Route("GET", "/api/clipboard", "what it takes"),
            Route("POST", "/api/clipboard", "copy {\"text\"}, a file {\"shelf\", \"name\"}, or a node {\"mind\"}"),
        ]),
        Group(id: "browser", title: "Chrome's page", about: "The page in front of Chrome, to guide the person through a site: what's open, what it says, whether words are on it, where a thing is, and a ring to show them. Reads only; never clicks or types",
              endpoint: .browser, routes: RunAPI.browserRoutes.map { Route($0.method, $0.path, $0.summary) }),
        Group(id: "automation", title: "Automation", about: "Scripts and flows that run by themselves", endpoint: nil, routes: [
            Route("GET", "/api/automation", "the tags there are, and what runs by itself"),
            Route("POST", "/api/automation", "tag a script or a flow to run by itself {\"script\"|\"flow\", \"automation\": [tags]}", asks: true),
        ]),
        Group(id: "runs", title: "Runs and requests", about: "Every request's id, the runs, what they printed, and stopping one", endpoint: .runs, routes: [
            Route("GET", "/api/requests/{id}", "where a request is, from the moment it arrived (a library operation's id too)"),
            Route("GET", "/api/requests", "the latest requests (?limit)"),
            Route("GET", "/api/runs", "the latest runs, without their output (?limit)"),
            Route("GET", "/api/runs/{id}", "one run, with everything it printed (and a flow's steps)"),
            Route("POST", "/api/runs/{id}/stop", "stop it (one the person started waits for Stop It on the Mac)", asks: true),
        ]),
    ]

    /// Every route, in order.
    public static var all: [Route] { groups.flatMap(\.routes) }

    static func json(_ g: Group, settings: APISettings) -> [String: Any] {
        var out: [String: Any] = [
            "id": g.id, "title": g.title, "about": g.about,
            "routes": g.routes.map { ["method": $0.method, "path": $0.path, "summary": $0.summary, "asks_on_the_mac": $0.asks] },
        ]
        if let e = g.endpoint {
            out["switch"] = e.rawValue
            out["on"] = settings.isOn(e)
        }
        return out
    }

    /// The routes as the doc lists them: a heading for each group, then a line for each route.
    public static var text: String {
        groups.map { g in
            // The summaries line up: after the longest method and path, and two spaces.
            let width = 7 + (g.routes.map(\.path.count).max() ?? 20) + 2
            let lines = g.routes.map { r in
                let head = r.method.padding(toLength: 7, withPad: " ", startingAt: 0) + r.path
                return head.padding(toLength: width, withPad: " ", startingAt: 0) + r.summary + (r.asks ? "   [asks on the Mac]" : "")
            }
            return "### \(g.title)\n\(g.about).\n\n" + lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}
