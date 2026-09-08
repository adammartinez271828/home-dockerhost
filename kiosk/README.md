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
| Network | Wi-Fi only, `wlan0` MAC `e4:5f:01:33:86:d0`, SSID `Bean` (5 GHz), lease 192.168.86.206, power save off |
| Wired MAC | `e4:5f:01:33:86:cf` — gets the old `dockerhost` lease `.197` if a cable is ever plugged in |
| Access | key-only SSH from the desktop, passwordless sudo (`/etc/sudoers.d/010_kiosk-nopasswd`) |
| Old SSD | the Pi 4's previous `dockerhost` SSD is unplugged and labelled "dockerhost rollback 2026-09-05". **Never reattach it to this Pi**; with no USB boot device the Pi 4 boots the card |

What this directory holds: this README, the kiosk wrapper script, systemd
unit, PAM file, defaults example and `install.sh` that deploy it (see
*Compositor and kiosk unit*), and `install-beszel-agent.sh` (see
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

```sh
kiosk$ echo "192.168.86.37 kinboard.local" | sudo tee -a /etc/hosts
kiosk$ sudo nmcli connection modify netplan-wlan0-bean 802-11-wireless.powersave 2   # 2 = disable
kiosk$ sudo nmcli connection up netplan-wlan0-bean
```

Check: `getent hosts kinboard.local` → `192.168.86.37` even with
`sudo systemctl stop avahi-daemon.socket avahi-daemon.service` (start them
again afterwards); `/usr/sbin/iw dev wlan0 get power_save` → `Power save: off`.

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
| `cage@.service` | `/etc/systemd/system/cage@.service` (644) | the Cage wiki's unit: `User=kiosk`, `PAMName=cage`, `Conflicts=getty@%i`, `Restart=always`/`RestartSec=3`, `EnvironmentFile=-/etc/default/kinboard-kiosk`; instance `cage@tty1` |
| `pam.d-cage` | `/etc/pam.d/cage` (644) | `pam_unix` + `pam_systemd`: registers a logind session so wlroots gets the seat without root |
| `chromium-policy.json` | `/etc/chromium/policies/managed/kinboard-kiosk.json` (644) | managed Chromium policy: home page and new-tab page pinned to `http://kinboard.local/`, `URLBlocklist: *` with only `kinboard.local` / `dockerhost.local` allowed. Added 2026-09-07 after the Home key on the 2.4 GHz-dongle mini keyboard (USB `1997:2433`, `XF86HomePage`) opened Google: `--kiosk` hides the UI but keeps the shortcut, so this makes it a reload of Kinboard and stops any other key (Back, Forward, Search) leaving the dashboard. Static: change it here too if `KIOSK_URL` ever changes |
| `kinboard-kiosk.defaults.example` | `/etc/default/kinboard-kiosk` **only if absent** | the knobs below; the live copy is the kiosk's own state, so local tuning survives reinstalls (the installer does append the `KIOSK_SCREEN_*` block if it is missing) |
| `install.sh` | — | `scp` to a temp dir, `sudo install` each file, `daemon-reload`, `set-default graphical.target`, `enable cage@tty1`, `enable --now kinboard-kiosk-screen.timer`; `--restart` (`make kiosk-install R=1`) also restarts the unit. Idempotent |

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
