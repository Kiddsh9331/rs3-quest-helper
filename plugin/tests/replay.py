# Replays a session recording through the current plugin code (offline, via
# mock.lua) and compares what the plugin decided in game with what it
# decides now: which steps it completed by itself, and which dialogue
# options it turned blue. Use it to reproduce a tester's report, then to
# confirm a fix (steps that needed a click in game should now go "auto").
#
#   python plugin/tests/replay.py                 newest session in the beta's PluginData.db
#   python plugin/tests/replay.py --session 7
#   python plugin/tests/replay.py --file rec.txt  a copy saved with read_rec.py --save
import argparse
import os
import sys

from lupa import lua54

import recording

here = os.path.dirname(os.path.abspath(__file__)).replace("\\", "/")


def run_replay(game_lines):
    """Feeds a recording through the current plugin; returns the replay's own recording."""
    plugin_dir = os.path.join(here, "..", "rs3-quest-buddy").replace("\\", "/")
    lua = lua54.LuaRuntime()
    lua.globals().PLUGIN_DIR = plugin_dir
    lua.globals().REC = lua.table_from(game_lines)
    lua.execute('package.path = PLUGIN_DIR .. "/?.lua;" .. package.path')
    # Recordings of the five test quests replay against their data (see
    # run.py); any other quest needs the full list the plugin ships.
    fixture = os.path.join(here, "quests_test.lua").replace("\\", "/")
    with open(fixture, encoding="utf8") as f:
        fixture_text = f.read()
    opened = {recording.parse(line)[2][0] for line in game_lines if recording.parse(line)[1] == "open"}
    if all('key = "%s"' % key in fixture_text for key in opened):
        lua.globals().TEST_QUESTS = fixture
        lua.execute("package.loaded.quests = dofile(TEST_QUESTS)")
    for script in ("mock.lua", "replay.lua"):
        with open(os.path.join(here, script), encoding="utf8") as f:
            result = lua.execute(f.read())
    return list(result.values())


def steps(lines):
    """Step changes as (tick, quest, from, to, why, source)."""
    out = []
    for line in lines:
        tick, kind, f = recording.parse(line)
        if kind == "step":
            out.append((tick, f[0], int(f[1]), int(f[2]), f[3], f[4]))
    return out


def reached(changes):
    """(quest, step) -> first (tick, why, source) that landed on it."""
    out = {}
    for tick, quest, _, to, why, source in changes:
        out.setdefault((quest, to), (tick, why, source))
    return out


def compare(game_lines, replay_lines):
    """Steps now auto that were by hand, steps no longer auto, new auto steps, same steps."""
    replay_changes, game_changes = steps(replay_lines), steps(game_lines)
    in_game, now = reached(game_changes), reached(replay_changes)
    fixed, broke, same = [], [], []
    for key, (tick, why, source) in sorted(in_game.items(), key=lambda item: item[1][0]):
        quest, to = key
        then_auto = source == "auto"
        replayed = now.get(key)
        if source in ("done button", "checkbox", "Alt+D", "manual") and (replayed is None or replayed[2] != "auto"):
            # An automatic jump over this step (ore mined a step early) counts
            # too, if it happened while the tester was working towards it.
            earlier = [t for t, *_ in game_changes if t < tick]
            since = earlier[-1] if earlier else 0
            for t, q, start, end, w, s in replay_changes:
                if q == quest and s == "auto" and start < to < end and since <= t <= tick:
                    replayed = (t, w + " (skipped past it)", s)
                    break
        now_auto = replayed is not None and replayed[2] == "auto"
        line = "%s  %s step %d" % (recording.clock(tick), quest, to)
        if not then_auto and now_auto:
            fixed.append("%s: in game by hand (%s), now auto at %s (%s)"
                         % (line, source, recording.clock(replayed[0]), replayed[1]))
        elif then_auto and not now_auto:
            broke.append("%s: was auto (%s), now %s" % (line, why, "reached by hand" if replayed else "never reached"))
        else:
            same.append("%s  %s" % (line, why or source))
    extra = ["%s  %s step %d (%s)" % (recording.clock(tick), quest, to, why)
             for (quest, to), (tick, why, source) in sorted(now.items(), key=lambda item: item[1][0])
             if (quest, to) not in in_game and source == "auto"]
    return fixed, broke, extra, same


def option_marks(lines):
    return [(tick, f[0]) for tick, kind, f in map(recording.parse, lines) if kind == "optionmarks" and f and f[0]]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--db")
    parser.add_argument("--file")
    parser.add_argument("--session")
    parser.add_argument("--all", action="store_true", help="list matching steps too, not just differences")
    args = parser.parse_args()
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

    sessions = recording.load(args.db, args.file)
    if not sessions:
        sys.exit("No recordings found.")
    name = args.session or list(sessions)[-1]
    game_lines = sessions[name]
    replay_lines = run_replay(game_lines)
    print("Session %s: %d events replayed (%s of play)" % (name, len(game_lines),
          recording.clock(recording.parse(game_lines[-1])[0] if game_lines else 0)))
    print()

    fixed, broke, extra, same = compare(game_lines, replay_lines)
    if args.all:
        for line in same:
            print("  same   " + line)
    print("Steps that now complete by themselves (%d):" % len(fixed))
    for line in fixed:
        print("  + " + line)
    print("Steps that no longer complete by themselves (%d):" % len(broke))
    for line in broke:
        print("  - " + line)
    if extra:
        print("Steps the replay reached that the game never did (%d):" % len(extra))
        for line in extra:
            print("  ? " + line)
    print("Unchanged: %d" % len(same))

    game_marks, replay_marks = set(m for _, m in option_marks(game_lines)), set(m for _, m in option_marks(replay_lines))
    if game_marks != replay_marks:
        print()
        print("Dialogue options highlighted in game but not in the replay: %s" % (sorted(game_marks - replay_marks) or "none"))
        print("Highlighted in the replay but not in game: %s" % (sorted(replay_marks - game_marks) or "none"))

    flags = [(t, f) for t, k, f in map(recording.parse, game_lines) if k == "flag"]
    if flags:
        print()
        print("Flagged problems: " + ", ".join("#%s at %s (%s step %s)" % (f[0], recording.clock(t), f[2], f[3]) for t, f in flags))
    errors = [f[0] for _, k, f in map(recording.parse, replay_lines) if k == "note" and "ERROR" in f[0]]
    if errors:
        print()
        print("Errors during the replay:")
        for e in errors:
            print("  " + e[:300])


if __name__ == "__main__":
    main()
