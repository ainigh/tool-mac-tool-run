# Doctrine

How this app is meant to feel, who it's for, and the checks every change has to pass. It's
distilled from the doctrine folder of
[ENTER-PRICE-AUTOMATION](https://github.com/ainigh/ENTER-PRICE-AUTOMATION/tree/main/docs/doctrine)
(`GUIDED-UX-PLAYBOOK.md` first, then `THE-USER.md`, `UI-LAW.md`, `SELF-HEALING-LAUNCH-PLAYBOOK.md`
and `WALKTHROUGH-AUDIT-PLAYBOOK.md`), boiled down and applied to this app. **It stands alone**:
nothing here needs those files to be understood or used. They're richer, if you have them.

---

## 1 · The north star

> A first-time user who knows nothing about this tool, its domain, or its internals can still
> run it, understand what is happening at every step, recover from mistakes, and know what to
> do next — without reading source, asking a human, or fearing they'll break something.

Sharper still, for the person this is built for:

> **They should be able to wake up having forgotten this project entirely, and still use it end
> to end — without confusion, and without one unexpected thing.** Anything that's only usable
> because you already know something is broken.

The thesis: **the tool teaches you how to use it, while you use it.** Guidance isn't a manual
bolted on; it's in every action.

## 2 · The person on the other side

They spend no attention on the tool, because all of it belongs to the work the tool serves. Every
step, every remembered option, every "is it doing something?" comes out of that budget. They're
technical (they write the scripts) and still refuse to remember a flag. Both are true.

| Trait | What it means here |
|---|---|
| Zero memory of the tool | Nothing needs recalling: the panel, the grids and the guide say it all. |
| One place of attention | They look at what they clicked. The result shows **there** (the cell, and the result pane beside it), not behind a list. |
| Silence reads as broken | Work with no visible motion looks like a hang, whether or not it is. |
| A question is a defect | If they have to ask what something does, the screen should already have said. |
| Same input, same output | Anything that varies run to run breaks trust in everything (cell colors come from the name, not a random pick). |
| Believes what they see | A change that can't be seen didn't happen (the version is in the panel). |
| Wants the one command | Install, update and repair are the same command. |
| Defaults should be derived | Never ask for what the app can work out (the language of a script, the PATH, a folder to suggest). |
| The visible order is the instruction order | The first, most prominent control is pressed first, and must work. |
| Surprise is a failure | Even a correct thing the screen didn't predict counts as a fault. |
| Expects gaps closed for them | Bugs found along the way are fixed, not reported and left. |
| Carries one file | A deliverable that needs its siblings is broken on arrival. |

## 3 · The five promises

Every feature keeps these. If a change breaks one, it isn't done.

1. **I'll tell you what I'm about to do — before I do it.**
2. **I'll tell you what happened — after each step, in plain words.**
3. **I'll never surprise you with something destructive or costly.**
4. **I'm safe to run again; you can't get stuck by trying again.**
5. **I'll always tell you what to do next.**

## 4 · The principles, and where they live in this app

| Principle | In this app |
|---|---|
| **One obvious way in** | One install command. One icon in the menu bar. With no folder chosen, choosing it is the panel's first tile and the whole of the grid window. |
| **Say it before doing it** | Help on every control says what a click does. "Add the Examples" says what it adds and that nothing else changes. |
| **Show the plan / confirm the consequence** | Quitting with runs going names how many will stop. Moving to the Trash says it can be put back. A script that looks like it can't be undone (`rm -rf`, `sudo`, a force-push…) says what it looks like it does and the exact command, and waits for Run. A flow's Ask to Continue stops before the costly step. Never a bare "Proceed?". |
| **One status vocabulary** | Running 👉, succeeded ✅, failed ❌, stopped ⏹, couldn't start ⚠️ — the same mark, icon and color on cells, in Runs, in the panel, in `flow run`. |
| **Progress you can follow** | A running cell's border moves, its elapsed time ticks, its last line shows; gone quiet, it says for how long. A flow's steps appear as they start, and in the block editor each step shows how it went. A run that takes long gets a notification; a question waiting comes forward, and its cell says so. |
| **Safe to repeat** | Running the installer again updates in place and keeps the old app until the new one is seen running. Adding examples twice adds nothing the second time. |
| **Report what happened** | Every run keeps its exit code, duration, output, and the exact command. |
| **Always a next step** | Every failure says the fix: a missing interpreter names the `brew install`, a flow mistake names the line and the change, a failed `run` suggests `attempt`. |
| **Fail loud, fail helpful** | No stack traces. Mistakes in a flow are caught before anything runs, with the line, the reason and the fix. |
| **Diagnose yourself** | Check Setup looks at the folder, each language's program and each flow, changing nothing, with the fix beside every problem. |
| **Fix it yourself, with a fallback** | The app finds your login shell's PATH so Homebrew's tools are found; when it can't build, the installer builds from source; when it still can't, it says the one command to run. |
| **Another app asks; you decide** | A run asked for over the HTTP API shows a large card first: which app, from where, why it wants it (in the app's words, or that it gave no reason), the exact command (or the Flow code in full), and what it looks like it does, in red (for a flow, what the scripts it runs look like they do too). Stopping a run the person started asks the same way (Stop It, Keep Running). Nothing runs until Run is clicked; it never takes the keyboard (Return can't say yes for you); no answer in two minutes is Don't Run, and the app is told which. Flow code with a mistake is turned down before anyone is asked. An app asking to tag something to run by itself gets the same card, with Allow. |
| **Runs by itself, never silently** | Running on a schedule is Peter's (Tool Mac Agent, a separate app): each run he asks for comes to the Mac as a card, like any app's, and waits for Run. |
| **Guard what can't be undone** | Nothing is deleted: removing a script moves it to the Trash, after asking. Editing autosaves, and Revert goes back to how the file was opened. |
| **Simplest surface first** | Click runs, the pencil edits. Arguments, colors, the Finder and the rest are in the right-click menu. A flow is built from blocks first (nothing to remember); Flow code is the same file, one switch away. |
| **EPA keeps its promises here too** | EPA's own narration is what a run shows (its plan, each step's status word, the one next step), written once, by EPA (`--ask-json` carries the words). Its go-aheads come to the app's question window with the consequence EPA names; what can't be undone is red and needs a click, never Return or `--yes`; a key it asks for is a hidden field, never kept. Setting it up is one cell (setup-epa), safe to run again, and Check Setup offers to run it. |
| **Docs within reach, offline** | The Flow and Straw guides ship inside the app (each one file, the same as docs/FLOW-GUIDE.md and docs/STRAW-GUIDE.md); the editor lists every function, from the language itself; straw.py run with nothing lists every Straw word, from its own table. |

