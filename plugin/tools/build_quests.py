# Builds plugin/rs3qh-test/quests.lua from the Alt1 app's parsed guides, then
# enriches it from the RuneScape Wiki so the plugin doesn't need web access:
#   pages: what each linked page is (npc / item / location / scenery) and its
#          map coordinates, for highlighting and navigation
#   items: a one or two sentence "what is it / how to get it" for every item
#          the guides say you need (e.g. how to make red dye)
#   recipes: how each needed item is made ({{Infobox Recipe}}: materials,
#          facility, skill), followed down through its materials
#   tradeable: which needed items can be bought on the Grand Exchange
#
#   python plugin/tools/build_quests.py guides_all.json --all --cache wiki.json
#   python plugin/tools/build_quests.py guides.json --out plugin/tests/quests_test.lua
#
# guides*.json come from plugin/tools/dump_guides.html (see that file). --all
# takes every guide in it (what the plugin ships); without it, the five test
# quests (the offline tests' data). --cache keeps wiki answers between runs.
import argparse
import json
import os
import re
import time
import urllib.parse
import urllib.request

ORDER = ["The Knight's Sword", "Goblin Diplomacy", "Vampyre Slayer", "Priest in Peril", "Witch's House"]
API = "https://runescape.wiki/api.php"
OUT = "plugin/rs3qh-test/quests.lua"
BS = chr(92)

parser = argparse.ArgumentParser()
parser.add_argument("guides")
parser.add_argument("--all", action="store_true")
parser.add_argument("--out", default=OUT)
parser.add_argument("--cache")
opts = parser.parse_args()
OUT = opts.out
cache = json.load(open(opts.cache, encoding="utf8")) if opts.cache and os.path.exists(opts.cache) else {}

def api(params):
    params = dict(params, format="json", redirects="1")
    url = API + "?" + urllib.parse.urlencode(params)
    if url in cache:
        return cache[url]
    req = urllib.request.Request(url, headers={"User-Agent": "rs3qh-plugin-builder (github.com/Kiddsh9331/rs3-quest-helper)"})
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                data = json.load(resp)
            break
        except OSError:
            if attempt == 3:
                raise
            time.sleep(5 * (attempt + 1))
    time.sleep(0.5)
    if opts.cache:
        cache[url] = data
        if len(cache) % 20 == 0:
            json.dump(cache, open(opts.cache, "w", encoding="utf8"))
    return data


def batches(items, size):
    items = list(items)
    for i in range(0, len(items), size):
        yield items[i:i + size]


def split_needed(text):
    """'Orange dye (Combine Red dye and Yellow dye), Blue dye' -> ['Orange dye (...)', 'Blue dye']"""
    parts, depth, cur = [], 0, ""
    for ch in text:
        depth += ch == "("
        depth -= ch == ")"
        if ch == "," and depth == 0:
            parts.append(cur.strip())
            cur = ""
        else:
            cur += ch
    if cur.strip():
        parts.append(cur.strip())
    return parts


def item_names(entry):
    """Names to look up for one needed entry, including ingredients in brackets."""
    names = []
    m = re.match(r"^(.*?)\s*\((.*)\)\s*$", entry)
    main, inner = (m.group(1), m.group(2)) if m else (entry, "")
    main = re.sub(r"^\d+\s*(x\s*)?", "", main)
    main = re.sub(r"^(suits?|sets?|pieces?|pairs?) of ", "", main, flags=re.I)
    names.append(main)
    inner = re.sub(r"^(combine|use|mix)\s+", "", inner, flags=re.I)
    for part in re.split(r",|\band\b|\bor\b", inner):
        part = re.sub(r"^\d+\s*", "", part.strip())
        if part:
            names.append(part)
    return [n.strip() for n in names if n.strip()]


