#!/bin/bash
# drill/setup-target.sh — build a real, throwaway MHS spigot container on a
# disposable local machine, so `mineback drill` has something genuine to
# restore into without ever touching a production host.
#
# `mineback drill` (vault/mineback:cmd_drill -> mineback_lib/restore.py) does
# a REAL restore: pause the container (touch /server/.stopped), docker cp +
# unzip a real snapshot into it, remove .stopped, then tail its logs for
# "Done (...)!" — entrypoint.sh's own auto-restart loop notices .stopped is
# gone and relaunches java, exactly like a real "student stopped and
# restarted their server" cycle. That only works against a container running
# minecraftHostingServer's actual spigot image (same /server layout, same
# .stopped convention, same entrypoint loop) — not a generic container with
# unzip in it.
#
# Idempotent: safe to re-run (reuses the existing image/volume/container).
set -euo pipefail

NAME="${1:-mc1-drill}"
MHS_REPO_URL="${MHS_REPO_URL:-https://github.com/cndrbrbr/minecraftHostingServer.git}"
MHS_CHECKOUT="${MHS_CHECKOUT:-$HOME/minecraftHostingServer-drill}"
IMAGE="mineback-drill-spigot"
MC_MEM_MIN="${MC_MEM_MIN:-512M}"
MC_MEM_MAX="${MC_MEM_MAX:-1536M}"

if [ "$(id -u)" -ne 0 ]; then
    echo "run as root (docker build/run, and this is meant to be a disposable" >&2
    echo "test machine — don't run this against a machine you care about)" >&2
    exit 1
fi

command -v docker >/dev/null 2>&1 || { echo "docker is required — install it first" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "git is required — install it first" >&2; exit 1; }

echo "==> Cloning minecraftHostingServer (drill-only checkout, separate from"
echo "    any real deployment) ..."
if [ -d "$MHS_CHECKOUT/.git" ]; then
    echo "    already present at $MHS_CHECKOUT — leaving it alone (git pull yourself if you want updates)"
else
    git clone --depth 1 "$MHS_REPO_URL" "$MHS_CHECKOUT"
fi

echo "==> Building the spigot image ($IMAGE) ..."
docker build -t "$IMAGE" "$MHS_CHECKOUT/spigot"

echo "==> Starting/reusing the throwaway container ($NAME) ..."
if docker inspect "$NAME" >/dev/null 2>&1; then
    echo "    $NAME already exists — leaving it as-is. Remove it first"
    echo "    (docker rm -f $NAME && docker volume rm ${NAME}_data) to rebuild from scratch."
else
    docker volume create "${NAME}_data" >/dev/null
    docker run -d \
        --name "$NAME" \
        --restart unless-stopped \
        --stop-signal SIGTERM \
        -v "${NAME}_data:/server" \
        -e "MC_NAME=$NAME" \
        -e "MC_LEVELNAME=world" \
        -e "MC_PORT=25565" \
        -e "MC_MEM_MIN=$MC_MEM_MIN" \
        -e "MC_MEM_MAX=$MC_MEM_MAX" \
        -e "FORCE_BUILD=false" \
        -e "BACKUP_URL=" \
        "$IMAGE" >/dev/null
    echo "    created — no ports published, this container is only ever reached"
    echo "    via 'docker exec'/'docker cp' from the vault, never by a Minecraft client"
fi

echo "==> Waiting for first boot — this builds Spigot via BuildTools on the very"
echo "    first start (several minutes), but only once: the jar is cached on the"
echo "    volume, so every restore afterward (including the real drill restart)"
echo "    restarts in seconds, well inside mineback's own 180s startup timeout."
if timeout 900 docker logs -f "$NAME" 2>&1 | grep -qm1 'Done ('; then
    echo "==> $NAME is up. Ready for a real drill."
else
    echo "==> Timed out waiting for 'Done (' — check 'docker logs $NAME' before" >&2
    echo "    trying a drill against it; something didn't boot cleanly." >&2
    exit 1
fi

cat <<EOF

==> Target ready: $NAME

Next: drill/tunnel.sh <vault-ssh-target> to open the reverse tunnel, then run
'mineback drill' from the vault. See drill/README.md for the full flow.
EOF
