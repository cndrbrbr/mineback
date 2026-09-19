"""Compat view — public/<host>/<server>/{cfg,plugins,worlds,state}-<date>.zip
plus latest.txt, built entirely of hardlinks onto store/ (T8).

This is what lets MHS's own, unmodified spigot/mc-restore.sh keep working:
point BACKUP_URL at "http://vault/<host-id>" and MC_NAME stays "mc3" — nothing
in the container image or the student-facing `restore latest` command changes.

The view is fully regenerable from store/ + the catalog at any time, so a
rebuild always wipes and relinks a server's directory from scratch rather
than patching it incrementally — much simpler, and hardlinks cost nothing to
recreate. secrets.age is never linked here (S4): only cfg/plugins/worlds/state.
"""
from __future__ import annotations

import os
import shutil

from . import store
from .config import Config

COMPAT_PARTS = ("cfg", "plugins", "worlds", "state")


def _date_of(snapshot_id: str) -> str:
    # snapshot_id looks like 20260919T203221Z
    return f"{snapshot_id[0:4]}-{snapshot_id[4:6]}-{snapshot_id[6:8]}"


def publish_server(cfg: Config, host_id: str, server: str) -> int:
    """Rebuild the compat view for one server. Returns dates published."""
    snaps = sorted(store.iter_server_snapshots(cfg, host_id, server), key=lambda s: s.snapshot_id)
    out_dir = cfg.public / host_id / server

    if not snaps:
        if out_dir.is_dir():
            shutil.rmtree(out_dir, ignore_errors=True)
        return 0

    # Newest snapshot per calendar date wins that date's link (ARCHITECTURE.md §6).
    by_date: dict[str, store.Snapshot] = {}
    for s in snaps:
        by_date[_date_of(s.snapshot_id)] = s

    if out_dir.is_dir():
        shutil.rmtree(out_dir, ignore_errors=True)
    out_dir.mkdir(parents=True, exist_ok=True)

    for date, snap in by_date.items():
        manifest = snap.manifest()
        for part in COMPAT_PARTS:
            art = f"{part}.zip"
            if art not in manifest.get("artifacts", {}):
                continue
            src = snap.artifact_path(art)
            dst = out_dir / f"{part}-{date}.zip"
            try:
                os.link(src, dst)
            except FileExistsError:
                dst.unlink()
                os.link(src, dst)

    latest_date = max(by_date)
    (out_dir / "latest.txt").write_text(latest_date + "\n")
    return len(by_date)


def publish_all(cfg: Config) -> int:
    total = 0
    for host_id in store.iter_hosts(cfg):
        for server in store.iter_servers(cfg, host_id):
            total += publish_server(cfg, host_id, server)
    return total
