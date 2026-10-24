# The browser guide: seeing the page in Chrome

`/api/browser` lets an app see what the person sees in Google Chrome — not a picture, but the page itself: its title, its address, its text and links, whether some words are on it, and **where** a thing is — and open a page there for them. It's for guiding the person through a site ("Compute is in the sidebar on the left, under Workers & Pages, which is closed: open it first"). It **never clicks, types or fills anything in** (Straw does that, after the person clicks Run: `/api/straw/run`). Each call answers at once, without asking on the Mac.

## Which tool is which

| To | Use | Asks on the Mac |
|---|---|---|
| find something out (a fact, hours, a price, the weather) | `GET /api/web/search?q=…`, then `GET /api/web/fetch?url=…` (tools: `web_search`, `web_fetch`) | no |
| call a JSON API a page or its docs point to | `GET /api/web/fetch?url=https://api…?param=…` | no |
| open a page for the person to see or use | `POST /api/browser/open {"url": "example.com"}` (it's read back too) | no |
| see what's on the page already in front | `/api/browser/url`, `/page`, `/has`, `/find`, `/outline` | no |
| show the person where something is | `POST /api/browser/highlight {"text"}` | no |
| click, type, fill, several steps | Straw: `POST /api/straw/run {"source": "open example.com\nclick \"More\""}` | yes (Run) |
| search a site (YouTube, Amazon, GitHub, Maps, 40 more) | `POST /api/run {"script": "browser/site-search.sh", "args": ["youtube lofi hip hop"]}` | yes (Run) |

So "what time does the Louvre open?" is a web search and a fetch: nothing in Chrome moves. "Open X, then help me find Y on it" is `/api/browser/open`, then `/api/browser/find` and `/highlight`. `GET /api/search?q=<what you want>` finds the right one.

## Before the first call

1. Chrome open, with the page in front (or `/api/browser/open` to open one).
2. The first time, macOS asks whether Tool Mac Tool Run may control Google Chrome: **Allow**.
3. For anything inside the page (text, has, find, outline, highlight): in Chrome, **View > Developer > Allow JavaScript from Apple Events**, once. The address and title work without it.

`GET /api/browser` says how each of these stands (`"chrome": "open"`, `"javascript": true`, or what to switch on).

## The routes

| Route | What it gives |
|---|---|
| `GET /api/browser` | whether Chrome is open, the tab in front, whether pages can be read |
| `GET /api/browser/url` | the tab in front: `title`, `url` (no JavaScript needed) |
| `GET /api/browser/tabs` | the front window's tabs (`?all=true`: every window), the one in front marked `active` |
| `POST /api/browser/open {"url"}` | opens it in a new tab in front (Chrome too, if it's closed), waits for it to load, and reads it: `opened`, then as `/page`; words instead of an address are a Google search |
| `GET /api/browser/page` | `title`, `url`, `text` (what's shown on the page; `?max=20000` characters), `links` (the main part's), `selection`, `scroll`, `focused` (`?outline=true` adds the outline) |
| `GET /api/browser/has?text=Compute` | `present`: true or false (and `answer`: yes or no), `count`, `hidden` (how many times in what's not shown), the `lines` it's on. `?case_sensitive=true`, `?whole_words=true` |
| `GET /api/browser/find?text=Compute` | each match: its `kind` (link, button, heading, text field…), `clickable`, `where` (`in view`, `above (scroll up)`, `below (scroll down)`, or `inside “Workers & Pages”, which is closed: open it first`), `side` (the top left…), `in` (navigation “Sidebar”…), and `lines`: each as a sentence to say to the person |
| `POST /api/browser/highlight {"text": "Compute", "seconds": 4}` | scrolls to it and rings it in red for a few seconds, with a label (or rings the closed menu it's in, to open first); `said` is what to tell the person |
| `GET /api/browser/outline` | headings, landmarks, navigation items, buttons, fields, links: the map of the page |

An address or words sent to a read aren't opened: the answer says so (`"not_opened"`, `"note"`) and `next` gives the call that opens it. `/api/browser/click`, `/type`, `/search` and the like are `400 browser_reads_only`, with what does instead.

Errors come with a `code` and a `fix`: `chrome_not_open`, `no_window`, `javascript_off`, `not_allowed` (macOS's Automation switch), `no_chrome`, `timed_out`.

Add `"copy": true` to copy an answer, `"present": true` to show it in a window.

## Guiding someone through a site

The person says: *"I'm on Cloudflare and I can't find Compute."*

1. `GET /api/browser/url` → it's `dash.cloudflare.com`. Good: they're where they think.
2. `GET /api/browser/find?text=Compute` → `The link “Compute (Workers)” is inside “Workers & Pages”, which is closed: open it first.`
3. Say so, and show them: `POST /api/browser/highlight {"text": "Compute"}` → the closed menu is ringed in red.
4. After they click it: `GET /api/browser/has?text=Create application` → `true`: they're on the right page. Say what's next.

Read the page before guiding, and again after each step: pages change, and what you remember of one can be wrong. Never say a thing is there without `has` or `find` saying so.

## From a terminal

`browser/browser.sh url`, `title`, `text`, `tabs`, `has "Compute"` (prints true or false), `find "Compute"`, in the scripts folder's browser folder, do the same without the app.
