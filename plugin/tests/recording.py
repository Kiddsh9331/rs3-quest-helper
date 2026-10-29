# Loads session recordings made by the test plugin (rs3-quest-buddy/recorder.lua)
# from the beta client's PluginData.db, or from a text file saved with
# read_rec.py --save. Shared by read_rec.py and replay.py.
import json
import os
import shutil
import sqlite3
import tempfile

DEFAULT_DB = r"C:\ProgramData\Jagex\RuneScape-BETA\plugins\PluginData.db"
PLUGIN = "RS3 Quest Buddy (test)"
OLD_PLUGIN = "RS3 Quest Helper (test)"  # the test build's name before the rename
TICK_SECONDS = 0.6


def _text(raw):
    return raw.decode("utf-8", "replace").rstrip("\x00") if isinstance(raw, bytes) else str(raw)


def _int(raw):
    if isinstance(raw, bytes):
        return int.from_bytes(raw, "little", signed=True)
    return int(raw or 0)


# Structured data is stored as JSON: [{"key": 1, "value": "..."}, ...].
def _list(raw):
    data = json.loads(_text(raw), strict=False)
    if not isinstance(data, list):
        return []
    return [entry["value"] for entry in sorted(data, key=lambda entry: float(entry["key"]))]


def load_db(path=DEFAULT_DB):
    """Returns {session name: [line, ...]}, oldest session first."""
    # Copy first: the game keeps the database open while it runs.
    copy = os.path.join(tempfile.mkdtemp(), "PluginData.db")
    shutil.copy(path, copy)
    db = sqlite3.connect(copy)
    rows = {}
    for plugin in (PLUGIN, OLD_PLUGIN):
        rows = dict(db.execute("SELECT Key, Value FROM DataStore WHERE PluginID = ? AND Key LIKE 'rec.%'",
                               (plugin,)).fetchall())
        if rows:
            break
    db.close()
    sessions = {}
    for name in (str(s) for s in _list(rows["rec.sessions"])) if "rec.sessions" in rows else []:
        lines = []
        for n in range(1, _int(rows.get("rec.%s.chunks" % name)) + 1):
            if "rec.%s.%d" % (name, n) in rows:
                lines += _list(rows["rec.%s.%d" % (name, n)])
        sessions[name] = lines
    return sessions


def load_file(path):
    with open(path, encoding="utf8") as f:
        return {os.path.basename(path): [line.rstrip("\n") for line in f if line.strip()]}


def load(db=None, file=None):
    return load_file(file) if file else load_db(db or DEFAULT_DB)


def parse(line):
    """'12<TAB>step<TAB>a<TAB>b' -> (12, 'step', ['a', 'b'])"""
    parts = line.split("\t")
    return int(parts[0]), parts[1], parts[2:]


def clock(tick):
    seconds = int(tick * TICK_SECONDS)
    return "%d:%02d" % (seconds // 60, seconds % 60)


# Step changes the tester made by hand. Each one on a step the plugin
# should have spotted is a missed auto-complete.
MANUAL_SOURCES = {"manual", "done button", "back button", "checkbox", "Alt+D", "mark complete button", "restart"}
