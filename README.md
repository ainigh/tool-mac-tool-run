# Tool Mac Tool Run

A terminal icon in the macOS menu bar. Click it, and a panel drops down, in two columns so it's
short enough to take in at a glance: what's waiting for you across the top; on the left a tile for
each grid (each fills 90% of the screen) and the latest runs; on the right EPA and the HTTP API
other apps use; the settings along the bottom. The four grids:

- **Scripts** — a cell for every script in your scripts folder: bash, zsh, PowerShell, Python, JavaScript,
  TypeScript, Ruby, Perl, PHP, Lua, Swift, Go, R, AppleScript, fish, Straw, or any
  executable. The language is told by itself: from the script's `#!` line, else its extension,
  else a look at what's in it. **Click a cell to run it. Click its pencil to edit it.**
- **Composer** — a cell for every **flow**: your scripts put together, built like a shortcut in
  Apple's Shortcuts. Drag your scripts and actions (Ask to Continue, If, Repeat with Each, Show
  Notification…) into a column of steps; each step's output can go into the steps after it. Every
  flow is also a small program in **Flow**, a little F#-like language, so it can be written as
  text too: the editor switches between the two, and they're the same file. Mistakes are caught
  before anything runs. → [The Flow guide](docs/FLOW-GUIDE.md)
- **Utilities** — small reusable scripts, kept in your folder's `utilities` folder: the weather
  (`weather`), the news and what's urgent in it (`news`), whether 20 cloud services are up
  (`cloud-status`: AWS, Google Cloud, Azure, GitHub, Cloudflare, OpenAI, Claude, Slack…), a sound
  or a song, something said out loud, the clipboard, little parsers (pick values out of JSON, CSV
  to JSON, every web address in some text).
- **Browser** — scripts that drive Google Chrome, kept in its `browser` folder: ask Google and
  get just the answer (`google`), search YouTube or play a video (`youtube`), play music on
  YouTube Music (`youtube-music`), read any page. `browser.sh` does the driving. And **Straw**
  scripts (`.straw`): a few plain words for driving a page by what's on it (`open`, `click "Sign
  in"`, `type "Search" "cats"`, `see "Results"`, `read all css "h2"`, `click first css "h3 a"`).
  → [The Straw guide](docs/STRAW-GUIDE.md)

The utilities also look things up (`wikipedia`, `define`, `currency`, `world-clock`,
`public-ip`), check things (`site-check`, `battery`, `system-info`) and help (`password`,
`timer`, which plays a sound and speaks through the other utilities; `copy-to-clipboard`, which
puts text on the clipboard and says what it copied; `alarm`, which rings on this Mac with a
sound, the words out loud and a notification at a time you give it: `alarm "20 minutes" "Stand
up"`, `alarm 16:30 "Call Sam"`, `alarm list`, `alarm cancel`). The browser scripts build on
each other: `translate` is `google --answer`; `gmail` reads your unread mail; `save-tabs`,
`close-duplicate-tabs` and `maps` drive Chrome through `browser.sh`.

**Finding files**, with Spotlight as ⌘Space does: `find-file` (by name, the newest first: `find-file
invoice`, `find-file invoice ~/Documents`, `find-file invoice everywhere`), `spotlight` (the words
in a file's name or in what's written in it, of a kind if you say: `spotlight --kind pdf tax
return`; image, video, audio, document, presentation, spreadsheet, code, folder, app, archive,
email), `screenshots` (every one, wherever it went; `screenshots latest`, `screenshots open`),
`large-files` (everything over a size: `large-files 2GB`), `recent-downloads` (the newest, with the
site each came from), `file-info` (a file's kind, dates, pages or pixels, and where it was
downloaded from), `find-text` (the files in a folder with some text in them, and the lines),
`find-duplicates` (exact copies, and the room they take) and `open-file` (opens one, shows it in
the Finder with `reveal`, previews it with `look`). None of them moves or deletes anything.

