# Builds the release zip for mod.io from plugin/rs3-quest-buddy: the same code
# as the test build minus its debug tools, with edition.lua and plugin.json
# rewritten for release. Checks the release copy offline (tests/release.lua)
# before zipping.
#
#   pip install lupa
#   python plugin/tools/package.py --email you@example.com
#   python plugin/tools/package.py --email you@example.com --no-guidance
#
# --email is the public contact address shown to players (mod.io requires
# one). --no-guidance leaves out the walking path, tile marker and teleport
# hints, for if review rules them out. The zip lands in plugin/dist/ with
# main.lua and plugin.json at its top level, as mod.io wants.
import argparse
import json
import os
import re
import shutil
import sys
import tempfile
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCE = os.path.join(HERE, "..", "rs3-quest-buddy")
DIST = os.path.join(HERE, "..", "dist")

NAME = "RS3 Quest Buddy"
LEFT_OUT = {"devtools.lua"}  # the test build's Debug section

EDITION = """-- Which build this is: the release build, made by tools/package.py.

return {
    name = "%s",
    release = true,
    devTools = false,
    recordByDefault = false,
    guidance = %s,
}
"""


def manifest(version, email):
    with open(os.path.join(SOURCE, "plugin.json"), encoding="utf8") as f:
        test = json.load(f)
    return {
        "name": NAME,
        "version": version,
        "contactEmailAddress": email,
        "hasRibbonIcon": test.get("hasRibbonIcon", True),
        "requiredDependencies": {},
        "optionalDependencies": {},
        "requiredPermissions": [],
        # Only chat: it lets "You have slain..." finish fight steps. The test
        # build's httpAccess was for a debug button; quest data is built in.
        "optionalPermissions": ["chatAccess"],
    }


def stage(dest, version="0.0.0", email="tester@example.com", guidance=True):
    """Write the release plugin's files into `dest` (an empty folder)."""
    for name in sorted(os.listdir(SOURCE)):
        if name.endswith(".lua") and name not in LEFT_OUT:
            shutil.copyfile(os.path.join(SOURCE, name), os.path.join(dest, name))
    with open(os.path.join(dest, "edition.lua"), "w", encoding="utf8", newline="\n") as f:
        f.write(EDITION % (NAME, "true" if guidance else "false"))
    with open(os.path.join(dest, "plugin.json"), "w", encoding="utf8", newline="\n") as f:
        json.dump(manifest(version, email), f, indent=4)
        f.write("\n")


def check(dest, guidance):
    """Load the staged plugin against the stand-in API and run tests/release.lua."""
    try:
        from lupa import lua54
    except ImportError:
        sys.exit("This needs the lupa package to check the plugin before zipping: python -m pip install lupa")
    tests = os.path.join(HERE, "..", "tests")
    lua = lua54.LuaRuntime()
    g = lua.globals()
    g.PLUGIN_DIR = dest.replace("\\", "/")
    g.GUIDANCE = guidance
    lua.execute('package.path = PLUGIN_DIR .. "/?.lua;" .. package.path')
    for script in ("mock.lua", "release.lua"):
        with open(os.path.join(tests, script), encoding="utf8") as f:
            report = lua.execute(f.read())
    return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--email", required=True, help="public contact address for players")
    parser.add_argument("--version", help="digits and dots; defaults to rs3-quest-buddy/plugin.json's")
    parser.add_argument("--no-guidance", action="store_true", help="leave out the path, tile marker and teleport hints")
    opts = parser.parse_args()

    with open(os.path.join(SOURCE, "plugin.json"), encoding="utf8") as f:
        version = opts.version or json.load(f)["version"]
    if not re.fullmatch(r"\d+(\.\d+)*", version):
        sys.exit("version must be digits and dots only (mod.io rule): " + version)
    if not re.fullmatch(r"[^@\s]+@[^@\s]+\.[^@\s]+", opts.email) or "example." in opts.email:
        sys.exit("--email must be a real public contact address")
    guidance = not opts.no_guidance

    with tempfile.TemporaryDirectory() as dest:
        stage(dest, version, opts.email, guidance)
        report = check(dest, guidance)
        print(report)
        if not report.endswith("RELEASE CHECKS PASSED"):
            sys.exit("release checks failed: not zipped")
        os.makedirs(DIST, exist_ok=True)
        slug = re.sub(r"[^a-z0-9]+", "-", NAME.lower()).strip("-")
        out = os.path.join(DIST, "%s-%s%s.zip" % (slug, version, "" if guidance else "-no-guidance"))
        with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
            for name in sorted(os.listdir(dest)):
                z.write(os.path.join(dest, name), name)  # top level, no folder
    print("wrote " + os.path.normpath(out))


if __name__ == "__main__":
    main()
