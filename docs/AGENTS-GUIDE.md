# Using the API from an agent

How an assistant that runs on this Mac (Super Voice's **Tom** and **Jerry**, or any agent with
tools) should use Tool Mac Tool Run's HTTP API, and in particular the **request id** every
request gets: the one thing to keep, and the one thing to ask about later.

The contract itself is [API.md](../API.md); this guide is the way to use it from an agent loop.
`GET /api/doc` serves the same contract compacted to one page, with this Mac's address filled in.

```
Base URL   http://127.0.0.1:8768
```

**A small model, or one whose attention belongs to its task, doesn't need any of this.** It can
talk to [Peter](https://github.com/ainigh/tool-mac-tool-run-agent) (Tool Mac Agent) in plain
words: `POST http://127.0.0.1:8770/api/say` takes what it wants as text and answers in text,
reading it into this API's calls, following runs itself and calling the client back when they're
over. No ids, no polling, no JSON. Its instructions need one line: *"To get anything done on the
Mac or the web, ask Peter in plain words. If he answers with templates, fill one in and say it
back."* → SYSTEM-DOCS' PROMPT-SMALL-MODEL.
What follows is for an agent that makes the calls itself.

## In one minute

```bash
# 1. Ask for a run and come straight back with its id (nothing has run yet: the card is on the Mac)
curl -si localhost:8768/api/run -d '{"script": "backup.sh", "async": true, "client": "Super Voice", "why": "You asked Tom to back up before the trip"}'
# HTTP/1.1 202 Accepted
# X-Request-Id: 2A7C4B19-5E0D-4F3A-9C2B-7D1E8F6A0B34
# {"request":"2A7C4B19-…","state":"waiting","url":"/api/requests/2A7C4B19-…","message":"On the Mac, waiting for Run; …"}

# 2. Any time later, from any turn, any process: where is it?
curl -s localhost:8768/api/requests/2A7C4B19-5E0D-4F3A-9C2B-7D1E8F6A0B34
# {"request":"2A7C4B19-…","state":"waiting", …}      the person hasn't clicked yet
# {"request":"2A7C4B19-…","state":"running","run_id":"6C1D…","run":{"output":"Copying…"}, …}
# {"request":"2A7C4B19-…","state":"succeeded","ok":true,"run":{"code":0,"output":"Done. 1,204 files.\n", …}, …}
# {"request":"2A7C4B19-…","state":"denied","ok":false,"code":"denied","error":"backup.sh didn't run: the person at the Mac chose Don't Run"}
```

```bash
# 3. Lost track? What you've asked for and not collected yet, oldest first
curl -s localhost:8768/api/requests/open
# {"count":2,"waiting":1,"running":0,"ready":1,"requests":[{"position":1,"request":"2A7C…","state":"succeeded","delivery":"ready",…},…]}

# 4. Don't know the route? Ask by a few words; every answer's "next" says what usually comes after it
curl -s "localhost:8768/api/search?q=remember+a+birthday"
```

Four things an agent must know, and nothing else is a surprise:

1. **Nothing runs without the person's click.** Every run request puts a card on the Mac; the
   person clicks **Run** or **Don't Run**, and no click in two minutes is Don't Run. The agent
   can't click, and shouldn't pretend it has: say "it's waiting for you to click Run".
2. **Send `client` and `why` with every run.** `client` names the agent on the card ("Super Voice
   wants to run a script"); `why` is why, in the user's terms ("You asked Tom to back up before
   the trip"). The card says when an app gave no reason, and that makes Don't Run likelier.
3. **Keep the request id.** It's in every answer (`X-Request-Id`, and `request` in the JSON), the
   moment the request arrives, whether it was allowed or not. It is the handle for everything
   after: the agent's turn can end, the connection can drop, another process can take over, and
   `GET /api/requests/{id}` still answers for it.
4. **Each result is handed over once.** Once the request is over, the first read of
   `GET /api/requests/{id}` carries the result (`"delivery": "delivered"`, with `run`) and clears
   it; read again, it says how it ended without the output. So use the output the first time you
   get it. `GET /api/requests/open` is everything not collected yet, oldest first.

## Finding your way without the whole contract

An agent with a short context shouldn't load `/api/endpoints` (over a hundred routes) or
`/api/doc`. Two things make that unnecessary:

- **`GET /api/search?q=<a few words>`** answers only the routes, scripts and flows that match, the
  best first. Routes are found by their tags too (the words someone would say: "status", "job",
  "cancel", "birthday"), and scripts by their header's `# Tags:` line. A script or flow comes
  back with `"run"`: the request that runs it, its inputs as `<placeholders>`. `?in=scripts`,
  `?group=memory` and `?limit` narrow it.
- **`"next"` on every JSON answer**: a few `{"method", "path", "why"}` calls that usually follow,
  with ids filled in. After a 202, it's where to ask about the request and how to take it back;
  after a run, the run and the open requests; after a 404, a search for the path's words.

`GET /api/endpoints?brief=true` (the groups, each with its route count and words) is the fallback
when a search finds nothing.

## The request id

A request is anything that reaches the card: `POST /api/run` (a script), `POST /api/compose` (a
flow, or Flow code the agent writes) (running something later, or every day, is Peter's).
Each gets a UUID as it arrives, before anyone has clicked. You get it back:

| where | as |
|---|---|
| the HTTP answer, whatever its status | the `X-Request-Id` header |
| a run's JSON (the default, waited-for answer) | `request` |
| the `202` of `"wait": false` or `"async": true` | `request` |
| the `403` for Don't Run or no answer | `request` (with `code` and `error`) |
| a stream (`"stream": true`) | `request` on its `waiting`, `started`, `done`, `denied` and `error` lines (and the `X-Request-Id` header) |
| a run read later (`/api/runs`, `/api/runs/{id}`) | `request` |

Then `GET /api/requests/{id}` answers for it for as long as the app runs (the latest 500):

```json
{
  "request": "2A7C4B19-…", "state": "succeeded", "ok": true,
  "kind": "script", "name": "backup.sh", "via": "run",
  "client": "Super Voice", "from": "this Mac", "why": "You asked Tom to back up before the trip",
  "asked": "2026-10-23T09:12:00.004Z", "answered": "2026-10-23T09:12:07.318Z",
  "run_id": "6C1D2F0E-…", "run_url": "/api/runs/6C1D2F0E-…", "url": "/api/requests/2A7C4B19-…",
  "run": {"id": "6C1D2F0E-…", "state": "succeeded", "ok": true, "code": 0, "seconds": 41.2,
          "output": "Done. 1,204 files.\n", "stdout": "…", "stderr": "", "steps": […]}
}
```

### The states, and what an agent does with each

| `state` | it means | the agent |
|---|---|---|
| `waiting` | the card is on the Mac; no click yet | says so to the user; asks again later (`answered` is absent) |
| `denied` | the person clicked Don't Run | stops; doesn't ask the same thing again unprompted. `error` is a sentence to relay |
| `not_answered` | no click in two minutes | tells the user it timed out and can be sent again; doesn't resend by itself |
| `running` | started; `run.output` is what it has printed so far | waits; `run_id` can stop it (`POST /api/runs/{run_id}/stop`) |
| `succeeded` | done, exit code 0; `ok: true` | relays `run.output` (cut it short when long) |
| `failed` | done, not 0; `run.code`, `run.stderr`, `run.problem` | relays what went wrong, from `stderr`/`problem` first |
| `stopped` | someone stopped it (the agent, or the person in Runs) | says it was stopped |
| `could_not_start` | allowed, but it couldn't start (a missing `python3`, a flow that doesn't check…); `error`/`run.problem` says why and the fix | relays the fix |
| `withdrawn` | the agent took it back (`DELETE /api/requests/{id}`) before the click | nothing ran; says so if asked |
| `gone` | the run was cleared from the app's history (Clear Finished) | treats it as finished with an unknown result |

`ok` is present only once it's over: `true` for `succeeded` and `automated`, `false` for the
rest. So the loop is: **while `ok` is absent, it's still going.**

A request that didn't run keeps answering the same way: `denied` stays `denied`.

### `delivery`: collecting the result once

Beside `state`, every answer about a request says where its result is:

| `delivery` | it means | the agent |
|---|---|---|
| `pending` | waiting for the click, or running | asks again later; `run.output` is what it has printed so far |
| `delivered` | this answer is the result, handed over once; it's cleared now | uses it now (relays `run.output`, keeps what it needs) |
| `cleared` | handed over before (or cleared without it) | has it already; `state`/`ok` still say how it ended; `run_url` still has the run while the app keeps it |
| `ready` | over, not collected (in `/api/requests/open`, or read with `?peek=true`) | reads its `url` to collect it |

A waited-for, streamed or refused request is `delivered` in its own answer, so it never shows in
`/api/requests/open`. An async one stays there until the agent collects it, or clears it without
reading (`DELETE /api/requests/{id}`, or `POST /api/requests/clear` for all that are over). A
`DELETE` on one still waiting for the click takes it back: the card goes, nothing runs.

### Lifecycle

```
POST /api/run ──▶ waiting ──▶ (Don't Run)  denied        ok: false
  "async": true     │        (no click)   not_answered   ok: false
  202 + request     │
                    └──▶ (Run) running ──▶ succeeded     ok: true
                               │           failed        ok: false
                               │           stopped       ok: false
                               └──────▶    could_not_start ok: false
                                           (later: gone, if the run is cleared)
```

## Three ways to run, and which one an agent picks

| way | the call | answers | pick it when |
|---|---|---|---|
| **wait** (default) | `{"script": …}` | once the run has ended, with everything | the script is short and the agent can hold the connection (it's what Super Voice's `run_script` does today, with a 15-minute timeout) |
| **async** | `{"script": …, "async": true}` | now (`202`), with `request` and `state: "waiting"` | the agent's turn must end (a supervisor/worker loop, a tool call that can't block), the run is long, or the person may take a while to click. **This is the one for agents.** |
| **stream** | `{"script": …, "stream": true}` | now, then one JSON line per event | a UI that shows output as it prints |

`"wait": false` is the older middle: it answers `202` once the person has clicked, with the run's
`id`. It still works and still means that; `async` is what you want when you don't want to wait
for the click either.

With **async**, polling is the whole protocol: `GET /api/requests/{id}` every second or two is
fine (nothing runs for the asking, and the answer is small while it's `waiting`). When the agent
needs the output, read `run.output` from the same answer; `GET /api/runs/{run_id}` is the same
run with the same fields.

## Super Voice: Tom, Jerry and the job record

Super Voice's [Supervisor/Worker design](https://github.com/ainigh/super-mac-tts-stt-service/blob/main/Supervisor-Worker%20Agent%20Design.md)
already has the shape this API wants: a job record the harness owns, a status the harness
writes, `get_status(job_id)` for Tom, and an approval gate before any real tool runs. The request
id slots in as the one field that ties a job to what Tool Mac Tool Run is doing.

**Jerry proposes, the harness runs, the request id is the receipt.** When Jerry's tool call is
`run_script`/`run_flow`/`run_flow_code`, the harness sends it with `"async": true` and records
the `request` on the job:

```yaml
job:
  id: j17
  status: awaiting_approval          # the card is on the Mac (Tool Mac Tool Run's own gate)
  tool_run:
    request_id: 2A7C4B19-…           # from the 202's "request" / X-Request-Id
    request_url: /api/requests/2A7C4B19-…
    state: waiting                   # mirrored from GET /api/requests/{id}
    run_id: null                     # filled in once it's "running"
```

Then the harness polls `/api/requests/{id}` and mirrors `state` into the job (writing status is
the harness's job, never a model's, as the design says). The mapping:

| `/api/requests/{id}` says | job `status` | L3 event |
|---|---|---|
| `waiting` | `awaiting_approval` | `tool_proposed` (already written when the call was sent) |
| `denied`, `not_answered` | `running` (Jerry gets the rejection as the tool result) | `tool_rejected` |
| `running` | `running` | `tool_approved` |
| `succeeded`, `failed`, `stopped`, `could_not_start`, `gone` | `running` (Jerry gets the result) | `tool_result` |

Two things this buys the design:

- **Tom's `get_status(job_id)` is honest without Jerry's help**: the harness answers it from the
  job record, which it keeps current from `/api/requests/{id}`. Tom can tell the user "the backup
  is still waiting for you to click Run" or "it's running, 40 seconds in" between Jerry's turns.
- **Nothing is lost when a turn ends.** Jerry's loop doesn't have to hold a connection for up to
  15 minutes inside one tool call. The call returns the id at once; the result arrives as a later
  event (`tool_result`), which queues a Tom turn as any event does.

**Don't put request ids in Tom's memory.** They live as long as the app runs (the latest 500) and
mean nothing after it restarts. The job record is the right place; memory is for what Tom learned
("Jerry's backup script takes about a minute").

**The user still clicks.** Tool Mac Tool Run's card is the approval gate for *these* tools: the
harness doesn't need its own approval step in front of them (that would be two clicks for one
run). Record `tool_proposed` when the call is sent, and let the card's answer write
`tool_approved`/`tool_rejected`.

### What to change in `ToolRun.swift`

Super Voice's client (`Sources/VoiceCore/ToolRun.swift`) runs scripts with the default wait, up to
15 minutes, and tells the model the run's `id` at the end. Three small changes make it fit the
loop above. Shapes only; the names are suggestions.

1. **`run_script`, `run_flow`, `run_flow_code` send `"async": true` and return the request id.**

```swift
case "run_script":
    guard let script = string(arguments["script"] ?? arguments["name"]) else { return "Say which script: its name from list_scripts." }
    var body: [String: Any] = ["script": script, "async": true]
    if let args = list(arguments["args"] ?? arguments["arguments"]) { body["args"] = args }
    if let stdin = string(arguments["stdin"] ?? arguments["input"]) { body["stdin"] = stdin }
    if let why = string(arguments["why"]) { body["why"] = why }   // let the model say why; the card shows it
    let (status, json) = try await runner.call("POST", "/api/run", body: body)
    if let trouble = trouble(status, json) { return trouble }
    let id = (json["request"] as? String) ?? "?"
    return "Sent. It's on the user's Mac waiting for them to click Run. Request id \(id): use check_request with it to see how it goes."
```

   The tool's description should say the same: *"Starts one of the user's scripts and gives back
   a request id at once. Nothing runs until the user clicks Run on their Mac. Use `check_request`
   to see whether they clicked, and how it went."* Add a `why` argument (*"why the user wants
   this, in their words; shown on the card"*).

2. **A `check_request` tool** (and the harness's own poll uses the same call):

```swift
AssistantTools.Tool(name: "check_request",
    description: "Where a run request is: waiting for the user to click Run, denied, running, or how it ended, with what it printed. Use the request id run_script gave you.",
    arguments: [("id", "string: the request id")]),

case "check_request":
    guard let id = string(arguments["id"] ?? arguments["request"]) else { return "Give the request id." }
    let (status, json) = try await runner.call("GET", "/api/requests/\(ToolRunTools.escaped(id))", body: nil)
    if let trouble = trouble(status, json) { return trouble }
    let state = (json["state"] as? String) ?? "unknown"
    switch state {
    case "waiting": return "Still waiting for the user to click Run on their Mac."
    case "denied": return "It didn't run: the user clicked Don't Run."
    case "not_answered": return "It didn't run: no one clicked Run within two minutes. Ask the user before sending it again."
    case "automated": return "Allowed: it's tagged to run by itself now."
    case "gone": return "It ran, but the run has been cleared from Tool Mac Tool Run's history, so its output is gone."
    case _ where json["delivery"] as? String == "cleared":
        return "\(state): its result was handed over already (it's given once)."
    default:
        if let run = json["run"] as? [String: Any] { return outcome(run) }   // running, succeeded, failed, stopped, could_not_start
        return "\(state): \((json["error"] as? String) ?? "")"
    }
```

   `outcome(run)` is the function the client already has: it writes the state, exit code, time,
   run id and output for the model. While `running`, it shows the output so far. Once it's over,
   `run` comes once: the read that hands it over (`"delivery": "delivered"`); so if the harness
   polls too, it's the harness that keeps the output on the job record for the model.

3. **`trouble` knows `unknown_request`**, and the timeout can come down:

```swift
case "unknown_script", "unknown_flow", "unknown_run", "unknown_request": return error
```

   With `async`, `/api/run` answers in milliseconds, so `runTimeout` (15 minutes) is only needed
   if a wait-mode tool is kept; `timeout` (15 s) does for everything else.

Keep `read_run`, `list_runs` and `stop_run` as they are: `check_request` gives `run_id` for
`stop_run`, and runs now carry `request` so the two lists cross-reference.

### Telling the user

The model talks; these are the sentences that match each state and never claim more than is true:

- `waiting`: "It's on your Mac, waiting for you to click Run."
- `running`: "It's running (40 seconds so far). It's printed: …"
- `succeeded`: "Done: …" (what it printed, cut short when long).
- `failed`: "It failed with exit code 3: …" (from `stderr`, else `problem`, else the output).
- `denied`: "You clicked Don't Run, so it didn't run." (and leave it there).
- `not_answered`: "Nobody clicked Run within two minutes, so it didn't run. Want me to send it again?"
- `could_not_start`: "It couldn't start: python3 isn't installed. The fix: brew install python."
- `gone`: "It ran, but its output has been cleared from the app's history."
- `withdrawn`: "I took that back before you clicked, so nothing ran."

The card already told the person *who* asked (`client`) and *why* (`why`); the agent repeating
the why in chat is fine, inventing a different one is not.

## Checking before running

- `GET /api/scripts` and `GET /api/flows` list what there is, with `summary` (what it does),
  `dangers` (what it looks like it does that can't be undone, shown on the card too) and `inputs`
  (what it takes: `prompt`, `kind` `argument` or `stdin`, `optional`, `why`). An agent that reads
  `inputs` can ask the user for exactly what the script needs before sending it.
- `POST /api/check` checks Flow code the agent wrote without running or asking anything. Do it
  before `/api/compose` with `source`: a mistake comes back with `line` and `fix`, and the user
  never sees a card for code that wouldn't run.
- A name works with or without its extension, and a utility or browser script by its file name
  alone (`"speak"` for `utilities/speak.sh`).

## The file library: memory that needs no click

The person's notes, **LIBRARY** in TOOL-MAC-RUN on their Desktop, are a key-value store an agent can use without
a card: a note is a name (no `.md`) and its text. Everything is one endpoint, answered at once:

```bash
curl -s localhost:8768/api/library -d '{"op": "write", "name": "Agent notes", "text": "- the user prefers metric\n", "client": "My Agent"}'
curl -s localhost:8768/api/library -d '{"op": "append", "name": "Agent notes", "text": "- flight on Friday"}'
curl -s localhost:8768/api/library -d '{"op": "read", "name": "Agent notes"}'          # {"text": …}
curl -s localhost:8768/api/library -d '{"op": "find", "q": "flight"}'                  # {"names": […], the best first}
curl -s localhost:8768/api/library -d '{"op": "search", "q": "\"flight on\""}'        # every line it's on
```

- Each call has an id too (`request`, `X-Request-Id`); `GET /api/requests/{id}` answers for it,
  as `{"kind": "library", "op", "ok", "summary"}`. There's nothing to poll: the answer is final.
- `read` of a name that isn't there is `404 not_found` with `fix` naming the notes near it: use
  one of those, or `find` first. Never guess a name.
- `delete` moves a note to the library's own Trash (`restore` brings it back), so a mistake can be
  undone; still, replace or delete only what the user asked about. Prefer `append` for adding to
  a note over `write`, which replaces it.
- `GET /api/library` lists every operation with the fields it takes.

## MEMORY and the mind: remembering without a click

Beyond the library, **MEMORY** (a file for each kind of thing: PEOPLE, ORGANIZATIONS, EVENT-DATES,
BIRTHDAYS, LOCATIONS, IDEAS, LEVERAGE, STRATEGIES, OTHERS) and **the mind** (what links to what,
append only) answer at once too. An agent's habit:

```bash
curl -s "localhost:8768/api/memory/recall?name=ada"                       # before answering about anyone
curl -s localhost:8768/api/memory/remember -d '{"category": "PEOPLE", "about": "Ada Lovelace", "text": "Lead engineer at Acme", "client": "My Agent"}'
curl -s localhost:8768/api/mind/add -d '{"from": "ada lovelace", "label": "works at", "to": "acme"}'
curl -s "localhost:8768/api/memory/upcoming?days=14"                      # what's coming up
```

- Recall first; remember only what the user said (the mind's log keeps every line).
- `POST /api/mind/append {"text": "<a model's reply>"}` takes a ```` ```mm ```` block as it is;
  one bad line writes nothing, and `problems` says each fix. `POST /api/mind/check` first, if unsure.
- `GET /api/system-docs/files/PROMPT-ASSISTANT` is a system prompt for exactly this; `RECIPES` and
  `EXCHANGES` show the calls for the usual questions.

## Showing, copying, and guiding through a site

- `POST /api/present {"title", "text", "why"}` (or `{"shelf": "memory", "name": "PEOPLE"}`, or
  `{"mind": "ada"}`) puts it in a window in front of everything, with copy buttons. `"present": true`
  on any read does the same with its answer; `"copy": true` puts it on the clipboard.
- `GET /api/browser/url`, `/page`, `/has?text=…` (true or false), `/find?text=…` (where it is, as a
  sentence), `POST /api/browser/highlight {"text"}` (a red ring on the page): the page in Chrome.
  `POST /api/browser/open {"url"}` opens one for the person, in a new tab, and reads it back. Look
  again after each step; never say something is on the page that `has` or `find` didn't find.
  `PROMPT-SITE-GUIDE` in SYSTEM-DOCS is the prompt for it. It never clicks or types: Straw does,
  after Run on the Mac.
- `GET /api/web/search?q=…` and `GET /api/web/fetch?url=…` (`&find=words`) find things out on the
  web without Chrome, at once: a page's text and links, or a JSON API's answer.

## Tools, for a model

`GET /api/tools` is the whole API as a short list of tools a model calls by name, each with its
arguments, with a `guide` and `examples` to put in its instructions; `POST /api/tools/{name}
{"arguments": {…}}` calls one, and answers with the route's own JSON. An agent loop that hands
its model the list and passes its calls through needs no wrapper of its own, and gets whatever is
added here the day it ships.

## Straw: driving Chrome

`GET /api/straw` lists Straw's words; `POST /api/straw/check {"source"}` checks Straw code an
agent wrote without running or asking anything (its mistake comes back with `line` and `fix`);
`POST /api/straw/run {"source", "name", "client", "why", "async": true}` runs it in Chrome once the
person clicks Run, with the request id like any run. What the script `read`s is its output.

## When things aren't there

| what happened | you see | do |
|---|---|---|
| the app restarted since the request | `404 unknown_request` | the request is gone; `GET /api/runs?limit=20` still lists the runs it started, with `request` on each, so a run that finished can be found by name and time |
| the run was cleared (Clear Finished) | `state: "gone"` | treat it as finished with an unknown result |
| the API group is off in the app's panel | `503 endpoint_off` | tell the user which switch (`error` names it) |
| no scripts folder chosen yet | `409 no_folder` | tell the user to pick one in the app's panel |
| the app isn't running | the connection is refused | say so; nothing to poll |
| the agent is on another device | `401 unauthorized` | the token from the app's panel, as `Authorization: Bearer <token>`; the request id works the same from there, and the card says which device asked |

## Cheat sheet

```bash
# start, come back with the id
curl -si localhost:8768/api/run -d '{"script": "backup.sh", "async": true, "client": "My Agent", "why": "…"}'
curl -si localhost:8768/api/compose -d '{"flow": "morning.flow", "async": true, "client": "My Agent", "why": "…"}'
curl -si localhost:8768/api/compose -d '{"source": "run \"hello.sh\" [] |> print", "name": "Say hi", "async": true, "client": "My Agent", "why": "…"}'

# where is it (poll this; once it's over, the first read hands over the result)
curl -s localhost:8768/api/requests/<request id>
curl -s "localhost:8768/api/requests/<request id>?peek=true"   # look without taking it
curl -s localhost:8768/api/requests/open                       # not collected yet, oldest first
curl -s -X DELETE localhost:8768/api/requests/<request id>     # clear it; still waiting for the click: take it back
curl -s localhost:8768/api/requests?limit=20                   # history, cleared or not

# find the call (or the script) for something, by a few words
curl -s "localhost:8768/api/search?q=weather&in=scripts"

# the run itself, and stopping it
curl -s localhost:8768/api/runs/<run_id>
curl -s -X POST localhost:8768/api/runs/<run_id>/stop   # one the person started asks them first (Stop It / Keep Running)

# before running
curl -s localhost:8768/api/scripts
curl -s localhost:8768/api/flows
curl -s localhost:8768/api/check -d '{"source": "let x = 1"}'

# the file library (no click): write, read, find
curl -s localhost:8768/api/library -d '{"op": "write", "name": "Agent notes", "text": "…", "client": "My Agent"}'
curl -s localhost:8768/api/library -d '{"op": "read", "name": "Agent notes"}'
curl -s localhost:8768/api/library -d '{"op": "find", "q": "flight"}'

# every route, in its groups (?brief=true: the groups alone); the whole contract in one page, with this Mac's address
curl -s localhost:8768/api/endpoints
curl -s localhost:8768/api/doc
```
