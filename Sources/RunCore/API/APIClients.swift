import Foundation

/// How another app calls the API, ready to paste: a snippet for each kind of client (a terminal,
/// Python, JavaScript, Swift, Apple's Shortcuts, an AI agent), with this Mac's address (and the
/// token, when sharing on the network is on) filled in. What the panel's **Copy for…** buttons
/// copy. Each one lists the scripts, runs one with `client` and `why`, keeps the request id, and
/// handles Don't Run: the things every caller has to get right.
public enum APIClient: String, CaseIterable, Sendable {
    case curl, python, javascript, swift, shortcuts, agent, smallModel

    /// The button's word.
    public var title: String {
        switch self {
        case .curl: "curl"
        case .python: "Python"
        case .javascript: "JavaScript"
        case .swift: "Swift"
        case .shortcuts: "Shortcuts"
        case .agent: "AI Agent"
        case .smallModel: "Small Model"
        }
    }

    /// The button's symbol (SF Symbols).
    public var symbol: String {
        switch self {
        case .curl: "terminal"
        case .python: "chevron.left.forwardslash.chevron.right"
        case .javascript: "curlybraces"
        case .swift: "swift"
        case .shortcuts: "square.stack.3d.up"
        case .agent: "sparkles"
        case .smallModel: "text.bubble"
        }
    }

    /// What the button copies, in a line (its tooltip).
    public var help: String {
        switch self {
        case .curl: "Copy curl commands: list the scripts, run one, follow a request by its id"
        case .python: "Copy a Python helper (no packages needed): run a script or a flow, wait or not, Don't Run handled"
        case .javascript: "Copy a JavaScript helper (fetch: Node 18+, Deno, Bun or a page on this Mac)"
        case .swift: "Copy a Swift helper (URLSession, async): for a Mac app or a command-line tool"
        case .shortcuts: "Copy the steps for a shortcut in Apple's Shortcuts that runs a script here"
        case .agent: "Copy instructions for an AI agent (Claude, ChatGPT, a local model): the rules, the endpoints, the request id"
        case .smallModel: "Copy what a small model needs to talk to it in plain words, through Peter (Tool Mac Agent): one line for its instructions, and how the app passes it on"
        }
    }

    /// The snippet, for a server at `baseURL`; with `token`, every request sends it.
    public func text(baseURL: String, token: String? = nil) -> String {
        let token = token.flatMap { $0.isEmpty ? nil : $0 }
        switch self {
        case .curl: return Self.curl(baseURL, token)
        case .python: return Self.python(baseURL, token)
        case .javascript: return Self.javascript(baseURL, token)
        case .swift: return Self.swift(baseURL, token)
        case .shortcuts: return Self.shortcuts(baseURL, token)
        case .agent: return Self.agent(baseURL, token)
        case .smallModel: return Self.smallModel(baseURL, token)
        }
    }

    // MARK: the snippets

