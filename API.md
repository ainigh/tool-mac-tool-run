# Tool Mac Tool Run API

Tool Mac Tool Run is a menu bar app for the Mac that runs your scripts (bash, Python, Node…) and
your **flows** (scripts composed in the Flow language). It serves both to other apps over HTTP,
the way [Super Voice](https://github.com/ainigh/super-mac-tts-stt-service) serves speech:

- **List** the scripts and flows in the person's scripts folder.
- **Run** a script, a flow, or Flow code your app sends, and get back how it went and everything
  it printed (all at once, or streamed as it prints).
- **Read** the runs, and stop one.
- **Automate**: tag a script or a flow to run by itself, on a schedule or when something happens.

**Nothing runs without the person's say-so.** Every run request shows a large card on the Mac
naming your app, why it wants the run (your `why`, in your words; the card says when you gave
none), what would run (the exact command, or your Flow code in full) and anything it looks like
it does that can't be undone, with **Run** and **Don't Run**. Your request waits for the click.
No click in two minutes is Don't Run. **Send `why` with every run**: it's what the person reads
before deciding.

This document is the contract for client apps. New fields may be added to responses, but nothing
listed here changes meaning.

```
Base URL   http://127.0.0.1:8768
```

**The same, in one page:** `GET /api/doc` answers this contract compacted to a page of text (every
endpoint, field, event and error, with the address you reached it at and, from another device,
the token to send), as does **Copy API Doc** in the app's panel. Paste it into your app's code, its
README, or a chat with an assistant writing the client for you.

## In one minute

```bash
# is it there, and what's on?
curl -s localhost:8768/api/health

# the scripts in the folder
curl -s localhost:8768/api/scripts

# run one (waits for Run on the Mac, then for the script to end)
curl -s localhost:8768/api/run -d '{"script": "hello.sh", "args": ["world"], "client": "My App", "why": "You pressed Greet in My App"}'
# {"id":"…","name":"hello.sh","state":"succeeded","ok":true,"code":0,"seconds":0.04,
#  "output":"Hello, world!\n","stdout":"Hello, world!\n","stderr":"", …}

# the same, sent as it prints (NDJSON, one event a line)
curl -sN localhost:8768/api/run -d '{"script": "backup.sh", "stream": true}'

# run a flow from the folder, or Flow code you send
curl -s localhost:8768/api/compose -d '{"flow": "morning.flow"}'
curl -s localhost:8768/api/compose -H 'Content-Type: text/plain' --data-binary @mine.flow

# check Flow code without running anything (nothing is asked on the Mac)
curl -s localhost:8768/api/check -d '{"source": "let double x = x * 2"}'

# tag a script to run by itself every evening (waits for Allow on the Mac; nothing runs now)
curl -s localhost:8768/api/automation -d '{"script": "backup.sh", "automation": ["every evening"], "client": "My App", "why": "So the backup never waits on anyone"}'
```

## Endpoints

| route | switch | does |
|---|---|---|
| `GET  /api/health` | — | whether it's up, which endpoints are on, the folder |
| `GET  /api/scripts` | `catalog` | the scripts in the folder (and its utilities and browser scripts): name, group, language, description, what they look like they do |
| `GET  /api/flows` | `catalog` | the flows in the folder's `composer` folder |
| `POST /api/run` | `run` | runs a script once it's allowed on the Mac |
| `POST /api/compose` | `compose` | runs a flow, or Flow code you send, once it's allowed |
| `POST /api/check` | `compose` | checks Flow code: its types, or its mistake (nothing runs, nothing is asked) |
| `GET  /api/automation` | `catalog` | the automation tags there are, and the items that run by themselves |
| `POST /api/automation` | `run` / `compose` | tags a script (or a flow) to run by itself, once it's allowed on the Mac |
| `GET  /api/doc` | — | this contract in one page of text (`text/markdown`), with the address and token filled in |
| `GET  /api/runs` | `runs` | the latest runs (yours and the person's), without their output |
| `GET  /api/runs/{id}` | `runs` | one run, with its output (and a flow's steps) |
| `POST /api/runs/{id}/stop` | `runs` | stops it |
| `GET  /` | — | a status page listing the endpoints, with a place to try running a script or Flow code |

**Switches.** Each group can be turned off or on in the menu bar panel's **HTTP API** section (and
the whole server stopped and started) without quitting the app. A call to a group that's off gets
`503 {"error": "run scripts is turned off in Tool Mac Tool Run", "code": "endpoint_off"}`. When the
server is stopped, connections are refused. `GET /api/health` always says what's on.

---

### `GET /api/health`

```json
{
  "ok": true,
  "service": "toolmactoolrun",
  "version": "0.1.42",
  "run": true, "compose": true, "catalog": true, "runs": true,
  "folder": "/Users/sam/Scripts", "scripts": 12, "flows": 4,
  "approval": "each run waits for a click on Run, on the Mac"
}
```

`folder` is `null` until the person has chosen a scripts folder; until then the other endpoints
answer `409 no_folder`. A refused connection or a timeout means the app isn't running (or its API
is stopped).

### `GET /api/scripts`

```json
{
  "folder": "/Users/sam/Scripts",
  "scripts": [
    {"name": "hello.sh", "title": "hello", "group": "scripts", "language": "bash", "language_name": "Bash",
     "summary": "Says hello to whoever's named", "asks_for_input": false, "dangers": [], "uses_epa": false,
     "inputs": [{"prompt": "Who to greet (the world unless set)", "kind": "argument", "optional": true, "why": "It's put in the greeting as typed"}]},
    {"name": "tidy.py", "title": "tidy", "group": "scripts", "language": "python", "language_name": "Python",
     "summary": "Moves old downloads to the Trash", "asks_for_input": false,
     "dangers": ["deletes files"], "uses_epa": false},
    {"name": "utilities/json-get.py", "title": "json-get", "group": "utilities", "language": "python",
     "language_name": "Python", "summary": "Picks a value out of JSON (its input, or a file)…",
     "asks_for_input": false, "dangers": [], "uses_epa": false,
     "inputs": [{"prompt": "Where the value is: a.b.0.c, with * for every item", "kind": "argument", "optional": false},
                {"prompt": "The JSON", "kind": "stdin", "optional": false}]},
    {"name": "browser/page-info.sh", "title": "page-info", "group": "browser", "language": "bash",
     "language_name": "Bash", "summary": "The page in front of your browser: its title, then its address",
     "asks_for_input": false, "dangers": [], "uses_epa": false}
  ]
}
```

- `name` is what you send to run it (the file name; the name without its extension works too).
  A utility's or browser script's name starts with its folder (`utilities/json-get.py`); its file
  name alone works too (`json-get`) when no script at the top of the folder has it.
- `group` is the grid it's on: `scripts` (the top of the folder), `utilities` (small reusable
  helpers, in its `utilities` folder) or `browser` (scripts that drive the default browser, in
  its `browser` folder). They're all scripts, and run the same way. `?group=utilities` (or
  `browser`, `scripts`) lists one group only.
