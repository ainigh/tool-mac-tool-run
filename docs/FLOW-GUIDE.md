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
| `int` | `42`, `-3`, `1_000` | whole numbers only |
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
are no variables that change: to build a new value, make one from the old.

### Text

- `"plain text"`, with `\n` (new line), `\t` (tab), `\"` (a quote) and `\\` (a backslash).
- `$"Hello {name}, you have {count + 1} files"`: an **interpolated** text. Anything inside
  `{…}` is worked out and put in as text (numbers, lists, anything). Write `{{` and `}}` for
  braces of their own.
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
the right. That's why the functions take the thing they work on last:

```
run "list-files" [folder]
|> lines
|> filter (endsWith ".log")
|> sort
|> join ", "
|> print
```

A line that starts with `|>` (or any operator) carries on the line above, so long pipelines read
top to bottom.

`f >> g` joins two functions into one that does `f`, then `g`:

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

A function can call itself:

```
let countdown n =
    if n > 0 then
        print n
        countdown (n - 1)
```

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
if used > 85 then notify "Disk nearly full" else print "fine"

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
| `=` or `==` | equal | anything but functions |
| `<>` or `!=` | not equal | anything but functions |
| `<` `<=` `>` `>=` | compare | `int`, `string` (alphabetically) |
| `&&` `\|\|` | and, or (the right side is only looked at when needed) | `bool` |
| `@` | join two lists | lists |
| `\|>` | pipe a value into a function | anything |
| `>>` | join two functions | functions |

`not` is a function: `not (exists "out.txt")`.

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

There are no loops: `each` does something for every item, `map` makes a new list, `fold` carries
a value through a list, and a function can call itself.

---

## Running your scripts

| Function | Type | What it does |
|---|---|---|
| `run` | `string -> string list -> string` | runs a script; gives back what it printed (trimmed); **stops the flow if it fails** |
| `attempt` | `string -> string list -> Run` | runs a script and **keeps going** whatever happens; you get `.out`, `.err`, `.code`, `.ok` |
| `pipe` | `string -> string list -> string -> string` | runs a script with text as its input (stdin), made for `\|>` |
| `sh` | `string -> string` | runs one line of shell (bash) |
| `parallel` | `(unit -> 'a) list -> 'a list` | runs several steps at once, waits for all, keeps their order |
| `retry` | `int -> (unit -> 'a) -> 'a` | tries a step up to n times, waiting a little longer each time |

- **Names.** `run "hello"` finds `hello.sh` (or `hello.py`…): the file name with or without its
  extension. If two scripts share a name with different extensions, write the extension. A flow
  can run another flow the same way (`run "morning" []`); what that flow prints is its output.
- **Arguments** always go in a list of text: `run "resize" [file; "800"]`. A number goes in as
  `string n`, or inside `$"…"`. They reach the script exactly as given (no shell splitting), so a
  space in an argument is fine.
- **Where it runs.** Scripts run in your scripts folder, with your login shell's PATH (so
  Homebrew's `python3`, `node` and the rest are found).
- **Failure.** `run` stops the flow when a script's exit code isn't 0, saying which script, on
  which line, and its last error line. Use `attempt` when failing is an answer, not an accident:

```
let r = attempt "ping-server" ["example.com"]
if r.ok then print "up" else notify $"Server down: {r.err}"
```

- **Stopping.** Stop (on the cell, in Runs, or Ctrl-C for `flow run`) stops the script running
  now, and nothing after it starts.
- **The flow's own arguments** are `args : string list` (from the cell's arguments, or
  `flow run x.flow a b`).

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
apply     = postfix { postfix }          (arguments on the same line or indented under it)
postfix   = atom { "." name }
atom      = INT | STRING | $STRING | "true" | "false" | name
          | "(" ")" | "(" expr ")" | "[" [expr {(";"|","|NEWLINE) expr}] "]"
          | "fun" param {param} "->" body
          | "if" expr "then" body {"elif" expr "then" body} ["else" body]
```

---

## Not in the language (yet), on purpose

- **Decimal numbers.** Numbers are whole. Scripts that need decimals can do the arithmetic and
  print the answer.
- **Records, `match`, options.** A script's result (`Run`) is the one record; `if`/`elif` covers
  the choices flows have needed so far.
- **Changing a name's value, and loops.** `each`, `map`, `fold` and functions that call
  themselves do the work of loops, and nothing can change behind your back.
- **`import`.** Flows share by running each other.
- **Reading from the keyboard.** A flow runs from a click, with no terminal to type into: give it
  arguments instead.

Each of these would be a row or a stage above; they're left out until a flow needs one.
