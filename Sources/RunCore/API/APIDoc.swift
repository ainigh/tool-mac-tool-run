import Foundation

/// The API in one page, for another app (or the person writing one, or an assistant writing one
/// for them): every endpoint, every field, the events, the errors, and how to get in. It's what
/// `GET /api/doc` answers and what the panel's **Copy API Doc** copies, with the live base URL
/// (and the token, when sharing on the network is on) filled in, so it can be pasted whole into
/// another app's code, a README, or a chat with an assistant. The long form, with examples in
/// several languages, is API.md in the repository.
public enum APIDoc {
    /// The doc for a server at `baseURL` (`http://127.0.0.1:8768`). With a `token`, the doc says
    /// how to send it; without one, only this Mac's programs can reach the API.
    public static func text(baseURL: String, token: String? = nil, version: String? = nil) -> String {
        let token = token.flatMap { $0.isEmpty ? nil : $0 }
        let v = version.map { " (v\($0))" } ?? ""
        let access: String
        if let token {
            access = """
            Sharing on the network is on. From another device, send the token with every request:
                Authorization: Bearer \(token)
            Programs on the Mac itself need no token. Runs asked for from another device still wait for Run on the Mac.
            """
        } else {
            access = """
            It listens on 127.0.0.1 only: programs on this Mac can call it; other machines can't reach it.
            Browser pages from this machine (http://localhost:*, http://127.0.0.1:*) may call it (CORS); other origins are refused.
            """
        }
        return """
        # Tool Mac Tool Run API\(v)

        Base URL: \(baseURL)
        Tool Mac Tool Run is a menu bar app on this Mac that runs the person's scripts (bash, Python, Node…) and flows (scripts composed in the Flow language), and serves them over HTTP. JSON in, JSON out.

        NOTHING RUNS WITHOUT THE PERSON'S CLICK (the file library aside: see below). Every run request shows a card on the Mac naming your app and what would run; your request waits until the person clicks Run (or Don't Run; no click in two minutes is Don't Run). Send "client": "Your App's Name" so the card says who's asking.
        EVERY REQUEST HAS AN ID you can depend on: it comes back at once (the X-Request-Id header, and "request" in the JSON of every answer, refusals included), and GET /api/requests/{id} says where it is any time later: waiting for the click, denied, running, how it ended. Send "async": true to get the id now and not wait at all.
        EACH RESULT IS HANDED OVER ONCE: in the answer itself when you waited, else by the first read of /api/requests/{id} once it's over; after that it's cleared (how it ended, without the output). GET /api/requests/open lists what you haven't collected yet, oldest first.
        YOU DON'T HAVE TO READ ALL OF THIS: GET /api/search?q=<a few words> answers only the routes, scripts and flows that match, each with how to call it, and every JSON answer has "next": the calls that usually come after it, with its ids filled in.
        FOR A MODEL, THERE ARE TOOLS: GET /api/tools is everything here as a short list of tools to hand a model as is (each with what it's for, its arguments, and whether it waits for Run), with a guide and examples for its instructions; POST /api/tools/{name} {"arguments": {…}} calls one. A client that passes its model's calls through never needs to know a route.

        ## Tools, for a model

        GET /api/tools → {"tools": [{"name", "description", "args": [{"name", "type", "required", "about"}], "asks_on_the_mac", "answers", "stream", "on", "aliases", "call", "uses"}], "guide": [lines for the model's instructions], "examples": [{"user", "steps": [{"call": {"tool", "arguments"}, "result"}], "answer"}]}. A tool whose switch is off is left out (?all=true: listed, "on": false). GET /api/tools/{name}: one.
        POST /api/tools/{name} {"arguments": {…}, "client": "<you>", "why"?: "<shown on a card>", "stream"?: true}: the answer is the JSON of the route the tool stands for (a run's, a note's, a page's…), with "tool": its name. The arguments may be given flat, too. The names a model reaches for are taken: another name for a tool ("google" is web_search, "list_runs" is runs with op list), another for an argument ("query" for "q", "address" for "url"), a script's or flow's own name as the tool (it's run). A miss says what to do: 404 unknown_tool (the tools there are, and what fits its words), 400 missing_argument; an error has "takes" (what the tool takes) and "tools" (what fits instead, a line each).
        The tools: find (the tools, scripts and flows for some words), run_script, run_flow, run_flow_code, check_flow, runs, web_search, web_fetch, browser, straw, library, remember, recall, memory, mind, show, copy, docs, call_api (any route no tool covers). run_script, run_flow, run_flow_code and straw wait for Run on the Mac and stream with "stream": true; the rest answer at once.

        ## The web, from this Mac

        GET /api/web/search?q=words (?limit=8) → {"engine", "results": [{"title", "url", "snippet"}], "lines"}: a web search, answered at once (DuckDuckGo, else Bing). GET /api/web/fetch?url=https://… (?find=words: "lines", the ones that have them; ?max=8000) → {"url", "status", "type", "kind": "page"|"json"|"text"|"file", "title"?, "description"?, "text", "chars", "truncated", "links"?: [{"text", "url"}], "json"?}: a page made readable (its main part, no scripts, menus or styles), a JSON API's answer, or text. GET only, a browser's User-Agent, no cookies; never this Mac or its local network (403 local_address), redirects there refused. Errors: 400 bad_url, 502 unreachable | search_failed, 504 timed_out. The "Read the web" switch turns it off.

        ## Endpoints, by group

        GET /api/endpoints gives this list as JSON ({"groups": [{"id", "title", "about", "routes": [{"method", "path", "summary", "asks_on_the_mac"}]}]}); ?group=memory one group; ?brief=true the groups alone (each with its route count and words); ?q=words a search of the routes.

        ## Finding your way: search, and "next"

        GET /api/search?q=remember a birthday → {"q", "words", "count", "total", "results": [...], "next"}: the best matches first. A route: {"kind": "route", "method", "path", "call", "summary", "group", "asks_on_the_mac", "tags", "matched", "score"}. A script or flow: {"kind": "script"|"flow", "name", "summary", "tags", "inputs", "run": {"method", "path", "body"}}: the request that runs it, its inputs as <placeholders>.
        - ?in=routes,scripts,flows (all by default), ?group=memory (one group's routes), ?limit=10 (at most 50). Words like "how", "a", "the" are left out; the rest compare by stem ("birthdays" = "birthday").
        - Routes are found by their path, summary, group and tags (the words someone looking for one would say: "status", "result", "job" find /api/requests/{id}). Scripts and flows by their name, first comment, topic, and their header's "# Tags: weather forecast" line.
        - Nothing matched: "count": 0, and "next" points to /api/endpoints?brief=true. No ?q=: 400 missing_query.
        Every JSON answer (errors too) carries "next": [{"method", "path", "why"}], the calls that usually follow, with the path's values ({name}, {id}) and the request's ids filled in; a placeholder like {words} is for you to fill. ?next=false leaves it out.

        \(APIRoutes.text)

        Each switch (run, compose, catalog, runs, library) can be turned off in the app: its routes then answer 503 {"code": "endpoint_off"}. A refused connection means the app isn't running or its API is stopped.

        ## Running

        POST /api/run with {"script": "hello.sh", "args": ["world"], "client": "My App", "why": "The user pressed Greet in My App"}
        - script: its name from /api/scripts, with or without the extension. A utility or browser script's name starts with its folder (utilities/speak.sh); its file name alone works too ("speak") when no script in the folder above has it.
        - args: a list of strings, or one line split as a shell would ("--all '/tmp/my files'").
        - stdin: text handed to the script as its input (for scripts with "asks_for_input": true).
        - client: your app's name, shown on the card. Without it, the X-Client header, else the User-Agent's first word.
        - why: SEND THIS. Why your app wants it run, in a sentence or two the person can read on the card before clicking Run (what pressed the button, what the result is for). Without it the card says your app gave no reason, which makes Don't Run likelier. It's kept with the run ("why" in its JSON). "reason" works too.
        - wait: false → 202 as soon as it has started (once Run is clicked), with its "id"; then read /api/runs/{id} until "state" isn't "running".
        - async: true → 202 now, before anyone has clicked, with "request"; then read /api/requests/{id} (see Request ids).
        - stream: true → see Streaming.
        - automation: tag it to run by itself instead of running it now (see Automation).

        By default the answer comes once the run has ended (however long it takes; closing the connection doesn't stop it):
        {"id", "request", "kind": "script"|"flow", "name", "state", "ok", "code", "seconds", "started", "ended", "command", "arguments", "output", "stdout", "stderr", "trimmed", "requested_by", "why"?, "problem"?, "signal"?, "steps"?}
        - state: running | succeeded | failed | stopped | could_not_start.   ok: state is succeeded (exit code 0).
        - code: the exit code (killed by a signal: 128 + the signal, and "signal" says which).
        - output: everything it printed, in order; stdout and stderr are the two apart. trimmed: over 300 KB, the earliest part was dropped.
        - problem: why it couldn't start (or why a flow stopped), with the fix.
        A run that fails is still 200: look at "ok". It didn't run when the status is 403 ("denied": Don't Run was clicked; "not_answered": no click in two minutes) or 404 ("unknown_script"; "error" lists the ones there are).

        POST /api/compose with {"flow": "morning.flow"} runs a flow from the folder; with {"source": "<Flow code>", "name": "What to call it"} runs code you send (it can run the folder's scripts: run "hello.sh" []). The code is checked first: a mistake is 400 flow_mistake and nothing is shown on the Mac. A flow's result has "kind": "flow" and "steps": each script it ran, as a run of its own. A flow that asks something asks the person at the Mac and waits. In Flow code you send, say why a question is asked: confirmBecause "Delete them?" "They're 30 days old and take 12 GB" (also askBecause, askYesNoBecause, chooseBecause) — the why shows under the question.

        ## The file library: notes by name, answered at once

        LIBRARY, in TOOL-MAC-RUN on the person's Desktop, holds their notes: Markdown files, each known by its name without .md (groceries is LIBRARY/groceries.md). A name is a key and the note's text its value. NOTHING HERE ASKS ON THE MAC: the library's calls answer at once (they're notes, not programs). A delete only moves the note to the library's own Trash folder, numbered (groceries (1).md, groceries (2).md…), so it can be restored.
        Every call has an id, as a run's request does: X-Request-Id, and "request" in the JSON; GET /api/library/operations/{id} (or /api/requests/{id}) says what it did, who asked and how it went.
        The easy way: POST /api/library {"op": "<operation>", …its fields}. Every answer has "ok", "op" and "request"; a refusal also "code", "error" and often "fix".
        - list {"sort"?: "name"|"modified"|"created"|"size", "order"?: "asc"|"desc", "q"?: words in the name, "limit"?, "offset"?, "content"?: true} → {"notes": [{"name", "file", "title"?, "size", "modified", "created"?, "text"?}], "count", "total"}
        - names → {"names": [...]}            read {"name"} → {"name", "text", "title", "size", "words", "lines", "modified", …}
        - read_many {"names": [...]} → {"notes": [...], "missing": [...]}            exists {"name"} → {"exists": true|false}
        - write {"name", "text"} creates it or replaces its text → {"name", "new": true|false, "action": "created"|"replaced", …}
        - create {"name", "text"?} → 409 already_exists if the name is taken            append {"name", "text"} adds it on a line of its own (creating the note if needed)
        - rename {"name", "to", "overwrite"?}            copy {"name", "to"}            delete {"name"} → {"trash": {"name", "number", "file", "deleted"}}
        - search {"q", "match"?: "all"|"any", "case_sensitive"?, "whole_words"?, "names_only"?, "lines"?: 5, "limit"?} → {"results": [{"name", "score", "lines": [{"line", "text"}], …}]}: every word (or a "quoted phrase") in the name or the text, accents and case aside, the best first
        - find (the same fields) → {"names": [...]}, the best first            recent {"limit"?: 10}            stats            outline {"name"} → {"headings": [{"level", "text", "line"}]}            backlinks {"name"}: the notes linking to it ([[name]])
        - trash → {"trash": [...]}            restore {"name", "number"?, "as"?} (the latest of that name unless "number"; "as" when the name is taken now)            empty_trash {"older_than_days"?}
        Names: any words but / and :, not starting with a dot; "groceries.md" is groceries; case and accents don't matter when one is found. 404 not_found says the names near it ("fix"). 400 bad_name, unknown_op; 409 already_exists.
        Raw text works too: PUT /api/library/files/groceries with the text as the body (text/plain or text/markdown) writes it; GET /api/library/files/groceries?format=text gives the text alone.

        ## MEMORY: what's remembered, answered at once

        MEMORY, in TOOL-MAC-RUN beside LIBRARY, is a library with a file for each kind of thing worth remembering: PEOPLE, ORGANIZATIONS, EVENT-DATES, BIRTHDAYS, LOCATIONS, IDEAS, LEVERAGE, STRATEGIES, OTHERS (and any others made). Each file is a node of the mind (below). Every library operation and route works on it, at /api/memory (POST /api/memory {"op"}, /api/memory/files/{name}…). Its own:
        - remember {"category": "PEOPLE", "about": "Ada Lovelace", "text"?, "links"?: [{"label"?, "to", "category"?}], "notes"?: ["birthday 03-14"]} → a line in the file, and in the mind the file linked to it, its links and notes → {"file", "node", "added_to_file", "added_to_mind"}
        - recall {"name"} (GET /api/memory/recall?name=ada) → {"found", "nodes", "about": [{"notes", "links"}], "categories", "mentions", "lines"}: look here before answering about a person, place or plan
        - categories → each file, whether it's one MEMORY comes with, how many things the mind files under it            members {"name"} (GET /api/memory/categories/PEOPLE/members)
        - upcoming {"days"?: 30} → {"upcoming": [{"day", "in_days", "what", "source", "yearly"}], "lines"}: dated notes in the mind, and lines in the files that start with a day (2026-11-03; 03-14 every year)
        - sync (each file a node)            defaults (puts back the nine files)
        A memory file's name is also a node's name: words, no @, and no -, | or = after a space (400 bad_name otherwise).

        ## The mind: what links to what, append only

        The mind is MIND/mind.txt in TOOL-MAC-RUN: lines in the text mind-map notation (GET /api/system-docs/files/MIND-NOTATION has every rule; MIND-GUIDE how to use it). "| ada lovelace - works at | acme" links two things; "| paper @date 2026-11-03" is a note; "| old = new" merges; "| old =" forgets; "| @ work" starts a scope. MEMORY's files are nodes in the root scope. NOTHING ASKS ON THE MAC, and nothing is ever taken out of the log: every change is a line added at the end.
        Ask it without the notation: GET /api/mind/nodes/{name} (all about a thing, looked up as a person means it), /nodes/{name}/neighbors?depth=2, /path?from=&to=, /find?q=, /edges?label=, /notes?kind=date, /dates?days=30, POST /api/mind/context {"text"} (the part of the mind a conversation touches, as lines), /stats, /graph, /canonical (one line a fact), /log.
        Ask it in the notation: POST /api/mind/query {"q": "| sam | x"}: a name not in the mind is a variable (| x - reviews | y, | paper @x, | @ talk) → {"lines", "answers": [{"matches": [{"bindings", "lines"}]}]}.
        Add without the notation: POST /api/mind/add {"from", "label"?, "to"?, "undirected"?, "notes"?} or {"facts": [those]}; note {"name", "note"}; rename {"name", "to"}; forget {"name"}. Names are matched to the mind's (case, spaces); new ones are written in lower case.
        Add in the notation: POST /api/mind/append {"lines": [...]} or {"text": "<a model's reply with a mm block>"}; check (the same, nothing written). Any mistake writes nothing (400 bad_lines, with "problems": [{"line", "text", "error", "fix"}]; "partial": true writes the rest). Lines already known are left out ("known"). A scope delete or merge is refused: it's the person's. POST /api/mind/prompt {"messages"} gives the notation's prompt for a model, filled in, with its grammar.

        ## SYSTEM-DOCS: how this app works, read only

        GET /api/system-docs/files/START-HERE, then PROMPT-ASSISTANT (a system prompt for you), RECIPES, EXCHANGES, MEMORY-GUIDE, MIND-GUIDE, BROWSER-GUIDE, PRESENT-AND-COPY, the guides, this API. The library's reading routes, at /api/system-docs (search, names, outline…); a write is 403 read_only.

        ## Showing and copying

        POST /api/present shows something on the Mac in a window in front of everything, with copy buttons: {"shelf": "memory", "name": "PEOPLE"}, {"mind": "ada lovelace"}, or {"title", "text", "format"?: "markdown"|"text"|"json"}; "why" is shown with it, "copy": true copies it too. POST /api/clipboard {"text"} (or a file, or "mind") puts it on the clipboard. On ANY library, memory, system-docs, mind or browser call, "copy": true puts the answer's text on the clipboard ("copied": true) and "present": true shows it ("presented": true). The clipboard isn't read.

        ## Chrome's page: to guide the person through a site

        The person's own Google Chrome, answered at once. POST /api/browser/open {"url", "new_tab"?: true, "max"?} opens an address in a new tab in front (a window, or Chrome itself, if there's none), waits for it to load and reads it: {"opened", "title", "url", "text", "links", …}; words instead of an address are a Google search, opened. GET /api/browser/url → {"title", "url"} (needs nothing switched on); /tabs; /page → {"title", "url", "text", "links", "selection", "scroll"} (?max=20000); /has?text=Compute → {"present": true|false, "count", "lines"}; /find?text=Compute → each match's "kind", "clickable", "where" (in view, above, below, or inside a closed menu to open first), "in", and "lines" (each a sentence to say); POST /api/browser/highlight {"text"} rings it in red on the page for a few seconds; /outline (headings, navigation, buttons, fields). IT NEVER CLICKS, TYPES OR FILLS ANYTHING IN: that's Straw (below), after Run on the Mac. To find something out without Chrome, the web's routes are quicker. Errors: 409 chrome_not_open | no_window | no_chrome, 403 javascript_off (fix: Chrome's View > Developer > Allow JavaScript from Apple Events) | not_allowed. Never tell the person something is on the page unless has or find said so; read again after each step.

        ## Straw: Chrome by what's on the page

        Straw scripts (.straw, in the browser folder) drive Google Chrome by naming what's on the page: open news.ycombinator.com, click "More", type "Search" "cats", read all css ".titleline > a". GET /api/straw lists the 25 words (each with what it takes, what it does and an example) and the Straw scripts in the folder. POST /api/straw/check {"source": "<Straw code>"} checks it without running anything → {"ok": true, "steps", "plan": [lines]} or {"ok": false, "code": "straw_mistake", "line", "error", "fix"}. POST /api/straw/run {"script": "hacker-news"} runs one, or {"source": "<Straw code>", "name"?} runs code you send (checked first: a mistake is 400 and nothing is asked); it waits for Run on the Mac like /api/run (the card shows your code in full), and takes the same "args", "why", "wait", "async" and "stream". What a Straw script reads is its output; what it's doing (a line a step) is its stderr.

        ## Request ids

        Every request that reaches the card (/api/run, /api/compose, /api/automation) gets an id the moment it arrives: the X-Request-Id header of the answer, "request" in its JSON (the run's JSON, the 202, the 403 for Don't Run), and "request" on every line of a stream. Keep it: whether you waited, streamed, hung up, or sent "async": true, GET /api/requests/{id} answers for it while the app runs (the latest 500):
        {"request", "state", "ok"?, "kind": "script"|"flow"|"automation"|"stop", "name", "via": "run"|"compose"|"automation"|"stop", "client", "from", "why"?, "asked", "answered"?, "run_id"?, "run_url"?, "run"?, "code"?, "error"?, "url"}
        - state: waiting (on the Mac, no click yet) | denied | not_answered | running | succeeded | failed | stopped | could_not_start | automated | gone (the run was cleared from the app's history). A stop request ("kind": "stop") that was allowed is stopped.
        - ok: once it's over (true for succeeded and automated); absent while waiting or running.
        - run: once started, the run itself with everything it printed, as /api/runs/{id} gives it. code, error: when it didn't run.
        Poll it as often as you like (nothing runs for the asking). GET /api/requests?limit=20 lists the latest (cleared or not), without "run". An unknown id is 404 unknown_request. Runs carry "request" too.
        - state also: withdrawn (your app took it back before the click).
        - delivery: pending (waiting or running: nothing to collect yet) | delivered (this answer is the result, handed over once; it's cleared now) | cleared (handed over before, or cleared without it: how it ended, without "run"; "cleared", "cleared_by": delivered | collected | dismissed | withdrawn) | ready (over, not collected: in the open list, or read with ?peek=true).
        - A waited-for, streamed or refused request is delivered in its own answer. An async one is collected by the first read of /api/requests/{id} once it's over; ?peek=true looks without taking it. Once cleared, the run is still at run_url while the app keeps it.
        GET /api/requests/open → {"count", "waiting", "running", "ready", "order": "oldest first", "requests": [{"position", "request", "name", "state", "delivery", "url", …}], "next"}: what you've asked for and not collected, in the order you sent it. GET /api/health counts them too ("requests").
        DELETE /api/requests/{id}: clear one that's over without reading it; one sent with "async": true and still waiting for the click is taken back (the card goes, nothing runs: state withdrawn). 409 still_running (stop it first) | still_waiting (its caller is still on the line). POST /api/requests/clear {"requests"?: [ids]} clears every one that's over and not collected.

        ## Automation

        A script or a flow can be tagged to run by itself. The tags are fixed (never made up): schedules — every-minute, every-5-minutes, every-10-minutes, every-30-minutes, every-hour, every-morning (7:00), every-afternoon (13:00), every-evening (19:00), every-day (9:00), every-week (Monday 9:00), every-month (the 1st, 9:00) — and triggers — when-api-called, when-a-script-runs, when-a-flow-runs, when-a-utility-runs, when-a-browser-script-runs, after-an-item (with "after": [names]), when-anything-runs. A trigger fires once the run that set it off has ended; a run the automation started never sets off another. Spaces work too ("every morning").
        POST /api/run (or /api/compose, or /api/automation) with {"script": "backup.sh", "automation": ["every evening"], "once": false, "client": "My App", "why": "…"} shows a card on the Mac saying your app wants it to run every evening from now on; Run tags it, Don't Run doesn't. Nothing runs at once. The answer: {"ok": true, "automated": true, "name", "kind", "tags", "once", "after", "summary", "next"?}. "once": true runs it the next time only, then takes the tags off. "automation": [] takes its automation off. An automated run shows in /api/runs with "requested_by": "Automation: <tag>", and runs with the arguments remembered for its cell.
        GET /api/automation → {"tags": [{"name", "title", "kind": "schedule"|"trigger", "about"}], "items": [{"name", "kind", "group", "title", "tags", "once", "after", "summary", "next"?}]}.

        ## Streaming

        With "stream": true, /api/run and /api/compose answer at once with Content-Type: application/x-ndjson, one JSON object per line, as things happen:
        {"type": "waiting", "request", "url", "message"}       it's on the Mac, waiting for Run; "request" is the id for /api/requests/{id}
        {"type": "denied", "request", "code", "message"}       denied or not_answered; the stream ends
        {"type": "started", "id", "request", "name"}
        {"type": "output", "stream": "out"|"err", "text"}      for a flow's step, also "step": the script's name
        {"type": "step", "id", "name", "state", "code"?}       a flow's step starting, then ending
        {"type": "done", …}                                    everything a waited-for run gives (above)
        {"type": "error", "message"}                           the stream ends
        Closing the connection while it's "waiting" takes the card away (nothing runs). Once started, the run goes on.

        ## Errors

        {"error": "what went wrong", "code": "…", "next": [where to look instead]}
        400 missing_script | missing_flow | bad_args | bad_request    the request isn't right
        400 missing_query | unknown_group                            a search without ?q=, or a group that isn't one
        400 unknown_tag                                             no such automation tag ("error" lists them)
        400 flow_mistake                                            the Flow code has a mistake (with "line" and "fix")
        401 unauthorized                                            sharing on the network is on and no token was sent
        403 denied | not_answered                                   it didn't run
        403 forbidden                                               a page from another site, a Host that isn't this Mac, or another machine while sharing is off
        400 missing_op | unknown_op | bad_name                       a library call that isn't right (see The file library)
        400 straw_mistake                                           the Straw code has a mistake (with "line" and "fix")
        404 not_found | unknown_script | unknown_flow | unknown_run | unknown_request
        400 bad_lines                                               lines for the mind have mistakes ("problems": each line, error and fix); nothing was written
        403 read_only                                               SYSTEM-DOCS can't be changed
        409 already_exists                                          a library note of that name is there already
        400 browser_reads_only                                      /api/browser/click, /type, /search…: Chrome's page doesn't act; "error" and "next" say what does (Straw, the web's search)
        404 unknown_tool | 400 missing_argument                     a tool call that missed: "takes" and "tools" say what to do instead
        403 local_address | 400 bad_url | 502 unreachable | search_failed   a web call that couldn't be made, with its fix
        409 chrome_not_open | no_window | no_chrome                 Chrome isn't there to read; 403 javascript_off | not_allowed: what to switch on
        409 no_folder                                               no scripts folder is chosen yet
        409 still_waiting | still_running                           a request that can't be cleared yet (its caller waits on it; it's running)
        413 too_large                                               a body over 8 MB
        503 endpoint_off                                            that group is switched off in the app
        500 failed

        ## Access

        \(access)

        ## Examples

        curl -s "\(baseURL)/api/search?q=remember+a+birthday"
        curl -s "\(baseURL)/api/endpoints?brief=true"
        curl -s \(baseURL)/api/scripts
        curl -s \(baseURL)/api/run -d '{"script": "hello.sh", "args": ["world"], "client": "My App", "why": "You pressed Greet"}'
        curl -sN \(baseURL)/api/run -d '{"script": "backup.sh", "stream": true, "client": "My App", "why": "Nightly backup, from the Backup Now button"}'
        curl -si \(baseURL)/api/run -d '{"script": "backup.sh", "async": true, "client": "My App", "why": "Nightly backup"}'   # 202 now, with X-Request-Id
        curl -s \(baseURL)/api/requests/<the id>                    # once it's over, the first read hands over the result
        curl -s \(baseURL)/api/requests/open                        # what you haven't collected yet, oldest first
        curl -s \(baseURL)/api/compose -d '{"source": "print \\"hi\\"", "name": "Say hi", "client": "My App"}'
        curl -s \(baseURL)/api/library -d '{"op": "write", "name": "groceries", "text": "- eggs\\n- milk\\n"}'
        curl -s \(baseURL)/api/library -d '{"op": "search", "q": "milk"}'
        curl -s \(baseURL)/api/library/files/groceries?format=text
        curl -s -X DELETE \(baseURL)/api/library/files/groceries      # to the library's Trash
        curl -s \(baseURL)/api/memory/remember -d '{"category": "PEOPLE", "about": "Ada Lovelace", "text": "Met at the conference", "client": "My App"}'
        curl -s "\(baseURL)/api/memory/recall?name=ada"
        curl -s \(baseURL)/api/mind/add -d '{"from": "ada lovelace", "label": "works at", "to": "acme"}'
        curl -s \(baseURL)/api/mind/query -d '{"q": "| x - works at | acme"}'
        curl -s \(baseURL)/api/present -d '{"shelf": "memory", "name": "PEOPLE", "why": "To check the details"}'
        curl -s "\(baseURL)/api/browser/has?text=Compute"
        curl -s \(baseURL)/api/straw/check -d '{"source": "open example.com\\nread title"}'
        curl -s \(baseURL)/api/automation -d '{"script": "backup.sh", "automation": ["every evening"], "client": "My App", "why": "So the backup never waits on anyone"}'
        """
    }
}
