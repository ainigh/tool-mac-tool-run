#!/usr/bin/env python3
"""Which model translates best: runs BENCH.md's cases through POST /api/say/translate.

Each case is what a client said and the template it should become. Every model given is asked
every case (the app asks it, exactly as it would in a conversation: the same instructions, the
same templates), and scored on whether its best reading is the right template, whether the
values it filled in are the ones expected, and how long it took.

    scripts/bench-say.py                                   # the translator as it's set now
    scripts/bench-say.py -m qwen2.5:7b -m llama3.2         # two Ollama models
    scripts/bench-say.py -m anthropic:claude-haiku-5-5     # the key from ANTHROPIC_API_KEY
    scripts/bench-say.py -m openai:gpt-5-mini@https://api.openai.com/v1/chat/completions
    scripts/bench-say.py --only 1-20 --out results.json    # some of the cases; every answer kept

A model is [api:]name[@address]: api is openai (any chat completions address; Ollama's by
default) or anthropic. Needs Tool Mac Tool Run serving on this Mac, with the Examples added
(the cases name the example scripts). Python 3, the standard library only.
"""
import argparse
import json
import math
import os
import re
import statistics
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
BENCH = os.path.join(HERE, "..", "BENCH.md")


def cases(path):
    """The rows of BENCH.md's table of cases: number, said, why, expected titles, expected values."""
    out = []
    inside = False
    for line in open(path, encoding="utf-8"):
        if line.startswith("## "):
            inside = line.strip().lower().startswith("## the cases")
            continue
        if not inside or not line.startswith("|"):
            continue
        cells = [c.strip().replace("\\|", "|") for c in re.split(r"(?<!\\)\|", line.strip())[1:-1]]
        if len(cells) < 5 or not cells[0].isdigit():
            continue
        number, said, why, expect, values = cells[:5]
        said = said.strip("`").replace("\\n", "\n")
        between = []
        if why.startswith("between"):
            between = [t.strip() for t in why[len("between"):].strip(" :").split(";") if t.strip()]
            why = "between"
        elif why.startswith("weak"):
            between = [why[len("weak"):].strip(" :")]
            why = "weak"
        titles = [] if expect in ("—", "-", "none", "") else [t.strip() for t in expect.split(" or ")]
        wanted = [] if values in ("—", "-", "") else [v.strip().strip("`") for v in values.split(",")]
        out.append({"n": int(number), "said": said, "why": why or "nothing", "between": between, "expect": titles, "values": wanted})
    return out


def model_spec(spec):
    """[api:]name[@address] → the settings to try."""
    s = {}
    if "@" in spec:
        spec, s["url"] = spec.split("@", 1)
    if spec.startswith(("openai:", "anthropic:")):
        s["api"], spec = spec.split(":", 1)
    s["model"] = spec
    key = os.environ.get("ANTHROPIC_API_KEY" if s.get("api") == "anthropic" else "OPENAI_API_KEY", "")
    host = s.get("url", "")
    # A provider's key only to the provider (a local server needs none).
    if key and (s.get("api") == "anthropic" and ("api.anthropic.com" in host or not host) or "api.openai.com" in host):
        s["key"] = key
    return s


def ask(base, body, timeout):
    req = urllib.request.Request(base.rstrip("/") + "/api/say/translate?client=bench-say", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        try:
            return json.load(e)
        except Exception:
            return {"ok": False, "error": f"HTTP {e.code}"}
    except Exception as e:
        return {"ok": False, "error": str(e)}


def score(case, answer, sure):
    """Whether the best reading is the right template, its values the ones expected, and it would be acted on."""
    suggestions = answer.get("suggestions") or []
    top = suggestions[0] if suggestions else {}
    acted = bool(top) and top.get("complete") and (top.get("confidence") or 0) >= sure
    if not case["expect"]:
        # Nothing should fit: right when nothing would be acted on.
        return {"title": not acted, "values": not acted, "valid": True, "acted": acted}
    title = (answer.get("top") or "") in case["expect"]
    said = (top.get("say") or "").lower()
    values = title and all(v.lower() in said for v in case["values"])
    return {"title": title, "values": values, "valid": top.get("template") is not None if top else False, "acted": acted}


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("-m", "--model", action="append", default=[], help="[api:]name[@address]; again for more (none: as it's set now)")
    p.add_argument("--base", default="http://127.0.0.1:8768", help="where Tool Mac Tool Run is serving")
    p.add_argument("--bench", default=BENCH, help="the cases (BENCH.md)")
    p.add_argument("--only", help="some of the cases: 1-20,25")
    p.add_argument("--sure", type=float, default=0.75, help="how sure a reading must be to be acted on (the translator's own setting)")
    p.add_argument("--timeout", type=float, default=120)
    p.add_argument("--out", help="every answer, as JSON")
    a = p.parse_args()

    todo = cases(a.bench)
    if a.only:
        keep = set()
        for part in a.only.split(","):
            lo, _, hi = part.partition("-")
            keep.update(range(int(lo), int(hi or lo) + 1))
        todo = [c for c in todo if c["n"] in keep]
    if not todo:
        sys.exit(f"No cases in {a.bench}.")
    models = [model_spec(m) for m in a.model] or [{}]

    results = []
    for m in models:
        name = m.get("model") or "(as set now)"
        print(f"\n{name}: {len(todo)} cases", file=sys.stderr)
        rows = []
        for c in todo:
            body = {"text": c["said"], "why": c["why"], "between": c["between"], **m}
            started = time.time()
            answer = ask(a.base, body, a.timeout)
            took = answer.get("seconds") or (time.time() - started)
            s = score(c, answer, a.sure) if answer.get("ok") else {"title": False, "values": False, "valid": False, "acted": False}
            mark = "✅" if s["title"] and s["values"] else "🟡" if s["title"] else "❌"
            top = (answer.get("suggestions") or [{}])[0]
            print(f"  {mark} {c['n']:>3}  {c['said'][:48]:<48}  → {answer.get('top') or answer.get('error') or '—'}"
                  f"{'  “' + top.get('say', '')[:40] + '”' if top.get('say') else ''}", file=sys.stderr)
            rows.append({"case": c, "answer": answer, "score": s, "seconds": took})
        ok = [r for r in rows if r["answer"].get("ok")]
        times = [r["seconds"] for r in ok] or [0]
        summary = {
            "model": name,
            "cases": len(rows),
            "template": sum(r["score"]["title"] for r in rows) / len(rows),
            "values": sum(r["score"]["values"] for r in rows) / len(rows),
            "valid": sum(r["score"]["valid"] for r in rows) / len(rows),
            "failed": len(rows) - len(ok),
            "median_s": statistics.median(times),
            "p90_s": sorted(times)[max(0, math.ceil(0.9 * len(times)) - 1)],
        }
        results.append({"summary": summary, "rows": rows})

    print("\n| Model | Cases | Right template | Right values | Valid readings | Failed calls | Median s | p90 s |")
    print("|---|---|---|---|---|---|---|---|")
    for r in results:
        s = r["summary"]
        print(f"| {s['model']} | {s['cases']} | {s['template']:.0%} | {s['values']:.0%} | {s['valid']:.0%} | {s['failed']} | {s['median_s']:.2f} | {s['p90_s']:.2f} |")
    if a.out:
        with open(a.out, "w", encoding="utf-8") as f:
            json.dump(results, f, indent=2, ensure_ascii=False)
        print(f"\nEvery answer: {a.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
