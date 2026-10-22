# The Flow guide

A **flow** is a small program that composes your scripts: it runs them by name, hands what one
prints to the next, and decides what to do with the results. Flows are written in **Flow**, a
little language shaped like F#: values flow left to right through `|>`, nothing needs a type
written down, and every mistake is caught *before* the first script runs.

Flows live in the `composer` folder inside your scripts folder, one `.flow` file each, and each
gets a cell on the **Composer grid**. Click the cell to run it; click the pencil to edit it.

```
// Says hello, checks the disk, and warns when it's getting full
let greeting = run "hello" ["friend"]
print greeting

let used = run "disk-space" [] |> replace "%" "" |> int
print $"The disk is {used}% full."

if used > 85 then
    notify $"Disk is {used}% full: time to tidy up"
else
    print "Plenty of room."
```

That's `morning.flow`, one of the examples (**Add the Examples** on an empty grid puts them in
your folder, next to the example scripts they use). The first comment line is what the cell
shows under the flow's name.

---

## Building a flow with blocks

The pencil on a flow's cell opens it as **blocks**, like Apple's Shortcuts: a column of steps,
run top to bottom. Nothing needs typing that a menu can give you.

- **Add a step**: on the right are your scripts and every kind of step (Run Script, Show, Ask to
  Continue, If, Repeat with Each…). Click one to add it after the step you picked (or at the end),
  or drag it to where it goes. Drag a step's title to move it; drop it inside an If or a Repeat
  to put it there.
- **Use what a step made**: a step's output has a name (shown under it, and yours to change). The
  ⊕ beside any field puts a value from an earlier step in, written `{name}`; the text around it
  stays as it is: `Disk is {diskSpace} full`. A script run with **If it fails: Keep going** gives
  its whole result: what it printed, its errors, its exit code, and whether it worked.
- **Decide**: an **If** compares a value ("diskSpace *is greater than* 85", "greeting *contains*
  hi", "backup *failed*", "*you answer Yes to* Upload too?"), with **Otherwise** for the other case.
- **Repeat**: **Repeat with Each** goes through each line of a value (or each item of a list);
  **Repeat** does its steps a number of times.
- **Ask**: **Ask to Continue** stops the flow and asks before going on (put it before anything
  that deletes, sends or costs); **Ask for Text**, **Ask Yes or No** and **Choose from List** keep
  the answer for the steps after.
- **Show**: **Show Result** puts text (or a value) in a window of its own and waits for Done, as
  Shortcuts' Show Result does (`showResult`); **Show in Output** writes it into the run's output
  without stopping (`print`); **Show Notification** puts it on the screen (`notify`): a large
  notice in the middle of the screen, half its size, that goes by itself after a few seconds
  (not while the pointer is on it); a click shows the run.
- **Anything else**: a **Flow Code** step holds any Flow, word for word.

As you build, the flow is written as Flow, saved, and checked: a step with a mistake is outlined
in red with the fix under it, and the bar under the steps says whether it's ready to run. When it
runs, each step that runs a script shows how it went (click it for its output).

**Blocks and Flow Code are the same file.** The switch at the top of the editor shows it either
way; change it in one and the other follows. A flow written by hand opens as blocks too: what the
blocks don't cover (a function of your own, a long pipeline) shows as a Flow Code step, kept
exactly as written, and a step you don't change is saved exactly as it was. ⌘Z undoes a change to
the blocks.

---

## Running a flow

- **From the Composer grid**: click its cell. While it runs, the cell's border moves and its
  last line of output shows; click it again to watch everything it prints.
- **From the editor**: **Save & Run** (⌘R). The output shows under the editor.
- **From a terminal**: `flow run ~/Scripts/composer/morning.flow` (the installer puts the `flow`
  command in `~/.local/bin`). `flow check file.flow` checks it without running anything and shows
  the type of everything it defines. `flow functions` lists every function.

Every run, and every script a flow runs (as a step under it), is in the **Runs** window, with
what it printed and the command to run it yourself in a terminal.

A flow is checked before it runs. If it has a mistake, nothing runs: the cell says
*Couldn't start*, and the editor shows the line and how to fix it.

**When it asks.** A flow that asks (`confirm`, `ask`, `choose`, `askYesNo`) waits: its question
comes forward in a small window, its cell says *Waiting for your answer*, and Runs and the editor
show it too; any of them answers it. Stop ends the flow there. From a terminal, `flow run` asks
in the terminal; `flow run --yes file.flow` answers Continue and Yes by itself (for a run with no
one at the keyboard).

**When it takes a while.** A run still going after a minute gets a notification (click it to
watch, or stop, it); the panel's bell (**Notice after…**) changes how long, or turns
it off. A cell whose run has printed nothing for a while says so, so a quiet run never looks hung.

---

## The language in ten minutes

### Comments

```
// to the end of the line
# also to the end of the line (so a #! first line is fine)
(* across
   several lines *)
```

### Values and their types

| Type | Looks like | Notes |
|---|---|---|
| `int` | `42`, `-3`, `1_000` | whole numbers only, from -9223372036854775808 to 9223372036854775807 |
| `string` | `"hello"`, `$"hi {name}"` | text |
| `bool` | `true`, `false` | |
| `unit` | `()` | "nothing": what a step that only *does* something gives back |
| `'a list` | `[1; 2; 3]`, `["a", "b"]` | every item the same type |
| `Run` | from `attempt` | a script's whole result: `.out`, `.err`, `.code`, `.ok` |
| `'a -> 'b` | `fun x -> x + 1` | a function |

`'a` and `'b` stand for "any type" (generic), as in F#.

### Names: `let`

```
let name = "world"
let count = 3
```

A name can be defined again further down (the new one hides the old one from there on). There
are no variables that change: to build a new value, make one from the old. That works for
functions too: in `let f x = f (x * 10)`, the `f` inside is the `f` from above, as in F# (only a
`let rec` sees its own name; see *Functions of your own*).

