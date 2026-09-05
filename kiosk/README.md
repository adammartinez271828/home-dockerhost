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
| Hardware | Raspberry Pi 4 Model B, 5 V / 3 A USB-C PSU |
| Boot medium | SanDisk High Endurance 128 GB microSD (`/dev/mmcblk0p2` root) |
| OS | Raspberry Pi OS Lite 64-bit, Trixie (kernel `6.18.39+rpt-rpi-v8` at install) |
| Hostname / user | `kitchen-kiosk` / `kiosk` (`kitchen-kiosk.local` via avahi) |
| Network | Wi-Fi only, `wlan0` MAC `e4:5f:01:33:86:d0`, SSID `Bean` (5 GHz), lease 192.168.86.206, power save off |
| Wired MAC | `e4:5f:01:33:86:cf` — gets the old `dockerhost` lease `.197` if a cable is ever plugged in |
| Access | key-only SSH from the desktop, passwordless sudo (`/etc/sudoers.d/010_kiosk-nopasswd`) |
| Old SSD | the Pi 4's previous `dockerhost` SSD is unplugged and labelled "dockerhost rollback 2026-09-05". **Never reattach it to this Pi**; with no USB boot device the Pi 4 boots the card |

What this directory holds: this README now; the Phase 6 kiosk wrapper script
and its systemd unit once they exist (see *Not done yet*).

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
kiosk$ sudo apt install -y cage wlr-randr chromium rpi-chromium-mods seatd libnss-mdns avahi-daemon
```

Installed 2026-09-05: cage `0.2.0-2+rpt1+b1`, wlr-randr `0.4.1-1`, chromium
`1:152.0.7977.75-1~deb13u1+rpt1`, rpi-chromium-mods `20260211`, seatd
`0.9.1-1` (enabled and active), libnss-mdns `0.15.1-4+b1`, avahi-daemon `0.8-16`.

Check: `cage -v`, `chromium --version`; from the kiosk
`curl -s -o /dev/null -w '%{http_code}\n' http://kinboard.local/` → `200`,
`…/rest/v1/` → `401` (Kong), `…/api/health` contains `"db":true`.

## Not done yet (Phase 6 of the plan)

- `/usr/local/bin/kinboard-kiosk` wrapper (rotate with `wlr-randr`, `exec
  chromium --kiosk … --ozone-platform=wayland`), to be tracked here.
- `cage@tty1.service` as user `kiosk` with the Cage wiki's PAM stack,
  `Restart=always`; `/etc/default/kinboard-kiosk` for `KIOSK_OUTPUT`,
  `KIOSK_TRANSFORM` (90 vs 270 decided on the wall), `KIOSK_SCALE`.
- The HDMI output name has not been observed yet (bench boot was headless);
  both `card1-HDMI-A-{1,2}` reported `disconnected`. Expect `HDMI-A-1`.
- Join the kiosk to the Kinboard family from its browser, turn on kiosk mode
  for that device, and **set Kinboard's screensaver inactivity timeout to
  off first** or the wall goes dark.
- Add the kiosk to `smokeping/Targets` and reserve `.206` in Google Home.

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
