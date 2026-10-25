# Tool Mac Tool Run API

Tool Mac Tool Run is a menu bar app for the Mac that runs your scripts (bash, Python, Node…) and
your **flows** (scripts composed in the Flow language). It serves both to other apps over HTTP,
the way [Super Voice](https://github.com/ainigh/super-mac-tts-stt-service) serves speech:

- **Talk to it in words**: that's [Peter](https://github.com/ainigh/tool-mac-tool-run-agent)
  (Tool Mac Agent, `POST http://127.0.0.1:8770/api/say`): he reads what's wanted, calls what's
  below for you, answers in words, and keeps the schedule (what runs later, or every day).
- **List** the scripts and flows in the person's scripts folder.
- **Run** a script, a flow, or Flow code your app sends, and get back how it went and everything
  it printed (all at once, or streamed as it prints).
- **Read** the runs, and stop one. **Every request has an id** you get back at once and can ask
  about any time later (`/api/requests/{id}`): still waiting for the click, denied, running, done.
- **Automate**: tag a script or a flow to run by itself, on a schedule or when something happens.
- **Keep notes** in the person's file library (LIBRARY (in STORAGE-SPACES/USER on their Desktop)): Markdown notes by name,
  like keys and values. List, read, write, append, search the full text, delete to the library's
  own Trash and restore. **These answer at once, without a card**: they're notes, not programs.
- **Drive Chrome with Straw**: its words, check Straw code, run a Straw script or code you send.
- **Find what you need by a few words**: `GET /api/search?q=remember a birthday` answers only the
  routes, scripts and flows that match, each with how to call it, instead of every route at once.
  Every route has tags (the words someone looking for it would say), and so can a script
  (`# Tags: weather forecast` in its header). **Every JSON answer says what to call next**
  (`"next"`), with its ids filled in, so nothing has to be known ahead of time.
- **Keep track of what you asked for**: `GET /api/requests/open` lists the requests not collected
  yet, oldest first, each waiting, running or ready. **A result is handed over once**: the first
  read once it's over takes it, and asked again, the request says how it ended without the output.
- **See every route**, in its groups: `GET /api/endpoints` (`?brief=true`: the groups alone).

**Nothing runs without the person's say-so** (the file library aside). Every run request shows a large card on the Mac
naming your app, why it wants the run (your `why`, in your words; the card says when you gave
none), what would run (the exact command, or your Flow code in full) and anything it looks like
it does that can't be undone, with **Run** and **Don't Run**. Your request waits for the click.
No click in two minutes is Don't Run. **Send `why` with every run**: it's what the person reads
before deciding.

This document is the contract for client apps. New fields may be added to responses, but nothing
listed here changes meaning. **You can depend on the request id**: every answer to `/api/run`,
`/api/compose` and `/api/runs/{id}/stop` carries it (the `X-Request-Id` header and `request` in the
JSON, on success and on refusal alike), and `GET /api/requests/{id}` answers for it for as long as
the app runs (the latest 500). **A result is handed over once** (in the answer itself when you
waited for it, or the first read of `/api/requests/{id}` once it's over); after that the request
still says how it ended, without the output.

```
Base URL   http://127.0.0.1:8768
```

**From an agent** (Super Voice's Tom and Jerry, or any assistant with tools): the
[agents guide](docs/AGENTS-GUIDE.md) is this contract as a loop: send with `"async": true`, keep
the request id, poll `/api/requests/{id}`, and what to tell the person at each state.

**The same, in one page:** `GET /api/doc` answers this contract compacted to a page of text (every
endpoint, field, event and error, with the address you reached it at and, from another device,
the token to send), as does **Copy API Doc** in the app's panel. Paste it into your app's code, its
README, or a chat with an assistant writing the client for you.

**Ready to paste, for your kind of app:** the panel's HTTP API section has a chip for each —
**curl**, **Python** (the standard library only), **JavaScript** (`fetch`), **Swift**
(`URLSession`), **Shortcuts** (the actions, step by step) and **AI Agent** (the rules and the
endpoints, worded for an assistant's instructions) — and one for the **Address**. Each copies
working code with this Mac's address (and the token, when sharing on the network is on) that lists
the scripts, runs one with `client` and `why`, keeps the request id, and handles Don't Run.

## In one minute

```bash
# in words, through Peter (Tool Mac Agent, a separate app): say what you want, get words back
curl -s localhost:8770/api/say?client=My+App -H 'Content-Type: text/plain' -d "what's the weather in Lagos"
# Asked for the weather. I'll tell you how it goes.

# what you need, by a few words: only the routes, scripts and flows that match, each with how to call it
curl -s "localhost:8768/api/search?q=remember+a+birthday"

# for a model: every tool, with its arguments, a guide and examples; then call one by name
curl -s localhost:8768/api/tools
curl -s localhost:8768/api/tools/web_search -d '{"arguments": {"q": "louvre opening hours"}, "client": "My App"}'

# is it there, and what's on? (and how many of your requests are still open)
curl -s localhost:8768/api/health

# the scripts in the folder
curl -s localhost:8768/api/scripts

# run one (waits for Run on the Mac, then for the script to end)
curl -s localhost:8768/api/run -d '{"script": "hello.sh", "args": ["world"], "client": "My App", "why": "You pressed Greet in My App"}'
# {"id":"…","name":"hello.sh","state":"succeeded","ok":true,"code":0,"seconds":0.04,
#  "output":"Hello, world!\n","stdout":"Hello, world!\n","stderr":"", …}

# the same, sent as it prints (NDJSON, one event a line)
curl -sN localhost:8768/api/run -d '{"script": "backup.sh", "stream": true}'

# don't wait at all: the request's id comes back now; ask about it whenever you like
curl -si localhost:8768/api/run -d '{"script": "backup.sh", "async": true, "client": "My App", "why": "Nightly backup"}'
# HTTP/1.1 202 Accepted … X-Request-Id: 2A7C…   {"request":"2A7C…","state":"waiting","url":"/api/requests/2A7C…", …}
curl -s localhost:8768/api/requests/2A7C…
# {"request":"2A7C…","state":"succeeded","ok":true,"delivery":"delivered","run_id":"6C1D…","run":{…everything it printed…}, …}
# (handed over once: asked again, it says "delivery":"cleared" and how it ended, without the output)

# what you've asked for and not collected yet, oldest first: waiting, running, or ready
curl -s localhost:8768/api/requests/open

# run a flow from the folder, or Flow code you send
curl -s localhost:8768/api/compose -d '{"flow": "morning.flow"}'
curl -s localhost:8768/api/compose -H 'Content-Type: text/plain' --data-binary @mine.flow

# check Flow code without running anything (nothing is asked on the Mac)
curl -s localhost:8768/api/check -d '{"source": "let double x = x * 2"}'

# the file library: a note by name, written, read, searched (answered at once, nothing asked)
curl -s localhost:8768/api/library -d '{"op": "write", "name": "groceries", "text": "- eggs\n- milk\n"}'
curl -s localhost:8768/api/library -d '{"op": "search", "q": "milk"}'
curl -s localhost:8768/api/library/files/groceries?format=text

# remember someone, and recall them (MEMORY, and the mind that links it: answered at once)
curl -s localhost:8768/api/memory/remember -d '{"category": "PEOPLE", "about": "Ada Lovelace", "text": "Met at the conference", "client": "My App"}'
curl -s "localhost:8768/api/memory/recall?name=ada"

# show something on the Mac, in front of everything, with copy buttons; copy to the clipboard
curl -s localhost:8768/api/present -d '{"shelf": "memory", "name": "PEOPLE", "why": "To check the details"}'
curl -s localhost:8768/api/clipboard -d '{"text": "ssh me@example.com"}'

# what's on the page in Chrome: true or false, and where a thing is
curl -s "localhost:8768/api/browser/has?text=Compute"
curl -s "localhost:8768/api/browser/find?text=Compute"

# every route, in its groups (long: ?brief=true gives the groups alone, ?group=memory one group)
curl -s localhost:8768/api/endpoints
```

## Endpoints

`GET /api/endpoints` (or `GET /api`) lists every route, in these groups, as JSON:
`{"groups": [{"id", "title", "about", "switch"?, "on"?, "routes": [{"method", "path", "summary",
"asks_on_the_mac"}]}]}`; `?group=library` gives one; `?brief=true` gives the groups alone (each
with how many routes it has and the words it's found by); `?q=words` is a search of the routes.
`GET /api/doc` lists them the same way, as text. A small client starts with `GET /api/search`.

| group | what's in it |
|---|---|
| **About the API** | `/api/search`, `/api/endpoints`, `/api/health`, `/api/doc`, `/` |
| **Scripts and flows** | `/api/scripts`, `/api/flows`, `/api/run`, `/api/compose`, `/api/check` |
| **Straw** | `/api/straw`, `/api/straw/check`, `/api/straw/run` ([below](#straw-get-apistraw-post-apistrawcheck-post-apistrawrun)) |
| **File library** | `/api/library` and everything under it ([below](#the-file-library-apilibrary)) |
| **Runs and requests** | `/api/requests/open`, `/api/requests/{id}`, clearing them, `/api/requests`, `/api/runs`, stopping one |

| route | switch | does |
|---|---|---|
| `GET  /api/search` | — | the routes, scripts and flows that match some words, the best first, each with how to call it |
| `GET  /api/endpoints` | — | every route, in its groups (`?brief=true`: the groups alone) |
| `GET  /api/health` | — | whether it's up, which endpoints are on, the folder, the library |
| `GET  /api/scripts` | `catalog` | the scripts in the folder (and its utilities and browser scripts): name, group, language, description, what they look like they do |
| `GET  /api/flows` | `catalog` | the flows in the folder's `composer` folder |
| `POST /api/run` | `run` | runs a script once it's allowed on the Mac |
| `POST /api/compose` | `compose` | runs a flow, or Flow code you send, once it's allowed |
| `POST /api/check` | `compose` | checks Flow code: its types, or its mistake (nothing runs, nothing is asked) |
| `GET  /api/doc` | — | this contract in one page of text (`text/markdown`), with the address and token filled in |
| `GET  /api/requests/open` | `runs` | your requests not collected yet, oldest first: waiting, running, or ready |
| `GET  /api/requests/{id}` | `runs` | where a request is; once it's over, the first read hands over its result |
| `DELETE /api/requests/{id}` | `runs` | clears one without reading it (one still waiting for the click is taken back) |
| `POST /api/requests/clear` | `runs` | clears every one that's over and not collected |
| `GET  /api/runs` | `runs` | the latest runs (yours and the person's), without their output |
| `GET  /api/runs/{id}` | `runs` | one run, with its output (and a flow's steps) |
| `POST /api/runs/{id}/stop` | `runs` | stops it |
| `GET  /api/straw` | `catalog` | Straw's words and the Straw scripts in the folder |
| `POST /api/straw/check` | `catalog` | checks Straw code: what it would do, or its mistake (nothing runs, nothing is asked) |
| `POST /api/straw/run` | `run` | runs a Straw script, or Straw code you send, in Chrome, once it's allowed |
| `/api/library…` | `library` | the file library's notes: **answered at once, nothing asked** ([below](#the-file-library-apilibrary)) |
| `GET  /` | — | a status page listing the endpoints, with a place to try running a script or Flow code |

**Switches.** Each group can be turned off or on in the menu bar panel's **HTTP API** section (and
the whole server stopped and started) without quitting the app. A call to a group that's off gets
`503 {"error": "run scripts is turned off in Tool Mac Tool Run", "code": "endpoint_off"}`. When the
server is stopped, connections are refused. `GET /api/health` always says what's on.

**Every JSON answer says what to call next**: `"next": [{"method", "path", "why"}]`, a few calls
that usually follow the one just made, with its own values filled in (after reading a note: write
it, add to it, show it; after a run: the run, the open requests; after a 404: a search for the
words of the path). Answers about a request or a run fill in their ids. `?next=false` leaves it out.

---

### Finding your way: `GET /api/search`

`/api/endpoints` lists well over a hundred routes; a small client (a model with a short context, a
phone shortcut) shouldn't have to read them all. Ask for what you want in a few words instead:

```bash
curl -s "localhost:8768/api/search?q=remember+a+birthday"
```

```json
{
  "ok": true, "q": "remember a birthday", "words": ["remember", "birthday"], "count": 3, "total": 3,
  "results": [
    {"kind": "route", "method": "POST", "path": "/api/memory/remember", "call": "POST /api/memory/remember",
     "summary": "remember something {\"category\": \"PEOPLE\", \"about\": …}", "group": "memory", "asks_on_the_mac": false,
     "tags": ["remember", "save", "store", "keep", "note", "add", "person", "birthday", "fact", "tell"],
     "matched": ["remember", "birthday"], "score": 30.2},
    {"kind": "route", "method": "GET", "path": "/api/memory/upcoming", …}
  ],
  "next": [{"method": "POST", "path": "/api/memory/remember", "why": "the best match: …"}, …]
}
```

- `q`: the words. Words that say nothing ("how do I", "a", "the") are left out; the rest are
  compared by their stem ("birthdays", "birthday"), accents and case aside.
- `in`: `routes`, `scripts`, `flows`, or several with commas (all three when it's left out).
- `group`: the routes of one group only (`memory`, `library`, `runs`…; `/api/endpoints?brief=true`
  lists them).
- `limit`: how many (10; at most 50). `total` says how many matched in all.

A route is found by its path, its summary, its group, and its **tags**: the words someone looking
for it would say (`/api/requests/{id}` is found by "status", "result", "job", "poll";
`/api/runs/{id}/stop` by "cancel", "kill"). A word few routes have counts for more than one many
have, and only what matches about as many of your words as the best match is kept, so a long
question doesn't bring back everything.

A **script** or a **flow** is found by its name, what its first comment says it does, its topic,
and the tags its header gives (`# Tags: weather, forecast rain`, beside its `# Input:` lines). Each
comes back with `"run"`: the request that runs it, its inputs as placeholders to fill:

```json
{"kind": "script", "name": "utilities/weather.sh", "summary": "The weather now", "tags": ["forecast", "rain"],
 "run": {"method": "POST", "path": "/api/run", "asks_on_the_mac": true,
         "body": {"script": "utilities/weather.sh", "args": ["<A city>"], "async": true, "client": "<your app's name>", "why": "<…>"}}}
```

Nothing matched: `count` is 0 and `next` points to `/api/endpoints?brief=true`, the groups with
their words. `400 missing_query` without `q`.

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
| `wait` | optional | `false`: answer as soon as it has started (`202`, once Run is clicked), then read it from `/api/runs/{id}` |
| `async` | optional | `true`: answer now, before anyone has clicked (`202` with the request's id), then read `/api/requests/{id}` (see *Request ids*) |
| `stream` | optional | `true`: answer at once and send events as they happen (see *Streaming*) |

The script runs exactly as a click on its cell runs it: in the scripts folder, with the person's
shell PATH, its `#!` line or its language's program. It shows on its cell and in Runs, marked as
asked for over the API by your app.

**By default the answer comes once the run has ended** (however long it takes; closing the
connection doesn't stop the run, `POST /api/runs/{id}/stop` does):

```json
{
  "id": "6C1D2F0E-…", "request": "2A7C4B19-…", "kind": "script", "name": "hello.sh", "state": "succeeded", "ok": true,
  "code": 0, "seconds": 0.04, "started": "2026-10-18T09:12:03.120Z", "ended": "2026-10-18T09:12:03.161Z",
  "command": "cd /Users/sam/Scripts && /bin/bash /Users/sam/Scripts/hello.sh world --loud", "arguments": ["world", "--loud"],
  "output": "HELLO, WORLD!\n", "stdout": "HELLO, WORLD!\n", "stderr": "", "trimmed": false,
  "requested_by": "My App, on this Mac", "why": "You pressed Greet in My App's toolbar"
}
```

| field | |
|---|---|
| `request` | the request's id (also the `X-Request-Id` header): `/api/requests/{id}` answers for it any time later |
| `state` | `running`, `succeeded`, `failed`, `stopped` or `could_not_start` |
| `ok` | `state` is `succeeded` (exit code 0) |
| `code` | the exit code (killed by a signal: 128 + the signal, and `signal` says which) |
| `output` | everything it printed, in order; `stdout` and `stderr` are the two apart |
| `trimmed` | it printed more than 300 KB, so the earliest part was dropped |
| `problem` | why it couldn't start, or why a flow stopped, with the fix (e.g. a missing `python3` and the `brew install` for it) |

A run that fails is still `200`: look at `ok`. These are the answers that mean it didn't run
(each carries `request` too, and `/api/requests/{id}` keeps saying the same):

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

### Running by itself: Peter's

Running a script or a flow later, or on a schedule, is
[Peter's](https://github.com/ainigh/tool-mac-tool-run-agent) (Tool Mac Agent): `POST
http://127.0.0.1:8770/api/say "every morning at 7, run the nightly backup"`. When it's due he asks
for it here like any app (a card waits for Run). A run request here with `automation` is answered
`400 moved`, and `/api/automation` `404 moved`.

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
{"type":"waiting","request":"2A7C4B19-…","url":"/api/requests/2A7C4B19-…","message":"Waiting for the person at the Mac to click Run"}
{"type":"started","id":"6C1D2F0E-…","request":"2A7C4B19-…","name":"backup.sh"}
{"type":"output","stream":"out","text":"Copying 1,204 files…\n"}
{"type":"output","stream":"err","text":"skipped: Photos Library (in use)\n"}
{"type":"done","state":"succeeded","ok":true,"code":0,"seconds":41.2,"output":"…", …}
```

| event | fields |
|---|---|
| `waiting` | `request` (the request's id, also the `X-Request-Id` header), `url`, `message`: it's on the Mac, waiting for Run |
| `denied` | `code` (`denied` or `not_answered`), `message`; the stream ends |
| `started` | `id`, `name` |
| `output` | `stream` (`out` or `err`), `text`; for a flow's step, `step` (the script's name) |
| `step` | a flow's step: `id`, `name`, `state` (`running`, then how it ended, with `code`) |
| `done` | everything a waited-for run gives (see `/api/run`) |
| `error` | `message`; the stream ends |

Closing the connection while it's `waiting` takes the card away (nothing runs). Once it has
started, the run goes on, and `/api/requests/{id}` (from the `waiting` line) still answers for it.

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

### Request ids: `GET /api/requests/{id}`, `GET /api/requests`

**Every request that reaches the card gets an id, the moment it arrives.** It's in the
`X-Request-Id` header of the answer to `/api/run`, `/api/compose` and `/api/runs/{id}/stop`, in
that answer's JSON as `request` (the run's JSON, the `202`, the `403` for Don't Run), and in every line of a stream. Keep it: whether your app waited for the answer, streamed
it, hung up, or asked with `"async": true`, `GET /api/requests/{id}` says where the request is,
and the app keeps the latest 500 for as long as it runs.

```bash
curl -si localhost:8768/api/run -d '{"script": "backup.sh", "async": true, "client": "My App", "why": "Nightly backup"}'
```

```
HTTP/1.1 202 Accepted
X-Request-Id: 2A7C4B19-…
{"request": "2A7C4B19-…", "state": "waiting", "url": "/api/requests/2A7C4B19-…", "message": "On the Mac, waiting for Run; …"}
```

`"async": true` answers before anyone has clicked: the card stays on the Mac, and the run (if
allowed) goes on without you. Then, whenever you like:

```bash
curl -s localhost:8768/api/requests/2A7C4B19-…
```

```json
{
  "request": "2A7C4B19-…", "state": "succeeded", "ok": true, "kind": "script", "name": "backup.sh", "via": "run",
  "client": "My App", "from": "this Mac", "why": "Nightly backup",
  "asked": "2026-10-23T09:12:00.004Z", "answered": "2026-10-23T09:12:07.318Z",
  "run_id": "6C1D2F0E-…", "run_url": "/api/runs/6C1D2F0E-…", "url": "/api/requests/2A7C4B19-…",
  "run": { "id": "6C1D2F0E-…", "state": "succeeded", "ok": true, "code": 0, "output": "…", "stdout": "…", "stderr": "", … }
}
```

| field | |
|---|---|
| `state` | `waiting` (on the Mac, no click yet), `denied`, `not_answered`, `running`, then how the run ended: `succeeded`, `failed`, `stopped`, `could_not_start`; `stopped` for a stop request that was allowed; `withdrawn` when your app took it back before the click; `gone` when the run was cleared from the app's history |
| `ok` | once it's over: `true` for `succeeded`, `false` otherwise (absent while `waiting` or `running`) |
| `kind`, `name`, `via` | what was asked for (`script`, `flow` or `stop`), its name, and the endpoint it came through (`run`, `compose`, `stop`) |
| `client`, `from`, `why` | who asked, from where, and why (as the card showed them) |
| `asked`, `answered` | when it arrived, and when the person clicked (or the two minutes ran out) |
| `run_id`, `run_url`, `run` | once started: the run's id, its address, and the run itself with everything it printed (as `/api/runs/{id}` gives it) |
| `code`, `error` | when it didn't run: `denied`, `not_answered`, or why it couldn't start |
| `delivery`, `note` | whether its result is still to come, ready, handed over in this answer, or cleared (below), in a sentence |
| `cleared`, `cleared_by` | once cleared: when, and how (`delivered`, `collected`, `dismissed`, `withdrawn`) |
| `next` | what to call next: ask again, collect it, stop it, the run, the open requests |

Poll it as often as you like (every second is fine; nothing runs for the asking). `GET
/api/requests?limit=20` lists the latest requests, newest first, each as above without `run`.
An id the app doesn't have is `404 unknown_request`. The runs themselves (`/api/runs`,
`/api/runs/{id}`) carry `request` too, so you can go either way.

#### Each result is handed over once

There's one client, so the app keeps track for it of what it has collected. A request's result is
**handed over once**, and then it's **cleared**:

- Waited for (the default), streamed, or refused there and then: the answer itself carries the
  result (`"delivery": "delivered"`), so it's cleared at once.
- Sent with `"async": true` (or `"wait": false`): while it's `waiting` or `running`, reading
  `/api/requests/{id}` takes nothing (`"delivery": "pending"`, `run.output` so far). Once it's
  over, **the first read hands over the result** (`"delivery": "delivered"`, with `run`) and
  clears it.
- Asked about again once cleared: `"delivery": "cleared"`, `cleared`, `cleared_by` (`delivered`,
  `collected`, `dismissed` or `withdrawn`), and how it ended (`state`, `ok`, `code`, `run_id`), but
  not `run`. The run itself is still at `run_url` while the app keeps it (until Clear Finished).
- `?peek=true` looks without taking it (`"delivery": "ready"`).

| `delivery` | it means |
|---|---|
| `pending` | waiting for the click, or running: nothing to collect yet; ask again in a few seconds |
| `ready` | over, not collected (in the open list, or read with `?peek=true`) |
| `delivered` | this answer is the result, handed over once; it's cleared now |
| `cleared` | handed over before (or cleared without it): how it ended, without the output |

#### `GET /api/requests/open`

The requests not cleared yet, **oldest first** (the order you sent them), each with where it is,
without the output. It's the way back after a while away: what's still waiting for the person,
what's running, and what's ready to collect.

```json
{
  "ok": true, "count": 3, "waiting": 1, "running": 1, "ready": 1, "order": "oldest first",
  "requests": [
    {"position": 1, "request": "2A7C…", "name": "backup.sh", "state": "succeeded", "ok": true, "delivery": "ready", "url": "/api/requests/2A7C…", …},
    {"position": 2, "request": "9F01…", "name": "report.flow", "state": "running", "delivery": "pending", "run_id": "…", …},
    {"position": 3, "request": "4B2E…", "name": "speak.sh", "state": "waiting", "delivery": "pending", "message": "On the Mac, waiting for Run", …}
  ],
  "next": [{"method": "GET", "path": "/api/requests/2A7C…", "why": "collect backup.sh's result (succeeded): it's handed over once, then cleared"}, …]
}
```

`GET /api/health` counts them too (`"requests": {"open", "waiting", "running", "ready"}`).

#### Clearing without reading: `DELETE /api/requests/{id}`, `POST /api/requests/clear`

- `DELETE /api/requests/{id}` on one that's over clears it without handing it over
  (`"cleared_by": "dismissed"`).
- On one sent with `"async": true` and still **waiting for the click**, it's **taken back**: the
  card goes from the Mac, nothing runs, and the request's state is `withdrawn` (`ok: false`). One
  whose caller is still on the line waiting is `409 still_waiting` (hang up to take it back).
- On one that's **running**: `409 still_running`; stop it first (`POST /api/runs/{run_id}/stop`).
- `POST /api/requests/clear` clears every request that's over and not collected
  (`{"requests": [ids]}`: only those) → `{"cleared": [ids], "still_open": [...]}`.

### `GET /api/runs`, `GET /api/runs/{id}`, `POST /api/runs/{id}/stop`

`/api/runs?limit=20` gives the latest runs, newest first, each as above without `output`,
`stdout`, `stderr` and `steps`. `/api/runs/{id}` gives one with everything (and `request`, the id
of the request it came from, when it came over the API). `…/stop` stops it (a
flow's step stops its flow) and answers `{"ok": true, "stopping": true}` (`false`: it had already
ended). An id the app doesn't have (runs are kept until **Clear Finished**, the latest 300) is
`404 unknown_run`.

**A run the person started is theirs.** A run that came over the API (any app's, once the person
allowed it) stops at once. One the person started (its cell, a flow, a schedule) puts a card on
the Mac first, *"My App wants to stop a run you started"*, with **Stop It** and **Keep Running**:
send `client` and `why` in the body as for a run. It answers like a run request: `403 denied` or
`not_answered` when it's left running, else `{"ok": true, "stopping": true, "request": "…"}`, and
`GET /api/requests/{id}` has it (`"kind": "stop"`, `"state": "stopped"`).

---

### The file library: `/api/library`

**LIBRARY**, in STORAGE-SPACES/USER on the person's Desktop ([Storage Spaces](https://github.com/ainigh/tool-mac-tool-run-storage-spaces) keeps it, and serves the same files at http://127.0.0.1:8771), holds their notes: Markdown files, each known by its name
without `.md` (`groceries` is `LIBRARY/groceries.md`). A name is a key and its text the value.
**Nothing here shows a card or waits for a click**: the library's calls answer at once. Deleting
a note only moves it to the library's own Trash folder, numbered (`groceries (1).md`, `groceries
(2).md`…), so several of the same name can wait there and `restore` brings back the latest, or the
one you name. The person sees the same notes on the app's **Library** board (⌘7), and flows reach
them too (`libraryRead`, `libraryWrite`…).

**Every call has an id**, as a run's request does: the `X-Request-Id` header and `request` in the
JSON (refusals too). `GET /api/library/operations/{id}` — or `GET /api/requests/{id}` — says what
it was, who asked and how it went; `GET /api/library/operations?limit=20` lists the latest.

**The easy way: one endpoint for everything.** `POST /api/library` with `{"op": "…", …its fields}`:

| op | fields | gives back |
|---|---|---|
| `list` | `sort` (`name`·`modified`·`created`·`size`), `order` (`asc`·`desc`), `q` (words in the name), `limit`, `offset`, `content` | `notes`: `[{name, file, title, size, modified, created, text?}]`, `count`, `total` |
| `names` | | `names`, A to Z |
| `read` | `name` | `name`, `text`, `title`, `size`, `words`, `lines`, `modified`, `created` |
| `read_many` | `names` | `notes` (each with its `text`), `missing` |
| `exists` | `name` | `exists` |
| `write` | `name`, `text` | the note, and `new` (true: it was created) and `action` (`created`·`replaced`) |
| `create` | `name`, `text`? | the note; **409** `already_exists` if the name is taken |
| `append` | `name`, `text` | adds it on a line of its own at the end (creating the note if needed); `action`: `created`·`appended` |
| `rename` | `name`, `to`, `overwrite`? | the note under its new name (`overwrite`: the one there goes to the Trash first) |
| `copy` | `name`, `to` | the copy |
| `delete` | `name` | `trash`: `{name, number, file, deleted}` |
| `search` | `q`, `match` (`all`·`any`), `case_sensitive`, `whole_words`, `names_only`, `lines` (5), `limit` | `results`: `[{name, score, lines: [{line, text}], …}]`, the best first |
| `find` | the same | `names`, the best first: "list the files by the search's result" |
| `recent` | `limit` (10) | `notes`, the latest changed first |
| `outline` | `name` | `headings`: `[{level, text, line}]` |
| `backlinks` | `name` | `results`: the notes linking to it (`[[name]]`, or a Markdown link to its file) |
| `stats` | | `notes`, `bytes`, `words`, `trashed`, `newest` |
| `trash` | | `trash`: what's in it, the latest deleted first |
| `restore` | `name`, `number`?, `as`? | the note, back (the latest of that name unless `number`; `as` another name when it's taken) |
| `empty_trash` | `older_than_days`? | `deleted`: how many, for good |

A search's words must all be in the note (`"match": "any"`: one is enough), in its name or its
text; a `"phrase in quotes"` is one; case and accents never matter (`cafe` finds `café`). A name in
its name counts more than in its text.

**Or a route each**, for the usual ones: `GET /api/library/files` (list, with the same fields as
query parameters), `POST /api/library/files` (create), `GET|PUT|DELETE /api/library/files/{name}`
(read, write, to the Trash), `POST …/{name}/append|rename|copy`, `GET …/{name}/exists|outline|backlinks`,
`GET /api/library/names|search|find|recent|stats|trash`, `POST /api/library/trash/restore|empty`.
`PUT` takes the text itself as its body too (`text/plain` or `text/markdown`), and
`GET /api/library/files/{name}?format=text` gives the text alone, as Markdown.

```bash
curl -s localhost:8768/api/library -d '{"op": "create", "name": "Trip to Lagos", "text": "# Trip\n- book the flight\n", "client": "My App"}'
curl -s localhost:8768/api/library -d '{"op": "append", "name": "Trip to Lagos", "text": "- call the bank"}'
curl -s localhost:8768/api/library -d '{"op": "find", "q": "bank"}'          # {"names": ["Trip to Lagos"], …}
curl -s -X PUT localhost:8768/api/library/files/groceries -H 'Content-Type: text/markdown' --data-binary @groceries.md
curl -s -X DELETE localhost:8768/api/library/files/groceries                 # {"trash": {"file": "groceries (1).md", …}}
curl -s localhost:8768/api/library/trash/restore -d '{"name": "groceries"}'
```

Names: any words but `/` and `:`, not starting with a dot (`groceries.md` is `groceries`); case
and accents don't matter when one is looked up. A name that isn't there is **404** `not_found`,
with `fix` naming the notes near it; **400** `bad_name`, `missing_op`, `unknown_op`; **409**
`already_exists`. The `library` switch turns them all off (**503** `endpoint_off`).

### MEMORY: `/api/memory`

**MEMORY**, in STORAGE-SPACES/USER beside LIBRARY, is an opinionated library: it comes with a file for
each kind of thing worth remembering — `PEOPLE`, `ORGANIZATIONS`, `EVENT-DATES`, `BIRTHDAYS`,
`LOCATIONS`, `IDEAS`, `LEVERAGE`, `STRATEGIES`, `OTHERS` — and **every file is a node of the mind**
(below), in its root scope. Every library operation and route works here too, with `/api/memory`
for `/api/library` (`GET /api/memory/files/PEOPLE`, `POST /api/memory/files/PEOPLE/append`…); a
file written, made, copied, restored or renamed keeps its node in step (the answer's `mind` says
what was added). Nothing asks on the Mac. Its own operations:

| op | route | fields | gives back |
|---|---|---|---|
| `remember` | `POST /api/memory/remember` | `category` (a file: `PEOPLE`…), `about` (the name), `text`?, `links`? (`[{label?, to, category?}]`), `notes`? (`["birthday 03-14"]`) | `file`, `node`, `added_to_file`, `added_to_mind`: a line in the file (`- Ada Lovelace: …`), and in the mind `\| PEOPLE \| ada lovelace`, its links (filed under their category too) and notes |
| `recall` | `GET /api/memory/recall?name=…` | `name` | `found`, `nodes`, `about` (each node's `notes` and `links`), `categories` (the files it's under), `mentions` (lines in the files), `lines` (all of it, as text) |
| `categories` | `GET /api/memory/categories` | | each file: `default` (one MEMORY comes with), `members` (how many the mind files under it) |
| `members` | `GET /api/memory/categories/{name}/members` | `name` | what the mind files under it |
| `upcoming` | `GET /api/memory/upcoming` | `days` (30) | `upcoming`: `[{day, in_days, what, source, yearly}]`: dated notes in the mind, and lines in the files that start with a day (`2026-11-03`; `03-14` comes round every year, as does any day in BIRTHDAYS) |
| `sync` | `POST /api/memory/sync` | | makes each file a node (the ones that aren't) |
| `defaults` | `POST /api/memory/defaults` | | puts back any of the nine files that isn't there |

A memory file's name is a node's name too: words, with no `@` and no `-`, `|` or `=` after a space
(`EVENT-DATES` is fine), else **400** `bad_name`. Deleting a file moves it to MEMORY's Trash; its
node stays in the mind. [docs/system/MEMORY-GUIDE.md](docs/system/MEMORY-GUIDE.md) has more.

```bash
curl -s localhost:8768/api/memory/remember -d '{"category": "PEOPLE", "about": "Ada Lovelace", "text": "Met at the conference",
  "links": [{"label": "works at", "to": "Acme", "category": "ORGANIZATIONS"}], "notes": ["birthday 03-14"], "client": "My App"}'
curl -s "localhost:8768/api/memory/recall?name=ada"
curl -s "localhost:8768/api/memory/upcoming?days=30"
```

### The mind: `/api/mind`

The mind is `MIND/mind.txt` in STORAGE-SPACES/USER: lines in the [text mind-map notation](docs/Text%20mind-map%20notation.md)
that compile to a graph (things, and directed or undirected links with labels and notes, in
scopes). **It's only ever added to**: every change, even a rename (`| old = new`) or a forget
(`| old =`), is a line appended; the log is the record. Nothing asks on the Mac. MEMORY's files
are its root nodes. The Mind board (⌘9) draws it.

**Asking, without the notation** (names are looked up as a person means them: case, spaces, "the",
plurals, a few letters off):

| route | gives back |
|---|---|
| `GET /api/mind/nodes/{name}` | its `notes`, its `links` (`[{node, direction: out·in·both·undirected, labels, notes}]`), `lines`; and `memory_text` for a MEMORY file |
| `GET /api/mind/nodes/{name}/neighbors?depth=2&direction=out·in·both` | the nodes around it, the nearest first |
| `GET /api/mind/path?from=…&to=…` | the shortest way: `nodes`, `lines` (`found`: false when there's none) |
| `GET /api/mind/find?q=…` | nodes with the words in their name, notes or links' labels |
| `GET /api/mind/edges?label=works at` | the edges with that label (`&contains=true`: with it in it) |
| `GET /api/mind/notes?kind=date` | the notes of a kind (`@date 2026-11-03`), on nodes and edges |
| `GET /api/mind/dates?days=30&past=0` | the days coming up in the notes |
| `POST /api/mind/context {"text"}` | the part of the mind the text is about (the nodes named in it, one step out), as `lines`: what to give a model with a conversation |
| `GET /api/mind/nodes`, `/scopes`, `/graph`, `/stats`, `/layout`, `/problems` | the rest of it |
| `GET /api/mind/log`, `/canonical` | the log as written, and in its shortest form (one line a fact), as `text/plain` (`?format=json`: lines) |

**Asking in the notation**: `POST /api/mind/query {"q": "| sam | x"}`. A name that isn't in the mind
is a variable: `| sam | x` (every edge from sam), `| x - reviews | y`, `| paper @x` (its notes),
`| paper @date` (its notes of that kind), `| @ talk` (the scope). The answer: `lines` (every line
that matched), and `answers` (each query line's `matches`, with `bindings`).

**Adding, without the notation**: `POST /api/mind/add {"from", "label"?, "to"?, "undirected"?,
"notes"?}` or `{"facts": [those]}`; `POST /api/mind/note {"name", "note"}`, `/rename {"name", "to"}`,
`/forget {"name"}`, `/comment {"text"}`. A name the mind has (the same but for case) is used as it
is; a new one is written in lower case (`"keep_case": true` keeps it). Text that would read as a
symbol (` - ` in a note) is made safe, and `rewritten` says so.

**Adding in the notation**: `POST /api/mind/append {"lines": ["| sam - writes | paper"]}`, or
`{"text": "<a model's reply>"}` (the lines of its ```` ```mm ```` block that start with `|`), with
`scope`? and `comment`?. Every line is checked against the mind first; **one mistake and nothing is
written**: **400** `bad_lines` with `problems: [{line, text, error, fix}]` (`"partial": true`
writes the others). Lines that add nothing are left out (`known`). Each addition is stamped with a
comment line (when, and the `client`). Deleting or merging a scope is refused: it's the person's
(the board asks them). `POST /api/mind/check` answers the same without writing (`would_add`,
`known`, `problems`). `POST /api/mind/prompt {"messages"}` gives the notation's prompt for a small
model, filled in with the part of the mind the messages touch, and its `grammar` (GBNF): send the
model's reply to `append`. `POST /api/mind/compact` rewrites the log in its shortest form, keeping
the old one in `MIND/Archive`.

```bash
curl -s localhost:8768/api/mind/add -d '{"facts": [{"from": "sam", "label": "writes", "to": "the paper"}, {"from": "ana", "label": "reviews", "to": "the paper"}]}'
curl -s localhost:8768/api/mind/nodes/sam
curl -s localhost:8768/api/mind/query -d '{"q": "| x - reviews | y"}'
curl -s localhost:8768/api/mind/append -d '{"lines": ["| sam - moved to | lagos", "| sam @date 2026-10-17 moved"]}'
```

### SYSTEM-DOCS: `/api/system-docs`

How the app works, for people and for models, as a shelf the app writes (each time it starts) and
nobody changes: `START-HERE`, `PROMPT-ASSISTANT` (a system prompt for a model using the app),
`PROMPT-MIND-KEEPER`, `PROMPT-SITE-GUIDE`, `RECIPES`, `EXCHANGES`, `MEMORY-GUIDE`, `MIND-GUIDE`,
`BROWSER-GUIDE`, `PRESENT-AND-COPY`, `TOOL-MAC-RUN`, the Flow, Straw and agents guides, this
document, the notation (`MIND-NOTATION`), and docs made from the app itself (`API-REFERENCE`,
`API-ROUTES`, `FLOW-FUNCTIONS`, `STRAW-WORDS`). The library's reading routes answer here
(`GET /api/system-docs/files/{name}`, `/search`, `/names`, `/files/{name}/outline`); a write is
**403** `read_only`. The sources are [docs/system](docs/system).

### Showing and copying: `POST /api/present`, `POST /api/clipboard`

`POST /api/present` shows something on the Mac in a window that comes in front of everything,
with copy buttons (the whole, each section, each piece of code; for the mind, each line) and the
things shown before it: a file (`{"shelf": "memory", "name": "PEOPLE"}`; shelves `library`,
`memory`, `system-docs`), a node of the mind (`{"mind": "ada lovelace"}`; `""`: the whole mind), or
any text (`{"title", "text", "format": "markdown"·"text"·"json"}`). `why` is shown under the title;
`"copy": true` copies it too. `POST /api/clipboard` puts `{"text"}` (or a file, or a node) on the
clipboard. Neither asks first; the **Show and copy** switch turns them off. The clipboard isn't
read.

**On any answer**: every library, memory, system-docs, mind and browser call takes `"copy": true`
(or `?copy=true`) to put its answer's text on the clipboard (`"copied": true`), and
`"present": true` to show it in that window (`"presented": true`). The text is a file's text, the
lines found, the names, or else the JSON.

### In plain words: Peter

Saying what you want in words is [Peter's](https://github.com/ainigh/tool-mac-tool-run-agent)
(Tool Mac Agent), an app of its own beside this one: `POST http://127.0.0.1:8770/api/say`. He
makes his templates from what this API lists (`GET /api/tools`, `GET /api/scripts`, `GET
/api/flows`: each script's and flow's `say`, from its header's `# Say:` lines), calls the tools
for you, and answers in words. `/api/say` here answers `404 moved`.

### Tools, for a model: `GET /api/tools`, `POST /api/tools/{name}`

An app with a model doesn't have to teach it the routes. `GET /api/tools` is everything here as a
short list of tools to hand the model as is, and `POST /api/tools/{name}` calls one: the app passes
the model's calls through, and a tool added here is there the day it ships, with nothing to change
in the app.

```json
{"ok": true, "count": 19,
 "tools": [{"name": "web_fetch", "description": "Reads any web address from this Mac, at once …",
            "args": [{"name": "url", "type": "string", "required": true, "about": "the address (https://…) …"},
                     {"name": "find", "type": "string", "required": false, "about": "words: only the lines that have them"}],
            "asks_on_the_mac": false, "answers": "at once", "stream": false, "on": true,
            "aliases": ["fetch", "open_url", …], "call": "POST /api/tools/web_fetch", "uses": "GET /api/web/fetch"}, …],
 "guide": ["Every tool answers in JSON. An error has \"error\", often \"fix\", and \"tools\" …", …],
 "examples": [{"user": "When does the Louvre open on Sunday?",
               "steps": [{"call": {"tool": "web_search", "arguments": {"q": "Louvre opening hours"}}, "result": "…"}, …],
               "answer": "On Sundays the Louvre is open from 9 in the morning to 6 in the evening."}, …]}
```

- **The tools**: `find` (the tools, scripts and flows for a few words), `say` (all of it in plain
  words, [above](#say-plain-words-post-apisay)), `run_script`, `run_flow`,
  `run_flow_code`, `check_flow`, `runs`, `web_search`, `web_fetch`, `browser`, `straw`, `library`,
  `remember`, `recall`, `memory`, `mind`, `show`, `copy`, `docs`, `call_api` (any route no tool
  covers). A tool whose switch is off is left out (`?all=true` lists it, `"on": false`).
- **`guide`** is a line each on using them well (find before guessing; the web before saying you
  can't; which tools wait for Run); **`examples`** are exchanges that show calls at work. Both are
  for the model's instructions, so they're written here, beside the tools they're about.
- **Calling one**: `POST /api/tools/web_fetch {"arguments": {"url": "https://example.com"}, "client":
  "My App"}`. The answer is the JSON of the route the tool stands for, with `"tool"`. `run_script`,
  `run_flow`, `run_flow_code` and `straw` wait for Run on the Mac (send `"why"`), and stream with
  `"stream": true` (NDJSON, as `POST /api/run`); everything else answers at once.
- **The names a model reaches for** are taken: another name for a tool (`google` is `web_search`,
  `list_runs` is `runs` with `op` `list`, `notes` is `library`), another for an argument (`query`
  for `q`, `address` for `url`), the arguments flat instead of under `"arguments"`, and a script's or
  flow's own name as the tool (it's run, with its `args`).
- **A miss says what to do**: `404 unknown_tool` names the tools there are and what fits the
  words; `400 missing_argument` says what's missing; every error has `"takes"` (what the tool
  takes) and `"tools"` (what fits instead, a line each).
- `GET /api/search` finds tools too (`"kind": "tool"`), and gives each hit as a line a model reads
  (`"lines"`: `tool web_fetch: Reads any web address … | takes: url (string): …`).

### The web: `GET /api/web/search`, `GET /api/web/fetch`

The web, read from this Mac without Chrome, answered at once: a model finds things out the way a
person would (search, read the best result, follow a link or the JSON API a page points to).

| route | gives back |
|---|---|
| `GET /api/web/search?q=louvre+opening+hours` (`?limit=8`) | `results`: `[{title, url, snippet}]`, `lines` (one a result), `engine` (DuckDuckGo, else Bing) |
| `GET /api/web/fetch?url=https://…` (`?find=words`, `?max=8000`) | `url`, `status`, `type`, `kind` (`page`, `json`, `text`, `file`); a page's `title`, `description`, `text` (its main part, without scripts, styles, menus or footers) and `links` (`[{text, url}]`, whole addresses); a JSON API's `json`; `chars`, `truncated`, `more`; with `find`, `lines`: the lines that have the words |

It only reads: GET, a browser's User-Agent, no cookies, nothing sent but the address. It never
reaches this Mac or its local network (`localhost`, `192.168.…`, `10.…`, `*.local`, `169.254.…`):
**403** `local_address`, and a redirect there is refused too. Errors: **400** `bad_url`, **502**
`unreachable` · `search_failed`, **504** `timed_out`, each with its `fix`. The **Read the web**
switch turns it off (and its tools with it).

### Chrome's page: `/api/browser`

Google Chrome, answered at once (nothing asks on the Mac): open a page, read it, find where a
thing is, and ring it in red. **It never clicks, types or fills anything in**: that's Straw, after
Run.

**Where** (`"where"`, on every route, and on Straw): each of these works the same in three places.

| `where` | What it is |
|---|---|
| `side_by_side` (the default) | a Chrome window of the app's own on the right half of the screen, and the person's own Chrome window moved to the left half: the app works beside the person, each in a window of their own. The person's window stays in front, theirs to work in |
| `on_screen` | the person's own tab in front of them (to guide them through what they're looking at) |
| `background` | the app's own window, kept behind the person's: nothing on their screen moves |

`open` with no `where` opens side by side (or where the app's own window already is). A read
(`url`, `page`, `has`, `find`, `highlight`, `outline`, `tabs`) with no `where` reads the app's own
window while there is one, else the person's tab. Every answer says which (`"where"`, and
`"where_said"` in words). `POST /api/browser/place {"where"}` moves the app's own window (side by
side, or behind; `on_screen` closes it), and `POST /api/browser/close` closes it and puts the
person's window back where it was. The first side by side brings Chrome forward; after that, what
the person moves stays moved. Asked for a place with no window of its own yet: `409
no_window_of_its_own`, with the call that opens one. Words work too: `"beside me"`, `"on my
screen"`, `"in the background"`.

| To | Use | Asks on the Mac |
|---|---|---|
| open a page beside the person (and read it) | `POST /api/browser/open {"url": "example.com"}` (side by side) | no |
| open a page in the person's own window | `POST /api/browser/open {"url": "example.com", "where": "on_screen"}` | no |
| find something out, without Chrome | `GET /api/web/search?q=…`, `GET /api/web/fetch?url=…` | no |
| see what's on a page (its own, or the person's with `"where": "on_screen"`) | `/api/browser/url`, `/page`, `/has`, `/find`, `/outline` | no |
| show the person where something is | `POST /api/browser/highlight {"text"}` | no |
| click, type, fill, several steps | Straw: `POST /api/straw/run {"source": "open example.com\nclick \"More\""}` | yes (Run) |
| search a site (YouTube, Amazon, GitHub, Maps, 40 more) | `POST /api/run {"script": "browser/site-search.sh", "args": ["youtube lofi hip hop"]}` | yes (Run) |

`POST /api/browser/open {"url", "where"?, "new_tab"?, "max"?}` opens the address: side by side
or in the background, in the app's own window (made when there's none; it goes to the page, or a
new tab with `"new_tab": true`); on screen, in a new tab of the person's window, in front (in a
new window, or Chrome itself, when there's none; `"new_tab": false` uses the tab in front). It
waits up to 15 seconds for it to load, and answers with the page as `/page` reads it
(`"opened": true`, `title`, `url`, `text`, `links`). Words instead of an address are a Google
search, opened (`"searched"`). An address sent to a read (`/api/browser/url?text=https://…`)
isn't opened: the answer is the page it reads as always, with `"not_opened"`, a `"note"`, and `next`
giving the call that opens it. An action it doesn't do (`/api/browser/click`, `/type`, `/search`…)
is `400 browser_reads_only`, saying what does.

To work beside the person, or guide them through a site, an app sees the page itself — not a
picture: its address and title, its text and links, whether words are on it, and where a thing is.
The **Chrome's page** switch turns it off.

| route | gives back |
|---|---|
| `GET /api/browser` | `chrome` (`open`, or what's wrong), `front` (`{title, url}`: the person's), `its_window` (`{id, where}`, or null), `javascript` (whether pages can be read, and the fix) |
| `GET /api/browser/url` | `title`, `url`, `loading` (needs nothing switched on in Chrome) |
| `GET /api/browser/tabs` | `tabs`: `[{window, index, active, title, url}]` (`?all=true`: every window) |
| `GET /api/browser/page` | `title`, `url`, `host`, `text` (`?max=20000` characters; `chars`, `truncated`), `links` (the main part's, `[{text, url}]`), `selection`, `description`, `scroll`, `focused` (`?outline=true` adds `outline`) |
| `POST /api/browser/open {"url", "where"?}` | opens it (side by side unless `where` says) and reads it: `opened`, `where`, then as `/page` |
| `POST /api/browser/place {"where"}` | the app's own window put side by side (the person's to the left half) or behind; `on_screen`: closed, as `/close` |
| `POST /api/browser/close` | the app's own window closed, the person's put back where it was (`restored`) |
| `GET /api/browser/has?text=Compute` | `present` (true·false), `answer` (yes·no), `count`, `hidden` (times in what isn't shown), `lines` (`?case_sensitive`, `?whole_words`) |
| `GET /api/browser/find?text=Compute` | `found`: `[{text, kind, clickable, exact, shown, where, side, in, href, box}]` — `where` is `in view`, `above (scroll up)`, `below (scroll down)`, or `inside “Workers & Pages”, which is closed: open it first`; `lines`: each as a sentence to say |
| `POST /api/browser/highlight {"text", "seconds"?}` | scrolls to it and rings it in red, with a label (or the closed menu it's inside); `said`: what to tell the person |
| `GET /api/browser/outline` | `headings`, `landmarks`, `navigation`, `buttons`, `fields`, `links` |

The first time, macOS asks whether the app may control Chrome. Reading inside a page needs
Chrome's **View > Developer > Allow JavaScript from Apple Events** (the address and title don't).
Errors: **409** `chrome_not_open` · `no_window` · `no_chrome`; **403** `javascript_off` ·
`not_allowed` (System Settings > Privacy & Security > Automation); **504** `timed_out`. Each has its
`fix`. [docs/system/BROWSER-GUIDE.md](docs/system/BROWSER-GUIDE.md) walks through guiding someone.

### Straw: `GET /api/straw`, `POST /api/straw/check`, `POST /api/straw/run`

[Straw](docs/STRAW-GUIDE.md) scripts drive Google Chrome by naming what's on the page (`open
news.ycombinator.com`, `click "More"`, `read all css ".titleline > a"`).

- `GET /api/straw`: its 25 words (`[{word, takes, does, example}]`), the Straw scripts in the
  folder (as `/api/scripts` gives them), and where its runner (`straw.py`) is.
- `POST /api/straw/check` with `{"source": "<Straw code>"}` (or the code as `text/plain`): nothing
  runs and nothing is asked. `{"ok": true, "steps", "plan": [what it would do, a line a step]}`, or
  `{"ok": false, "code": "straw_mistake", "line", "error", "fix"}`.
- `POST /api/straw/run` with `{"script": "hacker-news"}` (a Straw script's name) or `{"source":
  "<Straw code>", "name": "What to call it"}`: runs it in Chrome once the person clicks **Run**
  (the card shows your code in full). Code you send is checked first: a mistake is **400**, and
  nothing is asked. It takes `args`, `why`, `client`, `wait`, `async` and `stream` as `/api/run`
  does, and answers the same way: what the script read is its `stdout`; what it was doing, a line a
  step, is its `stderr`.

## Errors

Errors are JSON, `{"error": "what went wrong", "code": "…", "next": [...]}` (`next`: where to look
instead, such as a search for a route that isn't one):

| status | `code` | when |
|---|---|---|
| 400 | `missing_script`, `missing_flow`, `bad_args`, `bad_request` | the request isn't right |
| 400 | `missing_query`, `unknown_group` | a search without `?q=`, or a group that isn't one (`error` lists them) |
| 400 / 404 | `moved` | `automation`, `/api/automation` and `/api/say` are [Peter's](https://github.com/ainigh/tool-mac-tool-run-agent) now (Tool Mac Agent, port 8770) |
| 400 | `flow_mistake` | the Flow code has a mistake (with `line` and `fix`) |
| 400 | `straw_mistake` | the Straw code has a mistake (with `line` and `fix`) |
| 400 | `missing_op`, `unknown_op`, `bad_name` | a file library call that isn't right (`fix` says how) |
| 400 | `bad_lines` | lines for the mind have mistakes: `problems` has each line, its error and fix; nothing was written |
| 400 | `unknown_shelf` | `/api/present` or `/api/clipboard` named a shelf that isn't one (`library`, `memory`, `system-docs`) |
| 401 | `unauthorized` | sharing on the network is on and the request didn't send the token |
| 403 | `denied`, `not_answered` | it didn't run: Don't Run, or no answer in time |
| 403 | `forbidden` | a browser page from another site, a `Host` that isn't this Mac, or another machine while sharing is off |
| 403 | `read_only` | SYSTEM-DOCS can't be changed |
| 403 | `javascript_off`, `not_allowed` | Chrome doesn't let apps read inside pages yet, or macOS hasn't let the app control Chrome (`fix` says the switch) |
| 404 | `not_found`, `unknown_script`, `unknown_flow`, `unknown_run`, `unknown_request` | no such route, script, flow, run or request |
| 409 | `no_folder` | no scripts folder is chosen yet |
| 409 | `still_waiting`, `still_running` | a request can't be cleared yet: its caller is still waiting on it, or it's running (stop it first) |
| 409 | `already_exists` | a library note of that name is there already (`create`, `rename`, `copy`, `restore`) |
| 409 | `no_runner` | Straw code was sent, and the browser folder has no `straw.py` to run it |
| 400 | `browser_reads_only` | `/api/browser/click`, `/type`, `/search`…: Chrome's page doesn't act; `error` and `next` say what does (Straw, the web's search) |
| 409 | `chrome_not_open`, `no_window`, `no_chrome` | there's no page in Chrome to read (`POST /api/browser/open` opens one) |
| 409 | `no_window_of_its_own`, `window_gone` | asked for the app's own window (side by side, background) when there's none, or the person closed it: `POST /api/browser/open {"url", "where"}` makes one |
| 400 | `bad_where` | `where` isn't `side_by_side`, `on_screen` or `background` |
| 404 | `unknown_tool` | `POST /api/tools/{name}` for a tool there isn't: `error` names the tools, and what fits |
| 400 | `missing_argument` | a tool called without what it needs: `takes` says what it takes |
| 403 | `local_address` | the web's routes never reach this Mac or its local network |
| 400 | `bad_url` | not a web address (http or https) |
| 502 | `unreachable`, `search_failed` | the site didn't answer, or the search found nothing |
| 413 | `too_large` | a body over 8 MB |
| 501 | `not_available` | showing or the clipboard asked of something that isn't the app on a Mac |
| 503 | `endpoint_off` | that group is switched off in the app |
| 504 | `timed_out` | Chrome didn't answer in 30 seconds (macOS may be asking whether the app may control it) |
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
