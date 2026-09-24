# Kiosk overnight CPU spin (03:30 → 06:00)

Investigated 2026-09-24 on `kitchen-kiosk` (Pi 4, Cage 0.3.1 / wlroots 0.20.2,
Chromium 153.0.8010.52). Times are EDT unless marked UTC.

**Status:** fix A (section 6) applied and deployed 2026-09-24 in `kiosk/kinboard-kiosk` (uncommitted at first). Verified with the E2 reproduction: restart inside a forced off window gave no Chromium process and 0.0% of one core for 30 s (was 105%); `S=on` at 13:53:31 had renderers up by 13:53:35.

## 1. Summary

- **What spins:** the Chromium **browser process main thread** and **Cage's main thread**, about 56% + 49% of one core (≈105% of a core, which Beszel shows as 25% of four cores). They ping-pong a `wl_display.sync` round trip about 6,600 times a second over the Wayland socket.
- **Why:** the wrapper runs `kinboard-kiosk-screen auto` *before* `exec chromium`. Inside the 23:00–06:00 window that disables the output, and wlroots then withdraws the `wl_output` global. Chromium's Wayland init runs `while (!WlGlobalsReady()) RoundTripQueue();`, which never waits on anything, so it spins until an output appears.
- **Start and stop:** it starts whenever Chromium starts with the output disabled, whatever restarted cage (nightly timer, `systemctl restart`, crash-style `Restart=always`) and whatever the page is (`about:blank` too). It stops the moment the output is enabled (06:00). Turning the output off on an already-running browser does not trigger it.
- **Fix (proposed, not applied):** don't start Chromium while the output is off. Either make the wrapper wait for the output before `exec chromium` (recommended), or start Chromium with the output on and apply the schedule afterwards (prototyped: 2.2%).

## 2. Timeline of observations

| When | What |
|---|---|
| 2026-09-19 21:32 | `kinboard-kiosk-restart` first runs (by hand, at deploy time). Nightly runs from 09-20 03:31. |
| 09-20 … 09-24, nightly | Beszel 120 m rows: overnight average rises from ~0.4% to 13–20%, peaks pinned at ~25.6% (a 120 m bucket straddles the 03:30 start and 06:00 stop). |
| 09-24 03:34:01 | Nightly restart. Beszel 10 m: 03:30 row 0.4%, 03:40 row 14.8% (peak 25.5%), 03:50 … 06:00 rows a flat 25.4–25.5%, memory 0.74 → 0.33 GB. |
| 09-24 06:00:01 | Screen-on. GPU process, utility processes and renderers start (`ps` lstart 06:00:01; the browser process dates from 03:34:02). 06:10 row 2.5%, 06:20 onwards 0.4–0.5%, memory 0.86 GB. |
| 09-24 13:29 | `ps` cumulative CPU of the 03:34 instance: cage **4,246 s**, browser **5,005 s** over 35,744 s. At the moment of measurement both were idle. |
| 13:30 | Baseline, screen on, page loaded: 2.6% of one core. |
| 13:31 | E1: screen off, no restart: 0.8%. |
| 13:32:10 | E2: restart with the screen forced off: **105%** (browser 56.4% + cage 48.6%), no GPU or renderer process. |
| 13:33 | strace and gdb on the spinning pair: a `wl_display.sync` loop. The registry shows no `wl_output`. |
| 13:34:31 | E3: screen on. The GPU process and renderers spawn within seconds: 3.8%. |
| 13:35:36 | E4: restart with the screen on: 1.6%. |
| 13:37:01 | E5: screen off + `KIOSK_URL=about:blank`, triggered through `kinboard-kiosk-restart.service`: **105%**. |
| 13:38:15 | E6: `pkill -9` the browser (cage exits, `Restart=always`), screen off: **105%**. |
| 13:39:35 → 13:41:05 | Stopping the E6 spinning instance hit the 90 s `stop-sigterm` timeout; systemd SIGKILLed cage (side finding). |
| 13:41:06 | Prototype of fix B (screen-off applied 20 s *after* Chromium starts): screen off, page loaded, **2.2%**. |
| 13:42:59 | Restored: tracked wrapper, no drop-ins, screen timer running, `S=auto`: 0.9%. |

## 3. Evidence

