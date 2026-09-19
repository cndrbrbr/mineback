"""GFS (grandfather-father-son) retention (L1-L6).

The selection logic is pure — it takes plain (snapshot_id, reason) pairs and
returns a keep/prune split — so it's testable without touching a filesystem.
`prune_server` is the thin, effectful wrapper that deletes whole snapshot
directories (L5: never partial) and refreshes the compat view + catalog
afterward (L6).
"""
from __future__ import annotations

import shutil
from dataclasses import dataclass
from datetime import datetime, timezone

from . import catalog, publish, store
from .config import Config, RetentionConfig


def _parse(snapshot_id: str) -> datetime:
    return datetime.strptime(snapshot_id, "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc)


@dataclass
class RetentionDecision:
    keep: set[str]
    prune: set[str]


def select(
    snapshot_ids: list[str],
    reasons: dict[str, str],
    retention: RetentionConfig,
    now: datetime | None = None,
) -> RetentionDecision:
    now = now or datetime.now(timezone.utc)
    all_ids = set(snapshot_ids)

    protected = {sid for sid in all_ids if reasons.get(sid) in retention.keep_reasons}
    pool = sorted(all_ids - protected, reverse=True)  # newest first

    keep = set(protected)

    # keep_last: newest N unconditionally
    keep.update(pool[: retention.keep_last])

    # keep_daily / keep_weekly / keep_monthly: newest snapshot in each of the
    # last N buckets of that size, counting back from `now`.
    def bucket_key(sid: str, kind: str) -> tuple:
        dt = _parse(sid)
        if kind == "day":
            return (dt.year, dt.month, dt.day)
        if kind == "week":
            iso = dt.isocalendar()
            return (iso[0], iso[1])
        if kind == "month":
            return (dt.year, dt.month)
        raise ValueError(kind)

    def bucket_age(sid: str, kind: str) -> int:
        dt = _parse(sid)
        if kind == "day":
            return (now.date() - dt.date()).days
        if kind == "week":
            now_iso, dt_iso = now.isocalendar(), dt.isocalendar()
            return (now_iso[0] * 53 + now_iso[1]) - (dt_iso[0] * 53 + dt_iso[1])
        if kind == "month":
            return (now.year * 12 + now.month) - (dt.year * 12 + dt.month)
        raise ValueError(kind)

    for kind, n in (("day", retention.keep_daily), ("week", retention.keep_weekly), ("month", retention.keep_monthly)):
        if n <= 0:
            continue
        newest_in_bucket: dict[tuple, str] = {}
        for sid in pool:
            if bucket_age(sid, kind) >= n:
                continue
            b = bucket_key(sid, kind)
            if b not in newest_in_bucket or sid > newest_in_bucket[b]:
                newest_in_bucket[b] = sid
        keep.update(newest_in_bucket.values())

    prune = all_ids - keep
    return RetentionDecision(keep=keep, prune=prune)


@dataclass
class PruneReport:
    host_id: str
    server: str
    kept: list[str]
    pruned: list[str]
    bytes_reclaimed: int
    dry_run: bool


def prune_server(cfg: Config, host_id: str, server: str, dry_run: bool = True) -> PruneReport:
    retention = cfg.retention_for(server)
    snaps = list(store.iter_server_snapshots(cfg, host_id, server))
    ids = [s.snapshot_id for s in snaps]
    reasons = {}
    by_id = {s.snapshot_id: s for s in snaps}
    for s in snaps:
        try:
            reasons[s.snapshot_id] = s.manifest().get("reason", "")
        except Exception:
            reasons[s.snapshot_id] = ""

    decision = select(ids, reasons, retention)
    bytes_reclaimed = 0
    pruned = sorted(decision.prune)

    if not dry_run:
        for sid in pruned:
            snap = by_id[sid]
            try:
                bytes_reclaimed += sum(
                    p.stat().st_size for p in snap.dir.rglob("*") if p.is_file()
                )
            except OSError:
                pass
            shutil.rmtree(snap.dir, ignore_errors=True)
        publish.publish_server(cfg, host_id, server)
        catalog.reindex(cfg, host_filter=host_id)

    return PruneReport(
        host_id=host_id,
        server=server,
        kept=sorted(decision.keep),
        pruned=pruned,
        bytes_reclaimed=bytes_reclaimed,
        dry_run=dry_run,
    )


def prune_all(cfg: Config, dry_run: bool = True) -> list[PruneReport]:
    reports = []
    for host_id in store.iter_hosts(cfg):
        for server in store.iter_servers(cfg, host_id):
            reports.append(prune_server(cfg, host_id, server, dry_run=dry_run))
    return reports
