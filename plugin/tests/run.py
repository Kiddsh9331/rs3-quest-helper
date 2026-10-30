# Offline test run for the plugin: loads it in a real Lua 5.4 (via lupa)
# against mock.lua's stand-in API, clicks through every feature, and
# prints PASS/FAIL lines ending in "ALL PLUGIN TESTS PASSED".
#
#   pip install lupa
#   python plugin/tests/run.py
#
# It catches typos, nil errors and logic bugs. It can't tell whether the
# real API behaves the way mock.lua assumes; only the beta client can.
import os
import sys

from lupa import lua54

# Quest text has characters the Windows console can't show.
if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(errors='replace')

here = os.path.dirname(os.path.abspath(__file__)).replace('\\', '/')
plugin_dir = os.path.join(here, '..', 'rs3-quest-buddy').replace('\\', '/')

lua = lua54.LuaRuntime()
lua.globals().PLUGIN_DIR = plugin_dir
lua.execute('package.path = PLUGIN_DIR .. "/?.lua;" .. package.path')
# The plugin ships every quest; the tests play the five in quests_test.lua
# (built with build_quests.py's default list).
lua.globals().TEST_QUESTS = os.path.join(here, 'quests_test.lua').replace('\\', '/')
lua.execute('package.loaded.quests = dofile(TEST_QUESTS)')

# Syntax-check every module first so a typo names its file.
for name in sorted(os.listdir(plugin_dir)):
    if name.endswith('.lua'):
        with open(os.path.join(plugin_dir, name), encoding='utf8') as f:
            lua.execute('assert(load(..., "' + name + '"))', f.read())

with open(os.path.join(here, 'mock.lua'), encoding='utf8') as f:
    lua.execute(f.read())
with open(os.path.join(here, 'run.lua'), encoding='utf8') as f:
    report = lua.execute(f.read())

# The session the run just recorded, replayed in a fresh runtime, must reach
# every step the same way (recorder.lua -> replay.lua round trip).
import replay
recorded = list(lua.globals().RUN_RECORDING.values())
fixed, broke, extra, same = replay.compare(recorded, replay.run_replay(recorded))
round_trip = not fixed and not broke and not extra and len(same) > 20
lines = report.splitlines()
lines.insert(-1, ('PASS' if round_trip else 'FAIL') + ' replaying the recorded test session reaches every step the same way')
if not round_trip:
    lines.insert(-1, '  ' + '; '.join(fixed + broke + extra) + ' (%d same)' % len(same))
    lines[-1] = 'REPLAY FAILED' if lines[-1] == 'ALL PLUGIN TESTS PASSED' else lines[-1]

# The release zip's contents (tools/package.py), with and without walking
# guidance, each loaded fresh and checked by release.lua.
import tempfile
sys.path.insert(0, os.path.join(here, '..', 'tools'))
import package
for guidance in (True, False):
    with tempfile.TemporaryDirectory() as staged:
        package.stage(staged, guidance=guidance)
        release = package.check(staged, guidance)
    ok = release.endswith('RELEASE CHECKS PASSED')
    lines.insert(-1, ('PASS' if ok else 'FAIL') + ' release build checks (%s guidance)' % ('with' if guidance else 'without'))
    if not ok:
        lines.insert(-1, '  ' + '; '.join(l for l in release.splitlines() if l.startswith('FAIL')))
        lines[-1] = 'RELEASE FAILED' if lines[-1] == 'ALL PLUGIN TESTS PASSED' else lines[-1]
# --full [wiki cache]: every quest through check_quests.py against the
# committed baseline (tests/check_baseline.json); new bug-class findings fail.
if '--full' in sys.argv:
    import subprocess
    args = [sys.executable, os.path.join(here, 'check_quests.py'), os.path.join(plugin_dir, 'quests.lua'),
            '--baseline', os.path.join(here, 'check_baseline.json')]
    extra = [a for a in sys.argv[1:] if a != '--full']
    if extra:
        args += ['--cache', extra[0]]
    full = subprocess.run(args, capture_output=True, text=True, encoding='utf8', errors='replace')
    out = full.stdout.splitlines()
    start = next((i for i, l in enumerate(out) if l.startswith('== compared with')), len(out))
    tail = [l for l in out[start + 1:] if l.startswith('   ') or l.startswith('BASELINE')]
    ok = 'BASELINE CHECK PASSED' in full.stdout
    lines.insert(-1, ('PASS' if ok else 'FAIL') + ' all quests on paper match the baseline (check_quests.py)')
    for l in tail:
        lines.insert(-1, '  ' + l.strip())
    if not ok:
        lines[-1] = 'BASELINE FAILED' if lines[-1] == 'ALL PLUGIN TESTS PASSED' else lines[-1]
report = '\n'.join(lines)
print(report)
sys.exit(0 if report.endswith('ALL PLUGIN TESTS PASSED') else 1)
