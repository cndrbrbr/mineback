# Example setup: three hosts (cndrbrbr.de, meckminecraft.de, codefield.de)

A worked example for a vault backing up three different real hosts at once:

| Host | Role |
|---|---|
| **cndrbrbr.de** | vault + local MHS, standalone mode (mc1-mc5, no BungeeCord) |
| **meckminecraft.de** | remote, MHS BungeeCord mode (mc1-mc5 + lobby + bungee) |
| **codefield.de** | remote, [javascriptMinecraftWorkshopServer](https://github.com/cndrbrbr/javascriptMinecraftWorkshopServer) — a different, single-server layout |

Host-ids used below: `cndrbrbr`, `meckminecraft`, `codefield` (dots aren't valid in a
host-id). See [example-setup.md](example-setup.md) for the single-host colocated
case and [README.md](README.md#prerequisites) for prerequisites.

## 0. Unblock codefield.de first

The vault needs root SSH access to codefield.de before anything else in that
section works (the same access meckminecraft.de already had set up). On
codefield.de, append the vault's public key to `/root/.ssh/authorized_keys`, then
confirm with `ssh root@codefield.de hostname` from the vault. Also confirm its
jsmcws checkout path (e.g. `/root/javascriptMinecraftWorkshopServer`) and its
container name (`spigot`) — adjust the steps below if different.

## 1. cndrbrbr.de — finish the vault, add this host's own agent

This assumes the repo lives at `/opt/mineback`, not under `/root`. That matters:
`mineback-receive` runs as the unprivileged `mc-backup` account (via every agent's
forced SSH command in steps 2.4/3.4), and `/root` is `700` by default — root-only —
so a repo cloned there is unreachable to `mc-backup` no matter what
`/usr/local/bin` symlinks point at. If yours is under `/root`, move it first
(`sudo mv /root/mineback /opt/mineback`, then re-run `install-vault.sh`, which now
checks for exactly this and warns if something's still blocking it).

**1.1 — Add all three host blocks:**

```bash
sudoedit /etc/mineback/mineback.toml
```

```toml
[hosts.cndrbrbr]
mhs_dir = "/root/hostMC/minecraftHostingServer"
# no `address` — vault and this hosting host are the same machine

[hosts.meckminecraft]
address = "ssh://root@meckminecraft.de"
mhs_dir = "/root/minecraftHostingServer"

[hosts.codefield]
address = "ssh://root@codefield.de"
mhs_dir = "/root/javascriptMinecraftWorkshopServer"   # adjust to the real path
```

**1.2 — Install the agent here:**

```bash
cd /opt/mineback
sudo install/install-agent.sh
```

**1.3 — Configure `/etc/mineback/agent.env`:**

```bash
sudoedit /etc/mineback/agent.env
```

```bash
MINEBACK_HOST_ID=cndrbrbr
MINEBACK_VAULT=local
MINEBACK_RECIPIENTS_FILE=/etc/mineback/recipients.age
MINEBACK_SERVERS="mc1 mc2 mc3 mc4 mc5"
MINEBACK_MHS_DIR=/root/hostMC/minecraftHostingServer
```

Delete/comment `MINEBACK_VAULT_SSH_KEY`, `MINEBACK_LOBBY`, `MINEBACK_PROXY` (standalone
mode, no lobby/bungee here).

**1.4 — Compat-view HTTP server.** `omasys-caddy` already owns host ports 80/443 on
this box, and nginx's own stock `default` site also listens on 80 by default and
will fail to bind alongside it — remove that site and put mineback on 8088 instead
of the template's default 8080:

```bash
sudo apt install nginx
sudo rm -f /etc/nginx/sites-enabled/default
sudo cp /opt/mineback/etc/nginx/mineback-vault.conf /etc/nginx/sites-available/mineback-vault
sudo sed -i 's/listen 8080;/listen 8088;/; s/listen \[::\]:8080;/listen [::]:8088;/' /etc/nginx/sites-available/mineback-vault
sudo ln -s /etc/nginx/sites-available/mineback-vault /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl enable --now nginx
```

**1.5 — Point mc1–mc5 at it** — edit `/root/hostMC/minecraftHostingServer/docker-compose.yml`,
every `BACKUP_URL: ""` line becomes:

```yaml
BACKUP_URL: "http://localhost:8088/cndrbrbr"
```

```bash
cd /root/hostMC/minecraftHostingServer
docker compose up -d --no-deps mc1 mc2 mc3 mc4 mc5
```

**1.6 — Weekly auto-prune timer:**

```bash
sudo cp /opt/mineback/etc/systemd/mineback-vault-maintenance.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now mineback-vault-maintenance.timer
```

**1.7 — Verify:**

```bash
mineback-agent selftest
mineback-agent snapshot --fleet --reason install-check
mineback ls --host cndrbrbr
```

## 2. meckminecraft.de — remote agent (BungeeCord fleet)

Run these **on meckminecraft.de**, over root SSH access to it.

**2.1 — Clone and install:**

```bash
git clone https://github.com/cndrbrbr/mineback.git && cd mineback
sudo apt install age zip unzip   # docker/ssh/curl already present
sudo install/install-agent.sh
```

This prints a public key at the end — ignore it for restore (you're using the
already-authorized root key for that); it's for the backup-push direction below,
a *different*, restricted key.

**2.2 — Copy the vault's recipients file over** (run from cndrbrbr.de):

```bash
scp /etc/mineback/recipients.age root@meckminecraft.de:/etc/mineback/recipients.age
```

**2.3 — On meckminecraft.de, configure `agent.env`:**

```bash
sudoedit /etc/mineback/agent.env
```

```bash
MINEBACK_HOST_ID=meckminecraft
MINEBACK_VAULT=ssh://mc-backup@cndrbrbr.de:22
MINEBACK_VAULT_SSH_KEY=/etc/mineback/agent_key
MINEBACK_RECIPIENTS_FILE=/etc/mineback/recipients.age
MINEBACK_SERVERS="mc1 mc2 mc3 mc4 mc5"
MINEBACK_LOBBY=lobby
MINEBACK_PROXY=bungee
MINEBACK_MHS_DIR=/root/minecraftHostingServer
```

**2.4 — Seed `known_hosts` for the vault, on meckminecraft.de.** Without this,
`mineback-agent selftest`'s SSH reachability check (and every real push) fails with
`Host key verification failed` — the agent's SSH calls use `BatchMode=yes`
deliberately (so cron never hangs on a host-key prompt), which means an unknown
host is refused outright rather than asked about interactively:

```bash
ssh-keyscan -H cndrbrbr.de >> /root/.ssh/known_hosts
```

**2.5 — Authorize its push key on the vault.** Print the key on meckminecraft.de:

```bash
cat /etc/mineback/agent_key.pub
```

Then, **on cndrbrbr.de**, append a restricted line to `mc-backup`'s authorized_keys.
The absolute path to `mineback-receive` is deliberate — a forced command's shell
doesn't source any rc file, so `/usr/local/bin` isn't guaranteed to be on PATH
(this is what `mineback host add <id>` itself now prints too):

```bash
sudo mkdir -p /var/lib/mineback/.ssh
echo 'command="/usr/local/bin/mineback-receive --fixed-host meckminecraft",no-pty,no-port-forwarding,no-agent-forwarding,no-X11-forwarding <paste-the-pubkey-here>' \
    | sudo tee -a /var/lib/mineback/.ssh/authorized_keys > /dev/null
sudo chown -R mc-backup:mc-backup /var/lib/mineback/.ssh
sudo chmod 700 /var/lib/mineback/.ssh
sudo chmod 600 /var/lib/mineback/.ssh/authorized_keys
```

**2.6 — Point its containers at the vault's HTTP view** — in
`/root/minecraftHostingServer/docker-compose*.yml` on meckminecraft.de, each
server's `BACKUP_URL` becomes:

```yaml
BACKUP_URL: "http://cndrbrbr.de:8088/meckminecraft"
```

then `docker compose up -d --no-deps mc1 mc2 mc3 mc4 mc5 lobby bungee`. (Make sure
cndrbrbr.de's firewall allows inbound 8088 from meckminecraft.de.)

**2.7 — Verify:**

```bash
mineback-agent selftest
mineback-agent snapshot --fleet --reason install-check
```

Then back on the vault: `mineback ls --host meckminecraft`.

If `bungee` specifically comes back `FAILED` while every `mcN`/`lobby` server
succeeds, check for `zip`/`unzip` inside that container — `minecraftHostingServer`'s
BungeeCord image doesn't ship them (its Spigot image does), so proxy config/plugin
capture has nothing to run:

```bash
docker exec bungee which zip unzip || docker exec bungee bash -c 'apt-get update -qq && apt-get install -y -qq zip unzip'
```

That's a fix to the running container only — it won't survive a rebuild/recreate
unless added to the image itself (a `minecraftHostingServer` change, not a
`mineback` one).

## 3. codefield.de — single-server, non-MHS layout

Same shape as step 2, once SSH is unblocked (step 0).

**3.1 — Clone and install:**

```bash
git clone https://github.com/cndrbrbr/mineback.git && cd mineback
sudo apt install age zip unzip   # docker/git already there per its own setup-debian.sh
sudo install/install-agent.sh
```

**3.2 — Copy the recipients file** (from cndrbrbr.de):

```bash
scp /etc/mineback/recipients.age root@codefield.de:/etc/mineback/recipients.age
```

**3.3 — On codefield.de, configure `agent.env`:**

```bash
sudoedit /etc/mineback/agent.env
```

```bash
MINEBACK_HOST_ID=codefield
MINEBACK_VAULT=ssh://mc-backup@cndrbrbr.de:22
MINEBACK_VAULT_SSH_KEY=/etc/mineback/agent_key
MINEBACK_RECIPIENTS_FILE=/etc/mineback/recipients.age
MINEBACK_SERVERS=spigot
MINEBACK_MHS_DIR=/root/javascriptMinecraftWorkshopServer
```

Leave `MINEBACK_LOBBY`/`MINEBACK_PROXY` at their defaults — there's no lobby/bungee
container here, so `--fleet` will just report them as harmlessly "skipped" (fleet
status `partial`, forever). Worth keeping `--fleet` anyway rather than switching
the timer to plain `snapshot spigot`, since only the fleet path also captures
`hostconf.zip` — the only way `.env` (the one real secret here, not in git) gets
backed up at all.

**3.4 — Seed `known_hosts` for the vault, on codefield.de** (same reason as 2.4 —
`BatchMode=yes` means an unseeded host key fails outright, not interactively):

```bash
ssh-keyscan -H cndrbrbr.de >> /root/.ssh/known_hosts
```

**3.5 — Authorize its push key on the vault**, same pattern as 2.5 but
`--fixed-host codefield`.

**3.6 — Verify** — this is the case the [secrets.age
fix](README.md) actually covers, worth watching closely the first time:

```bash
mineback-agent selftest
mineback-agent snapshot --fleet --reason install-check
```

Confirm `cfg.zip`/`plugins.zip`/`worlds.zip`/`state.zip` land and there's no
`secrets.age` (correctly absent — no sshd in that container) and the run still
reports `ok`, not `FAILED`.

No `BACKUP_URL`/nginx step here — jsmcws has no student self-service restore path
to preserve (no `backup.sh`/`mc-restore.sh` equivalent), so there's no compat view
to wire up.