Per-thread sampling used a throwaway script (`/tmp/threadcpu.py` on the kiosk,
since removed). It reads `utime+stime` from `/proc/<pid>/task/*/stat` for every
`cage`/`chromium` process at the start and end of an interval, and prints % of
one core per process and per thread.

For experiments, the screen-off window was forced without touching tracked or
deployed config. A **runtime** drop-in (`/run/systemd/system/cage@tty1.service.d/zz-exp.conf`)
added a second `EnvironmentFile=/run/kiosk-exp.env` with
`KIOSK_SCREEN_OFF=00:00` / `KIOSK_SCREEN_ON=23:59`, so the wrapper's own
`kinboard-kiosk-screen auto` disables the output before `exec chromium`,
exactly as at 03:30. `kinboard-kiosk-screen.timer` was stopped during the
experiments so its minutely `auto` would not undo a forced state. Everything
was reverted (section 7).

### 3.1 Cumulative CPU of the overnight instance

```
$ ps -o times=,etimes= -p <pid>        # at 13:29, instance started 03:34:02
379926 cage      4246   35744
379934 browser   5005   35744
385826 gpu-proc   160   26985            # started 06:00:01
385871 renderer   131   26984            # started 06:00:01
```
Together that is ≈9,250 s of CPU. 03:34→06:00 is 8,760 s, so the pair burned
about one full core through the window, and almost nothing after it.

### 3.2 Beszel (dockerhost, read-only SQLite, `system_stats`, system `sijtxnbc8spko0w`, 10 m rows)

```
09-24 03:30 cpu=0.4  cpum=0.4   mu=0.74
09-24 03:40 cpu=14.8 cpum=25.5  mu=0.49
09-24 03:50 cpu=25.4 cpum=25.58 mu=0.33
   … 05:00–06:00 identical: cpu 25.4–25.5, cpum ≤25.68, mu 0.33 …
09-24 06:10 cpu=2.5  cpum=14.99 mu=0.88
09-24 06:20 cpu=0.5  cpum=0.65  mu=0.86
```
120 m rows show the same signature every night since 09-20 (`cpum` ≈25.6),
for example `09-23 04:50 cpu=13.3 cpum=25.66 mu=0.52`, `09-22 02:50 cpu=0.4`.

### 3.3 Controlled reproduction (before / after)

```
# Baseline: screen on, page loaded
interval 20.0s  total cage+chromium 2.6% of one core
  renderer 1.3%  gpu-process 0.7%  browser 0.4%  cage 0.0%

# E1: make kiosk-screen S=off (no restart)
interval 30.0s  total cage+chromium 0.8% of one core
  thread VizCompositorTh (gpu-process) 0.6%

# E2: runtime drop-in forces the off window; sudo systemctl restart cage@tty1 (13:32:10)
$ kinboard-kiosk-screen status
output=HDMI-A-1 enabled=no …
$ ps …   # only browser, zygotes and crashpad exist; no gpu-process, no renderer
interval 30.0s  total cage+chromium 105.0% of one core
  proc  408119 browser      56.4%
  proc  408111 cage         48.6%
  thread  408119 (408119 browser) chromium           56.4%    <- browser main thread (tid == pid)
  thread  408111 (408111 cage) cage               48.6%       <- cage main thread

# E3: make kiosk-screen S=on (13:34:31), 20 s later
408400 23 --type=gpu-process …   408402 23 --type=utility (network) …   408451/408452 23 --type=renderer …
interval 30.0s  total cage+chromium 3.8% of one core

# E4: drop-in removed, restart with the screen on
interval 30.0s  total cage+chromium 1.6% of one core

# E5: drop-in + KIOSK_URL=about:blank, sudo systemctl start kinboard-kiosk-restart.service
(browser argv ends in) about:blank
interval 30.0s  total cage+chromium 105.0% of one core
  browser 56.6%   cage 48.4%

# E6: screen still forced off; sudo pkill -9 the browser -> cage exits 137, Restart=always
NRestarts=1
interval 20.0s  total cage+chromium 105.0% of one core
  browser 56.1%   cage 48.9%
```

### 3.4 What the spinning threads do

