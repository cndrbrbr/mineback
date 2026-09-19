"""Load mineback.toml — the vault's single config file (O2)."""
from __future__ import annotations

import os
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

DEFAULT_CONFIG_PATHS = [
    os.environ.get("MINEBACK_CONFIG", ""),
    "/etc/mineback/mineback.toml",
]


@dataclass
class RetentionConfig:
    keep_last: int = 3
    keep_daily: int = 7
    keep_weekly: int = 4
    keep_monthly: int = 6
    keep_reasons: tuple[str, ...] = ("pre-restore", "pre-version", "workshop-final")


@dataclass
class HostEntry:
    host_id: str
    address: str | None = None   # e.g. "ssh://root@10.0.0.5" — used by `docker -H` for restore
    mhs_dir: str | None = None   # path to the MHS checkout on that host, for fleet restore


@dataclass
class Config:
    home: Path = field(default_factory=lambda: Path(os.environ.get("MINEBACK_HOME", "/var/lib/mineback")))
    age_identity: Path | None = None
    retention: RetentionConfig = field(default_factory=RetentionConfig)
    retention_overrides: dict[str, RetentionConfig] = field(default_factory=dict)
    hosts: dict[str, HostEntry] = field(default_factory=dict)

    @property
    def store(self) -> Path:
        return self.home / "store"

    @property
    def incoming(self) -> Path:
        return self.home / "incoming"

    @property
    def public(self) -> Path:
        return self.home / "public"

    @property
    def catalog_path(self) -> Path:
        return self.home / "catalog.sqlite"

    @property
    def logs(self) -> Path:
        return self.home / "logs"

    def retention_for(self, server: str) -> RetentionConfig:
        return self.retention_overrides.get(server, self.retention)


def load(path: str | None = None) -> Config:
    candidates = [path] if path else DEFAULT_CONFIG_PATHS
    data: dict = {}
    for p in candidates:
        if p and Path(p).is_file():
            with open(p, "rb") as f:
                data = tomllib.load(f)
            break

    cfg = Config()
    if "home" in data:
        cfg.home = Path(data["home"])
    elif "vault" in data and "home" in data["vault"]:
        cfg.home = Path(data["vault"]["home"])

    if "age_identity" in data.get("vault", {}):
        cfg.age_identity = Path(data["vault"]["age_identity"])

    r = data.get("retention", {})
    cfg.retention = RetentionConfig(
        keep_last=r.get("keep_last", 3),
        keep_daily=r.get("keep_daily", 7),
        keep_weekly=r.get("keep_weekly", 4),
        keep_monthly=r.get("keep_monthly", 6),
        keep_reasons=tuple(r.get("keep_reasons", RetentionConfig().keep_reasons)),
    )
    for server, overrides in data.get("retention_overrides", {}).items():
        base = cfg.retention
        cfg.retention_overrides[server] = RetentionConfig(
            keep_last=overrides.get("keep_last", base.keep_last),
            keep_daily=overrides.get("keep_daily", base.keep_daily),
            keep_weekly=overrides.get("keep_weekly", base.keep_weekly),
            keep_monthly=overrides.get("keep_monthly", base.keep_monthly),
            keep_reasons=tuple(overrides.get("keep_reasons", base.keep_reasons)),
        )

    for host_id, h in data.get("hosts", {}).items():
        cfg.hosts[host_id] = HostEntry(
            host_id=host_id,
            address=h.get("address"),
            mhs_dir=h.get("mhs_dir"),
        )

    return cfg
