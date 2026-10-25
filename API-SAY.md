# Say: the API for clients

`POST /api/say` is **the way in for a client**: say what you want in words, get plain words back.
It sits in front of everything else in [API.md](API.md) (scripts, flows, the web, Chrome, notes,
MEMORY, the mind, showing and copying) and calls it for you. A client that uses Say never needs a
route, a tool name, an argument, a request id, a poll or a line of JSON. Everything else in API.md
is still there, underneath, for a client that wants it; a new client should start here.

The client is often a model, and often a small one. Its instructions need one line:

> To use the Mac's tools, use `say`. Say what you want; if it offers templates, fill one in and say it back.

(Why it's built this way: [Talking to Tool Mac Tool Run](Talking%20to%20Tool%20Mac%20Tool%20Run%20-%20the%20problem%20and%20the%20approach.md).
Testing which model translates best: [BENCH.md](BENCH.md).)

```
Base URL   http://127.0.0.1:8768
```

## In one minute

```bash
# say what you want; who's talking is ?client= (each client has a conversation and a log of its own)
curl -s 'localhost:8768/api/say?client=My+App' -H 'Content-Type: text/plain' -d "what's the weather in Lagos"
# Asked for the weather. I'll tell you how it goes.

# not one of its templates: the translator reads it, and says how it took it
curl -s 'localhost:8768/api/say?client=My+App' -H 'Content-Type: text/plain' -d "gonna need an umbrella in Lagos tomorrow?"
# Taken as: what's the weather in Lagos
#
# Asked for the weather. I'll tell you how it goes.

# later: the news comes first in the next reply
curl -s 'localhost:8768/api/say?client=My+App' -H 'Content-Type: text/plain' -d "what have I asked for today"
# Meanwhile: The weather finished (it worked). Say "show me the weather" to see what it printed.
# …
```

## The exchange

| | |
|---|---|
| **Request** | `POST /api/say`, the words as the body (`Content-Type: text/plain`), or JSON `{"text": "…", "client": "…", "reply_to"?: "…"}` |
| **Who's talking** | `?client=`, the `X-Client` header, `"client"`, else the User-Agent. Each client has its own conversation, numbers and log. |
| **Answer** | `text/plain`, always `200`. A refusal or a failure is said in words. Never JSON, routes, file names or ids. |
| **Told when it's over** | `X-Reply-To` (or `"reply_to"`): an `http` address on this Mac. The moment a run of this client's is over, the news is POSTed there as `{"client", "text": "Meanwhile: …", "entries": [as /api/say/log has them]}`. |
| **As one tool** | `say` in `GET /api/tools`: `POST /api/tools/say {"arguments": {"text": "…"}}` answers the same text. |

Every reply has three parts, any of them empty:

1. **The news**: what changed in this client's requests since it last spoke (*Meanwhile: The
   nightly backup finished (it worked).*). Each change is told once.
2. **The answer**: what was done or found. A long one is cut to its first 20 lines (or 1500
   characters), then *(26 more lines: say "more" for the rest.)*. Lists are numbered, so the client
   can say "the second one".
3. **What you can say next**: one or two templates that usually follow.

## How what's said is read

The adapter reads what was said in this order and stops at the first that applies. Only the
last steps ever ask the model; everything before them is deterministic and answers at once.

```
said ─┬─ nothing at all ──────────────────────────────► "what can you do"
      ├─ a number, right after a numbered list ───────► that choice (done, or shown to fill)
      ├─ yes / no, to a question waiting ──────────────► done / "nothing was done"
      ├─ the labeled shape (a title, "- label: value") ► that template ─┬─ all there ──► done (or asked first)
      │                                                                 ├─ some missing ► "That needs … too"
      │                                                                 └─ a bad choice ► the choices there are
      ├─ the inline shape (a sentence) ─┬─ one clear fit ─────────────► done
      │                                 ├─ two about as close ───────► the translator, if it's sure
      │                                 │    (one of them changes)      else "Did you mean: 1. … 2. …"
      │                                 └─ only a loose fit, and it ─► the translator, if it's sure
      │                                      changes something          else "Did you mean …? Say yes"
      ├─ a template's title alone ────────────────────► the template, to fill (or done: it takes nothing)
      └─ none of these ───────────────────────────────► the translator: done if it's sure, offered if not
                                                         else the templates whose words fit, numbered
```

