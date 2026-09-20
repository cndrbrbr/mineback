#!/bin/bash
# drill/tunnel.sh — hold a reverse SSH tunnel open from a disposable local
# drill target back to the vault, for machines with no direct inbound
# reachability (behind NAT, no port forward, no VPN).
#
# Run this ON the local drill-target machine, in its own terminal/session —
# it runs in the foreground on purpose. Ctrl-C closes the tunnel when you're
# done; nothing about this is meant to be left open permanently, since a
# drill is an on-demand rehearsal (weekly/on-demand per ARCHITECTURE.md §11),
# not part of the always-on backup path.
#
# What it does: dials out from here to the vault and asks it to bind
# 127.0.0.1:<remote-port> on ITSELF, forwarding anything that connects there
# back through the tunnel to this machine's own sshd. The vault can then
# reach this machine's Docker socket via `docker -H ssh://user@127.0.0.1:<remote-port>`
# as if it were any other directly-reachable host — from the vault's own
# point of view, "127.0.0.1:<remote-port>" IS this machine, for the
# lifetime of the tunnel. Use 127.0.0.1 on the vault side, not "localhost" —
# "localhost" resolves ::1 first on most systems, and nothing is listening
# on the IPv6 loopback (the bind above is IPv4-only), so it just hangs/fails
# with no useful error.
set -euo pipefail

VAULT_TARGET="${1:?usage: tunnel.sh <user@vault-host> [remote-port] [local-ssh-port]}"
# 19222, not something like 2222: minecraftHostingServer maps each student's
# SSH/FileZilla port at 222N (2221=mc1, 2222=mc2, ...), so a "nice round"
# port in that range is exactly the one most likely to already be taken on
# the vault if it's also a colocated hosting host (it was, the first time
# this was tried). Check the vault's actual open ports (`ss -ltn`) before
# assuming any port is free, this default included.
REMOTE_PORT="${2:-19222}"
LOCAL_SSH_PORT="${3:-22}"

cat <<EOF
==> Opening a reverse tunnel: ${VAULT_TARGET}:127.0.0.1:${REMOTE_PORT} -> this machine's :${LOCAL_SSH_PORT}

Once connected, on the VAULT (${VAULT_TARGET#*@}), in another session, add
(if not already present) to /etc/mineback/mineback.toml:

    [hosts.drill-local]
    address = "ssh://root@127.0.0.1:${REMOTE_PORT}"

then run, for whichever real host/server you want to rehearse a restore of:

    mineback drill <host>/<server> --to drill-local/<container-name-on-this-machine>

Leave this running for the duration of the drill. Ctrl-C to close it
afterward — the tunnel and the [hosts.drill-local] entry are both inert
(just a dead address) once it's down, nothing to clean up on the vault side.
EOF

exec ssh -N \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    -R "127.0.0.1:${REMOTE_PORT}:localhost:${LOCAL_SSH_PORT}" \
    "$VAULT_TARGET"
