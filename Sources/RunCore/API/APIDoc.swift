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

        ## Endpoints, by group

        GET /api/endpoints gives this list as JSON ({"groups": [{"id", "title", "about", "routes": [{"method", "path", "summary", "asks_on_the_mac"}]}]}).

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

        ## Straw: Chrome by what's on the page

        Straw scripts (.straw, in the browser folder) drive Google Chrome by naming what's on the page: open news.ycombinator.com, click "More", type "Search" "cats", read all css ".titleline > a". GET /api/straw lists the 25 words (each with what it takes, what it does and an example) and the Straw scripts in the folder. POST /api/straw/check {"source": "<Straw code>"} checks it without running anything → {"ok": true, "steps", "plan": [lines]} or {"ok": false, "code": "straw_mistake", "line", "error", "fix"}. POST /api/straw/run {"script": "hacker-news"} runs one, or {"source": "<Straw code>", "name"?} runs code you send (checked first: a mistake is 400 and nothing is asked); it waits for Run on the Mac like /api/run (the card shows your code in full), and takes the same "args", "why", "wait", "async" and "stream". What a Straw script reads is its output; what it's doing (a line a step) is its stderr.

        ## Request ids

        Every request that reaches the card (/api/run, /api/compose, /api/automation) gets an id the moment it arrives: the X-Request-Id header of the answer, "request" in its JSON (the run's JSON, the 202, the 403 for Don't Run), and "request" on every line of a stream. Keep it: whether you waited, streamed, hung up, or sent "async": true, GET /api/requests/{id} answers for it while the app runs (the latest 500):
        {"request", "state", "ok"?, "kind": "script"|"flow"|"automation"|"stop", "name", "via": "run"|"compose"|"automation"|"stop", "client", "from", "why"?, "asked", "answered"?, "run_id"?, "run_url"?, "run"?, "code"?, "error"?, "url"}
        - state: waiting (on the Mac, no click yet) | denied | not_answered | running | succeeded | failed | stopped | could_not_start | automated | gone (the run was cleared from the app's history). A stop request ("kind": "stop") that was allowed is stopped.
        - ok: once it's over (true for succeeded and automated); absent while waiting or running.
        - run: once started, the run itself with everything it printed, as /api/runs/{id} gives it. code, error: when it didn't run.
        Poll it as often as you like (nothing runs for the asking). GET /api/requests?limit=20 lists the latest, without "run". An unknown id is 404 unknown_request. Runs carry "request" too.

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

        {"error": "what went wrong", "code": "…"}
        400 missing_script | missing_flow | bad_args | bad_request    the request isn't right
        400 unknown_tag                                             no such automation tag ("error" lists them)
        400 flow_mistake                                            the Flow code has a mistake (with "line" and "fix")
        401 unauthorized                                            sharing on the network is on and no token was sent
        403 denied | not_answered                                   it didn't run
        403 forbidden                                               a page from another site, a Host that isn't this Mac, or another machine while sharing is off
        400 missing_op | unknown_op | bad_name                       a library call that isn't right (see The file library)
        400 straw_mistake                                           the Straw code has a mistake (with "line" and "fix")
        404 not_found | unknown_script | unknown_flow | unknown_run | unknown_request
        409 already_exists                                          a library note of that name is there already
        409 no_folder                                               no scripts folder is chosen yet
        413 too_large                                               a body over 8 MB
        503 endpoint_off                                            that group is switched off in the app
        500 failed

        ## Access

        \(access)

        ## Examples

        curl -s \(baseURL)/api/endpoints
        curl -s \(baseURL)/api/scripts
        curl -s \(baseURL)/api/run -d '{"script": "hello.sh", "args": ["world"], "client": "My App", "why": "You pressed Greet"}'
        curl -sN \(baseURL)/api/run -d '{"script": "backup.sh", "stream": true, "client": "My App", "why": "Nightly backup, from the Backup Now button"}'
        curl -si \(baseURL)/api/run -d '{"script": "backup.sh", "async": true, "client": "My App", "why": "Nightly backup"}'   # 202 now, with X-Request-Id
        curl -s \(baseURL)/api/requests/<the id>
        curl -s \(baseURL)/api/compose -d '{"source": "print \\"hi\\"", "name": "Say hi", "client": "My App"}'
        curl -s \(baseURL)/api/library -d '{"op": "write", "name": "groceries", "text": "- eggs\\n- milk\\n"}'
        curl -s \(baseURL)/api/library -d '{"op": "search", "q": "milk"}'
        curl -s \(baseURL)/api/library/files/groceries?format=text
        curl -s -X DELETE \(baseURL)/api/library/files/groceries      # to the library's Trash
        curl -s \(baseURL)/api/straw/check -d '{"source": "open example.com\\nread title"}'
        curl -s \(baseURL)/api/automation -d '{"script": "backup.sh", "automation": ["every evening"], "client": "My App", "why": "So the backup never waits on anyone"}'
        """
    }
}
