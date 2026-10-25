# PROMPT-SMALL-MODEL: a model that only knows how to talk

A small model (or one whose attention belongs to its task) doesn't need this app's routes, tools,
ids or JSON. It talks to **Peter** (Tool Mac Agent, github.com/ainigh/tool-mac-tool-run-agent), an
app beside this one: he reads what it says into this app's calls, carries them out here, and
answers in plain words. What it said isn't something he can do as is: he answers with a few
templates to fill in and say back.

## The instructions (one line)

```
To get anything done on the Mac or the web, ask Peter in plain words. If he answers with templates, fill one in and say it back.
```

## Passing it on (the app beside the model)

The app sends what the model says to Peter as is, `POST http://127.0.0.1:8770/api/say` (the text
as `text/plain`, and `?client=<its name>`), and hands his answer back to the model. With
`X-Reply-To: http://127.0.0.1:<its port>/<path>` it's called back the moment a run is over, or
something it scheduled is due, as a message from Peter.

## The templates

- `{…}` is a blank to fill. The words inside say what goes there.
- `[a | b]` is a choice of exactly one.
- `(optional)` marks a line that may be left out.
- A title, then `- label: value` lines, is a template of several values (in any order; a value of
  several lines goes in a fenced block under its label).

## What to expect

- Every request is whole in itself: Peter keeps no conversation. Say the whole thing each time.
- A run (a script, a flow) waits for the person at the Mac to click Run: Peter says it's asked
  for, and tells you how it went when it's over.
- "remind me in 20 minutes to …", "every morning at 7, …": Peter keeps the schedule, and tells
  you (or does it) when it's due.
