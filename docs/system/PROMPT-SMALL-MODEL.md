# Prompt: a small model that only knows how to talk

For a model whose attention belongs to its task (help the person, write the email, plan the
trip), and a small one most of all. It doesn't carry tool schemas, load docs, keep request ids,
poll, or read JSON: it says what it wants to Tool Mac Tool Run and gets plain words back. If what
it said isn't something the app can do as is, the answer is a few templates to fill in and say
back.

## The instructions

This is all a model's instructions need:

```text
To use the Mac's tools, use say. Say what you want; if it offers templates, fill one in and say it back.
```

## The one tool

```json
{"name": "say",
 "description": "Talk to the Mac's tools in plain words. Say what you want; if it answers with templates, fill one in and say it back.",
 "input_schema": {"type": "object", "properties": {"text": {"type": "string", "description": "what you want, or a template filled in"}}, "required": ["text"]}}
```

The app beside the model passes each call to `POST /api/say` (the text as `text/plain`, and
`?client=<its name>`), or to `POST /api/tools/say {"arguments": {"text": "…"}}`, and hands the
answer back as is.

## The templates

- `{…}` is a blank to fill. The words inside say what goes there.
- `[a | b | c]` is a choice: one of them.
- `(optional)` after a label: the line may be left out.
- A form with lines: keep its title as the first line, then one `- label: value` line each, in any
  order. A value of several lines goes in a fenced block under its label.

```
Remember something
- category: EVENT-DATES
- about: Lagos trip
- fact: rain likely on the first afternoon, plan indoors
- date: 2026-10-25
```

## Always there

```
what can you do
what happened to {something you asked for}
what have I asked for [today | recently | since {a time}]
show me {something you asked for}
more
stop {something you asked for}
I'm done with {something you asked for}
start over
```

`{something you asked for}` is "the last one", a word from it ("the backup"), a time ("the one
around 3"), or a number from the last list ("the second one").

## An exchange

```
Model:  I need to know if it'll rain in Lagos tomorrow
Mac:    These can do that:
        1. Weather
             what's the weather in {a place}
        2. Search the web
             search the web for {what to look for}
        Fill one in and say it back.

Model:  what's the weather in Lagos
Mac:    This needs the person at the Mac to click Run. I'll tell you when they do.

Model:  what's coming up this week
Mac:    Meanwhile: The weather finished (it worked). Say "show me the weather" to see what it printed.

        Coming up in the next 7 days:
        1. 2026-10-25, tomorrow: lagos trip
```

## What the model should know

- A run (a script, a flow) waits for the person at the Mac to click Run. Say so to them; the
  model agreeing never stands in for that click.
- It never polls: what changed comes at the start of the next answer ("Meanwhile: …").
- A long answer ends with "say more for the rest".
- A question back ("Did you mean …? Say yes to go ahead, or no.") comes only when the match was
  uncertain and it would change something.
