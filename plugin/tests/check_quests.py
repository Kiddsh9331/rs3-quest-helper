# Plays every step of every quest through the plugin's logic on paper
# (check_quests.lua) and summarises where it would go wrong, so fixes can be
# made for quests nobody has tested in game yet.
#
#   python plugin/tools/build_quests.py guides_all.json --all --out all.lua --cache wiki.json
#   python plugin/tests/check_quests.py all.lua --cache wiki.json --out findings.json
#
# guides_all.json comes from tools/fetch_wikitext.py + tools/dump_guides.html?src=.
# Prints a summary per kind of problem with a few examples; --out keeps
# every finding for a closer look.
import argparse
import collections
import json
import os
import re
import time
import urllib.parse
import urllib.request

from lupa import lua54

here = os.path.dirname(os.path.abspath(__file__)).replace("\\", "/")
API = "https://runescape.wiki/api.php"

parser = argparse.ArgumentParser()
parser.add_argument("quests")
parser.add_argument("--cache", help="wiki answers, shared with build_quests.py --cache")
parser.add_argument("--out")
parser.add_argument("--examples", type=int, default=6)
opts = parser.parse_args()

cache = json.load(open(opts.cache, encoding="utf8")) if opts.cache and os.path.exists(opts.cache) else {}


def api(params):
    params = dict(params, format="json", redirects="1")
    url = API + "?" + urllib.parse.urlencode(params)
    if url not in cache:
        req = urllib.request.Request(url, headers={"User-Agent": "rs3qh-plugin-builder (github.com/Kiddsh9331/rs3-quest-helper)"})
        with urllib.request.urlopen(req, timeout=60) as resp:
            cache[url] = json.load(resp)
        time.sleep(0.5)
    return cache[url]


def run_lua():
    lua = lua54.LuaRuntime(encoding=None)
    g = lua.globals()
    g.PLUGIN_DIR = os.path.join(here, "..", "rs3qh-test").replace("\\", "/").encode()
    g.QUESTS_FILE = os.path.abspath(opts.quests).replace("\\", "/").encode()
    lua.execute(b'package.path = PLUGIN_DIR .. "/?.lua;" .. package.path')
    for script in ("mock.lua", "check_quests.lua"):
        with open(os.path.join(here, script), encoding="utf8") as f:
            result = lua.execute(f.read().encode())
    def text(v):
        return v.decode("utf8", "replace") if isinstance(v, bytes) else v
    findings = [{text(k): text(v) for k, v in f.items()} for f in result[b"findings"].values()]
    return findings, {text(k): v for k, v in result[b"stats"].items()}


def item_pages(names):
    """name -> True (an item page), False (some other page), None (no page)."""
    out = {}
    names = sorted(set(names))
    for i in range(0, len(names), 40):
        group = names[i:i + 40]
        data = api({"action": "query", "prop": "revisions", "rvprop": "content", "rvslots": "main",
                    "rvsection": "0", "titles": "|".join(group)})
        q = data["query"]
        back = {}
        for r in q.get("normalized", []) + q.get("redirects", []):
            back.setdefault(r["to"], []).append(r["from"])
        for page in q["pages"].values():
            titles = [page["title"]] + back.get(page["title"], [])
            for t in list(titles):
                titles += back.get(t, [])
            if "missing" in page or "revisions" not in page:
                kind = None
            else:
                text = page["revisions"][0]["slots"]["main"]["*"]
                kind = bool(re.search(r"\{\{\s*Infobox (Item|Bonuses|Construction)", text, re.I)) or "{{Disambig" in text
            for t in titles:
                out[t.lower()] = kind
    return out


findings, stats = run_lua()
by_kind = collections.defaultdict(list)
for f in findings:
    by_kind[f["kind"]].append(f)

# "Get:" names that aren't items on the wiki ("Get: boat", "Get: to the top").
gets = by_kind.pop("get", [])
names = {f["detail"] for f in gets}
known = item_pages([n[:1].upper() + n[1:] for n in names if 3 <= len(n) <= 60 and "|" not in n and "#" not in n])
for f in gets:
    name = f["detail"]
    kind = known.get(name.lower())
    if kind is None and name.endswith("s"):
        kind = known.get(name[:-1].lower())
    if kind is not True:
        f["detail"] = name + ("  (no wiki page)" if kind is None else "  (not an item)")
        by_kind["get-not-item"].append(f)
stats["getChecked"] = len(gets)

# Items shown under "Bring:" with nothing to say how to get them.
items = by_kind.pop("item", [])
no_help = collections.Counter()
for f in items:
    name, ge, recipe, hint, parts = (f["detail"].split("\t") + [""] * 5)[:5]
    if not (ge or recipe or hint or parts not in ("", "0")):
        no_help[name] += 1
stats["itemLines"] = len(items)

if opts.cache:
    json.dump(cache, open(opts.cache, "w", encoding="utf8"))

print("%d quests, %d steps" % (stats["quests"], stats["steps"]))
for key in sorted(stats):
    if key not in ("quests", "steps"):
        print("  %s: %s" % (key, stats[key]))
print()
for kind, rows in sorted(by_kind.items(), key=lambda kv: -len(kv[1])):
    quests = len({r["quest"] for r in rows})
    print("== %s: %d steps in %d quests" % (kind, len(rows), quests))
    details = collections.Counter(r["detail"] for r in rows)
    if len(details) < len(rows):
        print("   most common: " + "; ".join("%s (%d)" % (d, n) for d, n in details.most_common(8)))
    for r in rows[:: max(1, len(rows) // opts.examples)][:opts.examples]:
        print("   %s #%d [%s] %s" % (r["quest"], r["step"], r["detail"], r["text"][:160]))
    print()
print("== items under Bring: with no hint, GE, recipe or parts: %d names" % len(no_help))
print("   " + "; ".join("%s (%d)" % kv for kv in no_help.most_common(30)))

if opts.out:
    json.dump({"stats": stats, "findings": findings, "noHelp": no_help.most_common()},
              open(opts.out, "w", encoding="utf8"), indent=1)