    private static func curl(_ base: String, _ token: String?) -> String {
        let auth = token.map { " -H 'Authorization: Bearer \($0)'" } ?? ""
        return """
        # Tool Mac Tool Run, from a terminal (or any script that can run curl).
        # Every run waits for the person at the Mac to click Run; send "client" and "why" so the card says who and why.

        # Is it up, and what's on?
        curl -s\(auth) \(base)/api/health

        # The scripts and flows there are (name, title, what each asks for)
        curl -s\(auth) \(base)/api/scripts
        curl -s\(auth) \(base)/api/flows

        # Run a script and wait for it to end: the answer has "ok", "code" and "output"
        curl -s\(auth) \(base)/api/run -d '{"script": "hello.sh", "args": ["world"], "client": "My Terminal", "why": "Trying the API"}'

        # The same, as it prints (one JSON object a line)
        curl -sN\(auth) \(base)/api/run -d '{"script": "hello.sh", "stream": true, "client": "My Terminal", "why": "Trying the API"}'

        # Don't wait at all: keep the request id, ask about it any time later
        curl -si\(auth) \(base)/api/run -d '{"script": "hello.sh", "async": true, "client": "My Terminal", "why": "Trying the API"}'
        curl -s\(auth) \(base)/api/requests/<the X-Request-Id>

        # A flow from the folder, or Flow code you send
        curl -s\(auth) \(base)/api/compose -d '{"flow": "morning.flow", "client": "My Terminal", "why": "Morning check"}'
        curl -s\(auth) \(base)/api/compose -d '{"source": "print \\"hi\\"", "name": "Say hi", "client": "My Terminal"}'

        # The file library (LIBRARY, in STORAGE-SPACES/USER on the Desktop): notes by name, answered at once, nothing asked on the Mac
        curl -s\(auth) \(base)/api/library -d '{"op": "write", "name": "groceries", "text": "- eggs\\n- milk\\n", "client": "My Terminal"}'
        curl -s\(auth) \(base)/api/library -d '{"op": "search", "q": "milk"}'
        curl -s\(auth) "\(base)/api/library/files/groceries?format=text"
        curl -s\(auth) -X DELETE \(base)/api/library/files/groceries      # to the library's Trash (restore brings it back)

        # Straw: check Straw code (nothing runs), or run it in Chrome (waits for Run on the Mac)
        curl -s\(auth) \(base)/api/straw/check -d '{"source": "open example.com\\nread title"}'
        curl -s\(auth) \(base)/api/straw/run -d '{"source": "open example.com\\nread title", "client": "My Terminal", "why": "Trying Straw"}'

        # Every route, in its groups; the whole API in one page
        curl -s\(auth) \(base)/api/endpoints
        curl -s\(auth) \(base)/api/doc
        """
    }

