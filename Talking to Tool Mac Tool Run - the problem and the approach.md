# Talking to Tool Mac Tool Run: the problem and the approach

## Where we are

Tool Mac Tool Run serves scripts, flows, notes, memory, the web and the browser over a local HTTP
API. It already does a lot to be easy on clients:

- `/api/search` finds a route, script or flow by a few words.
- Every answer says what to call `next`.
- `/api/tools` packages everything as model-ready tools.
- The server keeps track of requests. Each request gets an id and the client polls with it. Once a
  finished result has been read, it's handed over and cleared, so asking again no longer lists it
  as open.

## The problem

The client is often a model, and often a **small** one. Its attention is divided: it's there to do
a narrow task (help the person, write the email, plan the trip), and every bit of this system it
has to hold in mind is taken from that task.

To use the system today, a client model has to:

1. **Know the tools exist** and carry their schemas (names, arguments, types) in its context.
2. **Load the docs**, or enough of them, to pick the right route or tool.
3. **Compose the call**: the right name, the right arguments in the right shape.
4. **Keep the request id** for anything that runs asynchronously.
5. **Remember to come back** and poll for status, then read the result.
6. **Interpret the answer**: JSON, states (`waiting`, `running`, `delivered`, `cleared`…), error
   codes and fixes.
7. **Track its own history**: what it asked for, when, and what came of it.

Each step is easy for a large model and a real cost for a small one. The cost is paid in the
context window (docs and schemas), in attention (switching from the task to the plumbing), and in
reliability (a forgotten poll, a misremembered id, a mistyped argument).

## The goal

**A client should only need to know how to talk.**

There should be one way in: say something, get plain words back. A client shouldn't need any tool
names, routes, arguments, ids, polling or JSON. Nothing has to be loaded first.

---

## The approach: a template adapter

### The idea in one paragraph

An adapter sits in front of the whole API and becomes the API. A client says what it wants. If
that doesn't match anything yet, the adapter treats it as a search and answers with a few
**templates**: the sentences or short forms that would do it, each with blanks to fill. The client
copies one, fills the blanks, and says it back. The adapter recognizes its own template, calls the
real API, keeps track of the request, and answers in plain words.

### Why this works

The hard part of understanding free language is pulling the arguments out of a sentence. The
adapter reverses who does the parsing. **The system offers the forms, and the model fills them.**
Filling a blank is easy for even a small model. Reading back a filled-in template is easy for a
script, because it wrote the template and knows its fixed words. Each side does what it's good at.

Clients also can't ask for things the system can't do, because they only ever fill forms the
system offered. Misunderstandings become rare, so confirmation turns become rare too.

