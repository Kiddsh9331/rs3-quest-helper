# Prints what the test plugin saved in the beta client's PluginData.db:
# its error/diagnostic log, status snapshots, and settings.
#
#   python plugin/tests/read_diag.py [path to PluginData.db]
import os
import shutil
import sqlite3
import sys
import tempfile

DEFAULT = r"C:\ProgramData\Jagex\RuneScape-BETA\plugins\PluginData.db"
PLUGIN = "RS3 Quest Helper (test)"

source = sys.argv[1] if len(sys.argv) > 1 else DEFAULT
# Copy first: the game keeps the database open while it runs.
copy = os.path.join(tempfile.mkdtemp(), "PluginData.db")
shutil.copy(source, copy)

db = sqlite3.connect(copy)
# Session recordings (rec.*) have their own reader: read_rec.py.
rows = db.execute("SELECT Key, Value FROM DataStore WHERE PluginID = ? AND Key NOT LIKE 'rec.%' ORDER BY Key",
                  (PLUGIN,)).fetchall()
for key, value in rows:
    text = value.decode("utf-8", "replace").rstrip("\x00") if isinstance(value, bytes) else str(value)
    print("== " + key)
    print(text)
