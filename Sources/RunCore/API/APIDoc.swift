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

        NOTHING RUNS WITHOUT THE PERSON'S CLICK. Every run request shows a card on the Mac naming your app and what would run; your request waits until the person clicks Run (or Don't Run; no click in two minutes is Don't Run). Send "client": "Your App's Name" so the card says who's asking.
        EVERY REQUEST HAS AN ID you can depend on: it comes back at once (the X-Request-Id header, and "request" in the JSON of every answer, refusals included), and GET /api/requests/{id} says where it is any time later: waiting for the click, denied, running, how it ended. Send "async": true to get the id now and not wait at all.

        ## Endpoints

        GET  /api/health              is it up, which groups are on, the folder, how many scripts and flows
        GET  /api/scripts             the scripts: name, title, group, language, language_name, summary, asks_for_input, dangers, uses_epa, inputs
                                      (?group=utilities or ?group=browser: only that grid's)
        GET  /api/flows               the flows: name, title, summary, uses_epa, inputs
                                      (inputs: what each takes, in order: {"prompt", "kind": "argument"|"stdin", "optional", "why"?})
        POST /api/run                 run a script  {"script", "args"?, "stdin"?, "client"?, "why"?, "wait"?, "async"?, "stream"?, "automation"?}
        POST /api/compose             run a flow    {"flow", "args"?, "client"?, "why"?, "wait"?, "async"?, "stream"?, "automation"?}
                                      or Flow code  {"source", "name"?, …} (a text/plain body is the source)
        POST /api/check               check Flow code without running it  {"source"} → {"ok": true, "bindings": [{"name", "type", "line"}]} or {"ok": false, "code": "flow_mistake", "error", "message", "line", "fix"}
        GET  /api/automation          the automation tags there are, and the items that run by themselves (see Automation)
        POST /api/automation          tag a script or a flow to run by itself  {"script"|"flow", "automation": [tags], "once"?, "after"?}
        GET  /api/requests/{id}       where a request is (see Request ids): {"request", "state", "ok"?, "run_id"?, "run_url"?, "run"?, …}
        GET  /api/requests?limit=20   the latest requests, newest first, without their runs' output
        GET  /api/runs?limit=20       the latest runs, newest first, without their output
        GET  /api/runs/{id}           one run, with output, stdout, stderr (and a flow's steps)
        POST /api/runs/{id}/stop      stop it → {"ok": true, "stopping": true|false}; a run the person started (not one an app asked for) waits for Stop It on the Mac (send "client", "why")
        GET  /api/doc                 this page (text/markdown)
        GET  /                        a status page in a browser, with a place to try a script or Flow code

        Each group (run, compose, catalog, runs) can be switched off in the app: it then answers 503 {"code": "endpoint_off"}. A refused connection means the app isn't running or its API is stopped.

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
        404 not_found | unknown_script | unknown_flow | unknown_run | unknown_request
        409 no_folder                                               no scripts folder is chosen yet
        413 too_large                                               a body over 8 MB
        503 endpoint_off                                            that group is switched off in the app
        500 failed

        ## Access

        \(access)

        ## Examples

        curl -s \(baseURL)/api/scripts
        curl -s \(baseURL)/api/run -d '{"script": "hello.sh", "args": ["world"], "client": "My App", "why": "You pressed Greet"}'
        curl -sN \(baseURL)/api/run -d '{"script": "backup.sh", "stream": true, "client": "My App", "why": "Nightly backup, from the Backup Now button"}'
        curl -si \(baseURL)/api/run -d '{"script": "backup.sh", "async": true, "client": "My App", "why": "Nightly backup"}'   # 202 now, with X-Request-Id
        curl -s \(baseURL)/api/requests/<the id>
        curl -s \(baseURL)/api/compose -d '{"source": "print \\"hi\\"", "name": "Say hi", "client": "My App"}'
        curl -s \(baseURL)/api/automation -d '{"script": "backup.sh", "automation": ["every evening"], "client": "My App", "why": "So the backup never waits on anyone"}'
        """
    }
}
