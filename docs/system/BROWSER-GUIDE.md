# The browser guide: working in Chrome beside the person

`/api/browser` lets an app work in Google Chrome — not with a picture, but with the page itself: its title, its address, its text and links, whether some words are on it, and **where** a thing is — and open pages. It's for working beside the person, and for guiding them through a site ("Compute is in the sidebar on the left, under Workers & Pages, which is closed: open it first"). It **never clicks, types or fills anything in** (Straw does that, after the person clicks Run: `/api/straw/run`). Each call answers at once, without asking on the Mac.

## Where: side by side, on screen, or in the background

Every call (and Straw) works in one of three places, the same way in each. Say which with `"where"`:

| `where` | What the person sees |
|---|---|
| `side_by_side` — **the default** | a Chrome window of your own on the right half of the screen, theirs moved to the left half: you work beside them, each in your own window. Theirs stays in front |
| `on_screen` | their own tab, in front of them: for guiding them through what they're looking at |
| `background` | nothing moves: your own window is kept behind theirs |

- `open` with no `where` opens side by side (or where your window already is).
- A read (`page`, `has`, `find`, `highlight`, `url`, `outline`, `tabs`) with no `where` reads **your own window** while there is one, else theirs. To read what *they* are looking at while you have a window of your own, say `"where": "on_screen"`.
- Every answer says where it was (`"where"`, and `"where_said"` in words), so you never mistake one page for the other.
- `POST /api/browser/place {"where": "background"}` moves your window behind theirs (and puts theirs back); `{"where": "side_by_side"}` brings it beside again. When you're done, `POST /api/browser/close` closes your window and puts theirs back where it was.

## Which tool is which