**Working things out, and this Mac's network**: `calc` (arithmetic, written as you'd say it:
`calc 15% of 80`, `calc sqrt 2`; worked out, never run as code), `convert` (units: `convert 5 km to
miles`, `convert 72 f to c`, `convert 3 GB to MB`, cups, mph, hours…), `json-format` (tidies JSON,
or says where it's broken), `network` (this Mac's address, the router, DNS, and whether the
internet answers), `speed-test` (macOS's own `networkQuality`), `keep-awake` (no sleep for a
while: `keep-awake 90`, `keep-awake stop`), `dark-mode` (on, off, or switch), `qr-code` (a QR code
of a link, on your Desktop), `port-check` (what's listening on a port, or on every one) and
`git-status-all` (which of your repositories have work not committed or pushed).

**The date and the time**, every way they're written: `today` (the day, ISO, the week and day of
the year, the quarter, what's left of the year; `today iso`, `today long`, `today week` for one
piece), `now` (this Mac's time, UTC, the zone, ISO 8601, Unix seconds; `now unix`, `now stamp`),
`format-date`, which reads a date written any way (`tomorrow`, `next friday`, `in 3 weeks`, `23
Oct`, `christmas`, `2026-10-23 14:30`, Unix seconds) and writes it the way you ask (`long`,
`short`, `us`, `unix`, `relative`, or any strftime pattern), `days-until` (how long until a date,
in days and weeks, and which day it falls on), `month` (a calendar with today marked, or any
month or year), `stopwatch` (`start`, `lap`, `stop`, across runs), `sunrise` (sunrise, sunset and
the day's length, where you are or anywhere) and `holidays` (the next public holidays in your
country, or any).

**The apps and this Mac**: `open-app` opens an app by name and brings it forward (`open-app
Safari`, `open-app Preview ~/photo.png`, `open-app list`), `quit-app` quits one the way ⌘Q does
(it gets to save first), `front-app` says which app is in front and its window's title,
`running-apps` lists the ones running, `notify` shows a notification, `screenshot` takes one
(the screen, a part you drag out, or a window; to the Desktop or the clipboard), `volume` sees
or sets the volume (`volume 30`, `volume up`, `volume mute`), `lock-screen` locks the screen.

**Text and chance**: `text-case` rewrites text in a case (upper, lower, title, sentence, slug,
snake, kebab, camel, pascal), `encode` encodes or decodes Base64, web-address escapes, hex and
HTML entities, `hash` gives the SHA-256 (or SHA-1, MD5) of text or a file, `new-id` makes a UUID
or a short id, and `pick` picks at random: a number, one of some things, heads or tails, a dice
roll, or a shuffle.

The **Composer** examples put them together: `ask-google`, `weather-now`, `news-briefing`,
`urgent-news`, `cloud-check`, `youtube-search` (pick a video from the top results),
`play-music`, `morning-briefing` (the weather, urgent news, the top stories and any cloud
service that's down, fetched at once, in one result), `research` (Wikipedia, Google and the
news about a topic), `travel-check` (the weather, the time and the money where you're going),
`focus-session` (music, a timer, then a break), `site-watch`, `mac-health`, `translate`,
`tidy-chrome`, `inbox-check`, `new-password`, `today-briefing` (the date, the sun, the next
holidays and this month's calendar, the date said out loud), `open-apps` (the apps you name,
opened one after another), `countdown` (a notice with how long until a date), `hn-briefing` (the
top five stories on Hacker News, read by a Straw script, the first said out loud),
`network-check` (the network, the address on the internet and the speed, at once), `dev-check`
(repositories with work not pushed, and what's listening), `presentation-mode` (awake for an hour,
muted, after asking), `clean-read` (the page in front without its cookie banner, in outline),
`search-a-site` (pick one of 50 well-known sites, say what, and its results open),
`search-everywhere` (YouTube, GitHub, Hacker News and arXiv, the top three of each, read by Straw
scripts), `youtube-channels` (the newest videos from the channels you name), `find-and-open` (a
file by name: pick one, then open it, show it in the Finder, preview it or copy where it is),
`spotlight-search` (a kind of file, by its words), `latest-screenshot` (opened, and its path on
the clipboard), `downloads-report` (the newest downloads, the biggest and the copies, in one
result), and, from what's selected in Chrome, `explain-selection` (Wikipedia and the dictionary
on it), `translate-selection` and `read-selection-aloud`.

The **Scripts** grid's own examples, beside `hello` and friends: `backup-folder` (a folder zipped
into ~/Backups, dated), `top-processes` (what's using the CPU and the memory) and `recent-files`
(what you changed lately). The **Browser** grid's: the Straw scripts `hacker-news`,
`wikipedia-article`, `page-outline`, `dismiss-cookies` and `fill-search`, the searches that read
their results, a line each (title, tab, address), `youtube-videos`, `youtube-play` (the first one,
playing), `youtube-latest` (a channel's newest), `github-repos`, `hn-search` and `arxiv-search`;
`site-search` (any of 50 well-known sites by name: `site-search amazon usb-c hub`, `site-search
maps coffee`, `site-search list`); and `copy-link` (the page in front as a Markdown link),
`archive-page` (the Wayback Machine's copies of it, or `--save` one) and `find-tab` (the tab with
your words in it, brought to the front). Two Straw scripts are on the **Utilities** grid, for flows
to build on: `selected-text` (what's selected on the page in front) and `page-word-count` (how
long it takes to read); its Add the Examples brings `straw.py` and `browser.sh` with them.

**The API board** (⌘5) is everything the HTTP API can run, a tile each, filling the window: every
script, utility, browser script and flow, EPA's commands and Flow's own functions, with a search
and a chip for each section. A click runs one: when its header says it takes something
(`# Input: What should Google be asked?`), it asks first, with your last answers already in. Its
result shows beside the tiles, live, and stays when it's done, printed something or not. A tile
drags into a flow's block editor, as the editor's library does; right-click copies the `curl`
command (or the request) another app would send for the same run. It's the way to try anything
the API offers by hand. Each section's tiles are under their topics (the utilities' Library,
Finding files, Date and time, This Mac…; the browser's Straw, Searching sites, Chrome; the
functions' Text, Lists, System…), and its **Library** section runs the file library's operations.

**The Library board** (⌘7) is your notes: a folder called **LIBRARY** on your Desktop, each note a
Markdown file known by its name alone (`groceries` is `LIBRARY/groceries.md`). A tile each, the
latest changed first; click one to read and edit it beside them (⌘S saves); **New Note** (⌘N),
a search across every note's text (each match with the lines it's on), right-click to rename,
duplicate, open in its app or show in the Finder. Deleting moves a note to the library's own
**Trash**, numbered (`groceries (1)`, `groceries (2)`…), so several of a name can wait there to be
restored. Other apps use the same notes over the API (`/api/library`: list, read, write, create,
append, rename, copy, delete, restore, full-text search, find by it, recent, outline, backlinks),
**without asking you each time**: they're notes, not programs, and every call still gets an id.
Flows use them too (`libraryRead`, `libraryWrite`, `libraryAppend`, `libraryFind`…), and so do
the Utilities grid's `library` scripts (`library-search`, `library-find`, `library-append`…) and
the flows `quick-note`, `journal`, `find-note`, `library-digest`, `save-page` and `clip-selection`.

**The Automation board** (⌘6) is everything that runs by itself, the same tiles grouped by what
makes them run: a **schedule** (every minute, every 5, 10 or 30 minutes, every hour, every
morning, afternoon or evening, every day, week or month) or a **trigger** (when the API is
called, when a script, a flow, a utility or a browser script runs, after an item you pick, when
anything runs). The tags are a fixed set, never made up; an item can wear several, and **One
Time Only** takes them off once it has run. Right-click any cell or tile → **Automation** to tag
it; the tag shows on the cell, with its next time under the pointer. A run started this way is
marked in Runs (*Started by itself: every morning*), uses the cell's remembered arguments, asks
on a card first if the cell would, and gets a notice if it fails. Other apps can tag things over
the API too (`"automation": ["every evening"]`), and you're asked first.

**Every question says why.** Before you answer anything, the screen says what the answer
decides: a flow's question carries its reason (`confirmBecause "Delete them?" "They're 30 days
old and take 12 GB"`, or the Ask step's **Why** field in the block editor), a script's `# Input:`
line can carry a `# Why:` line shown under the field, and a run another app asks for shows the
app's own `why` on the card (or that it gave none).

Utilities and browser scripts are scripts, exactly: a click runs one, the pencil edits it, a flow
runs it by name (`run "speak" ["Done"]`), and other apps run them over the API. Only their
folder puts them on a grid of their own.
→ [Utilities and the browser](docs/FLOW-GUIDE.md#utilities-and-the-browser)

**Results where you're looking.** Beside the cells, the result pane shows the run you just
started, live: how it went in big letters, everything it printed (errors in red), Stop or Run
Again, and for a flow each step's own output a click away (a failed step's first). A run that
ends while you're elsewhere comes as a notice whose **Show Result** opens the same view in a
window; so do the panel's latest runs.

The same panel has **Runs**: every run of a script or a flow, with how it went and everything it
printed (live while it runs), the command to run it yourself in a terminal, Stop and Run Again.

**Every route, in its groups**: `GET /api/endpoints` lists them (About the API, Scripts and flows,
Straw, File library, Automation, Runs and requests), and so do `/api/doc` and the API's own page.
**Straw has routes of its own**: `GET /api/straw` (its words and scripts), `POST /api/straw/check`
(Straw code checked, nothing run) and `POST /api/straw/run` (a Straw script, or Straw code an app
sends, run in Chrome once you click Run; the card shows the code).

**Other apps can run them too, with your OK.** The app serves an HTTP API at
`http://127.0.0.1:8768` (the way Super Voice serves speech): another app lists your scripts and
flows, asks to run one (or sends Flow code to run), and gets back how it went and what it printed,
all at once or as it prints. Each request shows a large card on the Mac (which app, the exact
command or the code in full, what it looks like it does, and for a flow what the scripts it runs
look like they do) and waits for you to click **Run**. An app asking to stop a run you started
gets the card too (**Stop It** or **Keep Running**). → [API.md](API.md)


**Notifications you can't miss.** A run that ends while you're elsewhere, one that's taking long,
a flow waiting for an answer, an update: each comes as a large notice in the middle of the
screen (half its width and height), in its state's color, with the one thing to do next (Show
Result, Answer, Install Update). It never takes the keyboard from what you're typing, goes by itself
(a bar shows how long it has; the pointer on it keeps it), and several at once wait behind each
other.

