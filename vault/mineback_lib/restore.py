"""Restore orchestration — single server, and fleet (ARCHITECTURE.md §9).

Talks to the target host's Docker daemon via `docker -H <address>` (Docker's
own built-in SSH remote-context support), so cross-host restore (R6) needs no
hand-rolled scp/ssh plumbing: set `hosts.<id>.address = "ssh://root@1.2.3.4"`
in mineback.toml and every `docker` call below is transparently remote.

Extraction goes through `docker cp` + `unzip` *inside* the container rather
than piping a stream into `unzip` on stdin, because Info-Zip's unzip needs
random access to the central directory at the end of the archive — the same
reason MHS's own mc-restore.sh downloads to a real file before unzipping it.
"""
from __future__ import annotations

import hashlib
import os
import subprocess
import tempfile
import time
import zipfile
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

from . import store
from .config import Config

RESTORABLE_PARTS = ("cfg", "plugins", "worlds", "state", "secrets")
DEFAULT_PARTS = ("cfg", "plugins", "worlds", "state")


class RestoreError(Exception):
    pass


class NeedsConfirmation(Exception):
    """Raised instead of acting when yes=False and this isn't a dry run.
    The CLI catches this, shows plan_lines, and prompts interactively —
    kept out of this module so restore logic stays testable without stdin.
    """

    def __init__(self, plan_lines: list[str]):
        super().__init__("confirmation required")
        self.plan_lines = plan_lines


def _docker_env(cfg: Config, host_id: str) -> dict:
    env = dict(os.environ)
    h = cfg.hosts.get(host_id)
    if h and h.address:
        env["DOCKER_HOST"] = h.address
    else:
        env.pop("DOCKER_HOST", None)
    return env


def _run(cmd: list[str], env: dict | None = None, input_bytes: bytes | None = None, check: bool = True):
    r = subprocess.run(cmd, env=env, input=input_bytes, capture_output=True)
    if check and r.returncode != 0:
        raise RestoreError(f"command failed ({r.returncode}): {' '.join(cmd)}\n{r.stderr.decode(errors='replace')}")
    return r


def container_running(env: dict, name: str) -> bool:
    r = _run(["docker", "inspect", "-f", "{{.State.Running}}", name], env=env, check=False)
    return r.stdout.decode().strip() == "true"