| To | Use | Asks on the Mac |
|---|---|---|
| find something out (a fact, hours, a price, the weather) | `GET /api/web/search?q=…`, then `GET /api/web/fetch?url=…` (tools: `web_search`, `web_fetch`) | no |
| call a JSON API a page or its docs point to | `GET /api/web/fetch?url=https://api…?param=…` | no |
| open a page to work on beside them | `POST /api/browser/open {"url": "example.com"}` (side by side; it's read back too) | no |
| open a page in their own window, for them | `POST /api/browser/open {"url": "example.com", "where": "on_screen"}` | no |
| see what's on a page (yours; theirs with `"where": "on_screen"`) | `/api/browser/url`, `/page`, `/has`, `/find`, `/outline` | no |
| show the person where something is | `POST /api/browser/highlight {"text"}` | no |
| click, type, fill, several steps | Straw: `POST /api/straw/run {"source": "open example.com\nclick \"More\""}` | yes (Run) |
| search a site (YouTube, Amazon, GitHub, Maps, 40 more) | `POST /api/run {"script": "browser/site-search.sh", "args": ["youtube lofi hip hop"]}` | yes (Run) |

So "what time does the Louvre open?" is a web search and a fetch: nothing in Chrome moves. "Open X and let's look at it together" is `/api/browser/open` (side by side), then `/find` and `/highlight` on your window. "I'm on X and can't find Y" is `/find` and `/highlight` with `"where": "on_screen"`: their own page. `GET /api/search?q=<what you want>` finds the right one.

## Before the first call

1. Chrome open (or `/api/browser/open` to open it, and a page).
2. The first time, macOS asks whether Tool Mac Tool Run may control Google Chrome: **Allow**.
3. For anything inside the page (text, has, find, outline, highlight): in Chrome, **View > Developer > Allow JavaScript from Apple Events**, once. The address and title work without it.

`GET /api/browser` says how each of these stands (`"chrome": "open"`, `"javascript": true`, or what to switch on).

## The routes

| Route | What it gives |
|---|---|
| `GET /api/browser` | whether Chrome is open, the person's tab in front, your own window (`its_window`: where it is), whether pages can be read |
| `GET /api/browser/url` | the page's `title`, `url` (no JavaScript needed) |
| `GET /api/browser/tabs` | the front window's tabs (`?all=true`: every window), the one in front marked `active` |
| `POST /api/browser/open {"url", "where"?}` | opens it (side by side unless `where` says; Chrome too, if it's closed), waits for it to load, and reads it: `opened`, `where`, then as `/page`; words instead of an address are a Google search |
| `POST /api/browser/place {"where"}` | your window side by side (theirs to the left half) or in the background; `on_screen` closes it |
| `POST /api/browser/close` | closes your window and puts theirs back where it was |
| `GET /api/browser/page` | `title`, `url`, `text` (what's shown on the page; `?max=20000` characters), `links` (the main part's), `selection`, `scroll`, `focused` (`?outline=true` adds the outline) |
| `GET /api/browser/has?text=Compute` | `present`: true or false (and `answer`: yes or no), `count`, `hidden` (how many times in what's not shown), the `lines` it's on. `?case_sensitive=true`, `?whole_words=true` |
| `GET /api/browser/find?text=Compute` | each match: its `kind` (link, button, heading, text field…), `clickable`, `where` (`in view`, `above (scroll up)`, `below (scroll down)`, or `inside “Workers & Pages”, which is closed: open it first`), `side` (the top left…), `in` (navigation “Sidebar”…), and `lines`: each as a sentence to say to the person |
| `POST /api/browser/highlight {"text": "Compute", "seconds": 4}` | scrolls to it and rings it in red for a few seconds, with a label (or rings the closed menu it's in, to open first); `said` is what to tell the person |
| `GET /api/browser/outline` | headings, landmarks, navigation items, buttons, fields, links: the map of the page |

An address or words sent to a read aren't opened: the answer says so (`"not_opened"`, `"note"`) and `next` gives the call that opens it. `/api/browser/click`, `/type`, `/search` and the like are `400 browser_reads_only`, with what does instead.

Errors come with a `code` and a `fix`: `chrome_not_open`, `no_window`, `no_window_of_its_own` (a place asked for with no window of your own there yet: open one), `window_gone` (the person closed it), `bad_where`, `javascript_off`, `not_allowed` (macOS's Automation switch), `no_chrome`, `timed_out`.

Add `"copy": true` to copy an answer, `"present": true` to show it in a window.

## Guiding someone through a site

The person says: *"I'm on Cloudflare and I can't find Compute."* It's their page, so every call says `"where": "on_screen"`:

1. `GET /api/browser/url?where=on_screen` → it's `dash.cloudflare.com`. Good: they're where they think.
2. `GET /api/browser/find?text=Compute&where=on_screen` → `The link “Compute (Workers)” is inside “Workers & Pages”, which is closed: open it first.`
3. Say so, and show them: `POST /api/browser/highlight {"text": "Compute", "where": "on_screen"}` → the closed menu is ringed in red.
4. After they click it: `GET /api/browser/has?text=Create application&where=on_screen` → `true`: they're on the right page. Say what's next.

## Working side by side

The person says: *"Let's compare these two flights."* They keep theirs on the left; you open the other beside it:

1. `POST /api/browser/open {"url": "airline.example/flight/2"}` → your own window, on the right half; theirs moved to the left.
2. `GET /api/browser/find?text=Baggage` → on your page. `POST /api/browser/highlight {"text": "Baggage"}` rings it there, for them to see beside theirs.
3. `GET /api/browser/page?where=on_screen` reads theirs, to compare.
4. Done: `POST /api/browser/close` → your window closes, theirs goes back where it was.

Read the page before guiding, and again after each step: pages change, and what you remember of one can be wrong. Never say a thing is there without `has` or `find` saying so.

## From a terminal

`browser/browser.sh url`, `title`, `text`, `tabs`, `has "Compute"` (prints true or false), `find "Compute"`, in the scripts folder's browser folder, do the same without the app (in the window in front; `TMR_CHROME_WINDOW=<its id>` for another).