It's the sibling of [Tool Mac Tool](https://github.com/ainigh/tool-mac-tool), whose boards' grid
this borrows: the same cell colors and the same rows-closest-to-square layout.

## EPA, built in

The main thing this app is for: [EPA](https://github.com/ainigh/ENTER-PRICE-AUTOMATION)
(Enter-Price Automation), the kit for Cloudflare and the services around it (Resend, SendGrid,
SES, MailUp, Microsoft 365, Google, Freshdesk), run from the grids.

- **Recipes, ready to click**: check every connection, connect a service, set up a sending domain,
  secure a site, Gmail on your own domain, look up a person, onboard or offboard someone, sweep a
  phishing email out of every mailbox, open the Atlas. Each is a flow made of blocks.
- **EPA's questions come to you**: before EPA changes anything it says what, in the app's own
  question window. What can't be undone says so and needs a click (Return won't do it); a key it
  needs goes in a hidden field and is never kept.
- **It reads like EPA in a terminal**: its plan, each step's status word, the one next step, with
  clickable links. A failure stops the flow with EPA's own sentence and its fix.
- **An EPA step in the block editor** for every command, and `epa […]` / `attemptEpa […]` in Flow.
- **Set up in one click**: **Add the EPA Recipes** (first run, an empty grid, or the panel's
  **EPA** section) adds the recipes and runs `setup-epa`, which installs Node.js if needed and
  fetches EPA (run it again to update). The installer sets EPA up too. Its keys live in `.env` in
  your scripts folder (**EPA → Keys (.env)…** opens it).