What counts as close (`Sources/RunCore/Say/SayMatch.swift`):

| Threshold | Value | Means |
|---|---|---|
| `floor` | 0.72 | the least a sentence, title or label must match to count at all |
| `part` | 0.75 | what each run of a template's fixed words must reach ("find {…} on the internet" isn't "find {…} on the page") |
| `clean` | 0.90 | a clean match: done at once (for a read, or a run the Mac will ask about anyway) |
| `sureChange` | 0.97 | a change that doesn't wait for the Mac (delete a note) is done at once only this sure; below it, it's asked about first |
| title alone | 0.85 | a title said by itself is taken as that template |
| translator `sure` | 0.75 | how sure the model must say it is for its reading to be acted on (a setting) |

**What's forgiving and what isn't.** Titles, fixed words, labels and choices match fuzzily (case,
punctuation, a misspelling, swapped letters, a small word missing); a corrected choice is said
(*taken as PEOPLE*). **Values are taken exactly as written** (quotes around one are taken off). In
a sentence a blank takes everything between its fixed words, the last one the rest. Of two
sentences as close, the more particular wins (`read the note {its name}` over `read {a web
address}`). Of two templates as good, the one this client has used more comes first.

**When it asks first.** Only when a match was uncertain and it would change something. A read is
always answered at once. A run is never asked about here: the card on the Mac is the question.

## Templates

A template is what the adapter offers and what it takes back. Two shapes:

```
Search the web                                  Remember something
  search the web for {what to look for}         - category: [PEOPLE | ORGANIZATIONS | … | OTHERS]
                                                - about: {who or what it's about}
                                                - fact: {what to remember}
                                                - date (optional): {a day, like 2026-11-03, or 03-14 for every year}
```

| Written | Means |
|---|---|
| a title (`Remember something`) | the template's name: plain words, stable from version to version (a renamed one keeps its old title, still taken) |
| `{…}` | a blank to fill; the words say what goes there |
| `[a \| b \| c]` | exactly one of these |
| `(optional)` | a line that may be left out |
| `- label: value` | one value a line, in any order |
| a label, then a fenced block | a value of several lines (note text, Flow code, Straw lines) |

**Inline** is for nothing or one value; **labeled** for two or more, or a value of several lines.
An inline template can be sent labeled too (its title, then a line per blank).
`GET /api/say/forms` lists every template there is now (`?q=words`: the ones that fit, best
first; `?format=json`: each with its fields).

### How templates map to what's done

Every template stands for one call underneath. The adapter makes the call, as the client, with
the client's own words as its reason (`why`), and keeps it in the client's log.

**The conversation's own** (always there, never searched):

| Template | Does |
|---|---|
| `what can you do` (`help`, `what can I say`) | a few lines of what there is |
| `what happened to {something you asked for}` (`how is … going`, `is … done`) | how a request is going |
| `what have I asked for [today \| recently \| since {a time}]` | the requests, numbered, each with how it went |
| `show me {something you asked for}` | what a request gave back, in full |
| `more` (`the rest`, `go on`, `continue`) | the next page of a long answer |
| `stop {something you asked for}` (`cancel …`) | taken back while it waits for the OK; stopped while it runs |
| `I'm done with {something you asked for}` (`never mind …`) | no more news about it |
| `start over` | the numbers and anything pending forgotten (the log is kept) |
| `yes` / `no` | the answer to a question waiting |

`{something you asked for}` is "the last one", a word from it ("the backup"), a time ("the one
around 3"), or a number from the last list ("the second one").

**The tools'** (`SayForms.tools` in `Sources/RunCore/Say/SayForms.swift`; a template is there only
while its switch in the panel is on):

