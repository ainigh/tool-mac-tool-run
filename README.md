# Tool Mac Tool Run

A terminal icon in the macOS menu bar. Click it, and its menu opens one of two grids, each filling
90% of the screen:

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

The same menu has **Runs**: every run of a script or a flow, with how it went and everything it
printed (live while it runs), the command to run it yourself in a terminal, Stop and Run Again.

It's the sibling of [Tool Mac Tool](https://github.com/ainigh/tool-mac-tool), whose boards' grid
this borrows: the same cell colors and the same rows-closest-to-square layout.

## Install (and update)

**The first time only:** the installer comes through `gh` (GitHub's command line tool), signed in
to an account that can see this repository. With [Homebrew](https://brew.sh), paste this in
Terminal (a browser window opens to sign in):

```bash
brew install gh && gh auth login --web --git-protocol https -h github.com
```

Then paste this. Run it again any time to update: it keeps your scripts, settings and run
history.

```bash
gh api -H "Accept: application/vnd.github.raw" repos/ainigh/tool-mac-tool-run/contents/install.sh | bash
```

It checks `gh` can see the repository (and asks you to sign in again if it can't), downloads the
latest build into `~/Applications`, links the `flow` command into `~/.local/bin`, and opens the
app. If the new app quits as soon as it opens, or anything fails on the way, the app you had is
put back. With no build published yet, it builds the app on your Mac (needs Apple's command line
tools: `xcode-select --install`). Needs macOS 14 (Sonoma) or newer.

The app adds itself to your login items the first time it runs (**Open at Login** in its menu
turns that off).

## First run

1. Click the terminal icon in the menu bar. The first item is **Choose Your Scripts Folder…**.
2. Use **~/Scripts** (one click; it's made if it isn't there) or pick any folder. Keep "Add the
   examples" on and you start with five small scripts and four flows that use them.
3. Click a cell. It runs; its border moves while it does, and its last line of output shows on
   it. When it's done, the bottom of the cell says how it went (click there to see everything it
   printed).

## The grids

| To | Do |
|---|---|
| Run a script | click its cell |
| Watch a running one | click it again, or its status line |
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
| Type into a script that asks (`read -p`, `input()`…) | its output in Runs (or under the editor) has a line to type in |

**Your scripts folder**: scripts go at its top; flows go in its `composer` folder (made for you).
The grids follow the folder: add, rename or remove a file in the Finder and the grid changes
with it. Each script's first comment line is shown on its cell, under its name.

Scripts run in your scripts folder, with your shell's PATH (what a new Terminal window has), so
Homebrew's `python3`, `node` and the rest are found. A script with a `#!` line runs with exactly
what that line names, flags and all (`#!/bin/sh -e`, a virtual environment's python,
`#!/usr/bin/env -S deno run --allow-read`), whether or not it's marked executable; one without
runs with its language's program (`python3`, `node`, `bash`…), and a text file with neither runs
with `/bin/sh`, as a shell would. When the program is missing, the run says which one and the
command that installs it. **Copy Command for Terminal** gives the same thing to paste:
`cd` into the scripts folder, then the exact command. **Check Setup…** in the menu looks at everything at once (the folder,
each language's program, each flow), changing nothing.

## Asking first, and long runs

- A script (or flow) that looks like it can't be undone — `rm -rf`, `sudo`, `git push --force`,
  `DROP TABLE`, erasing a disk, emptying the Trash… — asks before it runs, saying what it looks
  like it does and the exact command. Untick the box to stop it asking; right-click → **Ask
  Before Running** turns asking on (or off) for any cell.
- A flow can ask too: **Ask to Continue** (`confirm`) stops and waits for Continue or Stop.
- A run still going after a minute gets a notification (the menu's **Notify Me When a Run Takes
  Over** sets how long). A run that's printed nothing for a while says so on its cell, and a
  script that looks like it's waiting for typed input gets a line to type into.

## The editor

The pencil opens it. A flow opens as **blocks** (see the guide); the switch at the top shows it
as **Flow Code** instead. It saves as you type (**Revert** goes back to how the file was when the window
opened). Type in the name at the top to rename the file. **Save & Run** (⌘R) runs it and shows the
output underneath. Smart quotes and other auto-corrections are off: it's for code.

For a flow, the panel beside it shows, as you type, whether it checks out and the type worked out
for everything it defines, or what's wrong, on which line, and how to fix it. Under that: your
scripts and every function, each a click away from being typed in.

## From a terminal

```bash
flow run ~/Scripts/composer/morning.flow     # check, then run a flow (questions are asked here)
flow run --yes ~/Scripts/composer/tidy.flow  # with no one at the keyboard: Continue and Yes
flow check ~/Scripts/composer/morning.flow   # check it, and see its types
flow functions                               # every builtin, with its type
flow examples ~/Scripts                      # add the examples to a folder
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
| `Sources/flow/` | the `flow` command |
| `Sources/ToolMacToolRun/` | the menu bar app (SwiftUI and AppKit) |
| `docs/FLOW-GUIDE.md` | the Flow guide (also shown inside the app) |
| `docs/DOCTRINE.md` | how the app should feel and the checks every change walks |

Every change is checked against [docs/DOCTRINE.md](docs/DOCTRINE.md): the guided-UX promises, who
it's for, and the cold-start walks.

## The brief

The original request this app was built from is in [docs/BRIEF.md](docs/BRIEF.md).