## 5 · The feel

> **Nothing is arbitrary. Every element reacts, every difference has a stated reason, the
> structure mirrors what the app actually contains, and the thing stays small in the head even
> as it grows.**

- **Everything reacts** — a hover lifts a cell, a press does something, always. Things you didn't
  touch hold still: running one cell doesn't move another.
- **Nothing is silent** — no action finishes without evidence.
- **Effects stay local** — the result appears where the action was taken: the cell shows its
  run and the result pane beside the cells shows its output and how it went, with no window to
  open; the editor shows its output underneath. A run started away from its grid (a recipe from
  the panel, a notice) opens its result where you are.
- **Friction follows stakes** — friction rises with consequence and falls with reversibility and
  frequency. Running a script is frequent and cheap: one click, no confirm. Trashing a script is
  rare: a confirm, and it's still reversible (Put Back). Like actions get like treatment, everywhere.
- **One writer per truth** — every fact is written in one place and read everywhere else: the
  builtin functions' table feeds the checker, the editor's list and the guide; the run states'
  marks and colors come from one mapping.
- **Behavior as data** — a new language is a row in the language table; a new builtin is a row in
  the builtin table; a new kind of block is a row in `BlockType.info`; a new danger is a row in
  `Caution.dangers`. Not a new `if` in a render path.
- **Words from the domain** — "Run", "Watch Output", "Couldn't start", "Move to Trash…"; never
  "Submit" or "OK".
- **Never-blank empties** — an empty grid says what belongs there and offers the first step
  (Add the Examples, New Script, Show Folder).
- **Honesty** — no invented numbers, no placeholder pretending to be finished.
- **Color is meaning** — mostly neutral; color for state and to tell same-type cells apart.
  The app follows light and dark mode; the cells keep their light colors in both.
