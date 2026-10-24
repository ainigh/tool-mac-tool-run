# Recipes

The calls for what's asked most, ready to paste. `$API` is the API's address (`API=http://127.0.0.1:8768`). Every call answers with JSON (`"ok"`, `"request"`, and on a mistake `"code"`, `"error"`, `"fix"`); none of these asks on the Mac, but running a script or flow (it waits for Run).

## Finding the call for something

| To | Call |
|---|---|
| Find the route for anything, by a few words | `curl -s "$API/api/search?q=remember+a+birthday"` |
| Find a script or flow by what it does | `curl -s "$API/api/search?q=weather&in=scripts,flows"` (each comes with `"run"`: the request that runs it) |
| The groups of routes, small | `curl -s "$API/api/endpoints?brief=true"` |
| One group's routes | `curl -s "$API/api/endpoints?group=memory"` |

Every answer has `"next"`: the calls that usually come after it, ids filled in.

## Running, and collecting the result

```sh
curl -s $API/api/run -H 'Content-Type: application/json' -d '{"script": "backup.sh", "async": true, "client": "My Assistant", "why": "You asked for a backup before the trip"}'
# {"request": "2A7C…", "state": "waiting", "delivery": "pending", "next": [...]}   it waits for Run on the Mac
curl -s $API/api/requests/2A7C…        # pending while waiting or running; once over, this hands over the result, once
curl -s $API/api/requests/open         # everything not collected yet, oldest first
curl -s -X DELETE $API/api/requests/2A7C…   # clear it; still waiting for the click: take it back
```

## Remembering

**Remember a person, where they work, and their birthday**

```sh
curl -s $API/api/memory/remember -H 'Content-Type: application/json' -d '{
  "category": "PEOPLE", "about": "Ada Lovelace", "text": "Met at the 2026 conference; prefers short emails",
  "links": [{"label": "works at", "to": "Acme", "category": "ORGANIZATIONS"}],
  "notes": ["birthday 03-14"], "client": "My Assistant"}'
```

**An event on a day**

```sh
curl -s $API/api/memory/remember -H 'Content-Type: application/json' -d '{
  "category": "EVENT-DATES", "about": "paper review", "text": "- 2026-11-03 — Ana reviews the paper",
  "links": [{"label": "by", "to": "Ana", "category": "PEOPLE"}], "notes": ["date 2026-11-03"]}'
```

**An idea, a strategy, a favour owed** — the same call, with `"category": "IDEAS"`, `"STRATEGIES"` or `"LEVERAGE"`.

**Just a link between two things**

```sh
curl -s $API/api/mind/add -H 'Content-Type: application/json' -d '{"from": "acme", "label": "is at", "to": "lagos"}'
```

**Several at once**

```sh
curl -s $API/api/mind/add -H 'Content-Type: application/json' -d '{"facts": [
  {"from": "sam", "label": "writes", "to": "the paper"},
  {"from": "ana", "label": "reviews", "to": "the paper"},
  {"from": "sam", "notes": ["pref mornings"]}]}'
```

**A note on something** — `curl -s $API/api/mind/note -H 'Content-Type: application/json' -d '{"name": "sam", "note": "todo call back on Friday"}'`

## Recalling

| Question | Call |
|---|---|
| What do we know about Ada? | `curl -s "$API/api/memory/recall?name=ada"` |
| Everything about one thing in the mind | `curl -s $API/api/mind/nodes/acme` |
| Who are the people? | `curl -s $API/api/memory/categories/PEOPLE/members` |
| Who works at Acme? Where does Ada work? | a query in the notation (below) |
| Birthdays and events in the next 30 days | `curl -s "$API/api/memory/upcoming?days=30"` |
| Every todo | `curl -s "$API/api/mind/notes?kind=todo"` |
| How are Sam and Lagos connected? | `curl -s "$API/api/mind/path?from=sam&to=lagos"` |
| What's around Acme, two steps out? | `curl -s "$API/api/mind/nodes/acme/neighbors?depth=2"` |
| Things to do with rockets | `curl -s "$API/api/mind/find?q=rocket"` |
| Every line in MEMORY with "Lagos" | `curl -s "$API/api/memory/search?q=lagos"` |
| What the mind knows that this chat touches | `curl -s $API/api/mind/context -H 'Content-Type: application/json' -d '{"text": "…the messages…"}'` |

**Questions in the notation's own query lines** (a name that isn't in the mind is a variable):

```sh
curl -s $API/api/mind/query -H 'Content-Type: application/json' -d '{"q": "| x - works at | acme"}'           # who works at Acme
curl -s $API/api/mind/query -H 'Content-Type: application/json' -d '{"q": "| ada lovelace - works at | x"}'   # where Ada works
curl -s $API/api/mind/query -H 'Content-Type: application/json' -d '{"q": "| PEOPLE | x\n| x @birthday"}'   # the people, and the birthdays
```

## Showing and copying

| To | Call |
|---|---|
| Show PEOPLE in a window | `curl -s $API/api/present -H 'Content-Type: application/json' -d '{"shelf": "memory", "name": "PEOPLE", "why": "To check the details"}'` |
| Show all about Ada | `curl -s $API/api/present -H 'Content-Type: application/json' -d '{"mind": "ada lovelace"}'` |
| Show steps you wrote | `curl -s $API/api/present -H 'Content-Type: application/json' -d '{"title": "Three steps", "text": "1. …\n2. …"}'` |
| Copy a note's text | `curl -s "$API/api/library/files/groceries?copy=true"` |
| Copy any text | `curl -s $API/api/clipboard -H 'Content-Type: application/json' -d '{"text": "ssh me@example.com"}'` |
| Show a search's results | `curl -s "$API/api/memory/search?q=acme&present=true"` |

## The page in Chrome

| To | Call |
|---|---|
| What's open? | `curl -s $API/api/browser/url` |
| What does the page say? | `curl -s $API/api/browser/page` |
| Is "Compute" on the page? (true/false) | `curl -s "$API/api/browser/has?text=Compute"` |
| Where is "Compute"? | `curl -s "$API/api/browser/find?text=Compute"` |
| Show the person where | `curl -s $API/api/browser/highlight -H 'Content-Type: application/json' -d '{"text": "Compute"}'` |
| The page's map | `curl -s $API/api/browser/outline` |
| Copy the page's text | `curl -s "$API/api/browser/page?copy=true"` |

## The docs

| To | Call |
|---|---|
| Where to start | `curl -s "$API/api/system-docs/files/START-HERE?format=text"` |
| Every doc | `curl -s $API/api/system-docs/names` |
| Search them | `curl -s "$API/api/system-docs/search?q=remember"` |

## Keeping the mind tidy

- `GET $API/api/mind/problems`: lines of the log that couldn't be read, each with its fix.
- `POST $API/api/mind/rename {"name": "the paper", "to": "thesis"}`: two names for one thing.
- `POST $API/api/mind/compact`: the log in its shortest form (the old one archived) — the person's call; ask first.
