#!/bin/bash
# smoke-test.sh — end-to-end test of the mineback agent + vault, with no real
# Docker containers, no real Minecraft, and no network — everything runs
# against a fake `docker` shim (fake-docker/docker) plus synthetic fixtures
# built below. Safe to run repeatedly on a dev machine or in CI.
#
# What it exercises (numbers refer to FEATURES.md ids):
#   B1-B4, B5, B8, B9   — packing every part, fleet incl. proxy, exclusions
#   C1-C3               — hot quiesce + guaranteed save-on
#   T1, T5, T6, T8       — append-only receive, checksums, atomic commit, compat view
#   R2, R3, R5, R7, R9-R11 — selective/default/secrets/proxy/fleet restore,
#                            dry-run, confirmation gate, safety snapshot
#   V1                  — scrub catches injected corruption
#   L1-L3               — GFS retention unit-tested inline
#   R12, V2             — export, drill
#
# Requires: bash, docker-free (uses the fake shim), zip, unzip, age, python3.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
WORK="$(mktemp -d /tmp/mineback-smoke-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
check() {
    local desc="$1"; shift
    if "$@"; then
        echo "  ok   $desc"
        PASS=$((PASS+1))
    else
        echo "  FAIL $desc"
        FAIL=$((FAIL+1))
    fi
}
contains() { grep -qF -- "$2" "$1"; }
not_contains() { ! grep -qF -- "$2" "$1"; }

echo "== workdir: $WORK =="

# ── fake docker shim ──────────────────────────────────────────────────
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/docker" <<'DOCKEREOF'
#!/bin/bash
FAKE_ROOT="${FAKE_DOCKER_ROOT:?set FAKE_DOCKER_ROOT}"
SEP=$'\x01'
rewrite() {
  local cname="$1" s="$2"
  s="${s//\/server/${SEP}SRV${SEP}}"
  s="${s//\/bungee/${SEP}BNG${SEP}}"
  s="${s//\/tmp/${SEP}TMP${SEP}}"
  s="${s//${SEP}SRV${SEP}//$FAKE_ROOT/$cname/server}"
  s="${s//${SEP}BNG${SEP}//$FAKE_ROOT/$cname/bungee}"
  s="${s//${SEP}TMP${SEP}//$FAKE_ROOT/$cname/tmp}"
  echo "$s"
}
sub="$1"; shift
case "$sub" in
  inspect)
    name="${@: -1}"
    [ -d "$FAKE_ROOT/$name" ] && echo true || echo false
    ;;
  exec)
    name=""; declare -a envs=()
    while [ $# -gt 0 ]; do
      case "$1" in
        -T|-i|-it) shift ;;
        -e) envs+=("$2"); shift 2 ;;
        *) name="$1"; shift; break ;;
      esac
    done
    script="$3"
    # Regression guard: the pkill/pgrep self-match fix (see comments in
    # agent/mineback-agent and vault/mineback_lib/restore.py) must pass the
    # match pattern via an env var, never embed it in the wrapping script.
    if [[ "$script" == *pkill* || "$script" == *pgrep* ]]; then
        if [[ "$script" == *"spigot-.*"* ]]; then
            echo "REGRESSION: pkill/pgrep pattern embedded literally (self-match risk)" >&2
            exit 99
        fi
        [[ "$script" == *pkill* ]] && exit 0
        exit 1
    fi
    script="$(rewrite "$name" "$script")"
    mkdir -p "$FAKE_ROOT/$name/tmp"
    ( for kv in "${envs[@]}"; do export "$kv"; done; bash -c "$script" )
    ;;
  cp)
    src="$1"; dst="$2"
    if [[ "$dst" == *:* ]]; then
      cname="${dst%%:*}"; rpath="$(rewrite "$cname" "${dst#*:}")"
      mkdir -p "$(dirname "$rpath")"; cp -a "$src" "$rpath"
    else
      cname="${src%%:*}"; rpath="$(rewrite "$cname" "${src#*:}")"
      mkdir -p "$(dirname "$dst")"; cp -a "$rpath" "$dst"
    fi
    ;;
  restart) exit 0 ;;
  logs)
    echo "[Server thread/INFO]: Saved the game"
    echo "[Server thread/INFO]: Done (1.234s)! For help, type \"help\""
    ;;
  *) echo "fake docker: unsupported subcommand '$sub'" >&2; exit 1 ;;