This has a precedent in menu-based natural-language interfaces (Tennant's NLMenu, early 1980s),
which showed users only the sentences the system could understand and had them complete those.

### What it replaces

| The client used to | Now |
|---|---|
| carry tool schemas and docs | says what it wants; gets the forms that fit |
| compose a call | fills a form |
| keep a request id | refers to it in words: "the backup", "the last one" |
| remember to poll | hears about it at the start of its next reply |
| parse JSON | reads a few sentences |
| track its history | asks: "what have I asked for today?" |

---

## The template grammar

### Two shapes

**Inline**, for a capability that takes nothing or one value:

```
Search the web
  search the web for {what to look for}
```

**Labeled**, for anything with two or more values, or with a value that can run to several lines:

```
Remember something
- category: [PEOPLE | ORGANIZATIONS | EVENT-DATES | BIRTHDAYS | LOCATIONS | IDEAS | LEVERAGE | STRATEGIES | OTHERS]
- about: {who or what it's about}
- fact: {what to remember}
- date (optional): {a day, like 2026-11-03, or 03-14 for every year}
```

The labeled shape is the main one. A label on every line removes the ambiguity that inline
sentences run into when a value contains one of the template's fixed words. ("search for flights
to Lagos" contains "to".) It also means the order of the lines doesn't matter.

### Notation

| Written | Means |
|---|---|
| A title line (`Remember something`) | the capability's name. It's stable, plain words, never a file name or route. |
| `{…}` | a blank to fill. The words inside say what goes there. |
| `[a \| b \| c]` | choose exactly one of these. |
| `(optional)` after a label | may be left out. |
| `- label: value` | one value per line, in any order. |
| a label followed by a fenced block | a value of several lines (note text, Flow code, Straw code): |

````
Write a note
- name: groceries
- text:
```
- eggs
- milk
```
````

Everything else in a template is fixed wording.

### What the adapter accepts

The adapter is forgiving about everything except the values themselves:

- **Fixed words and titles** match fuzzily (edit distance, case, punctuation, a paraphrase close to
  the issued wording).
- **Labels** match fuzzily.
- **Choices** match fuzzily. When a choice was corrected, the reply says so ("taken as PEOPLE").
- **Values** are taken exactly as written. Quotes around a value are allowed, and removed.
- In the inline shape, a blank takes everything between its anchors, and the last blank takes
  the rest of the line.

### Where the templates come from

Nobody has to write them by hand. The system already describes everything:

- **Tools** (`/api/tools`) have arguments with `about` text, which give a labeled form directly.
- **Scripts and flows** have `# Input:` lines (each one a blank) with `# Why:` lines and
  `(optional)` marks, plus a summary for the title.
- **Routes** have summaries and tags.

Two optional additions improve the wording where the generated one is clumsy:

- a `# Say:` header line on a script or flow (`# Say: what's the weather in {a city}`)
- a `say` field on a route or tool

---

## Built-in forms

These are always available. They aren't found through search, because they're about the
conversation itself.

```
what can you do
what happened to {something you asked for}
what have I asked for [today | recently | since {a time}]
show me {something you asked for}
more
stop {something you asked for}
I'm done with {something you asked for}
```

`{something you asked for}` accepts any of these: "the last one", a word from its name or
description ("the backup"), a time ("the one around 3"), or a number from the last list the
adapter showed ("the second one").

---

## State: the adapter holds everything

- **The request log.** For each client, the adapter keeps every request id, what was asked, when,
  how it's going, and whether its result was delivered. The client never sees an id.
- **No polling.** The adapter polls itself.
- **News first.** Every reply starts with what has changed since the client last spoke:

```
Meanwhile: the nightly backup finished (it worked). Say "show me the backup" to see what it printed.
```

- **Hand-over once.** The adapter keeps the system's rule. A result is shown in full once, then
  referred to briefly ("the backup finished at 9:12 and worked"), unless the client asks again.

---

## Replies: fixed shapes, plain words

Every reply has the same three parts, any of which can be empty:

1. **News**: what changed since last time.
2. **The answer**: what was done or found.
3. **What you can say next**: one to three templates that usually follow.

Rules:

- Never JSON, file names, routes or ids.
- Large results are cut down by fixed rules: a count, the first lines, then "say 'more' for the rest".
- Lists are numbered, so the client can say "the second one".
- A failure is a plain sentence plus the template that fixes it.
- The person's consent stays separate, and the client doesn't have to know about it. Something
  that waits for the Mac is "asked for" ("Asked for the nightly backup. I'll tell you how it
  goes."); the news says when it was turned down, and "what happened to …" says it's waiting for
  an OK and that nothing has run. The client agreeing to something never stands in for that click.

### When the adapter asks first

Only when the match was uncertain: two templates were about equally close, or a title or choice
needed a big correction. A cleanly filled template is acted on at once. Reads always answer at once.

---

## An exchange

```
Client:  I need to know if it'll rain in Lagos tomorrow

Adapter: These can do that:
         1. The weather
              what's the weather in {a city}
         2. Search the web
              search the web for {what to look for}

Client:  what's the weather in Lagos

Adapter: Lagos: 29°C, thunderstorms likely tomorrow afternoon (70%).
         You can also say: search the web for {what to look for}

Client:  remember something
         - category: EVENT-DATES
         - about: Lagos trip
         - fact: rain likely on the first afternoon, plan indoors
         - date: 2026-10-25

Adapter: Remembered under EVENT-DATES: Lagos trip.
         You can also say: what's coming up [this week | this month]

Client:  run the nightly backup

Adapter: Asked for the nightly backup. I'll tell you how it goes.
         You can also say: what happened to {something you asked for}

         … later …

Client:  what have I asked for today

Adapter: Meanwhile: the nightly backup finished (it worked).
         Today you asked for:
         1. the weather in Lagos (answered)
         2. remembering "Lagos trip" (done)
         3. the nightly backup (done, not shown yet: say "show me the backup")
```

---

## How it's offered to a client

- **One tool**: `say(text) → text`.
- **Over HTTP**: `POST /api/say` takes `text/plain` and answers `text/plain`. The client is
  identified as it already is, by `client` or `X-Client`, so each client has its own log.
- What a small model needs in its instructions: *"To use the Mac's tools, use `say`. Say what you
  want; if it offers templates, fill one in and say it back."*

---

## Layers

1. **The template adapter** (this document). It's deterministic, built on `/api/search` and the
   existing metadata, and covers single-step requests, status and history.
2. **The d-model** (optional, later). It adds a free-language parser in front of the adapter that
   tries to understand requests that aren't filled templates. It would also learn from what
   clients approve (counting a mapping as learned only once its result was used without
   correction), and would chain simple steps ("then save it"). It's only needed where layer 1
   proves too strict.

## Where it stands

Layer 1 is built: `POST /api/say` ([API.md](API.md#say-plain-words-post-apisay)). The code is in
`Sources/RunCore/Say/` (the grammar, the matcher, the templates, the words, the log) and
`Sources/RunCore/API/SayAPI.swift` (the conversation). Beside `POST /api/say`:

| Route | What it's for |
|---|---|
| `GET /api/say` | how to use it, as text: the one line for a model's instructions, and the built-in forms |
| `GET /api/say/forms` | every template there is now (`?q=words`: the ones that fit; `?format=json`) |
| `GET /api/say/log` | what this client asked for and how each went, as JSON (for the app beside the model, or for debugging) |
| `POST /api/say/stop` | one of them called off by its number (`{"number": 3}`): for the app beside the model, its Cancel button |
| `POST /api/say/reset` | start over (`{"forget": true}`: the log too) |
| `POST /api/tools/say` | the same, as the one tool (`say` is in `GET /api/tools`) |

A script or flow says how it's offered with a `# Say:` header line. The tools' templates are
written once, in `SayForms.tools`, beside the tools they call (their `say`); routes are reached
through them.

## Decisions on the open questions

- **How many templates a search returns**: the best three, numbered; up to five more come with
  "more". When fewer than three fit, "Search the web" is offered last, since the web answers most
  questions.
- **Titles are a contract**: a title never changes on its own. A tool's template keeps its title
  from version to version; one that's renamed keeps the old one in `formerly`, and it's still
  taken. A script's or flow's title is its file name in words ("nightly-backup" is "Nightly
  backup"), so it changes only when the file is renamed; two of the same name get "(a flow)" or
  "(in Chrome)" after the second.
- **How long a log is kept**: a week, at most 200 requests a client, for the latest 100 clients,
  in memory while the app runs (as the request ledger is). **A conversation starts again** after
  six hours without a word: the numbers ("the second one"), what "more" would give and anything
  waiting for "yes" are forgotten; the log stays, so "what have I asked for today" still answers.
  `start over` (or `POST /api/say/reset`) does it at once.
- **Chains** ("search for X, then save the first result as a note") wait for the d-model. A
  layer-1 chain would need a way to refer to a result inside a template, which is a language, not
  a form.
- **Remembering which templates a client uses**: yes. Each use is counted per client, and of two
  templates that fit as well, the one it has used more is offered (and taken) first.

## Gaps closed on the way

- **The client doesn't need to know about consent either.** The first version answered a run with
  "This needs the person at the Mac to click Run", which asks the client to understand scripts,
  flows and permissions. Now a run is just *asked for* ("Asked for the nightly backup. I'll tell
  you how it goes."). The detail comes when it matters: in the news when it was turned down or not
  OK'd in time, and in "what happened to …" ("it hasn't started yet: it's waiting for someone at
  the Mac to OK it. Nothing has run."). The person's OK is unchanged: the card on the Mac still
  says what it does and why, and nothing the client says stands in for it.

- **Yes and no** are built-in forms (a question asked first needs an answer), and so is `start
  over`. A question with two choices is answered by number.
- **A number** is a pick only right after a numbered list (of templates, of requests, or of
  choices); otherwise it's a value. A pick of a template with blanks shows it alone, to fill; one
  that takes nothing is done.
- **Either shape for any template**: an inline template can be sent labeled (its title, then a
  line per blank), and a labeled value of several lines can be its lines under its label, without
  a fence.
- **Of two sentences as close, the more particular wins** (`read the note {its name}` over `read
  {a web address}`): the one that matched more of its own fixed words.
- **The words of a request** ("I need to know if", "tell me whether") aren't searched for: only
  what it's about.
- **Hand-over once, for two**: the adapter is the client of the system. It collects a result once
  it's over (so `GET /api/requests/open` no longer lists it), and the client hears of it as news
  and sees it in full when it asks.
- **The card says who and why in the client's words**: a run asked for through `say` carries
  `why`: *My App asked in words: “run the nightly backup”*. Nothing reaches the Mac that the
  person wouldn't see in full; tagging something to run by itself waits for Allow the same way,
  and the answer comes as news.
- **What isn't followed**: requests a client makes directly (`POST /api/run`) aren't in its `say`
  log; only what it asked for in words.

- **Told the moment it's over, not only at the next reply.** "News first" still left the client
  to say something before it heard that a run was done. A client that can listen says where, with
  what it says (`X-Reply-To`, an address on this Mac), and the adapter POSTs the news there the
  moment a run is over: the same "Meanwhile: …" words, with the entries as JSON. The client's
  model never polls or keeps an id: the news comes in like a message from someone it asked.
  Delivered news isn't told again; news that couldn't be delivered comes first in the next reply,
  as before. [Super Face](https://github.com/ainigh/JUST-super-mac-tts-ONLY-service) talks to it
  this way: its model writes "@peter …" and hears back from "Peter".

## Open questions (answered above, kept for the record)

- How many templates should a search return: the best three, or up to five?
- Titles become a contract that client models learn. How are they kept stable, and how is a
  rename handled (old titles still accepted)?
- How long is a client's log kept, and when does a "conversation" start again?
- Should simple chains ("search for X, then save the first result as a note") be a built-in form
  in layer 1, or wait for the d-model?
- Should the adapter remember which templates a client has used, and offer those first next time?