```
$ sudo timeout 5 strace -f -c -p <browser>
% time     seconds  usecs/call     calls    errors syscall
 34.53    0.340605           5     65777     32888 recvmsg
 21.70    0.214045           6     32888           sendmsg
 15.11    0.149034           4     32888           ppoll
$ sudo timeout 5 strace -c -p <cage>
 48.87    0.389130           5     71560     35780 recvmsg
 29.97    0.238636           6     35779           sendmsg
 21.17    0.168556           4     35780           epoll_pwait
```
That is ≈6,600 send/recv pairs a second on each side, all on one fd. The
per-call trace of the browser (fd 32 is the Wayland socket):
```
sendmsg(32, "\1\0\0\0 \0\0\f\0 \3\0\0\0")            # obj 1 wl_display, opcode 0 = sync(new_id 3), 12 bytes
ppoll([{fd=32, events=POLLIN}], …) = 1
recvmsg(32, "\3\0\0\0 \0\0\f\0 \3\0\0\0  \1\0\0\0 \1\0\f\0 \3\0\0\0") = 24
                                                       # wl_callback#3.done  +  wl_display.delete_id(3)
recvmsg(32, …) = -1 EAGAIN
sendmsg(32, sync(3)) …                                 # repeats every ~0.3 ms
```
That is a `wl_display_roundtrip` in a tight loop. Cage's stack while spinning
is its normal request dispatch (`wl_display_run → wl_event_loop_dispatch →
libwayland-server → libffi → handler`): it is only answering the syncs. The
Chromium stacks from gdb were unusable (stripped, no frame pointers): libc
`recvmsg`/`ppoll` frames and unresolved addresses.

### 3.5 No `wl_output` while the output is disabled

```
$ WAYLAND_DEBUG=1 wlr-randr 2>&1 | grep 'wl_registry#.*\.global' …   # output disabled
"ext_idle_notifier_v1" … "wl_compositor" … "wl_seat" "wl_shm" … "xdg_wm_base" … "zxdg_output_manager_v1"
$ WAYLAND_DEBUG=1 wlr-randr 2>&1 | grep -c '"wl_output"'
0
```

### 3.6 The loop in Chromium's source (tag `153.0.8010.52`, the installed version)

`ui/ozone/platform/wayland/host/wayland_connection.cc`:
```cpp
  // `RoundTripQueue()` internally calls `wl_display_roundtrip_queue()`, which
  // blocks until wl_display.sync is done. Use it to ensure the required globals
  // are emitted.
  while (!WlGlobalsReady()) {
    RoundTripQueue();
  }
…
bool WaylandConnection::WlGlobalsReady() const {
  bool ready = !!compositor_;
  // Output manager must be able to instantiate a valid WaylandScreen when
  // requested by the upper layers.
  ready &= output_manager_ && output_manager_->IsOutputReady();
```
`wayland_output_manager.cc`: `IsOutputReady()` is true only if some
`wl_output` in `output_list_` is ready. With no `wl_output` global it stays
false, and each round trip returns immediately, so the loop never sleeps. On
`main` the only change is a `wl_display_get_error()` check inside the loop; there
is still no backoff. This runs in `WaylandConnection::Initialize()`, before
any window, GPU process or navigation, which is why the page is irrelevant.

### 3.7 Side finding: a spinning instance ignores SIGTERM

```
13:39:35 systemd[1]: Stopping cage@tty1.service …
13:41:05 systemd[1]: cage@tty1.service: State 'stop-sigterm' timed out. Killing.
13:41:05 systemd[1]: cage@tty1.service: Killing process 409161 (cage) with signal SIGKILL.
```
Every other stop today (non-spinning instances) took about 1 s. It was seen once (E6's
instance). The E2 instance was not stopped while spinning (E3 had already
enabled the output), so this has one data point.

### 3.8 Nightly restart history (kiosk journal)

```
Sep 20 03:31:01  Sep 21 03:32:14  Sep 22 03:30:24  Sep 23 03:31:43  Sep 24 03:34:01   Starting kinboard-kiosk-restart.service
```

## 4. Root cause by confidence