- **Keyboard** — ⌘1 to ⌘4 open the grids (Scripts, Composer, Utilities, Browser), ⌘5 the API board, ⌘6 to ⌘9 Library, Memory, Mind and System Docs, ⌘R runs from the editor, ⌘S saves, ⌘. stops, Return
  and Escape answer every sheet.
- **A question says why** — nothing asks for an answer without saying what the answer decides:
  a flow's question carries its why (`confirmBecause`, the Ask step's Why field), a script's
  `Input:` carries its `Why:`, another app's request carries the app's `why` (and the card says
  when it gave none), and a run that starts by itself says which tag started it.

## 6 · Self-healing launch (the installer and the runner)

1. **One command** — install, update and repair are the same invocation.
2. **Probe, don't predict** — "is `python3` on the PATH the scripts run with?", not "is Python
   installed somewhere".
3. **A failure → fix table** — one place (`Remedy` in `ScriptProcess.swift`) maps a missing
   program to the command that installs it. An unrecognized failure is a missing row.
4. **Safest fix first** — retry, then a fallback path, then build from source; nothing
   destructive without asking.
5. **Degrade, don't die** — no release yet? Build here. The new build won't start? The previous
   app comes back.
6. **End with the state** — the installer closes with what was installed, what was replaced,
   and the next thing to do.

## 7 · The tests every change walks

**Walk these, don't just read them.** The builder is always already set up, which is exactly why
the worst faults survive review.

1. **Cold wake** — from a fresh install with no folder and no history, using only what's on
   screen: can you get from the menu bar icon to a script running, and to a flow running, with
   nothing confusing or unexpected? Note every surprise; each is a defect.
2. **The opener is outside the box** — anything that sets things up is reachable *before* the
   thing it sets up exists (choosing the folder is reachable with no folder; the examples are
   offered on the empty grid that needs them), and the less is set up, the more prominent it is.
3. **First press** — from a cold start, press the most prominent control. Does it do something?
   A refusal is guidance arriving one press too late: show the prerequisite first, or show the
   control disabled with its reason beside it.
4. **Anticipation** — in the state the person is in, is the next likely want already open and
   pointed at? (A new script opens straight in the editor with its name ready to type; a click on a
   cell shows its output beside the cells as it runs, and the result when it ends.)

And the checklist (any "no" is a defect with a name, not a matter of taste):

- [ ] Someone who's forgotten the project can do this using only what's on screen.
- [ ] There's one obvious thing to press to begin.
- [ ] It's visible and usable from the state the person is actually in, including nothing set up.
- [ ] The default path needs no remembered option.
- [ ] Nothing is asked that the app could work out.
- [ ] It says what it'll do before, and what happened after.
- [ ] The result appears where the action was taken.
- [ ] There's visible motion while it works.
- [ ] The same input gives the same output, by construction.
- [ ] The person can see from outside that the change shipped (the version is in the panel).
- [ ] Running it twice is safe and keeps what the first run did.
- [ ] Anything replaced or discarded is named first.
- [ ] Every ending, including every failure, says what to do next.
- [ ] Nothing behaves in a way the screen didn't lead the person to expect.
- [ ] A deliverable works on its own (the guide is one file inside the app; the installer is one command).
- [ ] The most prominent control works on the first press.
- [ ] The likely next want is already open, not merely somewhere.
- [ ] The words, defaults and prominence all speak the state actually recorded.

## 8 · Auditing a change (a walkthrough, in four stages)

When something feels off, audit before fixing:

1. **Walk** — from cold, step by step, write what's on screen (*See*), what you'd think
   (*Think*), what you do and why (*Do*), and what happens (*Get*). No fixes while walking.
2. **Debug** — name each stumble against the traits and tests above. Look for the *class* behind
   the instance: a report of one is usually a report of many.
3. **Plan** — the smallest set of changes that removes the classes, in order.
4. **Re-examine** — every stumble is accounted for, the journeys not walked are named, and the
   one deepest cause is stated in one sentence.

## 9 · Holding it loosely

These are defaults with the escape hatch built in. A deviation is right when a real user would be
at least indifferent and at best glad. The only wrong kind is "I didn't think about it". Deviate
knowingly, and say why.
