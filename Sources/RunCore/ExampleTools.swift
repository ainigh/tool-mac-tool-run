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
        ("utilities/weather.py", #"""
        #!/usr/bin/env python3
        # The weather now and for the next days: where this Mac is, or a place you name
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


        def fetch(url):
            request = urllib.request.Request(url, headers={"User-Agent": "ToolMacToolRun weather"})
            for attempt in range(3):
                try:
                    with urllib.request.urlopen(request, timeout=15) as response:
                        return json.load(response)
                except (urllib.error.URLError, TimeoutError):
                    # A slow or dropped connection: once more, after a moment.
                    if attempt == 2:
                        raise
                    time.sleep(1 + attempt)


        def here():
            """Where this Mac is, from its internet address: (name, latitude, longitude, country code)."""
            try:
                d = fetch("https://ipapi.co/json/")
                if "latitude" in d:
                    name = ", ".join(p for p in [d.get("city"), d.get("region"), d.get("country_name")] if p)
                    return name, d["latitude"], d["longitude"], d.get("country_code", "")
            except Exception:
                pass
            d = fetch("https://ipinfo.io/json")
            lat, lon = d["loc"].split(",")
            name = ", ".join(p for p in [d.get("city"), d.get("region"), d.get("country")] if p)
            return name, float(lat), float(lon), d.get("country", "")


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
        wanted = [a.lower() for a in args if not a.startswith("--")]
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

        # AppleScript (from its input) run with Chrome's id, then the words given, as argv.
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
          tell application id (item 1 of argv)
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
          tell application id (item 1 of argv)
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
          tell application id (item 1 of argv)
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
          set address to item 2 of argv
          tell application id (item 1 of argv)
            if (count of windows) = 0 then
              make new window
              set URL of active tab of front window to address
              set t to active tab of front window
            else
              set w to front window
              set before to active tab index of w
              set t to make new tab at end of tabs of w with properties {URL:address}
              if item 3 of argv is "behind" then set active tab index of w to before
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
          tell application id (item 1 of argv)
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
          tell application id (item 1 of argv)
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
          tell application id (item 1 of argv)
            if (count of windows) = 0 then error "NO_WINDOW"
            set t to active tab of front window
            if item 2 of argv is "url" then return URL of t
            return title of t
          end tell
        end run
        APPLESCRIPT
        }

        list_tabs() {
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
        }

        focus_tab() {
          run_script "$1" <<'APPLESCRIPT'
        on run argv
          set wanted to item 2 of argv
          tell application id (item 1 of argv)
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
          tell application id (item 1 of argv)
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
          tabs) list_tabs ;;
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
            echo "It knows: open, read, url, title, text, tabs, js, js-in, focus, go, wait and encode (the top of browser.sh says how each goes)." >&2
            exit 1 ;;
        esac
        """# + "\n"),
        ("browser/google.sh", #"""
        #!/bin/bash
        # Asks Google and gives back just the answer: Google's own (AI Overview, a quick answer, the info box), then the top results
        #
        #   google.sh how tall is the eiffel tower
        #   google.sh "weather in Lagos"
        # Google is asked in Chrome, in a tab of its own behind the one you're on, closed after.
        # GOOGLE_LANGUAGE=fr asks in another language (English unless set).
        set -euo pipefail

        browser="$(dirname "$0")/browser.sh"
        if [ ! -f "$browser" ]; then
          echo "This needs browser.sh beside it, in the browser folder (Add the Examples on the Browser grid puts it back)." >&2
          exit 1
        fi
        if [ $# -eq 0 ]; then
          echo "What should Google be asked? (google.sh how tall is the eiffel tower)" >&2
          exit 1
        fi

        query=$(bash "$browser" encode "$*")
        address="https://www.google.com/search?hl=${GOOGLE_LANGUAGE:-en}&q=${query}"
        answer=$(bash "$browser" read "$address" '
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
        for (const sel of [".Z0LcW", "[data-tts=answers]", ".hgKElc", ".IZ6rdc", "[data-attrid=\"wa:/description\"]", ".kno-rdesc span", "#wob_wc", ".vk_bk.dDoNo"]) {
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
        ("browser/open-page.sh", #"""
        #!/bin/bash
        # Opens a page in Chrome (the address given, or example.com), waits for it to load, and prints its title
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
        let question = if isEmpty args then ask "What do you want to know?" else join " " args
        let answer = run "google" [question]
        showResult answer
        """# + "\n"),
        ("weather-now.flow", #"""
        // The weather where you are, or in the place in the cell's arguments: a notice now, the next days shown
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
        let problems = run "cloud-status" (["--problems"] @ args) |> lines |> filter (fun line -> not (startsWith "✅" line))

        if isEmpty problems then
            print "✅ Every service is up."
        else
            notify $"{length problems} with problems: {first problems}"
            showResult (join "\n" problems)
        """# + "\n"),
        ("youtube-search.flow", #"""
        // Searches YouTube (the cell's arguments, or typed when it runs), lets you pick one of the top videos, and plays it in Chrome
        let search = if isEmpty args then ask "Search YouTube for…" else join " " args
        let videos = run "youtube" [search] |> lines
        let picked = choose "Play which one?" videos
        let address = picked |> split " — " |> last

        run "browser.sh" ["open"; address] |> ignore
        print $"Playing {address}"
        """# + "\n"),
        ("play-music.flow", #"""
        // Plays a song, artist or album on YouTube Music in Chrome (the cell's arguments, or typed when it runs)
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
