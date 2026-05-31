# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A declarative config repo for a self-hosted homelab Docker host (originally a Raspberry Pi running Debian). There is no application source code to build or test here — the "code" is the `docker-compose.yml` stack plus host-provisioning shell scripts. Work consists of editing compose/env files and running container lifecycle commands on the host.

## Stack (docker-compose.yml)

All services share the external-named bridge network `network_landockernet` and are prefixed `con_`:

- **caddy** — reverse proxy and the only host-port binding (`:80`). Routes by `Host:` header (see `Caddyfile`) to the service containers over the internal network; services themselves publish no host ports. Plain HTTP only.
- **db_recipes / web_recipes / nginx_recipes** — a 3-container [Tandoor Recipes](https://github.com/vabene1111/recipes) deployment (Postgres 16 + Django/gunicorn app + nginx static server). `staticfiles` and `nginx_config` are shared named volumes; `web_recipes` populates them and `nginx_recipes` serves them read-only. Caddy fronts it as `recipes.local` → `nginx_recipes:80`.

Pi-hole, nginx-proxy-manager, and dashy were previously here and have been removed (Pi-hole/NPM superseded by NextDNS + Caddy); recover from git history if needed.

## LAN access: names without a local DNS server

DNS is **NextDNS** (cloud) + a Nest WiFi router with no local-DNS feature, so friendly names come from **mDNS (`.local`)**, not DNS. The Pi runs `avahi-daemon`, and the `mdns-aliases` systemd service publishes one `.local` alias per service (`avahi-publish -a -R <name>.local <ip>`, list in `mdns-aliases/aliases`) all pointing at the Pi. Caddy then routes each name to the right container. mDNS is link-local multicast — it never reaches NextDNS, so the two don't interfere. Apple/Windows/Linux-with-`nss-mdns` resolve `.local` natively; Android is not supported (and not needed here).

## Adding a service (3 explicit edits)

1. Add the container to `docker-compose.yml` (on `network_landockernet`, **no host port**; give it `env.d/<name>.env` if it needs config).
2. Add a `http://<name>.local { reverse_proxy <container>:<port> }` block to `Caddyfile`, then `make caddy-reload`.
3. Add `<name>.local` to `mdns-aliases/aliases`, then `make mdns-restart`.

## Conventions

- **Secrets live outside git.** Per-service env files live in `env.d/` (e.g. `env.d/recipes.env`); `env.d/*.env` is gitignored while `env.d/*.env.example` templates are committed. Edit the `.example` when documenting new config, and the real file (locally, never committed) when deploying.
- **Image pinning before upgrades.** When upgrading a service, the prior image digest is recorded as a commented `# image: <sha>  # current image` line above the live `image:` so a known-good version can be rolled back to. Preserve this pattern.

## Common commands

A `Makefile` wraps the common operations (run `make` / `make help` to list). Run from the repo root on the host:

```sh
make up            # bring the whole stack up (docker compose up -d)
make logs S=caddy  # follow logs for one service
make caddy-reload  # apply Caddyfile changes with no downtime
make mdns-install  # install + enable the mDNS alias service (one-time, sudo)
make mdns-restart  # re-publish after editing mdns-aliases/aliases
make backup-db     # dump the recipes Postgres DB into backups/
make update        # pull newer images and re-up
```

## Recipes DB upgrade / migration

`db-migration-commands.txt` is the runbook for a Postgres major-version bump (dump → swap data dir → restore). `pg_extract.sh <dump> <dbname>` slices a single database out of a `pg_dumpall` output. Note the dump/restore commands use `-U djangouser` / `-d djangouser` with db `djangodb`; the user/db names are easy to transpose, so copy them verbatim from the runbook.

## Host provisioning

`setup.sh` is a one-time bootstrap run as root on a fresh Debian/Pi host: installs Docker CE + compose plugin, adds the `pi` user to the `docker` group, sets up json-file log rotation, and appends cgroup memory flags to `/boot/cmdline.txt` (required for Docker memory accounting on the Pi — needs a reboot). It is idempotent-ish but intended to run once at provision time, not as part of normal deploys.
