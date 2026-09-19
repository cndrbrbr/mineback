"""Scrub (V1) and incoming/ garbage collection (L7)."""
from __future__ import annotations

import hashlib
import shutil
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path

from . import store
from .config import Config


@dataclass
class ScrubIssue:
    ref: str
    artifact: str
    problem: str


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def scrub(cfg: Config, host: str | None = None, server: str | None = None) -> list[ScrubIssue]:
    issues: list[ScrubIssue] = []
    hosts = [host] if host else list(store.iter_hosts(cfg))
    for host_id in hosts:
        servers = [server] if server else list(store.iter_servers(cfg, host_id))
        for srv in servers:
            for snap in store.iter_server_snapshots(cfg, host_id, srv):
                ref = f"{host_id}/{srv}/{snap.snapshot_id}"
                try:
                    manifest = snap.manifest()
                except Exception as e:
                    issues.append(ScrubIssue(ref, "manifest.json", f"unreadable: {e}"))
                    continue
                for art, meta in manifest.get("artifacts", {}).items():
                    p = snap.artifact_path(art)
                    if not p.is_file():
                        issues.append(ScrubIssue(ref, art, "missing"))
                        continue
                    actual = _sha256(p)
                    if actual != meta.get("sha256"):
                        issues.append(ScrubIssue(ref, art, f"checksum mismatch (expected {meta.get('sha256')}, got {actual})"))
                        continue
                    if art.endswith(".zip"):
                        r = subprocess.run(["unzip", "-t", str(p)], capture_output=True)
                        if r.returncode != 0:
                            issues.append(ScrubIssue(ref, art, "unzip -t failed (corrupt archive)"))
    return issues


def gc_incoming(cfg: Config, min_age_hours: int = 6) -> tuple[int, int]:
    """Removes stale in-flight upload directories under incoming/. Returns
    (directories_removed, bytes_reclaimed). Only touches things older than
    min_age_hours so an upload currently in progress is never disturbed."""
    if not cfg.incoming.is_dir():
        return (0, 0)
    cutoff = time.time() - min_age_hours * 3600
    removed = 0
    reclaimed = 0
    for snap_dir in cfg.incoming.glob("*/*/*/*"):
        if not snap_dir.is_dir():
            continue
        try:
            mtimes = [p.stat().st_mtime for p in snap_dir.rglob("*") if p.is_file()]
        except OSError:
            continue
        newest = max(mtimes, default=snap_dir.stat().st_mtime)
        if newest > cutoff:
            continue
        size = sum(p.stat().st_size for p in snap_dir.rglob("*") if p.is_file())
        shutil.rmtree(snap_dir, ignore_errors=True)
        removed += 1
        reclaimed += size
    return (removed, reclaimed)