# The guides point at pictures and maps the plugin can't show: "(see map
# below)", "Using the image, press each button", "The solution is in the
# image to the right." Those bits go; the instruction stays.
PIC = r"(?:image|images|picture|pictures|map|screenshot|diagram)"
PIC_POS = r"(?:(?:on|to) the (?:right|left)|below|above)"
PICTURE_RULES = [
    # "(pictured right, north of fairy ring AIQ)" -> "(north of fairy ring AIQ)"
    (r"\(\s*pictured\s+\w+\s*[,;]\s*", "("),
    # Brackets that are only about a picture or the wiki's map (not the
    # minimap, and not "(use dig sites map or other means)").
    (r"\s*\((?=[^()]*(?:\bpictur|\bimages?\b|\bscreenshot|\b(?:see|refer to|on|in) (?:the )?map\b"
     r"|\bmap (?:below|above|to the|on the|pictured|shown|locations|labelled)|\b(?:see|shown|table|locations) "
     r"(?:below|above)\b|\bfor reference\b))[^()]*\)", ""),
    (r"\s*\((?:right|left|below|above)\)", ""),
    # "Using the image, ...", "Referencing the image to the right, ..."
    (r"\b(?:using|referencing|referring to|following) the " + PIC + r"(?: " + PIC_POS + r")?(?: for reference)?,\s*", ""),
    (r"\b(?:use|see|refer to) the " + PIC + r" " + PIC_POS + r"(?: for reference)?,\s*", ""),
    # "... shown in the picture", "as indicated on the map on the right"
    (r"(?<!is )(?<!are )(?<!is)(?<!are),?\s*\b(?:as )?(?:shown|indicated|marked|pictured|seen) (?:in|on) the " + PIC + r"(?: " + PIC_POS + r")?(?= |,|\.|$)", ""),
    (r",?\s*\b(?:using|referencing|referring to|following) the " + PIC + r" " + PIC_POS, ""),
    (r",?\s*\bpictured (?:right|left|below|above)\b", ""),
]
PICTURE_SENTENCE = re.compile(r"\b" + PIC + r"\b.*\b(?:right|left|below|above|reference|refer)\b"
                              r"|\b(?:right|left|below|above|reference|refer)\b.*\b" + PIC + r"\b", re.I)


def without_pictures(text):
    for pattern, repl in PICTURE_RULES:
        text = re.sub(pattern, repl, text, flags=re.I)
    # Whole sentences about a picture, after the first: "Use the picture on
    # the right for reference."
    sentences = re.split(r"(?<=[.!?])\s+", text)
    kept = [s for i, s in enumerate(sentences) if i == 0 or not PICTURE_SENTENCE.search(s) or len(s.split()) > 16]
    text = " ".join(kept).strip()
    text = re.sub(r"\s+([,.])", r"\1", text)
    return text[:1].upper() + text[1:]


def lua_str(v):
    v = v.replace(BS, BS + BS).replace('"', BS + '"').replace("\n", BS + "n")
    return '"' + v + '"'


def lua_list(xs):
    return "{ " + ", ".join(lua_str(x) for x in xs) + " }" if xs else "{}"


def key(name):
    return re.sub(r"[^a-z0-9]+", "_", name.lower()).strip("_")


guides = json.load(open(opts.guides, encoding="utf8"))
if opts.all:
    ORDER = sorted(t[:-len("/Quick guide")] for t, g in guides.items() if g.get("sections"))

# ---------- collect everything to look up ----------
link_pages, needed_items = set(), set()
for name in ORDER:
    for sec in guides[name + "/Quick guide"]["sections"]:
        for entry in sec["needed"]:
            for part in split_needed(entry):
                needed_items.update(item_names(part))
        for st in sec["steps"]:
            for link in st.get("links", []):
                link_pages.add(link["page"])
    for line in (guides[name + "/Quick guide"].get("details") or {}).get("items", []):
        first = re.split(r"\s+or\s+|\(", line["text"])[0].strip()
        if first and not first.lower().startswith("or "):
            needed_items.update(item_names(first))

