#!/usr/bin/env python3
"""
Migrate players.db: rename unit keys in deck/unlock JSON columns.
  "lancer"    -> "clavicula"
  "clavicula" -> "migraine"

Must be done as a swap to avoid double-renaming.
Run on the VPS: python3 migrate_unit_rename.py /opt/autochest/server/players.db
"""
import sqlite3
import json
import sys
import shutil
import os

if len(sys.argv) < 2:
    print("Usage: python3 migrate_unit_rename.py <path_to_players.db>")
    sys.exit(1)

db_path = sys.argv[1]

# Backup first
backup = db_path + ".bak"
shutil.copy2(db_path, backup)
print(f"Backup written to {backup}")

def rename_units(obj):
    """Recursively rename unit keys/values in a dict/list."""
    if isinstance(obj, dict):
        new = {}
        for k, v in obj.items():
            new_k = k
            if k == "lancer":
                new_k = "clavicula"
            elif k == "clavicula":
                new_k = "migraine"
            new[new_k] = rename_units(v)
        return new
    elif isinstance(obj, list):
        return [rename_units(i) for i in obj]
    elif isinstance(obj, str):
        if obj == "lancer":
            return "clavicula"
        elif obj == "clavicula":
            return "migraine"
        return obj
    return obj

JSON_COLS = ["deck1_json", "deck2_json", "deck3_json", "deck4_json", "deck5_json", "unlocks_json"]

conn = sqlite3.connect(db_path)
cur = conn.cursor()

cur.execute("SELECT id FROM players")
player_ids = [row[0] for row in cur.fetchall()]
print(f"Migrating {len(player_ids)} players...")

updated = 0
for pid in player_ids:
    cur.execute(f"SELECT {', '.join(JSON_COLS)} FROM players WHERE id = ?", (pid,))
    row = cur.fetchone()
    updates = {}
    for i, col in enumerate(JSON_COLS):
        raw = row[i]
        if raw is None:
            continue
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            print(f"  Player {pid} col {col}: invalid JSON, skipping")
            continue
        new_data = rename_units(data)
        if new_data != data:
            updates[col] = json.dumps(new_data, separators=(',', ':'))
    if updates:
        set_clause = ", ".join(f"{c} = ?" for c in updates)
        values = list(updates.values()) + [pid]
        cur.execute(f"UPDATE players SET {set_clause} WHERE id = ?", values)
        updated += 1
        print(f"  Player {pid}: updated {list(updates.keys())}")

conn.commit()
conn.close()
print(f"Done. {updated} players updated.")
