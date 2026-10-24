# The Straw guide

**Straw** is a small language for driving Google Chrome the way a person does: by naming what's
on the page. A Straw script is a `.straw` file in your scripts folder's `browser` folder, a plain
line for each step:

```
# The top stories on Hacker News right now, a line each
open news.ycombinator.com
wait css ".titleline"
read all css ".titleline > a"
```

It's a cell on the Browser grid like any other script: **click it to run it, click its pencil to
edit it.** A flow runs it by name (`run "hacker-news" []`), other apps run it over the HTTP API,
and in a terminal it's `python3 browser/straw.py browser/hacker-news.straw`.

It takes its idea from [Straw](https://github.com/ainigh/STRAWMAN) (*address things the way a
person would: by what they are called*) and keeps only the smallest part: twenty-five words, no
selectors unless you ask for one, nothing to install. `straw.py`, in the `browser` folder, runs
it; `browser.sh`, beside it, does the driving.

## Before the first run

Two things, once, both asked for the first time a browser script runs:

1. macOS asks whether Tool Mac Tool Run may control Google Chrome: click **Allow**.
2. In Chrome: **View > Developer > Allow JavaScript from Apple Events**.

`browser.sh` (its cell, with nothing typed) says whether both are done. Straw drives **the tab in
front** of Chrome's front window; `open` makes a new one and puts it there.

## A line

A line is a word, then what it works on. Text goes in quotes (`"…"` or `'…'`); a `#` starts a
comment, at the start of a line or after a space. Inside quotes, `\"` is a quote and `\\` a
backslash; any other backslash stays as it's written, so JavaScript's `'\t'` and `/\s+/` work in a
`js` line.

```
open example.com              # an address: quotes are optional when it's one word
click "Sign in"               # a THING: its name, as it's written on the page
type "Email" "me@example.com" # a THING, then the text
read title into heading       # into NAME keeps what's read as {heading}
print "It's {heading}"        # {heading} is filled in
```

**The whole file is checked before anything runs.** A word Straw doesn't know, a missing quote,
an `if` with nothing under it, a `{name}` nothing has given a value yet: each is said with its
line and the fix, and Chrome isn't touched. `python3 browser/straw.py --check FILE` checks one and
says what it would do, step by step, without running it.

## Naming things on the page

A **THING** is what a person would call it: the words on a button or link, a field's label, its
placeholder (`Type to search`), its `aria-label` or `title`, an image's `alt`. Case, extra spaces
and a trailing `…` or `:` don't matter.

- **Exact first.** `"Save"` finds something called exactly *Save* before *Save draft*, and *Save
  draft* (starting with it) before *Autosave* (having it in it).
- **The thing you'd click.** A name on a `<span>` inside a button is the button; a label is its
  field. `type "Email" "…"` finds the field the words *Email* name, or the one field right beside
  them.
- **One, or it says so.** When two buttons are both called *Delete*, Straw doesn't pick one: it
  stops, says how many, and how to say which, by what's beside it:

  ```
  click "Delete" in "my-old-key"      # the Delete in the row (the box) that has my-old-key in it
  ```

- **Or the first of them.** In a list of results, "the first one" is what a person says:
  `click first css "h3 a"` clicks the one highest on the page, of however many there are. Keep
  it for lists of the same kind of thing; for a button, say which (`in "…"`), so a page that
  changes stops the script instead of clicking the wrong one.

- **A selector when you need one.** `css "…"` takes a CSS selector instead of a name, for things
  with no name of their own: `read all css ".titleline > a"`, `click css "#next"`. A click needs
  it to match one thing too.

Only what's shown counts: something hidden, or under `aria-hidden`, isn't on the page.

## The words