- `summary` is the script's first comment line, when it has one.
- `dangers`: what the script looks like it does that can't be undone, in words ("deletes files
  for good (rm -r / rm -f)", "runs commands as the administrator (sudo)"…). The card on the Mac
  shows it in red.
- `asks_for_input`: it looks like it reads typed answers (`read -p`, `input()`): send them as `stdin`.
- `inputs`: what its header says it takes, in order (`# Input: …` lines): each `argument` goes in
  `args` (one argument each, spaces and all; an `optional` one can be left out), a `stdin` one
  goes in `stdin`; `why` (when the header has a `# Why:` line under it) says what the answer is
  for, to show whoever types it. The app's API board asks for exactly these before it runs one. A
  flow lists its own in `/api/flows` the same way.

What's *in* a script is never sent.

### `GET /api/flows`

```json
{"folder": "/Users/sam/Scripts/composer",
 "flows": [{"name": "morning.flow", "title": "morning", "summary": "The day's first checks", "uses_epa": false, "inputs": []}]}
```

### `POST /api/run`

```json
{"script": "hello.sh", "args": ["world", "--loud"], "client": "My App", "why": "You pressed Greet in My App's toolbar"}
```

| field | | |
|---|---|---|
| `script` | required | its `name` from `/api/scripts` (with or without the extension; a utility or browser script by its file name alone, too) |
| `args` | optional | a list of strings (numbers are taken as written), or one line split as a shell would: `"--all '/tmp/my files'"` |
| `stdin` | optional | text handed to the script as its input |
| `client` | optional | your app's name, shown on the Mac ("My App wants to run a script"). Without it, your `X-Client` header, else your User-Agent's first word (`curl`) |
| `why` | **send it** | why your app wants this run, in a sentence or two the person reads on the card before clicking Run: what pressed the button, what the result is for. Without it the card says your app gave no reason. Up to six lines; kept with the run as `why`. `reason` means the same |
| `wait` | optional | `false`: answer as soon as it has started (`202`), then read it from `/api/runs/{id}` |
| `stream` | optional | `true`: answer at once and send events as they happen (see *Streaming*) |
| `automation` | optional | tag it to run by itself instead of running it now (see *Automation*) |

