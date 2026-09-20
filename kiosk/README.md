# Kitchen kiosk (`kitchen-kiosk`)

The wall-mounted family dashboard: a Raspberry Pi 4 driving a portrait BenQ
EW3290U 32" 4K (3840×2160, driven at 30 Hz), showing [Kinboard](../kinboard/README.md) full-screen in Chromium
under the Cage compositor. Unlike `dockerhost`, **nothing on this host comes
from cloning this repo**: it runs no containers and holds no checkout. It is a
hand-provisioned Raspberry Pi OS Lite install, so this file is the record of
how it was built and how to rebuild it. Every command below was run on
2026-09-05; the play-by-play with actual outputs is in the (untracked)
`docs/family-dashboard/PLAN.md`, Phase 5.

Host facts:

| | |
|---|---|
| Hardware | Raspberry Pi 4 Model B, on its own 5 V / 3 A USB-C PSU (the one it ran on as `dockerhost`). It briefly ran off the monitor's USB port until 2026-09-07 without a flagged under-voltage; don't repeat that: a monitor port is under-rated for load spikes and cuts power in standby, which would hard-reset the Pi once a screen-off schedule exists |
| Boot medium | SanDisk High Endurance 128 GB microSD (`/dev/mmcblk0p2` root) |
| OS | Raspberry Pi OS Lite 64-bit, Trixie (kernel `6.18.39+rpt-rpi-v8` at install) |
| Hostname / user | `kitchen-kiosk` / `kiosk` (`kitchen-kiosk.local` via avahi) |
| Network | Wi-Fi only, `wlan0` MAC `e4:5f:01:33:86:d0`, SSID `Bean` (5 GHz), lease 192.168.86.206, power save off. Watched by `kinboard-kiosk-net` (see *Wi-Fi reachability watchdog*) since 2026-09-19, because the datapath can die silently with every local indicator still reporting a healthy link |
| Wired MAC | `e4:5f:01:33:86:cf` — gets the old `dockerhost` lease `.197` if a cable is ever plugged in |
| Access | key-only SSH from the desktop, passwordless sudo (`/etc/sudoers.d/010_kiosk-nopasswd`) |
| Old SSD | the Pi 4's previous `dockerhost` SSD is unplugged and labelled "dockerhost rollback 2026-09-05". **Never reattach it to this Pi**; with no USB boot device the Pi 4 boots the card |

What this directory holds: this README, the kiosk wrapper script, systemd
unit, PAM file, defaults example and `install.sh` that deploy it (see
*Compositor and kiosk unit*), the Wi-Fi watchdog script, units and drop-ins
(see *Wi-Fi reachability watchdog*), and `install-beszel-agent.sh` (see
*Monitoring*).

## Monitoring (Beszel agent)

The kiosk reports to the Beszel hub on `dockerhost` ([docs/beszel.md](../docs/beszel.md)):
SoC temperature, memory (Chromium runs for weeks), SD-card fill, `wlan0`
throughput, and the `cage@tty1` / `NetworkManager` / `unattended-upgrades`
units. Installed 2026-09-06 by

```sh
desk$ make kiosk-beszel-install       # kiosk/install-beszel-agent.sh
```

which fetches upstream's `beszel-agent` `.deb` pinned to the hub's version
(`AGENT_VERSION` + sha256 in the script — bump both together with the
`henrygd/beszel` image tags), reads the hub's public `KEY` from
`env.d/beszel.env` on dockerhost over ssh, writes `/etc/beszel-agent.conf`
(`KEY`, `SERVICE_PATTERNS`) and enables `beszel-agent.service`. The agent
listens on **TCP 45876** on the LAN and the hub connects *to* it, so the
kiosk never needs to resolve `beszel.local`; it only answers a hub holding
the matching private key. Then, once per install, in the hub UI: **Add
System** → name `kitchen-kiosk`, host `192.168.86.206`, port `45876`.

```sh
kiosk$ systemctl status beszel-agent; journalctl -u beszel-agent -n 20   # "Starting SSH server addr=:45876" is healthy;
                                                                          # the "HUB_URL not set" warning is expected (hub-connects mode)
kiosk$ sudo cat /etc/beszel-agent.conf                                    # KEY must equal `make beszel-key` on dockerhost
desk$  sudo apt remove beszel-agent   # on the kiosk, to remove; re-run the installer to reinstall/upgrade
```