| Template | Sentence or lines | Calls (tool → route) | Waits for the Mac |
|---|---|---|---|
| Search the web | `search the web for {what to look for}` · `look up {…} online` · `google {…}` | `web_search {q}` → `GET /api/web/search` | |
| Read a web page | `read the page at {a web address}` · `read {a web address}` | `web_fetch {url}` → `GET /api/web/fetch` | |
| Find words on a web page | `- address` `- words` | `web_fetch {url, find}` | |
| Open a page in Chrome | `open {a web address} in Chrome` · `go to {…}` · `open {…} side by side` | `browser {op: open}` (a window of the client's own, side by side) | |
| Open a page on my screen | `open {a web address} on my screen` | `browser {op: open, where: on_screen}` | |
| Open a page in the background | `open {a web address} in the background` | `browser {op: open, where: background}` | |
| Read the page in Chrome | `read the page in Chrome` · `what's on the page` | `browser {op: page}` | |
| Read my page | `read the page in front of me` · `what am I looking at` | `browser {op: page, where: on_screen}` | |
| Find something on the page | `where is {words on the page} on the page` | `browser {op: find}` | |
| Find something on my page | `where is {words on the page} on my page` | `browser {op: find, where: on_screen}` | |
| Point something out on the page | `point to {words on the page} on the page` · `highlight {…}` | `browser {op: highlight}` | |
| Point something out on my page | `point to {words on the page} on my page` | `browser {op: highlight, where: on_screen}` | |
| Work side by side | `work side by side with me` | `browser {op: place, where: side_by_side}` | |
| Put my browser back | `put my browser back` · `close your browser window` | `browser {op: done}` | |
| The tabs in Chrome | `what tabs are open` | `browser {op: tabs}` | |
| Do steps in Chrome | `- steps` (Straw lines) | `straw {source}` → `POST /api/straw/run` | yes |
| Remember something | `- category` `- about` `- fact` `- date (optional)` | `remember` → `POST /api/memory/remember` | |
| Recall something | `what do you know about {a name}` · `who is {a name}` | `recall {name}` | |
| What's coming up | `what's coming up [this week \| this month \| today \| in the next {a number of} days]` | `memory {op: upcoming, days}` | |
| What's filed under a kind | `what's filed under {a kind, like PEOPLE}` | `memory {op: members}` | |
| Link two things | `- from` `- link` `- to` | `mind {op: add}` | |
| How two things connect | `- from` `- to` | `mind {op: path}` | |
| Add a note to something | `- about` `- note` | `mind {op: note}` | |
| Read a note | `read the note {its name}` | `library {op: read}` | |
| Write a note | `- name` `- text` (several lines) | `library {op: write}` | |
| Add to a note | `- name` `- text` (several lines) | `library {op: append}` | |
| Find a note | `find the note about {a few words}` | `library {op: find}` | |
| Search my notes | `search my notes for {words}` | `library {op: search}` | |
| My notes | `what notes do I have` | `library {op: recent}` | |
| Rename a note | `- name` `- new name` | `library {op: rename}` | |
| Delete a note | `delete the note {its name}` | `library {op: delete}` (to the library's Trash) | |
| Bring a note back | `bring back the note {its name}` | `library {op: restore}` | |
| Show the person something | `- title` `- text` (Markdown) | `show` → `POST /api/present` | |
| Copy something | `- text` | `copy` → `POST /api/clipboard` | |
| Read a guide | `read the guide {its name}` | `docs {op: read}` | |
| Search the guides | `search the guides for {words}` | `docs {op: search}` | |
| The guides | `what guides are there` | `docs {op: list}` | |
| The latest runs | `what has run lately` · `what's running` | `runs {op: list}` | |
| Run Flow code | `- code` (several lines) | `run_flow_code` → `POST /api/compose` | yes |
| Check Flow code | `- code` (several lines) | `check_flow` → `POST /api/check` | |
| Run something by itself | `- what` `- when: [every morning \| …]` | `POST /api/automation` (Allow on the Mac) | yes |

**The folder's own**: every script and flow in the person's folder is a template, made from its
header, so nobody writes one by hand:

| The header says | The template |
|---|---|
| `# Say: what's the weather in {a city}` | that sentence (each `{…}` is one of its `# Input:` lines, in order); more `# Say:` lines are more ways to say it |
| nothing to say, no inputs | `run the {its name}` (`nightly-backup.sh` → `run the nightly backup`) |
| one input | `{its name}: {the input}` (`weather: {a place}`) |
| two inputs or more | labeled: a line for each `# Input:`, its `# Why:` in the blank |

Its title is its file name in words (`nightly-backup` → `Nightly backup`; a flow of the same name
is `Translate (a flow)`). The values go to its inputs in order (an `# Input:` that reads text gets
its value as stdin). It's asked for with `"async": true`: the person at the Mac sees the card.
The examples that ship with the app are said this way (`SayForms.exampleSay`): `what's the
weather in {a place}`, `what's in the news about {a topic}`, `set a timer for {how many minutes}
minutes`, `what does {a word} mean`, `convert money {an amount and two currencies}`, `what time is
it in {a city}`, `play {a song, artist or album} on YouTube Music`, `translate {what to translate}`,
`give me the morning briefing`, and more.

## The translator

The adapter's own matching is exact about what a template is and forgiving about how it's typed.
It can't know that *"gonna need an umbrella in Lagos?"* means the weather. That's the translator's
one job: **a model that reads what was said into the templates**, asked only when the words alone
don't settle it.

### When it's asked

| The words… | Without it | With it |
|---|---|---|
| match one template cleanly | done | **not asked** |
| match nothing closely | the templates whose words fit, numbered | asked; done if it's sure, offered if not, else as without |
| fit two templates about as well, and one changes something | "Did you mean: 1. … 2. …" | asked; done if it's sure, else as without |
| fit one only loosely, and it changes something | "Did you mean …? Say yes" | asked; done if it's sure, else as without |

It's **stateless**: each call is what was said, why it's asked, and the templates there are (the
closest by their words first). It sees no conversation, no history, no log, no results, no other
client. It never answers the request and never does anything: it says which templates it thinks
were meant, filled in, and how sure it is.

### What the model sees

The same instructions every time (`SayTranslator.system`, kept the same so a server can cache
them), and one message:

```
Said: "gonna need an umbrella in Lagos?"
Why: Nothing matched these words closely.

The closest templates by their words:

Weather (runs on the Mac once the person there OKs it)
  what's the weather in {a place}
  for: The weather now and for the next days: where this Mac is, or a place you name

All the other templates:

Search the web
  search the web for {what to look for}
Read a web page
  read the page at {a web address}
Find words on a web page
- address: {a web address}
- words: {what to look for on it}
…
Remember something (changes something)
- category: [PEOPLE | ORGANIZATIONS | EVENT-DATES | BIRTHDAYS | LOCATIONS | IDEAS | LEVERAGE | STRATEGIES | OTHERS]
- about: {who or what it's about}
- fact: {what to remember}
- date (optional): {a day, like 2026-11-03, or 03-14 for every year}
…
```

Every template there is goes in (all but `yes` and `no`): the closest by their words first (the
ones the words were between, then what search finds), each with what it's for; then the tools',
the conversation's own and the folder's, a line or two each. With the Examples added that's about
7,000 tokens: a local model needs a context of at least 8,192 (for Ollama, `OLLAMA_CONTEXT_LENGTH=16384`).

A full prompt, word for word, is in [BENCH.md](BENCH.md#what-the-model-sees).
`POST /api/say/translate {"text": "…", "dry": true}` gives it for any words, without asking a model.

### What it answers

JSON only:

```json
{"meaning": "tomorrow's weather in Lagos",
 "suggestions": [{"title": "Weather", "say": "what's the weather in Lagos", "confidence": 0.88},
                 {"title": "Search the web", "say": "search the web for rain in Lagos tomorrow", "confidence": 0.55}],
 "question": ""}
```

- `suggestions`: at most three, best first, each a template's title and **the template filled
  in, as a client would say it back**. A blank it can't fill is left as it is (`{a place}`), and
  asked about in `question`.
- `confidence`: 0 to 1. `meaning`: what the client wants, in a few words. `question`: one short
  question when something's missing or nothing fits, else `""`.
- Read forgivingly: a fence or words around the JSON, a lone suggestion instead of a list, a
  confidence as text or out of 100.

### What's done with it

The model's filling is **read back through the adapter's own matcher**, the way a client's
would be: a title there isn't is dropped; a filling that doesn't read as its template (at
`clean`, 0.9) becomes the template unfilled; a value left as `{…}` is a blank. So nothing reaches
a route that isn't one of the adapter's own templates with values it can take.

| The best reading is | Done |
|---|---|
| filled, at least `sure` (0.75), a read or a conversation's own | done at once, the reply starting `Taken as: <the template, filled>` |
| filled, at least `sure`, a run (it waits for the Mac) | asked for on the Mac (`Taken as: …`), the card saying the client's own words, not the model's |
| filled, at least `sure`, a change that doesn't wait for the Mac | asked first: *Did you mean: Delete a note (shopping)? Say yes to go ahead, or no.* |
| not sure, or not filled (only when nothing matched) | offered, numbered: *You might mean: 1. Weather what's the weather in {a place} 2. … Say its number to do it, or say one back changed.*, then its question. A number picks one: done when filled, shown to fill when not. |
| nothing usable (off, out of reach, not JSON, no template there is) | as without it |

*Taken as* is the point: the client sees the template its words became, and says it that way
next time without the model.

### Settings

Kept in `say-translator.json` in the app's Application Support folder (`~/Library/Application
Support/Tool Mac Tool Run/`, or where `TMR_TRANSLATOR` says), readable by its owner only.

| Setting | Default | |
|---|---|---|
| `on` | `true` | asked at all |
| `api` | `openai` | `openai`: any chat completions address (Ollama, LM Studio, llama.cpp, vLLM, OpenAI, OpenRouter…). `anthropic`: the Messages API. |
| `url` | `http://127.0.0.1:11434/v1/chat/completions` | Ollama on this Mac. With `api: anthropic`: `https://api.anthropic.com/v1/messages`. |
| `model` | `llama3.2` | with `api: anthropic`: `claude-opus-5-5` |
| `key` | empty | a bearer token (`openai`) or `x-api-key` (`anthropic`); empty: none, or `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` for the provider's own address. Never shown back. |
| `timeout` | 20 | seconds |
| `sure` | 0.75 | how sure it must be to be acted on |
| `format` | `json_object` | `openai` only: `json_object`, `json_schema` (the answer's schema, strict), or `none` |
| `effort` | `low` | `anthropic` only: `output_config.effort` (empty: not sent) |

With `anthropic`, the answer's shape is enforced (`output_config.format`, a JSON schema). With
`openai`, `temperature` is 0.

```bash
# a local model with Ollama (the default address)
ollama pull qwen2.5:7b
curl -s localhost:8768/api/say/translator -d '{"model": "qwen2.5:7b"}'

# Claude
curl -s localhost:8768/api/say/translator -d '{"api": "anthropic", "key": "sk-ant-…"}'

# off: the templates alone
curl -s localhost:8768/api/say/translator -d '{"on": false}'
```

**When it can't be reached**, the adapter answers as it does without one, and doesn't ask again
for 30 seconds (so each reply doesn't wait on a model that isn't there). `GET
/api/say/translator` says whether it's ready and shows its latest calls, errors and all.

**What leaves the Mac**: with a model elsewhere (`api.anthropic.com`, `api.openai.com`…), what
the client said and the templates' titles and wording (which include the names of the scripts
and flows in the folder) are sent there. Nothing else: no notes, no memory, no results, no log.
With a model on this Mac (the default), nothing leaves it.

## State: the adapter keeps it, the client doesn't

- **The log**: every request in words: what was asked, when, which template, how it's going, the
  system's id for it (never shown), whether its result was shown. A week, at most 200 requests a
  client, the latest 100 clients, while the app runs.
- **No polling**: the adapter follows each run itself, collects its result once it's over (so `GET
  /api/requests/open` no longer lists it), and tells it as news.
- **A conversation starts again** after six hours without a word: the numbers, "more" and anything
  waiting for "yes" are forgotten; the log stays. `start over` does it at once.
- **States** (as `/api/say/log` has them): `answered`, `done`, `failed`, `waiting` (for the OK on
  the Mac), `running`, `worked`, `denied`, `not_answered`, `withdrawn`, `could_not_start`, `stopped`.

## Consent stays the person's

A run (a script, a flow, Flow code, Straw, tagging something to run by itself) is asked for on
the Mac with a card that says which app, why in its own words (*My App asked in words: “gonna need
an umbrella in Lagos?”*), and exactly what would run. The reply only says it was asked for (*Asked
for the weather. I'll tell you how it goes.*); the detail comes when it matters, in the news or
when asked (*… hasn't started yet: it's waiting for someone at the Mac to OK it. Nothing has
run.*). Nothing the client says, and nothing the translator reads, stands in for that click.

## The rest of the group

| Route | |
|---|---|
| `GET /api/say` | how to use it, as text: the one line for a model's instructions, the forms that are always there |
| `GET /api/say/forms` | every template there is now (`?q=words`: the ones that fit, best first; `?format=json`: `{"forms": [{"title", "template", "kind", "shape", "sentences"?, "fields"?: [{"label", "blank"?, "choices"?, "optional", "multiline"}], "changes", "waits_for_the_mac", "formerly"?}]}`) |
| `GET /api/say/log` | what this client asked for, newest first: `{"entries": [{"number", "asked", "said", "template", "what", "state", "shown", "muted", "waits_for_the_mac", "request"?, "result"?, "ended"?}]}` |
| `POST /api/say/stop` | one of this client's requests called off by its number (`{"number": 3}`), for an app's Cancel button beside the model |
| `POST /api/say/reset` | start over (`{"forget": true}`: the log too) |
| `POST /api/say/translate` | the translator alone, stateless (below) |
| `GET /api/say/translator` | its settings (the key only as `"set"`), whether it's ready, its latest 20 calls |
| `POST /api/say/translator` | its settings changed, from this Mac only (any of the settings above) |

### `POST /api/say/translate`

The translator by itself, for trying models: nothing is done, and nothing is kept in a
conversation. `{"text": "…"}`, and optionally `"why": "nothing" | "between" | "weak"` with
`"between": ["Weather", "Search the web"]` (the titles the words were between, or the loose fit),
`"dry": true` (the prompt alone, no model asked), and any setting to try for this call only
(`"model"`, `"url"`, `"api"`, `"key"`, `"format"`, `"effort"`, `"timeout"`; from this Mac only).

```json
{"ok": true, "text": "will it rain in Lagos tomorrow", "why": "nothing", "model": "qwen2.5:7b", "seconds": 0.84,
 "prompt": {"system": "You translate what a client said …", "user": "Said: \"will it rain in Lagos tomorrow\"\nWhy: …"},
 "raw": "{\"meaning\": …}",
 "meaning": "tomorrow's weather in Lagos", "question": "",
 "suggestions": [{"title": "Weather", "say": "what's the weather in Lagos", "confidence": 0.88,
                  "template": "Weather", "complete": true, "taken": "what's the weather in Lagos"}],
 "top": "Weather", "templates_given": 215}
```

`template` is the template it was read back as (`null`: none there is), `complete` whether every
value it needs is there, `taken` what the adapter would take (`null` when it isn't complete).
`error` says why there's nothing (the model out of reach, its answer not JSON).

## For a client

1. Give the model one tool, `say(text) → text`, and the one line above.
2. Pass the model's calls through to `POST /api/say` with `?client=<your app>`.
3. If your app can listen, send `X-Reply-To` once: news arrives the moment a run is over, as a
   message from someone it asked.
4. That's all. No ids to keep, nothing to poll, no JSON to read.