The script runs exactly as a click on its cell runs it: in the scripts folder, with the person's
shell PATH, its `#!` line or its language's program. It shows on its cell and in Runs, marked as
asked for over the API by your app.

**By default the answer comes once the run has ended** (however long it takes; closing the
connection doesn't stop the run, `POST /api/runs/{id}/stop` does):

```json
{
  "id": "6C1D2F0E-…", "kind": "script", "name": "hello.sh", "state": "succeeded", "ok": true,
  "code": 0, "seconds": 0.04, "started": "2026-10-18T09:12:03.120Z", "ended": "2026-10-18T09:12:03.161Z",
  "command": "cd /Users/sam/Scripts && /bin/bash /Users/sam/Scripts/hello.sh world --loud", "arguments": ["world", "--loud"],
  "output": "HELLO, WORLD!\n", "stdout": "HELLO, WORLD!\n", "stderr": "", "trimmed": false,
  "requested_by": "My App, on this Mac", "why": "You pressed Greet in My App's toolbar"
}
```

| field | |
|---|---|
| `state` | `running`, `succeeded`, `failed`, `stopped` or `could_not_start` |
| `ok` | `state` is `succeeded` (exit code 0) |
| `code` | the exit code (killed by a signal: 128 + the signal, and `signal` says which) |
| `output` | everything it printed, in order; `stdout` and `stderr` are the two apart |
| `trimmed` | it printed more than 300 KB, so the earliest part was dropped |
| `problem` | why it couldn't start, or why a flow stopped, with the fix (e.g. a missing `python3` and the `brew install` for it) |

A run that fails is still `200`: look at `ok`. These are the answers that mean it didn't run:

| status | `code` | when |
|---|---|---|
| 403 | `denied` | the person clicked **Don't Run** |
| 403 | `not_answered` | no one clicked anything in two minutes |
| 404 | `unknown_script` | no such script (`error` lists the ones there are) |

### `POST /api/compose`

Runs a flow from the folder:

```json
{"flow": "morning.flow", "args": ["today"]}
```

or **Flow code you send** (see the [Flow guide](docs/FLOW-GUIDE.md); it can run the folder's
scripts by name with `run "hello.sh" []`):

```json
{"source": "let n = run \"count.sh\" []\nprint $\"There are {n}\"", "name": "Count them"}
```

A `text/plain` body is taken as `source`. `name` is what the run is called on the Mac and in Runs
(default: "Flow sent by My App"). `args`, `client`, `wait` and `stream` are as for `/api/run`.

The code is checked first, before anything is asked: a mistake answers
`400 {"code": "flow_mistake", "error": "line 2: …", "message", "line", "fix"}` and nothing is shown
on the Mac. The card shows your code in full; nothing runs until Run is clicked.

A flow's result has `"kind": "flow"`, its own output (what it `print`s, a line as each step starts
and ends) and `steps`: each script it ran, as a run of its own with its output. A flow that asks
something (`confirm`, `ask`, `choose`…) asks the person at the Mac, in the app's question window,
and waits for the answer. In code you send, say why each question is asked, so the person
answers knowing: `confirmBecause "Delete them?" "They're 30 days old and take 12 GB"` (and
`askBecause`, `askYesNoBecause`, `chooseBecause "Which?" "why" ["a"; "b"]`); the why shows under
the question.

