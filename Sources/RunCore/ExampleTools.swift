import Foundation

/// The example utilities and browser scripts, and the flows that use them. They're scripts like
/// any other: only their folders (`utilities`, `browser`) put them on grids of their own.
extension Examples {
    /// Small reusable helpers: sounds, speech, the clipboard, and parsing JSON, CSV and addresses.
    public static let utilities: [(String, String)] = [
        ("utilities/play-sound.sh", #"""
        #!/bin/bash
        # Plays a sound: one of the Mac's own (Glass unless another is named), or a sound file
        #
        #   play-sound.sh                 the Glass sound
        #   play-sound.sh Ping            another of the Mac's sounds (play-sound.sh list names them all)
        #   play-sound.sh ~/Music/a.mp3   a sound file (mp3, m4a, wav, aiff…)
        set -euo pipefail

        sounds=/System/Library/Sounds
        what="${1:-Glass}"

        if ! command -v afplay >/dev/null 2>&1; then
          echo "Playing a sound needs afplay, which comes with macOS." >&2
          exit 1
        fi

        if [ "$what" = "list" ]; then
          for f in "$sounds"/*; do basename "${f%.*}"; done
          exit 0
        fi

        if [ -f "$what" ]; then
          file="$what"
        elif [ -f "$sounds/$what.aiff" ]; then
          file="$sounds/$what.aiff"
        else
          echo "There's no sound file $what, and no Mac sound called that." >&2
          echo "The Mac's sounds: $(for f in "$sounds"/*; do printf '%s ' "$(basename "${f%.*}")"; done)" >&2
          exit 1
        fi

        afplay "$file"
        echo "Played $(basename "$file")"
        """# + "\n"),
        ("utilities/play-song.sh", #"""
        #!/bin/bash
        # Plays a song in the Music app: the first whose name or artist matches, or carries on where it was
        #
        #   play-song.sh "Clair de Lune"   plays the first song in your library with that in its name (or artist)
        #   play-song.sh                   carries on playing (or starts)
        #   play-song.sh pause | next | previous | now
        set -euo pipefail

        if ! command -v osascript >/dev/null 2>&1; then
          echo "Playing a song needs macOS's Music app (and osascript)." >&2
          exit 1
        fi

        case "${1:-}" in
          "") osascript -e 'tell application "Music" to play' >/dev/null ;;
          pause) osascript -e 'tell application "Music" to pause' >/dev/null; echo "Paused"; exit 0 ;;
          next) osascript -e 'tell application "Music" to next track' >/dev/null ;;
          previous) osascript -e 'tell application "Music" to previous track' >/dev/null ;;
          now) ;;
          *)
            found=$(osascript - "$*" <<'APPLESCRIPT'
        on run argv
          set wanted to item 1 of argv
          tell application "Music"
            set hits to (every track of library playlist 1 whose name contains wanted)
            if hits is {} then set hits to (every track of library playlist 1 whose artist contains wanted)
            if hits is {} then return ""
            play item 1 of hits
            return "ok"
          end tell
        end run
        APPLESCRIPT
            )
            if [ -z "$found" ]; then
              echo "No song in your Music library has \"$*\" in its name or artist." >&2
              exit 1
            fi
            ;;
        esac

        sleep 0.3
        osascript <<'APPLESCRIPT'
        tell application "Music"
          if player state is stopped then return "Nothing is playing."
          set t to current track
          set verb to "Playing: "
          if player state is paused then set verb to "Paused: "
          return verb & (name of t) & " by " & (artist of t)
        end tell
        APPLESCRIPT
        """# + "\n"),
        ("utilities/speak.sh", #"""
        #!/bin/bash
        # Says text out loud in the Mac's voice: its arguments, or its input
        #
        #   speak.sh "The backup is done"
        #   echo "Hello" | speak.sh
        #   SPEAK_VOICE=Samantha speak.sh "Hi"    another voice (say -v '?' lists them)
        set -euo pipefail

        if [ $# -gt 0 ]; then
          text="$*"
        elif [ ! -t 0 ]; then
          text=$(cat)
        else
          text=""
        fi

        if [ -z "${text//[[:space:]]/}" ]; then
          echo "Nothing to say: give it words (speak.sh \"Hello\"), or text as its input." >&2
          exit 1
        fi

        if ! command -v say >/dev/null 2>&1; then
          echo "Speaking needs say, which comes with macOS." >&2
          exit 1
        fi

        if [ -n "${SPEAK_VOICE:-}" ]; then
          say -v "$SPEAK_VOICE" -- "$text"
        else
          say -- "$text"
        fi
        echo "Said: $text"
        """# + "\n"),
        ("utilities/clipboard.sh", #"""
        #!/bin/bash
        # The clipboard: prints what's on it, or puts its arguments (or its input) on it
        #
        #   clipboard.sh                 prints what's on the clipboard
        #   clipboard.sh some words      puts "some words" on it
        #   echo hi | clipboard.sh       puts its input on it
        set -euo pipefail

        if ! command -v pbcopy >/dev/null 2>&1; then
          echo "The clipboard needs pbcopy and pbpaste, which come with macOS." >&2
          exit 1
        fi

        if [ $# -gt 0 ]; then
          printf '%s' "$*" | pbcopy
          echo "Copied: $*"
          exit 0
        fi

        if [ ! -t 0 ]; then
          given=$(cat)
          if [ -n "$given" ]; then
            printf '%s' "$given" | pbcopy
            echo "Copied $(printf '%s' "$given" | wc -c | tr -d ' ') characters"
            exit 0
          fi
        fi

        pbpaste
        """# + "\n"),
        ("utilities/json-get.py", #"""
        #!/usr/bin/env python3
        # Picks a value out of JSON (its input, or a file): json-get.py 'items.0.name', with * for every item
        #
        #   echo '{"a": {"b": [1, 2]}}' | json-get.py a.b.1     -> 2
        #   json-get.py 'people.*.name' people.json              -> each name, one per line
        #   json-get.py < data.json                              -> the whole of it, laid out
        # Text comes out as it is; anything else as JSON.
        import json
        import sys


        def pick(value, parts):
            if not parts:
                return [value]
            key, rest = parts[0], parts[1:]
            if key == "*":
                items = value.values() if isinstance(value, dict) else value if isinstance(value, list) else []
                return [found for item in items for found in pick(item, rest)]
            if isinstance(value, list):
                try:
                    return pick(value[int(key)], rest)
                except (ValueError, IndexError):
                    return []
            if isinstance(value, dict) and key in value:
                return pick(value[key], rest)
            return []


        def show(value):
            return value if isinstance(value, str) else json.dumps(value, indent=2, ensure_ascii=False)


        path = sys.argv[1] if len(sys.argv) > 1 else ""
        source = open(sys.argv[2], encoding="utf-8") if len(sys.argv) > 2 else sys.stdin
        text = source.read()
        if not text.strip():
            sys.exit("No JSON came in: pipe some in, or name a file after the path.")
        try:
            data = json.loads(text)
        except json.JSONDecodeError as e:
            sys.exit(f"That isn't JSON: {e.msg} (line {e.lineno}, column {e.colno}).")

        found = pick(data, [p for p in path.split(".") if p != ""])
        if not found:
            sys.exit(f"Nothing at {path} in that JSON.")
        for value in found:
            print(show(value))
        """# + "\n"),
        ("utilities/csv-to-json.py", #"""
        #!/usr/bin/env python3
        # Turns CSV (its input, or a file) into JSON: a list with an object for each row, named by the header
        #
        #   csv-to-json.py people.csv
        #   cat people.csv | csv-to-json.py | json-get.py '*.email'
        # Tab-separated text works too (it's told from the first line).
        import csv
        import json
        import sys

        source = open(sys.argv[1], newline="", encoding="utf-8-sig") if len(sys.argv) > 1 else sys.stdin
        text = source.read()
        if not text.strip():
            sys.exit("No CSV came in: pipe some in, or name a file.")
        first = text.splitlines()[0]
        delimiter = "\t" if first.count("\t") > first.count(",") else ","
        rows = list(csv.DictReader(text.splitlines(), delimiter=delimiter))
        print(json.dumps(rows, indent=2, ensure_ascii=False))
        """# + "\n"),
        ("utilities/extract-urls.py", #"""
        #!/usr/bin/env python3
        # Every web address in its input (or the files named), each once, in the order they come
        #
        #   browser/page-links.sh | extract-urls.py
        #   extract-urls.py notes.txt mail.eml
        import re
        import sys

        text = "".join(open(p, encoding="utf-8", errors="replace").read() for p in sys.argv[1:]) if sys.argv[1:] else sys.stdin.read()
        seen = set()
        for match in re.finditer(r"https?://[^\s<>\"'`)\]}]+", text):
            url = match.group(0).rstrip(".,;:!?")
            if url not in seen:
                seen.add(url)
                print(url)
        """# + "\n"),
    ]

    /// Scripts that drive the default browser. `browser.sh` does the driving (Safari, Chrome and
    /// the browsers built like it, through AppleScript); the others are made of it.
    public static let browser: [(String, String)] = [
        ("browser/browser.sh", #"""
        #!/bin/bash
        # Drives your default browser: opens pages, reads them, runs JavaScript in them (the other browser scripts use it)
        #
        #   browser.sh                which browser is the default, and what it can do from here
        #   browser.sh open URL       opens URL in a new tab, waits for it to load, prints its title
        #   browser.sh url            the address of the page in front
        #   browser.sh title          its title
        #   browser.sh text           its text, as it reads on screen
        #   browser.sh tabs           every tab in the front window: its title, a tab, its address
        #   browser.sh js 'CODE'      runs JavaScript in the page in front, prints what it gives back:
        #                             an expression (document.title), or statements with a return;
        #                             what isn't text is printed as JSON
        #   browser.sh wait           waits (up to 30 seconds) for the page in front to finish loading
        #
        # The browser is your default one (System Settings > Desktop & Dock > Default web browser), or
        # the one TMR_BROWSER names (an app's name or bundle id: TMR_BROWSER=Safari).
        # Safari, Chrome, Edge, Brave, Arc, Vivaldi and Chromium can be driven; any other opens pages.
        set -uo pipefail

        if ! command -v osascript >/dev/null 2>&1; then
          echo "Driving the browser needs macOS (osascript)." >&2
          exit 1
        fi

        # The browser: its bundle id and its name.
        pick_browser() {
          osascript -l JavaScript - "${TMR_BROWSER:-}" <<'JXA'
        ObjC.import("AppKit")
        function run(argv) {
          const want = argv[0] || ""
          const ws = $.NSWorkspace.sharedWorkspace
          let url = null
          if (want.includes(".")) url = ws.URLForApplicationWithBundleIdentifier(want)
          else if (want) {
            const path = ws.fullPathForApplication(want)
            if (!path.isNil()) url = $.NSURL.fileURLWithPath(path)
          } else url = ws.URLForApplicationToOpenURL($.NSURL.URLWithString("https://example.com"))
          if (!url || url.isNil()) return ""
          const id = $.NSBundle.bundleWithURL(url).bundleIdentifier.js
          const name = $.NSFileManager.defaultManager.displayNameAtPath(url.path).js.replace(/\.app$/, "")
          return id + "\t" + name
        }
        JXA
        }

        found=$(pick_browser 2>/dev/null)
        if [ -z "$found" ]; then
          if [ -n "${TMR_BROWSER:-}" ]; then
            echo "There's no browser called ${TMR_BROWSER} on this Mac (TMR_BROWSER names it)." >&2
          else
            echo "Couldn't tell which browser is your default." >&2
          fi
          echo "Fix: pick one in System Settings > Desktop & Dock > Default web browser, or set TMR_BROWSER=Safari" >&2
          exit 1
        fi
        tab=$'\t'
        id="${found%%"$tab"*}"
        name="${found#*"$tab"}"

        case "$id" in
          com.apple.Safari|com.apple.SafariTechnologyPreview) family=safari ;;
          com.google.Chrome*|com.microsoft.edgemac*|com.brave.Browser*|company.thebrowser.Browser|com.vivaldi.Vivaldi|org.chromium.Chromium) family=chrome ;;
          *) family=other ;;
        esac

        # Runs AppleScript (from its input) with the browser's bundle id, then the words given, as argv.
        tell_browser() {
          osascript - "$id" "$@"
        }

        # What went wrong, in words, with the fix; then stops.
        explain() {
          local err="$1"
          case "$err" in
            *"Allow JavaScript from Apple Events"*|*"JavaScript through AppleScript is turned off"*)
              echo "${name} doesn't let scripts run JavaScript in its pages yet." >&2
              if [ "$family" = safari ]; then
                echo "Fix, once: Safari > Settings > Advanced > tick \"Show features for web developers\", then Develop > Allow JavaScript from Apple Events." >&2
              else
                echo "Fix, once: in ${name}, View > Developer > Allow JavaScript from Apple Events." >&2
              fi ;;
            *NO_WINDOW*)
              echo "${name} has no window open." >&2
              echo "Fix: open a page first (browser.sh open https://example.com)." >&2 ;;
            *-1743*|*"Not authorized"*|*"not allowed to send"*)
              echo "macOS hasn't let this app control ${name}." >&2
              echo "Fix: System Settings > Privacy & Security > Automation > Tool Mac Tool Run (or your terminal) > turn on ${name}." >&2 ;;
            *-1719*|*-1728*)
              echo "${name} has no page open to read." >&2
              echo "Fix: open a page first (browser.sh open https://example.com)." >&2 ;;
            *TMR_JS_ERROR*)
              echo "The page's JavaScript failed: ${err#*TMR_JS_ERROR }" >&2 ;;
            *)
              echo "${name} said: $err" >&2 ;;
          esac
          exit 1
        }

        # Runs AppleScript given as its input; prints what it gives back, or explains what went wrong.
        run_script() {
          local out
          if ! out=$(tell_browser "$@" 2>&1); then
            explain "$out"
          fi
          printf '%s\n' "$out"
        }

        need_driveable() {
          if [ "$family" = other ]; then
            echo "${name} (your default browser) opens pages, but scripts can't look inside them or drive it." >&2
            echo "Fix: use Safari or Chrome for this: TMR_BROWSER=Safari, or make one your default browser (System Settings > Desktop & Dock)." >&2
            exit 1
          fi
        }

        # The page in front: a property of its tab (url, title, text), without JavaScript.
        tab_property() {
          need_driveable
          if [ "$family" = safari ]; then
            run_script "$1" <<'APPLESCRIPT'
        on run argv
          tell application id (item 1 of argv)
            if (count of windows) = 0 then error "NO_WINDOW"
            set t to current tab of front window
            set what to item 2 of argv
            if what is "url" then return URL of t
            if what is "title" then return name of t
            return text of t
          end tell
        end run
        APPLESCRIPT
          else
            run_script "$1" <<'APPLESCRIPT'
        on run argv
          tell application id (item 1 of argv)
            if (count of windows) = 0 then error "NO_WINDOW"
            set t to active tab of front window
            set what to item 2 of argv
            if what is "url" then return URL of t
            return title of t
          end tell
        end run
        APPLESCRIPT
          fi
        }

        # JavaScript, run in the page in front.
        run_js() {
          need_driveable
          local code="$1" body
          # Trailing semicolons and spaces off, so an expression can be returned.
          code="${code%"${code##*[![:space:];]}"}"
          case "$code" in
            *return*) body="$code" ;;
            *) body="return (
        $code
        );" ;;
          esac
          local js="(() => { try { const r = (() => {
        $body
        })(); return r === undefined || r === null ? '' : typeof r === 'string' ? r : JSON.stringify(r, null, 2); } catch (e) { return 'TMR_JS_ERROR ' + e; } })()"
          local out
          if [ "$family" = safari ]; then
            out=$(run_script "$js" <<'APPLESCRIPT'
        on run argv
          tell application id (item 1 of argv)
            if (count of windows) = 0 then error "NO_WINDOW"
            return do JavaScript (item 2 of argv) in current tab of front window
          end tell
        end run
        APPLESCRIPT
            ) || exit 1
          else
            out=$(run_script "$js" <<'APPLESCRIPT'
        on run argv
          tell application id (item 1 of argv)
            if (count of windows) = 0 then error "NO_WINDOW"
            return execute active tab of front window javascript (item 2 of argv)
          end tell
        end run
        APPLESCRIPT
            ) || exit 1
          fi
          case "$out" in
            TMR_JS_ERROR*) explain "$out" ;;
          esac
          printf '%s\n' "$out"
        }

        # Waits for the page in front to load (up to 30 seconds).
        wait_loaded() {
          [ "$family" = other ] && { sleep 2; return 0; }
          local i state
          for i in $(seq 1 60); do
            if [ "$family" = chrome ]; then
              state=$(tell_browser 2>/dev/null <<'APPLESCRIPT'
        on run argv
          tell application id (item 1 of argv) to return loading of active tab of front window
        end run
        APPLESCRIPT
              ) || state=""
              [ "$state" = "false" ] && return 0
            else
              # Safari says when it's done through JavaScript; without it, a moment's wait will do.
              state=$(tell_browser 'document.readyState' 2>/dev/null <<'APPLESCRIPT'
        on run argv
          tell application id (item 1 of argv) to return do JavaScript (item 2 of argv) in current tab of front window
        end run
        APPLESCRIPT
              ) || { sleep 2; return 0; }
              [ "$state" = "complete" ] && return 0
            fi
            sleep 0.5
          done
          echo "The page is still loading after 30 seconds; going on anyway." >&2
        }

        open_page() {
          local url="$1"
          case "$url" in
            *://*|about:*) ;;
            *) url="https://$url" ;;
          esac
          if [ "$family" = other ]; then
            open -b "$id" "$url" || explain "couldn't open $url"
            echo "Opened $url in ${name}"
            return 0
          fi
          if [ "$family" = safari ]; then
            run_script "$url" >/dev/null <<'APPLESCRIPT'
        on run argv
          tell application id (item 1 of argv)
            activate
            if (count of windows) = 0 then
              make new document with properties {URL:(item 2 of argv)}
            else
              tell front window to set current tab to (make new tab with properties {URL:(item 2 of argv)})
            end if
          end tell
        end run
        APPLESCRIPT
          else
            run_script "$url" >/dev/null <<'APPLESCRIPT'
        on run argv
          tell application id (item 1 of argv)
            activate
            if (count of windows) = 0 then
              make new window
              set URL of active tab of front window to (item 2 of argv)
            else
              tell front window to make new tab with properties {URL:(item 2 of argv)}
            end if
          end tell
        end run
        APPLESCRIPT
          fi
          sleep 0.5
          wait_loaded
          tab_property title
        }

        list_tabs() {
          need_driveable
          if [ "$family" = safari ]; then
            run_script <<'APPLESCRIPT'
        on run argv
          tell application id (item 1 of argv)
            if (count of windows) = 0 then error "NO_WINDOW"
            set rows to {}
            repeat with t in tabs of front window
              set end of rows to (name of t) & tab & (URL of t)
            end repeat
          end tell
          set AppleScript's text item delimiters to linefeed
          return rows as text
        end run
        APPLESCRIPT
          else
            run_script <<'APPLESCRIPT'
        on run argv
          tell application id (item 1 of argv)
            if (count of windows) = 0 then error "NO_WINDOW"
            set rows to {}
            repeat with t in tabs of front window
              set end of rows to (title of t) & tab & (URL of t)
            end repeat
          end tell
          set AppleScript's text item delimiters to linefeed
          return rows as text
        end run
        APPLESCRIPT
          fi
        }

        which_browser() {
          echo "Your browser: ${name} (${id})"
          if [ "$family" = other ]; then
            echo "It can open pages (browser.sh open URL). Reading them or running JavaScript in them needs"
            echo "Safari or a Chrome-like browser: TMR_BROWSER=Safari, or make one your default browser."
            return 0
          fi
          echo "From here it can: open pages, give the address, title and text of the one in front, list its tabs,"
          echo "and run JavaScript in a page (browser.sh js 'document.title')."
          if [ "$family" = safari ]; then
            echo "Running JavaScript needs, once: Safari > Settings > Advanced > Show features for web developers,"
            echo "then Develop > Allow JavaScript from Apple Events."
          else
            echo "Running JavaScript needs, once: View > Developer > Allow JavaScript from Apple Events, in ${name}."
          fi
          echo "The first time, macOS asks whether this app may control ${name}: click Allow."
        }

        command="${1:-which}"
        [ $# -gt 0 ] && shift
        case "$command" in
          which) which_browser ;;
          open)
            if [ $# -eq 0 ]; then
              echo "Which page? browser.sh open https://example.com" >&2
              exit 1
            fi
            open_page "$1" ;;
          url|title) tab_property "$command" ;;
          text)
            if [ "$family" = safari ]; then tab_property text; else run_js 'document.body ? document.body.innerText : ""'; fi ;;
          tabs) list_tabs ;;
          js)
            if [ $# -eq 0 ]; then
              echo "Which JavaScript? browser.sh js 'document.title'" >&2
              exit 1
            fi
            run_js "$*" ;;
          wait) wait_loaded ;;
          *)
            echo "browser.sh doesn't know \"$command\"." >&2
            echo "It knows: which, open URL, url, title, text, tabs, js 'CODE', wait." >&2
            exit 1 ;;
        esac
        """# + "\n"),
        ("browser/open-page.sh", #"""
        #!/bin/bash
        # Opens a page in your browser (the address given, or example.com), waits for it to load, and prints its title
        set -euo pipefail

        browser="$(dirname "$0")/browser.sh"
        if [ ! -f "$browser" ]; then
          echo "This needs browser.sh beside it, in the browser folder (Add the Examples on the Browser grid puts it back)." >&2
          exit 1
        fi

        bash "$browser" open "${1:-https://example.com}"
        """# + "\n"),
        ("browser/page-info.sh", #"""
        #!/bin/bash
        # The page in front of your browser: its title, then its address
        set -euo pipefail

        browser="$(dirname "$0")/browser.sh"
        if [ ! -f "$browser" ]; then
          echo "This needs browser.sh beside it, in the browser folder (Add the Examples on the Browser grid puts it back)." >&2
          exit 1
        fi

        bash "$browser" title
        bash "$browser" url
        """# + "\n"),
        ("browser/page-text.sh", #"""
        #!/bin/bash
        # The text of the page in front of your browser, as it reads on screen
        set -euo pipefail

        browser="$(dirname "$0")/browser.sh"
        if [ ! -f "$browser" ]; then
          echo "This needs browser.sh beside it, in the browser folder (Add the Examples on the Browser grid puts it back)." >&2
          exit 1
        fi

        bash "$browser" text
        """# + "\n"),
        ("browser/page-links.sh", #"""
        #!/bin/bash
        # Every link on the page in front of your browser: its words, a tab, its address (one a line)
        set -euo pipefail

        browser="$(dirname "$0")/browser.sh"
        if [ ! -f "$browser" ]; then
          echo "This needs browser.sh beside it, in the browser folder (Add the Examples on the Browser grid puts it back)." >&2
          exit 1
        fi

        bash "$browser" js '[...document.querySelectorAll("a[href]")]
          .map(a => (a.innerText.trim().replace(/\s+/g, " ") || "(no words)") + "\t" + a.href)
          .join("\n")'
        """# + "\n"),
    ]

    /// Flows that use the utilities and the browser scripts: added once every script they run is
    /// in the folder.
    public static let toolFlows: [(String, String)] = [
        ("page-aloud.flow", #"""
        // Says the title of the page in front of your browser out loud, and copies its address
        let title = run "browser.sh" ["title"]
        let address = run "browser.sh" ["url"]

        run "speak" [$"You're looking at {title}"] |> ignore
        run "clipboard" [address] |> ignore
        print $"{title}: {address} (copied to the clipboard)"
        """# + "\n"),
        ("page-addresses.flow", #"""
        // Lists every address the page in front of your browser links to, then plays a sound
        let addresses = run "page-links" [] |> pipe "extract-urls" [] |> lines
        print $"{length addresses} addresses on the page:"
        addresses |> each print

        run "play-sound" ["Glass"] |> ignore
        """# + "\n"),
    ]

    /// Every example script, wherever it goes.
    public static var allScripts: [(String, String)] { scripts + utilities + browser }
}
