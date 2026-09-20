# mineback — Features

Feature catalogue for the Minecraft farm backup infrastructure. Each feature has
an id, a milestone and an acceptance criterion, so this file doubles as the
implementation checklist.

- **Milestones:** `M1` first usable version · `M2` operational hardening · `M3` scale and comfort
- **Status:** `implemented` — working code, covered by `tests/smoke-test.sh` (a fake-Docker end-to-end run, no real containers/network). `partial` — the code path is real but a piece of it is unexercised or manual (noted in the row). `planned` — not built yet.

Design rationale for all of this lives in [ARCHITECTURE.md](ARCHITECTURE.md).

---

## 1. Backup scope

| id | Feature | Milestone | Status | Accepted when |
|----|---------|-----------|--------|---------------|
| B1 | **Single-server snapshot** — worlds, plugins, config as separate zips | M1 | implemented | `mineback-agent snapshot mc3` produces `cfg.zip`, `plugins.zip`, `worlds.zip` + manifest in the vault |
| B2 | **Player state capture** — `whitelist.json`, `ops.json`, banned lists, `usercache.json`, `permissions.yml`, `help.yml`, pinned `.version` | M1 | implemented | restoring onto an empty volume preserves the whitelist, ops and Spigot version |
| B3 | **Container identity capture** — SSH host keys, encrypted | M1 | implemented | after a full host restore, an unchanged FileZilla/PuTTY profile connects without a host-key warning |
| B4 | **Multi-world support** — every `data/worlds/*` dir, not just `level-name` | M1 | implemented | nether and end worlds appear in `worlds.zip` and in the manifest's `worlds` list |
| B5 | **Fleet snapshot** — all servers on a host in one run | M1 | implemented | `mineback-agent snapshot --fleet` snapshots lobby + mc1–mc5 + bungee and writes one fleet manifest |
| B6 | **Host config capture** — compose files, local `spigot/`+`bungee/` changes, MHS commit, crontab, `DOCKER-USER` rules | M1 | implemented | `hostconf.zip` rebuilds the stack definition without consulting the old machine |
| B7 | **Host secrets capture** — `.env`, `keys/` — age-encrypted | M1 | implemented | `hostconf-secrets.age` is unreadable on the vault without the age identity |
| B8 | **BungeeCord proxy backup** — `bungee_data` as kind `proxy` | M1 | implemented | proxy `config.yml` and plugins restore into a fresh `bungee` container |
| B9 | **Explicit exclusions** — Spigot JARs, `bundler/`, `logs/`, `crash-reports/`, control flags | M1 | implemented | a 20 GB volume with a cached JAR produces a snapshot without it, and the server still starts after restore |
| B10 | **Ad-hoc snapshot with a reason** — `--reason pre-version` / `workshop-final` | M1 | implemented | reason lands in the manifest and protects the snapshot from pruning |
| B11 | **`enable-rcon` untouched** — console via `/proc/1/fd/0` as `announce.sh` does | M1 | implemented | no new listening port appears on any container |
| B12 | **Standalone-mode support** — hosts without BungeeCord | M2 | implemented | a `docker-compose.standalone.yml` host (`MINEBACK_LOBBY=none MINEBACK_PROXY=none`) snapshots `complete` (not perpetually `partial`) and `mineback restore fleet` restores it identically — `restore_fleet` already iterates whatever the fleet manifest's `servers` map actually contains, with no hardcoded assumption of a proxy |
| B13 | **Kind-aware packing** — `spigot` and `proxy` layouts, extensible for Paper/Velocity | M3 | planned | adding a kind needs a pack/restore descriptor, no change to transport or store |

## 2. Consistency

| id | Feature | Milestone | Status | Accepted when |
|----|---------|-----------|--------|---------------|
| C1 | **Hot quiesce** — `save-off` → `save-all flush` → wait → zip → `save-on` | M1 | implemented | players stay connected through a snapshot and the restored world has no torn region files |
| C2 | **Flush confirmation** — tail the log for the save confirmation, with timeout | M1 | implemented | confirmed runs set `save_flush_confirmed: true`; a timeout warns and records `false` |
| C3 | **`save-on` guaranteed** — shell trap on error/signal | M1 | implemented | killing the agent mid-zip still leaves the server with saving enabled |
| C4 | **Cold snapshot** — `--cold` stops the server for a byte-exact copy | M2 | planned | server is stopped, packed and restarted; manifest records `method: cold` |
| C5 | **Player warning** — optional `say [BACKUP] …` before and after | M2 | planned | configurable per host, off by default for the nightly run |
| C6 | **Serialized, staggered execution** | M1 | implemented | a 6-server fleet run never has two zip processes in flight |

