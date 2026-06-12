#!/usr/bin/env python3
"""
Import SSH hosts into Warp's SQLite database from a CSV file.

CSV columns (order matters, header row required):
    alias, tag, group, ip, port, user, pass, notes

Rules:
  - Groups are auto-created if they don't exist.
  - Tags are comma-separated (e.g. "aws,prod") and auto-created in ssh_labels.
  - port defaults to 22 if blank.
  - pass and notes are optional (blank is fine).
  - Duplicate aliases are skipped with a warning.

Usage:
    python3 Ankur/import_ssh.py data.csv
    python3 Ankur/import_ssh.py data.csv --db /path/to/warp.sqlite
"""

import csv
import sqlite3
import sys
import os
import argparse
from datetime import datetime, timezone

# ---------------------------------------------------------------------------
# Locate the Warp SQLite DB
# ---------------------------------------------------------------------------

def _db_from_running_process() -> list:
    """
    Ask lsof which warp.sqlite file the running Warp process has open.
    Works for unsigned builds (warp-oss binary) and official builds alike.
    Returns a list so it can be prepended to CANDIDATE_PATHS.
    """
    import subprocess
    found = []
    try:
        # Try every likely executable name
        for exe in ("WarpAnkur"):
            pids = subprocess.run(
                ["pgrep", exe], capture_output=True, text=True
            ).stdout.split()
            for pid in pids:
                lsof = subprocess.run(
                    ["lsof", "-p", pid.strip()], capture_output=True, text=True
                )
                for line in lsof.stdout.splitlines():
                    if "warp.sqlite" in line and "REG" in line:
                        # last token on the line is the path
                        path = line.split()[-1]
                        if os.path.isfile(path) and path not in found:
                            found.append(path)
    except Exception:
        pass
    return found


def _group_container_paths():
    """Enumerate App Group container paths for all known team IDs / app names."""
    gc = os.path.expanduser("~/Library/Group Containers")
    if not os.path.isdir(gc):
        return []
    paths = []
    for entry in os.scandir(gc):
        if not entry.is_dir():
            continue
        for app_name in ("dev.warp.WarpOss", "dev.warp.Warp-Stable", "dev.warp.Warp-Dev", "dev.warp.Warp-Preview"):
            candidate = os.path.join(entry.path, "Library", "Application Support", app_name, "warp.sqlite")
            if os.path.isfile(candidate):
                paths.append(candidate)
    return paths

CANDIDATE_PATHS = (
    _db_from_running_process()          # highest priority: whatever is open right now
    + [
        # Non-sandboxed Application Support (unsigned / custom builds)
        os.path.expanduser("~/Library/Application Support/dev.warp.WarpOss/warp.sqlite"),
        os.path.expanduser("~/Library/Application Support/dev.warp.Warp-Stable/warp.sqlite"),
        os.path.expanduser("~/Library/Application Support/dev.warp.Warp-Dev/warp.sqlite"),
        os.path.expanduser("~/Library/Application Support/dev.warp.Warp-Preview/warp.sqlite"),
    ]
    + _group_container_paths()          # sandboxed official builds
)


def find_db() -> str:
    for path in CANDIDATE_PATHS:
        if os.path.isfile(path):
            return path
    raise FileNotFoundError(
        "Could not find warp.sqlite. "
        "Run Warp at least once so the DB is created, "
        "or pass --db /path/to/warp.sqlite explicitly.\n"
        "Searched:\n" + "\n".join(f"  {p}" for p in CANDIDATE_PATHS)
    )


# ---------------------------------------------------------------------------
# DB helpers
# ---------------------------------------------------------------------------

NOW = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")


