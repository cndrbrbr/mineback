# Example setup: vault + agent colocated on one host

A worked example for the common small-scale case: **one machine** running both the
MHS hosting stack (`mc1` … `mcN`) *and* the mineback vault — no second box, no SSH
between the two, snapshots pushed with `MINEBACK_VAULT=local` straight into
`mineback-receive`. See [README.md](README.md) for the general (multi-host)
quickstart and [ARCHITECTURE.md](ARCHITECTURE.md) for why things are shaped this way.

Replace `mc-workshop-01` below with whatever host-id you want — it becomes the
top-level directory under the vault's `store/` and `public/`, and survives a
rebuild as long as you reuse it. Replace `/root/hostMC/minecraftHostingServer` with
your actual MHS checkout path, and `mc1 mc2 mc3 mc4 mc5` with your actual container
names.

Install the [prerequisites](README.md#prerequisites) first:

```bash
sudo apt install python3 zip unzip age ssh sqlite3 docker.io docker-compose-plugin
```

## 1. Install the vault

```bash
cd /root/mineback
sudo install/install-vault.sh
```

Creates `/var/lib/mineback/`, the `mc-backup` system user, symlinks
`mineback`/`mineback-receive` onto PATH, generates the `age` encryption identity,
and writes `/etc/mineback/mineback.toml` — retention defaults to `keep_last=1`
(newest snapshot per server only, nothing older); adjust `[retention]` in
`mineback.toml` if you want more history.

## 2. Add this host to the vault config

```bash
sudoedit /etc/mineback/mineback.toml
```

Add at the bottom:

```toml
[hosts.mc-workshop-01]
mhs_dir = "/root/hostMC/minecraftHostingServer"
# no `address` — vault and hosting host are the same machine, so restore
# uses the local docker socket instead of ssh.
```

## 3. Install the agent

```bash
sudo install/install-agent.sh
```

Installs `mineback-agent` on PATH, writes a starter `/etc/mineback/agent.env`,
generates an SSH push key (unused in local mode, harmless), and enables the
nightly systemd timer (02:15, ±5min jitter).

## 4. Configure the agent for local push

```bash
sudoedit /etc/mineback/agent.env
```

Set:

```bash
MINEBACK_HOST_ID=mc-workshop-01
MINEBACK_VAULT=local
MINEBACK_RECIPIENTS_FILE=/etc/mineback/recipients.age
MINEBACK_SERVERS="mc1 mc2 mc3 mc4 mc5"
MINEBACK_MHS_DIR=/root/hostMC/minecraftHostingServer
```

Delete/comment out `MINEBACK_VAULT_SSH_KEY`, `MINEBACK_LOBBY`, `MINEBACK_PROXY` if
you're running standalone mode (no lobby/bungee container) — they only apply to a
BungeeCord-proxied fleet.

## 5. Enable the compat-view HTTP server

So the existing in-container `restore latest` keeps working for students:

```bash
sudo cp /root/mineback/etc/nginx/mineback-vault.conf /etc/nginx/sites-available/mineback-vault
sudo ln -s /etc/nginx/sites-available/mineback-vault /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```

Then point each container at it in `docker-compose.yml`:

```yaml
environment:
  BACKUP_URL: "http://localhost:8080/mc-workshop-01"
```

```bash
docker compose up -d --no-deps mc1 mc2 mc3 mc4 mc5
```

## 6. Enable weekly maintenance (scrub + prune)

```bash
sudo cp /root/mineback/etc/systemd/mineback-vault-maintenance.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now mineback-vault-maintenance.timer
```

By default this unit re-hashes stored artifacts, `unzip -t`s each zip, and prunes
with `--yes` — i.e. it actually deletes whatever GFS retention marks prunable every
Sunday at 04:00, matching `keep_last=1`. Drop `--yes` from the `mineback vault
prune` line in the `.service` file first if you'd rather review a dry-run report
and prune by hand.

## 7. Verify before trusting the nightly timer

```bash
mineback-agent selftest
mineback-agent snapshot --fleet --reason install-check
mineback ls --host mc-workshop-01
```

`mineback-agent.timer` is already enabled from step 3 — no further action needed
for the nightly run itself.

## Retention used in this example

```toml
[retention]
keep_last    = 1
keep_daily   = 0
keep_weekly  = 0
keep_monthly = 0
keep_reasons = ["pre-restore", "pre-version", "workshop-final"]
```

Only the newest snapshot per server is kept. `keep_reasons` snapshots (e.g. the
automatic pre-restore safety snapshot) are never pruned regardless of age, so
right after a restore you'll briefly have two snapshots on disk for that server
until the next weekly prune — expected, not a bug.