→ [EPA in the Flow guide](docs/FLOW-GUIDE.md#epa-cloudflare-and-the-services-around-it)

## For other apps

**[API.md](API.md)** is what client apps need: `http://127.0.0.1:8768`, with `/api/scripts`,
`/api/flows`, `/api/run`, `/api/compose` (a flow, or Flow code you send), `/api/check`,
`/api/runs` and `/api/requests`. Nothing runs until the person at the Mac clicks **Run** on the
card that comes up. Every request gets an id the moment it arrives (`X-Request-Id`, and `request`
in the answer), and `/api/requests/{id}` says where it is any time later: waiting for the click,
denied, running, how it ended. `"async": true` answers with the id at once.

```bash
curl -s localhost:8768/api/scripts
curl -s localhost:8768/api/run -d '{"script": "hello.sh", "args": ["world"], "client": "My App", "why": "You pressed Greet"}'
curl -sN localhost:8768/api/run -d '{"script": "backup.sh", "stream": true}'
curl -si localhost:8768/api/run -d '{"script": "backup.sh", "async": true, "client": "My App"}'   # 202 now, with X-Request-Id
curl -s localhost:8768/api/requests/<the id>
curl -s localhost:8768/api/automation -d '{"script": "backup.sh", "automation": ["every evening"], "client": "My App"}'
```

The panel's **HTTP API** section starts and stops it, has a switch for each group of endpoints
(run scripts, run flows, list them, read runs), **Copy API Doc** (the whole API in one page, with
this Mac's address and, when sharing is on, the token: paste it into another app's code, a README
or a chat with an assistant; it's also served at `/api/doc`), and **Try it** (the API's own page:
every endpoint, and a place to run a script or some Flow code). Under **How another app calls it,
ready to paste**, a chip copies working code for each kind of client: **curl**, **Python** (the
standard library only), **JavaScript** (`fetch`), **Swift** (`URLSession`), **Shortcuts** (the
actions, step by step, for a shortcut Siri can run), **AI Agent** (the rules and endpoints, worded
for an assistant's instructions), and the **Address**. Each lists the scripts, runs one with
`client` and `why`, keeps the request id and handles Don't Run. **Allow other devices** listens
on the network too; callers from elsewhere need the token shown there.

## Install (and update)

**The first time only:** the installer comes through `gh` (GitHub's command line tool), signed in
to an account that can see this repository. With [Homebrew](https://brew.sh), paste this in
Terminal (a browser window opens to sign in):

```bash
brew install gh && gh auth login --web --git-protocol https -h github.com
```

Then paste this. It keeps your scripts, settings and run history.

```bash
gh api -H "Accept: application/vnd.github.raw" repos/ainigh/tool-mac-tool-run/contents/install.sh | bash
```

It checks `gh` can see the repository (and asks you to sign in again if it can't), downloads the
latest build into `~/Applications`, links the `flow` command into `~/.local/bin`, and opens the
app. If the new app quits as soon as it opens, or anything fails on the way, the app you had is
put back. With no build published yet, it builds the app on your Mac (needs Apple's command line
tools: `xcode-select --install`). Needs macOS 14 (Sonoma) or newer.

The app adds itself to your login items the first time it runs (**Open at login** in its panel
turns that off).

**Updates are a click.** The app checks for a new version when it starts and every six hours
(or **Check for updates** in its panel). When there is one, a notification says so and the menu
bar icon gets a ⬇︎: click the notification, or **Install** in the panel. It
downloads GitHub's build (or builds it on your Mac when GitHub hasn't yet), checks it, swaps it
in and opens it again; if the new version won't open, the one you had comes back. It reaches
GitHub through `gh`, signed in as above. What went wrong, if anything, is in
`~/Library/Logs/ToolMacToolRun/update.log` (the copy button beside **Try again** in the panel). Running the
install command again still works too.

## First run

1. Click the terminal icon in the menu bar. The panel's first tile is **Choose Your Scripts Folder…**.
2. Use **~/Scripts** (one click; it's made if it isn't there) or pick any folder. Keep "Add the
   examples" on and you start with eight small scripts and four flows that use them, the
   utilities, the browser scripts (Straw ones among them), and the flows that use those (Google,
   the weather, the news, cloud services, YouTube, Hacker News, a morning briefing); keep "Add the EPA recipes" on
   and EPA's recipes are there too, with EPA set up for you. (Already set up? The empty Utilities
   and Browser grids offer **Add the Examples** for theirs.)
3. Click a cell. It runs; its border moves while it does, and what it prints shows beside the
   cells, in the result pane, as it prints it. When it's done, the pane says how it went (and the
   bottom of the cell too), with **Run Again** a click away. Nothing else to open.

## The grids

| To | Do |
|---|---|
| Run a script | click its cell |
| See what it printed, and how it went | it's beside the cells already (the result pane); for an earlier run of another cell, click that cell's status line |
| Hide or show the result pane | **Result**, at the top of the grid |
| Watch a running one | the result pane; or click it again |
| Stop it | **Stop** on the cell (or in Runs, ⌘.) |
| Edit it | the pencil (top right of the cell) |
| Run it with arguments | right-click → **Run with Arguments…** (they can be remembered for the cell) |
| Make a new one | the **+** cell after the last one, or **New Script** / **New Flow** at the top |
| Show more or fewer cells at once | **−** / **+** beside "12 cells" (1 to 64); more scripts than cells go on pages (‹ ›, or ⌘← ⌘→) |
| Move a cell | drag it onto another |
| Change its color | right-click → **Color** |
| Copy the terminal command | right-click → **Copy Command for Terminal** |
| Remove it | right-click → **Move to Trash…** (you can put it back from the Trash) |
| Be asked before it runs | right-click → **Ask Before Running** (on by itself for a script that looks like it deletes files, uses `sudo`, force-pushes… ✋ on its cell says so) |
| Make it run by itself | right-click → **Automation** → tick a schedule or a trigger (the Automation board, ⌘6, shows everything that does) |
| Answer a flow's question | the window that comes forward, or click the cell that says **Waiting for your answer** |
| Type into a script that asks (`read -p`, `input()`…) | the result pane (or Runs, or under the editor) has a line to type in |

**Your scripts folder**: scripts go at its top; flows go in its `composer` folder, utilities in
its `utilities` folder and browser scripts in its `browser` folder (all made for you).
The grids follow the folder: add, rename or remove a file in the Finder and the grid changes
with it. Each script's first comment line is shown on its cell, under its name.

Scripts run in your scripts folder, with your shell's PATH (what a new Terminal window has), so
Homebrew's `python3`, `node` and the rest are found. A script with a `#!` line runs with exactly
what that line names, flags and all (`#!/bin/sh -e`, a virtual environment's python,
`#!/usr/bin/env -S deno run --allow-read`), whether or not it's marked executable; one without
runs with its language's program (`python3`, `node`, `bash`…), and a text file with neither runs
with `/bin/sh`, as a shell would. When the program is missing, the run says which one and the
command that installs it. **Copy Command for Terminal** gives the same thing to paste:
`cd` into the scripts folder, then the exact command. **Check Setup** in the panel looks at everything at once (the folder,
each language's program, each flow), changing nothing.

## Asking first, and long runs

- A script (or flow) that looks like it can't be undone — `rm -rf`, `sudo`, `git push --force`,
  `DROP TABLE`, erasing a disk, emptying the Trash… — asks before it runs, saying what it looks
  like it does and the exact command. Untick the box to stop it asking; right-click → **Ask
  Before Running** turns asking on (or off) for any cell.
- A flow can ask too: **Ask to Continue** (`confirm`) stops and waits for Continue or Stop.
- A run still going after a minute gets a notification (the panel's bell, **Notice after 1 min**,
  sets how long). A run that's printed nothing for a while says so on its cell, and a
  script that looks like it's waiting for typed input gets a line to type into.

## The editor

The pencil opens it. A flow opens as **blocks** (see the guide); the switch at the top shows it
as **Flow Code** instead. It saves as you type (**Revert** goes back to how the file was when the window
opened). Type in the name at the top to rename the file. **Save & Run** (⌘R) runs it and shows the
output underneath. Smart quotes and other auto-corrections are off: it's for code.

For a flow, the panel beside it shows, as you type, whether it checks out and the type worked out
for everything it defines, or what's wrong, on which line, and how to fix it. Under that: your
scripts and every function, each a click away from being typed in.

## Driving the browser

`browser/browser.sh` (on the Browser grid) drives Google Chrome through AppleScript:

```bash
browser/browser.sh                             # is Chrome ready, and what to switch on if not
browser/browser.sh open https://example.com    # a new tab, in front; waits for it; prints its title
browser/browser.sh read https://example.com 'document.title'   # in a tab of its own, behind; closed after
browser/browser.sh title                       # also: url, text, tabs, js, js-in, focus, go, wait, encode
browser/google.sh how tall is the eiffel tower # just the answer, then the top results
browser/youtube-music.sh bohemian rhapsody     # plays it; also pause, play, next, previous, now
browser/site-search.sh amazon usb-c hub        # any of 50 well-known sites' results, in front (site-search.sh list)
```

Two things are asked once: macOS asks whether the app may control Chrome (click **Allow**), and
Chrome needs **View › Developer › Allow JavaScript from Apple Events** ticked. Until then the
scripts say which one is missing and where.

## Straw: driving a page by what's on it

A `.straw` file in the `browser` folder is a Straw script: a plain line a step, things named the
way you'd name them, checked whole before anything runs.

```
# Looks something up on Wikipedia in Chrome: the article's title and its first paragraph
# Input: What to look up
open "en.wikipedia.org/w/index.php?search={1}&go=Go"
wait css "#firstHeading"
if see css ".mw-search-results-container"
  click css ".mw-search-result-heading a[data-serp-pos='0']"
  wait gone css ".mw-search-results-container"
read css "#firstHeading"
read css ".mw-parser-output > p:not(.mw-empty-elt), .mw-parser-output > section > p:not(.mw-empty-elt)"
```

Twenty-five words: `open` `go` `tab` `back` `forward` `reload` `wait` `click` `hover` `type` `press`
`select` `check` `uncheck` `scroll` `see` `read` `js` `set` `print` `ask` `confirm` `stop` `if`
`else`. Two buttons with the same name? It stops and says how to tell them apart (`click "Delete"
in "my-old-key"`) rather than guessing, and in a list of results `click first css "h3 a"` takes
the one highest on the page; something not there? It names what's near. A `click` on
*Delete*, *Send*, *Buy* or *Publish* marks the cell and asks before it runs; `confirm "Post it?"`
asks at the moment it matters. `browser/straw.py` runs them (with nothing, it lists every word;
`--check FILE` says what a script would do without doing it). → [The Straw guide](docs/STRAW-GUIDE.md)
(also in the app: **Guides** → **Straw**)

## From a terminal

```bash
flow run ~/Scripts/composer/morning.flow     # check, then run a flow (questions are asked here)
flow run --yes ~/Scripts/composer/tidy.flow  # with no one at the keyboard: Continue and Yes
flow check ~/Scripts/composer/morning.flow   # check it, and see its types
flow functions                               # every builtin, with its type
flow examples ~/Scripts                      # add the examples (scripts, utilities, browser, flows)
flow recipes ~/Scripts                       # add the EPA recipes (then run setup-epa.sh once)
```

## Building it yourself

GitHub Actions tests and builds on every push, and publishes a release from `main` (what the
installer downloads). To build by hand on a Mac: `scripts/build-app.sh` (makes
`build/ToolMacToolRun.app`). `swift test` runs the tests on a Mac or on Linux.

| Where | What |
|---|---|
| `Sources/RunCore/` | the logic, Foundation only: language detection, the runner, the folder, grid settings and layout, runs, Check Setup |
| `Sources/RunCore/Flow/` | the Flow language: lexer, parser (F#'s indentation rule), type checker (Hindley–Milner), interpreter, builtins, and the blocks the editor shows (`Blocks.swift`) |
| `Sources/RunCore/Caution.swift` | what a script looks like it does before it runs: things that can't be undone, asking for typed input |
| `Sources/RunCore/API/` | the HTTP API: requests, access rules, the routes (`RunAPI.swift`), the page at `/` |
| `Sources/RunCore/EPA.swift`, `EPARecipes.swift` | EPA: its commands, running `epa --ask-json` (its words shown, its questions asked here), the recipes |
| `scripts/setup-epa.sh` | installs or updates EPA (the installer runs it; the app puts the same file in the folder) |
| `Sources/flow/` | the `flow` command |
| `Sources/RunCore/Automation.swift` | the automation tags, when a schedule next runs, what sets a trigger off |
| `Sources/ToolMacToolRun/` | the menu bar app (SwiftUI and AppKit): the panel (`Panel.swift`), the grids, the editor, Runs, the API's server and the card that asks before a run (`APIServer.swift`, `Approvals.swift`), the clock and triggers that start what's automated and the Automation board (`AutomationCenter.swift`, `AutomationBoard.swift`) |
| `API.md` | the HTTP API, for client apps |
| `docs/AGENTS-GUIDE.md` | the API from an agent's loop (Super Voice's Tom and Jerry): request ids, `async`, polling, what to tell the person |
| `docs/FLOW-GUIDE.md` | the Flow guide (also shown inside the app) |
| `docs/STRAW-GUIDE.md` | the Straw guide, for `.straw` scripts that drive Chrome (also shown inside the app); `straw.py`, which runs them, is an example in `Sources/RunCore/ExampleTools.swift`, and `Straw.swift` finds it |
| `docs/DOCTRINE.md` | how the app should feel and the checks every change walks |

Every change is checked against [docs/DOCTRINE.md](docs/DOCTRINE.md): the guided-UX promises, who
it's for, and the cold-start walks.

## The brief

The original request this app was built from is in [docs/BRIEF.md](docs/BRIEF.md).