# ---------- page kinds and coordinates ----------
pages = {}
recipes = {}
tradeable = {}
TRADEABLE_RE = re.compile(r"^\|\s*tradeable1?\s*=\s*(yes|no)\b", re.I | re.M)
RECIPE_RE = re.compile(r"\{\{\s*Infobox Recipe(.*?)\n\}\}", re.S | re.I)
RECIPE_DEPTH = 4  # needed item -> its materials -> theirs -> theirs


def parse_recipe(text):
    """First {{Infobox Recipe}} on a page: materials with quantities, facility, skill."""
    m = RECIPE_RE.search(text)
    if not m:
        return None
    fields = dict(re.findall(r"^\|\s*(\w+)\s*=\s*(.*?)\s*$", m.group(1), re.M))
    mats = []
    for n in range(1, 10):
        name = fields.get("mat%d" % n, "").strip()
        if name:
            qty = fields.get("mat%dqty" % n, "").strip()
            mats.append((qty + " " if qty and qty != "1" else "") + name)
    if not mats:
        return None
    skill = fields.get("skill1", "").strip()
    level = fields.get("skill1lvl", "").strip()
    if skill.lower() == "divination":
        return None  # transmuting ore or energy, not how anyone gets it for a quest
    return {"mats": mats, "facility": fields.get("facility", "").strip(),
            "skill": (skill + " " + level).strip() if skill else ""}


MAP_RE = re.compile(r"\{\{\s*(?:NPC map|Object map|Map|ObjectmapLink)\b([^{}]*)\}\}", re.I)
# Wiki maps write a spot as "x = 3222|y = 3218", "x:3222,y:3218" or a bare
# "|3222, 3218" pin. Some use a map's own local grid (Aga at 108,55): too
# small to be a game tile, so left out.
MIN_TILE = 1000
ALT_APART = 40     # tiles between two of an NPC's spots for both to be kept
MAX_ALTS = 6


def map_spots(text):
    spots = []
    for args in MAP_RE.findall(text):
        x = re.search(r"\bx\s*[=:]\s*(\d{3,5})", args)
        y = re.search(r"\by\s*[=:]\s*(\d{3,5})", args)
        if x and y:
            x, y = int(x.group(1)), int(y.group(1))
        else:
            pin = re.search(r"\|\s*(\d{3,5})\s*,\s*(\d{3,5})\s*(?=\||$)", args)
            if not pin:
                continue
            x, y = int(pin.group(1)), int(pin.group(2))
        p = re.search(r"\bplane\s*[=:]\s*(\d)", args)
        if x < MIN_TILE or y < MIN_TILE:
            continue
        spot = {"x": x, "y": y, "plane": int(p.group(1)) if p else 0}
        if all(abs(s["x"] - x) + abs(s["y"] - y) > ALT_APART for s in spots):
            spots.append(spot)
    return spots[:MAX_ALTS]


# What a page is, from its infobox: things to talk to or fight, things to
# carry, places (by size), objects. Anything else (achievements, quests,
# skills, spells) is "other": linked in a step, but nothing to click or go to.
INFOBOX_KINDS = {"npc": "npc", "monster": "npc", "item": "item", "bonuses": "item", "construction": "item",
                 "location": "location", "city": "location", "area": "location",
                 "shop": "place", "guild": "place", "minigame": "place", "ship": "place",
                 "scenery": "scenery", "object": "scenery"}


def acquire_names():
    """What each step's "get"/"buy"/"pick up" words name, as advance.lua reads
    them, so the wiki can say which are real items ("Get: boat" isn't)."""
    try:
        from lupa import lua54
    except ImportError:
        print("lupa isn't installed (pip install lupa): skipping the check of what steps say to get")
        return set()
    lua = lua54.LuaRuntime()
    here = os.path.dirname(os.path.abspath(__file__))
    with open(os.path.join(here, "..", "rs3qh-test", "advance.lua"), encoding="utf8") as f:
        advance = lua.execute(f.read())
    names = set()
    for quest in ORDER:
        for sec in guides[quest + "/Quick guide"]["sections"]:
            for st in sec["steps"]:
                for need in advance.AcquireTargets(lua.table_from({"text": st["text"]})).values():
                    names.add(need.name[:1].upper() + need.name[1:])
    return names


