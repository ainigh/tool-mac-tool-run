import Foundation

/// The example utilities and browser scripts, and the flows that use them. They're scripts like
/// any other: only their folders (`utilities`, `browser`) put them on grids of their own.
extension Examples {
    /// Small reusable helpers: sounds, speech, the clipboard, parsing JSON, CSV and addresses, and
    /// what's going on (the weather, the news, whether cloud services are up).
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
        # JavaScript is an expression (document.title), or statements with a return at the start of a line
        # (or after a ;) giving back the answer; what isn't text comes back as JSON. Chrome lets scripts run it once View > Developer > Allow JavaScript from Apple
        # Events is ticked; macOS asks once whether this app may control Chrome.
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

        # JavaScript, wrapped so an expression or statements with a return give back text (JSON for the rest).
        wrap_js() {
          local code="$1" body
          # Trailing semicolons and spaces off, so an expression can be returned.
          code="${code%"${code##*[![:space:];]}"}"
          # Statements when a return starts a line (or follows a ;); otherwise one expression, whatever
          # functions inside it return.
          case "$code" in
            return*|*"
        return"*|*"; return"*|*";return"*) body="$code" ;;
            *) body="return (
        $code
        );" ;;
          esac
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
    ]

    /// Every example script, wherever it goes.
    public static var allScripts: [(String, String)] { scripts + utilities + browser }
}