## Day-to-day

```sh
desk$ ssh kiosk@kitchen-kiosk.local                 # key auth; sudo -n works
kiosk$ /usr/sbin/iw dev wlan0 get power_save         # must say "off"; iw is not on the user PATH
kiosk$ /usr/sbin/iw dev wlan0 link                   # SSID, channel, signal
kiosk$ nmcli con show netplan-wlan0-bean             # the Wi-Fi profile Imager created
kiosk$ curl -s http://kinboard.local/api/health      # {"status":"ok",...,"db":true}
kiosk$ journalctl -b                                 # journal is in RAM; gone at reboot
```

Name resolution: `/etc/hosts` pins `192.168.86.37 kinboard.local` because
mDNS over Wi-Fi is unreliable (multicast queries get dropped by APs).
`nsswitch` is `files mdns4_minimal [NOTFOUND=return] dns`, so the pin wins.
If `dockerhost` ever changes address, update that line (the address is
DHCP-reserved in Google Home precisely so this does not happen).

## Rebuild from scratch

### 1. Flash the card (desktop, Raspberry Pi Imager)

- Device Raspberry Pi 4 → OS *Raspberry Pi OS (other)* → **Raspberry Pi OS
  Lite (64-bit)** → the SD card (check it is the USB reader, not a SATA disk).
- Customisation: hostname `kitchen-kiosk`; user `kiosk` with a password
  (stored in the password manager; SSH stays key-only); SSH on, **public-key
  only**, paste `~/.ssh/id_ed25519.pub`; Wi-Fi SSID **`Bean`** — case
  matters, see gotchas — password and country `US`; timezone
  `America/New_York`; decline Raspberry Pi Connect / telemetry.
- Imager 2.0.11.1 was used. Trixie applies these via cloud-init
  (`user-data` on `bootfs`), so they can be checked on the card before booting.

### 2. First boot and sudo

Insert the card (SSD unplugged), power on, wait ~90 s. Trixie's Imager user has
no passwordless sudo, so grant it once, interactively:

```sh
desk$ ssh kiosk@kitchen-kiosk.local 'echo "kiosk ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/010_kiosk-nopasswd >/dev/null && sudo chmod 440 /etc/sudoers.d/010_kiosk-nopasswd'
```

Check: `ssh -o BatchMode=yes kiosk@kitchen-kiosk.local 'uname -m; grep VERSION_CODENAME /etc/os-release; findmnt / -o SOURCE -n; sudo -n true && echo sudo-ok'`
→ `aarch64`, `trixie`, `/dev/mmcblk0p2`, `sudo-ok`.

### 3. Pin Kinboard's name and disable Wi-Fi power saving

The pin goes in the **cloud-init template**, not in `/etc/hosts` directly: the
Imager's user-data sets `manage_etc_hosts: true`, so cloud-init rewrites
`/etc/hosts` from the template on every boot and an appended line is silently
lost at the next reboot (see the 2026-09-19 gotcha).

```sh
kiosk$ printf '\n192.168.86.37 kinboard.local\n' | sudo tee -a /etc/cloud/templates/hosts.debian.tmpl
kiosk$ sudo cloud-init single --name update_etc_hosts --frequency always   # render it now
kiosk$ sudo nmcli connection modify netplan-wlan0-bean 802-11-wireless.powersave 2   # 2 = disable
kiosk$ sudo nmcli connection up netplan-wlan0-bean
```

Check: `getent hosts kinboard.local` → `192.168.86.37` even with
`sudo systemctl stop avahi-daemon.socket avahi-daemon.service` (start them
again afterwards); `/usr/sbin/iw dev wlan0 get power_save` → `Power save: off`.
A drop-in in `/etc/cloud/cloud.cfg.d/` does **not** work for this — datasource
user-data outranks it, as `sudo cloud-init query merged_cfg` shows.

### 4. Base config: updates, unattended upgrades, HDMI audio off, SD-wear

