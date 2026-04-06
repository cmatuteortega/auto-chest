#!/usr/bin/env python3
"""
Reset all deck slots for every player to:
  Deck 1: 2x boney, 2x marrow, 2x knight, 2x marc
  Decks 2-5: same contents, different name

Run on the VPS: python3 reset_decks.py /opt/autochest/server/players.db
"""
import sqlite3
import json
import sys
import shutil

if len(sys.argv) < 2:
    print("Usage: python3 reset_decks.py <path_to_players.db>")
    sys.exit(1)

db_path = sys.argv[1]

backup = db_path + ".bak"
shutil.copy2(db_path, backup)
print(f"Backup written to {backup}")

COUNTS = {"boney": 2, "marrow": 2, "knight": 2, "marc": 2}

decks = []
for i in range(1, 6):
    decks.append(json.dumps({"name": f"Deck {i}", "counts": COUNTS}, separators=(',', ':')))

conn = sqlite3.connect(db_path)
cur = conn.cursor()

cur.execute("""
    UPDATE players SET
        deck1_json = ?,
        deck2_json = ?,
        deck3_json = ?,
        deck4_json = ?,
        deck5_json = ?
""", decks)

print(f"Updated {cur.rowcount} players.")
conn.commit()
conn.close()
print("Done.")