for group in batches(sorted(link_pages | needed_items | acquire_names()), 40):
    data = api({"action": "query", "prop": "revisions", "rvprop": "content", "rvslots": "main",
                "titles": "|".join(group)})
    q = data["query"]
    aliases = {}
    for r in q.get("normalized", []) + q.get("redirects", []):
        aliases.setdefault(r["to"], []).append(r["from"])
    for page in q["pages"].values():
        if "revisions" not in page:
            continue
        text = page["revisions"][0]["slots"]["main"]["*"]
        recipe = parse_recipe(text)
        if recipe and page["title"] in needed_items | set(aliases):
            recipes[page["title"].lower()] = recipe
        info = {}
        m = re.search(r"\{\{\s*Infobox ([A-Za-z ]+?)\s*[|\n}]", text)
        if m:
            info["kind"] = INFOBOX_KINDS.get(m.group(1).lower(), "other")
        spots = map_spots(text)
        if spots:
            info.update(spots[0])
            if len(spots) > 1:
                info["alts"] = spots
        if info:
            titles = [page["title"]]
            # Follow aliases back to the names used in the guides.
            frontier = [page["title"]]
            while frontier:
                t = frontier.pop()
                for a in aliases.get(t, []):
                    titles.append(a)
                    frontier.append(a)
            for t in titles:
                pages[t.lower()] = info
                tm = TRADEABLE_RE.search(text)
                if tm and info.get("kind") == "item":
                    tradeable[t.lower()] = tm.group(1).lower() == "yes"

# ---------- recipes of materials, a few levels down ----------
lookup = set()
for recipe in recipes.values():
    lookup.update(re.sub(r"^\d+\s+", "", mat) for mat in recipe["mats"])
for _ in range(RECIPE_DEPTH - 1):
    lookup = {name for name in lookup if name.lower() not in recipes}
    if not lookup:
        break
    found = set()
    for group in batches(sorted(lookup), 40):
        data = api({"action": "query", "prop": "revisions", "rvprop": "content", "rvslots": "main",
                    "titles": "|".join(group)})
        q = data["query"]
        back = {}
        for r in q.get("normalized", []) + q.get("redirects", []):
            back.setdefault(r["to"], []).append(r["from"])
        for page in q["pages"].values():
            if "revisions" not in page:
                continue
            recipe = parse_recipe(page["revisions"][0]["slots"]["main"]["*"])
            if recipe:
                for t in [page["title"]] + back.get(page["title"], []):
                    recipes[t.lower()] = recipe
                found.update(re.sub(r"^\d+\s+", "", mat) for mat in recipe["mats"])
    lookup = found

# ---------- item explanations ----------
items = {}
for group in batches(sorted(needed_items), 20):
    data = api({"action": "query", "prop": "extracts", "exintro": "1", "explaintext": "1",
                "exsentences": "2", "exlimit": "20", "titles": "|".join(group)})
    q = data["query"]
    back = {}
    for r in q.get("normalized", []) + q.get("redirects", []):
        back.setdefault(r["to"], []).append(r["from"])
    for page in q["pages"].values():
        extract = (page.get("extract") or "").strip()
        if not extract:
            continue
        for t in [page["title"]] + back.get(page["title"], []):
            items[t.lower()] = extract