```sh
kiosk$ sudo apt update && sudo apt full-upgrade -y
kiosk$ sudo apt install -y unattended-upgrades && sudo dpkg-reconfigure -plow unattended-upgrades
kiosk$ sudo tee /etc/apt/apt.conf.d/52unattended-upgrades-local <<'EOT'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Origins-Pattern { "origin=Raspberry Pi Foundation,codename=${distro_codename}"; };
EOT
kiosk$ sudo sed -i 's/^dtoverlay=vc4-kms-v3d$/dtoverlay=vc4-kms-v3d,noaudio/' /boot/firmware/config.txt
kiosk$ sudo sed -i 's/^dtparam=audio=on/dtparam=audio=off/' /boot/firmware/config.txt
kiosk$ sudo mkdir -p /etc/systemd/journald.conf.d && printf '[Journal]\nStorage=volatile\nRuntimeMaxUse=32M\n' | sudo tee /etc/systemd/journald.conf.d/volatile.conf
kiosk$ sudo reboot
```

Why each line: the Pi-archive `Origins-Pattern` is needed because the kernel,
`rpi-eeprom`, `chromium` and `rpi-chromium-mods` come from
`archive.raspberrypi.com`, which Debian's default pattern (`origin=Debian`)
never matches — same fix as on `dockerhost`. `noaudio` + `audio=off` remove
the HDMI and analogue sound devices so nothing ever plays through the monitor.
Volatile journald keeps logs in RAM; with Chromium's cache also in RAM
(Phase 6 wrapper) the card sees almost no writes. `/boot/firmware/config.txt`
is the real config; `/boot/config.txt` is a stub.

Check after reboot: `aplay -l` → `no soundcards found`; `journalctl
--disk-usage` is a few MB and `ls -A /var/log/journal` is empty;
`systemctl is-enabled unattended-upgrades` → `enabled`; `sudo
unattended-upgrade --dry-run -d 2>&1 | grep 'Allowed origins'` lists both
`origin=Debian` and `origin=Raspberry Pi Foundation`.

`make kiosk-install` adds a second drop-in,
`/etc/apt/apt.conf.d/52kinboard-kiosk` (tracked as
`kiosk/apt.conf.d-kinboard-kiosk`), blacklisting **`wpasupplicant` and
`network-manager`**: an unattended upgrade of either restarts the Wi-Fi
stack under the running kiosk, which on 2026-09-19 happened nine hours
before the silent link death (no causal link proved, but not a risk worth
carrying for an unattended box). Both are therefore upgraded **by hand**,
at a reboot: `sudo apt install wpasupplicant network-manager && sudo
reboot`. Check with `apt-config dump | grep -A3 Package-Blacklist`.

### 5. Kiosk packages

```sh
kiosk$ sudo apt install -y cage wlr-randr chromium rpi-chromium-mods seatd libnss-mdns avahi-daemon fonts-noto-color-emoji
```

Installed 2026-09-05: cage `0.2.0-2+rpt1+b1`, wlr-randr `0.4.1-1`, chromium
`1:152.0.7977.75-1~deb13u1+rpt1`, rpi-chromium-mods `20260211`, seatd
`0.9.1-1` (enabled and active), libnss-mdns `0.15.1-4+b1`, avahi-daemon `0.8-16`.
Added 2026-09-07: fonts-noto-color-emoji `2.051-0+deb13u1` — Pi OS Lite ships
no emoji font (only DejaVu/Liberation), so Kinboard event titles like
"🌹 No School" rendered as tofu boxes. Chromium only sees new fonts after a
restart (`make kiosk-restart`); check with `fc-match ':charset=1f339'` →
`NotoColorEmoji.ttf`.

Check: `cage -v`, `chromium --version`; from the kiosk
`curl -s -o /dev/null -w '%{http_code}\n' http://kinboard.local/` → `200`,
`…/rest/v1/` → `401` (Kong), `…/api/health` contains `"db":true`.

## Compositor and kiosk unit (Phase 6)

The tracked files in this directory are deployed to the kiosk over ssh by
`kiosk/install.sh` (`make kiosk-install`; `KIOSK_HOST` defaults to
`kiosk@kitchen-kiosk.local`). The kiosk keeps no clone, so **edit here, then
re-run the install** — never edit the installed copies by hand.