## 3. Transport and storage

| id | Feature | Milestone | Status | Accepted when |
|----|---------|-----------|--------|---------------|
| T1 | **SSH push with forced command** — one restricted key per host | M1 | implemented | the agent key can only invoke `mineback-receive`; an interactive SSH attempt is refused |
| T2 | **Append-only receive** — no overwrite, no delete verb | M1 | implemented | a crafted request to overwrite or delete an existing artifact is rejected and logged |
| T3 | **Streaming upload** — `zip -r -` piped into ssh, no host-side temp file, with zip-to-temp fallback | M1 | implemented | snapshotting a world larger than the host's free space succeeds |
| T4 | **Spool fallback** — `MINEBACK_SPOOL_DIR` for unreliable links | M2 | implemented | with spooling on, a dropped connection retries from the spool without re-zipping |
| T5 | **Checksums on both ends** | M1 | implemented | a corrupted stream is detected and the snapshot is not committed |
| T6 | **Atomic commit** — `incoming/` → `store/`, `.complete` last | M1 | implemented | a killed upload leaves no snapshot visible to `mineback ls` |
| T7 | **Hardlink dedupe** of identical artifacts per server | M2 | planned | 7 nightly snapshots of an unchanged plugin set store `plugins.zip` once |
| T8 | **Compat view** — dated hardlinks + `latest.txt`, host-prefixed | M1 | implemented | unmodified `mc-restore.sh` restores from the vault with only `BACKUP_URL` changed |
| T9 | **Offsite replication** — `rclone`/`restic` of `store/` to S3/B2/another vault | M2 | planned | one command replicates, and a partial sync never yields an invalid snapshot |
| T10 | **Pull mode** — `--via ssh` for hosts that cannot run a timer | M2 | planned | a host with no agent installed can be snapshotted from the vault with the admin key |
| T11 | **Vault-side rate/size guards** — per-host quota, reject on low disk | M2 | planned | receive fails cleanly before filling the store, and alerts |

## 4. Restore

| id | Feature | Milestone | Status | Accepted when |
|----|---------|-----------|--------|---------------|
| R1 | **Student self-service preserved** — `restore latest` / `restore <date>` | M1 | implemented | works against the vault with no change to the MHS image |
| R2 | **Single-server restore in place** | M1 | implemented | `mineback restore server h/mc3` brings mc3 back on the snapshot's data and logs `Done` |
| R3 | **Selective parts** — `--parts worlds,plugins,cfg,state,secrets` | M1 | implemented | `--parts worlds` reverts the map and leaves plugin changes intact |
| R4 | **Snapshot selection** — `latest`, snapshot id, a date, `--before <ts>` | M1 | implemented | all four forms resolve, and an ambiguous date lists candidates instead of guessing |
| R5 | **Safety snapshot before restore** — skippable with `--no-safety` | M1 | implemented | a wrong restore is undone by restoring the auto-created `pre-restore` snapshot |
| R6 | **Cross-slot / cross-host restore** — `--to h2/mc1` | M2 | partial | an `mc3` snapshot comes up as `mc1` on another host with correct `level-name` and paths |
| R7 | **Full host restore** — `mineback restore fleet` | M1 | partial | a bare host plus vault plus MHS git yields a working stack with all worlds, whitelists and fingerprints |
| R8 | **Restore into a fresh stack** — provision compose, decrypt secrets, scaffold volumes, then fill | M1 | partial | performed on a machine that has never run MHS |
| R9 | **Post-restore health gate** — wait for `Done (…)!`, verify expected worlds | M1 | implemented | a server that fails to start makes the restore command exit non-zero with the log tail |
| R10 | **Dry-run restore** — `--dry-run` prints the plan and target paths | M1 | implemented | no container is touched and the plan lists every file action |
| R11 | **Destructive-action confirmation** — prompt naming target + snapshot, `--yes` for automation | M1 | implemented | an unattended run without `--yes` refuses rather than wipes |
| R12 | **Export bundle** — one zip for a human, never secrets | M2 | implemented | `mineback export h/mc3 --out x.zip` opens in any zip tool and contains no key material |
| R13 | **Restore log** — who restored what, where, from which snapshot | M2 | implemented | every restore appends an auditable line on the vault |
| R14 | **Partial-fleet restore** — pick a subset of servers from a fleet snapshot | M3 | implemented | `--servers mc2,mc4` restores only those two |

