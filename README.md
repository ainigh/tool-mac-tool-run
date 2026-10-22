# Tool Mac Tool Run

A terminal icon in the macOS menu bar. Click it, and a panel drops down: what's waiting for you,
a tile for each grid (each fills 90% of the screen), the latest runs, EPA, and the HTTP API other
apps use. The four grids:

- **Scripts** — a cell for every script in your scripts folder: bash, zsh, PowerShell, Python, JavaScript,
  TypeScript, Ruby, Perl, PHP, Lua, Swift, Go, R, AppleScript, fish, or any
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
  YouTube Music (`youtube-music`), read any page. `browser.sh` does the driving.

The **Composer** examples put them together: `ask-google`, `weather-now`, `news-briefing`,
`urgent-news`, `cloud-check`, `youtube-search` (pick a video from the top results),
`play-music`, and `morning-briefing` (the weather, urgent news, the top stories and any cloud
service that's down, fetched at once, in one result).

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

**Other apps can run them too, with your OK.** The app serves an HTTP API at
`http://127.0.0.1:8768` (the way Super Voice serves speech): another app lists your scripts and
flows, asks to run one (or sends Flow code to run), and gets back how it went and what it printed,
all at once or as it prints. Each request shows a large card on the Mac (which app, the exact
command or the code in full, what it looks like it does) and waits for you to click **Run**.
→ [API.md](API.md)


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
`/api/flows`, `/api/run`, `/api/compose` (a flow, or Flow code you send), `/api/check` and
`/api/runs`. Nothing runs until the person at the Mac clicks **Run** on the card that comes up.

```bash
curl -s localhost:8768/api/scripts
curl -s localhost:8768/api/run -d '{"script": "hello.sh", "args": ["world"], "client": "My App"}'
curl -sN localhost:8768/api/run -d '{"script": "backup.sh", "stream": true}'
```

The panel's **HTTP API** section starts and stops it, has a switch for each group of endpoints
(run scripts, run flows, list them, read runs), **Copy API Doc** (the whole API in one page, with
this Mac's address and, when sharing is on, the token: paste it into another app's code, a README
or a chat with an assistant; it's also served at `/api/doc`), and **Try it** (the API's own page:
every endpoint, and a place to run a script or some Flow code). **Allow other devices** listens
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
   examples" on and you start with five small scripts and four flows that use them, ten
   utilities, eight browser scripts, and ten flows that use those (Google, the weather, the news,
   cloud services, YouTube, a morning briefing); keep "Add the EPA recipes" on
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
```

Two things are asked once: macOS asks whether the app may control Chrome (click **Allow**), and
Chrome needs **View › Developer › Allow JavaScript from Apple Events** ticked. Until then the
scripts say which one is missing and where.

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
| `Sources/ToolMacToolRun/` | the menu bar app (SwiftUI and AppKit): the panel (`Panel.swift`), the grids, the editor, Runs, the API's server and the card that asks before a run (`APIServer.swift`, `Approvals.swift`) |
| `API.md` | the HTTP API, for client apps |
| `docs/FLOW-GUIDE.md` | the Flow guide (also shown inside the app) |
| `docs/DOCTRINE.md` | how the app should feel and the checks every change walks |

Every change is checked against [docs/DOCTRINE.md](docs/DOCTRINE.md): the guided-UX promises, who
it's for, and the cold-start walks.

## The brief

The original request this app was built from is in [docs/BRIEF.md](docs/BRIEF.md).