esac
DOCKEREOF
chmod +x "$WORK/fakebin/docker"

# ── fixtures: one spigot server, one lobby, one proxy ─────────────────
mk_spigot() {
    local root="$1"
    mkdir -p "$root/data/cfg" "$root/data/plugins" "$root/data/worlds/world/region"
    echo "server-name=x" > "$root/data/cfg/server.properties"
    echo "plugin" > "$root/data/plugins/x.jar"
    echo "world" > "$root/data/worlds/world/level.dat"
    echo "region" > "$root/data/worlds/world/region/r.0.0.mca"
    echo '[{"uuid":"abc","name":"Alice"}]' > "$root/whitelist.json"
    echo '[]' > "$root/ops.json"; echo '[]' > "$root/banned-players.json"
    echo '[]' > "$root/banned-ips.json"; echo '[]' > "$root/usercache.json"
    touch "$root/permissions.yml" "$root/help.yml"
    echo "1.21.11" > "$root/.version"
    echo "FAKE" > "$root/ssh_host_ed25519_key"; echo "FAKE" > "$root/ssh_host_ed25519_key.pub"
    echo "FAKE" > "$root/ssh_host_rsa_key"; echo "FAKE" > "$root/ssh_host_rsa_key.pub"
}
mk_spigot "$WORK/fakeroot/mc1/server"
mk_spigot "$WORK/fakeroot/lobby/server"
mkdir -p "$WORK/fakeroot/bungee/bungee/plugins" "$WORK/fakeroot/bungee/bungee/modules"
echo "listeners: []" > "$WORK/fakeroot/bungee/bungee/config.yml"
echo "{}" > "$WORK/fakeroot/bungee/bungee/modules.yml"
echo "{}" > "$WORK/fakeroot/bungee/bungee/locations.yml"
echo "plugin" > "$WORK/fakeroot/bungee/bungee/plugins/x.jar"
echo "module" > "$WORK/fakeroot/bungee/bungee/modules/y.jar"

# ── age identity + mineback.toml ───────────────────────────────────────
age-keygen -o "$WORK/identity.txt" 2>"$WORK/age.log"
grep -oP '(?<=Public key: )age1\S+' "$WORK/age.log" > "$WORK/recipients.txt"

cat > "$WORK/mineback.toml" <<EOF
home = "$WORK/vault-home"
[vault]
age_identity = "$WORK/identity.txt"
[retention]
keep_last = 3
keep_daily = 7
keep_weekly = 4
keep_monthly = 6
[hosts.h1]
EOF

# a minimal MHS checkout, so fleet snapshots exercise real hostconf capture
mkdir -p "$WORK/mhs/keys/mc1" "$WORK/mhs/spigot"
echo "services: {}" > "$WORK/mhs/docker-compose.yml"
echo "MC1_SFTP_PUBKEY=x" > "$WORK/mhs/.env"
echo "fake-private-key" > "$WORK/mhs/keys/mc1/ctrl_key"
git -C "$WORK/mhs" init -q
git -C "$WORK/mhs" -c user.email=t@t -c user.name=t add -A
git -C "$WORK/mhs" -c user.email=t@t -c user.name=t commit -q -m init

cat > "$WORK/agent.env" <<EOF
MINEBACK_HOST_ID=h1
MINEBACK_VAULT=local
MINEBACK_RECEIVE_BIN=$REPO/vault/mineback-receive
MINEBACK_RECIPIENTS_FILE=$WORK/recipients.txt
MINEBACK_SERVERS=mc1
MINEBACK_LOBBY=lobby
MINEBACK_PROXY=bungee
MINEBACK_MHS_DIR=$WORK/mhs
MINEBACK_FLUSH_TIMEOUT=5
MINEBACK_LOG=$WORK/agent.log
EOF