## 5. Retention and lifecycle

| id | Feature | Milestone | Status | Accepted when |
|----|---------|-----------|--------|---------------|
| L1 | **GFS retention** — `keep_last/daily/weekly/monthly` | M1 | implemented | pruning a year of synthetic snapshots leaves exactly the expected set |
| L2 | **Per-server overrides** | M2 | implemented | one server can keep 30 dailies while the rest keep 7 |
| L3 | **Protected reasons** — `pre-restore`, `pre-version`, `workshop-final` never pruned | M1 | implemented | a protected snapshot survives a prune that removes its neighbours |
| L4 | **Dry-run pruning by default** | M1 | implemented | `mineback vault prune` without `--yes` only reports |
| L5 | **Whole-snapshot deletion** — never partial | M1 | implemented | no snapshot is ever left missing an artifact after a prune |
| L6 | **Compat view rebuilt after prune** | M1 | implemented | `latest.txt` never names a deleted snapshot |
| L7 | **Garbage collection** of `incoming/` and uncommitted dirs | M1 | implemented | `mineback vault verify --gc` reclaims them and reports the bytes |
| L8 | **Manual hold/release** — `mineback hold <snapshot>` | M3 | planned | a held snapshot is exempt from every prune until released |

## 6. Integrity and verification

| id | Feature | Milestone | Status | Accepted when |
|----|---------|-----------|--------|---------------|
| V1 | **Scrub** — re-hash artifacts, `unzip -t` each zip | M2 | implemented | `mineback vault verify` detects a deliberately flipped byte |
| V2 | **Restore drill** — automated restore into a throwaway container | M2 | implemented | weekly drill restores the newest snapshot, sees `Done`, tears down, records success |
| V3 | **Manifest schema versioning** | M1 | implemented | a `schema: 1` manifest stays readable after the format grows |
| V4 | **Catalog reindex from manifests** | M1 | implemented | deleting `catalog.sqlite` and reindexing reproduces identical `ls` output |
| V5 | **Snapshot diff** — what changed between two snapshots | M3 | planned | `mineback diff` lists changed/added/removed entries per part |

## 7. Operations and UX

