# Downloads the wikitext of every quick guide (Category:Quick guides) and its
# quest page, for dump_guides.html?src= to parse all at once. The wiki turns
# away hundreds of browser requests, so this asks for 40 pages at a time and
# keeps what it got in a cache between runs.
#
#   python plugin/tools/fetch_wikitext.py wikitext_all.json --cache wt_cache.json
import argparse
import json
import os
import sys
import time
import urllib.parse
import urllib.request

API = "https://runescape.wiki/api.php"

parser = argparse.ArgumentParser()
parser.add_argument("out")
parser.add_argument("--cache")
opts = parser.parse_args()


def api(params):
    params = dict(params, format="json", redirects="1")
    req = urllib.request.Request(API + "?" + urllib.parse.urlencode(params),
                                 headers={"User-Agent": "rs3qh-plugin-builder (github.com/Kiddsh9331/rs3-quest-helper)"})
    for attempt in range(5):
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                return json.load(resp)
        except OSError as e:
            print("retrying:", e, file=sys.stderr)
            time.sleep(5 * (attempt + 1))
    raise SystemExit("the wiki didn't answer")


titles, cont = [], None
while True:
    params = {"action": "query", "list": "categorymembers", "cmtitle": "Category:Quick guides",
              "cmtype": "page", "cmlimit": "500"}
    if cont:
        params["cmcontinue"] = cont
    data = api(params)
    titles += [m["title"] for m in data["query"]["categorymembers"] if m["title"].endswith("/Quick guide")]
    cont = data.get("continue", {}).get("cmcontinue")
    if not cont:
        break

wanted = titles + [t[:-len("/Quick guide")] for t in titles]
text = json.load(open(opts.cache, encoding="utf8")) if opts.cache and os.path.exists(opts.cache) else {}
todo = [t for t in wanted if t not in text]
for i in range(0, len(todo), 40):
    group = todo[i:i + 40]
    data = api({"action": "query", "prop": "revisions", "rvprop": "content", "rvslots": "main",
                "titles": "|".join(group)})
    q = data["query"]
    back = {}
    for r in q.get("normalized", []) + q.get("redirects", []):
        back.setdefault(r["to"], []).append(r["from"])
    for page in q["pages"].values():
        content = page["revisions"][0]["slots"]["main"]["*"] if "revisions" in page else None
        names = [page["title"]] + back.get(page["title"], [])
        for name in list(names):
            names += back.get(name, [])
        for name in names:
            text[name] = content
    for t in group:
        text.setdefault(t, None)
    if opts.cache:
        json.dump(text, open(opts.cache, "w", encoding="utf8"))
    print("%d / %d" % (i + len(group), len(todo)), file=sys.stderr)
    time.sleep(1)

json.dump({"titles": titles, "text": {t: text.get(t) for t in wanted}}, open(opts.out, "w", encoding="utf8"))
print("%d guides, %d pages with text" % (len(titles), sum(1 for t in wanted if text.get(t))))
