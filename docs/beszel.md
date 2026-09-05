# Beszel: host, container and systemd monitoring

[Beszel](https://beszel.dev) watches the dockerhost itself (CPU, memory, root
disk, NVMe/SoC temperature, network, load), every Docker container on it
(CPU / memory / network history, status and health-check state, ports, logs)
and a handful of systemd units. UI: <http://beszel.local>.

## Layout

| Container | Role | Network | State |
| --- | --- | --- | --- |
| `con_beszel` | hub: web UI, SQLite history, alert rules | `network_landockernet`, fronted by Caddy | `beszel/data/` (gitignored) |
| `con_beszel_agent` | agent: collects metrics | **host** namespace (needed for real host NIC/load stats) | `beszel/agent-data/` (gitignored) |

Hub and agent talk over a unix socket in the shared `beszel_socket` volume
(`/beszel_socket/beszel.sock`), so the agent opens no TCP port and the
"only Caddy publishes a host port" rule still holds. The agent reads
`/var/run/docker.sock` (read-only) for container data and the system D-Bus
socket (read-only) for systemd units matching `SERVICE_PATTERNS` in
`docker-compose.yml` (docker, avahi-daemon, mdns-aliases, cloud-backup).

The agent only accepts a hub that signs with the key in its `KEY` env var.
That is the hub's own ed25519 public key, generated on the hub's first start,
so bringing Beszel up is a two-step bootstrap. The hub image is a bare Go
binary (no shell) and writes only the root-owned private key
`beszel/data/id_ed25519`; `make beszel-key` derives the public half on the
host with `sudo ssh-keygen -y`.

## First deploy

```sh
cp env.d/beszel.env.example env.d/beszel.env   # KEY empty for now
make up                                        # hub starts and generates its key;
                                               # the agent restart-loops until KEY is set
make beszel-key                                # prints "ssh-ed25519 AAAA..." (sudo)
$EDITOR env.d/beszel.env                       # KEY=ssh-ed25519 AAAA...
make up                                        # recreates only the agent
make caddy-reload && make mdns-restart         # beszel.local
```

Then in a browser at <http://beszel.local>:

1. Create the admin account (first-visit signup; Beszel closes open signup
   after the first user).
2. **Add System**: name `dockerhost`, Host/IP `/beszel_socket/beszel.sock`
   (the port field is ignored for a socket path). It should turn green within
   a few seconds and start charting.
3. Containers tab: expect all `con_*` and `kinboard-*` containers with a
   health column matching `docker ps`.
4. Alerts are per system in the systems table (status/offline, CPU, memory,
   disk, temperature, container health). Notification channels are Shoutrrr
   URLs under Settings → Notifications (ntfy, Pushover, Discord, email, ...);
   none is configured yet, so alerts only show in the UI.

Record the pulled image digests in the commented `# image: ...@sha256` lines in
`docker-compose.yml` (`docker inspect --format '{{index .RepoDigests 0}}'
con_beszel` / `con_beszel_agent`).

## If something is off

- **systemd panel empty** → `make logs S=beszel_agent`. D-Bus permission
  errors mean Docker's default AppArmor profile is blocking the socket:
  uncomment `security_opt: ["apparmor:unconfined"]` on `beszel_agent` in
  `docker-compose.yml` and `make up`. (The agent already holds the docker
  socket, which is root-equivalent, so this is not a meaningful widening.)
- **Root disk wrong size / shows overlay** → add
  `FILESYSTEM=nvme0n1p2__root` to the agent's `environment:`.
- **No temperature** → check `ls /sys/class/hwmon/*/name` on the host; set
  `PRIMARY_SENSOR` to the right name or drop it to let Beszel pick.
- **Agent "connection refused"/auth errors** → `KEY` in `env.d/beszel.env`
  must match `make beszel-key` exactly (one line). After editing, `make up`.
- **Start over** → `docker compose rm -sf beszel beszel_agent`, delete
  `beszel/data` and `beszel/agent-data`, then redo the bootstrap. History and
  the admin account live in `beszel/data`; nothing else depends on them, and
  they are deliberately not part of the nightly backup.

## Upgrading

Bump both `image:` tags together (hub and agent are released in lockstep),
keep the previous digest in the `# current image` comment, `make up`. Release
notes: <https://github.com/henrygd/beszel/releases>.
