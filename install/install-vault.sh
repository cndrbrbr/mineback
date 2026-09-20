#!/bin/bash
# install-vault.sh — set up the mineback vault on this machine.
# Idempotent: safe to re-run after a `git pull` to pick up code changes.
#
# What this does:
#   - checks for required tools (python3, zip, unzip, age, ssh)
#   - creates /var/lib/mineback/{store,incoming,public,logs,keys}
#   - creates a dedicated `mc-backup` system user to receive agent pushes
#   - generates the vault's age identity (if one doesn't exist yet)
#   - installs mineback + mineback-receive onto PATH
#   - drops a starter /etc/mineback/mineback.toml (if one doesn't exist)
#
# What this does NOT do (see README.md for the manual steps):
#   - enable the systemd timers / install the nginx compat-view config —
#     printed as next steps, since whether you want nginx or something else
#     serving public/ is a choice this script shouldn't make for you.
#   - add any per-host agent keys — that's `mineback host add <host-id>`,
#     run after this script, once per hosting host you enroll.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "run as root (creates a system user and files under /etc, /var/lib, /usr/local/bin)" >&2
    exit 1
fi

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MINEBACK_HOME="${MINEBACK_HOME:-/var/lib/mineback}"

echo "==> Checking required tools..."
missing=0
for tool in python3 zip unzip age ssh sqlite3; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "    MISSING: $tool"
        missing=1
    fi
done
if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    echo "    WARNING: python3 < 3.11 — tomllib (stdlib TOML parsing) needs 3.11+"
fi
if [ "$missing" -eq 1 ]; then
    echo "Install the missing tools (e.g. 'apt install zip unzip age sqlite3') and re-run." >&2
    exit 1
fi
echo "    OK"

echo "==> Creating $MINEBACK_HOME ..."
mkdir -p "$MINEBACK_HOME"/{store,incoming,public,logs,keys/authorized_keys.d}
# o+x (not o+r) on the home dir itself: lets nginx (www-data) traverse down
# into public/ to serve the compat view, per README's nginx step, without
# making the home directory's own contents listable or readable by others —
# store/, incoming/ and keys/ stay unreachable regardless (keys/ is 700 on
# top of that; store/incoming are only reachable by name from inside the
# tree, which nginx's root never points at).
chmod 701 "$MINEBACK_HOME"
chmod 700 "$MINEBACK_HOME/keys"

echo "==> Creating mc-backup system user (owns the vault + receives agent pushes)..."
# Needs a real shell, not /usr/sbin/nologin: every agent key is restricted by
# a `command=` forced command in authorized_keys (T1/S2), and sshd runs that
# forced command via the account's login shell (`<shell> -c "<command>"`).
# nologin refuses to run anything at all, including the forced command
# itself — it doesn't add security here (command= + no-pty already fully
# override whatever the client asks for), it just breaks every push.
if ! id mc-backup >/dev/null 2>&1; then
    useradd --system --home-dir "$MINEBACK_HOME" --shell /bin/bash mc-backup
    echo "    created"
else
    echo "    already exists"
    usermod -s /bin/bash mc-backup
fi
chown -R mc-backup:mc-backup "$MINEBACK_HOME"
mkdir -p /home/mc-backup 2>/dev/null || true

echo "==> Installing mineback + mineback-receive onto PATH..."
ln -sf "$REPO/vault/mineback" /usr/local/bin/mineback
ln -sf "$REPO/vault/mineback-receive" /usr/local/bin/mineback-receive
ln -sf "$REPO/vault/mineback_lib" /usr/local/lib/mineback_lib 2>/dev/null || true
# mineback itself adds its own directory to sys.path, so the symlink above
# is a convenience for other tools, not required for `mineback` to work.
echo "    OK ($(command -v mineback))"

# mc-backup (unprivileged) is who actually runs mineback-receive, via every
# agent's forced SSH command — if the repo sits under a directory only root
# can traverse (e.g. cloned into /root, which is 700 by default), that will
# silently break every push with "Permission denied" the first time a real
# agent connects, long after this script reports success. Catch it now.
if ! sudo -u mc-backup test -x "$REPO/vault/mineback-receive" 2>/dev/null; then
    echo ""
    echo "    !!! WARNING: mc-backup cannot execute $REPO/vault/mineback-receive."
    echo "    !!! Some ancestor directory of the repo (commonly /root itself)"
    echo "    !!! isn't traversable by other users, so every agent's forced-"
    echo "    !!! command push will fail once a restricted key is in place."
    echo "    !!! Fix: move the repo somewhere world-traversable, e.g."
    echo "    !!!   mv $REPO /opt/mineback   (then re-run this script)"
    echo "    !!! or grant traversal-only access to the blocking directory:"
    echo "    !!!   chmod o+x <that directory>"
    echo ""
fi

echo "==> Generating the vault's age identity (if needed)..."
mkdir -p /etc/mineback
IDENTITY=/etc/mineback/vault_identity.txt
RECIPIENTS=/etc/mineback/recipients.age
if [ ! -f "$IDENTITY" ]; then
    age-keygen -o "$IDENTITY" 2>/tmp/mineback-agekeygen.log
    chmod 600 "$IDENTITY"
    grep -oP '(?<=Public key: )age1\S+' /tmp/mineback-agekeygen.log > "$RECIPIENTS"
    rm -f /tmp/mineback-agekeygen.log
    echo "    generated $IDENTITY"
    echo ""
    echo "    !!! Back this file up somewhere OTHER than this machine (paper, USB, a"
    echo "    !!! password manager) — losing it turns a full host restore into a"
    echo "    !!! manual rebuild, per ARCHITECTURE.md §12."
    echo ""
else
    echo "    already exists — leaving it alone"
fi
echo "    recipient(s) for agent.env's MINEBACK_RECIPIENTS_FILE: $RECIPIENTS"

echo "==> Writing /etc/mineback/mineback.toml (if it doesn't exist)..."
if [ ! -f /etc/mineback/mineback.toml ]; then
    sed "s#/var/lib/mineback#$MINEBACK_HOME#; s#/etc/mineback/vault_identity.txt#$IDENTITY#" \
        "$REPO/etc/mineback.toml.example" > /etc/mineback/mineback.toml
    echo "    written — edit it to add each [hosts.<id>] block (or run 'mineback host add <id>')"
else
    echo "    already exists — leaving it alone"
fi

cat <<EOF

==> Vault base install complete. Next steps:

1. For each hosting host you'll back up:
     mineback host add <host-id>
   Follow its printed instructions (generate the host's agent key, add a
   restricted authorized_keys entry here, install the agent there).

2. Serve public/ over HTTP so the existing in-container 'restore' command
   (unchanged from minecraftHostingServer) can reach it:
     cp $REPO/etc/nginx/mineback-vault.conf /etc/nginx/sites-available/mineback-vault
     ln -s /etc/nginx/sites-available/mineback-vault /etc/nginx/sites-enabled/
     systemctl reload nginx

3. Enable weekly scrub + prune-dry-run:
     cp $REPO/etc/systemd/mineback-vault-maintenance.{service,timer} /etc/systemd/system/
     systemctl enable --now mineback-vault-maintenance.timer

4. sshd needs PermitUserEnvironment=no (default) and mc-backup's
   authorized_keys populated by 'mineback host add' — see its output.
EOF
