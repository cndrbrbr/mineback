# mineback

Backup and restore infrastructure for Minecraft server farms — worlds, plugins and
configs of every server deployed with
[minecraftHostingServer](https://github.com/cndrbrbr/minecraftHostingServer) (MHS).

> **Status: M1 implemented, not yet deployed to production.** The agent
> (`agent/mineback-agent`), the vault receiver (`vault/mineback-receive`) and
> the CLI (`vault/mineback`) are working code — every command below runs.
> `tests/smoke-test.sh` exercises the full backup→restore cycle end to end
> (single-server, fleet, proxy, selective parts, secrets, drills, GFS
> retention) against a fake Docker shim, with no real containers or network
> involved; run it with `bash tests/smoke-test.sh`. What's still missing
> before a real hosting host: enrolling it (`mineback host add`), installing
> the two `install-*.sh` scripts, and validating a real `docker exec`
> quiesce against a live Spigot container instead of the test double. See
> [ARCHITECTURE.md](ARCHITECTURE.md) (how and why) and
> [FEATURES.md](FEATURES.md) (full feature list with per-item status).

---

## What it does

| You want to… | mineback |
|--------------|----------|
| snapshot **one** Minecraft server — map, plugins, config, whitelist/ops | `mineback-agent snapshot mc3` |
| snapshot a **whole hosting host** — all servers plus `docker-compose.yml`, `.env`, `keys/` | `mineback-agent snapshot --fleet` |
| restore **one** server to an earlier state | `mineback restore server kag-01/mc3` |
| restore only the **map**, keeping later plugin work | `mineback restore server kag-01/mc3 --parts worlds` |
| rebuild a **complete hosting host** on fresh hardware | `mineback restore fleet kag-01 --to kag-03` |
| move a student's server to **another host** | `mineback restore server kag-01/mc3 --to kag-03/mc1` |
| let a **student** roll back their own world | unchanged: `ssh mc-ctrl@host -p 2221 restore latest` |
| hand a world to a **human** | `mineback export kag-01/mc3 --out mc3-final.zip` |

Backups run while the servers keep running: mineback flushes the world through the
server console (`save-off` / `save-all flush` / `save-on`) instead of stopping it.

## Why not just `backup.sh`

MHS ships a `backup.sh` that zips `cfg`, `plugins` and `worlds` per container, plus
an in-container `restore` command that fetches those zips over HTTP. That works and
mineback keeps it working — the student-facing `restore latest` path is unchanged
and byte-compatible. What it does not do:

- **It misses data that lives outside `data/`.** `whitelist.json`, `ops.json`, the
  ban lists and the pinned Spigot version (`.version`) sit in `/server`. Restore
  onto a fresh volume and every whitelisted player is gone.
- **It misses the container's SSH host keys**, so after a host rebuild every
  student's FileZilla and PuTTY profile throws a host-key warning mid-workshop.
- **It backs up nothing above the container** — no `docker-compose.yml`, no `.env`,
  no `keys/`. There is no path from "the host died" back to a running workshop.
- **It writes an inconsistent world.** A live server rewrites region files while the
  zip runs; nothing flushes or pauses saving.
- **It has no retention, no checksums, no catalog, and exits 0 when a server was
  down** — a silent gap you find out about when you need the backup.
- **Restore is all-or-nothing** and destroys the current state with nothing kept
  behind it.

mineback is the same idea taken to the point where you can lose a machine on a
workshop morning and be back in half an hour. See
[ARCHITECTURE.md §2](ARCHITECTURE.md#2-what-we-are-backing-up) for the exact scope.

## How it fits together

```
Hosting host (MHS)                        Vault host (mineback)
┌────────────────────────────┐            ┌──────────────────────────────────┐
│ mc1 … mc5, lobby, bungee   │            │ mineback-receive  (append-only)  │
│          ▲                 │            │ store/   canonical snapshots     │
│          │ docker exec     │  ssh push  │ public/  dated hardlinks ────┐   │
│ mineback-agent ────────────┼───────────▶│ catalog.sqlite               │   │
│ (bash, nightly timer)      │            │ mineback CLI                 │   │
└────────────────────────────┘            │ nginx :8080 ◀────────────────┘   │
        ▲                                 └──────────────────────────────────┘
        └── student: `restore latest` over HTTP ───────────┘
```

- The **agent** (bash, on each hosting host) quiesces a server, zips its parts and
  streams them to the vault over SSH. It can append snapshots and nothing else.
- The **vault** stores plain zips on a plain filesystem — readable with `unzip`,
  with no repository format in the way — plus manifests, a derived catalog, GFS
  retention and the read-only HTTP view the existing in-container `restore` reads.
- **Secrets** (`.env`, `keys/`, SSH host keys) are encrypted with
  [`age`](https://github.com/FiloSottile/age) *before* leaving the hosting host, to a
  public recipient the host cannot decrypt with. Game data stays in the clear so
  student self-service restore keeps working.
- **Restores** are driven by the admin from the vault; backup credentials can never
  trigger one.

Full reasoning, trust model and failure modes: [ARCHITECTURE.md](ARCHITECTURE.md).

## Snapshot contents

```
snapshot 20260919T020314Z  (host kag-01, server mc3)
├── cfg.zip        server.properties, spigot.yml, bukkit.yml, commands.yml
├── plugins.zip    plugin JARs + per-plugin data
├── worlds.zip     world, world_nether, world_the_end
├── state.zip      whitelist / ops / bans / usercache / permissions / .version
├── secrets.age    container SSH host keys                        (encrypted)
└── manifest.json  versions, sizes, sha256, quiesce result, status
```

Excluded on purpose: `spigot-*.jar`, `bundler/`, `logs/`, `crash-reports/` — MHS
rebuilds them on first start.

A **fleet snapshot** adds `hostconf.zip` (compose files, local `spigot/`+`bungee/`
changes, MHS commit, crontab, firewall rules) and `hostconf-secrets.age` (`.env`,
`keys/`), and references the server snapshots of the same run — so one server can
still be restored out of a whole-host backup.

## Quickstart (a real hosting host)

### 1. Vault

```bash
git clone https://github.com/cndrbrbr/mineback.git && cd mineback
sudo install/install-vault.sh           # store, age identity, mc-backup user
sudoedit /etc/mineback/mineback.toml    # retention, [hosts.<id>] entries
```

### 2. Enrol a hosting host

```bash
mineback host add kag-01                # prints the agent key/config skeleton
```

On the hosting host:

```bash
git clone https://github.com/cndrbrbr/mineback.git && cd mineback
sudo install/install-agent.sh           # prints this host's public key to hand the vault admin
sudoedit /etc/mineback/agent.env        # host id, vault address, MHS repo path
mineback-agent selftest                 # docker, zip, age, ssh, clock, disk
mineback-agent snapshot --fleet
```

### 3. Point the containers at the vault (keeps student self-service working)

```yaml
environment:
  MC_NAME: mc3
  BACKUP_URL: "http://vault.example:8080/kag-01"
```

```bash
docker compose up -d --no-deps mc3
```

### 4. Schedule it

`install-agent.sh` already enables a systemd timer (nightly 02:15, ±5min
jitter — `etc/systemd/mineback-agent.timer`). On a host without systemd, run
it with `--cron` instead to install `etc/cron/mineback-agent` under
`/etc/cron.d/` — stagger the minute by hand if more than one host shares a vault.

### 5. Check and rehearse

```bash
mineback ls --host kag-01 --since 7d
mineback vault verify                   # re-hash + zip test
mineback drill kag-01/mc3               # real restore into a throwaway container
```

## Command reference

```
# on a hosting host
mineback-agent snapshot [server…] [--fleet] [--cold] [--reason <text>]
mineback-agent selftest

# on the vault
mineback host add|ls|rm <host-id>
mineback ls [--host H] [--server S] [--since 7d] [--reason R]
mineback show <host>/<server>/<snapshot>
mineback restore server <host>/<server> [--snapshot latest|<id>|<date>]
                                        [--parts cfg,plugins,worlds,state,secrets]
                                        [--to <host>/<server>] [--dry-run] [--yes]
mineback restore fleet  <host> [--snapshot …] [--to <host>] [--servers mc2,mc4]
mineback export <host>/<server> --out <file.zip>
mineback drill  <host>/<server>
mineback vault status|verify|prune|reindex|replicate
mineback metrics
```

## Requirements

**Hosting host** — nothing new: `bash`, `docker` + compose, `ssh`, `zip`, `curl`
(all already in the MHS image/host), plus the `age` binary for encrypting secrets.

**Vault** — Linux, Python 3.11+ (standard library only, no pip install), `zip`/`unzip`,
`age`, `ssh`, Docker (for the HTTP view and restore drills), and disk of roughly
*(size of all worlds) × (retained snapshots, before dedupe)*.

## Related projects

- [minecraftHostingServer](https://github.com/cndrbrbr/minecraftHostingServer) — the hosting stack mineback backs up
- [minecraftDash](https://github.com/cndrbrbr/minecraftDash) — dashboard; consumes mineback's Prometheus metrics
- [javascriptMinecraftWorkshopServer](https://github.com/cndrbrbr/javascriptMinecraftWorkshopServer) — the workshop environment MHS builds on
- [script4kids](https://github.com/cndrbrbr/script4kids) — the plugin students script against

## Documentation

- [ARCHITECTURE.md](ARCHITECTURE.md) — components, data model, flows, security, design decisions
- [FEATURES.md](FEATURES.md) — feature catalogue with milestones and acceptance criteria

## License

Apache License 2.0 — see [LICENSE](LICENSE).
