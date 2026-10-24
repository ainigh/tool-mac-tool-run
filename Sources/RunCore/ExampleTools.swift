import Foundation

/// The example utilities and browser scripts, and the flows that use them. They're scripts like
/// any other: only their folders (`utilities`, `browser`) put them on grids of their own.
extension Examples {
    /// Small reusable helpers: sounds, speech, the clipboard, parsing JSON, CSV and addresses, what's
    /// going on (the weather, the news, whether cloud services are up), the date and the time every
    /// way they're written, the apps (open one by name, quit one, which is in front), this Mac's
    /// volume, screen and notifications, and text (cases, encodings, hashes, ids, chance).
    public static let utilities: [(String, String)] = [
        ("utilities/play-sound.sh", #"""
        #!/bin/bash
        # Plays a sound: one of the Mac's own (Glass unless another is named), or a sound file
        #
        # Input (optional): A Mac sound or a sound file (Glass unless set)
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
        # Input (optional): A song or artist in your Music library (or pause, next, previous, now)
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
        # Input: What to say
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
        # Input (optional): Text to put on the clipboard (what's on it is shown unless set)
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
        # Input: Where the value is: a.b.0.c, with * for every item
        # Input text: The JSON
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
        # Input text: The CSV (or tab-separated text)
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
        # Input text: Text with web addresses in it
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
        ("utilities/weather.py", #"""
        #!/usr/bin/env python3
        # The weather now and for the next days: where this Mac is, or a place you name
        #
        # Input (optional): A place (where you are unless set)
        #
        #   weather.py                 where you are (told from your internet address)
        #   weather.py Paris           a place by name ("Paris, Texas" picks among the Parises)
        #   weather.py --days 5 Lagos  more days (1 to 16)
        # The first line is the weather now; then a line a day. From Open-Meteo (no account needed).
        # °F and mph in the United States, °C and km/h elsewhere: WEATHER_UNITS=metric or imperial picks.
        # WEATHER_PLACE sets the place used when none is named.
        import datetime
        import json
        import os
        import sys
        import time
        import urllib.error
        import urllib.parse
        import urllib.request

        SKY = {0: "clear", 1: "mostly clear", 2: "partly cloudy", 3: "overcast", 45: "fog", 48: "freezing fog",
               51: "light drizzle", 53: "drizzle", 55: "heavy drizzle", 56: "freezing drizzle", 57: "freezing drizzle",
               61: "light rain", 63: "rain", 65: "heavy rain", 66: "freezing rain", 67: "freezing rain",
               71: "light snow", 73: "snow", 75: "heavy snow", 77: "snow grains", 80: "showers", 81: "showers",
               82: "violent showers", 85: "snow showers", 86: "heavy snow showers", 95: "thunderstorms",
               96: "thunderstorms with hail", 99: "thunderstorms with heavy hail"}


        def fetch(url, tries=3, timeout=15):
            request = urllib.request.Request(url, headers={"User-Agent": "ToolMacToolRun weather"})
            for attempt in range(tries):
                try:
                    with urllib.request.urlopen(request, timeout=timeout) as response:
                        return json.load(response)
                except (urllib.error.URLError, TimeoutError):
                    # A slow or dropped connection: again, after a moment.
                    if attempt == tries - 1:
                        raise
                    time.sleep(1 + attempt)


        def here():
            """Where this Mac is, from its internet address: (name, latitude, longitude, country code).
            Two services, each asked once and quickly: the second if the first doesn't answer."""
            try:
                d = fetch("https://ipinfo.io/json", tries=1, timeout=8)
                lat, lon = d["loc"].split(",")
                name = ", ".join(p for p in [d.get("city"), d.get("region"), d.get("country")] if p)
                return name, float(lat), float(lon), d.get("country", "")
            except (urllib.error.URLError, TimeoutError, KeyError, ValueError):
                pass
            d = fetch("https://ipapi.co/json/", tries=1, timeout=8)
            name = ", ".join(p for p in [d.get("city"), d.get("region"), d.get("country_name")] if p)
            return name, d["latitude"], d["longitude"], d.get("country_code", "")


        def find(place):
            """A place by name; "Paris, Texas" keeps the Paris whose region or country says Texas."""
            name, _, near = place.partition(",")
            query = urllib.parse.urlencode({"name": name.strip(), "count": 20, "language": "en"})
            found = fetch("https://geocoding-api.open-meteo.com/v1/search?" + query).get("results") or []
            near = near.strip().lower()
            if near:
                found = [r for r in found if any(near in (r.get(k) or "").lower() for k in ("admin1", "admin2", "country", "country_code"))]
            if not found:
                sys.exit(f"There's no place called {place} that I can find. Try its name and its country: \"Paris, France\".")
            r = found[0]
            parts = [r["name"]] + [p for p in (r.get("admin1"), r.get("country")) if p and p != r["name"]]
            return ", ".join(parts), r["latitude"], r["longitude"], r.get("country_code", "")


        args = sys.argv[1:]
        days = 3
        if args[:1] == ["--days"]:
            if len(args) < 2 or not args[1].isdigit():
                sys.exit("--days takes a number: weather.py --days 5 Paris")
            days = max(1, min(16, int(args[1])))
            args = args[2:]
        place = " ".join(args).strip() or os.environ.get("WEATHER_PLACE", "").strip()

        try:
            label, lat, lon, country = find(place) if place else here()
        except urllib.error.URLError as e:
            sys.exit(f"Couldn't reach the weather service ({e.reason}). Is this Mac online?")

        units = os.environ.get("WEATHER_UNITS", "").lower() or ("imperial" if country.upper() in ("US", "LR", "MM") else "metric")
        imperial = units.startswith("imp")
        deg, speed = ("°F", "mph") if imperial else ("°C", "km/h")
        query = urllib.parse.urlencode({
            "latitude": lat, "longitude": lon, "timezone": "auto", "forecast_days": days,
            "current": "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m",
            "daily": "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max",
            "temperature_unit": "fahrenheit" if imperial else "celsius", "wind_speed_unit": "mph" if imperial else "kmh"})
        try:
            w = fetch("https://api.open-meteo.com/v1/forecast?" + query)
        except urllib.error.URLError as e:
            sys.exit(f"Couldn't reach the weather service ({e.reason}). Is this Mac online?")

        now = w["current"]
        print(f"{label}: {round(now['temperature_2m'])}{deg}, {SKY.get(now['weather_code'], 'unsettled')}"
              f" (feels like {round(now['apparent_temperature'])}{deg}), wind {round(now['wind_speed_10m'])} {speed},"
              f" humidity {now['relative_humidity_2m']}%")
        daily = w["daily"]
        for i, day in enumerate(daily["time"]):
            when = "Today" if i == 0 else "Tomorrow" if i == 1 else datetime.date.fromisoformat(day).strftime("%a %d")
            rain = daily["precipitation_probability_max"][i]
            print(f"{when}: {round(daily['temperature_2m_min'][i])}–{round(daily['temperature_2m_max'][i])}{deg},"
                  f" {SKY.get(daily['weather_code'][i], 'unsettled')}" + (f", {rain}% chance of rain" if rain is not None else ""))
        """# + "\n"),
        ("utilities/news.py", #"""
        #!/usr/bin/env python3
        # The latest headlines from Google News: the top stories, or about a topic you name
        #
        # Input (optional): A topic (the top stories unless set)
        #
        #   news.py                    the top stories
        #   news.py "electric cars"    about a topic
        #   news.py --critical         only what looks urgent (disasters, attacks, outages, emergencies…)
        #                              in the top, world and national stories of the last 12 hours (or about
        #                              a topic named), each line starting with 🚨
        #   news.py --count 5 --links  how many, and each one's address under it
        # A line a headline: the headline, its source, how long ago. The edition follows your Mac's
        # language (en_GB: the UK's); NEWS_EDITION=en-GB:GB picks one.
        import email.utils
        import os
        import re
        import sys
        import time
        import urllib.error
        import urllib.parse
        import urllib.request
        import xml.etree.ElementTree as ET

        # What makes a headline look urgent: harm, disaster, conflict, or something many people depend on failing.
        URGENT = re.compile(r"\b(emergency|evacuat\w*|earthquake|tsunami|hurricane (makes|made|hits|nears|batters|slams)|"
                            r"typhoon|cyclone|tornado(es)?|wildfires?|flash flood\w*|flooding|eruption|explosions?|blasts?|"
                            r"terror\w*|gunman|gunmen|mass shooting|shooting at|shot dead|hostages?|missiles?|airstrikes?|"
                            r"drone strikes?|invasion|invades?|killed|kills|dead after|death toll|casualties|plane crash|"
                            r"train crash|derail\w*|collapse[sd]? (kills|traps)|outages?|blackouts?|cyberattack|ransomware|"
                            r"data breach|outbreak|pandemic|lockdown|martial law|coup|state of emergency|attacks? on|"
                            r"under attack)\b", re.IGNORECASE)


        def edition():
            chosen = os.environ.get("NEWS_EDITION", "")
            if ":" in chosen:
                hl, gl = chosen.split(":", 1)
                return hl, gl
            lang = (os.environ.get("LANG") or "en_US").split(".")[0]
            language, _, country = lang.partition("_")
            if not country or not language.isalpha():
                language, country = "en", "US"
            return f"{language}-{country}", country


        def feed(url):
            request = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 ToolMacToolRun news"})
            for attempt in range(3):
                try:
                    with urllib.request.urlopen(request, timeout=15) as response:
                        root = ET.fromstring(response.read())
                    break
                except urllib.error.HTTPError as e:
                    # Google News turns a quick run of requests away for a moment: wait, then once more.
                    if e.code not in (429, 503) or attempt == 2:
                        raise
                    time.sleep(2 * (attempt + 1))
            items = []
            for item in root.iter("item"):
                title = item.findtext("title", "")
                source = item.findtext("source", "")
                if source and title.endswith(" - " + source):
                    title = title[: -len(source) - 3]
                published = item.findtext("pubDate")
                when = email.utils.parsedate_to_datetime(published).timestamp() if published else None
                items.append({"title": title.strip(), "source": source, "when": when, "link": item.findtext("link", "")})
            return items


        def ago(when):
            if when is None:
                return ""
            minutes = max(0, int((time.time() - when) / 60))
            if minutes < 60:
                return f"{minutes} min ago"
            if minutes < 48 * 60:
                return f"{minutes // 60} h ago"
            return f"{minutes // (24 * 60)} days ago"


        args = sys.argv[1:]
        critical = "--critical" in args
        links = "--links" in args
        count = 10
        if "--count" in args:
            i = args.index("--count")
            if i + 1 >= len(args) or not args[i + 1].isdigit():
                sys.exit("--count takes a number: news.py --count 5")
            count = int(args[i + 1])
            del args[i:i + 2]
        topic = " ".join(a for a in args if a not in ("--critical", "--links")).strip()

        hl, gl = edition()
        tail = urllib.parse.urlencode({"hl": hl, "gl": gl, "ceid": f"{gl}:{hl.split('-')[0]}"})
        search = "https://news.google.com/rss/search?" + tail + "&q="
        try:
            if critical:
                hours = 12
                if topic:
                    stories = feed(search + urllib.parse.quote_plus(f"{topic} when:{hours}h"))
                else:
                    # Google's own picks: the top stories, the world's and the country's.
                    stories = feed(f"https://news.google.com/rss?{tail}")
                    for section in ("WORLD", "NATION"):
                        stories += feed(f"https://news.google.com/rss/headlines/section/topic/{section}?{tail}")
                cutoff = time.time() - hours * 3600
                stories = [s for s in stories if (s["when"] or 0) >= cutoff and URGENT.search(s["title"])]
            elif topic:
                stories = feed(search + urllib.parse.quote_plus(topic))
            else:
                stories = feed(f"https://news.google.com/rss?{tail}")
        except urllib.error.URLError as e:
            sys.exit(f"Couldn't reach Google News ({e.reason}). Is this Mac online?")
        except ET.ParseError:
            sys.exit("Google News sent something that isn't a news feed; try again in a minute.")

        seen, shown = set(), []
        for s in sorted(stories, key=lambda s: -(s["when"] or 0)) if critical else stories:
            key = s["title"].lower()
            if key in seen:
                continue
            seen.add(key)
            shown.append(s)
            if len(shown) == count:
                break

        if not shown:
            print("Nothing urgent in the news in the last 12 hours." if critical else f"No news found about {topic}.")
        for s in shown:
            detail = " · ".join(p for p in [s["source"], ago(s["when"])] if p)
            print(("🚨 " if critical else "") + s["title"] + (f" — {detail}" if detail else ""))
            if links:
                print("   " + s["link"])
        """# + "\n"),
        ("utilities/cloud-status.py", #"""
        #!/usr/bin/env python3
        # Whether the cloud services you rely on are up: AWS, Google Cloud, Azure, GitHub, Cloudflare, OpenAI, Claude, Slack…
        #
        # Input (optional): Which services, with spaces between them (all of them unless set)
        #
        #   cloud-status.py              every service below, from its own status page
        #   cloud-status.py github aws   just these
        #   cloud-status.py --problems   only the ones with a problem (or one line saying all are up)
        #   cloud-status.py --list       the services it knows
        # A line a service, starting with ✅ up, ⚠️ a problem, 🔴 an outage, or ❓ its status page
        # couldn't be reached. Add a service with a status page made by Statuspage (most are) to
        # STATUSPAGE below.
        import concurrent.futures
        import datetime
        import json
        import sys
        import urllib.error
        import urllib.request

        # Status pages made by Atlassian Statuspage: name, address.
        STATUSPAGE = [
            ("GitHub", "https://www.githubstatus.com"),
            ("Cloudflare", "https://www.cloudflarestatus.com"),
            ("OpenAI", "https://status.openai.com"),
            ("Claude", "https://status.anthropic.com"),
            ("Discord", "https://discordstatus.com"),
            ("Dropbox", "https://status.dropbox.com"),
            ("Zoom", "https://status.zoom.us"),
            ("Atlassian", "https://status.atlassian.com"),
            ("Vercel", "https://www.vercel-status.com"),
            ("Netlify", "https://www.netlifystatus.com"),
            ("DigitalOcean", "https://status.digitalocean.com"),
            ("npm", "https://status.npmjs.org"),
            ("Twilio", "https://status.twilio.com"),
            ("Reddit", "https://www.redditstatus.com"),
        ]


        def fetch(url):
            request = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 ToolMacToolRun cloud-status"})
            with urllib.request.urlopen(request, timeout=15) as response:
                return response.read()


        def as_json(data):
            # AWS sends UTF-16 (with its byte-order mark); the rest UTF-8.
            text = data.decode("utf-16") if data[:2] in (b"\xff\xfe", b"\xfe\xff") else data.decode("utf-8-sig")
            return json.loads(text)


        def statuspage(url):
            d = as_json(fetch(url + "/api/v2/summary.json"))
            indicator = d["status"]["indicator"]
            incidents = [i["name"] for i in d.get("incidents", [])]
            level = {"none": "up", "minor": "problem", "maintenance": "up"}.get(indicator, "outage")
            if level == "up" and incidents:
                level = "problem"
            return level, d["status"]["description"], incidents


        def google(url):
            open_ones = [i for i in as_json(fetch(url)) if not i.get("end")]
            if not open_ones:
                return "up", "No open incidents", []
            worst = "outage" if any(i.get("severity") == "high" for i in open_ones) else "problem"
            return worst, f"{len(open_ones)} open incident{'s' if len(open_ones) > 1 else ''}", [
                (i.get("service_name", "") + ": " + i.get("external_desc", "").replace("**", "").split("\n")[-1]).strip()[:140]
                for i in open_ones]


        def aws():
            events = as_json(fetch("https://health.aws.amazon.com/public/currentevents"))
            if not events:
                return "up", "No current events", []
            names = []
            for e in events:
                since = datetime.datetime.fromtimestamp(int(e.get("date", 0))).strftime("%b %d")
                names.append(f"{e.get('service_name', 'AWS')} in {e.get('region_name', 'a region')}: {e.get('summary', '')} (since {since})")
            return "problem", f"{len(events)} current event{'s' if len(events) > 1 else ''}", names


        def azure():
            import xml.etree.ElementTree as ET
            items = ET.fromstring(fetch("https://azure.status.microsoft/en-us/status/feed/")).iter("item")
            titles = [i.findtext("title", "").strip() for i in items]
            return ("problem", f"{len(titles)} active issue{'s' if len(titles) > 1 else ''}", titles) if titles else ("up", "No active issues", [])


        def slack():
            d = as_json(fetch("https://slack-status.com/api/v2.0.0/current"))
            incidents = [i.get("title", "") for i in d.get("active_incidents", [])]
            if d.get("status") == "ok" and not incidents:
                return "up", "All systems go", []
            return "problem", "Active incidents", incidents


        def apple():
            text = fetch("https://www.apple.com/support/systemstatus/data/system_status_en_US.js").decode("utf-8")
            d = json.loads(text[text.index("{"): text.rindex("}") + 1])
            issues = [f"{s['serviceName']}: {e.get('message') or e.get('statusType', 'issue')}"[:140]
                      for s in d.get("services", []) for e in s.get("events", [])
                      if e.get("eventStatus", "").lower() not in ("resolved", "completed") and not e.get("epochEndDate")]
            return ("problem", f"{len(issues)} service{'s' if len(issues) > 1 else ''} with issues", issues) if issues else ("up", "All services available", [])


        SERVICES = [("AWS", aws), ("Google Cloud", lambda: google("https://status.cloud.google.com/incidents.json")),
                    ("Azure", azure),
                    ("Google Workspace", lambda: google("https://www.google.com/appsstatus/dashboard/incidents.json")),
                    ("Apple", apple), ("Slack", slack)] + [(name, (lambda u: lambda: statuspage(u))(url)) for name, url in STATUSPAGE]

        MARK = {"up": "✅", "problem": "⚠️", "outage": "🔴", "unknown": "❓"}


        def check(service):
            name, how = service
            try:
                level, words, incidents = how()
            except (urllib.error.URLError, TimeoutError, OSError) as e:
                return name, "unknown", f"couldn't reach its status page ({getattr(e, 'reason', e)})", []
            except (ValueError, KeyError) as e:
                return name, "unknown", f"its status page answered in a way I can't read ({e})", []
            return name, level, words, incidents


        args = [a for a in sys.argv[1:]]
        if "--list" in args:
            print("\n".join(name for name, _ in SERVICES))
            sys.exit(0)
        problems_only = "--problems" in args
        wanted = [w.lower() for a in args if not a.startswith("--") for w in a.split()]
        chosen = [s for s in SERVICES if not wanted or any(w in s[0].lower().replace(" ", "") for w in wanted)]
        if not chosen:
            sys.exit(f"I don't know {' '.join(wanted)}. The services: {', '.join(n for n, _ in SERVICES)}")

        with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
            results = list(pool.map(check, chosen))

        if all(r[1] == "unknown" for r in results):
            sys.exit("Couldn't reach any status page. Is this Mac online?")
        shown = [r for r in results if r[1] != "up"] if problems_only else results
        if problems_only and not shown:
            print(f"✅ All {len(results)} services are up.")
        for name, level, words, incidents in shown:
            print(f"{MARK[level]} {name}: {words}" + (f" — {incidents[0]}" if incidents else "")
                  + (f" (and {len(incidents) - 1} more)" if len(incidents) > 1 else ""))
        """# + "\n"),
        ("utilities/wikipedia.py", #"""
        #!/usr/bin/env python3
        # What Wikipedia says about a topic, in a paragraph, with its address
        #
        # Input: A topic (Eiffel Tower, photosynthesis, Ada Lovelace…)
        #
        #   wikipedia.py Eiffel Tower
        #   WIKIPEDIA_LANGUAGE=fr wikipedia.py Tour Eiffel
        import json
        import os
        import sys
        import time
        import urllib.error
        import urllib.parse
        import urllib.request

        language = os.environ.get("WIKIPEDIA_LANGUAGE", "en")
        topic = " ".join(sys.argv[1:]).strip()
        if not topic:
            sys.exit("What should Wikipedia be asked about? (wikipedia.py Eiffel Tower)")


        def fetch(url):
            request = urllib.request.Request(url, headers={"User-Agent": "ToolMacToolRun/1 (wikipedia example)"})
            for attempt in range(2):
                try:
                    with urllib.request.urlopen(request, timeout=15) as response:
                        return json.load(response)
                except urllib.error.HTTPError as e:
                    # Asked too often: wait as long as it says (a few seconds at most), then once more.
                    if e.code != 429 or attempt == 1:
                        raise
                    time.sleep(min(5, int(e.headers.get("Retry-After") or 2)))


        base = f"https://{language}.wikipedia.org"
        try:
            # The page whose title is closest to the topic, then its summary.
            found = fetch(f"{base}/w/api.php?" + urllib.parse.urlencode(
                {"action": "opensearch", "search": topic, "limit": 1, "namespace": 0, "format": "json"}))
            if not found[1]:
                sys.exit(f"Wikipedia has no page about {topic}.")
            page = fetch(f"{base}/api/rest_v1/page/summary/" + urllib.parse.quote(found[1][0].replace(" ", "_")))
        except urllib.error.HTTPError as e:
            sys.exit(f"Wikipedia turned the question away ({e.code} {e.reason}). Try again in a minute.")
        except urllib.error.URLError as e:
            sys.exit(f"Couldn't reach Wikipedia ({e.reason}). Is this Mac online?")

        print(page.get("title", topic) + (f" — {page['description']}" if page.get("description") else ""))
        print()
        print(page.get("extract", "").strip())
        print()
        print(page.get("content_urls", {}).get("desktop", {}).get("page", ""))
        """# + "\n"),
        ("utilities/define.py", #"""
        #!/usr/bin/env python3
        # What a word means: its definitions, how it's said, and an example of it in use
        #
        # Input: A word (in English)
        #
        #   define.py serendipity
        import json
        import sys
        import urllib.error
        import urllib.parse
        import urllib.request

        word = " ".join(sys.argv[1:]).strip()
        if not word:
            sys.exit("Which word? (define.py serendipity)")
        url = "https://api.dictionaryapi.dev/api/v2/entries/en/" + urllib.parse.quote(word)
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "ToolMacToolRun"}), timeout=15) as r:
                entries = json.load(r)
        except urllib.error.HTTPError as e:
            if e.code == 404:
                sys.exit(f"No definition found for \"{word}\". Check its spelling, or try google.sh define {word}.")
            raise
        except urllib.error.URLError as e:
            sys.exit(f"Couldn't reach the dictionary ({e.reason}). Is this Mac online?")

        entry = entries[0]
        said = entry.get("phonetic") or next((p.get("text") for p in entry.get("phonetics", []) if p.get("text")), "")
        print(entry["word"] + (f"  {said}" if said else ""))
        shown = 0
        for meaning in entry.get("meanings", []):
            for d in meaning.get("definitions", [])[:2]:
                shown += 1
                print(f"{shown}. ({meaning.get('partOfSpeech', '')}) {d['definition']}")
                if d.get("example"):
                    print(f"   “{d['example']}”")
            if shown >= 5:
                break
        """# + "\n"),
        ("utilities/currency.py", #"""
        #!/usr/bin/env python3
        # Converts money between currencies at today's rate: 100 USD to EUR
        #
        # Input: An amount and two currencies (100 USD to EUR)
        #
        #   currency.py 100 USD EUR
        #   currency.py "250 gbp to jpy"
        # Rates from open.er-api.com (updated daily, no account needed).
        import json
        import re
        import sys
        import urllib.error
        import urllib.request

        words = re.findall(r"[A-Za-z]{3}|[\d.,]+", " ".join(sys.argv[1:]).replace(" to ", " ").replace(" in ", " "))
        amounts = [w for w in words if re.fullmatch(r"[\d.,]+", w)]
        codes = [w.upper() for w in words if re.fullmatch(r"[A-Za-z]{3}", w)]
        if len(codes) < 2:
            sys.exit("Give an amount and two currencies: currency.py 100 USD EUR")
        amount = float(amounts[0].replace(",", "")) if amounts else 1.0
        source, target = codes[0], codes[1]
        try:
            with urllib.request.urlopen(f"https://open.er-api.com/v6/latest/{source}", timeout=15) as r:
                data = json.load(r)
        except urllib.error.URLError as e:
            sys.exit(f"Couldn't reach the exchange rates ({e.reason}). Is this Mac online?")
        if data.get("result") != "success":
            sys.exit(f"{source} isn't a currency I know (three letters, such as USD, EUR, GBP, JPY).")
        rate = data["rates"].get(target)
        if rate is None:
            sys.exit(f"{target} isn't a currency I know (three letters, such as USD, EUR, GBP, JPY).")
        print(f"{amount:,.2f} {source} = {amount * rate:,.2f} {target}")
        print(f"1 {source} = {rate:.4f} {target} (rates of {data.get('time_last_update_utc', 'today')[:16]})")
        """# + "\n"),
        ("utilities/world-clock.py", #"""
        #!/usr/bin/env python3
        # The time now in other places: the cities you name, or a few around the world
        #
        # Input (optional): Places (London, Tokyo, New York…), with commas between them
        #
        #   world-clock.py
        #   world-clock.py "Lagos, Sydney, Los Angeles"
        # A place is found among the world's time zones, else by name (Open-Meteo's place search).
        import datetime
        import json
        import sys
        import urllib.parse
        import urllib.request
        import zoneinfo

        DEFAULT = ["Los Angeles", "New York", "London", "Paris", "Lagos", "Dubai", "India", "Tokyo", "Sydney"]
        ALIASES = {"india": "Asia/Kolkata", "uk": "Europe/London", "china": "Asia/Shanghai", "japan": "Asia/Tokyo",
                   "utc": "UTC", "gmt": "UTC", "san francisco": "America/Los_Angeles", "washington": "America/New_York"}

        given = ",".join(sys.argv[1:])
        places = [p.strip() for p in given.split(",") if p.strip()] or DEFAULT
        zones = {z.split("/")[-1].replace("_", " ").lower(): z for z in zoneinfo.available_timezones() if "/" in z}


        def find(place):
            key = place.lower()
            if key in ALIASES:
                return ALIASES[key]
            if key in zones:
                return zones[key]
            query = urllib.parse.urlencode({"name": place.split(",")[0], "count": 1, "language": "en"})
            try:
                with urllib.request.urlopen("https://geocoding-api.open-meteo.com/v1/search?" + query, timeout=10) as r:
                    found = json.load(r).get("results") or []
            except OSError:
                return None
            return found[0].get("timezone") if found else None


        here = datetime.datetime.now().astimezone()
        width = max(len(p) for p in places)
        for place in places:
            zone = find(place)
            if not zone:
                print(f"{place.ljust(width)}  (no place called that)")
                continue
            there = datetime.datetime.now(zoneinfo.ZoneInfo(zone))
            hours = (there.utcoffset() - here.utcoffset()).total_seconds() / 3600
            diff = "same time as here" if hours == 0 else f"{'+' if hours > 0 else ''}{hours:g} h"
            day = "" if there.date() == here.date() else (" tomorrow" if there.date() > here.date() else " yesterday")
            print(f"{place.ljust(width)}  {there.strftime('%H:%M')}{day}  {there.strftime('%a %d %b')}  ({diff})")
        """# + "\n"),
        ("utilities/site-check.py", #"""
        #!/usr/bin/env python3
        # Whether websites are up: each one's answer, how fast it came, and how long its certificate lasts
        #
        # Input: Websites, with spaces between them (example.com github.com)
        #
        #   site-check.py example.com https://github.com
        # A line each, starting with ✅ up, ⚠️ up but slow (over 2 s), answering with an error (4xx) or its
        # certificate ending within 14 days, or 🔴 down (no answer, or a server error, 5xx).
        import concurrent.futures
        import datetime
        import socket
        import ssl
        import sys
        import time
        import urllib.error
        import urllib.parse
        import urllib.request

        sites = [w for a in sys.argv[1:] for w in a.replace(",", " ").split()]
        if not sites:
            sys.exit("Which websites? (site-check.py example.com github.com)")


        def certificate_days(host):
            try:
                with socket.create_connection((host, 443), timeout=10) as sock:
                    with ssl.create_default_context().wrap_socket(sock, server_hostname=host) as tls:
                        ends = datetime.datetime.strptime(tls.getpeercert()["notAfter"], "%b %d %H:%M:%S %Y %Z")
                return (ends.replace(tzinfo=datetime.timezone.utc) - datetime.datetime.now(datetime.timezone.utc)).days
            except (OSError, ssl.SSLError, KeyError, ValueError):
                return None


        def check(site):
            url = site if "://" in site else "https://" + site
            host = urllib.parse.urlparse(url).hostname or site
            started = time.time()
            try:
                request = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 ToolMacToolRun site-check"})
                with urllib.request.urlopen(request, timeout=15) as r:
                    code = r.status
            except urllib.error.HTTPError as e:
                code = e.code
            except (urllib.error.URLError, OSError) as e:
                return f"🔴 {host}: down ({getattr(e, 'reason', e)})"
            seconds = time.time() - started
            days = certificate_days(host) if url.startswith("https") else None
            worry = code >= 400 or seconds > 2 or (days is not None and days < 14)
            mark = "🔴" if code >= 500 else "⚠️" if worry else "✅"
            cert = f", certificate {days} days left" if days is not None else ""
            return f"{mark} {host}: {code} in {seconds:.1f} s{cert}"


        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            for line in pool.map(check, sites):
                print(line)
        """# + "\n"),
        ("utilities/public-ip.py", #"""
        #!/usr/bin/env python3
        # This Mac's address on the internet, and where and who that looks like (city, country, provider)
        import json
        import sys
        import urllib.error
        import urllib.request

        try:
            with urllib.request.urlopen(urllib.request.Request("https://ipinfo.io/json", headers={"User-Agent": "ToolMacToolRun"}), timeout=15) as r:
                d = json.load(r)
        except urllib.error.URLError as e:
            sys.exit(f"Couldn't reach ipinfo.io ({e.reason}). Is this Mac online?")
        where = ", ".join(p for p in [d.get("city"), d.get("region"), d.get("country")] if p)
        print(d.get("ip", "?"))
        print(f"{where} · {d.get('org', 'unknown provider')}")
        """# + "\n"),
        ("utilities/password.py", #"""
        #!/usr/bin/env python3
        # A strong new password: letters, digits and symbols, 20 long unless another length is given
        #
        # Input (optional): How long (20 unless set)
        import secrets
        import string
        import sys

        length = int(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1].isdigit() else 20
        length = max(8, min(128, length))
        pool = string.ascii_letters + string.digits + "!#$%&*+-=?@^_"
        while True:
            word = "".join(secrets.choice(pool) for _ in range(length))
            if any(c.isdigit() for c in word) and any(c.isupper() for c in word) and any(not c.isalnum() for c in word):
                break
        print(word)
        """# + "\n"),
        ("utilities/battery.sh", #"""
        #!/bin/bash
        # The battery: how full it is, whether it's charging, and how long it has left
        set -euo pipefail

        if ! command -v pmset >/dev/null 2>&1; then
          echo "The battery needs pmset, which comes with macOS." >&2
          exit 1
        fi
        line=$(pmset -g batt | grep -E '[0-9]+%' || true)
        if [ -z "$line" ]; then
          echo "This Mac has no battery (it runs on power)."
          exit 0
        fi
        percent=$(printf '%s' "$line" | grep -oE '[0-9]+%' | head -n 1)
        state=$(printf '%s' "$line" | awk -F'; ' '{print $2}')
        left=$(printf '%s' "$line" | grep -oE '[0-9]+:[0-9]+ remaining' || true)
        source=$(pmset -g batt | head -n 1 | grep -q "AC Power" && echo "on power" || echo "on battery")
        echo "${percent} · ${state} · ${source}${left:+ · ${left}}"
        """# + "\n"),
        ("utilities/system-info.sh", #"""
        #!/bin/bash
        # This Mac at a glance: macOS, how long it's been on, how busy it is, memory, disk, and its network
        set -uo pipefail

        if [ "$(uname)" != "Darwin" ]; then
          echo "This tells about a Mac; this computer is $(uname)." >&2
          exit 1
        fi
        echo "macOS $(sw_vers -productVersion) on $(sysctl -n hw.model), $(sysctl -n hw.ncpu) cores"
        echo "On for $(uptime | sed -E 's/.*up ([^,]*(, [0-9]+:[0-9]+)?).*/\1/')"
        echo "Busy: $(sysctl -n vm.loadavg | awk '{print $2", "$3", "$4}') (load over 1, 5 and 15 minutes)"
        pages_free=$(vm_stat | awk '/Pages free/ {gsub(/\./, "", $3); print $3}')
        page_size=$(sysctl -n hw.pagesize)
        total=$(sysctl -n hw.memsize)
        echo "Memory: $((total / 1073741824)) GB, $((pages_free * page_size / 1048576)) MB free right now"
        echo "Disk: $(df -h / | awk 'NR==2 {print $4 " free of " $2 " (" $5 " used)"}')"
        wifi=$(networksetup -listallhardwareports 2>/dev/null | awk '/Wi-Fi|AirPort/ {getline; print $2; exit}')
        network=""
        [ -n "$wifi" ] && network=$(networksetup -getairportnetwork "$wifi" 2>/dev/null | sed -n 's/^Current Wi-Fi Network: //p')
        address=$(ipconfig getifaddr "${wifi:-en0}" 2>/dev/null || true)
        echo "Network: ${network:-not on Wi-Fi}${address:+ · ${address} on this network}"
        """# + "\n"),
        ("utilities/timer.sh", #"""
        #!/bin/bash
        # Waits, then plays a sound and says so out loud: a timer (5 minutes unless another time is given)
        #
        # Input (optional): How many minutes (5 unless set)
        # Input (optional): What to say when it's up (Time's up)
        set -euo pipefail

