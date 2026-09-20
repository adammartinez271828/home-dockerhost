# Kitchen kiosk: silent Wi-Fi link death (2026-09-19)

Handoff for a follow-up agent. Written 2026-09-19 after diagnosing and
restoring a 1½-hour kiosk outage (15:15–16:47 EDT). Reviewed adversarially
the same evening; corrections are marked **[review]** below. Service is **restored**, and the durable fix
(a reachability watchdog) was **built the same day** — see
`kiosk/README.md`, "Wi-Fi reachability watchdog".

Read `kiosk/README.md` first for how the kiosk is provisioned — this document
assumes it.

## TL;DR

The kitchen kiosk Pi stopped passing Wi-Fi traffic at 15:15 EDT while staying
powered, associated, and rendering. Nothing on the Pi noticed, so it never
recovered on its own. Two independent faults stacked:

1. **The Wi-Fi datapath died silently** while every local health indicator
   continued to report a healthy association. Root cause not conclusively
   established — see [Root cause](#root-cause).
   **[review]** The trigger is *not* a failed group rekey (see [Root cause](#root-cause)).
2. **The `kinboard.local` pin in `/etc/hosts` was missing**, so the browser
   fell back to mDNS and showed `DNS_PROBE_STARTED`. This was a latent bug
   from the 2026-09-17 reboot, independent of fault 1. **Fixed.**

## Status

| Item | State |
| --- | --- |
| Kinboard stack (Pi 5, `dockerhost`) | Never affected; all 10 containers healthy throughout |
| Kiosk Wi-Fi datapath | Restored 16:47 EDT by bouncing the NM connection |
| Kiosk display | Restored; dashboard verified by screenshot |
| `/etc/hosts` pin persistence | Fixed at the cloud-init template; verified across re-render |
| `kiosk/README.md` updates | Written, **uncommitted** in the working tree |
| Reachability watchdog | **Built 2026-09-19** — `kiosk/kinboard-kiosk-net` + `.service`/`.timer`, deployed by `make kiosk-install`; documented in `kiosk/README.md`, "Wi-Fi reachability watchdog" |
| Trip-time evidence capture | **Built** — same script, appended to `/var/log/kinboard-kiosk-net.log` (survives the volatile journal), rotated weekly ×4 |
| Wi-Fi stack unattended upgrades | **Blacklisted** — `/etc/apt/apt.conf.d/52kinboard-kiosk` holds `wpasupplicant` and `network-manager` back; upgrade by hand at a reboot |
| Ethernet cable | Was connected for diagnosis; user asked to remove it afterwards — verify |

## Evidence

All timestamps EDT. The kiosk journal is **volatile** (`Storage=volatile`,
`kiosk/README.md`), so everything below was captured before any reboot. It is
lost on the next power cycle.

### The outage window

SmokePing on the Pi 5 probes the kiosk continuously and dates it precisely:

```
docker exec con_smokeping rrdtool fetch /data/path/kitchen_kiosk.rrd AVERAGE -r 300 -s -48h

15:10  loss=0
15:15  loss=10.3      <- degrading
15:20  loss=20 (100%)
...    100% loss continuously until recovery
```

Uptime confirmed no reboot: `up 2 days, 12:46`, single boot
`2026-09-17 04:00:06` (the unattended-upgrades reboot).

### It was the kiosk alone, not the network

Same window, other SmokePing targets — all **zero loss** throughout
15:00–15:40:

- `/data/path/nest.rrd` (Nest router)
- `/data/path/att_gateway.rrd`
- `/data/internet/google_dns.rrd`

From the desktop during the outage: no ping, no ARP entry, no mDNS record for
`kitchen-kiosk.local` or `192.168.86.206`. A full sweep of `192.168.86.0/24`
found every other host; the only Raspberry Pi OUI present was the Pi 5.

### The association looked perfect from inside the Pi

Captured over the temporary Ethernet cable, *while still broken*:

```
$ nmcli -t -f DEVICE,TYPE,STATE,CONNECTION dev
wlan0:wifi:connected:netplan-wlan0-bean

$ iw dev wlan0 link
Connected to 28:bd:89:f5:ac:b3 (on wlan0)
        SSID: Bean
        freq: 5745.0
        signal: -57 dBm
        rx bitrate: 175.5 MBit/s   tx bitrate: 325.0 MBit/s

$ ip -br addr
wlan0   UP   192.168.86.206/24 ...          # lease held
$ ip route
default via 192.168.86.1 dev wlan0 proto dhcp src 192.168.86.206 metric 600

$ ip -s link show wlan0
RX: errors 0  dropped 42895   TX: errors 0  dropped 0  carrier 0
```

Note `mode DORMANT` on the `wlan0` link line, and **zero TX/RX errors**.

### But no packets moved at all

```
$ ping -c3 -W2 -I wlan0 192.168.86.1     # gateway
3 packets transmitted, 0 received, +3 errors, 100% packet loss

$ ping -c3 -W2 -I wlan0 192.168.86.37    # Pi 5
3 packets transmitted, 0 received, +3 errors, 100% packet loss

$ ip neigh show dev wlan0
192.168.86.1   FAILED
192.168.86.37  FAILED
```

It could not even ARP its own gateway.

### Nothing was logged

`journalctl -b -u NetworkManager -u wpa_supplicant` for the whole boot. The
complete wlan0 key/association story between boot and the Ethernet cable
(**[review]** corrected — the original version of this section started at
06:19 and misread the 06:19 lines as a rekey):

```
Sep 17 04:00:22  wpa_supplicant  Key negotiation completed with 28:bd:89:f5:ac:b3 [PTK=CCMP GTK=CCMP]   <- boot, association
Sep 17 10:48:43  wpa_supplicant  Group rekeying completed  [GTK=CCMP]
Sep 18 10:48:43  wpa_supplicant  Group rekeying completed  [GTK=CCMP]
Sep 19 06:19:13  dpkg            upgrade wpasupplicant 2:2.10-24 -> 2:2.10-24+rpt1   (unattended-upgrades)
Sep 19 06:19:16  wpa_supplicant  CTRL-EVENT-DISCONNECTED reason=3 locally_generated=1  <- service restart by the upgrade
Sep 19 06:19:17  NetworkManager  device (wlan0): Couldn't initialize supplicant interface: Name owner lost
Sep 19 06:19:30  wpa_supplicant  Key negotiation completed [PTK=CCMP GTK=CCMP]; CTRL-EVENT-CONNECTED   <- re-association
Sep 19 10:48:42  wpa_supplicant  Group rekeying completed  [GTK=CCMP]
Sep 19 16:46:42  NetworkManager  device (eth0): carrier: link connected      <- the diagnostic cable
```

Nothing at or near 15:15. No deauth, no disassoc, no CTRL-EVENT, no BSS-TM
response, no `brcmfmac` kernel message (`journalctl -b -k` shows nothing
after boot-time firmware load), no undervoltage (`vcgencmd get_throttled` →
`0x0`). The only journal entries in 15:05–15:30 are the per-minute screen
timer, `cron.hourly` at 15:17 and `apt-daily` at 15:23 (which ran 3 s and
fetched nothing — its list stamps are still from 03:16). Neither NM nor
wpa_supplicant ever registered a problem, which is why nothing ever retried.

The DHCP client is not involved either: NM renewed the lease at 16:01,
03:15, 14:22, 01:18 (roughly every 11 h), so the next renewal was not due
until ~17:20 on the 19th.

### Recovery

```
sudo nmcli connection down netplan-wlan0-bean
sudo nmcli connection up   netplan-wlan0-bean
```

Immediately restored: `ping -I wlan0 192.168.86.1` → 0% loss. No reboot
needed. `cage@tty1` was then restarted and the dashboard verified with
`grim`.

## Root cause

**Established:** the datapath died in *both* directions while the association
stayed up, nothing detected it, and nothing retried. That much is directly
measured. **[review]** Also established: the kiosk was associated to the
**primary Nest router itself** (BSSID `28:bd:89:f5:ac:b3`; the gateway's LAN
MAC is `28:bd:89:f5:ac:b1`, same unit), not to a mesh point, so no wireless
backhaul was in the path. `Bean` is a **2-unit** mesh, not 4 APs: the four
BSSIDs in the scan are the 5 GHz + 2.4 GHz radios of two units
(`f5:ac:b3/b7` = router, `e5:7c:d3/d7` = the point).

**Not established:** the trigger. First occurrence in 14 days of SmokePing
history (one 0.7 % blip on 09-12, otherwise zero loss until 15:15 on 09-19).

### Hypothesis 1, failed group rekey — **refuted [review]**

The original write-up extrapolated a ~4.5 h rekey cadence from the 06:19
and 10:48 entries and predicted a rekey at ~15:17. Two errors:

- The 06:19 line is not a rekey. It is a full re-association caused by
  unattended-upgrades replacing `wpasupplicant` (`2:2.10-24` →
  `2:2.10-24+rpt1`) and restarting the service.
- The real GTK cadence is **24 h**: `Group rekeying completed` at 10:48:43
  on the 17th, 10:48:43 on the 18th and 10:48:42 on the 19th. The next one
  was due at 10:48 on the 20th, not at 15:17.

Independently of timing, a bad GTK cannot produce the observed symptom. A
station's own ARP request goes to the AP as a unicast frame encrypted with
the **PTK**, and the ARP reply comes back unicast under the PTK too. A wrong
GTK breaks *reception of other people's broadcasts* (nobody could reach the
kiosk), but `ping -I wlan0 192.168.86.1` from the kiosk would still work.
It did not: unicast was dead.

### Hypothesis 2, AP stopped forwarding for this station — **open**

The router kept beaconing (RSSI −56/−57 dBm throughout) and the client's
frames were presumably still being ACKed at the MAC layer (a FullMAC
firmware would otherwise eventually report link loss), but nothing the
kiosk sent reached the router's IP stack and nothing came back. Candidate
mechanisms on the router side, none confirmable from the client:

- station entry dropped/blocked without a deauth (Nest device pause /
  Family Wi-Fi schedule would look exactly like this — worth checking in
  the Google Home app);
- an AP-side PHY/key state change the client did not follow (channel
  width, PN/replay-counter desync);
- a Nest bug. Only the kiosk is a candidate victim because it never
  re-associates; a phone would have roamed within seconds.

### Hypothesis 3, client firmware datapath stall — **open**

`brcmfmac` is FullMAC: the association, keys and link monitoring live in
the 43455 firmware (`7.45.265`, Aug 2023). A firmware-internal TX/RX stall
with beacon tracking intact would be invisible to wpa_supplicant and NM
and would be cleared by the disassociate/associate that `nmcli connection
down/up` performs, which is exactly what happened. Nothing distinguishes
this from hypothesis 2 in the data we have.

### What changed on the Pi that day

Only two things, both by unattended-upgrades at 06:18–06:19: Chromium
`152 → 153` (upgraded underneath the running kiosk; not network-related)
and `wpasupplicant 2:2.10-24 → 2:2.10-24+rpt1` (changelog: "fix reporting
of SAE support over D-Bus"). After the restart NM began offering
`SAE FT-SAE` in `key_mgmt` alongside `WPA-PSK`, but the router advertises
PSK only and no PMF (RSN caps `0x000c`), so the negotiated `key_mgmt` is
`WPA2-PSK` before and after. No causal path is visible, but the failure
did occur on the first day running the new build — one data point.

### Pi-side configuration audit [review]

Everything checked is correct: power save disabled at the driver
(`brcmf_cfg80211_set_power_mgmt: power save disabled`, `iw ... get
power_save` → off); `wifi.scan-rand-mac-address=no` (RPi default);
regulatory domain `US`; no NM dispatcher scripts, no `conf.d` overrides,
default bgscan; no undervoltage or SDIO errors since boot; firmware and
NVRAM are the stock Raspberry Pi OS files. `mode DORMANT` on the link
line is NM's normal link mode for Wi-Fi, not a symptom. `ipv6.method=ignore`
while the kernel still does SLAAC is cosmetic. There is no misconfiguration
to fix, which is why the watchdog is the honest answer: on this hardware
nothing in the Linux stack watches the datapath, only beacons.

## Why "just make it roam" is not the fix

Considered and rejected as the primary fix. The infrastructure supports it —
the AP advertises both 802.11k and 802.11v:

```
RM enabled capabilities:  Neighbor Report
Extended capabilities:    BSS Transition
```

But **roaming is driven by radio metrics, and reachability is not one of
them.** During the outage the AP kept beaconing and the kiosk kept hearing it
at -56 dBm. Beacons are unencrypted, so neither a broken GTK nor a station
eviction degrades the perceived signal. CQM thresholds, bgscan candidate
evaluation and 802.11v steering would all have seen a healthy link and had no
reason to act.

One reading actively cuts against it: if Nest *did* try to steer the kiosk via
802.11v at 15:15 and the client ignored the request, Nest's usual fallback is
disassociation — which is hypothesis 2. Under that reading an attempted roam
is what broke it. wpa_supplicant logs BSS TM requests, so the next occurrence
will settle this.

Practical snag: NM 1.52.1 does not expose bgscan as a connection property
(`nmcli connection show netplan-wlan0-bean` has no such field); it is set
internally. Changing it means a NetworkManager config override or taking
`wlan0` out of NM's management — real complexity on a box whose value is
booting unattended.

**Verdict:** shortening the scan interval is worth doing as AP-selection
hygiene (it is on a weaker AP than necessary, and scan interruptions are
invisible on a dashboard). It is not reliability work. Do not treat it as the
fix.

## Changes already made

### On the kiosk host (not tracked in git)

1. Bounced `netplan-wlan0-bean` to restore service.
2. Appended the Kinboard pin to `/etc/cloud/templates/hosts.debian.tmpl`:

   ```
   # Pin Kinboard on the Pi 5; mDNS over Wi-Fi is unreliable (kiosk/README.md step 3).
   192.168.86.37 kinboard.local
   ```

   Verified with `cloud-init single --name update_etc_hosts --frequency
   always` that the pin survives regeneration, and that
   `getent hosts kinboard.local` → `192.168.86.37` with avahi stopped.
3. Restarted `cage@tty1`.

**Why the template and not `/etc/hosts`:** the Imager's user-data sets
`manage_etc_hosts: true` (`/var/lib/cloud/instance/user-data.txt:5`), so
cloud-init regenerates `/etc/hosts` from the template every boot. The
README's original `tee -a /etc/hosts` was wiped by the 2026-09-17 04:00
reboot. A drop-in in `/etc/cloud/cloud.cfg.d/` does **not** work — datasource
user-data outranks it; this was tried and `cloud-init query merged_cfg` still
reported `"manage_etc_hosts": true`.

### In the repo (uncommitted)

- `kiosk/README.md`: step 3 rewritten to write the cloud-init template
  instead of `/etc/hosts`; new "Gotchas hit on 2026-09-19" section covering
  both faults; new "Wi-Fi reachability watchdog" section; the unattended-upgrades
  blacklist noted in step 4.
- New `kiosk/kinboard-kiosk-net`, `kinboard-kiosk-net.service`,
  `kinboard-kiosk-net.timer`, `logrotate-kinboard-kiosk-net`,
  `apt.conf.d-kinboard-kiosk`; `kiosk/install.sh`,
  `kiosk/kinboard-kiosk.defaults.example`, `Makefile` (`kiosk-net`,
  `kiosk-net-log`) and `CLAUDE.md` updated to match.

## Open work

### 1. Reachability watchdog (the actual fix) — **done 2026-09-19**

Built as `kiosk/kinboard-kiosk-net` + `.service` + `.timer` and deployed by
`make kiosk-install`. The two open design questions were answered by the
user: threshold **5 consecutive failed minutes** (`KIOSK_NET_FAILS`), and
escalation **`wpa_cli reassociate` → `nmcli down/up` → reboot after 3 failed
bounce cycles** (`KIOSK_NET_MAX_BOUNCES=3`, `0` disables the reboot rung).
Full description, knobs and rollback: `kiosk/README.md`, "Wi-Fi reachability
watchdog".

It follows the shape sketched below, which followed the existing `kinboard-kiosk-screen` pattern exactly
(tracked script + `.service` + `.timer` in `kiosk/`, deployed by
`kiosk/install.sh` / `make kiosk-install`, knobs in
`/etc/default/kinboard-kiosk`):

- Ping the gateway (and/or `192.168.86.37`) **bound to `wlan0`** every 1–2
  minutes. Binding matters: with the diagnostic cable in, an unbound ping
  succeeds over `eth0` and hides the fault.
- After N consecutive failures, `nmcli connection down/up
  netplan-wlan0-bean`.
- Must key on **reachability**, never on NM/`iw` state — both reported
  healthy throughout this outage.

### 2. Instrumentation to settle the root cause — **done 2026-09-19**

`kinboard-kiosk-net capture` records all of the below at trip time (and can
be run by hand: `make kiosk-net S=capture`), appending a delimited block to
`/var/log/kinboard-kiosk-net.log`. **How to read the first capture** — what
`tx failed` / `inactive time` / the scan lines / the debugfs counters tell
you, and which `FIXED-BY` rung implies which hypothesis — is written up in
`kiosk/README.md`, "Wi-Fi reachability watchdog". Still to do by hand when
it next trips: check the Google Home app for a device pause or Family Wi-Fi
schedule on the kiosk at the trip time.

The watchdog records, at the moment it trips: BSSID, signal,
`iw dev wlan0 station dump` (has firmware-level `tx failed`, `inactive
time`, rx/tx packet counts — the netdev `ip -s link` counters are
meaningless for a FullMAC chip and the "zero TX errors" above proves
nothing), `iw dev wlan0 info` (channel width), `/sys/kernel/debug/ieee80211/phy0/{counters,forensics}`
(brcmfmac firmware debugfs, root), and the last few wpa_supplicant lines.
Check the Google Home app for a device pause / Family Wi-Fi schedule on
the kiosk at the trip time. **[review]** That distinguishes the two
hypotheses on the next occurrence — specifically, look for whether a
`Group rekeying` line is due/missing, and whether a BSS TM (802.11v) request
preceded the failure.

Because the journal is volatile, this must be written **to disk** to survive
a power cycle — but keep it small and append-only; the SD card is
deliberately spared elsewhere (`Storage=volatile`, Chromium cache in RAM).

### 3. Optional, low priority

Shorter bgscan interval for AP selection. See the section above for why this
is hygiene, not a fix, and for the NM 1.52 snag.

## Access and useful commands

`kitchen-kiosk.local` resolves via mDNS (192.168.86.206 over Wi-Fi). If Wi-Fi
is dead, connect Ethernet — it takes 192.168.86.197, and the desktop's
`known_hosts` holds a stale key for that address, so use:

```sh
ssh -o BatchMode=yes -o HostKeyAlias=kitchen-kiosk.local kiosk@192.168.86.197
```

**Get in before power-cycling.** The journal is in RAM; a reboot destroys the
evidence.

```sh
# Date an outage from the Pi 5
ssh pi@dockerhost.local "docker exec con_smokeping rrdtool fetch /data/path/kitchen_kiosk.rrd AVERAGE -r 300 -s -48h"

# Is the link real, or only nominally up?
ping -c3 -W2 -I wlan0 192.168.86.1
ip neigh show dev wlan0

# Restore
sudo nmcli connection down netplan-wlan0-bean && sudo nmcli connection up netplan-wlan0-bean

# Verify the display
grim /tmp/check.png     # then scp it off
```