### `GET /api/automation`, `POST /api/automation`

A script or a flow can be tagged to **run by itself**. The tags are a fixed set (never made up):

| schedules | triggers |
|---|---|
| `every-minute`, `every-5-minutes`, `every-10-minutes`, `every-30-minutes`, `every-hour` (counted from when it was tagged) | `when-api-called` (after another app has run something over this API) |
| `every-morning` (7:00), `every-afternoon` (13:00), `every-evening` (19:00), `every-day` (9:00) | `when-a-script-runs`, `when-a-flow-runs`, `when-a-utility-runs`, `when-a-browser-script-runs` |
| `every-week` (Monday 9:00), `every-month` (the 1st, 9:00) | `after-an-item` (with `after`: the items' names), `when-anything-runs` |

Spaces work too (`"every morning"`). A trigger fires once the run that set it off has ended; a run
the automation started never sets off another. An automated run uses the arguments remembered for
its cell, shows in `/api/runs` with `"requested_by": "Automation: every morning"`, and asks on
the card first when its cell would (it looks like it can't be undone, or it's set to ask).

```json
{"script": "backup.sh", "automation": ["every evening", "when-api-called"], "once": false, "client": "My App", "why": "So the backup never waits on anyone"}
```

`POST /api/automation` (or `/api/run` or `/api/compose` with `automation`) shows a card on the
Mac saying your app wants it to run by itself and how; **Allow** tags it, **Don't Allow** doesn't
(`403 denied` / `not_answered`, as for a run). Nothing runs now. `once: true` runs it the next
time only, then takes its tags off. `"automation": []` takes its automation off. `after` names
the items it runs after (`"after": ["hello.sh"]` adds `after-an-item`). Flow code you send
(`source`) can't be automated: only a file in the folder can. An unknown tag is
`400 unknown_tag`, with the tags listed in `error`.

```json
{"ok": true, "automated": true, "name": "backup.sh", "kind": "script", "group": "scripts", "title": "backup",
 "tags": ["every-evening", "when-api-called"], "once": false, "after": [], "summary": "every evening, when the API is called",
 "next": "2026-10-22T19:00:00.000Z"}
```

`GET /api/automation` answers `{"tags": [{"name", "title", "kind": "schedule"|"trigger", "about"}], "items": [… as above …]}`:
every tag there is, and every item that runs by itself. `GET /api/health` counts them as `automated`.

### `POST /api/check`

```json
{"source": "let double x = x * 2"}
```

```json
{"ok": true, "bindings": [{"name": "double", "type": "int -> int", "line": 1}]}
```

or `{"ok": false, "code": "flow_mistake", "error", "message", "line", "fix"}`. Nothing runs and
nothing is asked: use it as you type.

### Streaming

With `"stream": true`, `/api/run` and `/api/compose` answer at once with
`Content-Type: application/x-ndjson`, one JSON object per line, sent as things happen:

```
{"type":"waiting","message":"Waiting for the person at the Mac to click Run"}
{"type":"started","id":"6C1D2F0E-…","name":"backup.sh"}
{"type":"output","stream":"out","text":"Copying 1,204 files…\n"}
{"type":"output","stream":"err","text":"skipped: Photos Library (in use)\n"}
{"type":"done","state":"succeeded","ok":true,"code":0,"seconds":41.2,"output":"…", …}
```

| event | fields |
|---|---|
| `waiting` | `message`: it's on the Mac, waiting for Run |
| `denied` | `code` (`denied` or `not_answered`), `message`; the stream ends |
| `started` | `id`, `name` |
| `output` | `stream` (`out` or `err`), `text`; for a flow's step, `step` (the script's name) |
| `step` | a flow's step: `id`, `name`, `state` (`running`, then how it ended, with `code`) |
| `done` | everything a waited-for run gives (see `/api/run`) |
| `error` | `message`; the stream ends |

