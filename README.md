# home-dockerhost

Declarative config for a self-hosted homelab Docker host (a Raspberry Pi running
Debian, `dockerhost` / `192.168.86.197`). There's no application code here — the
"code" is a `docker-compose.yml` stack plus a few host-provisioning scripts.

Multiple services run on the box, each reachable on the LAN at its own friendly
name over plain HTTP — without a local DNS server.

## How it works

Two layers give you `http://recipes.local` instead of a bare IP:

1. **Name resolution — mDNS (`.local`).** The Pi runs `avahi-daemon`, and the
   `mdns-aliases` systemd service publishes one `.local` alias per service (all
   pointing at the Pi). mDNS is link-local multicast, so it's resolved locally
   by the OS (macOS/iOS natively, Linux via `nss-mdns`) and **never touches
   NextDNS or the router's DNS** — no local-DNS server needed.
2. **HTTP routing — Caddy.** Caddy is the only container that binds a host port
   (`:80`). It routes by `Host:` header (see `caddy/Caddyfile`) to each service over
   the internal Docker network; the services publish no host ports themselves.

```
client ──(mDNS: recipes.local → 192.168.86.197)──▶ Pi :80 ──▶ Caddy
                                                              └─(Host: recipes.local)─▶ web_recipes:80  
```

> Plain HTTP only. `.local` names can't get a real CA cert, and self-signed
> would mean installing a root cert on every device — not worth it for a LAN.

## Services

All share the external bridge network `network_landockernet` and are prefixed `con_`.

- **caddy** — reverse proxy / network entrypoint (host port `:80`).
- **recipes** — a 2-container [Tandoor Recipes](https://github.com/vabene1111/recipes) 2.x
  deployment: `db_recipes` (Postgres 16) + `web_recipes` (the Tandoor image, whose
  built-in nginx serves the app, static and media on :80). Fronted by Caddy as `recipes.local`.
- **smokeping** — continuous latency + packet-loss grapher
  ([SmokePing](https://oss.oetiker.ch/smokeping/)). Pings WAN / gateway / DNS
  targets and renders RRD jitter graphs. Fronted by Caddy as `smokeping.local`
  (the bare host redirects to SmokePing's `/smokeping/smokeping.cgi`). Probe
  targets are the tracked `smokeping/Targets`; run `make smokeping-targets` to
  apply them. No secrets.
- **speedtest** — scheduled Ookla speedtests → download/upload/latency history
  ([Speedtest Tracker](https://github.com/alexjustesen/speedtest-tracker)).
  Fronted by Caddy as `speedtest.local`. Needs `env.d/speedtest.env` (an
  `APP_KEY` secret — copy from `speedtest.env.example` and generate the key).

## Setup on the Pi

```sh
git clone <this repo> ~/devel/home-dockerhost && cd ~/devel/home-dockerhost
sudo apt install -y avahi-utils        # provides avahi-publish
cp env.d/recipes.env.example env.d/recipes.env   # then fill in the secrets
make up                                # bring up the stack
make mdns-install                      # install + enable the mDNS alias service (sudo)
```

Then from another device: `ping recipes.local` → `192.168.86.197`, and open
`http://recipes.local`.

**Secrets** live in `env.d/<service>.env`, which is gitignored; commit changes to
the `.example` templates only. Never commit real env files.

## Common commands

A `Makefile` wraps the routine operations (run `make` to list them):

```sh
make up            # bring the whole stack up
make logs S=caddy  # follow logs for one service
make caddy-reload  # apply caddy/Caddyfile changes with no downtime
make mdns-restart  # re-publish after editing mdns-aliases/aliases
make backup-db     # dump the recipes Postgres DB into backups/
make backup-cloud  # dump + upload to Google Drive (nightly timer runs this)
make restore-test  # restore the newest cloud dump into a throwaway DB and show counts
make update        # pull newer images and re-up
```

## Backups

The recipes DB and `mediafiles/` are backed up nightly to Google Drive with
rclone, with a restore drill that never touches the live DB. Setup, daily use, and the real-restore runbook are in
[`docs/backup-restore.md`](docs/backup-restore.md).

## Local checks (pre-commit)

In place of CI, a committed `.githooks/pre-commit` validates changes locally:
`shellcheck` on the shell scripts and `docker compose config -q` on the stack.
Enable it once per clone:

```sh
make dev-setup   # enable the hook + check for shellcheck / docker compose
```

Each check skips gracefully if its tool isn't installed, and the compose check
falls back to `env.d/recipes.env.example` when the real env file is absent — so
it works on a secret-less dev clone. `scripts/setup.sh` enables the hook on the
Pi automatically. Bypass once with `git commit --no-verify`.

## Adding a service

Three explicit edits (no auto-discovery):

1. **`docker-compose.yml`** — add the container on `network_landockernet` with
   **no host port**; give it `env.d/<name>.env` if it needs config.
2. **`caddy/Caddyfile`** — add `http://<name>.local { reverse_proxy <container>:<port> }`,
   then `make caddy-reload`.
3. **`mdns-aliases/aliases`** — add `<name>.local`, then `make mdns-restart`.

## Repo layout

| Path | What it is |
| --- | --- |
| `docker-compose.yml` | the service stack |
| `caddy/Caddyfile` | reverse-proxy host→container routing (dir is bind-mounted) |
| `smokeping/Targets` | tracked SmokePing probe list (`make smokeping-targets` to apply) |
| `env.d/` | per-service env files (`*.env` gitignored, `*.env.example` tracked) |
| `mdns-aliases/` | mDNS `.local` publisher: `aliases` list, script, systemd unit |
| `Makefile` | common lifecycle commands |
| `scripts/setup.sh` | one-time host bootstrap (Docker CE, log rotation, cgroup flags, pre-commit hook) |
| `scripts/dev-setup.sh` | dev-clone bootstrap: enable pre-commit hook + check tooling |
| `.githooks/` | git hooks (pre-commit: shellcheck + `docker compose config`) |
| `scripts/db-backup.sh` | dump the DB; `--upload` ships it (+ media) to the cloud remote |
| `scripts/db-restore.sh` | restore a dump into a throwaway DB (default) or, with `--live`, the real one |
| `scripts/backup-setup-rclone.sh` | one-time creation of the `gdrive-backup` rclone remote (needs your own Google OAuth client via `GDRIVE_CLIENT_ID`/`GDRIVE_CLIENT_SECRET` — see `docs/backup-restore.md`) |
| `cloud-backup/` | systemd service + timer for the nightly backup (`make backup-install`) |
| `docs/backup-restore.md` | backup & restore runbook |
| `scripts/pg_extract.sh` | slice one DB out of a `pg_dumpall` dump |
| `docs/db-migration.md` | Postgres major-version upgrade runbook |
| `CLAUDE.md` | guidance for Claude Code in this repo |

## Notes

- **NextDNS** (cloud) handles general DNS; the Nest WiFi router has no local-DNS
  feature, which is why friendly names come from mDNS rather than DNS rewrites.
- **Android:** older versions don't resolve `.local` at all; Android 12+ usually
  can, but support is inconsistent across devices and browsers. Not relied on here
  (no important Android devices).
- Pi-hole and nginx-proxy-manager previously lived here (superseded by NextDNS +
  Caddy); recover from git history if needed.
- Before upgrading an image, the prior digest is kept as a commented
  `# image: <sha>  # current image` line above the live `image:` for rollback.