| id | Feature | Milestone | Status | Accepted when |
|----|---------|-----------|--------|---------------|
| O1 | **Host enrolment** — `mineback host add` prints the agent config and key | M1 | implemented | adding a host is copy-paste: key, config, timer |
| O2 | **Single TOML config** on the vault, env file on the agent | M1 | implemented | no settings duplicated between the two |
| O3 | **Catalog queries** — `ls`, `show`, filters by host/server/since/reason | M1 | implemented | `mineback ls --host h --since 7d` lists snapshots with size, age and status |
| O4 | **Scheduling** — cron or systemd timer templates, staggered | M1 | implemented | shipped units back up nightly without overlapping runs |
| O5 | **Summary output** — per-run table of server, parts, size, duration, result | M1 | implemented | one screen tells the admin what happened |
| O6 | **Non-zero exit on partial failure** | M1 | implemented | a fleet run with one dead container exits non-zero (unlike today's `backup.sh`) |
| O7 | **Agent self-test** — `mineback-agent selftest` checks docker, `zip` (incl. streaming-to-stdout support), `age`, ssh reachability, clock skew, free disk | M1 | implemented | a misconfigured host is diagnosed before the first nightly run |
| O8 | **Prometheus metrics** for minecraftDash | M2 | planned | last-success age, sizes, durations, failures, store bytes, verify and drill status are scrapable |
| O9 | **Staleness alert** — age of last success, not just failures | M2 | planned | a silently disabled timer raises an alert within 36h |
| O10 | **Notification hook** — script/webhook/mail on failure or partial | M2 | planned | one config line delivers nightly results |
| O11 | **MHS integration hook** — snapshot before `version` changes | M3 | planned | an optional MHS patch calls the agent before a Spigot version switch |
| O12 | **Multi-host fleet view** — status of every host on one screen | M3 | planned | `mineback status` shows per-host last success, size and drift |
| O13 | **Bootstrap installer** — `install-agent.sh` for a hosting host | M2 | implemented | one script installs agent, config, key and timer |
| O14 | **Capacity report** — store growth and projected fill | M3 | planned | `mineback vault status` reports growth per week and days until full |

## 8. Security

| id | Feature | Milestone | Status | Accepted when |
|----|---------|-----------|--------|---------------|
| S1 | **age encryption for secrets** — agent holds only the public recipient | M1 | implemented | a hosting host cannot decrypt any secrets bundle, including its own |
| S2 | **Restricted per-host agent keys** | M1 | implemented | the key yields no shell, no forwarding, one verb |
| S3 | **Host-scoped namespaces** — a host may only write under its own `host-id` | M1 | implemented | a request naming another host id is rejected |
| S4 | **Secrets never HTTP-served** | M1 | implemented | the compat view provably contains no `.age` file |
| S5 | **Key rotation** — rotate agent keys and the age recipient without rewriting history | M2 | planned | old snapshots stay decryptable with the retired identity; new ones use the new recipient |
| S6 | **`encrypt_all` option** — encrypt game data too | M3 | planned | enabling it is documented as disabling the self-service restore path |
| S7 | **Input validation on receive** — host/server/snapshot/artifact names strictly matched | M1 | implemented | path traversal and shell metacharacters are rejected |
| S8 | **Restore separated from backup credentials** | M1 | implemented | the agent key demonstrably cannot initiate a restore |

## 9. Explicit non-features

Listed so they are decisions rather than omissions:

- **No continuous/PITR backup.** Snapshot granularity only.
- **No in-place world editing.** mineback moves bytes; it does not inspect NBT or fix a corrupt chunk.
- **No web UI.** Status belongs in [minecraftDash](https://github.com/cndrbrbr/minecraftDash) via metrics; actions stay on the CLI.
- **No cross-server atomicity.** A fleet snapshot's servers are seconds to minutes apart.
- **No player-level restore** (one inventory, one build) in M1–M3. Extract a snapshot and do it by hand.
- **No backup of rebuildable artifacts.** Spigot JARs and plugin builds come from MHS and source.
- **No third-party Python dependencies** on the vault, and nothing beyond `bash`/`docker`/`ssh`/`zip`/`age` on hosting hosts.
- **No multi-tenant permissions.** One admin; SSH keys are the entire authorization model.

---

## Milestone summary

**M1 — first usable version.** Snapshot a single server or a whole host with hot
quiesce; append-only SSH push; atomic commit with checksums; compat view keeping
student self-service alive; single-server and full-host restore with selective
parts, dry-run, safety snapshot and a health gate; GFS pruning; catalog and
scheduling. At M1 every goal in the architecture doc is met at least once.

**M2 — operational hardening.** Scrub and restore drills, dedupe, offsite
replication, metrics and staleness alerts, notifications, cold snapshots,
cross-host restore, export bundles, key rotation, agent installer, pull mode.

**M3 — scale and comfort.** Multi-host status view, snapshot diff, holds,
capacity reporting, MHS version-change hooks, pluggable server kinds (Paper,
Velocity), optional full encryption.

## Current implementation status

Essentially all of M1 is implemented and passes `tests/smoke-test.sh`,
including a few items originally scoped for M2/M3 that turned out cheap once
the core plumbing existed (cold snapshots, cross-host restore via `docker -H`,
export, the install scripts, partial-fleet `--servers`, B12 standalone-mode
support). The backup path (single-server and fleet `snapshot`, secrets, push
over both `local` and real SSH transport) has now been run against three
independent production hosts — one colocated standalone fleet, one remote
BungeeCord fleet, one remote non-MHS layout (`javascriptMinecraftWorkshopServer`)
— which is what surfaced and fixed a real set of bugs the fake-Docker-shim
smoke test structurally couldn't reach: `docker exec`'s invalid `-T` flag,
`mc-backup`'s shell breaking every SSH forced command, `mineback-receive`
reading its verb from argv instead of `$SSH_ORIGINAL_COMMAND`, a shared
log file only one of two possible invokers could write to, and B12 itself.
What's real but still untested against production: R6/R7/R8 (marked
`partial`) — the *restore* code paths are written and exercised against a
fake Docker shim, but nobody has yet run an actual restore against a real
hosting host, or the git-clone/`docker compose up` bootstrap of
ARCHITECTURE.md §9.3 steps 1-3, which stays a manual step.
Genuinely not built: dedupe (T7), offsite replication (T9), pull mode (T10),
metrics/alerting (O8-O10), key rotation (S5), and everything scoped to M3.