        minutes="${1:-5}"
        said="Time's up"
        message="${2:-$said}"
        case "$minutes" in
          ''|*[!0-9.]*) echo "How many minutes? A number, such as 25 (timer.sh 25 \"Time for a break\")." >&2; exit 1 ;;
        esac
        here="$(dirname "$0")"
        seconds=$(awk -v m="$minutes" 'BEGIN { printf "%d", m * 60 }')
        echo "Timer: ${minutes} min, until $(date -v+"${seconds}"S '+%H:%M' 2>/dev/null || date -d "+${seconds} seconds" '+%H:%M')."
        sleep "$seconds"
        # The other utilities do the telling: a sound, then the words.
        bash "$here/play-sound.sh" Glass >/dev/null 2>&1 || true
        bash "$here/speak.sh" "$message" >/dev/null 2>&1 || true
        echo "$message"
        """# + "\n"),
        ("utilities/copy-to-clipboard.sh", #"""
        #!/bin/bash
        # Puts text on the clipboard, ready to paste (its arguments, or its input), and says what it copied
        #
        # Input: The text to copy
        # Why: It goes on the clipboard exactly as typed, replacing whatever was there
        #
        #   copy-to-clipboard.sh some words      puts "some words" on the clipboard
        #   echo hi | copy-to-clipboard.sh       puts its input on it (a flow: pipe "copy-to-clipboard" [])
        #   copy-to-clipboard.sh < notes.txt     a whole file
        set -euo pipefail

        if ! command -v pbcopy >/dev/null 2>&1; then
          echo "The clipboard needs pbcopy, which comes with macOS." >&2
          exit 1
        fi

        text=""
        if [ $# -gt 0 ]; then
          text="$*"
        elif [ ! -t 0 ]; then
          text=$(cat)
        fi
        if [ -z "$text" ]; then
          echo "Nothing to copy. Give it the text (copy-to-clipboard.sh some words), or pipe some in (echo hi | copy-to-clipboard.sh)." >&2
          exit 1
        fi

        printf '%s' "$text" | pbcopy
        chars=$(printf '%s' "$text" | wc -m | tr -d ' ')
        lines=$(printf '%s\n' "$text" | wc -l | tr -d ' ')
        first=$(printf '%s' "$text" | head -n 1 | cut -c 1-60)
        if [ "$lines" -gt 1 ]; then
          echo "Copied to the clipboard: $lines lines, $chars characters, starting \"$first\"…"
        elif [ "$chars" -gt 60 ]; then
          echo "Copied to the clipboard: $chars characters, starting \"$first\"…"
        else
          echo "Copied to the clipboard: $text"
        fi
        """# + "\n"),
        ("utilities/alarm.sh", #"""
        #!/bin/bash
        # Sets an alarm for later: when it's time, a sound, the words said out loud and a notification
        #
        # Input: When: a length from now (20 minutes, 1.5 hours, 90 seconds) or a time of day (16:30, 7am)
        # Why: A helper keeps waiting after this run ends, and rings on this Mac at that time (the Clock app can't be set from a script)
        # Input (optional): What it says when it rings (Alarm unless set)
        #
        #   alarm.sh "20 minutes" "Stand up"    rings in 20 minutes, saying "Stand up"
        #   alarm.sh 20 minutes                  the same, the time as two words
        #   alarm.sh 16:30 "Call Sam"            rings at 16:30 (tomorrow's, when today's has passed)
        #   alarm.sh list                        the alarms set and still waiting
        #   alarm.sh cancel                      cancels every alarm still waiting
        set -euo pipefail

        alarms="${TMPDIR:-/tmp}/toolmactoolrun-alarms"
        here="$(dirname "$0")"

        # The ringing, in the helper that waited (started below, in a session of its own so it
        # outlives this run): a sound three times, the words, a notification.
        if [ "${1:-}" = "--ring" ]; then
          target="$2"
          message="$3"
          while [ "$(date +%s)" -lt "$target" ]; do sleep 15; done
          rm "$alarms/$$" 2>/dev/null || true
          for _ in 1 2 3; do bash "$here/play-sound.sh" Glass >/dev/null 2>&1 || afplay /System/Library/Sounds/Glass.aiff 2>/dev/null || true; done
          ALARM_MESSAGE="$message" osascript -e 'display notification (system attribute "ALARM_MESSAGE") with title "Alarm" sound name "Glass"' >/dev/null 2>&1 || true
          bash "$here/speak.sh" "$message" >/dev/null 2>&1 || say -- "$message" 2>/dev/null || true
          exit 0
        fi

        mkdir -p "$alarms"

        # The alarms still waiting: each helper's pid is its file, holding "when<TAB>what". A file
        # whose helper is gone (it rang, or was ended) is tidied away.
        waiting() {
          for f in "$alarms"/*; do
            [ -f "$f" ] || continue
            pid=$(basename "$f")
            if kill -0 "$pid" 2>/dev/null; then echo "$pid"; else rm "$f" 2>/dev/null || true; fi
          done
        }

        case "${1:-}" in
          list)
            found=0
            for pid in $(waiting); do
              f="$alarms/$pid"
              when=$(cut -f 1 "$f")
              what=$(cut -f 2- "$f")
              left=$(( when - $(date +%s) ))
              echo "$(date -r "$when" '+%H:%M') (in $(( (left + 59) / 60 )) min): $what"
              found=1
            done
            [ "$found" = 1 ] || echo "No alarms waiting. Set one: alarm.sh \"20 minutes\" \"Stand up\"."
            exit 0 ;;
          cancel)
            n=0
            for pid in $(waiting); do
              f="$alarms/$pid"
              echo "Cancelled: $(date -r "$(cut -f 1 "$f")" '+%H:%M'): $(cut -f 2- "$f")"
              kill "$pid" 2>/dev/null || true
              rm "$f" 2>/dev/null || true
              n=$((n + 1))
            done
            [ "$n" -gt 0 ] || echo "No alarms were waiting."
            exit 0 ;;
          '')
            echo "When? A length from now (alarm.sh \"20 minutes\" \"Stand up\") or a time of day (alarm.sh 16:30 \"Call Sam\"). alarm.sh list shows the ones waiting; alarm.sh cancel cancels them." >&2
            exit 1 ;;
        esac

        # The time: one argument ("20 minutes", "16:30"), or a number and its unit as two.
        when="$1"; shift
        case "$when" in
          *[0-9]) case "${1:-}" in
                    s|sec|secs|second|seconds|m|min|mins|minute|minutes|h|hr|hrs|hour|hours) when="$when $1"; shift ;;
                  esac ;;
        esac
        message="Alarm"
        if [ $# -gt 0 ]; then message="$*"; fi
        now=$(date +%s)
        target=""

        lower=$(printf '%s' "$when" | tr '[:upper:]' '[:lower:]' | sed 's/^in //; s/^at //')
        if printf '%s' "$lower" | grep -Eq '^[0-9]+(\.[0-9]+)?[ ]*(s|sec|secs|second|seconds|m|min|mins|minute|minutes|h|hr|hrs|hour|hours)?$'; then
          number=$(printf '%s' "$lower" | sed -E 's/^([0-9]+(\.[0-9]+)?).*$/\1/')
          unit=$(printf '%s' "$lower" | sed -E 's/^[0-9]+(\.[0-9]+)?[ ]*//')
          case "$unit" in
            s|sec|secs|second|seconds) per=1 ;;
            h|hr|hrs|hour|hours) per=3600 ;;
            *) per=60 ;;   # minutes unless said
          esac
          seconds=$(awk -v n="$number" -v p="$per" 'BEGIN { printf "%d", n * p + 0.5 }')
          target=$((now + seconds))
        elif printf '%s' "$lower" | grep -Eq '^[0-9]{1,2}(:[0-9]{2})?[ ]*(am|pm)?$'; then
          hour=$(printf '%s' "$lower" | sed -E 's/^([0-9]{1,2}).*$/\1/')
          minute=$(printf '%s' "$lower" | sed -E 's/^[0-9]{1,2}:?([0-9]{2})?.*$/\1/')
          minute="${minute:-0}"
          case "$lower" in
            *pm) [ "$hour" -lt 12 ] && hour=$((hour + 12)) ;;
            *am) [ "$hour" -eq 12 ] && hour=0 ;;
          esac
          if [ "$hour" -gt 23 ] || [ "$minute" -gt 59 ]; then
            echo "$when isn't a time of day. Try 16:30, or 7am." >&2
            exit 1
          fi
          today=$(date '+%Y-%m-%d')
          target=$(date -j -f '%Y-%m-%d %H:%M' "$today $hour:$minute" +%s 2>/dev/null || date -d "$today $hour:$minute" +%s)
          # Already past today: tomorrow's.
          [ "$target" -le "$now" ] && target=$((target + 86400))
        else
          echo "When? A length from now (20 minutes, 1.5 hours, 90 seconds) or a time of day (16:30, 7am), not \"$when\"." >&2
          exit 1
        fi

        if [ "$target" -le "$now" ]; then
          echo "That's no time at all: give it at least a few seconds." >&2
          exit 1
        fi

        # The helper waits in a session of its own (perl's setsid, which every Mac has), so it
        # goes on after this run ends, and Stop on this run doesn't end it. It writes its own
        # record, and takes it away when it rings.
        ALARM_DIR="$alarms" ALARM_TARGET="$target" ALARM_MESSAGE="$message" ALARM_SCRIPT="$0" \
          perl -e 'use POSIX qw(setsid); my $pid = fork(); if ($pid) { exit 0 }
                   setsid(); open(STDIN, "<", "/dev/null"); open(STDOUT, ">", "/dev/null"); open(STDERR, ">", "/dev/null");
                   open(my $f, ">", "$ENV{ALARM_DIR}/$$"); print $f "$ENV{ALARM_TARGET}\t$ENV{ALARM_MESSAGE}"; close $f;
                   exec("bash", $ENV{ALARM_SCRIPT}, "--ring", $ENV{ALARM_TARGET}, $ENV{ALARM_MESSAGE}) or exit 1;' </dev/null
        left=$((target - now))
        if [ "$left" -ge 3600 ]; then
          in="$((left / 3600)) h $(( (left % 3600) / 60 )) min"
        elif [ "$left" -ge 60 ]; then
          in="$((left / 60)) min"
        else
          in="$left s"
        fi
        echo "Alarm set for $(date -r "$target" '+%H:%M') (in $in): \"$message\". It rings on this Mac with a sound, the words out loud and a notification. alarm.sh list shows it; alarm.sh cancel cancels it."
        """# + "\n"),
        ("utilities/today.sh", #"""
        #!/bin/bash
        # Today's date, every way it's written: the day, ISO, week and day of the year, the quarter, what's left of the year
        #
        # Input (optional): One piece of it: iso, long, short, us, day, week, month, year, year-day, quarter, left or compact (all of them unless set)
        #
        #   today.sh            Friday 23 October 2026 · 2026-10-23 · week 43 · day 296 of 365 (69 left) · Q4
        #   today.sh iso        2026-10-23          (for file names and sorting)
        #   today.sh long       Friday, 23 October 2026
        #   today.sh short      23/10/2026          today.sh us → 10/23/2026
        #   today.sh day        Friday              today.sh week → 43      today.sh quarter → Q4
        set -euo pipefail

        year=$(date +%Y); month=$(date +%m); day=$(date +%d)
        yday=$((10#$(date +%j)))
        week=$((10#$(date +%V)))
        m=$((10#$month))
        if [ $((year % 4)) -eq 0 ] && { [ $((year % 100)) -ne 0 ] || [ $((year % 400)) -eq 0 ]; }; then days=366; else days=365; fi
        left=$((days - yday))
        quarter=$(( (m - 1) / 3 + 1 ))
        weekday=$(date +%A); monthname=$(date +%B)

        case "${1:-}" in
          '') echo "$weekday $((10#$day)) $monthname $year · $year-$month-$day · week $week · day $yday of $days ($left left) · Q$quarter" ;;
          iso) echo "$year-$month-$day" ;;
          long) echo "$weekday, $((10#$day)) $monthname $year" ;;
          short|uk|eu) echo "$day/$month/$year" ;;
          us) echo "$month/$day/$year" ;;
          day|weekday) echo "$weekday" ;;
          week) echo "$week" ;;
          month) echo "$monthname" ;;
          year) echo "$year" ;;
          year-day|day-of-year) echo "$yday" ;;
          quarter) echo "Q$quarter" ;;
          left|days-left) echo "$left" ;;
          compact) echo "$year$month$day" ;;
          *) echo "Which piece? iso, long, short, us, day, week, month, year, year-day, quarter, left or compact (today.sh alone gives them all), not \"$1\"." >&2; exit 1 ;;
        esac
        """# + "\n"),
        ("utilities/now.sh", #"""
        #!/bin/bash
        # The time now, every way it's written: this Mac's time, UTC, its time zone, ISO 8601 and Unix seconds
        #
        # Input (optional): One piece of it: time, 12h, seconds, utc, zone, iso, unix or stamp (all of them unless set)
        #
        #   now.sh           14:05 · 2:05 pm · 14:05:32 · UTC 13:05 · BST (+0100) · 2026-10-23T14:05:32+01:00 · 1792764332
        #   now.sh iso       2026-10-23T14:05:32+01:00   (ISO 8601, with the zone)
        #   now.sh unix      1792764332                  (seconds since 1970, for scripts and APIs)
        #   now.sh stamp     20261023-140532             (for file names)
        #   now.sh utc       13:05:32
        set -euo pipefail

        hm=$(date +%H:%M); hms=$(date +%H:%M:%S)
        hour=$((10#$(date +%H))); minute=$(date +%M)
        ampm=pm; h12=$hour
        if [ "$hour" -lt 12 ]; then ampm=am; fi
        if [ "$hour" -eq 0 ]; then h12=12; elif [ "$hour" -gt 12 ]; then h12=$((hour - 12)); fi
        twelve="$h12:$minute $ampm"
        utc=$(date -u +%H:%M:%S)
        offset=$(date +%z)
        zone="$(date +%Z) ($offset)"
        unix=$(date +%s)
        iso="$(date +%Y-%m-%dT%H:%M:%S)${offset:0:3}:${offset:3:2}"
        stamp=$(date +%Y%m%d-%H%M%S)

        case "${1:-}" in
          '') echo "$hm · $twelve · $hms · UTC ${utc%:*} · $zone · $iso · $unix" ;;
          time|24h) echo "$hm" ;;
          12h) echo "$twelve" ;;
          seconds) echo "$hms" ;;
          utc) echo "$utc" ;;
          zone) echo "$zone" ;;
          iso) echo "$iso" ;;
          unix|epoch) echo "$unix" ;;
          stamp) echo "$stamp" ;;
          *) echo "Which piece? time, 12h, seconds, utc, zone, iso, unix or stamp (now.sh alone gives them all), not \"$1\"." >&2; exit 1 ;;
        esac
        """# + "\n"),
        ("utilities/format-date.py", #"""
        #!/usr/bin/env python3
        # Reads a date written any way (today, next friday, in 3 days, 23 Oct, 2026-10-23, Unix seconds…) and writes it the way you ask
        #
        # Input (optional): A date, written any way (today unless set)
        # Input (optional): How to write it: iso, long, short, us, day, week, unix, rfc, compact, relative, full, time, or a strftime pattern (iso unless set)
        #
        #   format-date.py                       2026-10-23
        #   format-date.py tomorrow long         Saturday, 24 October 2026
        #   format-date.py next friday           2026-10-30
        #   format-date.py "in 3 weeks" relative in 21 days
        #   format-date.py christmas day         Friday
        #   format-date.py 1792764332 full       2026-10-23 14:05:32 (Unix seconds, read as this Mac's time)
        #   format-date.py 23 Oct 2026 "%d.%m.%Y"   23.10.2026 (any strftime pattern)
        # The last word is the way to write it when it's one of the ways above; everything before is the date.
        # Numbers with slashes are day/month/year when the first can only be a day (23/10/2026); otherwise
        # month/day/year in the United States, day/month/year elsewhere (DATE_ORDER=dmy or mdy says which).
        import calendar
        import datetime
        import os
        import re
        import sys

        WAYS = {
            "iso": "%Y-%m-%d", "long": "%A, %-d %B %Y", "short": "%d/%m/%Y", "uk": "%d/%m/%Y", "eu": "%d/%m/%Y",
            "us": "%m/%d/%Y", "day": "%A", "weekday": "%A", "month": "%B", "year": "%Y", "compact": "%Y%m%d",
            "full": "%Y-%m-%d %H:%M:%S", "time": "%H:%M", "rfc": "%a, %d %b %Y %H:%M:%S %z", "stamp": "%Y%m%d-%H%M%S",
            "week": "%V", "unix": "unix", "relative": "relative",
        }
        UNITS = {"second": 1, "minute": 60, "hour": 3600, "day": 86400, "week": 604800}
        NAMED = {"christmas": (12, 25), "christmas eve": (12, 24), "boxing day": (12, 26), "new year": (1, 1),
                 "new year's": (1, 1), "new year's day": (1, 1), "new year's eve": (12, 31), "halloween": (10, 31),
                 "valentine's": (2, 14), "valentine's day": (2, 14), "valentines": (2, 14)}
        MONTHS = {m.lower(): i for i, m in enumerate(calendar.month_name) if m}
        MONTHS.update({m.lower(): i for i, m in enumerate(calendar.month_abbr) if m})
        MONTHS["sept"] = 9
        DAYS = {d.lower(): i for i, d in enumerate(calendar.day_name)}
        DAYS.update({d.lower(): i for i, d in enumerate(calendar.day_abbr)})


        def months_later(when, months):
            month = when.month - 1 + months
            year = when.year + month // 12
            month = month % 12 + 1
            day = min(when.day, calendar.monthrange(year, month)[1])
            return when.replace(year=year, month=month, day=day)


        def at_time(when, hour, minute, second=0):
            return when.replace(hour=hour, minute=minute, second=second, microsecond=0)


        def read(text, now):
            """The moment some words name, or None when they don't name one."""
            t = " ".join(text.lower().replace(",", " ").split())
            t = re.sub(r"(\d)(st|nd|rd|th)\b", r"\1", t)
            t = re.sub(r"^(on|at|the)\s+", "", t)
            today = at_time(now, 0, 0)

            if t in ("", "today"):
                return today
            if t == "now":
                return now
            if t == "tomorrow":
                return today + datetime.timedelta(days=1)
            if t == "yesterday":
                return today - datetime.timedelta(days=1)
            if t in NAMED:
                month, day = NAMED[t]
                when = today.replace(month=month, day=day)
                return when if when >= today else when.replace(year=when.year + 1)

            # A number alone: Unix seconds (ten or more digits), or a day of this month.
            if re.fullmatch(r"\d{10,13}", t):
                seconds = int(t) / (1000 if len(t) == 13 else 1)
                return datetime.datetime.fromtimestamp(seconds).astimezone()
            if re.fullmatch(r"\d{1,2}", t) and 1 <= int(t) <= calendar.monthrange(today.year, today.month)[1]:
                return today.replace(day=int(t))

            # A length from now, or ago: in 3 days, 2 weeks ago, in 1.5 hours, next month, last year.
            m = re.fullmatch(r"(in\s+)?(\d+(?:\.\d+)?|an?)\s+(second|minute|hour|day|week|month|year)s?(\s+ago|\s+from now)?", t)
            if m and (m.group(1) or m.group(4)):
                number = 1.0 if m.group(2) in ("a", "an") else float(m.group(2))
                sign = -1 if (m.group(4) or "").strip() == "ago" else 1
                unit = m.group(3)
                base = now if unit in ("second", "minute", "hour") else today
                if unit == "month":
                    return months_later(base, sign * int(number))
                if unit == "year":
                    return months_later(base, sign * int(number) * 12)
                return base + datetime.timedelta(seconds=sign * number * UNITS[unit])
            m = re.fullmatch(r"(next|last|this)\s+(week|month|year)", t)
            if m:
                step = {"next": 1, "last": -1, "this": 0}[m.group(1)]
                if m.group(2) == "week":
                    return today + datetime.timedelta(days=7 * step)
                return months_later(today, step * (1 if m.group(2) == "month" else 12))

            # A day of the week: friday (the coming one, today if it's today), next friday, last friday.
            m = re.fullmatch(r"(next|last|this)?\s*([a-z]+)", t)
            if m and m.group(2) in DAYS:
                ahead = (DAYS[m.group(2)] - today.weekday()) % 7
                if m.group(1) == "next":
                    ahead = ahead or 7
                elif m.group(1) == "last":
                    ahead = ahead - 7 if ahead else -7
                return today + datetime.timedelta(days=ahead)

            # A clock time, today: 14:30, 2:30pm, 7am, 14:30:05.
            m = re.fullmatch(r"(\d{1,2})(?::(\d{2}))?(?::(\d{2}))?\s*(am|pm)?", t)
            if m and (m.group(2) or m.group(4)):
                hour, minute, second = int(m.group(1)), int(m.group(2) or 0), int(m.group(3) or 0)
                if m.group(4) == "pm" and hour < 12:
                    hour += 12
                if m.group(4) == "am" and hour == 12:
                    hour = 0
                if hour > 23 or minute > 59 or second > 59:
                    return None
                return at_time(today, hour, minute, second)

            # A date and maybe a time: 2026-10-23, 2026-10-23 14:30, 2026-10-23T14:30:00, 23/10/2026, 10/23/26, 23.10.2026.
            m = re.fullmatch(r"(\d{4})-(\d{1,2})-(\d{1,2})(?:[t ](\d{1,2}):(\d{2})(?::(\d{2}))?)?(?:z|[+-]\d{2}:?\d{2})?", t)
            if m:
                try:
                    return datetime.datetime(int(m.group(1)), int(m.group(2)), int(m.group(3)),
                                             int(m.group(4) or 0), int(m.group(5) or 0), int(m.group(6) or 0)).astimezone()
                except ValueError:
                    return None
            m = re.fullmatch(r"(\d{1,2})[/.](\d{1,2})(?:[/.](\d{2}|\d{4}))?", t)
            if m:
                a, b = int(m.group(1)), int(m.group(2))
                order = os.environ.get("DATE_ORDER", "").lower()
                if not order:
                    lang = os.environ.get("LC_ALL") or os.environ.get("LC_TIME") or os.environ.get("LANG") or ""
                    order = "mdy" if "_US" in lang else "dmy"
                day, month = (a, b) if a > 12 or (b <= 12 and order == "dmy") else (b, a)
                year = int(m.group(3)) if m.group(3) else today.year
                if year < 100:
                    year += 2000
                try:
                    return today.replace(year=year, month=month, day=day)
                except ValueError:
                    return None

            # Words: 23 oct, oct 23, 23 october 2026, october 23 2026, with a time after (23 oct 14:30, oct 23 at 2pm).
            m = re.fullmatch(r"(?:(\d{1,2})\s+([a-z]+)|([a-z]+)\s+(\d{1,2}))(?:\s+(\d{4}))?(?:\s+(?:at\s+)?(.+))?", t)
            if m:
                day = int(m.group(1) or m.group(4))
                month = MONTHS.get(m.group(2) or m.group(3))
                if not month:
                    return None
                year = int(m.group(5)) if m.group(5) else today.year
                try:
                    when = today.replace(year=year, month=month, day=day)
                except ValueError:
                    return None
                if not m.group(5) and when < today - datetime.timedelta(days=180):
                    when = when.replace(year=year + 1)
                if m.group(6):
                    clock = read(m.group(6), now)
                    if clock is None:
                        return None
                    when = at_time(when, clock.hour, clock.minute, clock.second)
                return when
            m = re.fullmatch(r"([a-z]+)\s+(\d{4})", t)
            if m and m.group(1) in MONTHS:
                return today.replace(year=int(m.group(2)), month=MONTHS[m.group(1)], day=1)
            return None


        def relative(when, now):
            seconds = (when - now).total_seconds()
            today = at_time(now, 0, 0)
            days = (at_time(when, 0, 0) - today).days
            if abs(seconds) < 60 and when.hour == now.hour and days == 0:
                return "now"
            if at_time(when, 0, 0) == when and days != 0 or abs(days) >= 2:
                if days == 0:
                    return "today"
                if days == 1:
                    return "tomorrow"
                if days == -1:
                    return "yesterday"
                return f"in {days} days" if days > 0 else f"{-days} days ago"
            unit, size = next((u, s) for u, s in (("hour", 3600), ("minute", 60), ("second", 1)) if abs(seconds) >= s or s == 1)
            n = int(round(abs(seconds) / size))
            words = f"{n} {unit}{'s' if n != 1 else ''}"
            return f"in {words}" if seconds > 0 else f"{words} ago"


        def write(when, way, now):
            if way == "unix":
                return str(int(when.timestamp()))
            if way == "relative":
                return relative(when, now)
            pattern = WAYS.get(way, way)
            if sys.platform.startswith("win"):
                pattern = pattern.replace("%-d", "%#d")
            return when.strftime(pattern)


        def main(argv):
            now = datetime.datetime.now().astimezone()
            words = [w for w in argv if w.strip()]
            way = "iso"
            if words and (words[-1].lower() in WAYS or "%" in words[-1]):
                way = words.pop().lower() if "%" not in words[-1] else words.pop()
            text = " ".join(words)
            when = read(text, now)
            if when is None:
                sys.exit(f"I can't read \"{text}\" as a date. Try today, tomorrow, next friday, in 3 days, 23 Oct, 2026-10-23, 14:30, or Unix seconds.")
            print(write(when, way, now))


        if __name__ == "__main__":
            main(sys.argv[1:])
        """# + "\n"),
        ("utilities/days-until.py", #"""
        #!/usr/bin/env python3
        # How long until a date (or since one): days, weeks and days, and which day of the week it falls on
        #
        # Input: The date, written any way (Christmas, 2026-12-25, 25 Dec, next friday…)
        # Input (optional): Counting from when (today unless set)
        #
        #   days-until.py christmas           In 63 days (9 weeks): Friday, 25 December 2026
        #   days-until.py 2026-01-01          295 days ago: Thursday, 1 January 2026
        #   days-until.py 25 dec 2026-12-01   24 days from Tuesday, 1 December 2026 (3 weeks and 3 days): Friday, 25 December 2026
        # The dates are read by format-date.py, beside this script.
        import datetime
        import os
        import subprocess
        import sys

        here = os.path.dirname(os.path.abspath(__file__))
        reader = os.path.join(here, "format-date.py")


        def read(words):
            done = subprocess.run([sys.executable, reader, words, "iso"], capture_output=True, text=True)
            if done.returncode != 0:
                sys.exit(done.stderr.strip() or f"I can't read \"{words}\" as a date.")
            return datetime.date.fromisoformat(done.stdout.strip())


        def long(day):
            return f"{day.strftime('%A')}, {day.day} {day.strftime('%B %Y')}"


        def span(days):
            weeks, rest = divmod(days, 7)
            if weeks and rest:
                return f"{weeks} week{'s' if weeks != 1 else ''} and {rest} day{'s' if rest != 1 else ''}"
            if weeks:
                return f"{weeks} week{'s' if weeks != 1 else ''}"
            return f"{rest} day{'s' if rest != 1 else ''}"


        args = sys.argv[1:]
        if not args or not args[0].strip():
            sys.exit("Until when? (days-until.py christmas, days-until.py 2026-12-25, days-until.py \"next friday\")")
        target = read(args[0])
        start = read(args[1]) if len(args) > 1 and args[1].strip() else datetime.date.today()
        days = (target - start).days

        def say(days, target, start, given):
            where = long(target)
            size = f" ({span(abs(days))})" if abs(days) >= 7 else ""
            if days == 0:
                return f"That's the day itself: {where}" if given else f"That's today: {where}"
            n = f"{abs(days)} day{'s' if abs(days) != 1 else ''}"
            if given:
                return f"{n} {'after' if days > 0 else 'before'} {long(start)}{size}: {where}"
            return f"In {n}{size}: {where}" if days > 0 else f"{n} ago{size}: {where}"


        print(say(days, target, start, len(args) > 1 and bool(args[1].strip())))
        """# + "\n"),
        ("utilities/month.py", #"""
        #!/usr/bin/env python3
        # A calendar of this month with today marked, or of a month you name, or the whole year
        #
        # Input (optional): A month (December, next month, 2027-03) or a year (2027); this month unless set
        #
        #   month.py                 this month, today in brackets
        #   month.py december        a month of this year (a past month is next year's)
        #   month.py 2027-03         a month of another year
        #   month.py 2027            the whole year
        #   month.py next            next month (also: last)
        import calendar
        import datetime
        import re
        import sys

        today = datetime.date.today()
        MONTHS = {m.lower(): i for i, m in enumerate(calendar.month_name) if m}
        MONTHS.update({m.lower(): i for i, m in enumerate(calendar.month_abbr) if m})

        text = " ".join(sys.argv[1:]).strip().lower().replace(" month", "")
        year, month = today.year, today.month
        if text in ("", "this"):
            pass
        elif text in ("next", "last", "previous"):
            step = 1 if text == "next" else -1
            month += step
            if month > 12:
                month, year = 1, year + 1
            if month < 1:
                month, year = 12, year - 1
        elif re.fullmatch(r"\d{4}", text):
            cal = calendar.TextCalendar(calendar.MONDAY)
            print(cal.formatyear(int(text), 2, 1, 6, 3).rstrip())
            sys.exit(0)
        elif re.fullmatch(r"\d{4}-\d{1,2}", text):
            year, month = (int(p) for p in text.split("-"))
        elif re.fullmatch(r"\d{1,2}[/-]\d{4}", text):
            month, year = (int(p) for p in re.split(r"[/-]", text))
        elif text in MONTHS:
            month = MONTHS[text]
            if month < today.month:
                year += 1
        else:
            m = re.fullmatch(r"([a-z]+)\s+(\d{4})", text)
            if m and m.group(1) in MONTHS:
                month, year = MONTHS[m.group(1)], int(m.group(2))
            else:
                sys.exit(f"Which month? A name (december), a year and month (2027-03), a year (2027), or next or last; not \"{text}\".")
        if not 1 <= month <= 12:
            sys.exit(f"There's no month {month}: 1 to 12.")

        cal = calendar.TextCalendar(calendar.MONDAY)
        lines = cal.formatmonth(year, month).rstrip().split("\n")
        if year == today.year and month == today.month:
            # Today in brackets, in the space around it, so the columns stay put: "22 23 24" → "22[23]24".
            day = f"{today.day:2d}"
            lines = lines[:2] + [re.sub(f" {day} ", f"[{today.day}]".rjust(4), " " + line + " ")[1:].rstrip() for line in lines[2:]]
        print("\n".join(line.rstrip() for line in lines))
        """# + "\n"),
        ("utilities/stopwatch.sh", #"""
        #!/bin/bash
        # A stopwatch across runs: start it, see how long it's been (and mark laps), stop it and get the total
        #
        # Input (optional): start, lap, stop, or nothing to see the time (a name after start says what's being timed)
        #
        #   stopwatch.sh start "the build"   starts (or starts again from zero)
        #   stopwatch.sh                     how long it's been running, and the laps so far
        #   stopwatch.sh lap                 marks a lap
        #   stopwatch.sh stop                stops it, with the total and every lap
        set -euo pipefail

        state="${TMPDIR:-/tmp}/toolmactoolrun-stopwatch"
        clock() { # seconds as h:mm:ss, or m:ss under an hour
          local s=$1
          if [ "$s" -ge 3600 ]; then printf '%d:%02d:%02d' $((s / 3600)) $(((s % 3600) / 60)) $((s % 60))
          else printf '%d:%02d' $((s / 60)) $((s % 60)); fi
        }
        laps() {
          [ -f "$state/laps" ] || return 0
          local n=0 previous
          previous=$(cat "$state/start")
          for at in $(cat "$state/laps"); do
            n=$((n + 1))
            echo "  lap $n: $(clock $((at - previous))) (at $(clock $((at - $(cat "$state/start")))))"
            previous=$at
          done
        }

        now=$(date +%s)
        case "${1:-}" in
          start)
            mkdir -p "$state"
            echo "$now" > "$state/start"
            shift
            printf '%s' "$*" > "$state/name"
            rm "$state/laps" 2>/dev/null || true
            echo "Started${*:+: $*} (stopwatch.sh shows the time, lap marks one, stop ends it)." ;;
          '' | time | lap | stop)
            if [ ! -f "$state/start" ]; then
              echo "The stopwatch isn't running. Start it: stopwatch.sh start \"the build\"." >&2
              exit 1
            fi
            start=$(cat "$state/start"); name=$(cat "$state/name" 2>/dev/null || true)
            elapsed=$((now - start))
            case "${1:-}" in
              lap)
                echo "$now" >> "$state/laps"
                echo "Lap at $(clock $elapsed)${name:+ ($name)}"
                laps ;;
              stop)
                echo "Stopped at $(clock $elapsed)${name:+: $name} (started $(date -r "$start" '+%H:%M' 2>/dev/null || date -d "@$start" '+%H:%M'))"
                laps
                rm "$state/start" "$state/name" "$state/laps" 2>/dev/null || true; rmdir "$state" 2>/dev/null || true ;;
              *)
                echo "$(clock $elapsed)${name:+ · $name} (started $(date -r "$start" '+%H:%M' 2>/dev/null || date -d "@$start" '+%H:%M'))"
                laps ;;
            esac ;;
          *) echo "start, lap, stop, or nothing to see the time; not \"$1\"." >&2; exit 1 ;;
        esac
        """# + "\n"),
        ("utilities/sunrise.py", #"""
        #!/usr/bin/env python3
        # Sunrise and sunset today and tomorrow, and how long the day is: where this Mac is, or a place you name
        #
        # Input (optional): A place (where you are unless set)
        #
        #   sunrise.py              where you are (told from your internet address)
        #   sunrise.py Reykjavik    a place by name ("Paris, Texas" picks among the Parises)
        # The first line says whether the sun is up now. From Open-Meteo (no account needed).
        import datetime
        import json
        import sys
        import time
        import urllib.error
        import urllib.parse
        import urllib.request


        def fetch(url, tries=3, timeout=15):
            request = urllib.request.Request(url, headers={"User-Agent": "ToolMacToolRun sunrise"})
            for attempt in range(tries):
                try:
                    with urllib.request.urlopen(request, timeout=timeout) as response:
                        return json.load(response)
                except (urllib.error.URLError, TimeoutError):
                    if attempt == tries - 1:
                        raise
                    time.sleep(1 + attempt)


        def here():
            """Where this Mac is, from its internet address: (name, latitude, longitude)."""
            try:
                d = fetch("https://ipinfo.io/json", tries=1, timeout=8)
                lat, lon = d["loc"].split(",")
                return ", ".join(p for p in [d.get("city"), d.get("country")] if p), float(lat), float(lon)
            except (urllib.error.URLError, TimeoutError, KeyError, ValueError):
                pass
            d = fetch("https://ipapi.co/json/", tries=1, timeout=8)
            return ", ".join(p for p in [d.get("city"), d.get("country_name")] if p), d["latitude"], d["longitude"]


        def find(place):
            name, _, near = place.partition(",")
            query = urllib.parse.urlencode({"name": name.strip(), "count": 20, "language": "en"})
            found = fetch("https://geocoding-api.open-meteo.com/v1/search?" + query).get("results") or []
            near = near.strip().lower()
            if near:
                found = [r for r in found if any(near in (r.get(k) or "").lower() for k in ("admin1", "admin2", "country", "country_code"))]
            if not found:
                sys.exit(f"There's no place called {place} that I can find. Try its name and its country: \"Paris, France\".")
            r = found[0]
            return ", ".join([r["name"]] + [p for p in (r.get("country"),) if p]), r["latitude"], r["longitude"]


        place = " ".join(sys.argv[1:]).strip()
        try:
            name, lat, lon = find(place) if place else here()
            query = urllib.parse.urlencode({"latitude": lat, "longitude": lon, "daily": "sunrise,sunset,daylight_duration",
                                            "timezone": "auto", "forecast_days": 2})
            d = fetch("https://api.open-meteo.com/v1/forecast?" + query)
        except (urllib.error.URLError, TimeoutError) as e:
            sys.exit(f"Couldn't reach the sun times ({getattr(e, 'reason', e)}). Is this Mac online?")

        daily = d["daily"]
        zone = d.get("timezone", "")
        rises = [datetime.datetime.fromisoformat(t) for t in daily["sunrise"]]
        sets = [datetime.datetime.fromisoformat(t) for t in daily["sunset"]]
        lengths = daily["daylight_duration"]
        clock = lambda t: t.strftime("%H:%M")
        length = lambda s: f"{int(s // 3600)} h {int(s % 3600 // 60)} min"

        now = datetime.datetime.now(datetime.timezone.utc).astimezone()
        there = now.replace(tzinfo=None) if not zone else now.astimezone(datetime.timezone(datetime.timedelta(seconds=d.get("utc_offset_seconds", 0)))).replace(tzinfo=None)
        if there < rises[0]:
            state = f"The sun isn't up yet in {name}: it rises at {clock(rises[0])}, in {length((rises[0] - there).total_seconds())}."
        elif there < sets[0]:
            state = f"The sun is up in {name}: it sets at {clock(sets[0])}, in {length((sets[0] - there).total_seconds())}."
        else:
            state = f"The sun has set in {name}: it rises again at {clock(rises[1])}, in {length((rises[1] - there).total_seconds())}."
        print(state)
        print(f"Today     sunrise {clock(rises[0])} · sunset {clock(sets[0])} · {length(lengths[0])} of daylight")
        change = lengths[1] - lengths[0]
        print(f"Tomorrow  sunrise {clock(rises[1])} · sunset {clock(sets[1])} · {length(lengths[1])} ({'+' if change >= 0 else '−'}{abs(int(round(change / 60)))} min)")
        """# + "\n"),
        ("utilities/holidays.py", #"""
        #!/usr/bin/env python3
        # The next public holidays: in the country this Mac is in, or one you name
        #
        # Input (optional): A country (its two letters: US, GB, DE, NG…; where you are unless set)
        # Input (optional): How many to show (5 unless set)
        #
        #   holidays.py              the next ones where you are
        #   holidays.py GB 3         the next three in the United Kingdom
        #   holidays.py NG year      every holiday this year in Nigeria
        # A line each: the date, the day, the holiday, and how far off it is. From Nager.Date (no account needed).
        import datetime
        import json
        import os
        import sys
        import urllib.error
        import urllib.request

        args = [a for a in sys.argv[1:] if a.strip()]
        country = args[0].upper() if args and args[0].isalpha() and len(args[0]) == 2 else ""
        rest = args[1:] if country else args
        whole_year = bool(rest) and rest[0].lower() == "year"
        count = int(rest[0]) if rest and rest[0].isdigit() else 5
        if args and not country and not (args[0].isdigit() or args[0].lower() == "year"):
            sys.exit(f"Which country? Its two letters (US, GB, DE, NG…), not \"{args[0]}\".")


        def fetch(url):
            request = urllib.request.Request(url, headers={"User-Agent": "ToolMacToolRun holidays", "Accept": "application/json"})
            with urllib.request.urlopen(request, timeout=15) as response:
                return json.load(response)


        if not country:
            # Where this Mac is: its internet address, else the language it's set to (en_GB), else the United States.
            try:
                country = fetch("https://ipinfo.io/json").get("country", "")
            except (urllib.error.URLError, TimeoutError, ValueError):
                pass
            if not country:
                lang = os.environ.get("LC_ALL") or os.environ.get("LANG") or ""
                country = lang.split(".")[0].split("_")[-1] if "_" in lang else "US"

        today = datetime.date.today()
        try:
            if whole_year:
                found = fetch(f"https://date.nager.at/api/v3/PublicHolidays/{today.year}/{country}")
            else:
                found = fetch(f"https://date.nager.at/api/v3/NextPublicHolidays/{country}")[:count]
        except urllib.error.HTTPError as e:
            if e.code in (404, 500):
                sys.exit(f"Nager.Date doesn't know the holidays of {country}. A country's two letters: US, GB, DE, NG…")
            sys.exit(f"Couldn't get the holidays ({e.code} from date.nager.at).")
        except (urllib.error.URLError, TimeoutError) as e:
            sys.exit(f"Couldn't reach date.nager.at ({getattr(e, 'reason', e)}). Is this Mac online?")

        if not found:
            print(f"No public holidays listed for {country}.")
        for h in found:
            day = datetime.date.fromisoformat(h["date"])
            off = (day - today).days
            when = "today" if off == 0 else "tomorrow" if off == 1 else f"in {off} days" if off > 0 else f"{-off} days ago"
            name = h.get("localName") or h.get("name")
            if h.get("name") and h["name"] != name:
                name = f"{name} ({h['name']})"
            print(f"{day.strftime('%a %d %b %Y')}  {name}  ({when})")
        """# + "\n"),
        ("utilities/open-app.sh", #"""
        #!/bin/bash
        # Opens an app by name and brings it to the front: on its own, or with a file or web address to open in it
        #
        # Input: The app's name (Safari, Mail, Visual Studio Code…)
        # Input (optional): A file, folder or web address to open in it
        #
        #   open-app.sh Safari                       opens Safari (or brings it forward)
        #   open-app.sh Preview ~/Desktop/photo.png  opens the file in Preview
        #   open-app.sh Firefox https://example.com  a web address in that app
        #   open-app.sh list                         every app installed, by name
        set -euo pipefail

        folders=(/Applications /System/Applications /System/Applications/Utilities "$HOME/Applications")
        installed() {
          for folder in "${folders[@]}"; do
            [ -d "$folder" ] || continue
            for app in "$folder"/*.app; do [ -e "$app" ] && basename "${app%.app}"; done
          done | sort -fu
        }

        if ! command -v open >/dev/null 2>&1 || [ "$(uname)" != "Darwin" ]; then
          echo "Opening an app needs macOS's open command." >&2
          exit 1
        fi

        app="${1:-}"
        case "$app" in
          '') echo "Which app? (open-app.sh Safari; open-app.sh list names them all)" >&2; exit 1 ;;
          list) installed; exit 0 ;;
        esac
        shift
        what="${*:-}"

        if [ -n "$what" ]; then
          case "$what" in
            http://*|https://*|mailto:*|file://*) open -a "$app" "$what" 2>/dev/null && { echo "Opened $what in $app"; exit 0; } ;;
            *)
              path="${what/#\~/$HOME}"
              if [ ! -e "$path" ]; then echo "There's nothing at $what." >&2; exit 1; fi
              open -a "$app" "$path" 2>/dev/null && { echo "Opened $(basename "$path") in $app"; exit 0; } ;;
          esac
        else
          open -a "$app" 2>/dev/null && { echo "Opened $app"; exit 0; }
        fi

        # Not opened: no app by that name. Say which installed ones come close.
        close=$(installed | grep -i -- "$(printf '%s' "$app" | cut -c 1-4)" | head -n 5 | tr '\n' ',' | sed 's/,$//; s/,/, /g')
        if [ -n "$close" ]; then
          echo "There's no app called $app. Close: $close. (open-app.sh list names them all.)" >&2
        else
          echo "There's no app called $app in /Applications, the system's apps or ~/Applications (open-app.sh list names them all)." >&2
        fi
        exit 1
        """# + "\n"),
        ("utilities/quit-app.sh", #"""
        #!/bin/bash
        # Quits an app by name, the way ⌘Q does: it gets to save its work and ask about anything unsaved
        #
        # Input: The app's name (Safari, Mail, Music…)
        # Why: It's asked to quit politely, so it can save first; it's never forced
        #
        #   quit-app.sh Safari
        #   quit-app.sh Music
        set -euo pipefail

        if ! command -v osascript >/dev/null 2>&1; then
          echo "Quitting an app needs macOS (and osascript)." >&2
          exit 1
        fi
        app="${*:-}"
        if [ -z "$app" ]; then
          echo "Which app? (quit-app.sh Safari; running-apps.sh names the ones running)" >&2
          exit 1
        fi

        running=$(osascript -e 'tell application "System Events" to get name of every application process whose background only is false' | tr ',' '\n' | sed 's/^ *//')
        if ! printf '%s\n' "$running" | grep -qix -- "$app"; then
          echo "$app isn't running. Running now: $(printf '%s' "$running" | tr '\n' ',' | sed 's/,/, /g')." >&2
          exit 1
        fi

        # quit is a command every app answers to (it isn't in any one app's dictionary), so the app can be
        # named as it runs. An app that asks about unsaved work keeps the question on the screen: that's
        # what this run reports, and the app is still running.
        result=$(osascript - "$app" <<'APPLESCRIPT' 2>&1 || true
        on run argv
          set theApp to application (item 1 of argv)
          with timeout of 20 seconds
            tell theApp to quit
          end timeout
          return "quit"
        end run
        APPLESCRIPT
        )
        case "$result" in
          quit) echo "Quit $app" ;;
          *-1712*|*timed*out*) echo "$app is asking you something before it quits (unsaved work, most likely): answer it on the screen." ; exit 1 ;;
          *) echo "Couldn't quit $app: $result" >&2; exit 1 ;;
        esac
        """# + "\n"),
        ("utilities/front-app.sh", #"""
        #!/bin/bash
        # The app in front right now, and the title of its front window
        #
        #   front-app.sh      Safari — Example Domain
        set -euo pipefail

        if ! command -v osascript >/dev/null 2>&1; then
          echo "This needs macOS (and osascript)." >&2
          exit 1
        fi
        osascript <<'APPLESCRIPT'
        tell application "System Events"
          set p to first application process whose frontmost is true
          set found to name of p
          try
            set t to name of front window of p
            if t is not "" then set found to found & " — " & t
          end try
          return found
        end tell
        APPLESCRIPT
        """# + "\n"),
        ("utilities/running-apps.sh", #"""
        #!/bin/bash
        # The apps running right now, a line each, the one in front first and marked
        #
        # Input (optional): count, to get just how many
        #
        #   running-apps.sh          ▶ Safari, then the rest
        #   running-apps.sh count    7
        set -euo pipefail

        if ! command -v osascript >/dev/null 2>&1; then
          echo "This needs macOS (and osascript)." >&2
          exit 1
        fi
        apps=$(osascript <<'APPLESCRIPT'
        tell application "System Events"
          set names to name of every application process whose background only is false
          set front to name of first application process whose frontmost is true
          set text item delimiters to linefeed
          return front & linefeed & (names as text)
        end tell
        APPLESCRIPT
        )
        front=$(printf '%s\n' "$apps" | head -n 1)
        rest=$(printf '%s\n' "$apps" | tail -n +2 | grep -vx -- "$front" | sort -f)
        case "${1:-}" in
          count) printf '%s\n' "$apps" | tail -n +2 | wc -l | tr -d ' ' ;;
          '') echo "▶ $front"; [ -n "$rest" ] && printf '%s\n' "$rest" ;;
          *) echo "running-apps.sh alone lists them; running-apps.sh count counts them; not \"$1\"." >&2; exit 1 ;;
        esac
        """# + "\n"),
        ("utilities/notify.sh", #"""
        #!/bin/bash
        # Shows a notification on this Mac: the words, and a title if you give one
        #
        # Input: What it says
        # Input (optional): Its title (Tool Mac Tool Run unless set)
        #
        #   notify.sh "The backup is done"
        #   notify.sh "3 tests failed" "Nightly build"
        #   echo "Done" | notify.sh                   its input, when no words are given
        set -euo pipefail

        if ! command -v osascript >/dev/null 2>&1; then
          echo "Notifications need macOS (and osascript)." >&2
          exit 1
        fi
        text="${1:-}"
        title="${2:-Tool Mac Tool Run}"
        if [ -z "$text" ] && [ ! -t 0 ]; then text=$(cat); fi
        if [ -z "${text//[[:space:]]/}" ]; then
          echo "Nothing to show: give it the words (notify.sh \"The backup is done\")." >&2
          exit 1
        fi
        # The words go in through the environment, never pasted into the script: they're anyone's text.
        NOTIFY_TEXT="$text" NOTIFY_TITLE="$title" osascript -e 'display notification (system attribute "NOTIFY_TEXT") with title (system attribute "NOTIFY_TITLE")'
        echo "Shown: $title: $text"
        """# + "\n"),
        ("utilities/screenshot.sh", #"""
        #!/bin/bash
        # Takes a screenshot: the whole screen, a part you drag out, or a window you click; saved on the Desktop (or the clipboard)
        #
        # Input (optional): screen, select or window (screen unless set); add clipboard to copy it instead of saving
        #
        #   screenshot.sh                    the whole screen → ~/Desktop/Screenshot 2026-10-23 at 14.05.32.png
        #   screenshot.sh select             drag out the part you want (Esc cancels)
        #   screenshot.sh window             click the window you want
        #   screenshot.sh screen clipboard   onto the clipboard, ready to paste
        set -euo pipefail

        if ! command -v screencapture >/dev/null 2>&1; then
          echo "Screenshots need screencapture, which comes with macOS." >&2
          exit 1
        fi
        how=screen; where=file
        for word in "$@"; do
          case "$word" in
            screen|full|all) how=screen ;;
            select|selection|area|part) how=select ;;
            window) how=window ;;
            clipboard|copy) where=clipboard ;;
            '') ;;
            *) echo "screen, select or window, and clipboard to copy it; not \"$word\"." >&2; exit 1 ;;
          esac
        done
        flags=-x   # no shutter sound
        case "$how" in
          select) flags="$flags -i" ;;
          window) flags="$flags -i -W" ;;
        esac
        if [ "$where" = clipboard ]; then
          # shellcheck disable=SC2086
          screencapture $flags -c
          echo "The screenshot is on the clipboard."
          exit 0
        fi
        file="$HOME/Desktop/Screenshot $(date '+%Y-%m-%d at %H.%M.%S').png"
        # shellcheck disable=SC2086
        screencapture $flags "$file"
        if [ -s "$file" ]; then
          echo "$file"
        else
          echo "No screenshot was taken (cancelled?)." >&2
          exit 1
        fi
        """# + "\n"),
        ("utilities/volume.sh", #"""
        #!/bin/bash
        # The Mac's volume: see it, set it (0 to 100), turn it up or down a notch, mute or unmute
        #
        # Input (optional): A level (0–100), up, down, mute or unmute (just shows it unless set)
        #
        #   volume.sh         Volume 50% (sound on)
        #   volume.sh 30      sets it to 30%
        #   volume.sh up      10 louder (volume.sh down: 10 quieter)
        #   volume.sh mute    volume.sh unmute brings the sound back
        set -euo pipefail

        if ! command -v osascript >/dev/null 2>&1; then
          echo "The volume needs macOS (and osascript)." >&2
          exit 1
        fi
        level=$(osascript -e 'output volume of (get volume settings)')
        muted=$(osascript -e 'output muted of (get volume settings)')
        case "${1:-}" in
          '') ;;
          mute) osascript -e 'set volume output muted true'; muted=true ;;
          unmute) osascript -e 'set volume output muted false'; muted=false ;;
          up) level=$((level + 10 > 100 ? 100 : level + 10)); osascript -e "set volume output volume $level" ;;
          down) level=$((level - 10 < 0 ? 0 : level - 10)); osascript -e "set volume output volume $level" ;;
          *[!0-9]*) echo "A level from 0 to 100, up, down, mute or unmute; not \"$1\"." >&2; exit 1 ;;
          *) level=$(( $1 > 100 ? 100 : $1 )); osascript -e "set volume output volume $level" ;;
        esac
        if [ "$muted" = true ]; then echo "Volume $level% (muted)"; else echo "Volume $level% (sound on)"; fi
        """# + "\n"),
        ("utilities/lock-screen.sh", #"""
        #!/bin/bash
        # Locks the screen (what ⌃⌘Q does), so a password is needed to get back in
        #
        # Why: Nothing is closed or ended; the screen just locks, as when you step away
        set -euo pipefail

        if ! command -v osascript >/dev/null 2>&1; then
          echo "Locking the screen needs macOS (and osascript)." >&2
          exit 1
        fi
        # The lock keys, pressed for you. That needs this app in System Settings > Privacy & Security >
        # Accessibility; without it, the screen saver starts instead (which locks too, when the Lock
        # Screen settings ask for a password after it).
        if osascript -e 'tell application "System Events" to keystroke "q" using {command down, control down}' >/dev/null 2>&1; then
          echo "Locked."
        else
          open -a ScreenSaverEngine 2>/dev/null || open -b com.apple.ScreenSaver.Engine
          echo "The screen saver is on (locking the screen itself needs this app allowed under System Settings > Privacy & Security > Accessibility)."
        fi
        """# + "\n"),
        ("utilities/pick.py", #"""
        #!/usr/bin/env python3
        # Picks at random: a number, one of some things, heads or tails, a dice roll, or shuffles a list
        #
        # Input (optional): What to pick: a top number (1 to it), two numbers (between them), pick a b c, coin, dice, shuffle a b c (1 to 100 unless set)
        #
        #   pick.py              a number from 1 to 100
        #   pick.py 6            1 to 6               pick.py 10 20 → 10 to 20
        #   pick.py pick tea coffee water             one of them
        #   pick.py coin         heads or tails       pick.py dice → 1 to 6 (pick.py dice 2: two dice)
        #   pick.py shuffle a b c                     all of them, in a random order
        import secrets
        import sys

        args = [a for a in sys.argv[1:] if a.strip()]
        words = [w for a in args for w in a.replace(",", " ").split()]
        how = words[0].lower() if words else ""

        if not words:
            print(1 + secrets.randbelow(100))
        elif how == "coin":
            print(secrets.choice(["heads", "tails"]))
        elif how == "dice":
            dice = int(words[1]) if len(words) > 1 and words[1].isdigit() else 1
            rolls = [1 + secrets.randbelow(6) for _ in range(max(1, min(dice, 100)))]
            print(" ".join(str(r) for r in rolls) + (f"  (total {sum(rolls)})" if len(rolls) > 1 else ""))
        elif how in ("pick", "one", "choose"):
            if len(words) < 2:
                sys.exit("Pick from what? (pick.py pick tea coffee water)")
            print(secrets.choice(words[1:]))
        elif how == "shuffle":
            rest = words[1:]
            if not rest:
                sys.exit("Shuffle what? (pick.py shuffle a b c)")
            out = []
            while rest:
                out.append(rest.pop(secrets.randbelow(len(rest))))
            print("\n".join(out))
        elif all(w.lstrip("-").isdigit() for w in words) and len(words) <= 2:
            low, high = (1, int(words[0])) if len(words) == 1 else (int(words[0]), int(words[1]))
            if low > high:
                low, high = high, low
            print(low + secrets.randbelow(high - low + 1))
        else:
            sys.exit("A number (pick.py 6), two (pick.py 10 20), pick a b c, coin, dice or shuffle a b c; not \"" + " ".join(words) + "\".")
        """# + "\n"),
        ("utilities/text-case.py", #"""
        #!/usr/bin/env python3
        # Rewrites text in a case: UPPER, lower, Title, Sentence, slug-for-urls, snake_case, kebab-case, camelCase, PascalCase
        #
        # Input: Which case: upper, lower, title, sentence, slug, snake, kebab, camel, pascal, or swap
        # Input text (optional): The text (or give it after the case)
        #
        #   text-case.py slug "Hello, World! It's 2026"     hello-world-its-2026
        #   text-case.py title "the quick brown fox"         The Quick Brown Fox
        #   echo "Some Name" | text-case.py snake            some_name
        import re
        import sys
        import unicodedata

        args = sys.argv[1:]
        if not args:
            sys.exit("Which case? upper, lower, title, sentence, slug, snake, kebab, camel, pascal or swap (text-case.py slug \"Hello World\").")
        how = args[0].lower()
        text = " ".join(args[1:]) if len(args) > 1 else ("" if sys.stdin.isatty() else sys.stdin.read())
        text = text.rstrip("\n")


        def words(s):
            s = re.sub(r"([a-z0-9])([A-Z])", r"\1 \2", s)       # camelCase → camel Case
            s = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode()
            return [w for w in re.split(r"[^A-Za-z0-9]+", s) if w]


        ways = {
            "upper": str.upper,
            "lower": str.lower,
            "title": lambda s: " ".join(w[:1].upper() + w[1:].lower() for w in s.split(" ")),
            "sentence": lambda s: "\n".join(line[:1].upper() + line[1:].lower() for line in s.split("\n")),
            "slug": lambda s: "-".join(w.lower() for w in words(s.replace("'", ""))),
            "snake": lambda s: "_".join(w.lower() for w in words(s)),
            "kebab": lambda s: "-".join(w.lower() for w in words(s)),
            "camel": lambda s: "".join(w.lower() if i == 0 else w[:1].upper() + w[1:].lower() for i, w in enumerate(words(s))),
            "pascal": lambda s: "".join(w[:1].upper() + w[1:].lower() for w in words(s)),
            "swap": str.swapcase,
        }
        if how not in ways:
            sys.exit(f"Which case? upper, lower, title, sentence, slug, snake, kebab, camel, pascal or swap; not \"{how}\".")
        if not text.strip():
            sys.exit("Which text? Give it after the case (text-case.py upper hello), or as the input.")
        print(ways[how](text))
        """# + "\n"),
        ("utilities/encode.py", #"""
        #!/usr/bin/env python3
        # Encodes or decodes text: Base64, a web address's %20 escapes, hex, or HTML's &amp; entities
        #
        # Input: How: base64, base64-decode, url, url-decode, hex, hex-decode, html, html-decode
        # Input text (optional): The text (or give it after the how)
        #
        #   encode.py base64 "hello world"       aGVsbG8gd29ybGQ=
        #   encode.py url "a b&c"                a%20b%26c
        #   echo "&lt;b&gt;" | encode.py html-decode     <b>
        import base64
        import binascii
        import html
        import sys
        import urllib.parse

        args = sys.argv[1:]
        HOW = ["base64", "base64-decode", "url", "url-decode", "hex", "hex-decode", "html", "html-decode"]
        if not args or args[0].lower().replace("_", "-") not in HOW:
            sys.exit("How? " + ", ".join(HOW) + " (encode.py base64 \"hello world\").")
        how = args[0].lower().replace("_", "-")
        text = " ".join(args[1:]) if len(args) > 1 else ("" if sys.stdin.isatty() else sys.stdin.read())
        if len(args) > 1 or how.endswith("-decode"):
            text = text.rstrip("\n")
        if not text:
            sys.exit("Which text? Give it after the how (encode.py url \"a b\"), or as the input.")

        try:
            if how == "base64":
                out = base64.b64encode(text.encode()).decode()
            elif how == "base64-decode":
                padded = text.strip() + "=" * (-len(text.strip()) % 4)
                out = base64.b64decode(padded, validate=True).decode("utf-8", "replace")
            elif how == "url":
                out = urllib.parse.quote(text, safe="")
            elif how == "url-decode":
                out = urllib.parse.unquote_plus(text)
            elif how == "hex":
                out = text.encode().hex()
            elif how == "hex-decode":
                out = bytes.fromhex("".join(text.split())).decode("utf-8", "replace")
            elif how == "html":
                out = html.escape(text, quote=True)
            else:
                out = html.unescape(text)
        except (binascii.Error, ValueError) as e:
            sys.exit(f"That isn't {how.replace('-decode', '')}: {e}")
        print(out)
        """# + "\n"),
        ("utilities/hash.sh", #"""
        #!/bin/bash
        # The SHA-256 (or SHA-1, or MD5) of some text or a file: to check a download, or make a fingerprint
        #
        # Input (optional): Which: sha256, sha1 or md5 (sha256 unless set)
        # Input (optional): The text, or a file's path (its input unless set)
        #
        #   hash.sh "hello world"                 its SHA-256
        #   hash.sh sha1 ~/Downloads/tool.zip     a file's SHA-1 (a path that exists is read as a file)
        #   echo -n hello | hash.sh md5           its input
        set -euo pipefail

        which=sha256
        case "${1:-}" in
          sha256|sha1|md5|sha512) which="$1"; shift ;;
          SHA256|SHA1|MD5|SHA512) which=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]'); shift ;;
        esac
        bits="${which#sha}"
        digest() {
          if [ "$which" = md5 ]; then
            if command -v md5 >/dev/null 2>&1; then md5 -q "$@"; else md5sum "$@" | cut -d ' ' -f 1; fi
          elif command -v shasum >/dev/null 2>&1; then shasum -a "$bits" "$@" | cut -d ' ' -f 1
          else "sha${bits}sum" "$@" | cut -d ' ' -f 1; fi
        }

        if [ $# -gt 0 ]; then
          given="$*"
          path="${given/#\~/$HOME}"
          if [ -f "$path" ]; then
            echo "$(digest "$path")  $(basename "$path")"
          else
            printf '%s' "$given" | digest
          fi
        elif [ ! -t 0 ]; then
          digest
        else
          echo "What should be hashed? Some text (hash.sh \"hello\"), a file (hash.sh ~/a.zip), or its input." >&2
          exit 1
        fi
        """# + "\n"),
        ("utilities/new-id.sh", #"""
        #!/bin/bash
        # A new unique id: a UUID (lowercase), or a short one of letters and digits
        #
        # Input (optional): short, or how many characters a short one has (a UUID unless set)
        #
        #   new-id.sh           6f1c2b1e-9a0d-4f3e-8c7a-2b5e9d1f0a3c
        #   new-id.sh short     k3x9qz2m (8 characters)
        #   new-id.sh 12        a short one, 12 long
        set -euo pipefail

        short() { # letters and digits from /dev/urandom (head closing the pipe early is fine)
          id=$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c "$1" || true)
          echo "$id"
        }

        case "${1:-}" in
          '')
            if command -v uuidgen >/dev/null 2>&1; then uuidgen | tr '[:upper:]' '[:lower:]'
            else python3 -c 'import uuid; print(uuid.uuid4())'; fi ;;
          short) short 8 ;;
          *[!0-9]*) echo "short, or a number of characters (new-id.sh 12); not \"$1\"." >&2; exit 1 ;;
          *) short "$1" ;;
        esac
        """# + "\n"),
        ("utilities/calc.py", #"""
        #!/usr/bin/env python3
        # Works out arithmetic: calc 12*7+3, calc "2^10", calc 15% of 80, calc sqrt(2), with pi, round, min, max
        #
        # Input: The sum to work out (12*7+3, 15% of 80, sqrt 2)
        # Why: It's worked out on this Mac, never run as code
        import ast
        import math
        import operator
        import re
        import sys

        OPS = {ast.Add: operator.add, ast.Sub: operator.sub, ast.Mult: operator.mul, ast.Div: operator.truediv,
               ast.FloorDiv: operator.floordiv, ast.Mod: operator.mod, ast.Pow: operator.pow,
               ast.USub: operator.neg, ast.UAdd: operator.pos}
        NAMES = {"pi": math.pi, "e": math.e, "tau": math.tau}
        FUNCS = {"sqrt": math.sqrt, "round": round, "abs": abs, "min": min, "max": max, "floor": math.floor,
                 "ceil": math.ceil, "log": math.log10, "ln": math.log, "sin": math.sin, "cos": math.cos, "tan": math.tan}


        def value(node):
            if isinstance(node, ast.Constant) and isinstance(node.value, (int, float)):
                return node.value
            if isinstance(node, ast.BinOp) and type(node.op) in OPS:
                left, right = value(node.left), value(node.right)
                if isinstance(node.op, ast.Pow) and abs(right) > 10000:
                    raise ValueError("that power is too big to work out")
                return OPS[type(node.op)](left, right)
            if isinstance(node, ast.UnaryOp) and type(node.op) in OPS:
                return OPS[type(node.op)](value(node.operand))
            if isinstance(node, ast.Name) and node.id in NAMES:
                return NAMES[node.id]
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id in FUNCS:
                return FUNCS[node.func.id](*[value(a) for a in node.args])
            raise ValueError("only numbers, + - * / ^ %, brackets and " + ", ".join(sorted(FUNCS)) + " work here")


        def tidy(text):
            t = text.lower().replace("×", "*").replace("÷", "/").replace("^", "**").replace(",", "")
            # 15% of 80 → 15/100*80; 20% → 0.2
            t = re.sub(r"(\d+(?:\.\d+)?)\s*%\s*of\s*", r"(\1/100)*", t)
            t = re.sub(r"(\d+(?:\.\d+)?)\s*%", r"(\1/100)", t)
            t = re.sub(r"\b(" + "|".join(FUNCS) + r")\s+(\d+(?:\.\d+)?)", r"\1(\2)", t)  # sqrt 2 → sqrt(2)
            t = re.sub(r"\bx\b", "*", t)
            return t


        def show(n):
            if isinstance(n, float):
                if n.is_integer() and abs(n) < 1e15:
                    return f"{int(n):,}"
                return f"{n:,.10g}"
            return f"{n:,}"


        sum_ = " ".join(sys.argv[1:]).strip() or sys.stdin.read().strip()
        if not sum_:
            print("What should be worked out? calc 12*7+3, calc 15% of 80, calc sqrt 2", file=sys.stderr)
            sys.exit(1)
        try:
            answer = value(ast.parse(tidy(sum_), mode="eval").body)
        except ZeroDivisionError:
            print("That divides by zero.", file=sys.stderr)
            sys.exit(1)
        except (SyntaxError, ValueError, TypeError, OverflowError) as e:
            print(f"Couldn't work out {sum_}: {e if not isinstance(e, SyntaxError) else 'it is not a sum I can read'}.", file=sys.stderr)
            sys.exit(1)
        print(show(answer))
        """# + "\n"),
        ("utilities/convert.py", #"""
        #!/usr/bin/env python3
        # Converts units: convert 5 km to miles, convert 72 f to c, convert 3 GB to MB, convert 2 cups to ml, convert 90 min to h
        #
        # Input: What to convert (5 km to miles)
        import re
        import sys

        # Each unit: its kind, and how many of the kind's base unit it is (temperatures are worked out apart).
        UNITS = {}


        def units(kind, table):
            for names, size in table:
                for n in names.split():
                    UNITS[n] = (kind, size)


        units("length", [("mm millimeter millimeters millimetre millimetres", 0.001), ("cm centimeter centimeters centimetre centimetres", 0.01),
                         ("m meter meters metre metres", 1), ("km kilometer kilometers kilometre kilometres", 1000),
                         ("in inch inches", 0.0254), ("ft foot feet", 0.3048), ("yd yard yards", 0.9144), ("mi mile miles", 1609.344),
                         ("nmi nauticalmile nauticalmiles", 1852)])
        units("weight", [("mg milligram milligrams", 0.001), ("g gram grams", 1), ("kg kilo kilos kilogram kilograms", 1000),
                         ("t tonne tonnes", 1e6), ("oz ounce ounces", 28.349523125), ("lb lbs pound pounds", 453.59237), ("st stone stones", 6350.29318)])
        units("volume", [("ml milliliter milliliters millilitre millilitres", 0.001), ("l liter liters litre litres", 1),
                         ("tsp teaspoon teaspoons", 0.00492892), ("tbsp tablespoon tablespoons", 0.0147868), ("floz", 0.0295735),
                         ("cup cups", 0.24), ("pt pint pints", 0.473176), ("qt quart quarts", 0.946353), ("gal gallon gallons", 3.78541)])
        units("speed", [("kmh kph km/h", 1 / 3.6), ("mph", 0.44704), ("m/s mps", 1), ("knot knots kn", 0.514444)])
        units("data", [("b byte bytes", 1), ("kb kilobyte kilobytes", 1e3), ("mb megabyte megabytes", 1e6), ("gb gigabyte gigabytes", 1e9),
                       ("tb terabyte terabytes", 1e12), ("kib", 1024), ("mib", 1024 ** 2), ("gib", 1024 ** 3), ("tib", 1024 ** 4)])
        units("time", [("ms millisecond milliseconds", 0.001), ("s sec secs second seconds", 1), ("min mins minute minutes", 60),
                       ("h hr hrs hour hours", 3600), ("d day days", 86400), ("wk week weeks", 604800), ("yr year years", 31557600)])
        units("area", [("m2 sqm", 1), ("km2", 1e6), ("ha hectare hectares", 1e4), ("acre acres", 4046.8564224), ("ft2 sqft", 0.09290304)])
        TEMPS = {"c": "c", "celsius": "c", "°c": "c", "f": "f", "fahrenheit": "f", "°f": "f", "k": "k", "kelvin": "k"}


        def to_celsius(v, u):
            return v if u == "c" else (v - 32) * 5 / 9 if u == "f" else v - 273.15


        def from_celsius(v, u):
            return v if u == "c" else v * 9 / 5 + 32 if u == "f" else v + 273.15


        def show(n):
            return f"{n:,.6g}" if abs(n) < 1e15 else f"{n:.4e}"


        text = " ".join(sys.argv[1:]).strip().replace("square ", "").replace("sq ", "sq")
        m = re.match(r"^\s*(-?[\d.,]+)\s*([^\s\d][^\s]*)\s+(?:to|in|into|as)\s+(.+?)\s*$", text, re.I)
        if not m:
            print("What should be converted? convert 5 km to miles, convert 72 f to c, convert 3 GB to MB", file=sys.stderr)
            sys.exit(1)
        amount = float(m.group(1).replace(",", ""))
        src, dst = m.group(2).lower(), m.group(3).replace(" ", "").lower()
        if src in TEMPS and dst in TEMPS:
            out = from_celsius(to_celsius(amount, TEMPS[src]), TEMPS[dst])
            print(f"{show(amount)} °{TEMPS[src].upper()} = {show(out)} °{TEMPS[dst].upper()}")
            sys.exit(0)
        for u in (src, dst):
            if u not in UNITS and u not in TEMPS:
                kinds = sorted({k for k, _ in UNITS.values()} | {"temperature"})
                print(f"I don't know the unit \"{u}\". I know {', '.join(kinds)}: km, mi, kg, lb, l, cup, GB, MiB, mph, h, °C, °F…", file=sys.stderr)
                sys.exit(1)
        if src in TEMPS or dst in TEMPS or UNITS[src][0] != UNITS[dst][0]:
            a = "temperature" if src in TEMPS else UNITS[src][0]
            b = "temperature" if dst in TEMPS else UNITS[dst][0]
            print(f"{src} is a {a} and {dst} is a {b}: they don't convert.", file=sys.stderr)
            sys.exit(1)
        out = amount * UNITS[src][1] / UNITS[dst][1]
        print(f"{show(amount)} {m.group(2)} = {show(out)} {m.group(3)}")
        """# + "\n"),
        ("utilities/json-format.py", #"""
        #!/usr/bin/env python3
        # Tidies JSON (indented, keys in order) and says where it's broken if it is: json-format < file.json, or JSON as words
        #
        # Input text: The JSON to tidy
        import json
        import sys

        text = " ".join(sys.argv[1:]) if sys.argv[1:] and sys.argv[1] != "--compact" else ""
        compact = "--compact" in sys.argv[1:]
        text = text or sys.stdin.read()
        if not text.strip():
            print("Give it JSON: as words, or as what it reads (json-format < data.json).", file=sys.stderr)
            sys.exit(1)
        try:
            data = json.loads(text)
        except json.JSONDecodeError as e:
            line = text.splitlines()[e.lineno - 1] if e.lineno - 1 < len(text.splitlines()) else ""
            print(f"It isn't valid JSON: {e.msg}, at line {e.lineno}, column {e.colno}:", file=sys.stderr)
            print("  " + line.strip()[:120], file=sys.stderr)
            sys.exit(1)
        if compact:
            print(json.dumps(data, separators=(",", ":"), ensure_ascii=False))
        else:
            print(json.dumps(data, indent=2, sort_keys=True, ensure_ascii=False))
        """# + "\n"),
        ("utilities/speed-test.sh", #"""
        #!/bin/bash
        # How fast this Mac's internet is: download, upload and responsiveness (macOS's own networkQuality, about 20 seconds)
        set -uo pipefail

        if ! command -v networkQuality >/dev/null 2>&1; then
          echo "Measuring needs macOS 12 or later (its networkQuality command)." >&2
          exit 1
        fi
        echo "Measuring (about 20 seconds)…" >&2
        out=$(networkQuality -s 2>&1) || { echo "Couldn't measure: $out" >&2; exit 1; }
        down=$(printf '%s\n' "$out" | awk -F': ' '/[Dd]ownlink capacity/ {print $2; exit}')
        up=$(printf '%s\n' "$out" | awk -F': ' '/[Uu]plink capacity/ {print $2; exit}')
        resp=$(printf '%s\n' "$out" | awk -F': ' '/[Rr]esponsiveness/ {print $2; exit}')
        echo "⬇️  Download: ${down:-unknown}"
        echo "⬆️  Upload: ${up:-unknown}"
        echo "⏱  Responsiveness: ${resp:-unknown}"
        """# + "\n"),
        ("utilities/network.sh", #"""
        #!/bin/bash
        # This Mac on its network: its address, the router, the DNS servers, and whether the internet answers
        set -uo pipefail

        iface=$(route -n get default 2>/dev/null | awk '/interface:/ {print $2}')
        router=$(route -n get default 2>/dev/null | awk '/gateway:/ {print $2}')
        if [ -z "$iface" ]; then
          echo "❌ Not connected to a network (no route to the internet)."
          exit 1
        fi
        address=$(ipconfig getifaddr "$iface" 2>/dev/null || true)
        dns=$(scutil --dns 2>/dev/null | awk '/nameserver\[[0-9]+\]/ {print $3}' | sort -u | head -3 | paste -sd ' ' -)
        echo "Connected through $iface"
        echo "This Mac: ${address:-unknown}"
        echo "Router: ${router:-unknown}"
        echo "DNS: ${dns:-unknown}"
        if ping -c 1 -t 3 1.1.1.1 >/dev/null 2>&1; then
          if host -W 3 apple.com >/dev/null 2>&1 || nslookup apple.com >/dev/null 2>&1; then
            echo "✅ The internet answers, and names are found."
          else
            echo "⚠️  The internet answers, but names aren't found: DNS is the trouble."
          fi
        else
          echo "❌ The internet doesn't answer (1.1.1.1 didn't reply): the router, or beyond it."
        fi
        """# + "\n"),
        ("utilities/keep-awake.sh", #"""
        #!/bin/bash
        # Keeps this Mac awake (no sleep, no screen saver) for a while: keep-awake 90 (minutes), keep-awake status, keep-awake stop
        #
        # Input (optional): How many minutes (60 unless set), or status, or stop
        set -uo pipefail

        state="${TMPDIR:-/tmp}/toolmactoolrun-keep-awake.pid"
        running() { [ -f "$state" ] && kill -0 "$(cat "$state")" 2>/dev/null; }

        case "${1:-60}" in
          status)
            if running; then echo "☕ Keeping awake (caffeinate, pid $(cat "$state"))."; else echo "Not keeping awake: the Mac sleeps as usual."; fi ;;
          stop)
            if running; then kill "$(cat "$state")" && rm "$state"; echo "Stopped: the Mac sleeps as usual again."
            else echo "It wasn't keeping awake."; fi ;;
          *[!0-9]*)
            echo "Give a number of minutes (keep-awake 90), or status, or stop." >&2; exit 1 ;;
          *)
            minutes="${1:-60}"
            if running; then kill "$(cat "$state")" 2>/dev/null; fi
            nohup caffeinate -dimsu -t $((minutes * 60)) >/dev/null 2>&1 &
            echo $! > "$state"
            until=$(date -v+"${minutes}"M '+%H:%M' 2>/dev/null || date -d "+${minutes} minutes" '+%H:%M')
            echo "☕ Keeping awake for $minutes minutes, until $until (keep-awake stop ends it sooner)." ;;
        esac
        """# + "\n"),
        ("utilities/port-check.sh", #"""
        #!/bin/bash
        # What's listening on a port (port-check 3000), or every port that's listening on this Mac, and which program has it
        #
        # Input (optional): A port number (every one unless set)
        set -uo pipefail

        if [ -n "${1:-}" ]; then
          case "$1" in *[!0-9]*) echo "A port is a number: port-check 3000" >&2; exit 1 ;; esac
          out=$(lsof -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $1" (pid "$2")"}' | sort -u)
          if [ -z "$out" ]; then echo "Nothing is listening on port $1: it's free."; else echo "Port $1 is taken by: $out"; fi
          exit 0
        fi
        out=$(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {n = split($9, a, ":"); print a[n]"\t"$1" (pid "$2")"}' | sort -n -u)
        if [ -z "$out" ]; then echo "No program is listening on a port."; exit 0; fi
        printf 'Port\tProgram\n%s\n' "$out"
        """# + "\n"),
        ("utilities/git-status-all.sh", #"""
        #!/bin/bash
        # Which of your git repositories have changes or commits not pushed yet (in ~/Code, ~/Developer, ~/Projects and ~/src, or a folder you name)
        #
        # Input (optional): A folder of repositories (your usual ones unless set)
        set -uo pipefail

        if ! command -v git >/dev/null 2>&1; then
          echo "This needs git: xcode-select --install" >&2; exit 1
        fi
        if [ $# -gt 0 ]; then roots=("$@"); else roots=("$HOME/Code" "$HOME/Developer" "$HOME/Projects" "$HOME/src"); fi
        # A path with your home folder as ~.
        pretty() { case "$1" in "$HOME"*) printf '~%s' "${1#"$HOME"}" ;; *) printf '%s' "$1" ;; esac; }
        found=0; busy=0
        IFS=$'\n'  # a folder's name may have spaces
        for root in "${roots[@]}"; do
          [ -d "$root" ] || continue
          for git_dir in $(find "$root" -maxdepth 3 -name .git -type d -prune 2>/dev/null | sort); do
            repo="${git_dir%/.git}"
            found=$((found + 1))
            branch=$(git -C "$repo" symbolic-ref --short -q HEAD 2>/dev/null || echo "detached")
            changed=$(git -C "$repo" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
            ahead=$(git -C "$repo" rev-list --count '@{u}..HEAD' 2>/dev/null || echo "")
            notes=""
            [ "$changed" != "0" ] && notes="$changed changed"
            [ -n "$ahead" ] && [ "$ahead" != "0" ] && notes="${notes:+$notes, }$ahead to push"
            if [ -n "$notes" ]; then
              busy=$((busy + 1))
              echo "✏️  $(pretty "$repo") ($branch): $notes"
            fi
          done
        done
        if [ "$found" = 0 ]; then
          where=""
          for r in "${roots[@]}"; do where="${where:+$where, }$(pretty "$r")"; done
          echo "No git repositories in $where: name the folder they're in (git-status-all ~/work)." >&2
          exit 1
        fi
        [ "$found" = 1 ] && noun="repository" || noun="repositories"
        echo "$found $noun, $busy with something to commit or push."
        """# + "\n"),
        ("utilities/qr-code.sh", #"""
        #!/bin/bash
        # Makes a QR code of a link or some text, saves it on your Desktop and opens it (to scan with a phone)
        #
        # Input: The link or text for the QR code
        set -euo pipefail

        text="$*"
        if [ -z "$text" ]; then echo "What should the QR code say? qr-code https://example.com" >&2; exit 1; fi
        encoded=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$text")
        file="$HOME/Desktop/QR $(date '+%Y-%m-%d %H.%M.%S').png"
        if ! curl -fsS --max-time 20 "https://api.qrserver.com/v1/create-qr-code/?size=600x600&margin=12&data=$encoded" -o "$file"; then
          echo "Couldn't make it (api.qrserver.com didn't answer): are you online?" >&2; exit 1
        fi
        command -v open >/dev/null 2>&1 && open "$file"
        echo "Saved: ~${file#"$HOME"}"
        """# + "\n"),
        ("utilities/dark-mode.sh", #"""
        #!/bin/bash
        # Turns Dark Mode on or off, or switches it: dark-mode, dark-mode on, dark-mode off, dark-mode status
        #
        # Input (optional): on, off or status (switches it unless set)
        set -uo pipefail

        ask() { osascript -e 'tell application "System Events" to tell appearance preferences to '"$1" 2>&1; }
        case "${1:-toggle}" in
          on) set_to="true" ;;
          off) set_to="false" ;;
          toggle|switch) set_to="not dark mode" ;;
          status)
            now=$(ask "get dark mode") || { echo "Couldn't ask: $now" >&2; exit 1; }
            [ "$now" = "true" ] && echo "🌙 Dark Mode is on." || echo "☀️ Dark Mode is off."; exit 0 ;;
          *) echo "dark-mode on, off, status, or nothing to switch it." >&2; exit 1 ;;
        esac
        if ! out=$(ask "set dark mode to $set_to"); then
          echo "Couldn't change it: $out" >&2
          echo "Fix: System Settings > Privacy & Security > Automation > Tool Mac Tool Run > turn on System Events." >&2
          exit 1
        fi
        now=$(ask "get dark mode")
        [ "$now" = "true" ] && echo "🌙 Dark Mode is on." || echo "☀️ Dark Mode is off."
        """# + "\n"),
        ("utilities/find-file.sh", #"""
        #!/bin/bash
        # Finds files by name with Spotlight, newest first: in your home folder, in a folder you name, or anywhere on this Mac
        #
        # Input: Part of the file's name (invoice, .pdf, "trip photos")
        # Why: Spotlight is asked for files with it in their name; nothing is opened or changed
        # Input (optional): Where to look: a folder, or everywhere (your home folder unless set)
        #
        #   find-file.sh invoice                   files with "invoice" in their name, in your home folder
        #   find-file.sh invoice ~/Documents       only in that folder (and the folders in it)
        #   find-file.sh invoice everywhere        anywhere on this Mac, apps and the system too
        #   find-file.sh --all invoice             every match, not just the newest 20
        set -uo pipefail

        limit=20
        if [ "${1:-}" = "--all" ]; then limit=0; shift; fi
        name="${1:-}"
        where="${2:-$HOME}"
        if [ -z "$name" ]; then
          echo "What's in the file's name? (find-file.sh invoice)" >&2
          exit 1
        fi
        where="${where/#\~/$HOME}"
        if [ "$where" != everywhere ]; then
          if [ ! -d "$where" ]; then
            echo "There's no folder $where" >&2
            exit 1
          fi
          where=$(cd "$where" && pwd)
        fi
        # A path with your home folder written as ~.
        tidy() { sed "s|^$HOME/|~/|; s|^$HOME\$|~|"; }

        # Spotlight when it's on (mdfind), else find, which walks the folder (slower, and the same answer).
        search() {
          if command -v mdfind >/dev/null 2>&1; then
            if [ "$where" = everywhere ]; then mdfind -name "$name"; else mdfind -onlyin "$where" -name "$name"; fi
            return
          fi
          local top="$where"
          [ "$top" = everywhere ] && top=/
          find "$top" \( -name '.*' -o -name node_modules -o -path "$HOME/Library" \) -prune -o -iname "*$name*" -print 2>/dev/null
        }

        # Newest first: each path after its last change, in seconds (BSD stat on a Mac, GNU stat elsewhere).
        if stat -f '%m' / >/dev/null 2>&1; then when=(stat -f '%m %N'); else when=(stat -c '%Y %n'); fi
        found=$(search | grep -v -e '/\.' -e "^$HOME/Library/" | head -5000 | tr '\n' '\0' | xargs -0 "${when[@]}" 2>/dev/null | sort -rn | cut -d' ' -f2-)
        if [ -z "$found" ]; then
          echo "No file with \"$name\" in its name in $(printf '%s\n' "$where" | tidy)." >&2
          exit 1
        fi
        count=$(printf '%s\n' "$found" | wc -l | tr -d ' ')
        if [ "$limit" -gt 0 ] && [ "$count" -gt "$limit" ]; then
          echo "$count found; the newest $limit (--all for every one):" >&2
          found=$(printf '%s\n' "$found" | head -n "$limit")
        fi
        printf '%s\n' "$found" | tidy
        """# + "\n"),
        ("utilities/spotlight.sh", #"""
        #!/bin/bash
        # Searches this Mac with Spotlight, as ⌘Space does: files with your words in their name or in what's written in them, newest first
        #
        # Input: The words to look for (tax return 2025, or --kind pdf tax return)
        # Why: Spotlight is asked for files with every one of the words in them; nothing is opened or changed
        #
        #   spotlight.sh tax return                 files with both words in their name or their text
        #   spotlight.sh --kind pdf tax return      only PDFs; kinds: pdf, image, video, audio, text, document,
        #                                           presentation, spreadsheet, code, folder, app, archive, email
        #   spotlight.sh --in ~/Documents budget    only in that folder
        #   spotlight.sh --kinds                    every kind, and what it is
        set -uo pipefail

        # Each kind, as Spotlight's content type (every file has its type's parents too: a .jpg is public.image).
        kind_type() {
          case "$1" in
            pdf|pdfs) echo com.adobe.pdf ;;
            image|images|photo|photos|picture|pictures) echo public.image ;;
            video|videos|movie|movies) echo public.movie ;;
            audio|music|song|songs|sound|sounds) echo public.audio ;;
            text|txt) echo public.plain-text ;;
            document|documents|doc|docs) echo public.composite-content ;;
            presentation|presentations|slides|keynote) echo public.presentation ;;
            spreadsheet|spreadsheets|sheet|sheets|excel|numbers) echo public.spreadsheet ;;
            code|source) echo public.source-code ;;
            folder|folders) echo public.folder ;;
            app|apps|application|applications) echo com.apple.application-bundle ;;
            archive|archives|zip|zips) echo public.archive ;;
            email|emails|mail) echo com.apple.mail.emlx ;;
            *) return 1 ;;
          esac
        }

        kind="" where=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --kinds)
              echo "pdf, image, video, audio, text, document (Word, Pages, RTF…), presentation, spreadsheet,"
              echo "code, folder, app, archive (zip and the like), email (Mail's own)"
              exit 0 ;;
            --kind) kind="${2:-}"; shift 2 || shift ;;
            --in) where="${2:-}"; shift 2 || shift ;;
            *) break ;;
          esac
        done
        if [ $# -eq 0 ]; then
          echo "What should Spotlight look for? (spotlight.sh tax return, or spotlight.sh --kind pdf tax return)" >&2
          exit 1
        fi
        if [ -n "$kind" ] && ! type_of_kind=$(kind_type "$(printf '%s' "$kind" | tr '[:upper:]' '[:lower:]')"); then
          echo "Spotlight has no kind \"$kind\". The kinds: pdf, image, video, audio, text, document, presentation, spreadsheet, code, folder, app, archive, email" >&2
          exit 1
        fi
        where="${where/#\~/$HOME}"
        if [ -n "$where" ] && [ ! -d "$where" ]; then
          echo "There's no folder $where" >&2
          exit 1
        fi
        if ! command -v mdfind >/dev/null 2>&1; then
          echo "Spotlight (mdfind) is macOS's: this needs a Mac." >&2
          exit 1
        fi

        # Every word, in the name or the text (any case, any accents), and the kind if one was given.
        query=""
        for word in "$@"; do
          word=$(printf '%s' "$word" | tr -d '"*\\')
          [ -z "$word" ] && continue
          part="(kMDItemDisplayName == \"*$word*\"cd || kMDItemTextContent == \"$word*\"cdw)"
          query="${query:+$query && }$part"
        done
        [ -n "${type_of_kind:-}" ] && query="${query:+$query && }kMDItemContentTypeTree == \"$type_of_kind\""
        if [ -n "$where" ]; then found=$(mdfind -onlyin "$where" "$query"); else found=$(mdfind "$query"); fi

        found=$(printf '%s\n' "$found" | grep -v -e '^$' -e '/\.' -e "^$HOME/Library/" | head -2000 | tr '\n' '\0' | xargs -0 stat -f '%m %N' 2>/dev/null | sort -rn | cut -d' ' -f2-)
        what="\"$*\"${kind:+ ($kind)}"
        if [ -z "$found" ]; then
          echo "Spotlight found nothing for $what." >&2
          echo "Spotlight only finds what it has indexed: System Settings > Spotlight says what it looks in." >&2
          exit 1
        fi
        count=$(printf '%s\n' "$found" | wc -l | tr -d ' ')
        [ "$count" -gt 25 ] && echo "$count found for $what; the newest 25:" >&2
        printf '%s\n' "$found" | head -n 25 | sed "s|^$HOME/|~/|"
        """# + "\n"),
        ("utilities/find-text.sh", #"""
        #!/bin/bash
        # Finds the files in a folder that have some text in them, and the lines it's on (your home folder's Documents unless one is named)
        #
        # Input: The text to look for (any case)
        # Why: The files are read, never changed; folders like .git and node_modules are skipped
        # Input (optional): A folder to look in (your Documents unless set)
        set -uo pipefail

        text="${1:-}"
        where="${2:-$HOME/Documents}"
        where="${where/#\~/$HOME}"
        if [ -z "$text" ]; then echo "What text? (find-text.sh \"TODO\" ~/Projects)" >&2; exit 1; fi
        if [ ! -d "$where" ]; then echo "There's no folder $where" >&2; exit 1; fi

        # ripgrep when it's installed (fast, and it skips what .gitignore says to), else grep.
        if command -v rg >/dev/null 2>&1; then
          found=$(rg --ignore-case --fixed-strings --line-number --max-columns 200 --max-count 3 -g '!node_modules' -- "$text" "$where" 2>/dev/null)
        else
          found=$(grep -rIinF --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=Library -m 3 -- "$text" "$where" 2>/dev/null | cut -c1-240)
        fi
        if [ -z "$found" ]; then
          echo "No file in $(printf '%s' "$where" | sed "s|^$HOME|~|") has \"$text\" in it." >&2
          exit 1
        fi
        files=$(printf '%s\n' "$found" | cut -d: -f1 | sort -u | wc -l | tr -d ' ')
        echo "$files file$( [ "$files" = 1 ] || echo s) with \"$text\" (3 lines each at most):" >&2
        printf '%s\n' "$found" | head -150 | sed "s|^$HOME/|~/|"
        """# + "\n"),
        ("utilities/file-info.sh", #"""
        #!/bin/bash
        # What Spotlight knows about a file: its kind, size, dates, where it was downloaded from, and its pages, pixels or length
        #
        # Input: A file (a path; ~ is your home folder)
        # Why: Its details are read (Spotlight's mdls, and the file itself); nothing is opened or changed
        set -uo pipefail

        file="${1:-}"
        file="${file/#\~/$HOME}"
        if [ -z "$file" ]; then
          echo "Which file? (file-info.sh ~/Downloads/report.pdf)" >&2
          exit 1
        fi
        if [ ! -e "$file" ]; then
          echo "There's no file $file" >&2
          exit 1
        fi

        echo "$(basename "$file")"
        echo "  Where:     $(cd "$(dirname "$file")" && pwd | sed "s|^$HOME|~|")"
        if [ -d "$file" ]; then
          echo "  Size:      $(du -sh "$file" 2>/dev/null | cut -f1) ($(find "$file" -type f 2>/dev/null | wc -l | tr -d ' ') files)"
        else
          echo "  Size:      $(du -h "$file" | cut -f1) ($(wc -c < "$file" | tr -d ' ') bytes)"
        fi
        if ! command -v mdls >/dev/null 2>&1; then
          echo "  Changed:   $(date -r "$file" '+%Y-%m-%d %H:%M' 2>/dev/null)"
          exit 0
        fi

        # One attribute, as text ("" when Spotlight has none: (null)).
        attr() {
          mdls -raw -name "$1" "$file" 2>/dev/null | tr -d '\0' | grep -v '^(null)$'
        }
        # A list attribute, its items on one line: ("a", "b") is a, b.
        list() {
          attr "$1" | tr -d '()"\n' | sed 's/^ *//; s/,  */, /g; s/ *$//'
        }
        line() { [ -n "$2" ] && printf '  %-10s %s\n' "$1:" "$2"; }

        line "Kind" "$(attr kMDItemKind)"
        line "Created" "$(attr kMDItemContentCreationDate | cut -c1-16)"
        line "Changed" "$(attr kMDItemContentModificationDate | cut -c1-16)"
        line "Opened" "$(attr kMDItemLastUsedDate | cut -c1-16)"
        line "From" "$(list kMDItemWhereFroms)"
        line "Pages" "$(attr kMDItemNumberOfPages)"
        w=$(attr kMDItemPixelWidth) h=$(attr kMDItemPixelHeight)
        [ -n "$w" ] && [ -n "$h" ] && line "Pixels" "$w × $h"
        secs=$(attr kMDItemDurationSeconds)
        [ -n "$secs" ] && line "Length" "$(printf '%.0f' "$secs" | awk '{ printf "%d:%02d", $1 / 60, $1 % 60 }')"
        line "By" "$(list kMDItemAuthors)"
        line "Tags" "$(list kMDItemUserTags)"
        exit 0
        """# + "\n"),
        ("utilities/recent-downloads.sh", #"""
        #!/bin/bash
        # The newest files in your Downloads (10 unless you say how many): when each came, how big it is, and the site it came from
        #
        # Input (optional): How many (10 unless set)
        set -uo pipefail

        count="${1:-10}"
        case "$count" in *[!0-9]*|"") echo "Give a number: recent-downloads 20" >&2; exit 1 ;; esac
        dir="$HOME/Downloads"
        if [ ! -d "$dir" ]; then echo "There's no Downloads folder in your home folder." >&2; exit 1; fi

        if stat -f '%m' / >/dev/null 2>&1; then when=(stat -f '%m %N'); else when=(stat -c '%Y %n'); fi
        newest=$(find "$dir" -mindepth 1 -maxdepth 1 ! -name '.*' -print0 2>/dev/null | xargs -0 "${when[@]}" 2>/dev/null | sort -rn | head -n "$count")
        if [ -z "$newest" ]; then echo "Your Downloads folder is empty."; exit 0; fi

        now=$(date +%s)
        printf '%s\n' "$newest" | while read -r stamp path; do
          age=$(( (now - stamp) / 60 ))
          if [ "$age" -lt 60 ]; then ago="${age} min ago"
          elif [ "$age" -lt 1440 ]; then ago="$(( age / 60 )) h ago"
          else ago="$(( age / 1440 )) days ago"; fi
          size=$(du -sh "$path" 2>/dev/null | cut -f1)
          # Where it came from: the address the browser saved with it (Spotlight's kMDItemWhereFroms), its site.
          from=""
          if command -v mdls >/dev/null 2>&1; then
            from=$(mdls -raw -name kMDItemWhereFroms "$path" 2>/dev/null | tr -d '\0' | grep -o 'https\{0,1\}://[^/"]*' | head -1 | sed 's|^https\{0,1\}://||')
          fi
          printf '%s  ·  %s  ·  %s%s\n' "$(basename "$path")" "$size" "$ago" "${from:+  ·  from $from}"
        done
        """# + "\n"),
        ("utilities/screenshots.sh", #"""
        #!/bin/bash
        # Your screenshots, newest first, found by Spotlight wherever they were saved (10 unless you say how many)
        #
        # Input (optional): How many, or latest (just the newest one's path), or open (opens the newest)
        #
        #   screenshots.sh              the 10 newest, with when each was taken
        #   screenshots.sh 30           the 30 newest
        #   screenshots.sh latest       the newest one's path, alone (for a flow)
        #   screenshots.sh open         opens the newest in Preview
        set -uo pipefail

        what="${1:-10}"
        case "$what" in
          latest|open) count=1 ;;
          *[!0-9]*|"") echo "Give a number, latest, or open: screenshots 5" >&2; exit 1 ;;
          *) count="$what" ;;
        esac
        if ! command -v mdfind >/dev/null 2>&1; then
          echo "Spotlight (mdfind) is macOS's: this needs a Mac." >&2
          exit 1
        fi

        # macOS marks every screenshot it takes (kMDItemIsScreenCapture), whatever it's called and wherever it went.
        found=$(mdfind 'kMDItemIsScreenCapture == 1' | grep -v '/\.' | tr '\n' '\0' | xargs -0 stat -f '%m %N' 2>/dev/null | sort -rn | head -n "$count")
        if [ -z "$found" ]; then
          echo "Spotlight found no screenshots (⇧⌘3 or ⇧⌘4 takes one; ⇧⌘5 says where they go)." >&2
          exit 1
        fi
        case "$what" in
          latest) printf '%s\n' "$found" | cut -d' ' -f2- ;;
          open)
            newest=$(printf '%s\n' "$found" | cut -d' ' -f2-)
            open "$newest"
            echo "Opened $(basename "$newest")" ;;
          *)
            printf '%s\n' "$found" | while read -r stamp path; do
              printf '%s  ·  %s\n' "$(date -r "$stamp" '+%a %d %b %H:%M')" "$(printf '%s' "$path" | sed "s|^$HOME/|~/|")"
            done ;;
        esac
        """# + "\n"),
        ("utilities/large-files.sh", #"""
        #!/bin/bash
        # The biggest files in your home folder (or a folder you name), found by Spotlight: everything over a size you give (1 GB unless set), biggest first
        #
        # Input (optional): The smallest size to list: 500MB, 2GB (1GB unless set)
        # Input (optional): A folder to look in (your home folder unless set)
        set -uo pipefail

        size="${1:-1GB}"
        where="${2:-$HOME}"
        where="${where/#\~/$HOME}"
        number=$(printf '%s' "$size" | tr -d ' ' | tr '[:lower:]' '[:upper:]' | sed -E 's/I?B$//')
        digits="${number%[KMGT]}"
        case "${number#"$digits"}" in
          K) unit=1024 ;;
          M) unit=1048576 ;;
          G) unit=1073741824 ;;
          T) unit=1099511627776 ;;
          *) unit="" ;;
        esac
        case "$digits" in
          ""|*[!0-9]*) unit="" ;;
        esac
        if [ -z "$unit" ]; then
          echo "Give a size in whole KB, MB, GB or TB: large-files 500MB" >&2
          exit 1
        fi
        bytes=$(( digits * unit ))
        if [ ! -d "$where" ]; then echo "There's no folder $where" >&2; exit 1; fi

        # Spotlight's index when there is one; else find walks the folder (slower, and the same answer).
        if command -v mdfind >/dev/null 2>&1; then
          found=$(mdfind -onlyin "$where" "kMDItemFSSize > $bytes" | tr '\n' '\0' | xargs -0 stat -f '%z %N' 2>/dev/null)
        else
          found=$(find "$where" -type f -size +"$(( bytes / 1024 ))"k -print0 2>/dev/null | xargs -0 stat -c '%s %n' 2>/dev/null)
        fi
        found=$(printf '%s\n' "$found" | grep -v -e '^$' -e '/\.' | sort -rn | head -30)
        if [ -z "$found" ]; then
          echo "Nothing over $size in $(printf '%s' "$where" | sed "s|^$HOME|~|")."
          exit 0
        fi
        printf '%s\n' "$found" | while read -r bytes path; do
          printf '%8s  %s\n' "$(awk -v b="$bytes" 'BEGIN { split("B KB MB GB TB", u); i = 1; while (b >= 1024 && i < 5) { b /= 1024; i++ } printf (i == 1 ? "%d %s" : "%.1f %s"), b, u[i] }')" \
            "$(printf '%s' "$path" | sed "s|^$HOME/|~/|")"
        done
        """# + "\n"),
        ("utilities/find-duplicates.py", #"""
        #!/usr/bin/env python3
        # Finds files that are exact copies of each other in a folder and the folders in it (your Downloads unless one is named), and how much room the copies take
        #
        # Input (optional): A folder to look in (your Downloads unless set)
        #
        # Nothing is moved or deleted: it lists each set of copies, the newest first, so you can choose.
        import hashlib
        import os
        import sys

        SKIP = {".git", "node_modules", "Library", ".Trash"}


        def human(n):
            for unit in ("B", "KB", "MB", "GB"):
                if n < 1024:
                    return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
                n /= 1024
            return f"{n:.1f} TB"


        def digest(path):
            h = hashlib.sha256()
            with open(path, "rb") as f:
                for block in iter(lambda: f.read(1 << 20), b""):
                    h.update(block)
            return h.hexdigest()


        def main():
            home = os.path.expanduser("~")
            folder = os.path.expanduser(sys.argv[1]) if len(sys.argv) > 1 else os.path.join(home, "Downloads")
            if not os.path.isdir(folder):
                print(f"There's no folder {folder}", file=sys.stderr)
                return 1
            # Only files of the same size can be copies: they alone are read.
            by_size = {}
            for root, dirs, files in os.walk(folder):
                dirs[:] = [d for d in dirs if d not in SKIP and not d.startswith(".")]
                for name in files:
                    if name.startswith("."):
                        continue
                    path = os.path.join(root, name)
                    try:
                        if os.path.islink(path):
                            continue
                        size = os.path.getsize(path)
                    except OSError:
                        continue
                    if size > 0:
                        by_size.setdefault(size, []).append(path)
            sets = []
            for size, paths in by_size.items():
                if len(paths) < 2:
                    continue
                by_hash = {}
                for p in paths:
                    try:
                        by_hash.setdefault(digest(p), []).append(p)
                    except OSError:
                        continue
                sets += [(size, group) for group in by_hash.values() if len(group) > 1]
            shown = folder.replace(home, "~", 1)
            if not sets:
                print(f"No copies in {shown}: every file is different.")
                return 0
            sets.sort(key=lambda s: s[0] * (len(s[1]) - 1), reverse=True)
            wasted = sum(size * (len(group) - 1) for size, group in sets)
            print(f"{len(sets)} set{'s' if len(sets) != 1 else ''} of copies in {shown}; the copies take {human(wasted)}:")
            for size, group in sets[:40]:
                group.sort(key=lambda p: os.path.getmtime(p), reverse=True)
                print(f"\n{human(size)} × {len(group)}")
                for p in group:
                    print("  " + p.replace(home, "~", 1))
            return 0


        if __name__ == "__main__":
            sys.exit(main())
        """# + "\n"),
        ("utilities/open-file.sh", #"""
        #!/bin/bash
        # Opens a file with its app (or one you name), or shows it in the Finder, or previews it with Quick Look
        #
        # Input: A file (a path; ~ is your home folder)
        # Why: It's opened, shown or previewed, never changed
        # Input (optional): reveal (show it in the Finder), look (Quick Look), or an app to open it with
        #
        #   open-file.sh ~/Downloads/report.pdf           with its own app (Preview, for a PDF)
        #   open-file.sh ~/Downloads/report.pdf reveal    selected in a Finder window
        #   open-file.sh ~/Downloads/photo.jpg look       a Quick Look preview (Space in the Finder)
        #   open-file.sh ~/notes.txt "Visual Studio Code" with that app
        set -uo pipefail

        file="${1:-}"
        file="${file/#\~/$HOME}"
        how="${2:-}"
        if [ -z "$file" ]; then echo "Which file? (open-file.sh ~/Downloads/report.pdf)" >&2; exit 1; fi
        if [ ! -e "$file" ]; then echo "There's no file $file" >&2; exit 1; fi
        if ! command -v open >/dev/null 2>&1; then echo "Opening files needs macOS (open)." >&2; exit 1; fi

        name=$(basename "$file")
        case "$how" in
          "") open "$file" && echo "Opened $name" ;;
          reveal|finder|show) open -R "$file" && echo "Showing $name in the Finder" ;;
          look|preview|quicklook) qlmanage -p "$file" >/dev/null 2>&1 & echo "Previewing $name (Quick Look)" ;;
          *)
            if ! open -a "$how" "$file" 2>/dev/null; then
              echo "Couldn't open $name with \"$how\": is that the app's name, as in Applications?" >&2
              exit 1
            fi
            echo "Opened $name in $how" ;;
        esac
        """# + "\n"),
        ("utilities/library.py", #"""
        #!/usr/bin/env python3
        # Your notes library: add, list, search, read, change and remove notes (plain text files you can open anywhere)
        #
        # Input: What to do: add, list, search, read, append, replace, rename, star, unstar, remove, restore, where
        # Input (optional): The note (its title, or its number from list), or the words to search for
        # Input (optional): The text (to add, append or replace with), or the new title
        # Input text (optional): The text, when it's long (instead of the third argument)
        #
        #   library.py add "Shopping" "eggs, milk"      a new note called Shopping
        #   library.py list                             every note, newest first, with its number
        #   library.py list starred                     only the starred ones
        #   library.py search budget march              notes with all those words
        #   library.py read Shopping                    a note in full (or: read 3)
        #   library.py append Shopping "bread"          adds a line to it
        #   library.py replace Shopping "just coffee"   its text, all of it, replaced
        #   library.py rename Shopping "Groceries"
        #   library.py star Groceries | unstar Groceries
        #   library.py remove Groceries                 to the library's trash (restore Groceries brings it back)
        #   library.py where                            the folder they're kept in
        # Each note is a text file in ~/Documents/Library (LIBRARY_DIR to keep them elsewhere).
        import datetime
        import os
        import re
        import sys

        ROOT = os.path.expanduser(os.environ.get("LIBRARY_DIR") or "~/Documents/Library")
        TRASH = os.path.join(ROOT, ".trash")
        HELP = "What to do: add, list, search, read, append, replace, rename, star, unstar, remove, restore or where."


        def now():
            return datetime.datetime.now().replace(microsecond=0).isoformat(sep=" ")


        def slug(title):
            s = re.sub(r"[^\w\s-]", "", title, flags=re.UNICODE).strip().lower()
            return re.sub(r"[\s_]+", "-", s)[:60] or "note"


        def parse(path):
            with open(path, encoding="utf-8") as f:
                raw = f.read()
            meta, text = {}, raw
            if raw.startswith("---\n"):
                head, sep, rest = raw[4:].partition("\n---\n")
                if sep:
                    for line in head.splitlines():
                        key, _, value = line.partition(":")
                        meta[key.strip()] = value.strip()
                    text = rest
            stamp = datetime.datetime.fromtimestamp(os.path.getmtime(path)).replace(microsecond=0).isoformat(sep=" ")
            return {
                "path": path,
                "title": meta.get("title") or os.path.splitext(os.path.basename(path))[0],
                "created": meta.get("created") or stamp,
                "changed": meta.get("changed") or stamp,
                "starred": meta.get("starred") == "yes",
                "text": text.strip("\n"),
            }


        def save(note):
            os.makedirs(os.path.dirname(note["path"]), exist_ok=True)
            head = f"---\ntitle: {note['title']}\ncreated: {note['created']}\nchanged: {note['changed']}\nstarred: {'yes' if note['starred'] else 'no'}\n---\n"
            tmp = note["path"] + ".part"
            with open(tmp, "w", encoding="utf-8") as f:
                f.write(head + note["text"].rstrip("\n") + "\n")
            os.replace(tmp, note["path"])


        def notes(folder=ROOT):
            if not os.path.isdir(folder):
                return []
            found = [parse(os.path.join(folder, n)) for n in os.listdir(folder) if n.endswith(".md")]
            return sorted(found, key=lambda n: n["changed"], reverse=True)


        def find(which, folder=ROOT):
            """The note a title, a part of one, or a number from list means."""
            all_notes = notes(folder)
            if not which:
                sys.exit("Say which note: its title, or its number from list.")
            if which.isdigit() and 1 <= int(which) <= len(all_notes):
                return all_notes[int(which) - 1]
            key = which.strip().lower()
            exact = [n for n in all_notes if n["title"].lower() == key]
            if exact:
                return exact[0]
            near = [n for n in all_notes if key in n["title"].lower()]
            if len(near) == 1:
                return near[0]
            if len(near) > 1:
                sys.exit(f"More than one note has \"{which}\" in its title: " + "; ".join(n["title"] for n in near[:10]) + ". Say which.")
            sys.exit(f"There's no note called \"{which}\"." + (" The notes: " + "; ".join(n["title"] for n in all_notes[:20]) + "." if all_notes else " The library is empty."))


        def line(i, n):
            first = " ".join(n["text"].split())[:80]
            star = " ★" if n["starred"] else ""
            return f"{i}. {n['title']}{star} ({n['changed'][:16]}){': ' + first if first else ''}"


        def free_path(title, folder=ROOT):
            base = os.path.join(folder, slug(title))
            path, k = base + ".md", 2
            while os.path.exists(path):
                path, k = f"{base}-{k}.md", k + 1
            return path


        def text_from(args, start):
            if len(args) > start:
                return " ".join(args[start:])
            if not sys.stdin.isatty():
                return sys.stdin.read().strip("\n")
            return ""


        def main(args):
            if not args:
                sys.exit(HELP)
            what, rest = args[0].lower(), args[1:]
            if what in ("add", "new", "note", "save"):
                if not rest:
                    sys.exit("Give the note a title (and its text).")
                title = rest[0].strip()
                text = text_from(rest, 1)
                if any(n["title"].lower() == title.lower() for n in notes()):
                    sys.exit(f"There's already a note called \"{title}\": append to it, replace it, or pick another title.")
                n = {"path": free_path(title), "title": title, "created": now(), "changed": now(), "starred": False, "text": text}
                save(n)
                print(f"Added \"{title}\" to the library ({len(text.split())} words).")
            elif what in ("list", "ls", "all"):
                all_notes = notes()
                shown = [n for n in all_notes if n["starred"]] if rest and rest[0].lower() in ("starred", "star", "stars") else all_notes
                if not shown:
                    print("The library is empty." if not all_notes else "No starred notes.")
                for i, n in enumerate(all_notes, 1):
                    if n in shown:
                        print(line(i, n))
            elif what in ("search", "find"):
                words = [w.lower() for w in rest]
                if not words:
                    sys.exit("Say what to search for.")
                hits = [(i, n) for i, n in enumerate(notes(), 1) if all(w in (n["title"] + " " + n["text"]).lower() for w in words)]
                if not hits:
                    print(f"No note has {' and '.join(repr(w) for w in words)}.")
                for i, n in hits:
                    print(line(i, n))
            elif what in ("read", "show", "open", "get"):
                n = find(" ".join(rest))
                print(f"{n['title']}{' ★' if n['starred'] else ''} (written {n['created'][:16]}, changed {n['changed'][:16]})\n")
                print(n["text"] or "(empty)")
            elif what in ("append", "add-to", "addto"):
                n = find(rest[0] if rest else "")
                text = text_from(rest, 1)
                if not text:
                    sys.exit("Give the text to add.")
                n["text"] = (n["text"] + "\n" if n["text"] else "") + text
                n["changed"] = now()
                save(n)
                print(f"Added to \"{n['title']}\".")
            elif what in ("replace", "set", "edit", "change"):
                n = find(rest[0] if rest else "")
                text = text_from(rest, 1)
                if not text:
                    sys.exit("Give the new text (to empty it, remove it instead).")
                n["text"] = text
                n["changed"] = now()
                save(n)
                print(f"Replaced the text of \"{n['title']}\".")
            elif what == "rename":
                if len(rest) < 2:
                    sys.exit("Say which note, and its new title.")
                n = find(rest[0])
                old, n["title"], n["changed"] = n["title"], " ".join(rest[1:]).strip(), now()
                save(n)
                print(f"Renamed \"{old}\" to \"{n['title']}\".")
            elif what in ("star", "unstar"):
                n = find(" ".join(rest))
                n["starred"] = what == "star"
                save(n)
                print(f"{'Starred' if n['starred'] else 'Unstarred'} \"{n['title']}\".")
            elif what in ("remove", "delete", "trash"):
                n = find(" ".join(rest))
                os.makedirs(TRASH, exist_ok=True)
                os.replace(n["path"], free_path(n["title"], TRASH))
                print(f"Moved \"{n['title']}\" to the library's trash (restore \"{n['title']}\" brings it back).")
            elif what in ("restore", "undelete"):
                n = find(" ".join(rest), TRASH)
                target = free_path(n["title"])
                os.replace(n["path"], target)
                print(f"Restored \"{n['title']}\".")
            elif what in ("where", "folder"):
                print(ROOT)
            else:
                sys.exit(f"I don't know \"{what}\". {HELP}")


        main(sys.argv[1:])
        """# + "\n"),
        ("utilities/selected-text.straw", #"""
        # What's selected (highlighted) on the page in front of Chrome, as plain text: in the page, or in the field you're typing in
        #
        # Straw: other scripts and flows build on it (define it, translate it, say it out loud).
        js "const f = document.activeElement; const inField = f && typeof f.selectionStart === 'number' && f.selectionEnd > f.selectionStart; const t = (inField ? f.value.slice(f.selectionStart, f.selectionEnd) : String(getSelection())).trim(); if (!t) throw new Error('nothing is selected on the page in front of Chrome: select some words first'); return t"
        """# + "\n"),
        ("utilities/page-word-count.straw", #"""
        # How long the page in front of Chrome takes to read: its words, and the minutes at 230 words a minute
        #
        # Straw: the article (or the page's main part) is counted, not its menus.
        read title into title
        js "const words = (document.querySelector('article') || document.querySelector('main') || document.body).innerText.split(/\s+/).filter(Boolean).length; return words + ' words, about ' + Math.max(1, Math.round(words / 230)) + ' min to read'" into count
        print "{title}: {count}"
        """# + "\n"),
        ("utilities/library.py", #"""
        #!/usr/bin/env python3
        # The notes in LIBRARY on your Desktop, by name: list, read, write, add to, search, delete (to its Trash) and restore them
        #
        # Input (optional): What to do, then its words (with nothing, every note)
        #
        #   library.py                          every note, A to Z, with when it changed
        #   library.py read groceries           a note's text (its name, without .md)
        #   library.py write groceries - eggs   creates it, or replaces its text (the words, or the input)
        #   library.py new "Trip to Lagos"      a new note (not if the name is taken), starting with its name as a heading
        #   library.py append journal Ran 5k    adds a line at its end (creating it if it isn't there)
        #   library.py search bank account      every line with the words on it, in every note, the best first
        #   library.py find bank account        just the names of the notes with them, the best first
        #   library.py recent 5                 the latest changed
        #   library.py rename old new · copy a b · open groceries · stats · path
        #   library.py delete draft             to the library's Trash, as "draft (1).md" (then 2, 3…)
        #   library.py trash                    what's in the Trash · restore draft [number] [as NAME]
        #
        # The same library the app's Library board shows and its API serves (/api/library).
        import datetime
        import json
        import os
        import re
        import subprocess
        import sys
        import tempfile
        import unicodedata

        EXT = "md"
        ROOT = os.path.expanduser(os.environ.get("TMR_LIBRARY") or "~/Desktop/LIBRARY")
        TRASH = os.path.join(ROOT, "Trash")
        INDEX = os.path.join(TRASH, ".index.json")


        class Problem(Exception):
            pass


        def fold(s):
            s = unicodedata.normalize("NFKD", s)
            return "".join(c for c in s if not unicodedata.combining(c)).casefold()


        def key(name):
            k = unicodedata.normalize("NFC", name.strip())
            if k.lower().endswith("." + EXT):
                k = k[: -len(EXT) - 1].strip()
            if not k:
                raise Problem("A note needs a name.")
            if any(c in k for c in "/:\\") or k.startswith(".") or any(ord(c) < 32 for c in k):
                raise Problem(f'"{k}" can\'t be a name: any words but / and :, not starting with a dot.')
            if k.lower() == "trash":
                raise Problem("Trash is the library's own Trash folder.")
            return k


        def notes():
            try:
                files = os.listdir(ROOT)
            except FileNotFoundError:
                return []
            out = []
            for f in files:
                p = os.path.join(ROOT, f)
                if not f.startswith(".") and f.lower().endswith("." + EXT) and os.path.isfile(p):
                    out.append((unicodedata.normalize("NFC", f[: -len(EXT) - 1]), p))
            return sorted(out, key=lambda n: fold(n[0]))


        def find(name):
            """The note of that name, as the folder lists it (on a Mac, GROCERIES.md is groceries.md too)."""
            k = key(name)
            found = notes()
            for n, p in found:
                if n == k:
                    return n, p
            for n, p in found:
                if fold(n) == fold(k):
                    return n, p
            return None


        def existing(name):
            found = find(name)
            if found:
                return found
            k = key(name)
            near = [n for n, _ in notes() if fold(k) in fold(n) or fold(n) in fold(k) or fold(n)[:5] == fold(k)[:5]]
            raise Problem(f"There's no note called {k}." + (" Near it: " + ", ".join(near[:5]) if near else " (library.py lists them)"))


        def read_text(path):
            with open(path, encoding="utf-8", errors="replace") as f:
                return f.read()


        def save(path, text):
            os.makedirs(ROOT, exist_ok=True)
            fd, tmp = tempfile.mkstemp(dir=ROOT, prefix=".writing-")
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write(text)
            os.replace(tmp, path)


        def given_text(words):
            """The words after the name, else what was piped in (by a flow, or a terminal's |)."""
            if words:
                return " ".join(words)
            if not sys.stdin.isatty():
                return sys.stdin.read()
            return ""


        def ago(t):
            s = (datetime.datetime.now() - datetime.datetime.fromtimestamp(t)).total_seconds()
            if s < 90:
                return "just now"
            if s < 3600:
                return f"{int(s // 60)} min ago"
            if s < 86400:
                return f"{int(s // 3600)} h ago"
            return f"{int(s // 86400)} days ago"


        def load_index():
            try:
                with open(INDEX, encoding="utf-8") as f:
                    return json.load(f)
            except (OSError, ValueError):
                return {}


        def save_index(index):
            os.makedirs(TRASH, exist_ok=True)
            with open(INDEX, "w", encoding="utf-8") as f:
                json.dump(index, f, indent=2, sort_keys=True)


        def trashed():
            index = load_index()
            out = []
            try:
                files = os.listdir(TRASH)
            except FileNotFoundError:
                return []
            for f in files:
                if f.startswith(".") or not f.lower().endswith("." + EXT):
                    continue
                p = os.path.join(TRASH, f)
                known = index.get(f)
                if known:
                    name, number, when = known["name"], known["number"], known["deleted"]
                else:
                    m = re.match(r"^(.*) \((\d+)\)$", f[: -len(EXT) - 1])
                    name, number = (m.group(1), int(m.group(2))) if m else (f[: -len(EXT) - 1], 1)
                    when = datetime.datetime.fromtimestamp(os.path.getmtime(p), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
                out.append({"name": name, "number": number, "file": f, "path": p, "deleted": when})
            return sorted(out, key=lambda t: (t["deleted"], t["number"]), reverse=True)


        def search(words, names_only=False):
            terms = re.findall(r'"([^"]+)"|(\S+)', " ".join(words))
            terms = [fold(a or b) for a, b in terms]
            hits = []
            for name, path in notes():
                text = read_text(path)
                fname, ftext = fold(name), fold(text)
                if not all(t in fname or t in ftext for t in terms):
                    continue
                score = sum(fname.count(t) * 10 + ftext.count(t) for t in terms)
                lines = [(k + 1, line.strip()) for k, line in enumerate(text.split("\n")) if any(t in fold(line) for t in terms)]
                hits.append((score, os.path.getmtime(path), name, lines))
            hits.sort(key=lambda h: (-h[0], -h[1]))
            return hits


        def main(argv):
            what = argv[0].lower() if argv else "list"
            rest = argv[1:]
            if what in ("list", "ls", "all"):
                found = notes()
                if not found:
                    print(f"The library is empty: {ROOT.replace(os.path.expanduser('~'), '~')} (library.py new NAME makes a note)")
                    return 0
                for name, path in found:
                    print(f"{name}  ·  {ago(os.path.getmtime(path))}")
            elif what == "read":
                name, path = existing(" ".join(rest))
                sys.stdout.write(read_text(path))
            elif what in ("write", "new", "create"):
                if not rest:
                    raise Problem(f"Which note? (library.py {what} NAME words…)")
                k = key(rest[0])
                found = find(k)
                text = given_text(rest[1:])
                if what != "write" and found:
                    raise Problem(f"There's already a note called {found[0]}.")
                if what != "write" and not text:
                    text = f"# {k}\n"
                path = found[1] if found else os.path.join(ROOT, k + "." + EXT)
                save(path, text if text.endswith("\n") or not text else text + "\n")
                print(f"{'Wrote' if found else 'Created'} {found[0] if found else k}")
            elif what in ("append", "add"):
                if not rest:
                    raise Problem("Which note? (library.py append NAME words…)")
                text = given_text(rest[1:])
                if not text:
                    raise Problem("What should be added? (library.py append NAME words…)")
                found = find(rest[0])
                now = read_text(found[1]) if found else ""
                if now and not now.endswith("\n"):
                    now += "\n"
                path = found[1] if found else os.path.join(ROOT, key(rest[0]) + "." + EXT)
                save(path, now + text + ("" if text.endswith("\n") else "\n"))
                print(f"Added to {found[0] if found else key(rest[0])}")
            elif what in ("search", "grep"):
                if not rest:
                    raise Problem('What should be searched for? (library.py search words, or "a phrase")')
                hits = search(rest)
                if not hits:
                    print(f"No note has {' '.join(rest)} in it.", file=sys.stderr)
                    return 1
                for _, _, name, lines in hits:
                    if not lines:
                        print(f"{name}: (in its name)")
                    for number, line in lines[:5]:
                        print(f"{name}:{number}: {line[:240]}")
            elif what == "find":
                if not rest:
                    raise Problem("What should be found? (library.py find words)")
                hits = search(rest)
                if not hits:
                    print(f"No note has {' '.join(rest)} in it.", file=sys.stderr)
                    return 1
                for _, _, name, _ in hits:
                    print(name)
            elif what in ("recent", "latest"):
                count = int(rest[0]) if rest and rest[0].isdigit() else 10
                for name, path in sorted(notes(), key=lambda n: -os.path.getmtime(n[1]))[:count]:
                    print(f"{name}  ·  {ago(os.path.getmtime(path))}")
            elif what in ("rename", "move", "copy"):
                if len(rest) < 2:
                    raise Problem(f"library.py {what} OLD NEW")
                name, path = existing(rest[0])
                new = key(" ".join(rest[1:]))
                there = find(new)
                if there and fold(there[0]) != fold(name):
                    raise Problem(f"There's already a note called {there[0]}.")
                target = os.path.join(ROOT, new + "." + EXT)
                if what == "copy":
                    if there:
                        raise Problem(f"There's already a note called {there[0]}.")
                    save(target, read_text(path))
                    print(f"Copied {name} to {new}")
                else:
                    os.replace(path, target)
                    print(f"Renamed {name} to {new}")
            elif what in ("delete", "remove", "trash-it"):
                name, path = existing(" ".join(rest))
                os.makedirs(TRASH, exist_ok=True)
                number = max([t["number"] for t in trashed() if fold(t["name"]) == fold(name)] or [0]) + 1
                while os.path.exists(os.path.join(TRASH, f"{name} ({number}).{EXT}")):
                    number += 1
                target = f"{name} ({number}).{EXT}"
                os.replace(path, os.path.join(TRASH, target))
                index = load_index()
                index[target] = {"name": name, "number": number,
                                 "deleted": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
                save_index(index)
                print(f"Moved {name} to the library's Trash as {target} (library.py restore {name} brings it back)")
            elif what == "trash":
                items = trashed()
                if not items:
                    print("The library's Trash is empty.")
                for t in items:
                    print(f"{t['name']} ({t['number']})  ·  deleted {t['deleted'][:16].replace('T', ' ')}")
            elif what == "restore":
                if not rest:
                    return main(["trash"])
                words = list(rest)
                new = None
                if "as" in words:
                    k = words.index("as")
                    new, words = " ".join(words[k + 1:]), words[:k]
                number = int(words.pop()) if len(words) > 1 and words[-1].isdigit() else None
                name = " ".join(words)
                picks = [t for t in trashed() if fold(t["name"]) == fold(key(name)) and (number is None or t["number"] == number)]
                if not picks:
                    raise Problem(f"There's no {name}{f' ({number})' if number else ''} in the library's Trash (library.py trash lists it).")
                t = picks[0]
                target = key(new or t["name"])
                if find(target):
                    raise Problem(f'There\'s a note called {target} now: restore it as another name (library.py restore {name} as "{target} restored").')
                os.replace(t["path"], os.path.join(ROOT, target + "." + EXT))
                index = load_index()
                index.pop(t["file"], None)
                save_index(index)
                print(f"Restored {target}")
            elif what == "open":
                name, path = existing(" ".join(rest))
                if subprocess.run(["open", path]).returncode != 0:
                    raise Problem(f"Couldn't open {name} (opening needs macOS)")
                print(f"Opened {name}")
            elif what == "stats":
                found = notes()
                words = sum(len(read_text(p).split()) for _, p in found)
                size = sum(os.path.getsize(p) for _, p in found)
                print(f"{len(found)} notes, {words} words, {size / 1024:.1f} KB; {len(trashed())} in the Trash")
            elif what in ("path", "folder", "where"):
                print(ROOT)
            else:
                raise Problem(f"library.py doesn't know {what}: list, read, write, new, append, search, find, recent, rename, copy, delete, trash, restore, open, stats, path")
            return 0


        if __name__ == "__main__":
            try:
                sys.exit(main(sys.argv[1:]))
            except Problem as p:
                print(p, file=sys.stderr)
                sys.exit(1)
        """# + "\n"),
        ("utilities/library-search.sh", #"""
        #!/bin/bash
        # Searches every note in the library (LIBRARY on your Desktop): each line with your words on it, the best notes first
        #
        # Input: The words to look for (a "phrase" in quotes)
        # Why: Every note is read; nothing is changed
        set -euo pipefail

        # library.py, beside it, does the work (the same rules as the Library board and /api/library).
        exec python3 "$(dirname "$0")/library.py" search "$@"
        """# + "\n"),
        ("utilities/library-find.sh", #"""
        #!/bin/bash
        # Lists the notes in the library with every one of your words in their name or text, the best first: just their names
        #
        # Input: The words to look for (a "phrase" in quotes)
        # Why: Every note is read; nothing is changed
        set -euo pipefail

        # library.py, beside it, does the work (the same rules as the Library board and /api/library).
        exec python3 "$(dirname "$0")/library.py" find "$@"
        """# + "\n"),
        ("utilities/library-read.sh", #"""
        #!/bin/bash
        # A note's text, from the library (LIBRARY on your Desktop), by its name
        #
        # Input: The note's name (without .md)
        set -euo pipefail

        # library.py, beside it, does the work (the same rules as the Library board and /api/library).
        exec python3 "$(dirname "$0")/library.py" read "$@"
        """# + "\n"),
        ("utilities/library-write.sh", #"""
        #!/bin/bash
        # Writes a note in the library: creates it, or replaces its text with yours
        #
        # Input: The note's name (without .md)
        # Input: What goes in it (or its input, from a flow)
        # Why: The note's text is replaced by this (what was there isn't kept)
        set -euo pipefail

        # library.py, beside it, does the work (the same rules as the Library board and /api/library).
        exec python3 "$(dirname "$0")/library.py" write "$@"
        """# + "\n"),
        ("utilities/library-new.sh", #"""
        #!/bin/bash
        # Makes a new note in the library (not if the name is taken), starting with its name as a heading, or your words
        #
        # Input: The new note's name
        # Input (optional): What goes in it (its name as a heading unless set)
        set -euo pipefail

        # library.py, beside it, does the work (the same rules as the Library board and /api/library).
        exec python3 "$(dirname "$0")/library.py" new "$@"
        """# + "\n"),
        ("utilities/library-append.sh", #"""
        #!/bin/bash
        # Adds a line at the end of a note in the library (creating the note if it isn't there): a journal, a log, a list
        #
        # Input: The note's name (without .md)
        # Input: The line to add
        set -euo pipefail

        # library.py, beside it, does the work (the same rules as the Library board and /api/library).
        exec python3 "$(dirname "$0")/library.py" append "$@"
        """# + "\n"),
        ("utilities/library-delete.sh", #"""
        #!/bin/bash
        # Moves a note to the library's Trash (as name (1), name (2)…), from where library-restore brings it back
        #
        # Input: The note's name (without .md)
        # Why: It's moved to LIBRARY/Trash, not deleted for good
        set -euo pipefail

        # library.py, beside it, does the work (the same rules as the Library board and /api/library).
        exec python3 "$(dirname "$0")/library.py" delete "$@"
        """# + "\n"),
        ("utilities/library-restore.sh", #"""
        #!/bin/bash
        # Brings a note back from the library's Trash (the latest of that name, or its number), or says what's there
        #
        # Input (optional): The note's name, and its number in the Trash (what's there unless set)
        set -euo pipefail

        # library.py, beside it, does the work (the same rules as the Library board and /api/library).
        exec python3 "$(dirname "$0")/library.py" restore "$@"
        """# + "\n"),
        ("utilities/library-recent.sh", #"""
        #!/bin/bash
        # The notes in the library you changed last, newest first (10 unless you say how many)
        #
        # Input (optional): How many (10 unless set)
        set -euo pipefail

        # library.py, beside it, does the work (the same rules as the Library board and /api/library).
        exec python3 "$(dirname "$0")/library.py" recent "$@"
        """# + "\n"),
        ("utilities/library-open.sh", #"""
        #!/bin/bash
        # Opens a note from the library in its app (your Markdown editor, or TextEdit)
        #
        # Input: The note's name (without .md)
        set -euo pipefail

        # library.py, beside it, does the work (the same rules as the Library board and /api/library).
        exec python3 "$(dirname "$0")/library.py" open "$@"
        """# + "\n"),
    ]

    /// Scripts that drive Google Chrome. `browser.sh` does the driving (through AppleScript); the
    /// others (Google, YouTube, YouTube Music, the page in front) are made of it.
    public static let browser: [(String, String)] = [
        ("browser/browser.sh", #"""
        #!/bin/bash
        # Drives Google Chrome: opens pages, reads them (in a tab of their own, in the background), runs JavaScript in them
        #
        #   browser.sh                   whether Chrome is ready to be driven, and what to switch on if not
        #   browser.sh open URL          opens URL in a new tab, in front; waits for it; prints its title
        #   browser.sh read URL ['JS']   opens URL in a background tab, waits until the JavaScript gives something
        #                                back (the page's text if none is given), prints it, closes the tab
        #   browser.sh url | title | text | tabs     the page in front: its address, title or text; every tab
        #                                (of the front window; tabs --all: of every window)
        #   browser.sh close-duplicates  closes every tab showing the same address as one before it
        #   browser.sh js 'JS'           runs JavaScript in the page in front and prints what it gives back
        #   browser.sh js-in PART 'JS'   the same, in the first tab whose address has PART in it (music.youtube.com)
        #   browser.sh focus PART        brings that tab to the front
        #   browser.sh go PART URL       the first tab whose address has PART in it goes to URL (a new tab
        #                                if there's none), in front; waits for it; prints its title
        #   browser.sh wait              waits (up to 30 seconds) for the page in front to load
        #   browser.sh encode TEXT       TEXT made safe for an address (for ?q=…)
        #
        # JavaScript is an expression (document.title, or items.map(v => { …; return v.x })), or statements with a
        # return of their own, outside any function, giving back the answer; what isn't text comes back as JSON.
        # Chrome lets scripts run it once View > Developer > Allow JavaScript from Apple Events is ticked; macOS
        # asks once whether this app may control Chrome.
        set -uo pipefail

        CHROME=com.google.Chrome

        if ! command -v osascript >/dev/null 2>&1; then
          echo "Driving Chrome needs macOS (osascript)." >&2
          exit 1
        fi

        # AppleScript (from its input) run with Chrome's id, then the words given, as argv. Each script
        # names Chrome itself (tell application id "com.google.Chrome"): AppleScript reads Chrome's own
        # words (active tab, execute, loading) from the app it names, as it compiles.
        tell_chrome() {
          osascript - "$CHROME" "$@"
        }

        # What went wrong, in words, with the fix; then stops.
        explain() {
          local err="$1"
          case "$err" in
            *"JavaScript through AppleScript is turned off"*|*"Allow JavaScript from Apple Events"*)
              echo "Chrome doesn't let scripts run JavaScript in its pages yet." >&2
              echo "Fix, once: in Chrome, View > Developer > Allow JavaScript from Apple Events." >&2 ;;
            *NO_WINDOW*)
              echo "Chrome has no window open." >&2
              echo "Fix: open a page first (browser.sh open https://example.com)." >&2 ;;
            *NO_TAB*)
              echo "No tab in Chrome has ${err#*NO_TAB } in its address." >&2
              echo "Fix: open it first (browser.sh open …)." >&2 ;;
            *TAB_GONE*)
              echo "The tab was closed before it could be read." >&2 ;;
            *-1743*|*"Not authorized"*|*"not allowed to send"*)
              echo "macOS hasn't let this app control Chrome." >&2
              echo "Fix: System Settings > Privacy & Security > Automation > Tool Mac Tool Run (or your terminal) > turn on Google Chrome." >&2 ;;
            *"$CHROME"*|*"-10814"*|*"-2700"*)
              echo "Google Chrome isn't on this Mac." >&2
              echo "Fix: brew install --cask google-chrome (or download it from google.com/chrome)." >&2 ;;
            *TMR_JS_ERROR*)
              echo "The page's JavaScript failed: ${err#*TMR_JS_ERROR }" >&2 ;;
            *)
              echo "Chrome said: $err" >&2 ;;
          esac
          exit 1
        }

        # Runs AppleScript given as its input; prints what it gives back, or explains what went wrong.
        run_script() {
          local out
          if ! out=$(tell_chrome "$@" 2>&1); then
            explain "$out"
          fi
          printf '%s\n' "$out"
        }

        # Statements, not one expression: a return (or a const, let, var, if, for, while, try or throw
        # starting a statement) outside every function, string, comment and pattern in it.
        is_statements() {
          printf '%s' "$1" | LC_ALL=C awk 'BEGIN { RS = "\001" }
          {
            n = split($0, c, "")
            depth = 0; quote = ""; prev = ""
            for (i = 1; i <= n; i++) {
              ch = c[i]
              if (quote != "") {
                if (ch == "\\") i++
                else if (ch == quote) { quote = ""; prev = ch }
                continue
              }
              if (ch == "\"" || ch == "\047" || ch == "`") { quote = ch; continue }
              if (ch == "/" && c[i + 1] == "/") { while (i <= n && c[i] != "\n") i++; continue }
              if (ch == "/" && c[i + 1] == "*") { for (i += 2; i < n && !(c[i] == "*" && c[i + 1] == "/"); i++) ; i++; continue }
              if (ch == "/" && (prev == "" || index("(,=:[!&|?{};+-*%<>~^", prev) > 0)) {
                inclass = 0
                for (i++; i <= n && c[i] != "\n"; i++) {
                  if (c[i] == "\\") i++
                  else if (c[i] == "[") inclass = 1
                  else if (c[i] == "]") inclass = 0
                  else if (c[i] == "/" && !inclass) break
                }
                prev = "/"; continue
              }
              if (ch == "{" || ch == "(" || ch == "[") depth++
              else if (ch == "}" || ch == ")" || ch == "]") depth--
              else if (depth == 0 && ch ~ /[a-z]/ && (i == 1 || c[i - 1] !~ /[A-Za-z0-9_$.]/)) {
                w = ""
                for (j = i; j <= n && c[j] ~ /[A-Za-z0-9_$]/; j++) w = w c[j]
                if (w == "return") { found = 1; exit }
                if ((prev == "" || prev == ";" || prev == "}") && (w == "const" || w == "let" || w == "var" || w == "if" || w == "for" || w == "while" || w == "try" || w == "throw")) { found = 1; exit }
                i = j - 1; prev = c[i]; continue
              }
              if (ch !~ /[ \t\r\n]/) prev = ch
            }
          }
          END { exit found ? 0 : 1 }'
        }

        # JavaScript, wrapped so an expression or statements with a return give back text (JSON for the rest).
        wrap_js() {
          local code="$1" body
          # Trailing semicolons and spaces off, so an expression can be returned.
          code="${code%"${code##*[![:space:];]}"}"
          # Statements as they are; otherwise one expression, whatever functions inside it return
          # (items.map(v => { const t = …; return t }) is an expression).
          if is_statements "$code"; then
            body="$code"
          else
            body="return (
        $code
        );"
          fi
          printf '%s' "(() => { try { const r = (() => {
        $body
        })(); return r === undefined || r === null ? '' : typeof r === 'string' ? r : JSON.stringify(r, null, 2); } catch (e) { return 'TMR_JS_ERROR ' + e; } })()"
        }

        # The id of the tab in front, or of the first tab whose address has PART in it.
        tab_id() {
          run_script "${1:-}" <<'APPLESCRIPT'
        on run argv
          set wanted to item 2 of argv
          tell application id "com.google.Chrome"
            if (count of windows) = 0 then error "NO_WINDOW"
            if wanted is "" then return id of active tab of front window
            repeat with w in windows
              repeat with t in tabs of w
                if (URL of t) contains wanted then return id of t
              end repeat
            end repeat
          end tell
          error "NO_TAB " & wanted
        end run
        APPLESCRIPT
        }

        # JavaScript, run in the tab with this id; prints what it gives back.
        js_in_tab() {
          local out
          out=$(run_script "$1" "$(wrap_js "$2")" <<'APPLESCRIPT'
        on run argv
          set tid to item 2 of argv
          tell application id "com.google.Chrome"
            repeat with w in windows
              repeat with t in tabs of w
                if (id of t as text) is tid then return execute t javascript (item 3 of argv)
              end repeat
            end repeat
          end tell
          error "TAB_GONE"
        end run
        APPLESCRIPT
          ) || exit 1
          case "$out" in
            TMR_JS_ERROR*) explain "$out" ;;
          esac
          printf '%s\n' "$out"
        }

        # Waits (up to 30 seconds) for the tab with this id to finish loading.
        wait_tab() {
          local i state
          for i in $(seq 1 60); do
            state=$(tell_chrome "$1" 2>/dev/null <<'APPLESCRIPT'
        on run argv
          set tid to item 2 of argv
          tell application id "com.google.Chrome"
            repeat with w in windows
              repeat with t in tabs of w
                if (id of t as text) is tid then return loading of t
              end repeat
            end repeat
          end tell
          return "gone"
        end run
        APPLESCRIPT
            ) || state=""
            case "$state" in
              false|gone) return 0 ;;
            esac
            sleep 0.5
          done
          echo "The page is still loading after 30 seconds; going on anyway." >&2
        }

        # A new tab with this address: in front ("front"), or loading behind the tab you're on
        # ("behind"). Prints its id.
        new_tab() {
          run_script "$1" "$2" <<'APPLESCRIPT'
        on run argv
          set targetURL to item 2 of argv
          tell application id "com.google.Chrome"
            if (count of windows) = 0 then
              make new window
              set URL of active tab of front window to targetURL
              set t to active tab of front window
            else
              set w to front window
              set frontIndex to active tab index of w
              set t to make new tab at end of tabs of w with properties {URL:targetURL}
              if item 3 of argv is "behind" then set active tab index of w to frontIndex
            end if
            if item 3 of argv is "front" then activate
            return id of t
          end tell
        end run
        APPLESCRIPT
        }

        close_tab() {
          tell_chrome "$1" >/dev/null 2>&1 <<'APPLESCRIPT'
        on run argv
          set tid to item 2 of argv
          tell application id "com.google.Chrome"
            repeat with w in windows
              repeat with t in tabs of w
                if (id of t as text) is tid then
                  close t
                  return
                end if
              end repeat
            end repeat
          end tell
        end run
        APPLESCRIPT
        }

        with_scheme() {
          case "$1" in
            *://*|about:*|chrome:*) printf '%s' "$1" ;;
            *) printf 'https://%s' "$1" ;;
          esac
        }

        # The first tab whose address has PART in it goes to URL (a new tab if there's none), in front.
        go_page() {
          local id
          id=$(run_script "$1" "$(with_scheme "$2")" <<'APPLESCRIPT'
        on run argv
          set wanted to item 2 of argv
          tell application id "com.google.Chrome"
            repeat with w in windows
              set k to 0
              repeat with t in tabs of w
                set k to k + 1
                if (URL of t) contains wanted then
                  set URL of t to item 3 of argv
                  set active tab index of w to k
                  set index of w to 1
                  activate
                  return id of t
                end if
              end repeat
            end repeat
          end tell
          return ""
        end run
        APPLESCRIPT
          ) || exit 1
          if [ -z "$id" ]; then
            open_page "$2"
            return
          fi
          sleep 0.5
          wait_tab "$id"
          tab_property title
        }

        open_page() {
          local id
          id=$(new_tab "$(with_scheme "$1")" front) || exit 1
          sleep 0.5
          wait_tab "$id"
          tab_property title
        }

        # Reads a page in a tab of its own behind the one you're on: retries the JavaScript until it gives
        # something back (pages that draw themselves after loading), up to 15 seconds; then closes the tab.
        read_page() {
          local out i
          reading=$(new_tab "$(with_scheme "$1")" behind) || exit 1
          trap 'close_tab "$reading"' EXIT
          sleep 0.5
          wait_tab "$reading"
          for i in $(seq 1 30); do
            out=$(js_in_tab "$reading" "$2") || exit 1
            [ -n "${out//[[:space:]]/}" ] && break
            sleep 0.5
          done
          printf '%s\n' "$out"
        }

        tab_property() {
          run_script "$1" <<'APPLESCRIPT'
        on run argv
          tell application id "com.google.Chrome"
            if (count of windows) = 0 then error "NO_WINDOW"
            set t to active tab of front window
            if item 2 of argv is "url" then return URL of t
            return title of t
          end tell
        end run
        APPLESCRIPT
        }

        list_tabs() {
          run_script "${1:-}" <<'APPLESCRIPT'
        on run argv
          tell application id "com.google.Chrome"
            if (count of windows) = 0 then error "NO_WINDOW"
            set rows to {}
            if item 2 of argv is "--all" then
              set shown to windows
            else
              set shown to {front window}
            end if
            repeat with w in shown
              repeat with t in tabs of w
                set end of rows to (title of t) & (character id 9) & (URL of t)
              end repeat
            end repeat
          end tell
          set AppleScript's text item delimiters to linefeed
          return rows as text
        end run
        APPLESCRIPT
        }

        # Closes each tab whose address an earlier tab (in any window) already shows. Prints how many.
        close_duplicates() {
          run_script <<'APPLESCRIPT'
        on run argv
          set seen to {}
          set doomed to {}
          tell application id "com.google.Chrome"
            repeat with w in windows
              repeat with t in tabs of w
                set pageURL to URL of t
                if seen contains {pageURL} then
                  set end of doomed to id of t
                else
                  set end of seen to pageURL
                end if
              end repeat
            end repeat
            repeat with tid in doomed
              repeat with w in windows
                repeat with t in tabs of w
                  if id of t is (contents of tid) then
                    close t
                    -- The tabs after it have moved up: this window's list is read again for the next one.
                    exit repeat
                  end if
                end repeat
              end repeat
            end repeat
          end tell
          return (count of doomed) as text
        end run
        APPLESCRIPT
        }

        focus_tab() {
          run_script "$1" <<'APPLESCRIPT'
        on run argv
          set wanted to item 2 of argv
          tell application id "com.google.Chrome"
            repeat with w in windows
              set k to 0
              repeat with t in tabs of w
                set k to k + 1
                if (URL of t) contains wanted then
                  set active tab index of w to k
                  set index of w to 1
                  activate
                  return title of t
                end if
              end repeat
            end repeat
          end tell
          error "NO_TAB " & wanted
        end run
        APPLESCRIPT
        }

        encode() {
          osascript -l JavaScript - "$1" <<'JXA'
        function run(argv) { return encodeURIComponent(argv[0]) }
        JXA
        }

        status() {
          local where running
          if ! where=$(osascript -e "POSIX path of (path to application id \"$CHROME\")" 2>/dev/null); then
            echo "Google Chrome isn't on this Mac."
            echo "Fix: brew install --cask google-chrome (or download it from google.com/chrome)."
            return 1
          fi
          echo "Google Chrome: $where"
          running=$(osascript -e "application id \"$CHROME\" is running" 2>/dev/null)
          if [ "$running" != "true" ]; then
            echo "It isn't open; the browser scripts open it when they need it."
          fi
          echo "The browser scripts open pages in it, look inside them (in a tab of their own, closed after), and run JavaScript in them."
          echo "Two things are asked once: macOS asks whether this app may control Chrome (click Allow), and"
          echo "Chrome needs View > Developer > Allow JavaScript from Apple Events ticked."
          if [ "$running" = "true" ] && js_check=$(tell_chrome 2>&1 <<'APPLESCRIPT'
        on run argv
          tell application id "com.google.Chrome"
            if (count of windows) = 0 then return "no window"
            return execute active tab of front window javascript "1+1"
          end tell
        end run
        APPLESCRIPT
          ); then
            case "$js_check" in
              2) echo "✅ JavaScript from Apple Events is on: everything works." ;;
              *) echo "Open a page in Chrome, then run this again to check JavaScript is allowed." ;;
            esac
          elif [ "$running" = "true" ]; then
            explain "$js_check"
          fi
        }

        command="${1:-status}"
        [ $# -gt 0 ] && shift
        need() {
          if [ $# -lt 2 ] || [ -z "$2" ]; then
            echo "$1" >&2
            exit 1
          fi
        }
        case "$command" in
          status|which) status ;;
          open) need "Which page? browser.sh open https://example.com" "${1:-}"; open_page "$1" ;;
          read) need "Which page? (browser.sh read 'https://example.com' 'document.title')" "${1:-}"
            read_page "$1" "${2:-document.body ? document.body.innerText : ''}" ;;
          url|title) tab_property "$command" ;;
          text) id=$(tab_id) || exit 1; js_in_tab "$id" 'document.body ? document.body.innerText : ""' ;;
          tabs) list_tabs "${1:-}" ;;
          close-duplicates) closed=$(close_duplicates) || exit 1; echo "Closed ${closed} duplicate tab(s)." ;;
          js) need "Which JavaScript? browser.sh js 'document.title'" "$*"; id=$(tab_id) || exit 1; js_in_tab "$id" "$*" ;;
          js-in) need "Which tab, and what JavaScript? browser.sh js-in music.youtube.com 'document.title'" "${2:-}"
            id=$(tab_id "$1") || exit 1
            shift
            js_in_tab "$id" "$*" ;;
          focus) need "Which tab? browser.sh focus music.youtube.com" "${1:-}"; focus_tab "$1" ;;
          go) need "Which tab, and where to? browser.sh go music.youtube.com https://music.youtube.com" "${2:-}"; go_page "$1" "$2" ;;
          wait) id=$(tab_id) || exit 1; wait_tab "$id" ;;
          encode) need "What text? browser.sh encode 'two words'" "$*"; encode "$*" ;;
          *)
            echo "browser.sh doesn't know \"$command\"." >&2
            echo "It knows: open, read, url, title, text, tabs, close-duplicates, js, js-in, focus, go, wait and encode (the top of browser.sh says how each goes)." >&2
            exit 1 ;;
        esac
        """# + "\n"),
        ("browser/google.sh", #"""
        #!/bin/bash
        # Asks Google and gives back just the answer: Google's own (AI Overview, a quick answer, the info box), then the top results
        #
        # Input: What should Google be asked?
        #
        #   google.sh how tall is the eiffel tower
        #   google.sh "weather in Lagos"
        #   google.sh --answer 100 usd in eur   Google's own answer alone (the top result's words if it has none)
        # Google is asked in Chrome, in a tab of its own behind the one you're on, closed after.
        # GOOGLE_LANGUAGE=fr asks in another language (English unless set).
        set -euo pipefail

        browser="$(dirname "$0")/browser.sh"
        if [ ! -f "$browser" ]; then
          echo "This needs browser.sh beside it, in the browser folder (Add the Examples on the Browser grid puts it back)." >&2
          exit 1
        fi
        only_answer=false
        if [ "${1:-}" = "--answer" ]; then
          only_answer=true
          shift
        fi
        if [ $# -eq 0 ]; then
          echo "What should Google be asked? (google.sh how tall is the eiffel tower)" >&2
          exit 1
        fi

        query=$(bash "$browser" encode "$*")
        address="https://www.google.com/search?hl=${GOOGLE_LANGUAGE:-en}&q=${query}"
        answer=$(bash "$browser" read "$address" "const onlyAnswer = $only_answer;"'
        const clean = s => (s || "").replace(/ /g, " ").replace(/[ \t]+/g, " ").replace(/\n\s*\n+/g, "\n").trim();
        if (location.pathname.startsWith("/sorry") || /unusual traffic from your computer/i.test(document.body.innerText.slice(0, 3000))) return "TMR_ROBOT_CHECK";
        const answers = [];
        const add = text => { text = clean(text); if (text && !answers.some(a => a.includes(text) || text.includes(a))) answers.push(text); };
        const overview = [...document.querySelectorAll("h1, h2, [role=heading]")].find(h => /^AI Overview$/i.test(h.innerText.trim()));
        if (overview) {
          let box = overview.parentElement;
          while (box && box !== document.body && box.innerText.length < 300) box = box.parentElement;
          const said = clean(box.innerText.replace(/^\s*AI Overview/i, "")).split("\n")
            .filter(l => !/^(Show (more|all)|AI responses may include mistakes|Learn more|Dive deeper|Listen|Thank you|Feedback|Generative AI is experimental)/i.test(l));
          add(said.join("\n").slice(0, 1500));
        }
        for (const sel of ["#tw-target-text", ".dDoNo", "#cwos", ".Z0LcW", "[data-tts=answers]", ".hgKElc", ".IZ6rdc", "[data-attrid=\"wa:/description\"]", ".kno-rdesc span", "#wob_wc"]) {
          const found = document.querySelector(sel);
          if (found) add(found.innerText.slice(0, 800));
        }
        const results = [];
        const seen = new Set();
        for (const title of document.querySelectorAll("#search a h3, #rso a h3")) {
          const link = title.closest("a");
          if (!link || !/^https?:/.test(link.href) || /\/\/(www\.)?google\.[a-z.]+\/search/.test(link.href) || seen.has(link.href)) continue;
          seen.add(link.href);
          let box = link;
          // Up to the block of this result alone (no other title in it).
          for (let i = 0; i < 8 && box.parentElement && box.parentElement.querySelectorAll("h3").length === 1; i++) box = box.parentElement;
          const name = clean(title.innerText);
          const about = clean(box.innerText).split("\n").find(l => l.length > 40 && !l.includes(name) && !/^https?:\/\//.test(l) && !l.includes(" › "));
          results.push(`${results.length + 1}. ${name}` + (about ? `\n   ${about}` : "") + `\n   ${link.href}`);
          if (results.length === 5) break;
        }
        if (onlyAnswer) return answers[0] || (results[0] || "").split("\n").slice(1, 2).join("").trim() || "Google gave no answer of its own.";
        const text = [answers.join("\n\n"), results.join("\n")].filter(Boolean).join("\n\n");
        return text || clean((document.querySelector("#search") || document.body).innerText).slice(0, 1500);
        ')

        if [ "$answer" = "TMR_ROBOT_CHECK" ]; then
          echo "Google wants to check this isn't a robot before it answers." >&2
          echo "Fix: answer its check once in Chrome (browser.sh open \"$address\"), then ask again." >&2
          exit 1
        fi
        printf '%s\n' "$answer"
        """# + "\n"),
        ("browser/youtube.sh", #"""
        #!/bin/bash
        # Searches YouTube: the top videos (a line each, its address last), or plays the first, or shows the results in Chrome
        #
        # Input: What to search YouTube for
        #
        #   youtube.sh lofi hip hop          the top 10 videos: title — channel · length · views · age — address
        #   youtube.sh --play lofi hip hop   plays the first one, in Chrome, in front
        #   youtube.sh --open lofi hip hop   shows YouTube's results page, in Chrome, in front
        set -euo pipefail

        browser="$(dirname "$0")/browser.sh"
        if [ ! -f "$browser" ]; then
          echo "This needs browser.sh beside it, in the browser folder (Add the Examples on the Browser grid puts it back)." >&2
          exit 1
        fi
        mode=list
        case "${1:-}" in
          --play|--open) mode="${1#--}"; shift ;;
        esac
        if [ $# -eq 0 ]; then
          echo "What should YouTube be searched for? (youtube.sh lofi hip hop)" >&2
          exit 1
        fi

        address="https://www.youtube.com/results?search_query=$(bash "$browser" encode "$*")"
        if [ "$mode" = open ]; then
          bash "$browser" open "$address"
          exit 0
        fi

        found=$(bash "$browser" read "$address" '
        [...document.querySelectorAll("ytd-video-renderer")].map(v => {
          const link = v.querySelector("a#video-title");
          if (!link || !link.href.includes("watch?v=")) return "";
          const text = sel => ((v.querySelector(sel) || {}).textContent || "").replace(/\s+/g, " ").trim();
          const length = text("ytd-thumbnail-overlay-time-status-renderer").replace(/^(\S+) \1$/, "$1")
            || (v.querySelector("[is-live-video]") ? "live" : "");
          const about = [text("ytd-channel-name a"), length, ...[...v.querySelectorAll("#metadata-line span")].map(s => s.textContent.trim())]
            .filter(Boolean).join(" · ");
          return link.textContent.trim() + (about ? " — " + about : "") + " — https://www.youtube.com/watch?v=" + new URL(link.href).searchParams.get("v");
        }).filter(Boolean).slice(0, 10).join("\n")
        ')

        if [ -z "$found" ]; then
          echo "YouTube found no videos for \"$*\"." >&2
          exit 1
        fi
        if [ "$mode" = play ]; then
          first=$(printf '%s\n' "$found" | head -n 1)
          bash "$browser" open "${first##* — }" >/dev/null
          echo "Playing: ${first% — *}"
          exit 0
        fi
        printf '%s\n' "$found"
        """# + "\n"),
        ("browser/youtube-music.sh", #"""
        #!/bin/bash
        # Plays music on YouTube Music in Chrome: a song, artist or album you name, or pause, play, next, previous, now
        #
        # Input (optional): A song, artist or album (or pause, play, next, previous, now)
        #
        #   youtube-music.sh                     opens YouTube Music
        #   youtube-music.sh bohemian rhapsody   plays the best match (a song first, else the top result)
        #   youtube-music.sh pause | play | next | previous
        #   youtube-music.sh now                 what's playing
        # It uses the YouTube Music tab you have open (one is opened if there's none), so one thing plays at a time.
        set -euo pipefail

        browser="$(dirname "$0")/browser.sh"
        if [ ! -f "$browser" ]; then
          echo "This needs browser.sh beside it, in the browser folder (Add the Examples on the Browser grid puts it back)." >&2
          exit 1
        fi
        site=music.youtube.com

        now_playing='(() => {
          const bar = document.querySelector("ytmusic-player-bar");
          const title = bar && ((bar.querySelector(".title") || {}).textContent || "").trim();
          if (!title) return "Nothing is playing.";
          const by = ((bar.querySelector(".byline") || {}).textContent || "").replace(/\s+/g, " ").trim();
          const video = document.querySelector("video");
          return (video && video.paused ? "Paused: " : "Playing: ") + title + (by ? " — " + by : "");
        })()'

        control() {
          bash "$browser" js-in "$site" "$1" >/dev/null
          sleep 1.5
          bash "$browser" js-in "$site" "$now_playing"
        }

        case "${1:-}" in
          "")
            bash "$browser" go "$site" "https://$site" >/dev/null
            echo "YouTube Music is open in Chrome."
            exit 0 ;;
          pause) control 'document.querySelector("video") && document.querySelector("video").pause()'; exit 0 ;;
          play|resume) control 'document.querySelector("video") && document.querySelector("video").play() && ""'; exit 0 ;;
          next) control 'document.querySelector("ytmusic-player-bar .next-button").click()'; exit 0 ;;
          previous) control 'document.querySelector("ytmusic-player-bar .previous-button").click()'; exit 0 ;;
          now) bash "$browser" js-in "$site" "$now_playing"; exit 0 ;;
        esac

        bash "$browser" go "$site" "https://$site/search?q=$(bash "$browser" encode "$*")" >/dev/null
        # The results draw themselves after the page loads: try for up to 10 seconds.
        picked=""
        for i in $(seq 1 20); do
          picked=$(bash "$browser" js-in "$site" '
        const rows = [...document.querySelectorAll("ytmusic-responsive-list-item-renderer")].filter(r => r.querySelector("ytmusic-play-button-renderer"));
        const kind = r => ((r.querySelector(".secondary-flex-columns") || {}).innerText || "").trim();
        const card = document.querySelector("ytmusic-card-shelf-renderer");
        const cardPlay = card && [...card.querySelectorAll("button")].find(b => b.innerText.trim() === "Play");
        const song = rows.find(r => /^Song\b/.test(kind(r)));
        const video = rows.find(r => /^Video\b/.test(kind(r)));
        const target = song ? song.querySelector("ytmusic-play-button-renderer") : cardPlay || (video || rows[0] || document).querySelector("ytmusic-play-button-renderer");
        if (!target) return "";
        target.click();
        return "clicked";
        ')
          [ -n "$picked" ] && break
          sleep 0.5
        done
        if [ -z "$picked" ]; then
          echo "YouTube Music shows no match for \"$*\" that can be played." >&2
          echo "Its search is open in Chrome: pick one there." >&2
          exit 1
        fi
        sleep 3
        bash "$browser" js-in "$site" "$now_playing"
        """# + "\n"),
        ("browser/translate.sh", #"""
        #!/bin/bash
        # Translates text with Google (in Chrome): "good morning" to French, or to English from anything
        #
        # Input: What to translate
        # Input (optional): Into which language (English unless set)
        set -euo pipefail

        here="$(dirname "$0")"
        if [ $# -eq 0 ] || [ -z "$1" ]; then
          echo "What should be translated? (translate.sh \"good morning\" French)" >&2
          exit 1
        fi
        language="${2:-English}"
        # Google does the translating; google.sh gives back its answer alone.
        bash "$here/google.sh" --answer "translate \"$1\" to $language"
        """# + "\n"),
        ("browser/gmail.sh", #"""
        #!/bin/bash
        # Your unread email in Gmail (in Chrome, where you're signed in): how many, then who from and what about
        #
        # Gmail is read in a tab of its own behind the one you're on, closed after. GMAIL_ACCOUNT=1 reads
        # the second account you're signed in to (0, the first, unless set).
        set -euo pipefail

        browser="$(dirname "$0")/browser.sh"
        if [ ! -f "$browser" ]; then
          echo "This needs browser.sh beside it, in the browser folder (Add the Examples on the Browser grid puts it back)." >&2
          exit 1
        fi
        inbox=$(bash "$browser" read "https://mail.google.com/mail/u/${GMAIL_ACCOUNT:-0}/#inbox" '
        if (/accounts\.google\.com/.test(location.host)) return "TMR_SIGN_IN";
        const main = document.querySelector("div[role=main]");
        if (!main || !/Inbox/i.test(document.title)) return "";
        const count = (document.title.match(/\((\d[\d,]*)\)/) || [])[1] || "0";
        const rows = [...main.querySelectorAll("tr.zA.zE")].slice(0, 15).map(r => {
          const from = r.querySelector(".yX [email], .yX .yP, .yX .zF");
          const who = from ? (from.getAttribute("name") || from.textContent).trim() : "";
          const about = ((r.querySelector(".bog") || {}).textContent || "").trim();
          return "• " + who + " — " + about;
        });
        return count + " unread" + (rows.length ? "\n" + rows.join("\n") : "");
        ')
        if [ "$inbox" = "TMR_SIGN_IN" ]; then
          echo "Chrome isn't signed in to Gmail." >&2
          echo "Fix: open mail.google.com in Chrome and sign in once, then run this again." >&2
          exit 1
        fi
        printf '%s\n' "$inbox"
        """# + "\n"),
        ("browser/maps.sh", #"""
        #!/bin/bash
        # Google Maps in Chrome: a place, or the way from one place to another ("home to the airport")
        #
        # Input: A place, or "from to somewhere"
        set -euo pipefail

        browser="$(dirname "$0")/browser.sh"
        if [ ! -f "$browser" ]; then
          echo "This needs browser.sh beside it, in the browser folder (Add the Examples on the Browser grid puts it back)." >&2
          exit 1
        fi
        if [ $# -eq 0 ]; then
          echo "Which place? (maps.sh Eiffel Tower, or maps.sh Paris to Lyon)" >&2
          exit 1
        fi
        asked="$*"
        case "$asked" in
          *" to "*)
            from="${asked%% to *}"
            to="${asked#* to }"
            address="https://www.google.com/maps/dir/$(bash "$browser" encode "$from")/$(bash "$browser" encode "$to")" ;;
          *)
            address="https://www.google.com/maps/search/$(bash "$browser" encode "$asked")" ;;
        esac
        bash "$browser" open "$address"
        """# + "\n"),
        ("browser/save-tabs.sh", #"""
        #!/bin/bash
        # Saves every tab open in Chrome (every window) to a Markdown file, a link each, to open again later
        #
        # Input (optional): Where to save them (~/Documents/Chrome Tabs/<date>.md unless set)
        set -euo pipefail

        browser="$(dirname "$0")/browser.sh"
        if [ ! -f "$browser" ]; then
          echo "This needs browser.sh beside it, in the browser folder (Add the Examples on the Browser grid puts it back)." >&2
          exit 1
        fi
        file="${1:-$HOME/Documents/Chrome Tabs/$(date '+%Y-%m-%d %H.%M').md}"
        mkdir -p "$(dirname "$file")"
        tabs=$(bash "$browser" tabs --all)
        {
          echo "# Chrome tabs, $(date '+%A %d %B %Y, %H:%M')"
          echo
          printf '%s\n' "$tabs" | awk -F '\t' 'NF { printf "- [%s](%s)\n", ($1 == "" ? $2 : $1), $2 }'
        } > "$file"
        echo "Saved $(printf '%s\n' "$tabs" | grep -c .) tabs to $file"
        """# + "\n"),
        ("browser/close-duplicate-tabs.sh", #"""
        #!/bin/bash
        # Closes the tabs in Chrome that show a page another tab already shows (the first of each stays)
        set -euo pipefail

        browser="$(dirname "$0")/browser.sh"
        if [ ! -f "$browser" ]; then
          echo "This needs browser.sh beside it, in the browser folder (Add the Examples on the Browser grid puts it back)." >&2
          exit 1
        fi
        bash "$browser" close-duplicates
        """# + "\n"),
        ("browser/open-page.sh", #"""
        #!/bin/bash
        # Opens a page in Chrome (the address given, or example.com), waits for it to load, and prints its title
        #
        # Input (optional): An address (example.com unless set)
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
        # The page in front in Chrome: its title, then its address
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
        # The text of the page in front in Chrome, as it reads on screen
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
        # Every link on the page in front in Chrome: its words, a tab, its address (one a line)
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
        ("browser/straw.py", #"""
        #!/usr/bin/env python3
        # Runs Straw scripts (.straw): Chrome driven by what's on the page, one plain line at a time
        #
        # Input (optional): A .straw file to run (with nothing, the words Straw knows)
        #
        #   straw.py hacker-news.straw              runs it, in the tab in front (browser.sh does the driving)
        #   straw.py hacker-news.straw word…        what comes after is {1}, {2}… (and {args}, all of it)
        #   straw.py --check hacker-news.straw      reads it and says what it would do; runs nothing
        #   straw.py                                every word Straw knows, with an example of each
        #
        # A line is a word and what it works on: open news.ycombinator.com, click "More", type "Search" "cats",
        # see "Results", read all css ".titleline > a". Things are named the way a person names them: by the words
        # on them (their label, their placeholder, what's written on the button). The whole file is checked before
        # anything runs; a mistake says its line and the fix. What it reads goes to the output (a flow's value);
        # what it's doing goes beside it, a line a step. The Straw guide (in the app, and docs/STRAW-GUIDE.md) says more.
        import difflib
        import json
        import os
        import re
        import subprocess
        import sys
        import time
        import urllib.parse

        WAIT_SECONDS = 15

        # Every word, what it takes, and what it does: the checker, the help and the guide read this one table.
        WORDS = {
            "open":    ("URL", "opens the page in a new tab, in front, and waits for it ({values} after the ? are made safe for an address)", 'open "en.wikipedia.org/w/index.php?search={1}"'),
            "go":      ("URL", "the tab in front goes to the page, and waits for it", 'go https://example.com/next'),
            "tab":     ("TEXT", "brings to the front the first tab whose address has TEXT in it", 'tab "music.youtube.com"'),
            "back":    ("", "goes back a page", 'back'),
            "forward": ("", "goes forward a page", 'forward'),
            "reload":  ("", "loads the page again", 'reload'),
            "wait":    ("[gone] [THING] [SECONDS]", "waits for the page to load; for THING to show (15 s unless SECONDS); with gone, for it to go", 'wait "Results"'),
            "click":   ("THING", "clicks it", 'click "Sign in"'),
            "hover":   ("THING", "puts the pointer over it (menus that open on hover)", 'hover "Products"'),
            "type":    ("THING TEXT", "puts TEXT in the field (what was in it is replaced)", 'type "Search" "{1}"'),
            "press":   ("KEY", "presses a key in the field in front: Enter, Tab, Escape, Space, Backspace, ArrowDown…", 'press Enter'),
            "select":  ("THING OPTION", "picks OPTION in a menu (a <select>)", 'select "Country" "Nigeria"'),
            "check":   ("THING", "ticks a checkbox (or turns a switch on); already ticked stays ticked", 'check "Remember me"'),
            "uncheck": ("THING", "unticks it", 'uncheck "Send me news"'),
            "scroll":  ("THING | down | up | top | bottom", "scrolls it into view, or the page", 'scroll down'),
            "see":     ("[no] THING", "stops the script unless THING is on the page (with no: unless it isn't)", 'see "Welcome back"'),
            "read":    ("[all | after | links] THING | title | url | page | links  [into NAME]", "gives back its words (a field: what's in it); all: every match, a line each; after: what's beside it; links: every link (or each one THING names), its words, a tab, its address", 'read all css ".titleline > a"'),
            "js":      ("CODE [into NAME]", "runs JavaScript in the page and gives back what it gives (a list: a line each)", 'js "document.title" into t'),
            "set":     ("NAME TEXT", "remembers TEXT as {NAME}", 'set city "{1|Lagos}"'),
            "print":   ("TEXT", "gives TEXT back (the script's output)", 'print "Top story: {top}"'),
            "ask":     ("NAME QUESTION", "asks on the Mac, and remembers the answer as {NAME}", 'ask query "Search for what?"'),
            "confirm": ("MESSAGE", "asks on the Mac before going on: Stop ends the script here", 'confirm "Post the comment?"'),
            "stop":    ("MESSAGE", "ends the script here, as a failure, saying MESSAGE", 'stop "Not signed in"'),
            "if":      ("see THING | no THING", "does the indented lines under it only if THING is (or isn't) on the page", 'if see "Accept all"'),
            "else":    ("", "the indented lines under it, when the if above didn't", 'else'),
        }

        KEYS = {
            "enter": ("Enter", 13), "return": ("Enter", 13), "tab": ("Tab", 9), "escape": ("Escape", 27), "esc": ("Escape", 27),
            "space": (" ", 32), "backspace": ("Backspace", 8), "delete": ("Delete", 46), "arrowup": ("ArrowUp", 38),
            "arrowdown": ("ArrowDown", 40), "arrowleft": ("ArrowLeft", 37), "arrowright": ("ArrowRight", 39),
            "up": ("ArrowUp", 38), "down": ("ArrowDown", 40), "left": ("ArrowLeft", 37), "right": ("ArrowRight", 39),
            "home": ("Home", 36), "end": ("End", 35), "pageup": ("PageUp", 33), "pagedown": ("PageDown", 34),
        }


        class Mistake(Exception):
            """Something wrong with a line: where, what, and the fix."""

            def __init__(self, line, message, fix=None):
                super().__init__(message)
                self.line, self.message, self.fix = line, message, fix


        class Stop(Exception):
            """The script ends here (stop, confirm's Stop, or something on the page that isn't as it said)."""


        # ─── reading a line ──────────────────────────────────────────────────────────

        def tokens(text, number):
            """The words and "quoted texts" of a line, without its # comment. Each is (kind, value): word or text."""
            out, i, n = [], 0, len(text)
            while i < n:
                c = text[i]
                if c in " \t":
                    i += 1
                elif c == "#":
                    break
                elif c in "\"'":
                    j, buf = i + 1, []
                    while j < n and text[j] != c:
                        # \" (the quote it's in) and \\ are escapes; any other backslash stays, for JavaScript's \n and \s.
                        if text[j] == "\\" and j + 1 < n and text[j + 1] in (c, "\\"):
                            j += 1
                        buf.append(text[j])
                        j += 1
                    if j >= n:
                        raise Mistake(number, f"A text starts with {c} and doesn't end.", f"Put a {c} at its end.")
                    out.append(("text", "".join(buf)))
                    i = j + 1
                else:
                    j = i
                    while j < n and text[j] not in " \t\"'":
                        j += 1
                    out.append(("word", text[i:j]))
                    i = j
            return out


        class Step:
            def __init__(self, number, source, word, **parts):
                self.number, self.source, self.word = number, source, word
                self.parts = parts
                self.body, self.otherwise = [], []

            def __getattr__(self, name):
                parts = self.__dict__.get("parts", {})
                if name in parts:
                    return parts[name]
                raise AttributeError(name)


        def target(toks, number, word):
            """THING: "Name", css "selector", either with first before it (the first of several, the highest on the
            page) and in "Container" after it. Returns it and what's left."""
            if not toks:
                raise Mistake(number, f"{word} needs something to work on.", "Name it as it's written on the page: " + WORDS[word][2])
            first = toks[0] == ("word", "first")
            if first:
                toks = toks[1:]
                if not toks:
                    raise Mistake(number, "first needs the thing after it.", f'{word} first css "h3 a"')
            kind = "name"
            if toks[0] == ("word", "css"):
                kind = "css"
                toks = toks[1:]
                if not toks or toks[0][0] != "text":
                    raise Mistake(number, "css needs a selector, in quotes.", f'{word} css ".price"')
            if toks[0][0] != "text":
                raise Mistake(number, f'{word} needs the thing\'s name in quotes: {toks[0][1]} isn\'t.', f'{word} "{toks[0][1]}"')
            thing = {"kind": kind, "name": toks[0][1]}
            if first:
                thing["first"] = True
            toks = toks[1:]
            if toks and toks[0] == ("word", "in"):
                if len(toks) < 2 or toks[1][0] != "text":
                    raise Mistake(number, "in needs the name of what it's in, in quotes.", f'{word} "Delete" in "my-old-key"')
                thing["within"] = toks[1][1]
                toks = toks[2:]
            return thing, toks


        def into(toks, number):
            """The [into NAME] at the end of a line: the name, and what's left."""
            if len(toks) >= 2 and toks[-2] == ("word", "into"):
                name = toks[-1][1]
                if toks[-1][0] != "word" or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
                    raise Mistake(number, f"into needs a name made of letters: {name} isn't one.", "read title into heading")
                return name, toks[:-2]
            return None, toks


        def nothing_after(toks, number, word):
            if toks:
                raise Mistake(number, f"{word} doesn't take {' '.join(v for _, v in toks)}.", f"{word} takes {WORDS[word][0] or 'nothing'}: {WORDS[word][2]}")


        def one_text(toks, number, word, what):
            if len(toks) != 1:
                raise Mistake(number, f"{word} takes {what}, as one text in quotes.", WORDS[word][2])
            return toks[0][1]


        def parse_line(number, source):
            toks = tokens(source, number)
            if not toks:
                return None
            kind, word = toks[0]
            rest = toks[1:]
            if kind != "word" or word.lower() not in WORDS:
                near = difflib.get_close_matches(word.lower(), WORDS, n=1)
                fix = f"Did you mean {near[0]}? " if near else ""
                raise Mistake(number, f'Straw doesn\'t know "{word}".', fix + "The words: " + ", ".join(WORDS))
            word = word.lower()
            if word in ("open", "go"):
                return Step(number, source, word, url=one_text(rest, number, word, "an address"))
            if word == "tab":
                return Step(number, source, word, text=one_text(rest, number, word, "part of the tab's address"))
            if word in ("back", "forward", "reload", "else"):
                nothing_after(rest, number, word)
                return Step(number, source, word)
            if word == "wait":
                gone = bool(rest) and rest[0] == ("word", "gone")
                if gone:
                    rest = rest[1:]
                if not rest:
                    if gone:
                        raise Mistake(number, "wait gone needs what's to go.", 'wait gone "Loading…"')
                    return Step(number, source, word, thing=None, gone=False, seconds=WAIT_SECONDS)
                thing, rest = target(rest, number, word)
                seconds = WAIT_SECONDS
                if rest:
                    if len(rest) != 1 or not re.fullmatch(r"\d+(\.\d+)?", rest[0][1]):
                        raise Mistake(number, f"wait takes a number of seconds after the thing, not {' '.join(v for _, v in rest)}.", 'wait "Results" 30')
                    seconds = float(rest[0][1])
                return Step(number, source, word, thing=thing, gone=gone, seconds=seconds)
            if word in ("click", "hover", "check", "uncheck"):
                thing, rest = target(rest, number, word)
                nothing_after(rest, number, word)
                return Step(number, source, word, thing=thing)
            if word in ("type", "select"):
                thing, rest = target(rest, number, word)
                return Step(number, source, word, thing=thing, text=one_text(rest, number, word, "what to put in it" if word == "type" else "the option"))
            if word == "press":
                key = one_text(rest, number, word, "a key")
                if key.lower() not in KEYS and len(key) != 1:
                    raise Mistake(number, f"press doesn't know the key {key}.", "Keys: Enter, Tab, Escape, Space, Backspace, Delete, ArrowUp, ArrowDown, ArrowLeft, ArrowRight, Home, End, PageUp, PageDown, or one character")
                return Step(number, source, word, key=key)
            if word == "scroll":
                if len(rest) == 1 and rest[0][0] == "word" and rest[0][1].lower() in ("down", "up", "top", "bottom"):
                    return Step(number, source, word, where=rest[0][1].lower(), thing=None)
                thing, rest = target(rest, number, word)
                nothing_after(rest, number, word)
                return Step(number, source, word, where=None, thing=thing)
            if word == "see":
                no = bool(rest) and rest[0] == ("word", "no")
                thing, rest = target(rest[1:] if no else rest, number, word)
                nothing_after(rest, number, word)
                return Step(number, source, word, thing=thing, no=no)
            if word == "if":
                if rest and rest[0] == ("word", "see"):
                    rest = rest[1:]
                no = bool(rest) and rest[0] == ("word", "no")
                if no:
                    rest = rest[1:]
                thing, rest = target(rest, number, word)
                nothing_after(rest, number, word)
                return Step(number, source, word, thing=thing, no=no)
            if word == "read":
                name, rest = into(rest, number)
                mode = "one"
                if rest and rest[0][0] == "word" and (rest[0][1] in ("all", "after") or (rest[0][1] == "links" and len(rest) > 1)):
                    mode, rest = rest[0][1], rest[1:]
                if mode == "one" and len(rest) == 1 and rest[0][0] == "word" and rest[0][1] in ("title", "url", "page", "links"):
                    return Step(number, source, word, mode=rest[0][1], thing=None, name=name)
                thing, rest = target(rest, number, word)
                nothing_after(rest, number, word)
                return Step(number, source, word, mode=mode, thing=thing, name=name)
            if word == "js":
                name, rest = into(rest, number)
                return Step(number, source, word, code=one_text(rest, number, word, "the JavaScript"), name=name)
            if word in ("set", "ask"):
                if len(rest) != 2 or rest[0][0] != "word" or rest[1][0] != "text" or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", rest[0][1]):
                    raise Mistake(number, f"{word} takes a name, then a text in quotes.", WORDS[word][2])
                return Step(number, source, word, name=rest[0][1], text=rest[1][1])
            if word in ("print", "confirm", "stop"):
                if not rest or any(k != "text" for k, _ in rest):
                    raise Mistake(number, f"{word} takes text in quotes.", WORDS[word][2])
                return Step(number, source, word, text=" ".join(v for _, v in rest))
            raise Mistake(number, f"{word} isn't finished.")  # every word above returns


        def parse(text):
            """The steps, with the lines under an if (and its else) inside it. Every mistake in the file is found here, before anything runs."""
            lines = []
            for number, raw in enumerate(text.splitlines(), 1):
                if not raw.strip() or raw.lstrip().startswith("#"):
                    continue
                lead = raw[: len(raw) - len(raw.lstrip())]
                if "\t" in lead:
                    raise Mistake(number, "This line is indented with a tab.", "Indent with spaces (two a level).")
                step = parse_line(number, raw.strip())
                if step is not None:
                    lines.append((len(lead), step))
            steps, _ = block(lines, 0, 0)
            return steps


        def block(lines, i, indent):
            """The steps at this indent, from line i on: them, and where the block ends."""
            steps = []
            while i < len(lines):
                at, s = lines[i]
                if at < indent:
                    break
                if at > indent:
                    raise Mistake(s.number, "This line is indented more than the one above it, which isn't an if or an else.",
                                  "Line it up with the line above (only the lines under an if or an else are indented).")
                i += 1
                if s.word == "else" and (not steps or steps[-1].word != "if" or steps[-1].has_else):
                    raise Mistake(s.number, "This else has no if just above it, at the same indent.", "Put it right after the if's indented lines.")
                if s.word in ("if", "else"):
                    if i >= len(lines) or lines[i][0] <= at:
                        raise Mistake(s.number, f"Nothing is indented under this {s.word}.", "Indent the lines it does by two spaces.")
                    body, i = block(lines, i, lines[i][0])
                    if s.word == "if":
                        s.body, s.has_else = body, False
                        steps.append(s)
                    else:
                        steps[-1].otherwise, steps[-1].has_else = body, True
                    continue
                steps.append(s)
            return steps, i


        def walk(steps):
            for s in steps:
                yield s
                yield from walk(s.body)
                yield from walk(s.otherwise)


        NAMES = re.compile(r"\{([A-Za-z_][A-Za-z0-9_]*|\d+)(\|[^}]*)?\}")


        def texts_of(step):
            for key in ("url", "text", "code", "key"):
                if key in step.parts:
                    yield step.parts[key]
            thing = step.parts.get("thing")
            if thing:
                yield thing["name"]
                if "within" in thing:
                    yield thing["within"]


        def check(steps, inputs):
            """Names used before anything gives them a value, and arguments no Input: line asks for, are mistakes too."""
            known = set()

            def go(steps):
                for s in steps:
                    for t in texts_of(s):
                        for m in NAMES.finditer(t):
                            name, default = m.group(1), m.group(2)
                            if name.isdigit() or name == "args" or default is not None:
                                continue
                            if name not in known:
                                raise Mistake(s.number, f"{{{name}}} has no value yet here.",
                                              f'Give it one first (set {name} "…", ask {name} "…", read … into {name}), or a default: {{{name}|something}}')
                    if s.word in ("set", "ask") or s.parts.get("name"):
                        known.add(s.parts["name"])
                    go(s.body)
                    go(s.otherwise)

            go(steps)
            return steps


        def declared_inputs(text):
            """The # Input: lines at the top (what the app asks for before it runs): (prompt, optional)."""
            found = []
            for raw in text.splitlines()[:60]:
                line = raw.strip()
                if not line:
                    continue
                if not line.startswith("#"):
                    break
                m = re.match(r"#\s*Input( text)?\s*(\(optional\))?\s*:\s*(.+)", line, re.I)
                if m and not m.group(1):
                    found.append((m.group(3).strip(), bool(m.group(2))))
            return found


        # ─── the page side: one small library, sent with each step ──────────────────

        PAGE = r"""
        const norm = (s) => (s || '').replace(/\s+/g, ' ').trim().toLowerCase().replace(/[\s:.…*⌘↩︎]+$/u, '').trim();
        const ACTIVE = 'a[href],button,input,select,textarea,summary,label,[role=button],[role=link],[role=tab],[role=menuitem],[role=menuitemcheckbox],[role=menuitemradio],[role=option],[role=checkbox],[role=radio],[role=switch],[role=combobox],[role=textbox],[role=searchbox],[contenteditable=""],[contenteditable=true],[onclick],[tabindex]:not([tabindex="-1"])';
        const FIELD = 'input:not([type=hidden]):not([type=button]):not([type=submit]):not([type=reset]):not([type=checkbox]):not([type=radio]),textarea,select,[contenteditable=""],[contenteditable=true],[role=textbox],[role=searchbox],[role=combobox]';
        function shown(el) {
          if (!(el instanceof Element) || !el.getClientRects().length) return false;
          const b = el.getBoundingClientRect();
          if (b.width === 0 && b.height === 0) return false;
          const cs = getComputedStyle(el);
          if (cs.visibility === 'hidden' || cs.display === 'none') return false;
          return !el.closest('[aria-hidden="true"]');
        }
        function textOf(el) { return (el.innerText || el.textContent || '').replace(/[ \t]+/g, ' ').replace(/\n\s*\n+/g, '\n').trim(); }
        function namesOf(el) {
          const out = [];
          const push = (v) => { if (v) out.push(v); };
          push(el.getAttribute('aria-label'));
          const by = el.getAttribute('aria-labelledby');
          if (by) push(by.split(/\s+/).map((id) => { const e = document.getElementById(id); return e ? textOf(e) : ''; }).join(' '));
          if (el.labels) for (const l of el.labels) push(textOf(l));
          for (const a of ['placeholder', 'title', 'alt']) push(el.getAttribute(a));
          if (el.tagName === 'INPUT' && ['submit', 'button', 'reset'].includes(el.type)) push(el.value);
          const t = textOf(el);
          if (t && t.length <= 300) push(t);
          return out.map((v) => v.replace(/\s+/g, ' ').trim()).filter(Boolean);
        }
        function rung(names, want) {
          let best = 0;
          for (const raw of names) {
            const n = norm(raw);
            if (!n) continue;
            if (n === want) return 3;
            if (n.startsWith(want)) best = Math.max(best, 2);
            else if (want.length >= 3 && n.includes(want)) best = Math.max(best, 1);
          }
          return best;
        }
        // What a click on it reaches: the button or link it's in; a label is its field.
        function active(el) {
          const a = el.closest(ACTIVE) || el;
          return a.tagName === 'LABEL' && a.control ? a.control : a;
        }
        // Everything on the page called `name` (or matching the selector), the best-named first: exact, then
        // starting with it, then having it in it. Buttons, links and fields before the words around them.
        function candidates(thing, root) {
          root = root || document;
          if (thing.kind === 'css') {
            let list;
            try { list = [...root.querySelectorAll(thing.name)]; } catch (e) { throw new Error('the selector ' + thing.name + " isn't one: " + e.message); }
            return list.filter(shown);
          }
          const want = norm(thing.name);
          const scored = new Map();
          const add = (el, r) => { if (r > 0 && shown(el) && (scored.get(el) || 0) < r) scored.set(el, r); };
          for (const el of root.querySelectorAll(ACTIVE)) add(el, rung(namesOf(el), want));
          const walker = document.createTreeWalker(root === document ? document.body || document.documentElement : root, NodeFilter.SHOW_TEXT);
          for (let n = walker.nextNode(); n; n = walker.nextNode()) {
            if (!norm(n.nodeValue).includes(want.slice(0, 12)) && !norm(n.parentElement && n.parentElement.textContent).includes(want.slice(0, 12))) continue;
            const el = n.parentElement;
            if (el) add(el, rung(namesOf(el), want));
          }
          for (const el of root.querySelectorAll('[placeholder],[aria-label],[title],img[alt]')) add(el, rung(namesOf(el), want));
          if (!scored.size) return [];
          const top = Math.max(...scored.values());
          let found = [...scored.entries()].filter(([, r]) => r === top).map(([el]) => el);
          // The deepest of nested matches (a <span> in a <button> both called Save is one thing).
          found = found.filter((el) => !found.some((o) => o !== el && el.contains(o) && active(o) === active(el)));
          const actives = found.filter((el) => el.matches(ACTIVE) || el.closest(ACTIVE));
          return actives.length ? actives : found;
        }
        function find(thing) {
          let found;
          if (thing.within) {
            const holders = candidates({ kind: 'name', name: thing.within });
            found = [];
            for (const h of holders) {
              for (let box = h; box && box !== document.documentElement; box = box.parentElement) {
                const inside = candidates(thing, box).filter((el) => box.contains(el));
                if (inside.length) { found.push(...inside); break; }
              }
            }
          } else {
            found = candidates(thing);
          }
          return [...new Set(found)];
        }
        function where(el) {
          const box = el.closest('tr,li,[role=row],[role=listitem],article,section,form,fieldset,[role=dialog],dialog,nav,header,footer');
          const own = textOf(el);
          let t = box ? textOf(box).replace(own, '').replace(/\s+/g, ' ').trim() : '';
          return t.slice(0, 60);
        }
        function nearby() {
          const seen = new Set();
          for (const el of document.querySelectorAll(ACTIVE + ',h1,h2,h3,h4,th,dt,legend')) {
            if (!shown(el)) continue;
            const n = namesOf(el)[0];
            if (n && n.length <= 80) seen.add(n);
            if (seen.size >= 400) break;
          }
          return [...seen];
        }
        function missing(thing) { return { ok: false, why: 'not_found', near: thing.kind === 'css' ? [] : nearby() }; }
        function one(thing) {
          const found = find(thing);
          if (!found.length) return [null, missing(thing)];
          const distinct = [...new Set(found.map(active))];
          // first: the one highest on the page, in the order it's written.
          if (thing.first) return [distinct.sort((a, b) => (a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING ? -1 : 1))[0], null];
          if (distinct.length > 1) return [null, { ok: false, why: 'many', count: distinct.length, where: distinct.slice(0, 5).map(where) }];
          return [distinct[0], null];
        }
        function fieldOf(el) {
          if (el.matches(FIELD)) return el;
          if (el.tagName === 'LABEL' && el.control) return el.control;
          const inside = [...el.querySelectorAll(FIELD)].find(shown);
          if (inside) return inside;
          // The field beside its words (<div><span>Email</span><input></div>): in the box around them, when
          // that box has just the one field.
          for (let box = el.parentElement, k = 0; box && k < 3; box = box.parentElement, k++) {
            const fields = [...box.querySelectorAll(FIELD)].filter(shown);
            if (fields.length > 1) break;
            if (fields.length === 1) return fields[0];
          }
          return null;
        }
        function pointer(el, types) {
          const b = el.getBoundingClientRect();
          const at = { bubbles: true, cancelable: true, view: window, clientX: b.left + b.width / 2, clientY: b.top + b.height / 2 };
          for (const t of types) {
            const E = t.startsWith('pointer') && window.PointerEvent ? PointerEvent : MouseEvent;
            el.dispatchEvent(new E(t, Object.assign({ pointerType: 'mouse', isPrimary: true }, at)));
          }
        }
        function put(el, text) {
          el.focus();
          if (el.isContentEditable) {
            document.execCommand('selectAll', false, null);
            document.execCommand('insertText', false, text);
            return;
          }
          const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
          const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
          setter.call(el, text);
          el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: text }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
        }
        function valueOf(el) {
          if (el.tagName === 'SELECT') return el.selectedOptions[0] ? textOf(el.selectedOptions[0]) : '';
          if (el.tagName === 'INPUT' && ['checkbox', 'radio'].includes(el.type)) return el.checked ? 'checked' : 'unchecked';
          if ('value' in el && el.matches('input,textarea')) return el.value;
          return textOf(el);
        }
        function besideOf(el) {
          if (el.tagName === 'LABEL' && el.control) return valueOf(el.control);
          const dd = el.closest('dt');
          if (dd && dd.nextElementSibling) return textOf(dd.nextElementSibling);
          const cell = el.closest('th,td');
          if (cell && cell.nextElementSibling) return textOf(cell.nextElementSibling);
          for (let e = el; e && e !== document.body; e = e.parentElement) {
            if (e.nextElementSibling && textOf(e.nextElementSibling)) return textOf(e.nextElementSibling);
          }
          return '';
        }
        const STATE = 'input[type=checkbox],input[type=radio],[role=checkbox],[role=radio],[role=switch],[role=menuitemcheckbox]';
        function isOn(el) { return el.matches('input') ? el.checked : el.getAttribute('aria-checked') === 'true'; }
        const DO = {
          count(p) { return { ok: true, count: find(p.thing).length }; },
          click(p) {
            const [el, no] = one(p.thing); if (no) return no;
            el.scrollIntoView({ block: 'center', inline: 'center' });
            pointer(el, ['pointerover', 'pointerenter', 'mouseover', 'pointerdown', 'mousedown']);
            if (el.focus) el.focus();
            pointer(el, ['pointerup', 'mouseup']);
            el.click();
            return { ok: true, what: namesOf(el)[0] || el.tagName.toLowerCase() };
          },
          hover(p) {
            const [el, no] = one(p.thing); if (no) return no;
            el.scrollIntoView({ block: 'center' });
            pointer(el, ['pointerover', 'pointerenter', 'mouseover', 'mouseenter', 'pointermove', 'mousemove']);
            return { ok: true };
          },
          type(p) {
            const [el, no] = one(p.thing); if (no) return no;
            const f = fieldOf(el);
            if (!f) return { ok: false, why: 'not_field' };
            f.scrollIntoView({ block: 'center' });
            put(f, p.text);
            return { ok: true, now: valueOf(f) };
          },
          select(p) {
            const [el, no] = one(p.thing); if (no) return no;
            const s = el.tagName === 'SELECT' ? el : fieldOf(el);
            if (!s || s.tagName !== 'SELECT') return { ok: false, why: 'not_select' };
            const want = norm(p.text);
            const opts = [...s.options];
            const o = opts.find((x) => norm(x.text) === want) || opts.find((x) => norm(x.text).startsWith(want)) || opts.find((x) => norm(x.value) === want);
            if (!o) return { ok: false, why: 'no_option', options: opts.map((x) => textOf(x)).slice(0, 30) };
            s.value = o.value;
            s.dispatchEvent(new Event('input', { bubbles: true }));
            s.dispatchEvent(new Event('change', { bubbles: true }));
            return { ok: true, now: textOf(o) };
          },
          check(p) {
            const [el, no] = one(p.thing); if (no) return no;
            const box = el.matches(STATE) ? el : (el.tagName === 'LABEL' && el.control) || el.querySelector(STATE) || el;
            if (isOn(box) !== p.on) { box.click(); }
            return { ok: true, now: isOn(box) ? 'on' : 'off' };
          },
          scroll(p) {
            if (p.where) {
              const h = innerHeight * 0.8;
              if (p.where === 'down') scrollBy(0, h); else if (p.where === 'up') scrollBy(0, -h);
              else if (p.where === 'top') scrollTo(0, 0); else scrollTo(0, document.documentElement.scrollHeight);
              return { ok: true };
            }
            const found = find(p.thing);
            if (!found.length) return missing(p.thing);
            found[0].scrollIntoView({ block: 'center' });
            return { ok: true };
          },
          key(p) {
            const el = document.activeElement || document.body;
            const opts = { key: p.key, code: p.code, keyCode: p.keyCode, which: p.keyCode, bubbles: true, cancelable: true };
            const down = el.dispatchEvent(new KeyboardEvent('keydown', opts));
            el.dispatchEvent(new KeyboardEvent('keypress', opts));
            if (down && p.key.length === 1 && el.matches && el.matches('input,textarea')) put(el, el.value + p.key);
            if (down && p.key === 'Backspace' && el.matches && el.matches('input,textarea')) put(el, el.value.slice(0, -1));
            el.dispatchEvent(new KeyboardEvent('keyup', opts));
            if (down && p.key === 'Enter' && el.form && el.tagName === 'INPUT') {
              if (el.form.requestSubmit) el.form.requestSubmit(); else el.form.submit();
            }
            if (down && p.key === 'Tab') {
              const all = [...document.querySelectorAll(ACTIVE)].filter((e) => shown(e) && !e.disabled);
              const next = all[all.indexOf(el) + 1];
              if (next) next.focus();
            }
            return { ok: true, on: el.tagName ? el.tagName.toLowerCase() : 'page' };
          },
          read(p) {
            if (p.mode === 'title') return { ok: true, text: document.title };
            if (p.mode === 'url') return { ok: true, text: location.href };
            if (p.mode === 'page') return { ok: true, text: textOf(document.body) };
            if (p.mode === 'links') {
              let links = [...document.querySelectorAll('a[href]')].filter(shown);
              if (p.thing) {
                // The links among the things it names: each one's own, or the one it's in, or the first in it.
                const found = find(p.thing);
                if (!found.length) return missing(p.thing);
                links = found.map((el) => el.closest('a[href]') || el.querySelector('a[href]')).filter(Boolean);
              }
              const rows = links.map((a) => (textOf(a).replace(/\s+/g, ' ') || a.href) + '\t' + a.href);
              return { ok: true, text: [...new Set(rows)].join('\n') };
            }
            const found = find(p.thing);
            if (!found.length) return missing(p.thing);
            if (p.mode === 'all') return { ok: true, text: found.map(valueOf).filter((t) => t !== '').join('\n'), count: found.length };
            if (p.mode === 'after') return { ok: true, text: besideOf(found[0]) };
            const el = found[0];
            return { ok: true, text: valueOf(el.tagName === 'LABEL' && el.control ? el.control : el) };
          },
          history(p) {
            if (p.go === 'to') location.assign(p.url);
            else if (p.go === 'back') history.back(); else if (p.go === 'forward') history.forward(); else location.reload();
            return { ok: true };
          },
        };
        """


        class Browser:
            """The tab in front of Chrome, through browser.sh (which says what to switch on when Chrome won't be driven)."""

            def __init__(self, helper):
                self.helper = helper

            def sh(self, *args):
                r = subprocess.run([self.helper, *args], capture_output=True, text=True)
                if r.returncode != 0:
                    raise Stop((r.stderr or r.stdout).strip() or f"browser.sh {args[0]} failed ({r.returncode})")
                return r.stdout.rstrip("\n")

            def do(self, op, **p):
                code = PAGE + "\nconst P = " + json.dumps(p) + ";\nreturn JSON.stringify(DO." + op + "(P));"
                out = self.sh("js", code)
                try:
                    return json.loads(out)
                except ValueError:
                    raise Stop("The page gave back something that isn't an answer: " + out[:200])

            def settle(self):
                """After something that may load a page: a moment for it to start, then until it's loaded."""
                time.sleep(0.4)
                self.sh("wait")


        class Run:
            def __init__(self, steps, args, browser, inputs, path):
                self.steps, self.args, self.browser, self.inputs, self.path = steps, args, browser, inputs, path
                self.values = {}

            def say(self, text):
                print(text, file=sys.stderr, flush=True)

            def out(self, text):
                print(text, flush=True)

            def address(self, url, number):
                """An address with its {values} in: after the ?, each made safe for it (spaces, &, #…)."""
                head, mark, query = url.partition("?")
                return self.fill(head, number) + mark + self.fill(query, number, urllib.parse.quote_plus)

            def fill(self, text, number, safe=lambda v: v):
                def one(m):
                    return safe(value(m))

                def value(m):
                    name, default = m.group(1), m.group(2)
                    if name == "args":
                        return " ".join(self.args)
                    if name.isdigit():
                        k = int(name)
                        if 1 <= k <= len(self.args) and self.args[k - 1] != "":
                            return self.args[k - 1]
                        if default is not None:
                            return default[1:]
                        prompt, optional = self.inputs[k - 1] if 0 < k <= len(self.inputs) else (None, False)
                        if optional:
                            return ""
                        raise Stop(f"Line {number} needs {{{k}}}" + (f" ({prompt})" if prompt else "") + ": run it with " +
                                   ("an argument" if k == 1 else f"{k} arguments") + ".")
                    if name in self.values and self.values[name] != "":
                        return self.values[name]
                    if default is not None:
                        return default[1:]
                    return self.values.get(name, "")
                return NAMES.sub(one, text)

            def thing(self, step):
                t = dict(step.thing)
                t["name"] = self.fill(t["name"], step.number)
                if "within" in t:
                    t["within"] = self.fill(t["within"], step.number)
                return t

            def shown(self, thing):
                said = f'css "{thing["name"]}"' if thing["kind"] == "css" else f'"{thing["name"]}"'
                return said + (f' in "{thing["within"]}"' if "within" in thing else "")

            def refuse(self, step, answer, thing=None):
                why = answer.get("why")
                name = self.shown(thing) if thing else ""
                if why == "not_found":
                    names = {n.lower(): n for n in answer.get("near", [])}
                    near = [names[n] for n in difflib.get_close_matches((thing or {}).get("name", "").lower(), list(names), n=4, cutoff=0.45)]
                    fix = ("Near it on the page: " + ", ".join(f'"{n}"' for n in near) + ".") if near else \
                        "Nothing like it is on the page either: is it the page you think? (read title, read url)"
                    called = "matches" if thing and thing["kind"] == "css" else "is called"
                    raise Stop(f"Nothing on the page {called} {name}. {fix}")
                if why == "many":
                    where = [w for w in answer.get("where", []) if w]
                    hint = (f' Say which, by what\'s beside it: {step.word} {name} in "{where[0]}"' if where else
                            f' Say which, by what it\'s in: {step.word} {name} in "…"')
                    hint += f" (or {step.word} first {name}: the one highest on the page)"
                    raise Stop(f"{answer.get('count')} things on the page are called {name}.{hint}")
                if why == "not_field":
                    raise Stop(f"{name} isn't a field to type in, and there's no field beside it.")
                if why == "not_select":
                    raise Stop(f"{name} isn't a menu to pick from (a <select>): click it, then click the option.")
                if why == "no_option":
                    raise Stop(f"{name} has no option \"{self.fill(step.text, step.number)}\". Its options: " + ", ".join(answer.get("options", [])))
                raise Stop(answer.get("error") or f"It didn't work ({answer})")

            def find_count(self, thing):
                return self.browser.do("count", thing=thing).get("count", 0)

            def wait_for(self, thing, gone, seconds):
                end = time.time() + seconds
                while True:
                    try:
                        n = self.find_count(thing)
                    except Stop:
                        n = None  # between two pages: the next look will see the new one
                    if n is not None and (n == 0) == gone:
                        return True
                    if time.time() >= end:
                        return False
                    time.sleep(0.5)

            def dialog(self, script):
                # In front of everything, so it's seen: the question is what the run waits on.
                r = subprocess.run(["osascript", "-e", "activate", "-e", script], capture_output=True, text=True)
                return r.returncode, r.stdout.strip()

            def keep(self, step, text):
                if step.parts.get("name"):
                    self.values[step.name] = text
                else:
                    self.out(text)

            def go(self, steps):
                for s in steps:
                    self.step(s)

            def step(self, s):
                w, b = s.word, self.browser
                self.say(f"→ {self.fill(s.source, s.number)}")
                if w in ("open", "go"):
                    url = self.address(s.url, s.number)
                    if w == "open":
                        self.say("  " + b.sh("open", url))
                    else:
                        b.do("history", go="to", url=url if "://" in url or url.startswith("about:") else "https://" + url)
                        b.settle()
                        self.say("  " + b.do("read", mode="title").get("text", ""))
                elif w == "tab":
                    self.say("  " + b.sh("focus", self.fill(s.text, s.number)))
                elif w in ("back", "forward", "reload"):
                    b.do("history", go=w)
                    b.settle()
                elif w == "wait":
                    if s.thing is None:
                        b.sh("wait")
                    else:
                        thing = self.thing(s)
                        took = f"{s.seconds:g} second" + ("" if s.seconds == 1 else "s")
                        if not self.wait_for(thing, s.gone, s.seconds):
                            raise Stop(f"{self.shown(thing)} was still there after {took}." if s.gone
                                       else f"{self.shown(thing)} didn't show in {took}. " + self.near_hint(thing))
                elif w in ("click", "hover"):
                    thing = self.thing(s)
                    a = b.do(w, thing=thing)
                    if not a.get("ok"):
                        self.refuse(s, a, thing)
                    if w == "click":
                        b.settle()
                elif w in ("type", "select"):
                    thing = self.thing(s)
                    a = b.do(w, thing=thing, text=self.fill(s.text, s.number))
                    if not a.get("ok"):
                        self.refuse(s, a, thing)
                elif w == "press":
                    key, code = KEYS.get(s.key.lower(), (s.key, ord(s.key[0].upper())))
                    b.do("key", key=key, code=key if len(key) > 1 else "Key" + key.upper(), keyCode=code)
                    if key == "Enter":
                        b.settle()
                elif w in ("check", "uncheck"):
                    thing = self.thing(s)
                    a = b.do("check", thing=thing, on=w == "check")
                    if not a.get("ok"):
                        self.refuse(s, a, thing)
                elif w == "scroll":
                    a = b.do("scroll", where=s.where, thing=self.thing(s) if s.thing else None)
                    if not a.get("ok"):
                        self.refuse(s, a, self.thing(s))
                elif w == "see":
                    thing = self.thing(s)
                    n = self.find_count(thing)
                    if s.no and n:
                        raise Stop(f"{self.shown(thing)} is on the page, and the script says it shouldn't be.")
                    if not s.no and not n:
                        raise Stop(f"{self.shown(thing)} isn't on the page. " + self.near_hint(thing))
                elif w == "if":
                    thing = self.thing(s)
                    there = self.find_count(thing) > 0
                    if there != s.no:
                        self.say("  yes")
                        self.go(s.body)
                    else:
                        self.say("  no")
                        self.go(s.otherwise)
                elif w == "read":
                    thing = self.thing(s) if s.thing else None
                    a = b.do("read", mode=s.mode, thing=thing)
                    if not a.get("ok"):
                        self.refuse(s, a, thing)
                    self.keep(s, a.get("text", ""))
                elif w == "js":
                    self.keep(s, lines_of(b.sh("js", self.fill(s.code, s.number))))
                elif w == "set":
                    self.values[s.name] = self.fill(s.text, s.number)
                elif w == "print":
                    self.out(self.fill(s.text, s.number))
                elif w == "ask":
                    q = self.fill(s.text, s.number)
                    code, answer = self.dialog(f'text returned of (display dialog {applescript(q)} default answer "" '
                                               f'with title {applescript(self.title())} buttons {{"Stop", "Go On"}} default button "Go On" cancel button "Stop")')
                    if code != 0:
                        raise Stop(f"Stopped: you chose Stop when asked {q}")
                    self.values[s.name] = answer
                elif w == "confirm":
                    q = self.fill(s.text, s.number)
                    # Stop is the default: Return can't say yes for you.
                    code, _ = self.dialog(f'display dialog {applescript(q)} with title {applescript(self.title())} '
                                          f'buttons {{"Stop", "Go On"}} default button "Stop" cancel button "Stop" with icon caution')
                    if code != 0:
                        raise Stop(f"Stopped: you chose Stop at {q}")
                elif w == "stop":
                    raise Stop(self.fill(s.text, s.number))

            def near_hint(self, thing):
                if thing["kind"] == "css":
                    return "Is it the page you think? (read url)"
                a = self.browser.do("read", mode="title")
                return f"The page in front is “{a.get('text', '')}”."

            def title(self):
                return os.path.splitext(os.path.basename(self.path))[0] + " (Straw)"


        def lines_of(out):
            """What js gave back: a list (browser.sh gives it as JSON) a line each; anything else as it is."""
            if out.startswith("[") and out.endswith("]"):
                try:
                    items = json.loads(out)
                except ValueError:
                    return out
                if isinstance(items, list) and all(isinstance(i, (str, int, float)) for i in items):
                    return "\n".join(str(i) for i in items)
            return out


        def applescript(text):
            return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


        def plan(steps, depth=0):
            """What it would do, a line a step (--check)."""
            for s in steps:
                print("  " * depth + f"{s.number:>3}  {s.source}")
                plan(s.body, depth + 1)
                if s.otherwise:
                    print("  " * depth + "     else")
                    plan(s.otherwise, depth + 1)


        def words():
            print("Straw: Chrome driven by what's on the page, one plain line at a time.")
            print("Run a .straw file: straw.py FILE [words…]  (they're {1}, {2}…; {args} is all of them)")
            print("A THING is its name in quotes, as written on the page (\"Sign in\"), or css \"selector\";")
            print("either can be narrowed down with in \"what it's in\", or first before it: the highest on the page of several.\n")
            for word, (takes, does, example) in WORDS.items():
                print(f"  {word} {takes}".rstrip())
                print(f"      {does}")
                print(f"      e.g. {example}")


        def main(argv):
            check_only = bool(argv) and argv[0] == "--check"
            if check_only:
                argv = argv[1:]
            if not argv:
                words()
                return 0
            path, args = argv[0], argv[1:]
            try:
                with open(path, encoding="utf-8") as f:
                    text = f.read()
            except OSError as e:
                print(f"Couldn't read {path}: {e.strerror}.", file=sys.stderr)
                return 1
            name = os.path.basename(path)
            inputs = declared_inputs(text)
            try:
                steps = check(parse(text), inputs)
            except Mistake as m:
                lines = text.splitlines()
                print(f"{name}, line {m.line}: {m.message}", file=sys.stderr)
                if 0 < m.line <= len(lines):
                    print(f"  {lines[m.line - 1].strip()}", file=sys.stderr)
                if m.fix:
                    print(f"Fix: {m.fix}", file=sys.stderr)
                print("Nothing ran.", file=sys.stderr)
                return 2
            if check_only:
                count = sum(1 for _ in walk(steps))
                print(f"✅ {name}: {count} step{'s' if count != 1 else ''}, no mistakes. It would:")
                plan(steps)
                return 0
            helper = os.environ.get("STRAW_BROWSER") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "browser.sh")
            if not os.path.exists(helper):
                print("Straw drives Chrome through browser.sh, and it isn't beside straw.py.", file=sys.stderr)
                print("Fix: the Browser grid → Add the Examples puts it back.", file=sys.stderr)
                return 1
            run = Run(steps, args, Browser(helper), inputs, path)
            try:
                run.go(steps)
            except Stop as e:
                print(f"❌ {e}", file=sys.stderr)
                return 1
            except KeyboardInterrupt:
                return 130
            run.say("✅ Done.")
            return 0


        if __name__ == "__main__":
            sys.exit(main(sys.argv[1:]))
        """# + "\n"),
        ("browser/hacker-news.straw", #"""
        # The top stories on Hacker News right now, a line each
        #
        # Straw: a line is a word and what it works on (open, wait, read…); see the Straw guide.
        open news.ycombinator.com
        wait css ".titleline"
        read all css ".titleline > a"
        """# + "\n"),
        ("browser/wikipedia-article.straw", #"""
        # Looks something up on Wikipedia in Chrome: the article's title and its first paragraph
        #
        # Input: What to look up
        # Why: It's searched for on Wikipedia as typed; the best match is read
        open "en.wikipedia.org/w/index.php?search={1}&go=Go"
        wait css "#firstHeading"
        # No article by that exact name: Wikipedia lists what it found, the best match first.
        if see css ".mw-search-results-container"
          click css ".mw-search-result-heading a[data-serp-pos='0']"
          wait gone css ".mw-search-results-container"
        read css "#firstHeading"
        read css ".mw-parser-output > p:not(.mw-empty-elt), .mw-parser-output > section > p:not(.mw-empty-elt)"
        """# + "\n"),
        ("browser/page-outline.straw", #"""
        # The page in front of Chrome, in outline: its title, its address and its headings
        read title
        read url
        read all css "h1, h2, h3"
        """# + "\n"),
        ("browser/dismiss-cookies.straw", #"""
        # Clicks away the cookie banner on the page in front, if it has one (Reject all first, else Accept all, Got it, OK)
        set clicked "nothing: no cookie banner found"
        if see "Reject all"
          click "Reject all"
          set clicked "Reject all"
        if see "Accept all"
          click "Accept all"
          set clicked "Accept all"
        if see "Got it"
          click "Got it"
          set clicked "Got it"
        print "Cookie banner: clicked {clicked}"
        """# + "\n"),
        ("browser/fill-search.straw", #"""
        # Searches the page in front with its own search box: types the words, presses Enter, gives back the new page's title
        #
        # Input: What to search for
        # Why: It's typed into the search box of the page in front of Chrome, as is
        # Input (optional): The search box's name, as written on the page (Search unless set)
        type "{2|Search}" "{1}"
        press Enter
        wait
        read title
        """# + "\n"),
        ("browser/copy-link.sh", #"""
        #!/bin/bash
        # Copies the page in front of Chrome as a link: Markdown [title](address) unless you ask for plain, html or the address alone
        #
        # Input (optional): markdown, plain, html or url (markdown unless set)
        set -uo pipefail

        here="$(cd "$(dirname "$0")" && pwd)"
        title=$("$here/browser.sh" title) || exit 1
        url=$("$here/browser.sh" url) || exit 1
        case "${1:-markdown}" in
          markdown|md) link="[$title]($url)" ;;
          plain|text) link="$title — $url" ;;
          html) link="<a href=\"$url\">$title</a>" ;;
          url|address) link="$url" ;;
          *) echo "copy-link markdown, plain, html or url" >&2; exit 1 ;;
        esac
        printf '%s' "$link" | pbcopy
        echo "Copied: $link"
        """# + "\n"),
        ("browser/archive-page.sh", #"""
        #!/bin/bash
        # Opens the page in front of Chrome (or an address you give) in the Wayback Machine: its saved copies, or --save to keep one now
        #
        # Input (optional): An address (the page in front unless set)
        set -uo pipefail

        here="$(cd "$(dirname "$0")" && pwd)"
        save=0
        if [ "${1:-}" = "--save" ]; then save=1; shift; fi
        url="${1:-}"
        if [ -z "$url" ]; then url=$("$here/browser.sh" url) || exit 1; fi
        if [ "$save" = 1 ]; then
          "$here/browser.sh" open "https://web.archive.org/save/$url" >/dev/null || exit 1
          echo "Asked the Wayback Machine to save $url (its page in Chrome says when it's done)."
        else
          "$here/browser.sh" open "https://web.archive.org/web/*/$url" >/dev/null || exit 1
          echo "The Wayback Machine's copies of $url are open in Chrome."
        fi
        """# + "\n"),
        ("browser/find-tab.sh", #"""
        #!/bin/bash
        # Finds the Chrome tab whose title or address has your words in it, and brings it to the front (the others that match are listed)
        #
        # Input: Words in the tab's title or address
        set -uo pipefail

        here="$(cd "$(dirname "$0")" && pwd)"
        want="$*"
        if [ -z "$want" ]; then echo "Which tab? find-tab github, find-tab inbox" >&2; exit 1; fi
        tabs=$("$here/browser.sh" tabs --all) || exit 1
        matches=$(printf '%s\n' "$tabs" | grep -iF -- "$want" || true)
        if [ -z "$matches" ]; then
          echo "No tab has \"$want\" in its title or address ($(printf '%s\n' "$tabs" | grep -c . ) tabs open)." >&2
          exit 1
        fi
        first_url=$(printf '%s\n' "$matches" | head -1 | cut -f2)
        title=$("$here/browser.sh" focus "$first_url") || exit 1
        echo "In front: $title"
        others=$(printf '%s\n' "$matches" | tail -n +2 | cut -f1)
        if [ -n "$others" ]; then
          echo "Also matching:"
          printf '%s\n' "$others" | sed 's/^/  /'
        fi
        """# + "\n"),
        ("browser/site-search.sh", #"""
        #!/bin/bash
        # Searches a well-known site for you, in Chrome: YouTube, Amazon, GitHub, Wikipedia, Reddit, Stack Overflow, Google Maps and 40 more, by name
        #
        # Input: The site, then what to search it for (youtube lofi hip hop, amazon usb-c hub, maps coffee near me)
        # Why: The site's own results page is opened in Chrome, in front, as if you'd typed the search there
        #
        #   site-search.sh youtube lofi hip hop       YouTube's results, in a new tab in front
        #   site-search.sh --url amazon usb-c hub     just the address (for a flow, or another browser)
        #   site-search.sh list                       every site it knows, and the names it answers to
        set -uo pipefail

        # Each site: its names (the first is shown), then its search address, with %s where the words go.
        SITES='google g|https://www.google.com/search?q=%s
        images pictures|https://www.google.com/search?tbm=isch&q=%s
        maps map directions|https://www.google.com/maps/search/%s
        news|https://news.google.com/search?q=%s
        scholar papers|https://scholar.google.com/scholar?q=%s
        translate|https://translate.google.com/?sl=auto&tl=en&text=%s
        youtube yt|https://www.youtube.com/results?search_query=%s
        youtube-music music|https://music.youtube.com/search?q=%s
        wikipedia wiki w|https://en.wikipedia.org/w/index.php?search=%s
        duckduckgo ddg|https://duckduckgo.com/?q=%s
        bing|https://www.bing.com/search?q=%s
        perplexity|https://www.perplexity.ai/search?q=%s
        claude|https://claude.ai/new?q=%s
        chatgpt|https://chatgpt.com/?q=%s
        wolfram wolframalpha|https://www.wolframalpha.com/input?i=%s
        amazon|https://www.amazon.com/s?k=%s
        ebay|https://www.ebay.com/sch/i.html?_nkw=%s
        etsy|https://www.etsy.com/search?q=%s
        walmart|https://www.walmart.com/search?q=%s
        github gh|https://github.com/search?q=%s&type=repositories
        github-code code|https://github.com/search?q=%s&type=code
        stackoverflow so|https://stackoverflow.com/search?q=%s
        mdn|https://developer.mozilla.org/en-US/search?q=%s
        apple-developer swift|https://developer.apple.com/search/?q=%s
        npm|https://www.npmjs.com/search?q=%s
        pypi pip|https://pypi.org/search/?q=%s
        crates rust|https://crates.io/search?q=%s
        docker dockerhub|https://hub.docker.com/search?q=%s
        huggingface hf|https://huggingface.co/models?search=%s
        arxiv|https://arxiv.org/search/?query=%s&searchtype=all
        hackernews hn|https://hn.algolia.com/?q=%s
        reddit|https://www.reddit.com/search/?q=%s
        x twitter|https://x.com/search?q=%s
        linkedin|https://www.linkedin.com/search/results/all/?keywords=%s
        pinterest|https://www.pinterest.com/search/pins/?q=%s
        imdb movie movies|https://www.imdb.com/find/?q=%s
        rottentomatoes rt|https://www.rottentomatoes.com/search?search=%s
        netflix|https://www.netflix.com/search?q=%s
        spotify|https://open.spotify.com/search/%s
        apple-music|https://music.apple.com/us/search?term=%s
        soundcloud|https://soundcloud.com/search?q=%s
        twitch|https://www.twitch.tv/search?term=%s
        vimeo|https://vimeo.com/search?q=%s
        genius lyrics|https://genius.com/search?q=%s
        goodreads books|https://www.goodreads.com/search?q=%s
        archive wayback|https://archive.org/search?query=%s
        dictionary define|https://www.merriam-webster.com/dictionary/%s
        thesaurus synonyms|https://www.merriam-webster.com/thesaurus/%s
        unsplash photos|https://unsplash.com/s/photos/%s
        yelp|https://www.yelp.com/search?find_desc=%s
        tripadvisor|https://www.tripadvisor.com/Search?q=%s'

        # Text made safe for an address: each byte but letters, digits and -._~ as %XX (a space is %20, é is %C3%A9).
        encode() {
          printf '%s' "$1" | od -An -tx1 -v | LC_ALL=C awk '{
            for (i = 1; i <= NF; i++) {
              n = (index("0123456789abcdef", substr($i, 1, 1)) - 1) * 16 + index("0123456789abcdef", substr($i, 2, 1)) - 1
              c = sprintf("%c", n)
              if (n < 128 && c ~ /[A-Za-z0-9._~-]/) printf "%s", c; else printf "%%%s", toupper($i)
            }
          }'
        }

        # The search address of the site a name means (nothing, and a failure, when it means none).
        template() {
          printf '%s\n' "$SITES" | awk -F'|' -v want="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" '
            { n = split($1, names, " "); for (i = 1; i <= n; i++) if (names[i] == want) { print $2; found = 1; exit } }
            END { exit !found }'
        }

        # Every site: its name, where it is, and the other names it answers to.
        sites() {
          printf '%s\n' "$SITES" | awk -F'|' '{
            n = split($1, names, " "); host = $2; sub(/^https:\/\//, "", host); sub(/\/.*/, "", host)
            also = ""; for (i = 2; i <= n; i++) also = also (i > 2 ? ", " : "") names[i]
            printf "%-16s %s%s\n", names[1], host, (also == "" ? "" : " (or: " also ")")
          }'
        }

        only_url=false
        if [ "${1:-}" = "--url" ]; then only_url=true; shift; fi
        case "${1:-}" in
          list|--list|sites) sites; exit 0 ;;
          "") echo "Which site, and what? (site-search.sh youtube lofi hip hop) The sites:" >&2; sites >&2; exit 1 ;;
        esac
        site="$1"
        shift
        if ! url=$(template "$site"); then
          echo "site-search doesn't know \"$site\". site-search.sh list says every site it knows." >&2
          exit 1
        fi
        if [ $# -eq 0 ]; then
          echo "What should $site be searched for? (site-search.sh $site …)" >&2
          exit 1
        fi
        # The words go where the %s is (one in each address).
        address="${url%%\%s*}$(encode "$*")${url#*\%s}"
        if $only_url; then
          printf '%s\n' "$address"
          exit 0
        fi
        browser="$(dirname "$0")/browser.sh"
        if [ ! -f "$browser" ]; then
          echo "This needs browser.sh beside it, in the browser folder (Add the Examples on the Browser grid puts it back)." >&2
          exit 1
        fi
        title=$(bash "$browser" open "$address") || exit 1
        echo "Searched $site for \"$*\": ${title:-$address}"
        """# + "\n"),
        ("browser/youtube-videos.straw", #"""
        # Searches YouTube in Chrome: the top videos, a line each (the title, a tab, the address)
        #
        # Input: What to search YouTube for
        # Why: It's searched for on YouTube as typed, and the results page is read
        open "www.youtube.com/results?search_query={args}"
        wait css "ytd-video-renderer a#video-title"
        # Each video's own address (watch?v=…), without the mix and tracking YouTube adds to it.
        js "[...document.querySelectorAll('ytd-video-renderer a#video-title')].slice(0, 15).map(a => a.textContent.trim() + '\t' + 'https://www.youtube.com/watch?v=' + new URL(a.href).searchParams.get('v'))"
        """# + "\n"),
        ("browser/youtube-play.straw", #"""
        # Plays the first YouTube video for what you search for, in Chrome, in front
        #
        # Input: What to play on YouTube
        # Why: It's searched for on YouTube as typed, and the first video (not a mix or a channel) is played
        open "www.youtube.com/results?search_query={args}"
        wait css "ytd-video-renderer a#video-title"
        read css "ytd-video-renderer a#video-title" into title
        click first css "ytd-video-renderer a#video-title"
        wait css "video"
        print "Playing: {title}"
        """# + "\n"),
        ("browser/youtube-latest.straw", #"""
        # A YouTube channel's latest videos, newest first, a line each (the title, a tab, the address)
        #
        # Input: The channel's handle, as in its address (youtube.com/@LofiGirl is LofiGirl)
        # Why: Its Videos page is opened in Chrome and read
        open "www.youtube.com/@{1}/videos"
        # A handle YouTube doesn't know gets a bare "404 Not Found" page, without YouTube's own app in it.
        if no css "ytd-app"
          stop "YouTube has no channel @{1}: write the handle as it is in the channel's address."
        wait css "ytd-rich-item-renderer a#video-title-link, ytd-rich-item-renderer a.ytLockupMetadataViewModelTitle"
        read links css "ytd-rich-item-renderer a#video-title-link, ytd-rich-item-renderer a.ytLockupMetadataViewModelTitle"
        """# + "\n"),
        ("browser/github-repos.straw", #"""
        # Searches GitHub for repositories in Chrome: the top ones, a line each (owner/name, a tab, the address)
        #
        # Input: What to search GitHub for
        # Why: It's searched for on GitHub as typed (repositories only), and the results page is read
        open "github.com/search?q={args}&type=repositories"
        wait css "[data-testid='results-list'] .search-title a"
        read links css "[data-testid='results-list'] .search-title a"
        """# + "\n"),
        ("browser/hn-search.straw", #"""
        # Searches Hacker News (through Algolia) in Chrome: the stories that best match, a line each (the title, a tab, the address)
        #
        # Input: What to search Hacker News for
        # Why: It's searched for on hn.algolia.com as typed, and the results page is read
        open "hn.algolia.com/?q={args}"
        wait css ".Story_title"
        read links css ".Story_title > a:first-child"
        """# + "\n"),
        ("browser/arxiv-search.straw", #"""
        # Searches arXiv for papers in Chrome: the newest that match, a line each (the title, a tab, the abstract's address)
        #
        # Input: What to search arXiv for
        # Why: It's searched for on arxiv.org as typed (in every field), and the results page is read
        open "arxiv.org/search/?query={args}&searchtype=all&order=-announced_date_first"
        see no "Sorry, your query"
        wait css "li.arxiv-result"
        js "[...document.querySelectorAll('li.arxiv-result')].slice(0, 10).map(r => r.querySelector('p.title').textContent.replace(/\s+/g, ' ').trim() + '\t' + r.querySelector('p.list-title a').href)"
        """# + "\n"),
    ]

    /// Flows that use the utilities and the browser scripts (Google, the weather, the news, cloud
    /// services, YouTube): added once every script they run is in the folder.
    public static let toolFlows: [(String, String)] = [
        ("ask-google.flow", #"""
        // Asks Google a question (the cell's arguments, or typed when it runs) and shows just the answer
        //
        // Input: What do you want to know?
        let question = if isEmpty args then ask "What do you want to know?" else join " " args
        let answer = run "google" [question]
        showResult answer
        """# + "\n"),
        ("weather-now.flow", #"""
        // The weather where you are, or in the place in the cell's arguments: a notice now, the next days shown
        //
        // Input (optional): A place (where you are unless set)
        let report = run "weather" args
        notify (report |> lines |> first)
        showResult report
        """# + "\n"),
        ("news-briefing.flow", #"""
        // The top stories, with anything urgent first (and a notice when there is), fetched at the same time
        let both =
            parallel [ (fun () -> run "news" ["--critical"; "--count"; "5"]); (fun () -> run "news" ["--count"; "10"]) ]
        let urgent = both |> first |> lines |> filter (startsWith "🚨")
        let top = both |> last

        if isEmpty urgent then
            showResult $"Top stories\n\n{top}"
        else
            notify $"Urgent news: {first urgent}"
            showResult $"Urgent\n\n{join "\n" urgent}\n\nTop stories\n\n{top}"
        """# + "\n"),
        ("urgent-news.flow", #"""
        // Checks the news for anything urgent (a topic in the cell's arguments narrows it): a sound and a notice if so
        //
        // Input (optional): A topic (the top stories unless set)
        let urgent = run "news" (["--critical"] @ args) |> lines |> filter (startsWith "🚨")

        if isEmpty urgent then
            print "Nothing urgent in the news right now."
        else
            run "play-sound" ["Sosumi"] |> ignore
            notify $"{length urgent} urgent: {first urgent}"
            showResult (join "\n" urgent)
        """# + "\n"),
        ("cloud-check.flow", #"""
        // Checks whether the cloud services you rely on are up (or the ones in the cell's arguments) and tells you about any that aren't
        //
        // Input (optional): Which services (all of them unless set)
        let problems = run "cloud-status" (["--problems"] @ args) |> lines |> filter (fun line -> not (startsWith "✅" line))

        if isEmpty problems then
            print "✅ Every service is up."
        else
            notify $"{length problems} with problems: {first problems}"
            showResult (join "\n" problems)
        """# + "\n"),
        ("youtube-search.flow", #"""
        // Searches YouTube (the cell's arguments, or typed when it runs), lets you pick one of the top videos, and plays it in Chrome
        //
        // Input: What to search YouTube for
        let search = if isEmpty args then ask "Search YouTube for…" else join " " args
        let videos = run "youtube" [search] |> lines
        let picked = choose "Play which one?" videos
        let address = picked |> split " — " |> last

        run "browser.sh" ["open"; address] |> ignore
        print $"Playing {address}"
        """# + "\n"),
        ("play-music.flow", #"""
        // Plays a song, artist or album on YouTube Music in Chrome (the cell's arguments, or typed when it runs)
        //
        // Input: A song, artist or album
        let wanted = if isEmpty args then ask "Play what on YouTube Music?" else join " " args
        let playing = run "youtube-music" [wanted]
        notify playing
        print playing
        """# + "\n"),
        ("morning-briefing.flow", #"""
        // Your morning in one go: the weather (said out loud), urgent news, the top stories and any cloud service that's down
        let get r = if r.ok then r.out else $"(couldn't get it: {r.err})"
        let found =
            parallel [
                (fun () -> attempt "weather" [])
                (fun () -> attempt "news" ["--critical"; "--count"; "5"])
                (fun () -> attempt "news" ["--count"; "5"])
                (fun () -> attempt "cloud-status" ["--problems"]) ]
            |> map get
        let part n = found |> skip n |> first

        attempt "speak" [$"Good morning. {part 0 |> lines |> first}"] |> ignore
        showResult $"Weather\n{part 0}\n\nUrgent\n{part 1}\n\nTop stories\n{part 2}\n\nCloud services\n{part 3}"
        """# + "\n"),
        ("research.flow", #"""
        // Researches a topic in one go: what Wikipedia says, Google's own answer, and the latest news about it
        //
        // Input: A topic
        let topic = if isEmpty args then ask "Research what?" else join " " args
        let get r = if r.ok then r.out else $"(couldn't get it: {r.err})"
        let found =
            parallel [
                (fun () -> attempt "wikipedia" [topic])
                (fun () -> attempt "google" ["--answer"; topic])
                (fun () -> attempt "news" ["--count"; "5"; topic]) ]
            |> map get
        let part n = found |> skip n |> first

        showResult $"{topic}\n\nWikipedia\n{part 0}\n\nGoogle\n{part 1}\n\nIn the news\n{part 2}"
        """# + "\n"),
        ("travel-check.flow", #"""
        // Before a trip: the weather there, the time there, and what your money is worth there
        //
        // Input: Where you're going (a city)
        // Input (optional): Your money and theirs (USD JPY)
        let place = if isEmpty args then ask "Where are you going?" else first args
        let money = args |> skip 1 |> join " "
        let get r = if r.ok then r.out else $"(couldn't get it: {r.err})"
        let found =
            parallel [
                (fun () -> get (attempt "weather" [place]))
                (fun () -> get (attempt "world-clock" [place]))
                (fun () -> if money = "" then "(give your money and theirs, such as USD JPY, to see it)" else get (attempt "currency" [$"100 {money}"])) ]
        let part n = found |> skip n |> first

        showResult $"{place}\n\nWeather\n{part 0}\n\nTime\n{part 1}\n\nMoney\n{part 2}"
        """# + "\n"),
        ("focus-session.flow", #"""
        // A focus session: calm music on YouTube Music, then after the time's up the music stops and it says it's break time
        //
        // Input (optional): How many minutes (25 unless set)
        let minutes = if isEmpty args then "25" else first args

        attempt "youtube-music" ["lofi beats to study to"] |> ignore
        notify $"Focus for {minutes} minutes: the music is on"
        sleep (int minutes * 60)

        attempt "youtube-music" ["pause"] |> ignore
        run "play-sound" ["Glass"] |> ignore
        attempt "speak" ["Time for a break"] |> ignore
        notify "Break time: the music is paused"
        """# + "\n"),
        ("site-watch.flow", #"""
        // Checks your websites (the ones given, or listed in sites.txt in your scripts folder) and tells you about any that are down or slow
        //
        // Input (optional): Websites, with spaces between them (the ones in sites.txt unless set)
        let listed = sh "cat sites.txt 2>/dev/null || true" |> lines
        let sites = if not (isEmpty args) then args else (if isEmpty listed then ["example.com"; "github.com"] else listed)
        let report = run "site-check" sites |> lines
        let trouble = report |> filter (fun line -> not (startsWith "✅" line))

        if isEmpty trouble then
            print $"✅ All {length report} sites are up."
        else
            notify $"{length trouble} of {length report} sites need a look: {first trouble}"
            showResult (join "\n" report)
        """# + "\n"),
        ("mac-health.flow", #"""
        // This Mac's health in one go: battery, disk, memory, network, its address on the internet, and the cloud services it relies on
        let get r = if r.ok then r.out else $"(couldn't get it: {r.err})"
        let found =
            parallel [
                (fun () -> attempt "battery" [])
                (fun () -> attempt "disk-space" [])
                (fun () -> attempt "system-info" [])
                (fun () -> attempt "public-ip" [])
                (fun () -> attempt "cloud-status" ["--problems"]) ]
            |> map get
        let part n = found |> skip n |> first
        let battery = part 0
        let level = if contains "%" battery then battery |> split "%" |> first |> trim |> int else 100

        if level < 20 then
            notify $"Battery low: {battery}"
        showResult $"Battery\n{battery}\n\nDisk used\n{part 1}\n\nThis Mac\n{part 2}\n\nOn the internet\n{part 3}\n\nCloud services\n{part 4}"
        """# + "\n"),
        ("translate.flow", #"""
        // Translates text with Google, shows it, and puts the translation on the clipboard
        //
        // Input: What to translate
        // Input (optional): Into which language (English unless set)
        let text = if isEmpty args then ask "What should be translated?" else first args
        let language = if length args > 1 then args |> skip 1 |> first else "English"
        let said = run "translate" [text; language]

        said |> pipe "clipboard" [] |> ignore
        showResult $"{said}\n\n(on the clipboard)"
        """# + "\n"),
        ("tidy-chrome.flow", #"""
        // Tidies Chrome: saves every open tab to a file first (so nothing is lost), then closes the duplicates
        let saved = run "save-tabs" []
        let closed = run "close-duplicate-tabs" []

        notify closed
        print saved
        print closed
        """# + "\n"),
        ("inbox-check.flow", #"""
        // Checks Gmail for unread email: a notice with how many, and who they're from
        let inbox = run "gmail" []

        notify $"Gmail: {inbox |> lines |> first}"
        showResult inbox
        """# + "\n"),
        ("new-password.flow", #"""
        // Makes a strong password and puts it on the clipboard, ready to paste
        //
        // Input (optional): How long (20 unless set)
        let word = run "password" args

        word |> pipe "clipboard" [] |> ignore
        notify "A new password is on the clipboard"
        """# + "\n"),
        ("page-aloud.flow", #"""
        // Says the title of the page in front in Chrome out loud, and copies its address
        let title = run "browser.sh" ["title"]
        let address = run "browser.sh" ["url"]

        run "speak" [$"You're looking at {title}"] |> ignore
        run "clipboard" [address] |> ignore
        print $"{title}: {address} (copied to the clipboard)"
        """# + "\n"),
        ("page-addresses.flow", #"""
        // Lists every address the page in front in Chrome links to, then plays a sound
        let addresses = run "page-links" [] |> pipe "extract-urls" [] |> lines
        print $"{length addresses} addresses on the page:"
        addresses |> each print

        run "play-sound" ["Glass"] |> ignore
        """# + "\n"),
        ("today-briefing.flow", #"""
        // What today is, said out loud and shown: the date every way, the sun, the next holidays and this month's calendar
        let get r = if r.ok then r.out else $"(couldn't get it: {r.err})"
        let found =
            parallel [
                (fun () -> attempt "today" [])
                (fun () -> attempt "sunrise" [])
                (fun () -> attempt "holidays" ["3"])
                (fun () -> attempt "month" []) ]
            |> map get
        let part n = found |> skip n |> first

        attempt "speak" [$"It's {part 0 |> split " · " |> first}. {part 1 |> lines |> first}"] |> ignore
        showResult $"Today\n{part 0}\n\nThe sun\n{part 1}\n\nNext holidays\n{part 2}\n\n{part 3}"
        """# + "\n"),
        ("open-apps.flow", #"""
        // Opens the apps you name, one after another (the cell's arguments, or typed when it runs), and says which opened
        //
        // Input: The apps, with commas between them (Mail, Calendar, Slack)
        let named = if isEmpty args then ask "Which apps? (Mail, Calendar, Slack)" else join " " args
        let apps = named |> split "," |> map trim |> filter (fun app -> not (app = ""))
        let opened = apps |> map (fun app -> run "open-app" [app])

        notify $"{length opened} apps open: {join ", " apps}"
        opened |> each print
        """# + "\n"),
        ("countdown.flow", #"""
        // How long until a date (the cell's arguments, or typed when it runs): the days left, as a notice
        //
        // Input: The date (Christmas, 2026-12-25, next friday…)
        let date = if isEmpty args then ask "Until when?" else join " " args
        let left = run "days-until" [date]

        notify left
        print left
        """# + "\n"),
        ("hn-briefing.flow", #"""
        // The top five stories on Hacker News, read in Chrome by a Straw script, with the first said out loud
        let stories = run "hacker-news" [] |> lines |> filter (fun s -> trim s <> "") |> take 5

        if isEmpty stories then
            fail "Hacker News gave no stories: is Chrome open and allowed to run JavaScript? (run browser.sh to check)"
        attempt "speak" [$"Top of Hacker News: {first stories}"] |> ignore
        showResult (join "\n" stories)
        """# + "\n"),
        ("network-check.flow", #"""
        // Is the internet all right? This Mac on its network, its address on the internet, and how fast it is, in one go
        let get r = if r.ok then r.out else $"(couldn't get it: {r.err})"
        let found =
            parallel [
                (fun () -> attempt "network" [])
                (fun () -> attempt "public-ip" [])
                (fun () -> attempt "speed-test" []) ]
            |> map get
        let part n = found |> skip n |> first

        if contains "❌" (part 0) then
            notify $"Network trouble: {part 0 |> lines |> last}"
        showResult $"On the network\n{part 0}\n\nOn the internet\n{part 1}\n\nSpeed\n{part 2}"
        """# + "\n"),
        ("dev-check.flow", #"""
        // Before you stop for the day: your git repositories with work not committed or pushed, and what's still listening on a port
        let get r = if r.ok then r.out else $"(couldn't get it: {r.err})"
        let found =
            parallel [
                (fun () -> attempt "git-status-all" args)
                (fun () -> attempt "port-check" []) ]
            |> map get
        let part n = found |> skip n |> first

        showResult $"Git\n{part 0}\n\nListening\n{part 1}"
        """# + "\n"),
        ("presentation-mode.flow", #"""
        // Getting ready to present: keeps the Mac awake for an hour (or as long as you say), mutes it, and says when it's set
        //
        // Input (optional): How many minutes (60 unless set)
        let minutes = if isEmpty args then "60" else first args

        confirmBecause $"Keep the Mac awake for {minutes} minutes and mute it?" "So it doesn't sleep or ping while you present; keep-awake stop and volume 50 undo it"
        let awake = run "keep-awake" [minutes]
        run "volume" ["mute"] |> ignore
        notify $"Ready to present: {awake}"
        print awake
        """# + "\n"),
        ("clean-read.flow", #"""
        // Gets the page in front of Chrome ready to read: clicks away its cookie banner, then gives back its outline (Straw scripts, both)
        let cookies = run "dismiss-cookies" []
        let outline = run "page-outline" []

        showResult $"{cookies}\n\n{outline}"
        """# + "\n"),
        ("search-a-site.flow", #"""
        // Searches one of 50 well-known sites (YouTube, Amazon, GitHub, Reddit, Maps, IMDb…): pick it, say what, and its results open in Chrome
        //
        // Input (optional): The site, then what to search it for (amazon usb-c hub)
        let sites = run "site-search" ["list"] |> lines |> map (fun line -> first (split " " line))
        let site = if isEmpty args then choose "Search which site?" sites else first args
        let words = if length args > 1 then args |> skip 1 |> join " " else ask $"Search {site} for…"

        print (run "site-search" [site; words])
        """# + "\n"),
        ("search-everywhere.flow", #"""
        // Searches YouTube, GitHub, Hacker News and arXiv for a topic in Chrome (Straw scripts, all) and gives the top three of each in one result
        //
        // Input: A topic
        let topic = if isEmpty args then ask "Search everywhere for…" else join " " args
        // What went wrong, in its last line (a Straw script says what it was doing before that).
        let why r = if isEmpty (lines r.err) then $"it stopped ({r.code})" else r.err |> lines |> last
        let top r = if r.ok then r.out |> lines |> take 3 |> map (replace "\t" " — ") |> join "\n" else $"(couldn't search: {why r})"
        // One after another: a Straw script drives the tab in front of Chrome, so two at once would share it.
        let youtube = top (attempt "youtube-videos" [topic])
        let github = top (attempt "github-repos" [topic])
        let hackerNews = top (attempt "hn-search" [topic])
        let arxiv = top (attempt "arxiv-search" [topic])

        showResult $"{topic}\n\nYouTube\n{youtube}\n\nGitHub\n{github}\n\nHacker News\n{hackerNews}\n\narXiv\n{arxiv}"
        """# + "\n"),
        ("youtube-channels.flow", #"""
        // The latest videos from the YouTube channels you name, three each, in one result (read in Chrome by a Straw script, a channel at a time)
        //
        // Input: The channels' handles, with commas between them (LofiGirl, veritasium, mkbhd)
        let named = if isEmpty args then ask "Which channels? (LofiGirl, veritasium, mkbhd)" else join " " args
        let channels = named |> split "," |> map trim |> map (replace "@" "") |> filter (fun c -> not (c = ""))
        let why r = if isEmpty (lines r.err) then $"it stopped ({r.code})" else r.err |> lines |> last
        let latest channel =
            let r = attempt "youtube-latest" [channel]
            let videos = if r.ok then r.out |> lines |> take 3 |> map (fun v -> "  " + first (split "\t" v)) |> join "\n" else "  " + why r
            $"@{channel}\n{videos}"

        showResult (channels |> map latest |> join "\n\n")
        """# + "\n"),
        ("find-and-open.flow", #"""
        // Finds a file by name with Spotlight, lets you pick one of the newest, then opens it, shows it in the Finder, previews it or copies where it is
        //
        // Input: Part of the file's name
        let name = if isEmpty args then ask "Find a file called…" else join " " args
        let found = attempt "find-file" [name]
        if not found.ok then
            fail (found.err |> trim)
        let picked = found.out |> lines |> choose $"Files called “{name}”, the newest first:"
        let action = choose $"{picked}" ["Open it"; "Show it in the Finder"; "Preview it (Quick Look)"; "Copy where it is"]

        let done =
            if action = "Show it in the Finder" then run "open-file" [picked; "reveal"]
            elif action = "Preview it (Quick Look)" then run "open-file" [picked; "look"]
            elif action = "Copy where it is" then run "copy-to-clipboard" [picked]
            else run "open-file" [picked]
        print done
        """# + "\n"),
        ("spotlight-search.flow", #"""
        // Searches this Mac with Spotlight, as ⌘Space does, for a kind of file (or any): pick one of what it finds, and it opens
        //
        // Input: The words to look for (in the file's name or in what's written in it)
        let words = if isEmpty args then ask "Search this Mac for…" else join " " args
        let kind = choose "What kind of file?" ["anything"; "pdf"; "document"; "image"; "video"; "audio"; "presentation"; "spreadsheet"; "text"; "code"; "folder"; "app"; "archive"; "email"]
        let terms = words |> split " " |> filter (fun w -> not (w = ""))
        let found = if kind = "anything" then attempt "spotlight" terms else attempt "spotlight" (["--kind"; kind] @ terms)
        if not found.ok then
            fail (found.err |> trim)

        let picked = found.out |> lines |> choose $"Spotlight found, the newest first:"
        print (run "open-file" [picked])
        """# + "\n"),
        ("latest-screenshot.flow", #"""
        // Opens your newest screenshot, wherever it was saved, and puts where it is on the clipboard (for a message or a terminal)
        let newest = run "screenshots" ["latest"]
        run "open-file" [newest] |> ignore
        run "copy-to-clipboard" [newest] |> ignore

        notify $"Your newest screenshot is open, and where it is is on the clipboard"
        print newest
        """# + "\n"),
        ("downloads-report.flow", #"""
        // What's in your Downloads, in one result: the newest files and the sites they came from, the biggest, and any exact copies (nothing is moved or deleted)
        let get r = if r.ok then r.out else $"(couldn't look: {trim r.err})"
        let found =
            parallel [
                (fun () -> attempt "recent-downloads" ["10"])
                (fun () -> attempt "large-files" ["100MB"; "~/Downloads"])
                (fun () -> attempt "find-duplicates" ["~/Downloads"]) ]
            |> map get
        let part n = found |> skip n |> first

        showResult $"The newest\n{part 0}\n\nOver 100 MB\n{part 1}\n\nCopies\n{part 2}"
        """# + "\n"),
        ("explain-selection.flow", #"""
        // Explains what's selected on the page in front of Chrome: what Wikipedia says about it and what the dictionary says it means, in one result
        let picked = run "selected-text" []
        let get r = if r.ok then r.out else $"(nothing found: {trim r.err})"
        let found = parallel [ (fun () -> attempt "wikipedia" [picked]); (fun () -> attempt "define" [picked]) ] |> map get

        showResult $"“{picked}”\n\nWikipedia\n{first found}\n\nThe dictionary\n{found |> skip 1 |> first}"
        """# + "\n"),
        ("translate-selection.flow", #"""
        // Translates what's selected on the page in front of Chrome (into English, or the language you say), with Google
        //
        // Input (optional): The language to translate into (English unless set)
        let picked = run "selected-text" []
        let into = if isEmpty args then "English" else join " " args

        showResult $"“{picked}”\n\n{run "translate" [picked; into]}"
        """# + "\n"),
        ("read-selection-aloud.flow", #"""
        // Says out loud what's selected on the page in front of Chrome (select a paragraph, then run it)
        let picked = run "selected-text" []
        run "speak" [picked] |> ignore

        print $"Said {length (split " " picked)} words"
        """# + "\n"),
        ("quick-note.flow", #"""
        // Adds a line to the Inbox note in your library (LIBRARY on the Desktop), with the time: a thought to sort out later
        //
        // Input: What to note down
        let words = if isEmpty args then ask "Note down…" else join " " args
        libraryAppend "Inbox" $"- {now ()} {words}"

        notify $"In your Inbox: {words}"
        """# + "\n"),
        ("journal.flow", #"""
        // Writes in today's journal in your library: a note a day, named by its date, each entry under the time it was written
        //
        // Input: What happened, or what's on your mind
        let entry = if isEmpty args then ask "Today's journal…" else join " " args
        let stamp = now ()
        let day = stamp |> split " " |> first
        let time = stamp |> split " " |> last
        if not (libraryExists day) then libraryWrite day $"# {day}\n"
        libraryAppend day $"\n**{time}** {entry}"

        print $"Written in {day}"
        """# + "\n"),
        ("find-note.flow", #"""
        // Searches every note in your library for your words, lets you pick one of the notes that have them (the best first), and shows it
        //
        // Input: The words to look for (a "phrase" in quotes)
        let words = if isEmpty args then ask "Search the library for…" else join " " args
        let found = libraryFind words
        if isEmpty found then fail $"No note in the library has {words} in it."
        let picked = choose $"Notes with “{words}”, the best first:" found

        showResult $"{picked}\n\n{libraryRead picked}"
        """# + "\n"),
        ("library-digest.flow", #"""
        // What's new in your library: the five notes changed last, each with its first lines, in one result
        let names = run "library-recent" ["5"] |> lines |> map (fun line -> first (split "  ·  " line))
        let opening name =
            let start = libraryRead name |> lines |> take 3 |> join "\n"
            $"{name}\n{start}"

        if isEmpty names then fail "The library is empty: library-new (or the Library board's New Note) makes a note."
        showResult (names |> map opening |> join "\n\n")
        """# + "\n"),
        ("save-page.flow", #"""
        // Saves the page in front of Chrome to your library: a note named by the page's title, with its address and all its text
        let title = run "browser.sh" ["title"] |> trim
        let address = run "browser.sh" ["url"] |> trim
        let text = run "browser.sh" ["text"]
        // A title can have a / or a : in it; a note's name can't.
        let name = title |> replace "/" "-" |> replace ":" " -" |> trim
        libraryWrite name $"# {title}\n\n<{address}>\n\n{text}"

        notify $"Saved to the library: {name}"
        print name
        """# + "\n"),
        ("clip-selection.flow", #"""
        // Adds what's selected on the page in front of Chrome to the Clippings note in your library, with where it came from
        let picked = run "selected-text" []
        let address = run "browser.sh" ["url"] |> trim
        libraryAppend "Clippings" $"\n> {picked}\n\n— <{address}>"

        notify "Added to Clippings in the library"
        print picked
        """# + "\n"),
    ]

    /// What runs a Straw script, wherever it is: straw.py, and browser.sh, which it drives Chrome with.
    public static var strawRunner: [(String, String)] {
        browser.filter { $0.0 == "browser/\(Straw.runnerName)" || $0.0 == "browser/browser.sh" }
    }

    /// Every example script, wherever it goes.
    public static var allScripts: [(String, String)] { scripts + utilities + browser }
}