export MINEBACK_AGENT_CONF="$WORK/agent.env"
export MINEBACK_HOME="$WORK/vault-home"
export MINEBACK_CONFIG="$WORK/mineback.toml"
export FAKE_DOCKER_ROOT="$WORK/fakeroot"
export PATH="$WORK/fakebin:$REPO/vault:$REPO/agent:$PATH"

echo "== selftest =="
mineback-agent selftest > "$WORK/out.log" 2>&1
check "selftest passes" grep -q "selftest: PASS" "$WORK/out.log"

echo "== single-server snapshot (mc1) =="
mineback-agent snapshot mc1 --reason smoke-baseline > "$WORK/out.log" 2>&1
check "snapshot committed" grep -q "COMPLETE" "$WORK/out.log"
mineback vault reindex --quiet
SNAP1=$(mineback ls --host h1 --server mc1 | awk 'NR==2{print $3}')
check "snapshot appears in catalog" test -n "$SNAP1"

echo "== artifact integrity =="
STOREDIR="$WORK/vault-home/store/h1/servers/mc1/$SNAP1"
check "cfg.zip exists" test -f "$STOREDIR/cfg.zip"
check "worlds.zip exists" test -f "$STOREDIR/worlds.zip"
check "state.zip exists" test -f "$STOREDIR/state.zip"
check "secrets.age exists" test -f "$STOREDIR/secrets.age"
check "secrets.age is actually encrypted (age can't decrypt without identity)" \
    bash -c "! age -d '$STOREDIR/secrets.age' >/dev/null 2>&1"
check "secrets.age decrypts with the identity" \
    bash -c "age -d -i '$WORK/identity.txt' '$STOREDIR/secrets.age' >/dev/null 2>&1"

echo "== vault verify (scrub) =="
mineback vault verify > "$WORK/out.log" 2>&1
check "scrub clean on an untouched store" grep -q "0 issue" "$WORK/out.log"
echo "corruption" >> "$STOREDIR/cfg.zip"
mineback vault verify > "$WORK/out.log" 2>&1 || true
check "scrub detects injected corruption" grep -q "ISSUE" "$WORK/out.log"
ORIGSIZE=$(python3 -c "import json;print(json.load(open('$STOREDIR/manifest.json'))['artifacts']['cfg.zip']['bytes'])")
truncate -s "$ORIGSIZE" "$STOREDIR/cfg.zip"

echo "== compat view (T8) =="
DATE="${SNAP1:0:4}-${SNAP1:4:2}-${SNAP1:6:2}"
check "dated cfg zip published" test -f "$WORK/vault-home/public/h1/mc1/cfg-$DATE.zip"
check "latest.txt published" test -f "$WORK/vault-home/public/h1/mc1/latest.txt"

echo "== fleet snapshot incl. hostconf (B5, B6, B7, B8) =="
mineback-agent snapshot --fleet --reason smoke-fleet > "$WORK/out.log" 2>&1
check "fleet run reports 3 ok, exit 0 (hostconf configured -> complete)" \
    bash -c 'grep -q "ok=3" '"$WORK"'/out.log'
