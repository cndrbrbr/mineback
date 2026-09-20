# Running a restore drill against a disposable local machine

`mineback drill` (V2 in [FEATURES.md](../FEATURES.md)) does a *real* restore —
pause a container, extract a real snapshot into it, resume, and confirm it
comes back up — into a throwaway target instead of production. This walks
through doing that against a local Debian machine that has no direct inbound
reachability from the vault (behind NAT, no port forward, no VPN): the local
machine dials out to the vault and holds a reverse SSH tunnel open, so the
vault can reach back through it as if the machine were directly reachable.

If your drill target *is* directly reachable (public IP, port-forwarded, or
on the same VPN as the vault), skip the tunnel — just add a normal
`[hosts.<id>]` block with its real address, the same way
[example3servers.md](../example3servers.md) does for meckminecraft.de/
codefield.de, and go straight to step 4.

## 0. Authorize keys in both directions

Two separate SSH connections are involved here, in opposite directions, each
needing its own key authorized — easy to do only one and get a confusing
`Permission denied` on the other.

**0a. The local machine needs to reach the vault**, to open the tunnel itself
(`ssh -R ... root@<vault>` in step 2 — that's the *local* machine connecting
*out*). On the local machine, generate a key if it doesn't have one and print
it:

```bash
[ -f ~/.ssh/id_ed25519.pub ] || ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519
cat ~/.ssh/id_ed25519.pub
```

Append that to `/root/.ssh/authorized_keys` **on the vault**, and confirm from
the local machine: `ssh root@<vault> hostname`.

**0b. The vault needs to reach the local machine**, once the tunnel is up, to
actually drive the drill (`docker -H ssh://root@localhost:<port>` in step 4 —
that's the *vault* connecting to what looks like `localhost` but is really
the local machine, through the tunnel). Print the vault's own key **on the
vault** (not the age identity — that's for decrypting secrets, unrelated):

```bash
cat ~/.ssh/id_ed25519.pub
```

Append that to `/root/.ssh/authorized_keys` **on the local machine**.
Confirming this one has to wait until the tunnel from step 2 is actually
open — there's no direct path to it yet, that's the whole reason for the
tunnel.

## 1. Build the throwaway target

On the local machine, as root:

```bash
git clone https://github.com/cndrbrbr/mineback.git && cd mineback
./drill/setup-target.sh mc1-drill
```

Builds `minecraftHostingServer`'s real spigot image into a separate,
drill-only checkout, and starts one container (`mc1-drill` by default — pass
a different name as `$1` if you want several). First boot builds Spigot via
BuildTools (several minutes, one-time only — the jar is cached on the volume
after that). No ports are published; this container is only ever reached via
`docker exec`/`docker cp` from the vault, never by a Minecraft client. Safe
to re-run — it reuses the image/volume/container if they already exist.

## 2. Open the tunnel

Still on the local machine, in its own terminal (it runs in the foreground):

```bash
./drill/tunnel.sh root@cndrbrbr.de
```

Leave it running for the duration of the drill. It prints the exact vault-side
config and command to run next.

## 3. Point the vault at it

On the vault, add (once — it's inert without the tunnel up, safe to leave in
place between drills):

```bash
sudoedit /etc/mineback/mineback.toml
```

```toml
[hosts.drill-local]
address = "ssh://root@localhost:2222"
```

## 4. Run the drill

On the vault, for whichever real host/server you want to rehearse a restore
of — this is a genuine restore of a real snapshot, so pick something whose
data you're fine overwriting on the throwaway target (which is the point):

```bash
mineback drill cndrbrbr/mc1 --to drill-local/mc1-drill
```

`DRILL OK` means the snapshot's data was extracted for real and the container
came back up and logged `Done (...)!` within mineback's own startup timeout —
the same health gate (R9) a production restore uses. Inspect the result on
the local machine (`docker exec -it mc1-drill bash`, check `/server/data`)
before tearing anything down.

## 5. Tear down

- Ctrl-C the tunnel (step 2) — nothing to clean up on the vault side, the
  `[hosts.drill-local]` entry just becomes an unreachable address again.
- On the local machine, when you're done drilling entirely:
  `docker rm -f mc1-drill && docker volume rm mc1-drill_data`. Leave the
  container running between drills if you want the fast (no-rebuild) restart
  path for the next one — restoring into it again is exactly what a drill
  does anyway, append-only on the vault side either way.
