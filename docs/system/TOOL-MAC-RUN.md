# TOOL-MAC-RUN: the app's folder on your Desktop

Everything the app keeps for you (as opposed to your scripts, which live in the scripts folder you chose) is in one folder, **TOOL-MAC-RUN on the Desktop**, a folder for each shelf:

| Folder | What it is | Who changes it | Its board | Its API |
|---|---|---|---|---|
| `LIBRARY` | Your notes: Markdown files, each known by its name (groceries is `LIBRARY/groceries.md`) | You, and apps, without asking each time | Library (⌘7) | `/api/library` |
| `MEMORY` | What's remembered: a file for each kind of thing (PEOPLE, ORGANIZATIONS, EVENT-DATES, BIRTHDAYS, LOCATIONS, IDEAS, LEVERAGE, STRATEGIES, OTHERS), each a node of the mind | You, and apps, without asking each time | Memory (⌘8) | `/api/memory` |
| `MIND` | The mind: `mind.txt`, lines in the text mind-map notation that link what's known; `Archive` keeps old logs | Only ever added to (by you or apps) | Mind (⌘9) | `/api/mind` |
| `SYSTEM-DOCS` | How the app works, for you and for models: these docs | The app, each time it starts; nobody else | System Docs (⌘0) | `/api/system-docs` |

## What "by name" means

A file on a shelf is known by its name without `.md`: `PEOPLE` is `MEMORY/PEOPLE.md`, `START-HERE` is `SYSTEM-DOCS/START-HERE.md`. Case and accents don't matter when you ask for one (`people` finds `PEOPLE`).

## Deleting

Nothing on a shelf is deleted for good by accident. Deleting a note or a memory file moves it to that shelf's own `Trash` folder, numbered (`PEOPLE (1).md`), where Restore brings it back. Only **Empty the Trash** (which asks first) deletes for good.

The mind is never shrunk by deleting: forgetting a thing adds a line (`| name =`); the log keeps what was there. **Compact** rewrites the log in its shortest form and keeps the old one in `MIND/Archive`.

## Moving it

`TMR_HOME` (an environment variable) puts TOOL-MAC-RUN somewhere else; `TMR_LIBRARY`, `TMR_MEMORY`, `TMR_MIND` and `TMR_SYSTEM_DOCS` move one shelf each.

## The other things the app does for apps

- **Show something** to the person in a window in front of everything, with copy buttons: `POST /api/present` (PRESENT-AND-COPY).
- **Copy** to the clipboard: `POST /api/clipboard`, or `"copy": true` on any answer (PRESENT-AND-COPY).
- **See the page in Chrome** (its address, its text, where things are on it) to guide the person: `/api/browser` (BROWSER-GUIDE).
- **Run scripts and flows**, each after the person clicks Run: `/api/run`, `/api/compose` (API, AGENTS-GUIDE).