Closing the connection while it's `waiting` takes the card away (nothing runs). Once it has
started, the run goes on.

```js
const r = await fetch("http://127.0.0.1:8768/api/run", {
  method: "POST",
  headers: {"Content-Type": "application/json"},
  body: JSON.stringify({script: "backup.sh", stream: true, client: "My App"}),
});
const reader = r.body.getReader(), dec = new TextDecoder();
let buf = "";
for (;;) {
  const {value, done} = await reader.read();
  if (done) break;
  buf += dec.decode(value, {stream: true});
  for (let i; (i = buf.indexOf("\n")) >= 0; buf = buf.slice(i + 1)) {
    const ev = JSON.parse(buf.slice(0, i));
    if (ev.type === "output") process.stdout.write(ev.text);
    if (ev.type === "done") console.log(ev.ok ? "✅" : "❌", ev.state);
  }
}
```

```python
import json, requests
r = requests.post("http://127.0.0.1:8768/api/run", json={"script": "backup.sh", "stream": True, "client": "My App"}, stream=True)
for line in r.iter_lines():
    ev = json.loads(line)
    if ev["type"] == "output":
        print(ev["text"], end="")
    elif ev["type"] in ("done", "denied"):
        print(ev.get("state") or ev["message"])
```

### `GET /api/runs`, `GET /api/runs/{id}`, `POST /api/runs/{id}/stop`

`/api/runs?limit=20` gives the latest runs, newest first, each as above without `output`,
`stdout`, `stderr` and `steps`. `/api/runs/{id}` gives one with everything. `…/stop` stops it (a
flow's step stops its flow) and answers `{"ok": true, "stopping": true}` (`false`: it had already
ended). An id the app doesn't have (runs are kept until **Clear Finished**, the latest 300) is
`404 unknown_run`.

---

## Errors

Errors are JSON, `{"error": "what went wrong", "code": "…"}`:

| status | `code` | when |
|---|---|---|
| 400 | `missing_script`, `missing_flow`, `bad_args`, `bad_request` | the request isn't right |
| 400 | `unknown_tag` | no such automation tag (`error` lists them) |
| 400 | `flow_mistake` | the Flow code has a mistake (with `line` and `fix`) |
| 401 | `unauthorized` | sharing on the network is on and the request didn't send the token |
| 403 | `denied`, `not_answered` | it didn't run: Don't Run, or no answer in time |
| 403 | `forbidden` | a browser page from another site, a `Host` that isn't this Mac, or another machine while sharing is off |
| 404 | `not_found`, `unknown_script`, `unknown_flow`, `unknown_run` | no such route, script, flow or run |
| 409 | `no_folder` | no scripts folder is chosen yet |
| 413 | `too_large` | a body over 8 MB |
| 503 | `endpoint_off` | that group is switched off in the app |
| 500 | `failed` | anything else; `error` says what |

## Access

- It listens on **127.0.0.1** only: other machines can't reach it. Programs on this Mac (curl,
  scripts, apps, servers) are answered, and every run they ask for waits for Run on the Mac.
- **Browsers.** Pages from this machine (`http://localhost:*`, `http://127.0.0.1:*`) may call it
  (CORS). Other origins are refused, so a website you visit can't even ask. Requests whose `Host`
  names another machine are refused (with sharing on, they need the token), so a website can't
  reach it by pointing its own domain at 127.0.0.1.
- **Sharing on the network** (off by default): the panel's *Allow other devices* switch makes it
  listen on all interfaces and requires a token from everyone but this Mac (calling it as
  `localhost` or `127.0.0.1`): `Authorization: Bearer <token>`. A browser's preflight (`OPTIONS`)
  needs no token; an origin listed as allowed gets its CORS headers. The token is shown in the panel, with a copy button. Runs asked
  for from another device still wait for Run on the Mac, and the card says which device asked.
- The port is 8768 (Super Voice is 8767), so both can run side by side.