# ---------- write ----------
out = ["-- Generated by plugin/tools/build_quests.py from the Alt1 app's quick-guide",
       "-- parser plus RuneScape Wiki page data. Regenerate rather than hand-edit.",
       "-- Wiki content is CC BY-NC-SA 3.0 (runescape.wiki).",
       "--",
       "-- step.npcs  = wiki link targets in the step (see `pages` for what each is)",
       "-- step.tile  = { x, y, plane } from the guide's {{Map}}, when it has one",
       "-- pages      = [lower-case page] = { kind, x, y, plane, alts } for linked pages and",
       "--              what steps say to get; kind is npc, item, location (town), place",
       "--              (shop, guild), scenery or other; alts = every spot of an NPC found in",
       "--              several places",
       "-- items      = [lower-case item] = short description (how to get or make it)",
       "-- recipes    = [lower-case item] = { mats, facility, skill } from {{Infobox Recipe}}",
       "-- tradeable  = [lower-case item] = true when it can be bought on the Grand Exchange",
       "", "return {"]
for name in ORDER:
    g = guides[name + "/Quick guide"]
    details = g.get("details") or {"items": [], "recommended": []}
    out.append("    {")
    out.append("        key = %s, name = %s, wiki = %s," % (lua_str(key(name)), lua_str(name), lua_str(name + "/Quick guide")))
    # The quest page's {{Quest details}} lists: required and recommended items.
    out.append("        required = %s," % lua_list([i["text"] for i in details["items"]]))
    out.append("        recommended = %s," % lua_list([i["text"] for i in details["recommended"]]))
    out.append("        sections = {")
    for sec in g["sections"]:
        out.append("            {")
        out.append("                title = %s, needed = %s," % (lua_str(sec["title"]), lua_list(sec["needed"])))
        out.append("                steps = {")
        for st in sec["steps"]:
            out.append("                    {")
            out.append("                        text = %s," % lua_str(without_pictures(st["text"])))
            if st.get("chat"):
                out.append("                        chat = %s," % lua_str(st["chat"]))
            seen = []
            for link in st.get("links", []):
                if link["page"] not in seen:
                    seen.append(link["page"])
            out.append("                        npcs = %s," % lua_list(seen))
            if st.get("maps"):
                m = st["maps"][0]
                out.append("                        tile = { x = %d, y = %d, plane = %d }," % (m["x"], m["y"], m["plane"]))
            if st.get("sub"):
                out.append("                        subs = {")
                for sub in st["sub"]:
                    chat = (", chat = " + lua_str(sub["chat"])) if sub.get("chat") else ""
                    out.append("                            { text = %s%s }," % (lua_str(without_pictures(sub["text"])), chat))
                out.append("                        },")
            out.append("                    },")
        out.append("                },")
        out.append("            },")
    out.append("        },")
    out.append("    },")
out.append("    pages = {")
for title in sorted(pages):
    info = pages[title]
    fields = []
    if "kind" in info:
        fields.append("kind = %s" % lua_str(info["kind"]))
    if "x" in info:
        fields.append("x = %d, y = %d, plane = %d" % (info["x"], info["y"], info["plane"]))
    if "alts" in info:
        fields.append("alts = { %s }" % ", ".join("{ x = %d, y = %d, plane = %d }" % (a["x"], a["y"], a["plane"])
                                                  for a in info["alts"]))
    out.append("        [%s] = { %s }," % (lua_str(title), ", ".join(fields)))
out.append("    },")
out.append("    tradeable = {")
for title in sorted(tradeable):
    out.append("        [%s] = %s," % (lua_str(title), "true" if tradeable[title] else "false"))
out.append("    },")
out.append("    recipes = {")
for title in sorted(recipes):
    r = recipes[title]
    out.append("        [%s] = { mats = %s, facility = %s, skill = %s }," % (
        lua_str(title), lua_list(r["mats"]), lua_str(r["facility"]), lua_str(r["skill"])))
out.append("    },")
out.append("    items = {")
for title in sorted(items):
    out.append("        [%s] = %s," % (lua_str(title), lua_str(items[title])))
out.append("    },")
out.append("}")
open(OUT, "w", encoding="utf8", newline="\n").write("\n".join(out) + "\n")
if opts.cache:
    json.dump(cache, open(opts.cache, "w", encoding="utf8"))
print("wrote %s: %d pages, %d item descriptions, %d recipes" % (OUT, len(pages), len(items), len(recipes)))