def verify_checksums(snap: store.Snapshot) -> list[str]:
    issues = []
    manifest = snap.manifest()
    for art, meta in manifest.get("artifacts", {}).items():
        p = snap.artifact_path(art)
        if not p.is_file():
            issues.append(f"missing artifact: {art}")
            continue
        h = hashlib.sha256()
        with open(p, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        if h.hexdigest() != meta.get("sha256"):
            issues.append(f"checksum mismatch: {art}")
    return issues


@dataclass
class RestorePlan:
    source_ref: str
    target_host: str
    target_server: str
    parts: list[str]
    snapshot: store.Snapshot


def build_plan(cfg: Config, host_id: str, server: str, selector: str, parts: list[str], to: str | None) -> RestorePlan:
    snap = store.resolve_selector(cfg, host_id, server, selector)
    if to:
        if "/" not in to:
            raise RestoreError(f"--to expects 'host/server', got {to!r}")
        thost, tserver = to.split("/", 1)
    else:
        thost, tserver = host_id, server
    return RestorePlan(f"{host_id}/{server}/{snap.snapshot_id}", thost, tserver, list(parts), snap)


def describe_plan(plan: RestorePlan) -> list[str]:
    return [
        f"restore {plan.source_ref}  ->  {plan.target_host}/{plan.target_server}",
        f"  parts:  {', '.join(plan.parts)}",
        "  this will STOP the target container, replace the listed data, then resume it.",
    ]


def take_safety_snapshot(cfg: Config, target_host: str, target_server: str) -> str:
    h = cfg.hosts.get(target_host)
    cmd = ["mineback-agent", "snapshot", target_server, "--reason", "pre-restore"]
    try:
        if h and h.address:
            sshtarget = h.address.replace("ssh://", "", 1)
            _run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", sshtarget, "--"] + cmd)
        else:
            _run(cmd)
        return "ok"
    except RestoreError as e:
        return f"FAILED: {e}"


def _quiesce_stop(env: dict, container: str, timeout: int = 30) -> None:
    _run(["docker", "exec", container, "bash", "-c", "touch /server/.stopped"], env=env)
    # Pattern goes through an env var, not the `bash -c` string itself: `-f`
    # matches every process's full command line, including this wrapping
    # shell's own — which would otherwise contain the pattern text verbatim
    # and get killed along with (or instead of) the actual java process. See
    # the matching comment in agent/mineback-agent's quiesce_start().
    _run(["docker", "exec", "-e", "MB_PAT=spigot-.*\\.jar", container, "bash", "-c",
          'pkill -TERM -f "$MB_PAT" 2>/dev/null || true'], env=env)
    waited = 0
    while waited < timeout:
        r = _run(["docker", "exec", "-e", "MB_PAT=spigot-.*\\.jar", container, "bash", "-c",
                   'pgrep -f "$MB_PAT" >/dev/null 2>&1'], env=env, check=False)
        if r.returncode != 0:
            break
        time.sleep(1)
        waited += 1


def _resume(env: dict, container: str) -> None:
    # Removing .stopped is enough — entrypoint.sh's own loop, already running
    # inside the container, notices and relaunches java. No separate "start".
    _run(["docker", "exec", container, "bash", "-c", "rm -f /server/.stopped"], env=env, check=False)


def _wait_started(env: dict, container: str, timeout: int = 180) -> bool:
    since = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    script = f"timeout {timeout} docker logs --since {since} -f {container} 2>&1 | grep -qm1 'Done ('"
    r = subprocess.run(["bash", "-c", script], env=env)
    return r.returncode == 0


def _extract_part(
    env: dict, container: str, part: str, artifact_path: Path, age_identity: Path | None, kind: str = "spigot"
) -> None:
    if part == "secrets":
        if kind != "spigot":
            raise RestoreError(f"part 'secrets' is not applicable to a {kind!r} snapshot")
        if not age_identity:
            raise RestoreError("secrets.age present in --parts but no age identity configured")
        r = _run(["age", "-d", "-i", str(age_identity), str(artifact_path)])
        with tempfile.NamedTemporaryFile(suffix=".zip") as tf:
            tf.write(r.stdout)
            tf.flush()
            _run(["docker", "cp", tf.name, f"{container}:/tmp/restore-secrets.zip"], env=env)
        script = (
            "cd /server && unzip -qo /tmp/restore-secrets.zip && rm -f /tmp/restore-secrets.zip && "
            "chown root:root ssh_host_ed25519_key ssh_host_ed25519_key.pub "
            "ssh_host_rsa_key ssh_host_rsa_key.pub && "
            "chmod 600 ssh_host_ed25519_key ssh_host_rsa_key"
        )
        _run(["docker", "exec", container, "bash", "-c", script], env=env)
        return

    remote_tmp = f"/tmp/restore-{part}.zip"
    _run(["docker", "cp", str(artifact_path), f"{container}:{remote_tmp}"], env=env)

    if kind == "proxy":
        # BungeeCord's volume has no data/ split (docker-compose.yml mounts
        # bungee_data straight at /bungee) — cfg.zip/plugins.zip were packed
        # as flat archives already containing their own top-level names
        # (config.yml, plugins/, modules/), so they extract directly into
        # /bungee, not into a per-part subdirectory the way spigot's do.
        if part == "cfg":
            script = f"cd /bungee && unzip -qo {remote_tmp} && rm -f {remote_tmp}"
        elif part == "plugins":
            script = f"rm -rf /bungee/plugins /bungee/modules && cd /bungee && unzip -qo {remote_tmp} && rm -f {remote_tmp}"
        else:
            raise RestoreError(f"part {part!r} is not applicable to a proxy snapshot")
    elif part == "state":
        script = f"cd /server && unzip -qo {remote_tmp} && rm -f {remote_tmp}"
    else:
        script = (
            f"rm -rf /server/data/{part} && mkdir -p /server/data && "
            f"unzip -qo {remote_tmp} -d /server/data && rm -f {remote_tmp}"
        )
    _run(["docker", "exec", container, "bash", "-c", script], env=env)


def _log_restore(cfg: Config, plan: RestorePlan, safety: str | None, started: bool) -> None:
    cfg.logs.mkdir(parents=True, exist_ok=True)
    line = (
        f"{datetime.now(timezone.utc).isoformat()}\t"
        f"restore {plan.source_ref} -> {plan.target_host}/{plan.target_server}\t"
        f"parts={','.join(plan.parts)}\tsafety={safety}\tstarted={started}\n"
    )
    with open(cfg.logs / "restore.log", "a") as f:
        f.write(line)


@dataclass
class RestoreReport:
    plan: RestorePlan
    safety_snapshot: str | None
    started: bool


def restore_server(
    cfg: Config,
    host_id: str,
    server: str,
    selector: str = "latest",
    parts: list[str] | None = None,
    to: str | None = None,
    dry_run: bool = False,
    yes: bool = False,
    no_safety: bool = False,
    age_identity: Path | None = None,
) -> RestoreReport:
    parts = list(parts) if parts else list(DEFAULT_PARTS)
    for p in parts:
        if p not in RESTORABLE_PARTS:
            raise RestoreError(f"unknown part: {p!r} (expected one of {RESTORABLE_PARTS})")

    plan = build_plan(cfg, host_id, server, selector, parts, to)

    issues = verify_checksums(plan.snapshot)
    if issues:
        raise RestoreError(f"snapshot {plan.source_ref} failed integrity check: " + "; ".join(issues))

    if dry_run:
        return RestoreReport(plan, None, False)

    if not yes:
        raise NeedsConfirmation(describe_plan(plan))

    env = _docker_env(cfg, plan.target_host)
    container = plan.target_server
    if not container_running(env, container):
        raise RestoreError(f"target container '{container}' is not running on host '{plan.target_host}'")

    manifest = plan.snapshot.manifest()
    kind = manifest.get("kind", "spigot")
    if kind not in ("spigot", "proxy"):
        raise RestoreError(f"unsupported snapshot kind: {kind!r}")

    safety = None if no_safety else take_safety_snapshot(cfg, plan.target_host, plan.target_server)

    if kind == "spigot":
        _quiesce_stop(env, container)
        try:
            for part in parts:
                art = "secrets.age" if part == "secrets" else f"{part}.zip"
                if art not in manifest.get("artifacts", {}):
                    continue
                _extract_part(env, container, part, plan.snapshot.artifact_path(art), age_identity, kind)
            if any(p in parts for p in ("cfg", "plugins", "worlds", "state")):
                _run(["docker", "exec", container, "bash", "-c",
                      "chown -R mc-sftp:mc-sftp /server/data"], env=env, check=False)
        finally:
            _resume(env, container)
        started = _wait_started(env, container)
    else:
        # BungeeCord has no .stopped/pkill quiesce convention (that's a
        # spigot-image thing) and no volume data/ split — extract live, then
        # restart the container so it picks up the new config/plugins.
        for part in parts:
            art = f"{part}.zip"
            if art not in manifest.get("artifacts", {}):
                continue
            _extract_part(env, container, part, plan.snapshot.artifact_path(art), age_identity, kind)
        _run(["docker", "restart", container], env=env)
        time.sleep(2)
        started = container_running(env, container)

    _log_restore(cfg, plan, safety, started)
    return RestoreReport(plan, safety, started)


# ── fleet restore ──────────────────────────────────────────────────────
@dataclass
class FleetRestoreResult:
    server: str
    status: str
    report: RestoreReport | None = None


def resolve_fleet_selector(cfg: Config, host_id: str, selector: str) -> store.Snapshot:
    fleets = sorted(store.iter_fleet_snapshots(cfg, host_id), key=lambda s: s.snapshot_id)
    if not fleets:
        raise RestoreError(f"no fleet snapshots for host {host_id}")
    if selector == "latest":
        return fleets[-1]
    for s in fleets:
        if s.snapshot_id == selector:
            return s
    raise RestoreError(f"no such fleet snapshot: {host_id}/{selector}")


def restore_fleet(
    cfg: Config,
    host_id: str,
    selector: str = "latest",
    to: str | None = None,
    servers: list[str] | None = None,
    dry_run: bool = False,
    yes: bool = False,
    with_secrets: bool = True,
    age_identity: Path | None = None,
) -> list[FleetRestoreResult]:
    """Restores every server referenced by a fleet snapshot (R7/R14).

    Host-level config (docker-compose.yml, .env, keys/) is NOT applied by
    this function — see ARCHITECTURE.md §9.3 steps 1-3. This restores what a
    host that is already checked out and running MHS needs to come back:
    every server's worlds/plugins/cfg/state/(secrets), which is also exactly
    what R2/R3/R5/R9 already validate per-server.
    """
    fleet_snap = resolve_fleet_selector(cfg, host_id, selector)
    manifest = fleet_snap.manifest()
    target_host = to or host_id

    server_map = manifest.get("servers", {})
    server_list = servers or [s for s, v in server_map.items() if isinstance(v, str)]

    parts = list(DEFAULT_PARTS) + (["secrets"] if with_secrets else [])
    results: list[FleetRestoreResult] = []
    for server in server_list:
        server_snap_id = server_map.get(server)
        if not isinstance(server_snap_id, str):
            results.append(FleetRestoreResult(server, "skipped (not present in fleet snapshot)"))
            continue
        try:
            report = restore_server(
                cfg, host_id, server, server_snap_id, parts,
                to=f"{target_host}/{server}", dry_run=dry_run, yes=yes,
                no_safety=False, age_identity=age_identity,
            )
            results.append(FleetRestoreResult(server, "ok", report))
        except NeedsConfirmation:
            raise
        except RestoreError as e:
            results.append(FleetRestoreResult(server, f"FAILED: {e}"))
    return results


# ── export (R12) ────────────────────────────────────────────────────────
def export_snapshot(cfg: Config, host_id: str, server: str, selector: str, out_path: Path) -> None:
    snap = store.resolve_selector(cfg, host_id, server, selector)
    manifest = snap.manifest()
    with zipfile.ZipFile(out_path, "w", zipfile.ZIP_DEFLATED) as z:
        for part in ("cfg", "plugins", "worlds"):
            art = f"{part}.zip"
            if art in manifest.get("artifacts", {}):
                z.write(snap.artifact_path(art), arcname=art)
        z.writestr(
            "README.txt",
            f"Exported from {host_id}/{server}/{snap.snapshot_id}\n"
            f"Spigot version: {manifest.get('source', {}).get('spigot_version', '?')}\n"
            f"Level name: {manifest.get('source', {}).get('level_name', '?')}\n"
            "Contains cfg.zip, plugins.zip, worlds.zip — unzip each to inspect.\n",
        )
