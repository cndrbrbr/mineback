"""Filesystem layout, name validation and manifest I/O for the vault store.

The filesystem under store/ is the source of truth (ARCHITECTURE.md §5-6);
everything here just walks it safely. Shared regexes mirror (independently —
this is Python, the agent/receiver are bash) the ones enforced by
vault/mineback-receive, so the CLI refuses the same malformed identifiers.
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator

from .config import Config

ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
SNAPSHOT_RE = re.compile(r"^\d{8}T\d{6}Z$")


def valid_id(s: str) -> bool:
    return bool(ID_RE.match(s))


def valid_snapshot_id(s: str) -> bool:
    return bool(SNAPSHOT_RE.match(s))


class NotFound(Exception):
    pass


class Invalid(Exception):
    pass


@dataclass
class Snapshot:
    host_id: str
    server: str
    snapshot_id: str
    kind: str  # "server" | "fleet"
    dir: Path

    @property
    def manifest_path(self) -> Path:
        return self.dir / "manifest.json"

    @property
    def complete(self) -> bool:
        return (self.dir / ".complete").is_file()

    def manifest(self) -> dict:
        with open(self.manifest_path, "rb") as f:
            return json.load(f)

    def artifact_path(self, name: str) -> Path:
        return self.dir / name


def _require_id(name: str, value: str) -> None:
    if not valid_id(value):
        raise Invalid(f"invalid {name}: {value!r}")


def server_snapshot_dir(cfg: Config, host_id: str, server: str, snapshot_id: str) -> Path:
    _require_id("host_id", host_id)
    _require_id("server", server)
    if not valid_snapshot_id(snapshot_id):
        raise Invalid(f"invalid snapshot id: {snapshot_id!r}")
    return cfg.store / host_id / "servers" / server / snapshot_id


def fleet_snapshot_dir(cfg: Config, host_id: str, snapshot_id: str) -> Path:
    _require_id("host_id", host_id)
    if not valid_snapshot_id(snapshot_id):
        raise Invalid(f"invalid snapshot id: {snapshot_id!r}")
    return cfg.store / host_id / "fleets" / snapshot_id


def iter_hosts(cfg: Config) -> Iterator[str]:
    if not cfg.store.is_dir():
        return
    for p in sorted(cfg.store.iterdir()):
        if p.is_dir():
            yield p.name


def iter_servers(cfg: Config, host_id: str) -> Iterator[str]:
    d = cfg.store / host_id / "servers"
    if not d.is_dir():
        return
    for p in sorted(d.iterdir()):
        if p.is_dir():
            yield p.name


def iter_server_snapshots(cfg: Config, host_id: str, server: str) -> Iterator[Snapshot]:
    d = cfg.store / host_id / "servers" / server
    if not d.is_dir():
        return
    for p in sorted(d.iterdir()):
        if p.is_dir() and (p / ".complete").is_file():
            yield Snapshot(host_id, server, p.name, "server", p)


def iter_fleet_snapshots(cfg: Config, host_id: str) -> Iterator[Snapshot]:
    d = cfg.store / host_id / "fleets"
    if not d.is_dir():
        return
    for p in sorted(d.iterdir()):
        if p.is_dir() and (p / ".complete").is_file():
            yield Snapshot(host_id, "-", p.name, "fleet", p)


def iter_all_server_snapshots(cfg: Config) -> Iterator[Snapshot]:
    for host_id in iter_hosts(cfg):
        for server in iter_servers(cfg, host_id):
            yield from iter_server_snapshots(cfg, host_id, server)


def parse_ref(ref: str) -> tuple[str, str, str | None]:
    """Parse 'host/server[/snapshot]' -> (host, server, snapshot_or_None)."""
    parts = ref.split("/")
    if len(parts) == 2:
        return parts[0], parts[1], None
    if len(parts) == 3:
        return parts[0], parts[1], parts[2]
    raise Invalid(f"expected 'host/server' or 'host/server/snapshot', got {ref!r}")


def resolve_selector(cfg: Config, host_id: str, server: str, selector: str) -> Snapshot:
    """selector: 'latest' | an exact snapshot id | a YYYY-MM-DD date."""
    snaps = list(iter_server_snapshots(cfg, host_id, server))
    if not snaps:
        raise NotFound(f"no snapshots for {host_id}/{server}")

    if selector == "latest":
        return max(snaps, key=lambda s: s.snapshot_id)

    if valid_snapshot_id(selector):
        for s in snaps:
            if s.snapshot_id == selector:
                return s
        raise NotFound(f"no such snapshot: {host_id}/{server}/{selector}")

    if re.match(r"^\d{4}-\d{2}-\d{2}$", selector):
        day = selector.replace("-", "")
        candidates = [s for s in snaps if s.snapshot_id.startswith(day)]
        if not candidates:
            raise NotFound(f"no snapshot for {host_id}/{server} on {selector}")
        if len(candidates) > 1:
            ids = ", ".join(c.snapshot_id for c in candidates)
            raise Invalid(f"ambiguous date {selector} for {host_id}/{server} — candidates: {ids}")
        return candidates[0]

    raise Invalid(f"unrecognised snapshot selector: {selector!r} (use 'latest', a snapshot id, or YYYY-MM-DD)")
