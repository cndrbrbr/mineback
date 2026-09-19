"""catalog.sqlite — a derived index over store/. Never the source of truth:
`reindex()` rebuilds it from manifest.json files alone (V4), so losing or
corrupting this file costs a rescan, never data.
"""
from __future__ import annotations

import json
import sqlite3
from pathlib import Path

from . import store
from .config import Config

SCHEMA = """
CREATE TABLE IF NOT EXISTS snapshots (
    host_id      TEXT NOT NULL,
    server       TEXT NOT NULL,        -- '-' for a fleet snapshot
    kind         TEXT NOT NULL,        -- 'spigot' | 'proxy' | 'fleet'
    snapshot_id  TEXT NOT NULL,
    reason       TEXT,
    status       TEXT,
    finished_at  TEXT,
    bytes_total  INTEGER,
    manifest     TEXT NOT NULL,        -- raw JSON, re-parsed by `show`
    PRIMARY KEY (host_id, server, snapshot_id)
);
CREATE INDEX IF NOT EXISTS idx_snapshots_host_server ON snapshots(host_id, server);
CREATE INDEX IF NOT EXISTS idx_snapshots_finished ON snapshots(finished_at);
"""


def connect(cfg: Config) -> sqlite3.Connection:
    cfg.home.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(cfg.catalog_path)
    conn.executescript(SCHEMA)
    return conn


def _bytes_total(manifest: dict) -> int:
    return sum(a.get("bytes", 0) for a in manifest.get("artifacts", {}).values())


def upsert_snapshot(conn: sqlite3.Connection, snap: "store.Snapshot") -> None:
    manifest = snap.manifest()
    conn.execute(
        "INSERT OR REPLACE INTO snapshots "
        "(host_id, server, kind, snapshot_id, reason, status, finished_at, bytes_total, manifest) "
        "VALUES (?,?,?,?,?,?,?,?,?)",
        (
            snap.host_id,
            snap.server,
            manifest.get("kind", "fleet" if snap.kind == "fleet" else "spigot"),
            snap.snapshot_id,
            manifest.get("reason"),
            manifest.get("status", "complete"),
            manifest.get("finished_at"),
            _bytes_total(manifest),
            json.dumps(manifest),
        ),
    )


def reindex(cfg: Config, host_filter: str | None = None) -> int:
    """Rebuild the catalog from every committed manifest.json under store/.
    Returns the number of snapshots indexed. Safe to run at any time."""
    conn = connect(cfg)
    count = 0
    hosts = [host_filter] if host_filter else list(store.iter_hosts(cfg))
    conn.execute("DELETE FROM snapshots WHERE host_id = ?" if host_filter else "DELETE FROM snapshots",
                 (host_filter,) if host_filter else ())
    for host_id in hosts:
        for server in store.iter_servers(cfg, host_id):
            for snap in store.iter_server_snapshots(cfg, host_id, server):
                try:
                    upsert_snapshot(conn, snap)
                    count += 1
                except (OSError, json.JSONDecodeError) as e:
                    print(f"WARN: skipping unreadable manifest {snap.manifest_path}: {e}")
        for snap in store.iter_fleet_snapshots(cfg, host_id):
            try:
                upsert_snapshot(conn, snap)
                count += 1
            except (OSError, json.JSONDecodeError) as e:
                print(f"WARN: skipping unreadable manifest {snap.manifest_path}: {e}")
    conn.commit()
    conn.close()
    return count


def query(
    cfg: Config,
    host: str | None = None,
    server: str | None = None,
    reason: str | None = None,
    since_iso: str | None = None,
) -> list[sqlite3.Row]:
    conn = connect(cfg)
    conn.row_factory = sqlite3.Row
    clauses, params = [], []
    if host:
        clauses.append("host_id = ?"); params.append(host)
    if server:
        clauses.append("server = ?"); params.append(server)
    if reason:
        clauses.append("reason = ?"); params.append(reason)
    if since_iso:
        clauses.append("finished_at >= ?"); params.append(since_iso)
    where = f"WHERE {' AND '.join(clauses)}" if clauses else ""
    rows = conn.execute(
        f"SELECT * FROM snapshots {where} ORDER BY finished_at DESC", params
    ).fetchall()
    conn.close()
    return rows