**Established** (directly measured or reproduced):
- The CPU is the Chromium browser process main thread (≈56%) plus Cage's main thread (≈49%): ≈105% of one core = Beszel's 25%.
- The two threads exchange `wl_display.sync` → `callback.done` + `delete_id` about 6.6k times a second.
- It happens if and only if Chromium starts while `HDMI-A-1` is disabled (E2, E5, E6 spin; E4 and the prototype don't). It does not depend on how cage was started (manual restart, the real nightly restart unit, crash-style restart) or on the URL (`about:blank` spins).
- Disabling the output under an already-initialised browser does not spin (E1, 0.8%). That is why 23:00 → 03:30 stayed ~0.4% before and after the restart timer existed.
- Enabling the output stops it at once and lets Chromium finish starting (GPU process + renderers appear): E3 and the 06:00 `ps` timestamps.
- With the output disabled, the compositor advertises no `wl_output` global.
- The installed Chromium's source has an unthrottled `while (!WlGlobalsReady()) RoundTripQueue();` that requires a ready `wl_output`.
- The nightly trigger: `kinboard-kiosk-restart.timer` restarts cage at 03:30–03:35, inside the window, and the wrapper runs `kinboard-kiosk-screen auto` (→ `off`) before `exec chromium`.

**Inferred** (consistent with everything, not proven by a symbolised stack):
- The browser main thread is inside that specific source loop. The syscall pattern, its location before any child process spawns, the missing `wl_output` and the exact source match all point there, but gdb could not resolve Chromium frames.
- The low memory (0.33 GB) is simply because Chromium never got past Wayland init, so no GPU process, renderer or page existed.

**Unknown:**
- Why a spinning instance ignored SIGTERM for 90 s, and whether cage or Chromium is at fault (one observation). It matters if anything restarts cage inside the window while it spins: the crash watcher, the apt hook, or a second restart.
- Whether any Chromium switch skips the output wait (none known). Not needed for the proposed fixes.

## 5. Alternatives ruled out

| Alternative | Evidence against |
|---|---|
| The page (Kinboard JS, realtime/meal_plans loop, timers) spinning while hidden | No renderer process exists during the spin (E2 `ps`). `about:blank` spins identically (E5). The spinning thread is in the browser process, not a renderer. |
| GPU process / Viz busy-looping with no output | No GPU process exists until screen-on (overnight `ps` lstart 06:00:01; E2). |
| Screen-off itself (output disabled, monitor in standby) | E1: disabling the output under a running browser gives 0.8%. Overnight 23:00–03:30 is ~0.4% every night. |
| Something special about the nightly restart unit or timer | E2 (plain `systemctl restart`) and E6 (`pkill -9` → `Restart=always`) spin the same. E4 (same restart, screen on) doesn't. |
| Crash watcher / Wi-Fi watchdog / screen timer activity | The spinning PIDs are cage and the browser only (per-thread sampling). E2–E6 ran with the screen timer stopped and still spun. The crash log has no entries on the nights in question (last entries 09-23 17:42–19:44, explained). |
| A Chromium/cage upgrade that started overnight | The onset matches the first nightly restart (09-20 03:31), and it reproduces on demand on today's binaries at 13:32. |
| Load from other processes on the kiosk | Beszel 25% ≈ the measured 105% of one core for cage+browser alone. Load average at baseline was 0.00–0.04. |
| Chromium stuck retrying the network (Kinboard unreachable at 03:30) | No utility/network process exists during the spin. The syscalls are only on the Wayland socket. `about:blank` spins too. |

## 6. Proposed fixes (not applied)

All touch the tracked `kiosk/` files and deploy with `make kiosk-install`. Each
removes the "Chromium starts with no output" condition, and each should be
verified the same way:
**(1)** reproduce as in 3.3 E2 (runtime drop-in forcing the off window, restart
cage) and expect `cage+chromium` under ~2% with `threadcpu`/`top -H`;
**(2)** the next morning, Beszel 10 m rows for 03:30–06:00 should read about 0.4%, not 25%;
**(3)** at 06:00 the dashboard shows the current page at full scale (no grainy 1× buffer).

**A. Wrapper waits for the output before `exec chromium` (recommended).**
Replace the pre-launch `kinboard-kiosk-screen auto` with: apply `auto`, then
while `kinboard-kiosk-screen status` reports `enabled=no`, `sleep 30`; then
`exec chromium`. The minutely timer turns the output on at 06:00, and Chromium
starts within 30 s.
- *For:* zero CPU overnight, and it covers **every** restart path in the window (nightly, crash watcher, apt stale-Chromium hook, reboot). No flash of the monitor. The morning experience is the same as today's, since the page already first loads at 06:00.
- *Against:* the dashboard is blank for up to ~30 s plus page load after 06:00 (or after a manual `S=on`). Chromium isn't running overnight, so the crash watcher has nothing to watch (fine). The wrapper must `exec` only after the loop so Cage still tracks Chromium as its child. A manual `make kiosk-screen S=off` followed by a restart stays browserless until `S=on`, which is intended but worth a README note.

**B. Start Chromium with the output on; apply the schedule after it connects.**
Launch `(wait until Chromium has a GPU process or ~20 s; kinboard-kiosk-screen auto) &`,
then `exec chromium`, instead of calling `auto` first. **Prototyped on the
kiosk:** a restart inside a forced off window, with a 20 s delay, gave screen off,
GPU process + renderers present, **2.2%** of one core.
- *For:* the page is loaded and warm at 06:00 (instant picture). It covers every restart path.
- *Against:* the monitor wakes briefly on each restart inside the window (03:30 nightly, and any crash restart). The kitchen gets ~20 s of light at night, and the BenQ has a standby/hotplug history (the 2026-09-10 gotcha). A fixed sleep is racy on a slow start, and polling for the GPU process is better but more code. It is also the only fix that relies on the scale-nudge in `apply on` staying correct (it already does this at 06:00 every day).

**C. Move the nightly restart outside the window.**
For example `OnCalendar=22:55` (just before screen-off) or immediately after the
06:00 screen-on.
- *For:* a one-line timer change with no wrapper logic.
- *Against:* it only fixes the nightly path. A crash-watcher or apt-hook restart between 23:00 and 06:00 still spins until 06:00 (E6). 22:55 restarts while someone may be looking, and 06:00 restarts right when the screen comes on. Best combined with A, not instead of it.

**D. Upstream / structural (longer term).**
Report to Chromium that `WaylandConnection::Initialize` busy-spins without a
`wl_output` (it should block on registry events or back off). Alternatively,
keep a wl_output advertised while dark: there is no
`wlr-output-power-management` global in Cage 0.3.1, and a headless fallback
output risks Chromium sizing the window to it.
- *For:* fixes the real defect.
- *Against:* not actionable locally or on any timescale that matters here. A headless output is untested and could break scale/rotation.

Also worth considering alongside A or B: the SIGTERM hang (3.7). If a spinning
instance is ever stopped, the stop takes 90 s. A/B make the spinning state
unreachable, so no separate change is proposed, but a `TimeoutStopSec=` on
`cage@.service` would bound it.

## 7. Cleanup performed

- Removed the runtime drop-in `/run/systemd/system/cage@tty1.service.d/zz-exp.conf` (and its now-empty directory), `/run/kiosk-exp.env`, `/tmp/kiosk-exp-wrapper` and `/tmp/threadcpu.py` on the kiosk; ran `systemctl daemon-reload`.
- Restarted `cage@tty1` on the tracked wrapper (`ExecStart … /usr/bin/cage -- /usr/local/bin/kinboard-kiosk`, `DropInPaths=` empty). The GPU process and renderers are up, and cage+chromium use 0.9% of one core.
- Restarted `kinboard-kiosk-screen.timer` (stopped during the experiments) and ran `make kiosk-screen S=auto`. Status: `enabled=yes transform=90 scale=3.000000 schedule=off@23:00 on@06:00 wanted-now=on`.
- `systemctl is-active` → active for `cage@tty1`, `kinboard-kiosk-screen.timer`, `kinboard-kiosk-restart.timer`, `kinboard-kiosk-crash.path`, `kinboard-kiosk-net.timer`.
- `systemctl list-units --all | grep -iE "run-|transient"` lists only the pre-existing `run-lock.mount`, `run-user-1000.mount` and `systemd-machine-id-commit.service`, the same as before the experiments. There are no `run-*` transient units.
- No tracked or deployed file on the kiosk or dockerhost was changed; dockerhost was only read (Beszel DB, read-only URI). Side effects left in logs: the `kinboard-kiosk-restart` journal has a 13:37:01 run (E5), and the cage journal has one SIGKILL at 13:41:05. The kiosk rebooted at no point.
- Repo: only this file is new. `docs/family-dashboard/` and `docs/kinboard-weather-12h-fix.md` were already untracked before this session.
