# Showing and copying

Two things an app can do for the person besides answering: **show** them something, in a window that comes in front of everything (with copy buttons), and **copy** something to their clipboard. Neither asks first; both change nothing but what's on the screen and the clipboard. The panel's **Show and copy** switch turns them off.

## Showing: POST /api/present

```json
{"shelf": "memory", "name": "PEOPLE", "why": "So you can check Ada's details", "client": "My Assistant"}
{"mind": "ada lovelace"}
{"mind": ""}
{"title": "Your three steps", "text": "1. Open **Workers & Pages**\n2. …", "format": "markdown"}
{"title": "The answer", "text": "{\"ok\": true}", "format": "json"}
```

- A file from any shelf (`library`, `memory`, `system-docs`), by name.
- A node of the mind: all that's known about it, its lines in the notation, and its MEMORY file if it's one.
- The whole mind (`"mind": ""`), one line a fact, a copy button on each line.
- Any text: `markdown` (laid out: a copy button on the whole, on each section, on each piece of code), `text`, or `json` (pretty).
- `"copy": true` copies it too. `"why"` is shown under the title, in your words.

The window says what it is, where it's from, and who showed it. Things shown before are a click away (Shown Before).

## Copying: POST /api/clipboard

```json
{"text": "ssh me@example.com"}
{"shelf": "library", "name": "groceries"}
{"mind": "ada lovelace"}
```

The clipboard isn't read over the API.

## On any answer: "copy" and "present"

Every library, memory, system-docs, mind and browser call takes `"copy": true` (or `?copy=true`) and `"present": true`:

```
GET  /api/memory/files/PEOPLE?copy=true          the file's text, on the clipboard
POST /api/mind/query {"q": "| sam | x", "present": true}   the lines, in a window
GET  /api/browser/page?copy=true                 the page's text, on the clipboard
```

What's copied is the answer's text: a file's text, the lines found (a mind query, a search), the names, or else the JSON. The answer says `"copied": true` / `"presented": true` (or why not).