mineback vault reindex --quiet
FLEET=$(ls "$WORK/vault-home/store/h1/fleets" | sort | tail -1)
check "fleet manifest has a servers map" python3 -c "
import json,sys
m = json.load(open('$WORK/vault-home/store/h1/fleets/$FLEET/manifest.json'))
sys.exit(0 if {'mc1','lobby','bungee'} <= set(m.get('servers',{})) else 1)
"
check "fleet manifest status is complete" python3 -c "
import json,sys
m = json.load(open('$WORK/vault-home/store/h1/fleets/$FLEET/manifest.json'))
sys.exit(0 if m.get('status') == 'complete' else 1)
"
check "hostconf.zip captured" test -f "$WORK/vault-home/store/h1/fleets/$FLEET/hostconf.zip"
check "hostconf.zip contains docker-compose.yml, not .git/.env/keys" bash -c "
u=\$(unzip -l '$WORK/vault-home/store/h1/fleets/$FLEET/hostconf.zip')
echo \"\$u\" | grep -q docker-compose.yml && ! echo \"\$u\" | grep -q '\.env' && ! echo \"\$u\" | grep -q keys/ctrl_key
"
check "hostconf-secrets.age captured and encrypted" bash -c "
f='$WORK/vault-home/store/h1/fleets/$FLEET/hostconf-secrets.age'
[ -f \"\$f\" ] && ! age -d \"\$f\" >/dev/null 2>&1
"
check "hostconf-secrets.age decrypts to .env + keys/" bash -c "
age -d -i '$WORK/identity.txt' '$WORK/vault-home/store/h1/fleets/$FLEET/hostconf-secrets.age' > '$WORK/hostconf-secrets.zip' &&
unzip -l '$WORK/hostconf-secrets.zip' | grep -q '\.env' &&
unzip -l '$WORK/hostconf-secrets.zip' | grep -q ctrl_key
"

echo "== restore: dry-run touches nothing =="
S="$WORK/fakeroot/mc1/server"
echo '[{"uuid":"abc","name":"Alice"},{"uuid":"x","name":"Bob"}]' > "$S/whitelist.json"
echo "DRIFTED" > "$S/data/worlds/world/level.dat"
mineback restore server h1/mc1 --snapshot "$SNAP1" --dry-run > "$WORK/out.log" 2>&1
check "dry-run leaves world untouched" grep -q "DRIFTED" "$S/data/worlds/world/level.dat"

echo "== restore: selective --parts worlds only =="
mineback restore server h1/mc1 --snapshot "$SNAP1" --parts worlds --yes --no-safety > "$WORK/out.log" 2>&1
check "world reverted" bash -c "[ \"\$(cat '$S/data/worlds/world/level.dat')\" = world ]"
check "whitelist (untouched part) kept the live change" contains "$S/whitelist.json" Bob
check "container resumed (.stopped cleared)" bash -c "[ ! -f '$S/.stopped' ]"

echo "== restore: default full restore takes a safety snapshot =="
BEFORE=$(ls "$WORK/vault-home/store/h1/servers/mc1" | wc -l)
mineback restore server h1/mc1 --snapshot "$SNAP1" --yes > "$WORK/out.log" 2>&1
AFTER=$(ls "$WORK/vault-home/store/h1/servers/mc1" | wc -l)
check "whitelist reverted (state restored)" not_contains "$S/whitelist.json" Bob
check "a pre-restore safety snapshot was taken" test "$AFTER" -eq $((BEFORE + 1))

echo "== restore: confirmation gate aborts without --yes =="
if echo n | mineback restore server h1/mc1 --snapshot "$SNAP1" --no-safety > "$WORK/out.log" 2>&1; then
    check "refuses without confirmation" false
else
    check "refuses without confirmation" grep -q "Aborted" "$WORK/out.log"
fi

echo "== restore: secrets round-trip =="
mineback restore server h1/mc1 --snapshot "$SNAP1" --parts secrets --with-secrets --yes --no-safety > "$WORK/out.log" 2>&1
check "restored key has correct permissions (600)" bash -c "[ \"\$(stat -c%a '$S/ssh_host_ed25519_key')\" = 600 ]"

echo "== restore: proxy (kind=proxy) =="
B="$WORK/fakeroot/bungee/bungee"
echo "listeners: [drift]" > "$B/config.yml"
echo "stray" > "$B/plugins/stray.jar"
mineback restore server h1/bungee --snapshot latest --parts cfg,plugins --yes --no-safety > "$WORK/out.log" 2>&1
check "proxy config reverted" bash -c "[ \"\$(cat '$B/config.yml')\" = 'listeners: []' ]"
check "stray plugin removed" bash -c "[ ! -f '$B/plugins/stray.jar' ]"
check "original proxy plugin intact" test -f "$B/plugins/x.jar"

echo "== restore fleet (all 3 servers/kinds) =="
mineback restore fleet h1 --yes > "$WORK/out.log" 2>&1
check "fleet restore reports all ok" bash -c '[ "$(grep -c " ok$" "'"$WORK"'/out.log")" -eq 3 ]'

echo "== export (never includes secrets) =="
mineback export h1/mc1 --snapshot latest --out "$WORK/export.zip" > "$WORK/out.log" 2>&1
check "export produced a file" test -f "$WORK/export.zip"
check "export contains no secrets" bash -c "! unzip -l '$WORK/export.zip' | grep -q secrets"

echo "== drill (restore latest into a throwaway target) =="
cp -r "$WORK/fakeroot/mc1/server" "$WORK/fakeroot/mc1-drill-tmp" 2>/dev/null || true
mkdir -p "$WORK/fakeroot/mc1-drill"
cp -r "$WORK/fakeroot/mc1/server/." "$WORK/fakeroot/mc1-drill/server/" 2>/dev/null || \
    { mkdir -p "$WORK/fakeroot/mc1-drill/server"; cp -r "$WORK/fakeroot/mc1/server/." "$WORK/fakeroot/mc1-drill/server/"; }
mineback drill h1/mc1 --to h1/mc1-drill > "$WORK/out.log" 2>&1
check "drill reports OK" grep -q "DRILL OK" "$WORK/out.log"

echo "== fleet snapshot with hostconf unconfigured -> still commits, marked partial (O6 regression) =="
sed '/MINEBACK_MHS_DIR/d' "$WORK/agent.env" > "$WORK/agent-nohostconf.env"
RC=0
MINEBACK_AGENT_CONF="$WORK/agent-nohostconf.env" mineback-agent snapshot --fleet --reason smoke-nohostconf \
    > "$WORK/out.log" 2>&1 || RC=$?
check "exits non-zero when hostconf is unconfigured (partial fleet)" test "$RC" -ne 0
mineback vault reindex --quiet
FLEET2=$(ls "$WORK/vault-home/store/h1/fleets" | sort | tail -1)
check "fleet manifest STILL committed (servers map not lost)" python3 -c "
import json,sys
m = json.load(open('$WORK/vault-home/store/h1/fleets/$FLEET2/manifest.json'))
sys.exit(0 if {'mc1','lobby','bungee'} <= set(m.get('servers',{})) else 1)
"
check "fleet manifest status is partial" python3 -c "
import json,sys
m = json.load(open('$WORK/vault-home/store/h1/fleets/$FLEET2/manifest.json'))
sys.exit(0 if m.get('status') == 'partial' else 1)
"
check "no hostconf.zip when MHS_DIR is unconfigured" bash -c "[ ! -f '$WORK/vault-home/store/h1/fleets/$FLEET2/hostconf.zip' ]"

echo "== GFS retention (pure logic, no filesystem) =="
python3 -c "
import sys
sys.path.insert(0, '$REPO/vault')
from datetime import datetime, timezone, timedelta
from mineback_lib.retention import select
from mineback_lib.config import RetentionConfig

NOW = datetime(2026, 9, 19, 12, 0, 0, tzinfo=timezone.utc)
def sid(days_ago):
    dt = (NOW - timedelta(days=days_ago)).replace(hour=2, minute=0, second=0, microsecond=0)
    return dt.strftime('%Y%m%dT%H%M%SZ')

ids = [sid(d) for d in range(400)]
protected = sid(390)
reasons = {i: 'scheduled' for i in ids}
reasons[protected] = 'workshop-final'
r = RetentionConfig(keep_last=3, keep_daily=7, keep_weekly=4, keep_monthly=6,
                     keep_reasons=('pre-restore','pre-version','workshop-final'))
d = select(ids, reasons, r, now=NOW)
assert len(d.keep) < 30, 'GFS should collapse 400 dailies to a small set'
assert protected in d.keep, 'protected reason must survive pruning'
assert d.keep | d.prune == set(ids)
assert d.keep & d.prune == set()
print('OK')
" > "$WORK/out.log" 2>&1
check "GFS retention selection is correct" grep -q OK "$WORK/out.log"

echo
echo "================================================"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
