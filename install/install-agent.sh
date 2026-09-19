#!/bin/bash
# install-agent.sh — set up mineback-agent on an MHS hosting host.
# Idempotent: safe to re-run after a `git pull` to pick up code changes.
#
# What this does:
#   - checks for required tools (docker, zip, ssh, age)
#   - installs mineback-agent onto PATH
#   - drops a starter /etc/mineback/agent.env (if one doesn't exist)
#   - generates this host's restricted SSH key for pushing to the vault
#   - installs the systemd timer (or a cron.d fragment, with --cron)
#
# What this does NOT do:
#   - fill in agent.env's MINEBACK_HOST_ID / MINEBACK_VAULT / recipients —
#     those come from `mineback host add <host-id>` run on the vault; copy
#     its output into /etc/mineback/agent.env here after this script runs.
#   - add the generated public key to the vault — same step, on the vault.
set -euo pipefail

USE_CRON=0
[ "${1:-}" = "--cron" ] && USE_CRON=1

if [ "$(id -u)" -ne 0 ]; then
    echo "run as root (installs a systemd timer / cron.d entry and files under /etc)" >&2
    exit 1
fi

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> Checking required tools..."
missing=0
for tool in docker zip unzip age ssh curl; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "    MISSING: $tool"
        missing=1
    fi
done
if [ "$missing" -eq 1 ]; then
    echo "Install the missing tools and re-run. (age: 'apt install age' on Debian trixie+.)" >&2
    exit 1
fi
echo "    OK"

echo "==> Installing mineback-agent onto PATH..."
ln -sf "$REPO/agent/mineback-agent" /usr/local/bin/mineback-agent
echo "    OK ($(command -v mineback-agent))"

mkdir -p /etc/mineback
echo "==> Writing /etc/mineback/agent.env (if it doesn't exist)..."
if [ ! -f /etc/mineback/agent.env ]; then
    cp "$REPO/etc/agent.env.example" /etc/mineback/agent.env
    echo "    written — fill in MINEBACK_HOST_ID / MINEBACK_VAULT / MINEBACK_SERVERS"
    echo "    from 'mineback host add <host-id>' run on the vault."
else
    echo "    already exists — leaving it alone"
fi

echo "==> Generating this host's restricted SSH key (if needed)..."
if [ ! -f /etc/mineback/agent_key ]; then
    ssh-keygen -t ed25519 -f /etc/mineback/agent_key -N '' -C "mineback-agent@$(hostname)" -q
    chmod 600 /etc/mineback/agent_key
    echo "    generated /etc/mineback/agent_key"
else
    echo "    already exists — leaving it alone"
fi
echo ""
echo "    Public key to give the vault admin (for 'mineback host add'):"
echo "    ---"
cat /etc/mineback/agent_key.pub
echo "    ---"

if [ "$USE_CRON" -eq 1 ]; then
    echo "==> Installing cron.d fragment..."
    cp "$REPO/etc/cron/mineback-agent" /etc/cron.d/mineback-agent
    echo "    installed /etc/cron.d/mineback-agent (edit the schedule if running"
    echo "    this on more than one host against the same vault)"
else
    echo "==> Installing systemd timer..."
    cp "$REPO/etc/systemd/mineback-agent.service" /etc/systemd/system/
    cp "$REPO/etc/systemd/mineback-agent.timer" /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable --now mineback-agent.timer
    echo "    enabled mineback-agent.timer (nightly 02:15, ±5min jitter)"
fi

cat <<EOF

==> Agent install complete. Next steps:

1. On the vault, run: mineback host add <a-name-for-this-host>
   Paste this host's public key (shown above) where it asks.

2. Edit /etc/mineback/agent.env here with the values it prints
   (MINEBACK_HOST_ID, MINEBACK_VAULT, MINEBACK_RECIPIENTS_FILE, MINEBACK_SERVERS).

3. Save the vault's recipients file to the path in MINEBACK_RECIPIENTS_FILE.

4. Verify everything before trusting the nightly timer:
     mineback-agent selftest
     mineback-agent snapshot --fleet --reason install-check
EOF
