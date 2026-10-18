# Tool Mac Tool Run API

Tool Mac Tool Run is a menu bar app for the Mac that runs your scripts (bash, Python, Node…) and
your **flows** (scripts composed in the Flow language). It serves both to other apps over HTTP,
the way [Super Voice](https://github.com/ainigh/super-mac-tts-stt-service) serves speech:

- **List** the scripts and flows in the person's scripts folder.
- **Run** a script, a flow, or Flow code your app sends, and get back how it went and everything
  it printed (all at once, or streamed as it prints).
- **Read** the runs, and stop one.

**Nothing runs without the person's say-so.** Every run request shows a large card on the Mac
naming your app, what would run (the exact command, or your Flow code in full) and anything it
looks like it does that can't be undone, with **Run** and **Don't Run**. Your request waits for
the click. No click in two minutes is Don't Run.

This document is the contract for client apps. New fields may be added to responses, but nothing
listed here changes meaning.

```
Base URL   http://127.0.0.1:8768
```

## In one minute

```bash
# is it there, and what's on?
curl -s localhost:8768/api/health

# the scripts in the folder
curl -s localhost:8768/api/scripts

# run one (waits for Run on the Mac, then for the script to end)
curl -s localhost:8768/api/run -d '{"script": "hello.sh", "args": ["world"], "client": "My App"}'
# {"id":"…","name":"hello.sh","state":"succeeded","ok":true,"code":0,"seconds":0.04,
#  "output":"Hello, world!\n","stdout":"Hello, world!\n","stderr":"", …}

# the same, sent as it prints (NDJSON, one event a line)
curl -sN localhost:8768/api/run -d '{"script": "backup.sh", "stream": true}'

# run a flow from the folder, or Flow code you send
curl -s localhost:8768/api/compose -d '{"flow": "morning.flow"}'
curl -s localhost:8768/api/compose -H 'Content-Type: text/plain' --data-binary @mine.flow

# check Flow code without running anything (nothing is asked on the Mac)
curl -s localhost:8768/api/check -d '{"source": "let double x = x * 2"}'
```

## Endpoints

| route | switch | does |
|---|---|---|
| `GET  /api/health` | — | whether it's up, which endpoints are on, the folder |
| `GET  /api/scripts` | `catalog` | the scripts in the folder: name, language, description, what they look like they do |
| `GET  /api/flows` | `catalog` | the flows in the folder's `composer` folder |
| `POST /api/run` | `run` | runs a script once it's allowed on the Mac |
| `POST /api/compose` | `compose` | runs a flow, or Flow code you send, once it's allowed |
| `POST /api/check` | `compose` | checks Flow code: its types, or its mistake (nothing runs, nothing is asked) |
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
    {"name": "hello.sh", "title": "hello", "language": "bash", "language_name": "Bash",
     "summary": "Says hello to whoever's named", "asks_for_input": false, "dangers": [], "uses_epa": false},
    {"name": "tidy.py", "title": "tidy", "language": "python", "language_name": "Python",
     "summary": "Moves old downloads to the Trash", "asks_for_input": false,
     "dangers": ["deletes files"], "uses_epa": false},
    {"name": "clean-builds.sh", "title": "clean-builds", "language": "bash", "language_name": "Bash",
     "summary": "Empties every build folder", "asks_for_input": false,
     "dangers": ["deletes files for good (rm -r / rm -f)"], "uses_epa": false}
  ]
}
```

- `name` is what you send to run it (the file name; the name without its extension works too).
- `summary` is the script's first comment line, when it has one.
- `dangers`: what the script looks like it does that can't be undone, in words ("deletes files
  for good (rm -r / rm -f)", "runs commands as the administrator (sudo)"…). The card on the Mac
  shows it in red.
- `asks_for_input`: it looks like it reads typed answers (`read -p`, `input()`): send them as `stdin`.

What's *in* a script is never sent.

### `GET /api/flows`

```json
{"folder": "/Users/sam/Scripts/composer",
 "flows": [{"name": "morning.flow", "title": "morning", "summary": "The day's first checks", "uses_epa": false}]}
```

### `POST /api/run`

```json
{"script": "hello.sh", "args": ["world", "--loud"], "client": "My App"}
```

| field | | |
|---|---|---|
| `script` | required | its `name` from `/api/scripts` (with or without the extension) |
| `args` | optional | a list of strings (numbers are taken as written), or one line split as a shell would: `"--all '/tmp/my files'"` |
| `stdin` | optional | text handed to the script as its input |
| `client` | optional | your app's name, shown on the Mac ("My App wants to run a script"). Without it, your `X-Client` header, else your User-Agent's first word (`curl`) |
| `wait` | optional | `false`: answer as soon as it has started (`202`), then read it from `/api/runs/{id}` |
| `stream` | optional | `true`: answer at once and send events as they happen (see *Streaming*) |

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
  "requested_by": "My App, on this Mac"
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
and waits for the answer.

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
  names another machine are refused, so a website can't reach it by pointing its own domain at
  127.0.0.1.
- **Sharing on the network** (off by default): the panel's *Allow other devices* switch makes it
  listen on all interfaces and requires a token from everyone but this Mac:
  `Authorization: Bearer <token>`. The token is shown in the panel, with a copy button. Runs asked
  for from another device still wait for Run on the Mac, and the card says which device asked.
- The port is 8768 (Super Voice is 8767), so both can run side by side.