def get_or_create_group(conn: sqlite3.Connection, name: str) -> int:
    name = name.strip()
    label = name.lower()
    row = conn.execute(
        "SELECT id FROM ssh_groups WHERE LOWER(name) = ?", (label,)
    ).fetchone()
    if row:
        return row[0]
    conn.execute(
        "INSERT INTO ssh_groups (name, label, created_at) VALUES (?, ?, ?)",
        (name, label, NOW),
    )
    return conn.execute("SELECT last_insert_rowid()").fetchone()[0]


def ensure_labels(conn: sqlite3.Connection, tag_str: str):
    """Insert each comma-separated tag into ssh_labels (ignore duplicates)."""
    for tag in [t.strip() for t in tag_str.split(",") if t.strip()]:
        conn.execute(
            "INSERT OR IGNORE INTO ssh_labels (name) VALUES (?)", (tag,)
        )


def host_exists(conn: sqlite3.Connection, alias: str) -> bool:
    return conn.execute(
        "SELECT 1 FROM ssh_hosts WHERE alias = ?", (alias,)
    ).fetchone() is not None


def insert_host(
    conn: sqlite3.Connection,
    group_id: int,
    alias: str,
    host: str,
    port: int,
    user: str,
    pass_: str,
    notes: str,
    label: str,
):
    conn.execute(
        """
        INSERT INTO ssh_hosts
            (group_id, alias, host, port, user, pass, notes, label, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            group_id,
            alias,
            host,
            port,
            user,
            pass_,
            notes if notes else None,
            label,
            NOW,
            NOW,
        ),
    )


# ---------------------------------------------------------------------------
# Main import
# ---------------------------------------------------------------------------

def import_csv(csv_path: str, db_path: str):
    if not os.path.isfile(csv_path):
        sys.exit(f"CSV not found: {csv_path}")

    print(f"DB  : {db_path}")
    print(f"CSV : {csv_path}")
    print()

    conn = sqlite3.connect(db_path)
    conn.execute("PRAGMA foreign_keys = ON")

    added = skipped = errors = 0

    with open(csv_path, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)

        # Normalise header names to lowercase
        reader.fieldnames = [h.strip().lower() for h in reader.fieldnames]

        required = {"alias", "ip", "user"}
        missing = required - set(reader.fieldnames)
        if missing:
            sys.exit(f"CSV is missing required columns: {missing}")

        for lineno, row in enumerate(reader, start=2):
            # Normalise keys
            row = {k.strip().lower(): (v or "").strip() for k, v in row.items()}

            alias  = row.get("alias", "")
            tag    = row.get("tag", "")
            group  = row.get("group", "Default")
            ip     = row.get("ip", "")
            port   = int(row.get("port", "") or 22)
            user   = row.get("user", "")
            pass_  = row.get("pass", "")
            notes  = row.get("notes", "")

            if not alias or not ip or not user:
                print(f"  [SKIP] line {lineno}: alias/ip/user required — {row}")
                skipped += 1
                continue

            if host_exists(conn, alias):
                print(f"  [SKIP] line {lineno}: alias '{alias}' already exists")
                skipped += 1
                continue

            try:
                with conn:
                    group_id = get_or_create_group(conn, group or "Default")
                    if tag:
                        ensure_labels(conn, tag)
                    insert_host(conn, group_id, alias, ip, port, user, pass_, notes, tag)
                print(f"  [OK]   line {lineno}: {alias} → {ip}:{port} (group={group or 'Default'}, tag={tag or '—'})")
                added += 1
            except Exception as e:
                print(f"  [ERR]  line {lineno}: {alias} — {e}")
                errors += 1

    conn.close()
    print()
    print(f"Done — {added} added, {skipped} skipped, {errors} errors.")


def main():
    parser = argparse.ArgumentParser(description="Import SSH hosts into Warp SQLite.")
    parser.add_argument("csv", help="Path to the CSV file")
    parser.add_argument("--db", help="Path to warp.sqlite (auto-detected if omitted)")
    args = parser.parse_args()

    db_path = args.db or find_db()
    import_csv(args.csv, db_path)


if __name__ == "__main__":
    main()
