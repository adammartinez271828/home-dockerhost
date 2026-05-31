# Dockerhost reconfiguration plan: multi-service LAN hosting

Goal: host multiple services on the Pi (`dockerhost`, `192.168.86.197`), each
reachable on the home network at its own friendly hostname over plain HTTP,
without depending on Pi-hole (removed) or local-DNS features the Nest WiFi
router doesn't have.

## Background / why this shape

The old setup had two layers: **Pi-hole** resolved `tandoor.lan` → the Pi, and
**nginx-proxy-manager (NPM)** routed by `Host:` header to the right container.
Both are gone. We rebuild the same two layers with simpler pieces:

1. **Name resolution** → **mDNS** (`.local`), via avahi already running on the Pi.
   mDNS can advertise many distinct names for one box, so `recipes.local`,
   `monitor.local`, etc. all resolve to `192.168.86.197`. mDNS traffic never
   touches NextDNS or the router's DNS — it's link-local multicast — so it
   sidesteps the whole NextDNS-mix / Nest-WiFi-has-no-local-DNS problem.
2. **HTTP routing** → **Caddy** reverse proxy on host port `:80`, routing by
   hostname to each container over the internal Docker network.

### Decisions locked in
- **Explicit** config (not auto-discovery): Caddy + a hand-maintained alias
  list. No `docker.sock`/D-Bus exposure, no helper container.
- **Plain HTTP** only. (`.local` can't get a real CA cert; self-signed would
  mean installing a root cert on every device. Not worth it for the LAN.)
- Reverse proxy = **Caddy** (retiring NPM).
- Services for now: **recipes** (Tandoor, exists) + a **network monitoring**
  service (added later, separately).

### Client requirements (name resolution)
- **Apple devices (Mac/iPhone/iPad):** work natively (Bonjour), no setup.
- **Arch dev box:** needs `nss-mdns` + `avahi` and an mDNS entry in
  `/etc/nsswitch.conf` `hosts:` line. (Tracked in the other chat thread.)
- **Android:** not needed (no important Android devices).

## Repo changes

### 1. `docker-compose.yml`
- Add a `caddy` service:
  - image `caddy:2-alpine`
  - `ports: ['80:80']` (this is the network entrypoint now)
  - mount `./Caddyfile:/etc/caddy/Caddyfile:ro`
  - named volumes `caddy_data:/data` and `caddy_config:/config`
  - on `network_landockernet`
- **Remove** the `ports: - 80:80` that was added to `nginx_recipes` — Caddy
  fronts it now; Caddy reaches it internally as `nginx_recipes:80`.

### 2. `Caddyfile` (new)
```
http://recipes.local {
    reverse_proxy nginx_recipes:80
}

# Added later, when the monitoring service exists:
# http://monitor.local {
#     reverse_proxy <monitor_container>:<port>
# }
```
- The `http://` scheme prefix disables Caddy's automatic HTTPS for that site.
- Caddy preserves the incoming `Host` header upstream, and Tandoor's
  `ALLOWED_HOSTS=*` (in `.env`) already accepts `recipes.local`, so no Tandoor
  config change is needed.

### 3. `mdns-aliases/` (new) — host-side mDNS publisher
Tracked in the repo (like `setup.sh`), installed once on the Pi. Publishes one
`.local` alias per service using `avahi-publish -a -R <name>.local <ip>`
(the `-R` flag skips the reverse PTR record so multiple names sharing one IP
don't collide).

Contents:
- `aliases` — one hostname per line, e.g. `recipes.local`. Starts with just
  `recipes.local`.
- a small script that reads `aliases` and runs an `avahi-publish` per line.
- a systemd unit (`mdns-aliases.service`) that runs the script and stays up.

### 4. Per-service env files (`env.d/`)
Split the shared root `.env` so each service owns its config (the `.d`
drop-in-directory convention):
- `env.d/recipes.env` — all Tandoor + Postgres vars (was the bulk of `.env`).
- `env.d/recipes.env.example` — tracked template (replaces the old root
  `.env_example`; `PW_PIHOLE` dropped with Pi-hole).
- Future services get their own `env.d/<name>.env`.
- `.gitignore` ignores `env.d/*.env` but keeps `env.d/*.env.example`.

### 5. `Makefile`
Common operations, run from the repo root on the Pi. `make` / `make help`
lists them: `up`, `down`, `restart`, `pull`, `update`, `ps`, `logs [S=svc]`,
`caddy-reload`, `mdns-install`, `mdns-restart`, `mdns-status`, `backup-db`.

### 6. `CLAUDE.md`
Document the proxy + mDNS architecture and the "how to add a service" steps
below.

### Decommissioned (removed from compose; recoverable from git history)
- `nginx-proxy-manager` — replaced by Caddy.
- `pihole2` — replaced by NextDNS.
- `dashy` — was already disabled; drop for now (can return later as a
  `dashy.local` service if wanted).

## How to apply (on the Pi) — see the command list in chat for the exact run

1. Pull the branch onto the Pi at `~/devel/home-dockerhost`.
2. Install `avahi-utils` (provides `avahi-publish`) — not currently installed.
3. Migrate env: `mkdir -p env.d && cp .env env.d/recipes.env` (then optionally
   drop the now-unused `PW_PIHOLE` line).
4. `make up` — brings up Caddy and recreates `nginx_recipes` without the host port.
5. `make mdns-install` — installs + enables the mDNS alias systemd service.
6. Verify from another device: `ping recipes.local` (→ 192.168.86.197), then
   open `http://recipes.local`.

## Adding a future service (the repeatable recipe) — explicit edits
1. **`docker-compose.yml`** — add the container, on `network_landockernet`,
   with **no host port** (internal only). Give it `env.d/<name>.env` if it needs config.
2. **`Caddyfile`** — add a `http://<name>.local { reverse_proxy <container>:<port> }`
   block; then `make caddy-reload`.
3. **`mdns-aliases/aliases`** — add `<name>.local`; then `make mdns-restart`.

## Validation status
- [x] mDNS can advertise multiple `.local` names for one host (avahi `-R`).
- [x] Pi's avahi-daemon is running and advertising `dockerhost.local`.
- [x] Apple devices resolve `.local` natively; Arch box fixed via `nss-mdns`.
- [x] Single flat LAN — no cross-subnet mDNS blocking.
- [ ] **Confirm Nest WiFi mesh passes mDNS/multicast between nodes** — test
      `recipes.local` from a device on a different mesh point once live.

## Open / optional (not in this pass)
- Split recipes-specific vars out of the shared `.env` into per-service env
  files as more services are added. (Leaving `.env` untouched for now.)
- Revisit HTTPS only if a future service needs it — would require switching off
  `.local` to a real owned domain + split-horizon DNS (reintroduces DNS
  complexity), so deferred.

## Notes for next session (context recovery)
- Branch: `reconfigure-dockerhost`.
- The Arch-client `nss-mdns` fix is a separate concern from this repo (it's the
  dev box, not the Pi).
- **Repo files DONE** (compose, Caddyfile, env.d/, mdns-aliases/, Makefile,
  .gitignore, CLAUDE.md). Not yet committed, not yet deployed to the Pi.
- **Remaining:** run the Pi-side command list (avahi-utils, env migration,
  `make up`, `make mdns-install`, verify), then commit.