| Tracked file | Installed as | What it is |
|---|---|---|
| `kinboard-kiosk` | `/usr/local/bin/kinboard-kiosk` (755) | POSIX-sh wrapper Cage runs: `wlr-randr` rotates (and optionally sets the mode of) the output, runs `kinboard-kiosk-screen auto` so a (re)start inside the off window stays dark, then `exec chromium --kiosk --ozone-platform=wayland …` on Kinboard with the disk cache in `$XDG_RUNTIME_DIR` (RAM) |
| `kinboard-kiosk-screen` | `/usr/local/bin/kinboard-kiosk-screen` (755) | `off` / `on` / `auto` / `status`: disables or re-enables the wlroots output (`wlr-randr --off`; `--on` re-applies transform/scale/mode). No signal → the BenQ drops into its own standby; Chromium keeps running so the page is current when the picture returns. `auto` compares the clock with `KIOSK_SCREEN_OFF/ON` and only acts on a mismatch; it also re-applies transform/scale when they drift, so an **HDMI hotplug self-heals within a minute** (unplugging makes wlroots destroy the output and the replug creates a fresh one at transform normal / scale 1 while Cage and Chromium keep running; bit us moving the display on 2026-09-07) |
| `kinboard-kiosk-screen.service` + `.timer` | `/etc/systemd/system/` (644) | minutely timer running `kinboard-kiosk-screen auto` as `kiosk` inside the Cage session (`Requisite=cage@tty1`). Idempotent, so it rides through reboots, compositor restarts, DST and knob edits with no reload |
| `kinboard-kiosk-net` + `.service` + `.timer`, `logrotate-kinboard-kiosk-net`, `apt.conf.d-kinboard-kiosk` | `/usr/local/bin/kinboard-kiosk-net` (755), `/etc/systemd/system/` (644), `/etc/logrotate.d/kinboard-kiosk-net` (644), `/etc/apt/apt.conf.d/52kinboard-kiosk` (644) | the Wi-Fi reachability watchdog and its weekly log rotation, plus the unattended-upgrades blacklist for `wpasupplicant`/`network-manager`. Minutely timer running `kinboard-kiosk-net tick` as **root** (no `Requisite=cage@tty1`: it must run even with the compositor down). See *Wi-Fi reachability watchdog* |
| `cage@.service` | `/etc/systemd/system/cage@.service` (644) | the Cage wiki's unit: `User=kiosk`, `PAMName=cage`, `Conflicts=getty@%i`, `Restart=always`/`RestartSec=3`, `EnvironmentFile=-/etc/default/kinboard-kiosk`; instance `cage@tty1` |
| `pam.d-cage` | `/etc/pam.d/cage` (644) | `pam_unix` + `pam_systemd`: registers a logind session so wlroots gets the seat without root |
| `chromium-policy.json` | `/etc/chromium/policies/managed/kinboard-kiosk.json` (644) | managed Chromium policy: home page and new-tab page pinned to `http://kinboard.local/`, `URLBlocklist: *` with only `kinboard.local` / `dockerhost.local` allowed. Added 2026-09-07 after the Home key on the 2.4 GHz-dongle mini keyboard (USB `1997:2433`, `XF86HomePage`) opened Google: `--kiosk` hides the UI but keeps the shortcut, so this makes it a reload of Kinboard and stops any other key (Back, Forward, Search) leaving the dashboard. Static: change it here too if `KIOSK_URL` ever changes |
| `kinboard-kiosk.defaults.example` | `/etc/default/kinboard-kiosk` **only if absent** | the knobs below; the live copy is the kiosk's own state, so local tuning survives reinstalls (the installer does append the `KIOSK_SCREEN_*` block if it is missing) |
| `install.sh` | — | `scp` to a temp dir, `sudo install` each file, pin the HDMI connector as connected (`video=HDMI-A-1:e` appended to `/boot/firmware/cmdline.txt`, and `echo on > /sys/kernel/debug/dri/*/HDMI-A-1/force` for the running kernel — see the 2026-09-10 gotcha), `daemon-reload`, `set-default graphical.target`, `enable cage@tty1`, `enable --now kinboard-kiosk-screen.timer`; `--restart` (`make kiosk-install R=1`) also restarts the unit. Idempotent |

Knobs in `/etc/default/kinboard-kiosk` (apply with `make kiosk-restart`; the
`KIOSK_SCREEN_*` pair is picked up within a minute with no restart):

