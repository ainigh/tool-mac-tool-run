# Example exchanges

What a model using the app does, turn by turn: what the person says, the calls the model makes (and what comes back, cut short), and what it says. `$API` is the API's address.

## 1. Remembering someone

> **Person:** I just met Ada Lovelace — she's the lead engineer at Acme. Her birthday's March 14th.

```http
GET $API/api/memory/recall?name=Ada Lovelace
→ {"found": false, "nodes": [], …}

POST $API/api/memory/remember
{"category": "PEOPLE", "about": "Ada Lovelace", "text": "Lead engineer at Acme; met today",
 "links": [{"label": "works at", "to": "Acme", "category": "ORGANIZATIONS"}],
 "notes": ["birthday 03-14"], "client": "Assistant"}
→ {"ok": true, "file": "PEOPLE", "node": "ada lovelace",
   "added_to_mind": ["| PEOPLE | ada lovelace", "| ada lovelace @birthday 03-14",
                     "| ada lovelace - works at | acme", "| ORGANIZATIONS | acme"]}
```

> **Model:** Got it — Ada Lovelace, lead engineer at Acme, birthday March 14. She's in PEOPLE, and Acme's in ORGANIZATIONS.

## 2. Recalling, before answering

> **Person:** What do I know about Ada?

```http
GET $API/api/memory/recall?name=ada
→ {"found": true, "nodes": [{"id": "ada lovelace", "memory": …}],
   "about": [{"notes": ["birthday 03-14"], "links": [{"node": "PEOPLE", "direction": "in"}, {"node": "acme", "direction": "out", "labels": ["works at"]}]}],
   "categories": ["PEOPLE"],
   "lines": ["| ada lovelace @birthday 03-14", "| PEOPLE | ada lovelace", "| ada lovelace - works at | acme",
             "PEOPLE, line 14: - Ada Lovelace: Lead engineer at Acme; met today"]}
```

> **Model:** Ada Lovelace is the lead engineer at Acme; you met recently. Her birthday is March 14.

## 3. What's coming up

> **Person:** Anything coming up this month?

```http
GET $API/api/memory/upcoming?days=30
→ {"count": 2, "lines": ["2026-11-03 (in 10 days): 2026-11-03 — Ana reviews the paper — EVENT-DATES",
                         "2026-11-14 (in 21 days): sam: birthday 11-14 — mind"]}
```

> **Model:** Two things: Ana reviews the paper on November 3 (in 10 days), and it's Sam's birthday on the 14th.

## 4. Showing something to copy

> **Person:** Show me the steps to deploy, I'll follow along.

```http
POST $API/api/present
{"title": "Deploying", "text": "## 1. Build\n```sh\nnpm run build\n```\n## 2. Ship\n```sh\nwrangler deploy\n```",
 "why": "The steps you asked for, with the commands to copy", "client": "Assistant"}
→ {"ok": true, "shown": true, "title": "Deploying"}
```

> **Model:** They're in a window in front of you now — each command has a copy button.

## 5. Guiding through a site

> **Person:** I'm on Cloudflare and I can't find where to make a Worker.

```http
GET $API/api/browser/url
→ {"title": "Account Home | Cloudflare", "url": "https://dash.cloudflare.com/…/home"}

GET $API/api/browser/find?text=Workers
→ {"count": 2, "lines": ["The link “Workers & Pages” is in view, at the top left, in navigation “Sidebar”.", …]}

POST $API/api/browser/highlight {"text": "Workers & Pages"}
→ {"highlighted": true, "said": "It’s ringed in red on the page, at the top left."}
```

> **Model:** Click **Workers & Pages** in the sidebar on the left — it's ringed in red.
>
> **Person:** Done. Now what?

```http
GET $API/api/browser/has?text=Create application
→ {"present": true, "answer": "yes", "count": 1}

POST $API/api/browser/highlight {"text": "Create application"}
```

> **Model:** You're there. Click **Create application** (ringed in red), then **Create Worker**.

## 6. A small model keeping the mind

```http
POST $API/api/mind/prompt {"messages": "user: Sam moved to Lagos last week."}
→ {"prompt": "You keep a memory graph of this chat. … Existing nodes: sam, the paper … Recent messages:\nuser: Sam moved to Lagos last week.", "grammar": "root ::= line+ …"}
```

The model's reply:

````text
```mm
| sam - moved to | lagos
| sam @date 2026-10-17 moved
```
````

```http
POST $API/api/mind/append {"text": "```mm\n| sam - moved to | lagos\n| sam @date 2026-10-17 moved\n```", "client": "Mind Keeper"}
→ {"ok": true, "added": ["| sam - moved to | lagos", "| sam @date 2026-10-17 moved"], "known": []}
```

## 7. A mistake, and its fix

```http
POST $API/api/mind/append {"lines": ["| ana - reviews"]}
→ {"ok": false, "code": "bad_lines", "error": "A line has a mistake, so nothing was added.",
   "problems": [{"line": 41, "text": "| ana - reviews", "error": "A label needs `|` and a name after it.",
                 "fix": "Say what it links to: | ana - reviews | someone"}]}
```

The model sends `| ana - reviews | the paper` instead.
