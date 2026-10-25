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
        /// Words it's found by (`GET /api/search`) beyond its path and summary: what someone
        /// looking for it would say ("note", "remember", "job", "status"). One written `!open`
        /// is a word it's *not* for: a search that has it puts the route lower (Chrome's page
        /// only reads, so "open a page" isn't it).
        public let tags: [String]

        init(_ method: String, _ path: String, _ summary: String, asks: Bool = false, tags: String = "") {
            self.method = method
            self.path = path
            self.summary = summary
            self.asks = asks
            self.tags = tags.split(separator: " ").map(String.init)
        }

        /// "GET /api/health"
        public var key: String { method + " " + path }
    }

    public struct Group: Sendable {
        public let id: String
        public let title: String
        public let about: String
        /// The switch in the app that turns it off (nil: it's always on).
        public let endpoint: APIEndpoint?
        /// Words every route in it is found by, too.
        public let tags: [String]
        public let routes: [Route]

        init(id: String, title: String, about: String, endpoint: APIEndpoint?, tags: String = "", routes: [Route]) {
            self.id = id
            self.title = title
            self.about = about
            self.endpoint = endpoint
            self.tags = tags.split(separator: " ").map(String.init)
            self.routes = routes
        }
    }

    public static let groups: [Group] = [
        Group(id: "about", title: "About the API", about: "What's here, whether it's up, and the doc", endpoint: nil, tags: "api discover discovery help start begin overview list index routes endpoints search find what how", routes: [
            Route("GET", "/api/search", "only the routes, scripts and flows that match some words: ?q=remember a birthday (?in=routes,scripts,flows, ?group=memory, ?limit=10). Start here", tags: "search find lookup discover which how query match keyword small"),
            Route("GET", "/api/endpoints", "every route, in its groups (this list; GET /api too; ?group=library for one group; ?brief=true: the groups alone)", tags: "all every list routes groups catalog"),
            Route("GET", "/api/health", "is it up, which groups are on, the folder, how many scripts, flows and notes", tags: "health up alive ping status version check ok server running"),
            Route("GET", "/api/doc", "the whole API in one page (text/markdown), with this server's address", tags: "doc documentation reference contract markdown whole"),
            Route("GET", "/", "a status page in a browser, with a place to try a script or Flow code", tags: "html home try status"),
        ]),
        Group(id: "say", title: "Say: plain words", about: "One way in, for any client and a small model most of all: say what you want as text, and get plain words back (no routes, ids, polling or JSON). What isn't one of its templates yet is answered with the templates that would do it ({…} a blank to fill, [a | b] a choice of one); one said back filled in is done at once, or put to the person at the Mac (a run waits for Run). It follows each request itself, and every answer starts with what changed",
              endpoint: nil, tags: "say talk speak words plain text natural language sentence chat conversation template templates form forms adapter small model llm assistant", routes: [
            Route("POST", "/api/say", "say what you want, as text (text/plain, or {\"text\"}); the answer is plain text. ?client= (or X-Client) says who's talking: each client has its own log. X-Reply-To (an address on this Mac): how a run went is POSTed there the moment it's over", tags: "say talk ask tell words sentence chat message reply callback webhook notify push"),
            Route("GET", "/api/say", "how to use it, as text: the one line a model's instructions need, and the sentences that are always there", tags: "how help instructions usage"),
            Route("GET", "/api/say/forms", "every template it offers (?q=words: the ones that fit; ?format=json: as JSON, each with its lines)", tags: "templates forms list grammar sentences"),
            Route("GET", "/api/say/log", "what this client asked for, and how each went (JSON, the newest first)", tags: "log history asked requests conversation"),
            Route("POST", "/api/say/stop", "call off one of this client's requests by its number in the log {\"number\": 3}: taken back while it waits, stopped while it runs", tags: "stop cancel withdraw take back abort number"),
            Route("POST", "/api/say/reset", "start over: the numbers and anything pending forgotten ({\"forget\": true}: what was asked too)", tags: "reset start over forget clear new"),
            Route("POST", "/api/say/translate", "the translator alone, stateless {\"text\", \"dry\"?, \"model\"?…}: the prompt the model saw, what it answered, and which templates came of it (for trying models: BENCH.md)", tags: "translate translator model llm bench benchmark prompt natural language understand interpret"),
            Route("GET", "/api/say/translator", "the translator's settings (the model, its address, how sure it must be) and its latest calls", tags: "translator model llm settings ollama anthropic openai"),
            Route("POST", "/api/say/translator", "change the translator's settings, from this Mac {\"api\": \"openai\" | \"anthropic\", \"url\", \"model\", \"key\", \"sure\", \"on\"}", tags: "translator model llm settings configure ollama anthropic openai key"),
        ]),
        Group(id: "scripts", title: "Scripts and flows", about: "The scripts and flows in the folder, and running them", endpoint: nil, tags: "script flow run execute program shell bash python node command tool job task", routes: [
            Route("GET", "/api/scripts", "the scripts (?group=scripts, utilities or browser: one grid's)", tags: "scripts list available utilities tools what"),
            Route("GET", "/api/flows", "the flows", tags: "flows list available composer"),
            Route("POST", "/api/run", "run a script {\"script\", \"args\"?, \"stdin\"?, \"why\"?, \"wait\"?, \"async\"?, \"stream\"?}", asks: true, tags: "run execute start launch script async stream wait"),
            Route("POST", "/api/compose", "run a flow {\"flow\"}, or Flow code {\"source\"}", asks: true, tags: "run execute flow code source compose"),
            Route("POST", "/api/check", "check Flow code without running it {\"source\"}", tags: "check validate lint flow code compile type"),
        ]),
        Group(id: "straw", title: "Straw: Chrome by what's on the page", about: "Straw's words and scripts, checking Straw code, and running it in Chrome", endpoint: nil, tags: "straw chrome browser automate web page click type drive site", routes: [
            Route("GET", "/api/straw", "Straw's words (what each takes and does, with an example) and the Straw scripts in the folder", tags: "words vocabulary list scripts"),
            Route("POST", "/api/straw/check", "check Straw code without running it {\"source\"}: what it would do, or its mistake, line and fix", tags: "check validate plan"),
            Route("POST", "/api/straw/run", "run a Straw script {\"script\"}, or Straw code you send {\"source\", \"name\"?}, in Chrome: it opens pages, goes to addresses, clicks and types (open example.com, click \"More\")", asks: true, tags: "run execute click type fill press submit form login automate drive steps"),
        ]),
        Group(id: "library", title: "File library", about: "The notes in LIBRARY (in TOOL-MAC-RUN on the Desktop), by name (no extension): answered at once, without asking on the Mac",
              endpoint: .library, tags: "library note notes file files text markdown document doc key value store save", routes: [
            Route("GET", "/api/library", "where it is, how many notes, and every operation with what it takes", tags: "operations ops info where"),
            Route("POST", "/api/library", "any operation, by name: {\"op\": \"read\", \"name\": \"groceries\"} (list, read, write, create, append, rename, copy, delete, search, find…)", tags: "op operation any do"),
            Route("GET", "/api/library/files", "every note (?sort=name|modified|created|size, ?order, ?q=words in the name, ?limit, ?offset, ?content=true)", tags: "list all sort browse"),
            Route("POST", "/api/library/files", "a new note {\"name\", \"text\"?}; 409 if the name is taken", tags: "create new add make"),
            Route("GET", "/api/library/files/{name}", "a note's text and details (?format=text: the text alone, as Markdown)", tags: "read open get view content"),
            Route("PUT", "/api/library/files/{name}", "write it: created, or its text replaced {\"text\"} (or the text itself, as text/plain); \"new\" says which", tags: "write replace update save edit set"),
            Route("DELETE", "/api/library/files/{name}", "move it to the library's Trash, as name (1), name (2)…", tags: "delete remove trash"),
            Route("POST", "/api/library/files/{name}/append", "add text at its end {\"text\"} (created if it isn't there)", tags: "append add line log journal"),
            Route("POST", "/api/library/files/{name}/rename", "another name {\"to\", \"overwrite\"?}", tags: "rename move name"),
            Route("POST", "/api/library/files/{name}/copy", "a copy under another name {\"to\"}", tags: "copy duplicate"),
            Route("GET", "/api/library/files/{name}/exists", "whether it's there", tags: "exists there check"),
            Route("GET", "/api/library/files/{name}/outline", "its headings", tags: "outline headings toc structure"),
            Route("GET", "/api/library/files/{name}/backlinks", "the notes that link to it", tags: "backlinks links wiki"),
            Route("GET", "/api/library/names", "the names alone", tags: "names list"),
            Route("GET", "/api/library/search", "full text: ?q=words (a \"phrase\" in quotes), ?match=all|any, ?case_sensitive, ?whole_words, ?lines, ?limit", tags: "search find full text grep query look"),
            Route("GET", "/api/library/find", "the same search, only the names, the best first", tags: "find search names"),
            Route("GET", "/api/library/recent", "the latest changed (?limit)", tags: "recent latest changed new"),
            Route("GET", "/api/library/stats", "how many notes, bytes, words, in the Trash", tags: "stats count size words"),
            Route("GET", "/api/library/trash", "what's in the library's Trash", tags: "trash deleted bin"),
            Route("POST", "/api/library/trash/restore", "bring one back {\"name\", \"number\"?, \"as\"?}", tags: "restore undelete undo trash"),
            Route("POST", "/api/library/trash/empty", "delete what's in the library's Trash for good {\"older_than_days\"?}", tags: "empty trash purge"),
            Route("GET", "/api/library/operations", "the latest library operations, each with its id (?limit)", tags: "operations history log audit"),
            Route("GET", "/api/library/operations/{id}", "one operation: what it was, who asked, how it went", tags: "operation id history"),
        ]),
        Group(id: "memory", title: "Memory", about: "What's remembered, in MEMORY (in TOOL-MAC-RUN on the Desktop): a file for each kind of thing (PEOPLE, ORGANIZATIONS, EVENT-DATES, BIRTHDAYS, LOCATIONS, IDEAS, LEVERAGE, STRATEGIES, OTHERS), each a node of the mind. Every library route works here too (/api/memory/files/…); answered at once",
              endpoint: .memory, tags: "memory remember recall person people contact birthday date event organization place idea fact know", routes: [
            Route("GET", "/api/memory", "where it is, its files, and every operation (the library's, and memory's own) with what it takes", tags: "operations info files"),
            Route("POST", "/api/memory", "any operation, by name: {\"op\": \"remember\", …} (list, read, write, append, search, remember, recall, upcoming…)", tags: "op operation any"),
            Route("GET", "/api/memory/files", "every file (as /api/library/files)", tags: "files list categories"),
            Route("GET", "/api/memory/files/{name}", "a file's text (?format=text: the text alone)", tags: "read file"),
            Route("PUT", "/api/memory/files/{name}", "write a file (it becomes a node of the mind)", tags: "write replace"),
            Route("POST", "/api/memory/files/{name}/append", "add text at its end {\"text\"}", tags: "append add line"),
            Route("DELETE", "/api/memory/files/{name}", "move it to MEMORY's Trash (its node stays in the mind)", tags: "delete remove trash"),
            Route("GET", "/api/memory/search", "full text: ?q=words", tags: "search find text"),
            Route("POST", "/api/memory/remember", "remember something {\"category\": \"PEOPLE\", \"about\": \"Ada Lovelace\", \"text\"?, \"links\"?: [{\"label\", \"to\", \"category\"?}], \"notes\"?}: a line in the file, and links in the mind", tags: "remember save store keep note add person birthday fact tell"),
            Route("GET", "/api/memory/recall", "what's known about a name: ?name=Ada (its node, its links and notes, the files it's under, the lines that mention it)", tags: "recall lookup look know about who what"),
            Route("GET", "/api/memory/categories", "every file, and how many things the mind files under it", tags: "categories kinds files"),
            Route("GET", "/api/memory/categories/{name}/members", "what the mind files under one (PEOPLE: the people)", tags: "members list people who"),
            Route("GET", "/api/memory/upcoming", "the days coming up (?days=30): dated notes in the mind, dated lines in the files", tags: "upcoming soon next coming week month today calendar birthday date event reminder agenda"),
            Route("POST", "/api/memory/sync", "make each file a node of the mind", tags: "sync nodes"),
            Route("POST", "/api/memory/defaults", "put back any of the files MEMORY comes with", tags: "defaults restore files"),
            Route("GET", "/api/memory/operations", "the latest memory operations, each with its id", tags: "operations history log"),
        ]),
        Group(id: "mind", title: "The mind", about: "What's linked to what, in the text mind-map notation (MIND/mind.txt in TOOL-MAC-RUN): ask it in plain fields or in its query lines, add to it in plain fields or in the notation. Append only; answered at once",
              endpoint: .mind, tags: "mind graph link links relation relationship node edge knowledge map connect fact", routes: [
            Route("GET", "/api/mind", "how big it is, the scope it's in, and every operation with what it takes", tags: "operations info size"),
            Route("POST", "/api/mind", "any operation, by name: {\"op\": \"about\", \"name\": \"ada\"}", tags: "op operation any"),
            Route("GET", "/api/mind/stats", "how many nodes, edges, scopes, lines, problems", tags: "stats count size"),
            Route("GET", "/api/mind/nodes", "every node (?scope, ?q, ?memory=true)", tags: "nodes list things"),
            Route("GET", "/api/mind/nodes/{name}", "a node: its notes and links (looked up as a person means it: case, plurals, near spellings)", tags: "node about thing person read"),
            Route("GET", "/api/mind/nodes/{name}/neighbors", "the nodes around it (?depth=1, ?direction=out|in|both)", tags: "neighbors around related nearby"),
            Route("GET", "/api/mind/path", "the way from one node to another: ?from=…&to=…", tags: "path between connected route how"),
            Route("GET", "/api/mind/find", "nodes by words in their names, notes, links' labels: ?q=…", tags: "find search lookup"),
            Route("GET", "/api/mind/edges", "every edge (?label=works at)", tags: "edges links relations label"),
            Route("GET", "/api/mind/notes", "the notes of a kind: ?kind=date", tags: "notes kind todo date"),
            Route("GET", "/api/mind/dates", "the days coming up in its notes (?days=30)", tags: "dates upcoming calendar"),
            Route("POST", "/api/mind/query", "the notation's own queries {\"q\": \"| sam | x\"} (a name not in the mind is a variable)", tags: "query ask pattern notation variable who works where relationship"),
            Route("POST", "/api/mind/context", "the part of the mind some text touches {\"text\"}: lines to give a model", tags: "context conversation chat model llm"),
            Route("POST", "/api/mind/prompt", "the notation's prompt for a model, filled in {\"messages\"}, with its grammar", tags: "prompt model llm grammar"),
            Route("GET", "/api/mind/scopes", "the scopes", tags: "scopes"),
            Route("GET", "/api/mind/graph", "everything, as JSON (?scope)", tags: "graph json everything export"),
            Route("GET", "/api/mind/layout", "where each node goes in a picture", tags: "layout picture positions"),
            Route("GET", "/api/mind/log", "the log, as written (text/plain)", tags: "log text raw"),
            Route("GET", "/api/mind/canonical", "the mind in its shortest form (text/plain)", tags: "canonical short compact text"),
            Route("GET", "/api/mind/problems", "lines of the log that couldn't be read, with their fixes", tags: "problems errors mistakes"),
            Route("POST", "/api/mind/check", "what lines would add, without adding {\"lines\"} or {\"text\"}", tags: "check validate dry"),
            Route("POST", "/api/mind/add", "add facts in plain fields {\"from\", \"to\"?, \"label\"?, \"notes\"?} or {\"facts\": [...]}", tags: "add link connect relate relationship fact facts create people things"),
            Route("POST", "/api/mind/append", "append lines of the notation {\"lines\": [...]} or a model's reply {\"text\"}; a mistake adds nothing", tags: "append lines notation"),
            Route("POST", "/api/mind/note", "a note on a node {\"name\", \"note\": \"date 2026-11-03\"}", tags: "note annotate date todo"),
            Route("POST", "/api/mind/rename", "the node is called something else from here on {\"name\", \"to\"}", tags: "rename"),
            Route("POST", "/api/mind/forget", "the node and its edges are gone from the mind (the log keeps its history) {\"name\"}", tags: "forget delete remove"),
            Route("POST", "/api/mind/comment", "a comment line {\"text\"}", tags: "comment"),
            Route("POST", "/api/mind/compact", "the log rewritten in its shortest form (the old one archived)", tags: "compact shrink archive"),
            Route("GET", "/api/mind/operations", "the latest mind operations, each with its id", tags: "operations history log"),
        ]),
        Group(id: "system-docs", title: "System docs", about: "How this app works, for people and for models: guides, the API, prompts, recipes and example exchanges, in SYSTEM-DOCS (in TOOL-MAC-RUN). Read only",
              endpoint: .systemDocs, tags: "docs documentation guide guides help manual prompt recipe how system", routes: [
            Route("GET", "/api/system-docs", "where they are, and the operations (the library's that read)", tags: "info operations"),
            Route("POST", "/api/system-docs", "any reading operation, by name: {\"op\": \"search\", \"q\": \"remember\"}", tags: "op operation"),
            Route("GET", "/api/system-docs/files", "every doc", tags: "list all"),
            Route("GET", "/api/system-docs/files/{name}", "a doc (START-HERE first; ?format=text: the text alone)", tags: "read start"),
            Route("GET", "/api/system-docs/files/{name}/outline", "a doc's headings", tags: "outline headings"),
            Route("GET", "/api/system-docs/search", "full text: ?q=words", tags: "search find"),
            Route("GET", "/api/system-docs/names", "the docs' names", tags: "names list"),
        ]),
        Group(id: "screen", title: "Show and copy", about: "Show the person something in a window in front of everything, with copy buttons; put text on their clipboard. (\"present\": true and \"copy\": true do the same on any answer.)",
              endpoint: .screen, tags: "show display window present clipboard copy paste screen", routes: [
            Route("GET", "/api/present", "what it takes", tags: "present show how"),
            Route("POST", "/api/present", "show a file {\"shelf\", \"name\"}, a node {\"mind\": \"ada\"}, or text {\"title\", \"text\", \"format\"?}", tags: "present show display window"),
            Route("GET", "/api/clipboard", "what it takes", tags: "clipboard how"),
            Route("POST", "/api/clipboard", "copy {\"text\"}, a file {\"shelf\", \"name\"}, or a node {\"mind\"}", tags: "copy clipboard paste"),
        ]),
        Group(id: "browser", title: "Chrome's page", about: "Google Chrome, as the person sees it: open a page in a new tab, read the page in front (its text and links), whether words are on it, where a thing is, and a red ring to show them. It never clicks, types or fills anything in (Straw does that, POST /api/straw/run, after Run on the Mac). To find something out without Chrome: the web's routes (GET /api/web/search, /api/web/fetch)",
              endpoint: .browser, tags: "chrome browser page tab site guide read current front show !click !type !fill !press !submit", routes: RunAPI.browserRoutes.map { Route($0.method, $0.path, $0.summary, tags: RunAPI.browserTags[$0.path] ?? "") }),
        Group(id: "web", title: "The web", about: "The web, read from this Mac without Chrome: search it, and read any address (a page's text and links, a JSON API's answer, text). GET only, nothing sent but the address, never this Mac or its local network; answered at once",
              endpoint: .web, tags: "web internet online site website http https url search lookup api read", routes: RunAPI.webRoutes.map { Route($0.method, $0.path, $0.summary, tags: $0.tags) }),
        Group(id: "tools", title: "Tools, for a model", about: "Everything here as a short list of tools a model calls by name, each with its arguments, what it's for and how it answers (GET /api/tools), and one call that runs any of them (POST /api/tools/{name}). A client can hand the list to its model as is: what's added here later is there the day it ships",
              endpoint: nil, tags: "tools tool model llm agent assistant function functions calling manifest schema prompt", routes: [
            Route("GET", "/api/tools", "every tool: its name, what it's for, its arguments, whether it waits for Run on the Mac; with a guide and examples for a model's instructions", tags: "list all manifest schema describe"),
            Route("GET", "/api/tools/{name}", "one tool", tags: "one describe"),
            Route("POST", "/api/tools/{name}", "call a tool {\"arguments\": {…}} (and \"client\", \"why\", \"stream\"?): the answer of the route it calls; one that runs something waits for Run on the Mac", tags: "call run invoke use execute"),
        ]),
        Group(id: "automation", title: "Automation", about: "Scripts and flows that run by themselves", endpoint: nil, tags: "automation automate schedule cron trigger every recurring timer tag", routes: [
            Route("GET", "/api/automation", "the tags there are, and what runs by itself", tags: "list tags scheduled"),
            Route("POST", "/api/automation", "tag a script or a flow to run by itself {\"script\"|\"flow\", \"automation\": [tags]}", asks: true, tags: "schedule tag automate set"),
        ]),
        Group(id: "runs", title: "Runs and requests", about: "Every request's id, the runs, what they printed, and stopping one", endpoint: .runs, tags: "run runs request requests status state job result results output progress track poll id guid uuid", routes: [
            Route("GET", "/api/requests/open", "the requests not cleared yet, oldest first: each waiting (on the Mac), running, or ready to collect", tags: "open pending outstanding queue unread uncollected ready waiting track list status"),
            Route("GET", "/api/requests/{id}", "where a request is; once it's over, the first read hands over its result and clears it (?peek=true: look without taking it)", tags: "status state result collect poll check where progress"),
            Route("DELETE", "/api/requests/{id}", "clear one without reading it; one still waiting for the click is taken back (the card goes)", tags: "clear dismiss withdraw cancel forget delete remove"),
            Route("POST", "/api/requests/clear", "clear every request that's over and not collected {\"requests\"?: [ids]}", tags: "clear dismiss all ready done"),
            Route("GET", "/api/requests", "the latest requests, newest first, cleared or not (?limit)", tags: "history latest list log"),
            Route("GET", "/api/runs", "the latest runs, without their output (?limit)", tags: "runs history latest list"),
            Route("GET", "/api/runs/{id}", "one run, with everything it printed (and a flow's steps)", tags: "run output log result"),
            Route("POST", "/api/runs/{id}/stop", "stop it (one the person started waits for Stop It on the Mac)", asks: true, tags: "stop kill cancel abort halt"),
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