- `KIOSK_OUTPUT` — wlroots output name; Pi 4 HDMI0 (next to USB-C) is `HDMI-A-1`.
- `KIOSK_TRANSFORM` — `90` (default; what the kitchen wall needed) or `270`:
  purely which way the monitor hangs on the arm; flip it if the page is
  upside-down.
- `KIOSK_SCALE` — the compositor output scale (`wlr-randr --scale`), an
  **integer**: `3` at native 4K (default; a 720×1280 CSS-px layout, where
  Kinboard stacks its widgets in one column and fills the height), `2` for a
  two-column 1080×1920 layout that leaves an empty band at the top; `1`
  with the 1080p fallback. Chromium's `--force-device-scale-factor` is deliberately
  not used: under Ozone/Wayland it tags a logical-size buffer with that
  scale, so Cage draws the window at 1/N size in a corner (2.25 → a third,
  2 → a half; seen 2026-09-06). Fractional values would need
  `fractional-scale-v1`, which Cage 0.2 lacks.
- `KIOSK_MODE` — unset = native 3840x2160 (the Pi 4 does 4K at 30 Hz on
  HDMI0). `1920x1080` is the escape hatch if a 2 GB Pi 4 struggles to
  composite Chromium at 4K; the monitor upscales.
- `KIOSK_URL` — `http://kinboard.local/`.
- `KIOSK_SCREEN_OFF` / `KIOSK_SCREEN_ON` — nightly screen-off window, `HH:MM`
  local time (`23:00` / `06:00` since 2026-09-07; the kiosk's zone is
  `America/New_York`, so DST just works). Overnight windows are fine; set
  either empty for always-on. Only the display sleeps: a Pi 4 has no
  suspend and no RTC to wake on, and the Pi stays on its own PSU (never the
  monitor's USB, which cuts power in standby). `make kiosk-screen S=off|on`
  overrides by hand until the next minute tick disagrees, so for a lasting
  change edit the knobs.

Day-to-day:

```sh
desk$ make kiosk-status     # systemctl status cage@tty1 + loginctl (expect a kiosk session on seat0/tty1)
desk$ make kiosk-logs       # journalctl -u cage@tty1 -f (Cage + Chromium stderr)
desk$ make kiosk-restart    # after editing /etc/default/kinboard-kiosk on the kiosk
desk$ make kiosk-screen      # display state + schedule; S=off / S=on to force, S=auto to re-apply
desk$ make kiosk-install R=1  # after editing kiosk/kinboard-kiosk, kinboard-kiosk-screen*, cage@.service or chromium-policy.json here
kiosk$ sudo -u kiosk env WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/run/user/1000 wlr-randr   # output name, modes, Transform
```

Seat access: `seatd` is installed and its socket is group `video`, which
`kiosk` is in, so libseat uses the seatd backend; the PAM/logind session is
still what gives the unit a VT. Nothing extra was needed.

Crash / reboot drill (the acceptance test; re-run after any change here):
`sudo pkill -9 chromium` — Cage exits with its child and systemd restarts
the unit within ~10 s (`systemctl is-active cage@tty1` → `active`). `sudo
reboot` — the dashboard is back with no login prompt and no cursor; compare
`systemctl show -p ActiveEnterTimestamp cage@tty1` with `uptime -s`.

Kinboard side (done once, in the web UI): Settings → Screensaver →
inactivity timeout **off** (or the wall goes dark); the kiosk joined the
family from `/join` with a USB keyboard as device **`kitchen-kiosk`**, then
Settings → Devices → `kitchen-kiosk` → **Kiosk mode** on hides the nav
drawer. Rollback: remove the device; it can rejoin with the code.

Rollback of the whole unit: `sudo systemctl disable --now cage@tty1 &&
sudo systemctl set-default multi-user.target`. Just the schedule: `sudo
systemctl disable --now kinboard-kiosk-screen.timer` (or empty a `KIOSK_SCREEN_*` knob).

## Wi-Fi reachability watchdog

Why it exists: on 2026-09-19 the kiosk passed no Wi-Fi traffic for 1½ hours
while `nmcli` said `connected`, `iw` showed the BSSID at −57 dBm and the
lease and default route were intact — it could not even ARP its own gateway
(`docs/kiosk-wifi-silent-link-death.md`). Nothing retried, because on this
hardware **nothing in the Linux stack watches the datapath**: `brcmfmac` is
FullMAC, so link monitoring lives in the firmware and it watches *beacons*,
which kept arriving. The only signal that distinguishes a live link from a
dead one is whether packets come back, so the watchdog keys on reachability
and never on NM/`iw` state.

What it does, every minute (`kinboard-kiosk-net.timer` →
`kinboard-kiosk-net tick`, as **root**):

1. If `nmcli` does not report the interface `connected`, log once and do
   nothing — NM is already retrying; this watchdog is only for the *silent*
   failure.
2. `ping -I wlan0 -c 2 -W 2 <gateway>`. Binding to the interface is
   essential: with the diagnostic Ethernet cable plugged in an unbound ping
   succeeds over `eth0` and hides the fault.
3. After `KIOSK_NET_FAILS` (5) consecutive failed minutes it **trips**: logs
   `TRIP #N`, writes a capture (below), then climbs the ladder —
   `wpa_cli -i wlan0 reassociate`, wait 15 s, re-check (`FIXED-BY
   reassociate`); else `nmcli connection down/up netplan-wlan0-bean`, wait
   20 s, re-check (`FIXED-BY down-up`); else `BOUNCE FAILED (bounces=N)`.
4. After `KIOSK_NET_MAX_BOUNCES` (3) failed bounce cycles it logs `REBOOT`,
   `sync`s and reboots — roughly 3×(5+1) ≈ 18 min after onset. Set the knob
   to `0` to never reboot. The bounce count resets after 30 min of
   continuous success.

The log is `/var/log/kinboard-kiosk-net.log` (append-only, rotated weekly ×4
by `/etc/logrotate.d/kinboard-kiosk-net`). It is written **only** on state
changes, trips and captures — never on a quiet tick — because the journal is
volatile (so evidence must reach the card) but the card is otherwise
deliberately spared. Per-boot counters live in `/run/kinboard-kiosk-net/`
(tmpfs): `state`, `fails`, `bounces`, `last_ok`, `ok_since`.

Knobs in `/etc/default/kinboard-kiosk` (picked up on the next tick, no
restart; `kiosk/kinboard-kiosk.defaults.example` documents each one):
`KIOSK_NET_IFACE` (`wlan0`), `KIOSK_NET_CONNECTION`
(`netplan-wlan0-bean`), `KIOSK_NET_TARGET` (empty = the default gateway on
that interface), `KIOSK_NET_ALSO` (`192.168.86.37` — pinged and logged in the
capture only, never gating), `KIOSK_NET_FAILS` (5), `KIOSK_NET_MAX_BOUNCES`
(3), `KIOSK_NET_LOG`.

```sh
desk$ make kiosk-net            # state / fails / bounces / target / bssid / last event
desk$ make kiosk-net S=check    # exit 0 = the datapath is alive right now
desk$ make kiosk-net S=capture  # append an evidence block by hand
desk$ make kiosk-net-log N=200  # tail the evidence log
```

**Reading a capture.** The block is delimited by `===== kinboard-kiosk-net
capture <ts> =====`. What each part settles:

- `iw station dump` — `tx failed`, `inactive time` and the rx/tx packet
  counts come from the **firmware**, unlike the netdev counters in `ip -s
  link`, which are meaningless on a FullMAC chip (the "zero TX errors"
  during the 2026-09-19 outage proved nothing). Climbing `tx failed` with a
  healthy `signal` means frames are leaving and not being ACKed.
- `iw info` / the scan block — channel, width and (if the AP publishes them)
  channel utilisation and station count, i.e. whether the AP changed
  underneath the client or is saturated.
- the debugfs `counters` / `forensics` files — brcmfmac firmware-internal
  state; the firmware's own view of a stall.
- the wpa_supplicant/NetworkManager journal tail — look for a **BSS TM**
  (802.11v steering) request just before the failure, and for whether a
  `Group rekeying completed` line was due. Either would point at the AP.
- **Which rung fixed it is itself evidence.** `FIXED-BY reassociate` (the
  client re-associates, no new key exchange with NM) points at the AP having
  forgotten or blocked the station, i.e. hypothesis 2. Only `FIXED-BY
  down-up` working, after a reassociate did not, points at a client firmware
  datapath stall cleared by a full disassociate/associate, i.e. hypothesis 3.

Rollback: `sudo systemctl disable --now kinboard-kiosk-net.timer`, or set
`KIOSK_NET_MAX_BOUNCES=0` to keep the watchdog but never let it reboot.

## Nightly compositor restart and the stale-Chromium hook

Chromium never reloads a crashed tab: a renderer crash leaves "Aw, Snap!"
on the wall until something restarts it (seen 2026-09-19 20:50, error
code 5, with Wi-Fi and Kinboard both healthy). A package upgrade under the
running browser is one known cause: the old process keeps running from the
unlinked binary while every new renderer it spawns comes from the new one.
Two blunt guards, both installed by `install.sh`:

- **`kinboard-kiosk-restart.timer`** restarts `cage@tty1` at 03:30 local
  (plus up to 5 min jitter), inside the 23:00–06:00 screen-off window, so
  the browser starts each day fresh. The wrapper re-applies the screen
  schedule on start, so the restart stays dark.
- **`kinboard-kiosk-stale-chromium`** runs from the apt `DPkg::Post-Invoke`
  hook in `/etc/apt/apt.conf.d/52kinboard-kiosk` after every apt run. If the
  oldest `chromium` process's `/proc/PID/exe` ends in ` (deleted)`, the
  binary was replaced and it restarts `cage@tty1`; otherwise it does
  nothing. `sudo kinboard-kiosk-stale-chromium --check` reports without
  acting.

Check: `systemctl list-timers | grep kinboard-kiosk-restart`;
`journalctl -u kinboard-kiosk-restart` shows the nightly runs. If the page
is stuck on "Aw, Snap!" during the day: `make kiosk-restart`.

## Gotcha hit on 2026-09-10: the screen-off schedule flashed the display back on every minute

Symptom: inside the off window the monitor woke every minute for ~45 s showing
the page sideways and washed out, then went dark again. The journal had
`HDMI-A-1 off` from the timer 420 times in one night. Cause: ~14 s after
losing signal the BenQ pulses its hotplug line as it enters standby
(`udevadm monitor` shows two DRM `change` uevents 70–225 ms apart); wlroots
treats that as unplug + replug, destroys the output and creates a fresh one,
and Cage enables it at transform normal / scale 1. The next minute tick
turned it off again, and round it went. Fix: force the connector status to
"connected" so wlroots never sees a disconnect — `video=HDMI-A-1:e` on the
kernel command line (`/boot/firmware/cmdline.txt`, backup alongside as
`cmdline.txt.bak-2026-09-11`), which `install.sh` now maintains; for the
running kernel the same is `echo on | sudo tee
/sys/kernel/debug/dri/1/HDMI-A-1/force`. Verified: after the pin the pulse
still fires but `wlr-randr` keeps `Enabled: no` through it. Side effect:
a real unplug no longer destroys the output either, so the replug just
resumes; the geometry-drift self-heal in `kinboard-kiosk-screen auto` stays
as belt and braces. Test it with `make kiosk-screen S=off` and watch
`make kiosk-screen` for a minute; the timer flips it back on at the next tick
during the day, so read the `enabled=` line before that.

## Gotcha hit on 2026-09-12: the morning picture was grainy (Chromium at 1x)

After the screen came back at 06:00 every edge was a soft staircase, as if
the page were rendered at a third of the resolution. It was: while the
output is disabled Chromium's surface sits on no output, so Chromium drops
to scale 1, and re-entering the output at scale 3 does not make it redraw.
Cage then upscales the 1x buffer 3x. A `grim` screenshot shows it (crisp
right after a compositor restart, soft again after one off/on cycle). Only
a scale *change* triggers a redraw, so `kinboard-kiosk-screen on` now
nudges the output to another scale and back two seconds after enabling
it; the page relayouts once and is crisp. Cage 0.2 has no
`wlr-output-power-management` (so `wlopm`, which would have kept the output
enabled, is not an option). To check: `grim /tmp/s.png` on the kiosk and
zoom into text.

## Gotchas hit on 2026-09-19

- **The Wi-Fi link can die silently, and nothing notices.** At 15:15 the kiosk
  stopped passing traffic and stayed that way for 1½ h, still powered and
  rendering. Every local indicator looked healthy: `nmcli` said
  `wlan0 connected`, `iw dev wlan0 link` showed the BSSID at -57 dBm, the
  `.206` lease and default route were present, and `ip -s link` counted zero
  TX/RX errors — but `ping -I wlan0 192.168.86.1` could not even ARP the
  gateway. NetworkManager and wpa_supplicant logged **nothing**, so neither
  ever retried, and the Pi never self-healed.
  The trigger is **not known**. A failed WPA group rekey was the first
  theory and is wrong: the Nest rekeys the GTK once a day at 10:48 (seen on
  the 17th, 18th and 19th), and a bad GTK cannot break the kiosk's own
  unicast ARP to the gateway anyway. The kiosk was associated to the Nest
  router itself, not a mesh point. The only Pi-side change that day was
  unattended-upgrades restarting `wpasupplicant` (2:2.10-24+rpt1) at 06:19,
  nine hours earlier; no causal link found. Details and the open hypotheses
  in `docs/kiosk-wifi-silent-link-death.md`.
  Fix in the moment: `sudo nmcli connection down netplan-wlan0-bean && sudo
  nmcli connection up netplan-wlan0-bean` — no reboot needed. Diagnosing it
  needs the temporary Ethernet cable again, and the journal is volatile, so
  get in **before** power-cycling or the evidence is gone. SmokePing's
  `kitchen_kiosk` target on the Pi is what dates the outage:
  `docker exec con_smokeping rrdtool fetch /data/path/kitchen_kiosk.rrd AVERAGE -r 300 -s -48h`.
  Durable fix, built the same day: the **[Wi-Fi reachability
  watchdog](#wi-fi-reachability-watchdog)** now pings the gateway every
  minute, bounces the link after 5 failed minutes and writes the evidence to
  `/var/log/kinboard-kiosk-net.log`, which survives a power cycle.
- **Chromium "Aw, Snap!" (error code 5) at 20:50, everything else healthy.**
  A renderer crash; Chromium leaves it on screen forever. Crash dumps land in
  `~kiosk/.config/chromium/Crash Reports/pending/`. Fix in the moment:
  `make kiosk-restart`. Durable guards: the nightly restart timer and the
  stale-Chromium apt hook (see *Nightly compositor restart*).
- **`/etc/hosts` edits do not survive a reboot.** The Imager's user-data sets
  cloud-init's `manage_etc_hosts: true`, so `/etc/hosts` is regenerated from
  `/etc/cloud/templates/hosts.debian.tmpl` at every boot. The `kinboard.local`
  pin added in step 3 was therefore wiped by the 2026-09-17 04:00
  unattended-upgrades reboot, leaving the kiosk on mDNS alone — which is why
  the screen showed `DNS_PROBE_STARTED` rather than a connection timeout once
  Wi-Fi died. Step 3 now writes the template instead.

## Gotchas hit on 2026-09-05

- **Pi 4 would not boot the card** (ACT LED dark): the EEPROM had a USB-only
  `BOOT_ORDER` from its SSD days. Fix: boot once from an EEPROM rescue card
  (Imager → *Misc utility images* → *Bootloader (Pi 4 family)* → *SD Card
  Boot*; a 2023 one on hand worked) until the green LED blinks steadily, then
  swap the OS card back. Trixie's first boot then updated the bootloader to
  2026-05-17 by itself.
- **Wi-Fi SSID is case-sensitive, and the typo is not fixable by renaming
  alone.** The SSID was entered as `bean`; NetworkManager never matched
  `Bean`. Imager stores the passphrase as a 64-hex PSK derived from
  *passphrase + SSID*, so after `nmcli con modify netplan-wlan0-bean
  802-11-wireless.ssid Bean` the handshake still failed (`WRONG_KEY`). The
  passphrase had to be re-entered:
  `read -rsp 'Bean password: ' P; echo; sudo nmcli con modify netplan-wlan0-bean wifi-sec.psk "$P"`
  (keeps it out of history). Diagnosing this needed a temporary Ethernet
  cable; the kiosk is Wi-Fi only in normal use.
- **Stale host key.** The desktop's `known_hosts` still holds the old
  `dockerhost` key for `192.168.86.197`, which the wired MAC still leases.
  Connect by name, or use `-o HostKeyAlias=kitchen-kiosk.local` by IP.
- The SD card was not blank (an old Bookworm staging image from the Pi 5's
  first setup); mount read-only and look before flashing any reused card.