    private static func python(_ base: String, _ token: String?) -> String {
        let auth = token.map { #"    "Authorization": "Bearer \#($0)","# + "\n" } ?? ""
        return #"""
        # Tool Mac Tool Run from Python: the standard library only (no packages to install).
        # Every run waits for the person at the Mac to click Run; send "why" so the card says why.
        import json
        import time
        import urllib.error
        import urllib.request

        BASE = "\#(base)"
        HEADERS = {
            "Content-Type": "application/json",
        \#(auth)}
        CLIENT = "My Python App"  # shown on the card on the Mac


        def call(method, path, body=None):
            """One request: its JSON, and its HTTP status (403 is Don't Run, not an exception)."""
            data = json.dumps(body).encode() if body is not None else None
            req = urllib.request.Request(BASE + path, data=data, method=method, headers=HEADERS)
            try:
                with urllib.request.urlopen(req, timeout=None) as r:
                    return json.loads(r.read() or b"{}"), r.status
            except urllib.error.HTTPError as e:
                return json.loads(e.read() or b"{}"), e.code


        def run(script, args=(), why="", stdin=None):
            """Runs a script (waits for the click, then for it to end). Returns its result: ok, code, output."""
            body = {"script": script, "args": list(args), "client": CLIENT, "why": why}
            if stdin is not None:
                body["stdin"] = stdin
            result, status = call("POST", "/api/run", body)
            if status == 403:
                raise RuntimeError(result["error"])  # Don't Run, or no click in two minutes
            return result


        def compose(flow=None, source=None, why=""):
            """Runs a flow from the folder (by name), or Flow code you send."""
            body = {"client": CLIENT, "why": why}
            body.update({"flow": flow} if flow else {"source": source})
            result, status = call("POST", "/api/compose", body)
            if status in (400, 403):
                raise RuntimeError(result.get("error"))
            return result


        def run_later(script, args=(), why=""):
            """Asks now, returns at once with the request id; follow it with wait_for(id)."""
            result, _ = call("POST", "/api/run", {"script": script, "args": list(args), "client": CLIENT, "why": why, "async": True})
            return result["request"]


        def library(op, **fields):
            """The file library (LIBRARY, in STORAGE-SPACES/USER on the Desktop): notes by name, answered at once, nothing asked on the Mac.
            library("write", name="groceries", text="- eggs"), library("read", name="groceries")["text"],
            library("append", name="groceries", text="- milk"), library("search", q="milk")["results"],
            library("find", q="milk")["names"], library("names")["names"], library("delete", name="groceries")."""
            result, _ = call("POST", "/api/library", {"op": op, "client": CLIENT, **fields})
            if not result.get("ok"):
                raise RuntimeError(result.get("error"))  # not_found (with "fix": the names near it), already_exists…
            return result


        def wait_for(request_id, every=1.0):
            """Where the request is, once it's over: succeeded, failed, denied, not_answered…"""
            while True:
                r, _ = call("GET", "/api/requests/" + request_id)
                if r.get("state") not in ("waiting", "running"):
                    return r
                time.sleep(every)


        if __name__ == "__main__":
            scripts, _ = call("GET", "/api/scripts")
            print("Scripts:", ", ".join(s["name"] for s in scripts["scripts"]))
            r = run("hello.sh", ["world"], why="Trying the API from Python")
            print("ok" if r["ok"] else f"failed ({r['code']})", r["output"])
            library("write", name="From Python", text="Written by my Python app")
            print(library("read", name="From Python")["text"])
        """#
    }

    private static func javascript(_ base: String, _ token: String?) -> String {
        let auth = token.map { "\n  Authorization: \"Bearer \($0)\"," } ?? ""
        return """
        // Tool Mac Tool Run from JavaScript: fetch only (Node 18+, Deno, Bun, or a page on this Mac).
        // Every run waits for the person at the Mac to click Run; send `why` so the card says why.
        const BASE = "\(base)";
        const HEADERS = {
          "Content-Type": "application/json",\(auth)
        };
        const CLIENT = "My JS App"; // shown on the card on the Mac

        async function call(method, path, body) {
          const r = await fetch(BASE + path, { method, headers: HEADERS, body: body ? JSON.stringify(body) : undefined });
          return { status: r.status, requestId: r.headers.get("X-Request-Id"), json: await r.json().catch(() => ({})) };
        }

        // Runs a script: waits for the click, then for it to end. Resolves with { ok, code, output, … }.
        export async function run(script, args = [], why = "") {
          const { status, json } = await call("POST", "/api/run", { script, args, why, client: CLIENT });
          if (status === 403) throw new Error(json.error); // Don't Run, or no click in two minutes
          return json;
        }

        // Runs a flow from the folder, or Flow code you send ({ source: "print \\"hi\\"" }).
        export async function compose({ flow, source }, why = "") {
          const { status, json } = await call("POST", "/api/compose", { flow, source, why, client: CLIENT });
          if (status === 400 || status === 403) throw new Error(json.error);
          return json;
        }

        // Asks now and comes straight back with the request id; follow it with waitFor(id).
        export async function runLater(script, args = [], why = "") {
          const { json } = await call("POST", "/api/run", { script, args, why, client: CLIENT, async: true });
          return json.request;
        }

        // The file library (LIBRARY, in STORAGE-SPACES/USER on the Desktop): notes by name, answered at once, nothing asked on the Mac.
        // await library("write", { name: "groceries", text: "- eggs" }); (await library("read", { name: "groceries" })).text
        // (await library("search", { q: "eggs" })).results; (await library("find", { q: "eggs" })).names; library("delete", { name: "groceries" })
        export async function library(op, fields = {}) {
          const { json } = await call("POST", "/api/library", { op, client: CLIENT, ...fields });
          if (!json.ok) throw new Error(json.error); // not_found (with json.fix: the names near it), already_exists…
          return json;
        }

        export async function waitFor(requestId, everyMs = 1000) {
          for (;;) {
            const { json } = await call("GET", `/api/requests/${requestId}`);
            if (json.state !== "waiting" && json.state !== "running") return json;
            await new Promise((done) => setTimeout(done, everyMs));
          }
        }

        // Try it:
        // const r = await run("hello.sh", ["world"], "Trying the API from JavaScript");
        // console.log(r.ok ? "ok" : `failed (${r.code})`, r.output);
        """
    }

    private static func swift(_ base: String, _ token: String?) -> String {
        let auth = token.map { "\n        request.setValue(\"Bearer \($0)\", forHTTPHeaderField: \"Authorization\")" } ?? ""
        return """
        // Tool Mac Tool Run from Swift: URLSession, async/await, Foundation only.
        // Every run waits for the person at the Mac to click Run; send `why` so the card says why.
        import Foundation

        struct ToolMacToolRun {
            var base = URL(string: "\(base)")!
            var client = "My Swift App" // shown on the card on the Mac

            struct Refused: Error { let message: String }

            /// One request: its JSON and its HTTP status (403 is Don't Run).
            func call(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> ([String: Any], Int) {
                var request = URLRequest(url: base.appendingPathComponent(path))
                request.httpMethod = method
                request.timeoutInterval = 24 * 3600 // a waited-for run answers when it ends
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")\(auth)
                if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
                let (data, response) = try await URLSession.shared.data(for: request)
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                return (json, (response as? HTTPURLResponse)?.statusCode ?? 0)
            }

            /// Runs a script: waits for the click, then for it to end. Its result has "ok", "code", "output".
            func run(_ script: String, _ args: [String] = [], why: String) async throws -> [String: Any] {
                let (json, status) = try await call("POST", "api/run", ["script": script, "args": args, "client": client, "why": why])
                if status == 403 { throw Refused(message: json["error"] as? String ?? "it didn't run") }
                return json
            }

            /// Asks now, answers at once: the request id, for `state(of:)`.
            func runLater(_ script: String, _ args: [String] = [], why: String) async throws -> String {
                let (json, _) = try await call("POST", "api/run", ["script": script, "args": args, "client": client, "why": why, "async": true])
                return json["request"] as? String ?? ""
            }

            /// The file library (LIBRARY, in STORAGE-SPACES/USER on the Desktop): notes by name, answered at once, nothing asked on the Mac.
            /// `try await library("write", ["name": "groceries", "text": "- eggs"])`, `try await library("read", ["name": "groceries"])["text"]`,
            /// "search" (["q": "eggs"]), "find", "append", "delete" (to the library's Trash), "restore"…
            func library(_ op: String, _ fields: [String: Any] = [:]) async throws -> [String: Any] {
                var body = fields
                body["op"] = op
                body["client"] = client
                let (json, _) = try await call("POST", "api/library", body)
                if json["ok"] as? Bool != true { throw Refused(message: json["error"] as? String ?? "it didn't work") }
                return json
            }

            /// Where a request is: waiting, running, succeeded, failed, denied, not_answered…
            func state(of requestID: String) async throws -> [String: Any] {
                try await call("GET", "api/requests/\\(requestID)").0
            }
        }

        // Try it:
        // let r = try await ToolMacToolRun().run("hello.sh", ["world"], why: "Trying the API from Swift")
        // print(r["output"] ?? "")
        """
    }

    private static func shortcuts(_ base: String, _ token: String?) -> String {
        let auth = token.map { "\n     Headers: Authorization = Bearer \($0)" } ?? ""
        let curlAuth = token.map { " -H 'Authorization: Bearer \($0)'" } ?? ""
        return """
        A shortcut (Apple's Shortcuts app) that runs one of your scripts through Tool Mac Tool Run.
        The Mac shows its card first: the shortcut gets the result once Run is clicked.

        The quickest way: one action.
          1. Add "Run Shell Script" (Scripting). Shell: bash. Paste:
             curl -s\(curlAuth) \(base)/api/run -d '{"script": "hello.sh", "args": ["world"], "client": "Shortcuts", "why": "From my shortcut"}' | python3 -c 'import json,sys; r=json.load(sys.stdin); print(r.get("output") or r.get("error",""))'
          2. Add "Show Result" (or "Speak Text") with the Shell Script Result.

        Without the shell, in three actions:
          1. "Dictionary": script = hello.sh, client = Shortcuts, why = From my shortcut
             (and args: a List of Text, when the script takes some).
          2. "Get Contents of URL": \(base)/api/run
             Method: POST.  Request Body: JSON, the Dictionary.\(auth)
          3. "Get Dictionary Value": output, from the Contents of URL. Then Show Result.

        Ask Siri: name the shortcut ("Say hello"), and say its name.
        Other scripts: change "hello.sh" ( \(base)/api/scripts lists every name ).
        Don't Run (or no click in two minutes) answers {"error": "…", "code": "denied"}: the steps show the error.
        """
    }

    private static func agent(_ base: String, _ token: String?) -> String {
        let auth = token.map { "\nSend this header with every request: Authorization: Bearer \($0)" } ?? ""
        return """
        You can run the user's scripts and flows on their Mac through Tool Mac Tool Run's HTTP API at \(base) (JSON in, JSON out).\(auth)

        Rules:
        1. Nothing runs without the user's click. Every run request shows a card on their Mac; they click Run or Don't Run, and no click in two minutes is Don't Run. You can't click for them: say "it's waiting for you to click Run on your Mac".
        2. Send "client" (your name, shown on the card) and "why" (why you want it, in the user's terms, a sentence they read before clicking) with every run.
        3. If you call tools by name, GET \(base)/api/tools gives them (each with its arguments), and POST \(base)/api/tools/<name> {"arguments": {…}} calls one: use those instead of the routes below. Don't load every route. To find the call for something, search by a few words: GET \(base)/api/search?q=<what you want> (?in=scripts,flows for the user's scripts and flows only). It answers only what matches, the best first; a script or flow comes with "run": the request that runs it, its inputs as <placeholders>. Never guess a name.
        4. Every JSON answer has "next": the calls that usually come after it, with ids filled in. Follow it rather than guessing a path; errors have "fix" and "next" too.
        5. Send runs with "async": true and keep the request id ("request" in the JSON, and the X-Request-Id header). GET \(base)/api/requests/{id} says where it is: "delivery" is "pending" while it waits for the click or runs (ask again in a few seconds, or later). Once it's over, that read hands over the result ("delivered", with "run": its output) once; asked again, it says how it ended without the output. So use the output when you get it.
        6. Lost track? GET \(base)/api/requests/open lists every request not collected yet, oldest first, each "pending" or "ready". DELETE /api/requests/{id} takes back one still waiting for the click (nothing runs).
        7. A run that fails is still over: read "ok" and "run.code"; relay "run.stderr" or "run.problem". 403 (or state denied, not_answered) means it didn't run; don't ask again unless the user wants you to.
        8. The user's notes, LIBRARY (in STORAGE-SPACES/USER on their Desktop), are yours to read and write without a click: POST /api/library {"op": "<op>", …}. A note is a name (no .md) and its text, like a key and its value. Deleting moves it to the library's own Trash ("restore" brings it back), so it's safe; still, don't delete or replace what the user didn't ask you to.

        Endpoints:
        GET  /api/search?q=<words>        only the routes, scripts and flows that match, each with how to call it: START HERE
        GET  /api/scripts                 the scripts: name, title, summary, tags, inputs (what each asks for), dangers
        GET  /api/flows                   the flows (scripts composed in the Flow language)
        POST /api/run                     {"script": "<name>", "args": [...], "async": true, "client": "<you>", "why": "<why>"} → 202 {"request": id, "next": […]} at once
                                          without "async": waits for the click, then for it to end: {"ok", "code", "output", "request", …}
        POST /api/compose                 {"flow": "<name>"} or {"source": "<Flow code>"}, the same fields: runs a flow
        POST /api/check                   {"source": "<Flow code>"} → checks it, runs nothing
        GET  /api/requests/{id}           where a request is; once it's over, the first read hands over its result (?peek=true: look without taking it)
        GET  /api/requests/open           every request not collected yet, oldest first: waiting, running, or ready
        DELETE /api/requests/{id}         clear one without reading it; one still waiting for the click is taken back
        POST /api/runs/{id}/stop          stops a run you asked for (one the user started asks them first)
        POST /api/library                 {"op": "list"|"names"|"read"|"read_many"|"write"|"create"|"append"|"rename"|"copy"|"delete"|"restore"|"trash"|"search"|"find"|"recent"|"stats"|"outline"|"backlinks", "name"?, "text"?, "q"?, …}: the notes, answered at once
                                          e.g. {"op": "search", "q": "bank"} → {"results": [{"name", "score", "lines": [{"line", "text"}]}]}; {"op": "read", "name": "groceries"} → {"text", …}
        GET  /api/web/search?q=<words>    search the web from this Mac, at once: each result's title, address and words
        GET  /api/web/fetch?url=<address> read any address, at once: a page's text and links, or a JSON API's answer (?find=<words>: the lines with them)
        POST /api/browser/open            {"url"}: opens it in the user's Chrome, in a new tab, and reads it back, at once
        GET  /api/browser/page            the page in front of Chrome: its text and links (also /url, /has?text=, /find?text=; POST /api/browser/highlight rings a thing in red). It never clicks or types: Straw does
        GET  /api/straw                   Straw's words and the Straw scripts (Straw drives Chrome by what's on the page)
        POST /api/straw/check             {"source": "<Straw code>"} → what it would do, or its mistake; runs nothing
        POST /api/straw/run               {"script": "<name>"} or {"source": "<Straw code>"}, with "client" and "why": runs it in Chrome once the user clicks Run
        GET  /api/endpoints?brief=true    the groups of routes, small (?group=<id>: one group's routes); without it, every route: long
        GET  /api/doc                     every endpoint, field and error, in one page: long; search first

        Example:
        GET  \(base)/api/search?q=weather&in=scripts
        → {"results": [{"kind": "script", "name": "utilities/weather.py", "run": {"method": "POST", "path": "/api/run", "body": {"script": "utilities/weather.py", "args": ["<A city>"], "async": true, …}}}], …}
        POST \(base)/api/run
        {"script": "utilities/weather.py", "args": ["Lagos"], "async": true, "client": "Assistant", "why": "You asked what the weather is in Lagos"}
        → 202 {"request": "2A7C…", "delivery": "pending", "next": [{"method": "GET", "path": "/api/requests/2A7C…", …}]}
        GET  \(base)/api/requests/2A7C…   (again until "delivery" is "delivered": then "run.output" is the answer)
        """
    }

    private static func smallModel(_ base: String, _ token: String?) -> String {
        _ = token
        return """
        # A model that only knows how to talk: Peter (Tool Mac Agent) is the way in.
        # He reads what it says, carries it out here (\(base)), and answers in plain words:
        # https://github.com/ainigh/tool-mac-tool-run-agent

        ## The instructions
        To get anything done on the Mac or the web, ask Peter in plain words. If he answers with templates, fill one in and say it back.

        ## Passing it on (your app, not the model)
        # ?client= names your app on the Mac's cards, and a run's card shows why, in the model's own words.
        # The answer is plain text: hand it back to the model.
        # X-Reply-To (an address on this Mac): told the moment a run is over, or something scheduled is due.
        curl -s 'http://127.0.0.1:8770/api/say?client=My+Assistant' -H 'Content-Type: text/plain' --data-binary "what's the weather in Lagos"
        # Asked for the weather. I'll tell you how it goes.
        """
    }
}