Whole numbers that get too big (past 9223372036854775807, or below -9223372036854775808) stop
the flow with a message, rather than quietly turning into a wrong number.

### Text

- `"plain text"`, with `\n` (new line), `\t` (tab), `\"` (a quote) and `\\` (a backslash).
- `$"Hello {name}, you have {count + 1} files"`: an **interpolated** text. Anything inside
  `{…}` is worked out and put in as text (numbers, lists, anything). Write `{{` and `}}` for
  braces of their own. Text inside `{…}` is fine, braces and all, written either way:
  `$"{name + "!"}"` or `$"{name + \"!\"}"`, `$"{ "}" }"`.
- `+` joins text: `"a" + "b"`.

### Calling a function

A function is called by writing its arguments after it, separated by spaces (no commas, no
brackets):

```
print "hi"
replace "old" "new" "the old text"
```

Brackets group: `print (upper name)`. Without them, `print upper name` would hand `print` two
values.

Every function takes its arguments **one at a time**, so giving fewer makes a new function
waiting for the rest. `contains ".swift"` is a function that tells whether a text contains
`.swift`, ready for `filter`:

```
files |> filter (contains ".swift")
```

### Pipelines: `|>`

`x |> f` means `f x`: the value on the left goes in as the **last** argument of the function on
the right (and it's worked out first, so in `run "a" [] |> pipe "b" [run "c" []]`, `a` runs
before `c`). That's why the functions take the thing they work on last:

```
run "list-files" [folder]
|> lines
|> filter (endsWith ".log")
|> sort
|> join ", "
|> print
```

A line that starts with `|>` (or any operator) carries on the line above, so long pipelines read
top to bottom. (A line starting with a negative number, such as `-2`, is a number, not a minus
carrying on: write `- 2` to subtract on a line of its own.)