| Word | Takes | Does |
|---|---|---|
| `open` | URL | opens the page in a new tab, in front, and waits for it to load |
| `go` | URL | the tab in front goes to the page, and waits for it |
| `tab` | TEXT | brings to the front the first tab whose address has TEXT in it |
| `back` `forward` `reload` | | goes back a page, forward a page, or loads it again |
| `wait` | [gone] [THING] [SECONDS] | alone, waits for the page to load; with a THING, until it shows (15 seconds unless SECONDS); `wait gone THING`, until it's gone |
| `click` | THING | clicks it (the pointer's whole press, for pages that listen for it) |
| `hover` | THING | puts the pointer over it (menus that open on hover) |
| `type` | THING TEXT | puts TEXT in the field; what was in it is replaced |
| `press` | KEY | a key in the field that has the focus: `Enter` (sends its form), `Tab`, `Escape`, `Space`, `Backspace`, `Delete`, the arrows, `Home`, `End`, `PageUp`, `PageDown`, or one character |
| `select` | THING OPTION | picks OPTION in a menu (a `<select>`): its words, exactly or how they start |
| `check` `uncheck` | THING | ticks or unticks a checkbox, or turns a switch on or off; already so stays so |
| `scroll` | THING, or `down` `up` `top` `bottom` | brings it into view, or scrolls the page |
| `see` | [no] THING | stops the script unless THING is on the page; `see no THING`, unless it isn't |
| `read` | THING, `all` THING, `after` THING, `links` THING, `title`, `url`, `page`, `links` [into NAME] | gives back its words (a field: what's in it; a checkbox: checked or unchecked). `all`: every match, a line each. `after`: what's beside it (a `<dt>`'s `<dd>`, the next cell, the field a label names). `page`: all its text. `links`: every link, its words, a tab and its address; `links` THING: the links among what THING names (each one's own, or the one it's in) |
| `js` | CODE [into NAME] | runs JavaScript in the page and gives back what it gives (an expression, or statements with a `return`); a list comes back a line each |
| `set` | NAME TEXT | remembers TEXT as `{NAME}` |
| `print` | TEXT | gives TEXT back, as the script's output |
| `ask` | NAME QUESTION | asks on the Mac, with a field to type in, and keeps the answer as `{NAME}` (Stop ends the script) |
| `confirm` | MESSAGE | asks on the Mac before going on: **Go On** or **Stop**. Stop is the default, so Return can't say yes for you |
| `stop` | MESSAGE | ends the script here, as a failure, saying MESSAGE |
| `if` | `see` THING, or `no` THING | does the lines indented under it only when THING is on the page (`if no`: only when it isn't) |
| `else` | | the lines indented under it, when the `if` just above didn't |

`read` and `js` without `into` give what they read back as the script's output, a line each;
with `into NAME` they keep it instead. What the script is doing goes beside the output (a line
a step, `→ click "Sign in"`), so a flow that runs it gets just the values.

## Values

- `{1}`, `{2}`… are the words the script is run with; `{args}` is all of them. In a `# Input:`
  line at the top, say what each is: the cell and the API board ask for it before running
  (`# Input: What to look up`, then `# Why: It's searched for on Wikipedia as typed`).
- `{NAME}` is what `set`, `ask`, or `read … into NAME` kept.
- `{NAME|default}` is the default when it's empty or not given: `{2|Search}`.
- In an address (`open`, `go`), a value after the `?` is made safe for it: `open
  "en.wikipedia.org/w/index.php?search={1}"` works for `Ada Lovelace` and for `R&D`.

## If and else

Indent the lines an `if` does by two spaces; an `else` lines up with its `if`:

```
if see "Accept all"
  click "Accept all"
else
  print "No cookie banner"
```

There are no loops: a script reads like the steps a person takes. For repeating, choosing, and
putting several scripts together, a flow runs Straw scripts by name (see the Flow guide).

## Waiting for evidence, not for time

There's no `sleep`. After a click that changes the page, wait for something that's only on the
next one, or for something on this one to go:

```
click "Search"
wait "Results"                       # until it shows
wait gone css ".spinner"             # until it's gone
```

`open`, `go`, `back`, `forward`, `reload`, a `click` and `press Enter` each wait for the page to
load by themselves, but a page that draws itself after loading needs a `wait` for what you want.

## Stopping on surprises

`see` is the guard: `see "Your account"` after signing in stops the script, with what the page in
front is instead, rather than clicking on into the wrong page. `see no "Something went wrong"`
stops it on an error the page shows.

A Straw script whose `click` names a button that can't be taken back (*Delete*, *Send*, *Buy*,
*Pay*, *Publish*, *Post*, *Submit*, *Transfer*, *Unsubscribe*…) is marked on its cell, and the app
asks before it runs, as it does for a shell script with `rm -rf`. Inside the script, put a
`confirm` right before such a step, so the question comes at the moment it matters:

```
type "Comment" "{1}"
confirm "Post this comment for everyone to see?"
click "Post"
```

## When something isn't found

The run stops at that line and says why, with the fix:

```
❌ Nothing on the page is called "Sign up". Near it on the page: "Sign in", "Sign out".
❌ 2 things on the page are called "Delete". Say which, by what's beside it: click "Delete" in "alpha-key" (or click first "Delete": the one highest on the page)
❌ "Results" didn't show in 15 seconds. The page in front is “Search – Example”.
❌ "Country" has no option "France". Its options: Ghana, Nigeria, Kenya
```

Never guess a name: read it off the page (`read links`, `read all css "button"`, or the page
itself). A name that's written on the page is the one that keeps working.

## The examples

The Browser grid's **Add the Examples** puts these in the `browser` folder (with `straw.py`):

| Script | Does |
|---|---|
| `hacker-news.straw` | the top stories on Hacker News, a line each |
| `wikipedia-article.straw` | an article's title and first paragraph (`{1}` is what to look up) |
| `page-outline.straw` | the page in front: its title, address and headings |
| `dismiss-cookies.straw` | clicks away the cookie banner on the page in front, if it has one |
| `fill-search.straw` | types into the page's own search box, presses Enter, gives back the new title |
| `youtube-videos.straw` | searches YouTube: the top videos, a line each (the title, a tab, the address) |
| `youtube-play.straw` | plays the first video for what you search for (`click first`) |
| `youtube-latest.straw` | a channel's newest videos (`{1}` is its handle: `LofiGirl`) |
| `github-repos.straw` | searches GitHub's repositories (`read links css "…"`) |
| `hn-search.straw` | searches every Hacker News story (through Algolia) |
| `arxiv-search.straw` | the newest papers on arXiv that match (a `js` line that gives back a list) |

Beside them, `site-search.sh` opens the results of any of 50 well-known sites by name
(`site-search amazon usb-c hub`, `site-search maps coffee`, `site-search list`), for the sites
that are better read by you than by a script.

Two Straw scripts are utilities, in the `utilities` folder, for other scripts and flows to build
on (the Utilities grid's **Add the Examples** brings `straw.py` and `browser.sh` with them):
`selected-text.straw` (what's selected on the page in front, or in the field you're typing in)
and `page-word-count.straw` (its words, and the minutes it takes to read).

The flows put them together with other scripts: `hn-briefing` (the top five stories, the first
said out loud), `clean-read` (the cookie banner clicked away, then the page's outline),
`search-everywhere` (YouTube, GitHub, Hacker News and arXiv, the top three of each),
`youtube-channels` (the newest from the channels you name), and `explain-selection`,
`translate-selection` and `read-selection-aloud`, which start from what you've selected.

A Straw script drives **the tab in front**, so two at once would share it: a flow runs them one
after another (`attempt`, a line each), not in `parallel`.
