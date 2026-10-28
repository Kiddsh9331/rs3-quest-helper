# Prints a session recording from the test plugin as a readable timeline,
# with a summary of flagged problems and steps advanced by hand.
#
#   python plugin/tests/read_rec.py              newest session
#   python plugin/tests/read_rec.py --list       sessions kept
#   python plugin/tests/read_rec.py --session 7  one session
#   python plugin/tests/read_rec.py --full       include every position sample
#   python plugin/tests/read_rec.py --save rec.txt   keep a copy (for replay.py --file)
import argparse
import sys

import recording

parser = argparse.ArgumentParser()
parser.add_argument("--db", help="PluginData.db path (default: the beta client's)")
parser.add_argument("--file", help="a recording saved with --save")
parser.add_argument("--session", help="session name (default: newest)")
parser.add_argument("--list", action="store_true")
parser.add_argument("--full", action="store_true", help="show every position sample")
parser.add_argument("--save", help="write the session's raw lines to this file")
args = parser.parse_args()
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

sessions = recording.load(args.db, args.file)
if not sessions:
    sys.exit("No recordings found. Play with the plugin loaded (Recording: on), then close the game or wait ~6s.")
if args.list:
    for name, lines in sessions.items():
        last = recording.parse(lines[-1])[0] if lines else 0
        flags = sum(1 for line in lines if recording.parse(line)[1] == "flag")
        print("session %-6s %5d events  %s long  %d flagged" % (name, len(lines), recording.clock(last), flags))
    sys.exit(0)

name = args.session or list(sessions)[-1]
if name not in sessions:
    sys.exit("No session %s. Kept: %s" % (name, ", ".join(sessions)))
lines = sessions[name]
if args.save:
    with open(args.save, "w", encoding="utf8") as f:
        f.write("\n".join(lines) + "\n")
    print("Saved %d lines to %s" % (len(lines), args.save))


def describe(kind, f):
    get = lambda i: f[i] if i < len(f) else ""
    if kind == "step":
        source = get(4)
        text = "%s %s -> %s" % (get(0), get(1), get(2))
        if get(3):
            text += "  (%s)" % get(3)
        return text + ("  [BY HAND: %s]" % source if source in recording.MANUAL_SOURCES else "  [auto]")
    if kind == "click":
        where = "  in interface %s" % get(3) if get(3) else ""
        return "%s | %s  (type %s)%s" % (get(0), get(1), get(2), where)
    if kind == "var":
        return "%s %s -> %s" % (get(0), get(1) or "?", get(2))
    if kind == "pos":
        return "%s, %s  level %s" % (get(0), get(1), get(2))
    if kind == "flag":
        return ">>> PROBLEM #%s flagged (%s) on %s step %s <<<" % (get(0), get(1), get(2), get(3))
    if kind == "bag":
        return get(0).replace(";", ", ") or "(empty)"
    if kind == "targets":
        return "%s step %s: npcs=%s items=%s nav=%s" % tuple(get(i) for i in range(5))
    if kind == "start":
        return "build %s, quest %s step %s, %s, %s" % tuple(get(i) for i in range(5))
    return "  ".join(f)


events = [recording.parse(line) for line in lines]
flags = [(t, f) for t, k, f in events if k == "flag"]
manual = [(t, f) for t, k, f in events if k == "step" and len(f) > 4 and f[4] in recording.MANUAL_SOURCES]
auto = [(t, f) for t, k, f in events if k == "step" and len(f) > 4 and f[4] == "auto"]
errors = [(t, f) for t, k, f in events if k == "note" and "ERROR" in f[0]]

print("Session %s: %d events, %s long" % (name, len(events), recording.clock(events[-1][0] if events else 0)))
print("  %d steps advanced automatically, %d by hand, %d problems flagged, %d errors"
      % (len(auto), len(manual), len(flags), len(errors)))
for t, f in flags:
    print("  flag #%s at %s: %s step %s" % (f[0], recording.clock(t), f[2], f[3]))
for t, f in manual:
    print("  by hand at %s: %s %s -> %s (%s)" % (recording.clock(t), f[0], f[1], f[2], f[4]))
for t, f in errors:
    print("  error at %s: %s" % (recording.clock(t), f[0][:200]))
print()

last_pos = None
for t, kind, f in events:
    if kind == "pos" and not args.full:
        last_pos = f
        continue
    where = "  @%s,%s" % (last_pos[0], last_pos[1]) if last_pos and kind in ("step", "click", "flag") else ""
    print("%6s %-11s %s%s" % (recording.clock(t), kind.upper(), describe(kind, f), where))