`f >> g` joins two functions into one that does `f`, then `g` (`f` and `g` are worked out once,
when it's made):

```
let tidy = trim >> lower
print (tidy "  HELLO ")   // hello
```

### Functions of your own

```
let shout s = upper s + "!"
let add a b = a + b
let check name =
    let r = attempt name []
    if r.ok then $"✅ {name}" else $"❌ {name} ({r.code})"
```

`let name params = body`. The body can sit on the same line, or on the lines under it,
indented (see *Blocks* below); its last line is what the function gives back.

A function that calls itself is a `let rec` (as in F#: without `rec`, the name inside is
whatever it meant above, and if nothing, the checker says to add `rec`):

```
let rec countdown n =
    if n > 0 then
        print n
        countdown (n - 1)
```

`let rec f = fun n -> …` works too. A function that calls itself without end stops the flow
with a message (after some thousands of calls), rather than running forever.

A function without a name: `fun x -> x * 2`. A function that takes nothing: `fun () -> …`, and
it's called with `()`: `let stamp () = now ()`.

### Blocks and indentation

Indentation decides what belongs to what, as in F# and Python:

- A line **indented under** another carries it on (it's part of the same step).
- Lines at the **same** indent are steps one after another.
- The body of a `let … =`, a `fun … ->`, a `then` or an `else` can go on the lines under it,
  indented; those lines are a **block**. A block's value is its last line's.

```
let report folder =
    let files = run "list-files" [folder] |> lines
    let n = length files
    $"{n} files in {folder}"
```

A `fun` inside brackets can have a block too:

```
files |> each (fun f ->
    print $"Linting {f}"
    run "lint" [f] |> print)
```

Use spaces to indent (tabs count as one space each, so they're easy to get wrong).

### Choices: `if`

```
let used = run "disk-space" [] |> int
if used > 85 then notify "Disk nearly full" else print "fine"

let n = run "list-files" ["~/Desktop"] |> lines |> length
let size =
    if n > 100 then "big"
    elif n > 10 then "medium"
    else "small"
```

Both sides of an `if` give back the same type. An `if` with no `else` can only *do* something
(its `then` gives back `unit`).

### Operators

| Operator | Means | Works on |
|---|---|---|
| `+` | add, or join text | `int`, `string` |
| `-` `*` `/` `%` | subtract, multiply, divide (whole), remainder | `int` |
| `=` or `==` | equal | anything but functions (or lists of them) |
| `<>` or `!=` | not equal | anything but functions (or lists of them) |
| `<` `<=` `>` `>=` | compare | `int`, `string` (alphabetically) |
| `&&` `\|\|` | and, or (the right side is only looked at when needed) | `bool` |
| `@` | join two lists | lists |
| `\|>` | pipe a value into a function | anything |
| `>>` | join two functions | functions |

`not` is a function: `not (exists "out.txt")`.

A minus sign touching a number, with a space before it, makes it negative, as in F#: `range -3 3`
and `twice -1` give the functions -3 and -1 to work on. `a - 1` and `a-1` subtract.

From loosest to tightest: `|>`, `>>`, `||`, `&&`, comparisons, `@`, `+ -`, `* / %`, a minus
sign, calling a function, `.field`.

### Lists

```
let names = ["ada"; "linus"; "grace"]     // ; or , between items
let more = names @ ["ken"]
let xs = [
    "one"                                  // or one per line
    "two"
]
```

What you'll use most: `map`, `filter`, `each`, `fold`, `length`, `isEmpty`, `first`, `last`,
`take`, `skip`, `sort`, `reverse`, `unique`, `range`, `sum`, `join`. They're all in the list of
functions at the end.

### Doing something for each item: `for`

```
for line in lines (run "list-files" []) do
    print $"→ {line}"
    run "check" [line] |> print

for i in range 1 3 do
    print i
```

`for name in items do`, then the steps, indented under it. It's `each` written as a step (it's
what the block editor's Repeat writes). Besides `for`, `map` makes a new list, `filter` keeps some
items, `fold` carries a value through a list, and a `let rec` function can call itself.

---

## Running your scripts

| Function | Type | What it does |
|---|---|---|
| `run` | `string -> string list -> string` | runs a script; gives back what it printed (trimmed); **stops the flow if it fails** |
| `attempt` | `string -> string list -> Run` | runs a script and **keeps going** whatever happens; you get `.out`, `.err`, `.code`, `.ok` |
| `pipe` | `string -> string list -> string -> string` | runs a script with text as its input (stdin, ending with a line break), made for `\|>` |
| `attemptPipe` | `string -> string list -> string -> Run` | `pipe` that keeps going when the script fails, like `attempt` |
| `sh` | `string -> string` | runs one line of shell (bash) |
| `parallel` | `(unit -> 'a) list -> 'a list` | runs several steps at once, waits for all, keeps their order |
| `retry` | `int -> (unit -> 'a) -> 'a` | tries a step up to n times, waiting a little longer each time |

- **Names.** `run "hello"` finds `hello.sh` (or `hello.py`…): the file name with or without its
  extension. If two scripts share a name with different extensions, write the extension. A flow
  can run another flow the same way (`run "morning" []`); what that flow prints is its output.
  Utilities and browser scripts are found the same way (`run "speak" ["Done"]`); when a script at
  the top of the folder has the same name, that one wins, and `run "utilities/speak"` picks the
  utility.
- **Arguments** always go in a list of text: `run "resize" [file; "800"]`. A number goes in as
  `string n`, or inside `$"…"`. They reach the script exactly as given (no shell splitting), so a
  space in an argument is fine.
- **Where it runs.** Scripts run in your scripts folder, with your login shell's PATH (so
  Homebrew's `python3`, `node` and the rest are found).
- **Failure.** `run` stops the flow when a script's exit code isn't 0, saying which script, on
  which line, and its last error line. Use `attempt` when failing is an answer, not an accident
  (a script that can't run at all, such as a name worked out while running that isn't in the
  folder, is a failure too: `.ok` false, `.code` 127, `.err` saying why):

```
let r = attempt "ping-server" ["example.com"]
if r.ok then print "up" else notify $"Server down: {r.err}"
```

- **Stopping.** Stop (on the cell, in Runs, or Ctrl-C for `flow run`) stops the script running
  now, and nothing after it starts.
- **The flow's own arguments** are `args : string list` (from the cell's arguments, or
  `flow run x.flow a b`).

### Utilities and the browser

Two more grids hold scripts too, each in a folder of its own inside your scripts folder:

- **Utilities** (`utilities/`): small reusable helpers. The examples tell you what's going on:
  `weather` (where you are, or a place you name), `news` (the top stories, a topic, or with
  `--critical` only what looks urgent, each line starting with 🚨), `cloud-status` (whether AWS,
  Google Cloud, Azure, GitHub, Cloudflare, OpenAI, Claude, Slack and more are up: ✅ ⚠️ 🔴 ❓ at
  the start of each line; `--problems` for only the ones that aren't). Others play a sound
  (`play-sound`) or a song from Music (`play-song`), say text out loud (`speak`), use the
  clipboard (`clipboard`), and parse data: `json-get` picks values out of JSON, `csv-to-json`
  turns CSV into JSON, `extract-urls` lists every web address in some text.
- **Browser** (`browser/`): scripts that drive Google Chrome. `browser.sh` does the driving;
  `google` asks Google and gives back just the answer (Google's own, then the top results),
  `youtube` gives the top videos (or plays the first with `--play`), `youtube-music` plays a song
  and takes `pause`, `play`, `next`, `previous` and `now`; `open-page`, `page-info`, `page-text`
  and `page-links` work on any page.

More utilities look things up (`wikipedia`, `define`, `currency`, `world-clock`, `public-ip`),
check things (`site-check`, `battery`, `system-info`) and help (`password`, `timer`). They build on
each other: `timer` plays its sound and says its words through `play-sound` and `speak`;
`translate` is `google --answer` (Google's own answer alone); `save-tabs`, `close-duplicate-tabs`,
`maps` and `gmail` (your unread mail) drive Chrome through `browser.sh`.

The Composer examples do the heavy lifting with them: `ask-google`, `weather-now`,
`news-briefing`, `urgent-news`, `cloud-check`, `youtube-search`, `play-music`, `research`,
`travel-check`, `focus-session`, `site-watch`, `mac-health`, `translate`, `tidy-chrome`,
`inbox-check`, `new-password` and `morning-briefing`, which fetches the weather, the news and the
cloud services at the same time and keeps going when one can't be reached:

```
let get r = if r.ok then r.out else $"(couldn't get it: {r.err})"
let found =
    parallel [
        (fun () -> attempt "weather" [])
        (fun () -> attempt "news" ["--critical"; "--count"; "5"])
        (fun () -> attempt "cloud-status" ["--problems"]) ]
    |> map get
```

They're scripts like any other: a click runs one, the pencil edits it, and a flow runs it by
name. What they print is what a flow gets back, so the browser hands data straight to the next
step:

```
// Lists every address the page in front in Chrome links to, then plays a sound
let addresses = run "page-links" [] |> pipe "extract-urls" [] |> lines
print $"{length addresses} addresses on the page:"
addresses |> each print

run "play-sound" ["Glass"] |> ignore
```

```
"name,email\nAda,ada@example.com" |> pipe "csv-to-json" [] |> pipe "json-get" ["*.email"] |> print
```

`browser.sh` drives Google Chrome. What a flow can ask of it:

| `run "browser.sh" […]` | gives back |
|---|---|
| `[]` | whether Chrome is ready, and what to switch on if not |
| `["open"; url]` | opens the page in a new tab, in front, waits for it to load, gives its title |
| `["read"; url; code]` | opens the page in a tab of its own **behind** the one you're on, waits until the JavaScript gives something back (the page's text without one), gives that, closes the tab |
| `["url"]`, `["title"]`, `["text"]` | the address, title or text of the page in front |
| `["tabs"]` | each tab of the front window: its title, a tab, its address |
| `["js"; code]` | runs JavaScript in the page in front |
| `["js-in"; part; code]` | runs it in the first tab whose address has `part` in it (`"music.youtube.com"`) |
| `["focus"; part]`, `["go"; part; url]` | brings that tab to the front; sends it to an address (a new tab if there's none) |
| `["wait"]` | waits (up to 30 seconds) for the page in front to finish loading |
| `["encode"; text]` | the text made safe to put in an address (`?q=…`) |

JavaScript is an expression (`document.title`), or statements whose answer is given back by a
`return` at the start of a line; what isn't text comes back as JSON.

Two things are asked once, the first time: macOS asks whether the app may control Chrome (click
**Allow**), and Chrome needs **View › Developer › Allow JavaScript from Apple Events** ticked.
Until then, the browser scripts say which one is missing, and where it is.

### What a script or a flow takes: `Input:` lines

A comment line near the top says what a script (or a flow) takes before it runs:

```
#!/bin/bash
# Asks Google and gives back just the answer
#
# Input: What should Google be asked?
# Input (optional): A language (English unless set)
# Input text: The page to read
```

`Input:` is one argument (the whole answer, spaces and all); `(optional)` may be left empty
(then it's left out); `Input text:` is text handed to it as its input (stdin). In a flow, the
answers are its `args`. The API board asks for each before a click runs it (with the last
answers already in), and `GET /api/scripts` and `/api/flows` list them for other apps. The
summary on a cell is the first comment line that isn't an `Input:` line.

### Asking the person running it

| Function | Type | What it does |
|---|---|---|
| `confirm` | `string -> unit` | asks before going on: Continue carries on, Stop ends the flow |
| `askYesNo` | `string -> bool` | asks a yes-or-no question: `true` for Yes |
| `ask` | `string -> string` | asks for a line of text |
| `choose` | `string -> string list -> string` | asks to pick one of a list |

```
confirm "Delete last month's backups?"
run "clean-backups" [] |> print

let size = choose "Which size?" ["small"; "large"]
if askYesNo $"Upload the {size} one too?" then run "upload" [size] |> print
```

A script that asks before it runs from its cell asks from inside a flow too: one set to **Ask
Before Running** (on its cell's right-click menu), and one that looks like it does something that
can't be undone (✋ on its cell), unless it's set never to ask.

### EPA: Cloudflare and the services around it

[EPA](https://github.com/ainigh/ENTER-PRICE-AUTOMATION) (Enter-Price Automation) connects and
runs Cloudflare, Resend, SendGrid, Amazon SES, MailUp, Microsoft 365, Google and Freshdesk, through
one command, `epa`. Flows run it as a step of its own:

| Function | Type | What it does |
|---|---|---|
| `epa` | `string list -> string` | runs `epa` with these words; gives back what it showed; **stops the flow if it fails**, with EPA's own sentence and its next step |
| `attemptEpa` | `string list -> Run` | the same, but **keeps going**: `.ok`, `.out` (what it showed), `.err` (what failed, and `Next: …`) |

```
let domain = ask "Which domain will the email come from?"
epa ["connect"; "resend"; "--domain"; domain; "--test-to"; "me@acme.com"] |> ignore

let check = attemptEpa ["doctor"]
if not check.ok then notify "EPA needs something: see the run's output"
```

- **It reads as it does in a terminal.** The run's output is EPA's own words: its plan first,
  each step with its status word (✓ created, ↺ already in place, ✚ repaired, ⤳ skipped, ✗ failed),
  and the next step at the end. Links in it (where to get a key, the Atlas) are clickable.
- **It asks here.** EPA asks before it changes anything, naming what will change; the question
  comes up in the app's window (or the terminal, for `flow run`), like `confirm`. Go ahead and it
  goes on; Stop Flow tells EPA no and ends the flow. What can't be undone (EPA replacing mail
  records, moving email to the Trash) says so in red, and isn't answered by Return or by
  `flow run --yes`. A key it needs is asked for in a hidden field, and never kept in the run.
- **Where it runs.** In your scripts folder, so EPA's keys go in `.env` there (the `epa-keys`
  script opens it; Check Connections says what each service needs). Every run also keeps a full
  record in `.epa/logs/` there, secrets masked.
- **The commands** are EPA's: `doctor` (check every connection), `connect`, `secure`, `gmail`,
  `see`, `do`, `person`, `onboard`, `offboard`, `sweep`, `lists`, `atlas`. One EPA doesn't have
  is caught before anything runs (*EPA has no command "conect". Did you mean "connect"?*).
  `epa ["help"]` lists every option.
- **Blocks.** The library's **EPA** section has each command as a step, with example words ready
  to change; **If it fails: Keep going** makes it `attemptEpa`.
- **Not set up yet?** **Add the EPA Recipes** (on an empty grid, in the panel's EPA section, or
  `flow recipes ~/Scripts`) puts `setup-epa` in your folder and runs it: it installs Node.js if
  needed, fetches EPA into `~/.local/share/epa` and links `epa` into `~/.local/bin`. Running it
  again updates EPA. **Check Setup** says whether EPA is there, which flows use it, and where its
  keys are.

The recipes, each a flow made of blocks (open one with its pencil to see how it's built):

| Flow | What it does |
|---|---|
| `epa-check-connections` | checks every service EPA can reach (read-only) and says the next step |
| `epa-connect-service` | picks a service and connects it, proving it works |
| `epa-sending-domain` | sets a domain up to send email: the service, DNS on Cloudflare, verification, a test email |
| `epa-secure-site` | puts email sign-in in front of a site on Cloudflare |
| `epa-gmail-on-your-domain` | you@yourdomain.com in a free Gmail, through Cloudflare |
| `epa-person` | everything every connected service knows about one address |
| `epa-onboard` / `epa-offboard` | a joiner or a leaver, everywhere at once, in one go-ahead |
| `epa-phishing-sweep` | one phishing email out of every mailbox: counts first, then asks |
| `epa-atlas` | EPA's Atlas in your browser: every provider's reads and actions (Stop closes it) |

### Every script name is checked first

`run "helo" []` doesn't wait to fail at that line: the check before running says *There's no
script called "helo" in your scripts folder. Did you mean "hello.sh"?* (only when the name is
written out in quotes; a name worked out while running is checked when it runs).

---

## Types, worked out for you

Nothing in a flow needs a type written down. Before anything runs, the checker works out the type
of every value from how it's used (it's the Hindley–Milner method F# and OCaml use), and the
editor shows what it found beside the flow, as you type:

```
greeting : string
used : int
check : string -> string
twice : ('a -> 'a) -> 'a -> 'a
```

- **Generic functions.** `let id x = x` is `'a -> 'a`: it works on anything, and each use can be
  a different type.
- **`+` and comparisons** work on numbers and on text. When nothing says which, it's numbers, as
  in F#: `let add a b = a + b` is `int -> int -> int`.
- **`=` and `<>`** work on anything that isn't a function and has none inside it. A function that
  compares what it's given stays generic: `let same a b = a = b` is `'a -> 'a -> bool`, for
  numbers, text, lists… but `same print print` is a mistake.
- **One type per list, one type per `if`.** A list's items are all the same type; both sides
  of an `if` give back the same type.

### The mistakes it catches, and what it says

| You wrote | It says | The fix |
|---|---|---|
| `run "x" [count]` | `run` needs text (string) here, but this is a number (int) | `[string count]` or `[$"{count}"]` |
| `run "x" "a"` | needs a list (string list) here, but this is text | `["a"]` |
| `let n = run "count" []` then `n + 1` | both sides of + have to be the same type | `run "count" [] \|> int` |
| `prnt "hi"` | I don't know `prnt`. Did you mean `print`? | |
| `let r = run "x" []` then `r.ok` | only a script's result (from `attempt`) has .ok | use `attempt` |
| `if ok then 1 else "one"` | both sides of an `if` have to give back the same type | |
| `print "a" "b"` | `print` is a function given one value too many | one step per line, or brackets |
| `if x then 5` | an `if` without `else` can only do something | add an `else`, or `\|> ignore` |
| `map upper` on a line of its own | `map` is missing a value: it needs 1 more | give it the list, or `names \|> map upper` |
| `let f n = … f (n - 1)` | `f` can't use itself here: a `let` only sees its own name when it's a `let rec` | `let rec f n = …` |
| `[print] = [print]` | functions can't be compared | compare what they give back |

Every message names the line, and the editor's **Go to line** takes you there.

---

## Recipes

**Run a script for each file in a folder**

```
run "list-files" ["~/Desktop"]
|> lines
|> filter (endsWith ".png")
|> each (fun f -> run "optimize-image" [f] |> print)
```

**Hand one script's output to the next**

```
run "export-contacts" []
|> pipe "dedupe.py" []
|> pipe "to-csv.js" []
|> write "~/Desktop/contacts.csv"
```

**Keep going when one step fails, and say how each went**

```
let check name =
    let r = attempt name []
    if r.ok then $"✅ {name}" else $"❌ {name}: {r.err}"

["backup-photos"; "backup-docs"; "backup-mail"] |> map check |> each print
```

**Do three things at once**

```
let results =
    parallel [
        (fun () -> run "fetch-weather" [])
        (fun () -> run "fetch-calendar" [])
        (fun () -> run "fetch-news" [])
    ]
results |> join "\n\n" |> print
```

**Retry something flaky**

```
retry 3 (fun () -> run "upload" [file]) |> ignore
```

**Only when something is true**

```
if not (exists "~/Desktop/report.pdf") then
    run "make-report" [] |> ignore
notify "Report ready"
```

**Show what it found**

```
let used = run "disk-space" []
showResult $"The disk is {used} full"
```

**Count, add up, decide**

```
let sizes = run "file-sizes" [] |> lines |> map int
let total = sum sizes
if total > 1000 then notify $"{total} MB used" else print "fine"
```

**A flow as a building block**: write `tidy-downloads.flow`, then from any other flow
`run "tidy-downloads" [] |> print`.

---

## Your own functions, and growing the language

### In a flow

Most "built-in" helpers you'll want are one `let` away, and they're as good as the built-in ones:
checked, generic, usable with `|>`:

```
let lastLine = lines >> last
let ok name = (attempt name []).ok
let runAll names = names |> map (fun n -> run n [])
```

There's no `import` yet: a helper used by several flows goes in each (or in a flow of its own
that the others `run`).

### In the language itself (for whoever builds the app)

The language is four small files in `Sources/RunCore/Flow/`, one stage each:

| File | Stage |
|---|---|
| `Lexer.swift` | text → tokens (numbers, text, names, keywords, symbols), with positions |
| `Parser.swift` | tokens → a tree (`Expr`), with F#'s indentation rule |
| `Checker.swift` | the tree → a type for everything (Hindley–Milner), or a mistake with its line and fix |
| `Interpreter.swift` | runs the tree; scripts are run through a `FlowHost` |
| `Blocks.swift` | the block editor's view of a flow: blocks written as Flow and read back (anything else is a Flow Code block, word for word) |

**Adding a builtin is one row** in `Builtins.swift`: its name, its type written as F# writes it,
its group, one sentence, an example, how many arguments it takes, and what it does:

```swift
Builtin("words", "string -> string list", "Text", "Splits text at spaces and new lines.", "\"a b  c\" |> words", arity: 1) { _, a, _ in
    .list(a[0].string.split(whereSeparator: { $0 == " " || $0.isNewline }).map { .str(String($0)) })
},
```

The checker reads its type from that string, the editor's function list and this guide's list are
made from that row, and a test checks that every signature reads back as written and every
example parses. So a new builtin needs nothing else. Put the thing it works on **last**, so it
fits `|>`. To run something on the computer, go through `i.host` (see `FlowHost`), so the app,
the `flow` command and the tests each supply their own.

**A new operator**: add its symbol to `Lexer.symbols` (longest first), its precedence level to
`Parser.levels`, its type rule to `Checker.binary`, and what it does to `Interpreter.binary`.
**A new keyword**: `Lexer.keywords`, then its own case in `Parser.atom`.

Run `swift test` after any change (it runs on a Mac or on Linux).

---

## The grammar, briefly

```
program   = block
block     = item { NEWLINE-at-same-indent item }
item      = "let" ["rec"] name {param} "=" body
          | expr
param     = name | "()"
body      = expr                         (on the same line)
          | INDENTED block               (on the lines under it)
expr      = pipe
pipe      = compose { "|>" compose }
compose   = or { ">>" or }
or        = and { "||" and }
and       = compare { "&&" compare }
compare   = append [ ("="|"=="|"<>"|"!="|"<"|"<="|">"|">=") append ]
append    = sum [ "@" append ]
sum       = product { ("+"|"-") product }
product   = unary { ("*"|"/"|"%") unary }
unary     = "-" unary | apply
apply     = postfix { postfix | "-"INT } (arguments on the same line or indented under it)
postfix   = atom { "." name }
atom      = INT | STRING | $STRING | "true" | "false" | name
          | "(" ")" | "(" expr ")" | "[" [expr {(";"|","|NEWLINE) expr}] "]"
          | "fun" param {param} "->" body
          | "if" expr "then" body {"elif" expr "then" body} ["else" body]
          | "for" name "in" expr "do" body
```

A `let rec` without parameters has to be a `fun` (`let rec f = fun x -> …`). A minus sign right
before a number is part of it (so `-9223372036854775808` can be written), and a number with a
minus touching it and a space before it (`f -1`) is an argument of its own. Windows line endings
are fine, and so is a byte order mark at the start of the file. Things can nest (brackets in
brackets, blocks in blocks, `1 + 1 + …`) up to 300 levels deep; past that, the checker asks you
to split it up with `let`s, so the editor and the run never run out of room.

---

## Not in the language (yet), on purpose

- **Decimal numbers.** Numbers are whole. Scripts that need decimals can do the arithmetic and
  print the answer.
- **Records, `match`, options.** A script's result (`Run`) is the one record; `if`/`elif` covers
  the choices flows have needed so far.
- **Changing a name's value, and loops.** `each`, `map`, `fold` and functions that call
  themselves do the work of loops, and nothing can change behind your back.
- **`import`.** Flows share by running each other.
- **Reading from the keyboard line by line.** A flow asks with `ask`, `choose`, `askYesNo` and
  `confirm` instead (in the app, a window; in a terminal, a prompt).

Each of these would be a row or a stage above; they're left out until a flow needs one.
