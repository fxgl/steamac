# steamac — Valve's official ARM64 SteamOS (the Steam Frame image) in a VM on Apple Silicon

**English** · [Русский](README.ru.md) · [简体中文](README.zh.md)

On macOS 15 (Sequoia), Valve's actual SteamOS for Steam Frame runs in a lightweight VM on
Hypervisor.framework (libkrun) with GPU acceleration via Venus.

```
game (DX9/10/11) ─ DXVK (Proton 11, x86 via FEX) ─ Vulkan
   └─ guest Mesa Venus ─ virtio-gpu (blob, 16K alignment)
        └─ libkrun ─ virglrenderer (Venus) ─ MoltenVK | KosmicKrisp ─ Metal
```

Vulkan on Metal — MoltenVK from the UTM fork (geometry shaders, robustness2) +
`VK_EXT_depth_clip_enable` (PR #2712) + our fixes, by default. KosmicKrisp (Mesa's Vulkan driver on
Metal 4) is an experimental alternative on macOS 26+ (see “Vulkan driver”).

## Requirements

- Apple Silicon Mac, macOS 15+, ~150 GB of free space (the disk image is sparse).
- Xcode 26+ (full installation: its `actool` builds the app icon from an Icon Composer document), Homebrew, rustup.
- KosmicKrisp (optional, alternative Vulkan driver): built only on macOS 26+; `host/kosmickrisp/build.sh`
  installs its Homebrew dependencies (`llvm spirv-llvm-translator spirv-tools vulkan-loader glslang`).
- OrbStack (or Docker with arm64 and `--privileged`): the kernel, Mesa, and disk image are built in Linux containers.
- Homebrew packages: `meson ninja pkg-config dtc xz lld sshpass go` (`go`: license inventory of the bundled gvproxy/desync).
- libepoxy 1.5.10 is built from pinned sources by `host/libepoxy/build.sh`, before virglrenderer and
  libkrun; all three use `MACOSX_DEPLOYMENT_TARGET=15.0`, including on macOS 26/27 build hosts.
  Bundling rejects Mach-O deployment targets above macOS 15.0 (KosmicKrisp alone may require 26.0).

## Building and running

```sh
./build.sh          # everything: MoltenVK, virglrenderer, libkrun, launcher, kernel, Mesa, disk
./run.sh            # a window with SteamOS
```

Build parts separately: `./build.sh host`, `./build.sh guest`, or the scripts in the table below.
The SteamOS image is downloaded from Valve's servers (a signed RAUC bundle); its signature and
sha256 are verified.

Guest release artifacts have adjacent `.inputs.json` build receipts binding their selected Git
working-tree inputs to their output bytes. Relevant dirty edits invalidate them; unrelated commits
do not. `host/launcher/bundle.sh` refuses missing/stale receipts before modifying the app;
`dist.sh` also validates the receipts and resources inside an existing app before packaging it.
The error names the step to rerun. To refresh guest artifacts without touching an existing SteamOS
disk: `guest/kernel/build.sh` (only when its inputs changed or its receipt is missing),
`scripts/build-image.sh builder rootfs`, `guest/mesa/build.sh`, then
`scripts/build-image.sh initramfs layer`; finally `host/launcher/build.sh`. An unstamped artifact
needs its normal build once; kernel builds reuse the build volume without `clean`.
`ALLOW_NO_VENUS=1` layers are test-only and cannot be released.

VM options: `./run.sh --display 1920x1080 --cpus 10 --mem 24576` (full list:
`work/out/steamac-vm --help`).

Frame pacing: `./run.sh --perf-stats` (or `STEAMAC_PERF_STATS=1`) prints guest-frame and on-screen
frame intervals to the terminal every 5 s (p50/p95/p99/max, number of intervals > 25 and > 50 ms).
Stutters when a new effect first appears come from Metal shader compilation (~50–100 ms per
pipeline); Metal caches the result on disk, so the effect does not stutter again, even after
restarting the game or VM (measured via Venus: 102 ms → 0.95 ms per pipeline in a new process).

Steam Shader Pre-Caching and “Allow background processing of Vulkan shaders” (Settings → Downloads)
are on by default in the VM. Pre-caching is what brings Proton the transcoded cutscene videos: Steam
downloads them per game (`steamapps/shadercache/<appid>/transcoded_video.foz`, e.g. 836 MB for
Heroes of Might and Magic: Olden Era, 3.8 GB for Diplomacy is Not an Option) and passes
`STEAM_COMPAT_TRANSCODED_MEDIA_PATH` to Proton, which plays them for videos it cannot decode itself;
with pre-caching off those videos show a placeholder. DXVK's own cache (DXVK 2.7) lives in the game's
Wine prefix and works either way. The cost: every pipeline Steam's fossilize_replay processes is
compiled by Metal on the Mac (~70–100 ms), and Steam processes again after its shader updates for a
game and, for every game, after a launcher update that changes MoltenVK (the Venus driver identity is
a hash of MoltenVK's `pipelineCacheUUID`). Background processing does most of that while Steam is
idle; what is left shows as “Processing Vulkan shaders” when a game starts and can be skipped with
**Skip**. To turn it off: Steam → Settings → Downloads → Enable Shader Pre-caching (and/or Allow
background processing of Vulkan shaders).

Stock Steam keeps background processing off (`EnableShaderBackgroundProcessing` absent from
`~/.local/share/Steam/config/config.vdf` reads as 0). Before Steam starts,
`/usr/lib/steamac/steam-shader-defaults` (ExecStartPre of `steam.service`) writes
`"EnableShaderBackgroundProcessing" "1"` to the `ShaderCacheManager` block if there is no value yet,
once per Steam installation (marker `config/steamac-shader-defaults`), so a choice made in Steam's
settings stays. Launcher 1.4 shipped both settings off (`"DisableShaderCache" "1"`,
`"EnableShaderBackgroundProcessing" "0"`); on the first Steam start after updating, the script turns
both back on once, but only if both are still exactly those values.

SteamOS takes the Mac's time zone and 12/24-hour clock format (Settings > General
**Use the Mac's time zone and clock format**, on by default, applies on the next start).
On every boot the launcher adds `steamac.tz=<IANA zone of the Mac>` (`TimeZone.current`) and
`steamac.clock24=0|1` (the localized `j` hour template, honoring macOS's **24-hour time** switch).
The initramfs points `/etc/localtime` at the zone (`timedatectl`, Steam's Time zone setting via
`steamos-set-timezone`, and Steam's clock). `/etc/steamac/mac-timezone` remembers the last applied
zone; a different zone chosen inside SteamOS stays (until it is the Mac's zone again).
Before Steam starts, `/usr/lib/steamac/mac-clock-format` updates `b24HourClock` in the account's
`userdata/<account>/config/localconfig.vdf`, at
`UserLocalConfigStore/Software/Valve/Steam/FriendsUI/FriendsUIJSON`. This is Steam's
Settings → Time and date → 24-hour clock toggle, not a client-wide setting: on a new disk the file
does not exist before sign-in, so it is applied on the first Steam start **after sign-in**.
Desktop Mode gets `[Formats] LC_TIME` in `~/.config/plasma-localerc` (`en_GB.UTF-8` for 24-hour,
`en_US.UTF-8` for 12-hour; this also selects the time/date locale). Last applied values and
independent user overrides are kept in `~/.config/steamac/mac-clock24.json`: changing the format
in Steam or Plasma stops following the Mac for that setting, without changing the other.
With the launcher setting off, no zone or format is touched. A test can explicitly supply
`--cmdline "console=hvc0 rootwait steamac.clock24=0"` (or `1`) without changing macOS settings.

Boot and shutdown progress does not disappear before `ready`: the first click or keypress in the
window collapses the full-screen overlay into a progress pill at the bottom center (stage,
percentage, bar, detail line such as `378 / 564 MB · 1.9 MB/s`; input reaches the guest). Clicking
the pill or View → Show Boot Progress expands it again; with the overlay disabled (Settings >
General), the pill appears immediately. While a new disk is being prepared or the Steam client is
being downloaded / installed, clicks and keypresses do not collapse the overlay, and an overlay
previously collapsed by clicking expands automatically (`overlay: expanded for
steam-download`); one collapsed via View → Show Boot Progress remains a pill until `ready`. Before
`ready`, the window title repeats the stage: “FX Steam Launcher — Downloading Steam update 70%”,
“— Starting Steam…”, “— Shutting down…”. The log records `overlay: collapsed to pill (click)` /
`expanded from pill`. After `ready`, if the window has had no picture for ≥ 3 s (scanout is off, or
no frame has arrived after scanout was set or resized), or the displayed frame has been black for
≥ 5 s (sparse sampling of 64 × 40 points, brightness < 8/255 for ≥ 99.5%, no more than 4 times a
second, ~3 µs), and the focus is not in a game and the guest is not asleep / paused / suspended,
the pill says “Waiting for SteamOS to draw…” with the reason, agent heartbeat, and VM CPU usage;
it disappears on the first non-black frame (`no-picture: shown after 5.0 s (black picture …)` /
`hidden after … (first non-black frame)`). Test:
`work/out/steamac-vm --selftest-pill --selftest-out DIR`.

While a game has focus (`focus game <appid>`), if the guest sends no GPU commands for 2 s (the
virtio-gpu control queue and Venus rings — `krun_gpu_get_activity` counters), a card saying “Still
working — loading or compiling shaders…” appears over the last frame with VM CPU usage; if the
guest agent has also stopped sending heartbeats (> 5 s), it says “SteamOS is not responding…”
(this applies regardless of focus). An idle Steam interface sends no GPU commands for minutes and
does not trigger the indicator. It disappears on the very next GPU command or when focus leaves the
game; every occurrence is logged (`stall: gpu idle 3.1 s (guest alive, …)`). With `--perf-stats`, a line
`perf: gpu ctrl/s=… ring/s=… longest-idle=…` is added every 5 s. Disable it in Settings > General. The agent runs in each
gamescope session (gaming and Desktop Mode): when a session ends (Switch to Desktop, Return to Gaming
Mode), no heartbeat is expected until the new session's agent sends one; while the VM is suspended or
asleep the indicator is off, and after resume, guest wake, and Mac sleep, idle and heartbeat timers
start over.

| Keys in the window | |
|---|---|
| Ctrl+Cmd+F | full screen (macOS turns on Game Mode: Info.plist declares a game — `LSApplicationCategoryType` `public.app-category.games`, `GCSupportsGameMode`, `LSSupportsGameMode`; `gamepolicyd` logs “Game mode status is now on”) |
| Ctrl+Cmd+G | manually capture / release the mouse |
| Ctrl+Cmd+P | toggle Apple's Metal Performance HUD (FPS, frame interval, GPU time, memory); also View → Show Metal Performance HUD and Settings > Display |
| Ctrl+Option | release the captured mouse |
| close window | shut down the guest (power button) |

Mouse (`--mouse auto`, by default): the SteamOS cursor follows the Mac cursor precisely. gamescope
(gaming mode) does not accept absolute coordinates, so the launcher moves it with relative deltas
without acceleration. When a game has focus in the guest (the agent sends `focus game <appid>`), the
first click captures the mouse (relative movement for mouse-look); Ctrl+Option releases it. On
returning to Steam, capture is released automatically. **Mouse** menu:
- **Capture Mouse in This Game** — auto-capture for the current game (saved by appid);
- **Auto-Capture Mouse in Games** — default for all games;
- **Capture / Release Mouse Now** — same as Ctrl+Cmd+G.

These and all other settings are in the **Settings** window (see below), domain
`es.fxgam.steamac` (`defaults read es.fxgam.steamac`); on first launch they are copied once from
the previous domain `dev.steamac.vm`. Metal stores the shader cache by app identifier, so after
changing the identifier, the first launch of games compiles shaders again (one “cold” start).
`--auto-capture on|off` overrides the default for one launch.
`--mouse tablet` — absolute tablet (gamescope ignores it, so only for other guest compositors),
`--mouse capture` — always capture on click.

Guest access: `ssh -p 2222 steamos@127.0.0.1`, password `steamos` (change via
`STEAMOS_PASSWORD=... scripts/build-image.sh disk`). The hvc0 console is in the terminal running
`run.sh`.

SSH is toggled with one switch: **Settings → Advanced → Enable SSH** (or `--ssh-port N` /
`--no-ssh`). On each boot the launcher passes `steamac.ssh=0|1`: with 0, the Mac port is not opened
at all (gvproxy without forwarding), and initramfs masks sshd in SteamOS. By default SSH is enabled
in the dev launcher (`work/out/steamac-vm`, `./run.sh`, port 2222) and disabled in
`FX Steam Launcher.app` (the `SteamacReleaseDefaults` key in Info.plist, set by `bundle.sh`). When
enabled, the launcher generates a password for user `steamos` (20 characters, SecRandomCopyBytes),
stores it in the Keychain separately for each disk (by its GPT GUID), and on the next boot passes
only its SHA-512 crypt hash to the guest (“config payload” disk, `steamac.config=1`; the guest
responds `config applied`). Settings shows the user, password (Show/Copy), ready-to-use command
`ssh -p … steamos@127.0.0.1`, status “applied / will apply on next start”, and **Regenerate Password**;
in the dev launcher, the password is generated only via the button (Docker-built disks keep
`steamos`). Disks created in the app receive a password only this way — they have no default
password. From the terminal, `steamac-vm --ssh-password <disk>` prints the user, password, and
status.

### LAN networking and Steam Remote Play

Ordinary networking uses gvproxy user-mode NAT (`192.168.127.2` in SteamOS); LAN broadcasts
do not cross that NAT. **Settings → Advanced → LAN Remote Play** (next start), or
`--lan-remote-play`, enables a launcher-side discovery relay and same-port forwards:
UDP **27031–27036**, TCP **27036–27037**, from the Mac to the guest. It is **off by default**:
enabling it exposes Steam's Remote Play services to other machines, independently of SSH.
`--no-lan-remote-play` disables it for one boot; Network off disables it too.

Allow macOS's **Local Network** permission and incoming traffic in the Mac/SteamOS firewall.
Steam Link and the Mac must be on the **same IPv4 subnet** (Wi-Fi client isolation, guest
networks, VLANs, routed discovery and IPv6-only LANs are not supported). Enable Remote Play
in guest Steam; use the Mac's LAN address for manual pairing, not `192.168.127.2`.
Quit the Mac's own Steam client if it owns these ports: the launcher never shares or steals
UDP 27036, logs conflicts as `remote-play: disabled for this boot`, and rolls back its forwards.
The Mac Steam client's own UDP 27036 broadcasts are not relayed back into the guest.

The relay preserves Steam client identity and unknown protobuf fields, replaces status
address hints with the Mac's LAN IPv4 address, and retains ports because the forwards use
the same port numbers. Guest status announcements are refreshed by real discovery queries
every five seconds (gvproxy does not export unsolicited guest-subnet broadcasts); no status
is invented when Steam does not answer. Steam may not advertise a signed-out host.
`--selftest-remote-play` checks packet parsing and address rewriting without booting a VM.
For a real LAN probe (on the Mac or a second machine), run
`python3 scripts/test/remote-play-discovery.py --bind <LAN-IP> --broadcast <subnet-broadcast> --expect-host <Mac-LAN-IP>`.
It uses an ephemeral port, prints the actual Steam reply and rewritten address, and fails if
no host answers; it does not claim pairing or streaming success.
Protocol references: [Valve's Remote Play network settings](https://help.steampowered.com/en/faqs/view/3E3D-BE6B-787D-A5D2),
[Steam remote-client protobufs](https://github.com/SteamDatabase/Protobufs/blob/master/steam/steammessages_remoteclient_discovery.proto),
and [discovery envelope framing](https://github.com/OpenSourceLAN/steam-discover/blob/master/listener.js).

## Settings window

**FX Steam Launcher → Settings…** (Cmd+, — also works when the guest has the keyboard). Each field
is labeled “applies now” (takes effect immediately) or “applies on next start” (on the next VM
start). If anything in the second group changes, **Restart VM to apply** appears at the bottom:
the guest shuts down normally via the power button, and the supervisor starts the VM again with the
new values (also available through the **Restart VM** menu item). Command-line flags take precedence
over saved values, but only for that launch: the field displays “overridden by command line
(--cpus 6)”.

| Tab | Applies now | On next start |
|---|---|---|
| General | boot/shutdown overlay; “Still working…” indicator on GPU idle; “When FX Steam Launcher is in the background”: **Mute sound** (on by default: `krun_snd_set_volume(…, mute)` with a gradual ~150 ms fade-out; volume is restored when returning to the window) and **Pause the game** (off by default: the guest agent freezes only the game in focus — `systemctl --user freeze app-steam-app<appid>-*.scope`, cgroup v2; Steam, downloads, and updates continue running; online games may disconnect). While the agent confirms the freeze (`game-frozen`/`game-thawed`), the window is dimmed, with a “Game paused · Click to resume” card and “— paused” in the title; clicking the window resumes the game and is not passed to the guest; crash reports (`--no-crash-reports`, see below); **Check for updates at startup** (on by default, see “Update check”); frame statistics logging (`--perf-stats`) | full screen at startup; **Use the Mac's time zone and clock format** (on by default, see above) |
| Display | guest follows window size; Apple's Metal Performance HUD in the upper-right corner of the window (Ctrl+Cmd+P, View → Show Metal Performance HUD); **MetalFX super resolution** (off by default): Apple's MetalFX spatial upscaler scales the guest picture to the window's pixel size whenever the window has more pixels than the guest (2× on Retina screens, scaled or fullscreen windows) instead of linear / nearest scaling; it runs on the guest frame in the launcher, so it works for every game and the Steam UI | physical size source (auto from display / DPI / mm — `--dpi`, `--display-mm`), refresh rate (`--refresh`), window size (`--display`): standard resolutions from 1280 × 800 (Steam Deck) to 3840 × 2160 (those that do not fit on the display are marked “larger than this screen”; the window is shrunk as before), “Fit to screen” (largest size for the display, recalculated on every launch), or “Custom…” (W × H fields); **Retina resolution** (optional, off by default): the guest display gets the screen's pixel density (window points × the screen's backing scale, taken at boot; the scale is lowered so no side exceeds 4094 px) at the same EDID physical size, so SteamOS scales its UI up to the same size with sharp text — but games draw 4× the pixels and each frame copy is 4× larger; recommended instead: Retina resolution off + MetalFX super resolution (a 2× upscale on Retina screens) |
| Mouse | auto-capture in games; game list (name from `appmanifest_<appid>.acf`, Default/Auto/Off, remove) | — |
| Controller | which physical controller (GameController) drives the virtual pad (first connected or selected), whether SteamOS gets a pad and what it appears as (`--no-gamepad`, `--pad`, see “Controller”), whether a DualSense is passed through as itself, swap A/B and X/Y, stick dead zone, live input test | — |
| Sound | output device (System default follows macOS, or a specific CoreAudio device), volume/mute, Low/Normal/Safe buffer — via `krun_snd_set_*` (looked up with `dlsym`; with an older libkrun the fields are disabled with an explanation) | sound (`--no-sound`) |
| Advanced | — | vCPU (`--cpus`), RAM (`--mem`), SSH enable/disable + port (`--ssh-port`, `--no-ssh`) and generated password, network (`--no-net`), disk image (`--disk`), Create New Disk…, Steam client (`--steam-client`, see “Steam client”), Vulkan driver (`--vulkan-driver`, see “Vulkan driver”) |

**VM RAM and graphics share the Mac's memory.** Automatic VM RAM is half of physical RAM
(4–16 GiB). On every boot the launcher also reserves at least 3 GiB, or a quarter of host RAM,
for macOS, other apps and driver overhead; the remainder is the GPU budget (256 MiB–16 GiB,
rounded down to 256 MiB). For a 16 GiB Mac this is 8 GiB VM + 4 GiB GPU + 4 GiB reserve;
a custom 9 GiB VM leaves 3 GiB for graphics. Settings → Advanced shows both allowances
and warns when custom VM memory leaves less than 2 GiB for graphics or exceeds the total.
Both KosmicKrisp and MoltenVK advertise this budget through Venus's device-local heap and,
when enabled, `VK_EXT_memory_budget`; zink's GL memory queries and DXVK/vkd3d therefore see
the same smaller heap instead of the entire Mac's unified RAM (STEAMAC-S).
`steamac.gpu_mib=` also updates Steam's VRAM-report layer. This guides games' texture budgets;
it is not a hard allocation cap and cannot prevent every OOM if a game ignores it or other
Mac apps consume the reserve. Lower VM RAM or texture settings in that case.
For a throwaway-VM check, `--cmdline '… steamac.gpu_mib=3072'` overrides both host and guest
reporting; `host/virglrenderer/test/memory_budget.c` queries heaps/budgets and fills real GPU
buffers up to the advertised heap (run with `VN_DEBUG=mem_budget` to expose the budget extension;
Venus leaves it disabled by default). Never run the allocation test on the developer's disk.

**More room for games:** free space on the Mac is not automatically free space inside SteamOS.
The home capacity is fixed when a disk is created. **Settings → Advanced → Grow Disk…** increases
it without recreating the disk or deleting games (grow only, up to 4096 GiB). For the running disk,
**Grow and Restart** shuts SteamOS down normally, takes the disk's exclusive lock while the VM is
stopped, enlarges the image, then boots again. SteamOS grows the last home partition with
`systemd-repart`, then its ext4 filesystem with `x-systemd.growfs`, before using it. Other launchers
must be stopped too; suspended VMs still own their disks. APFS / Mac OS Extended consume added space
only as SteamOS writes; exFAT allocates the full added capacity immediately, so growth checks its
free space first. Terminal, with SteamOS stopped:
`work/out/steamac-vm --grow-disk /path/to/steamos.img --home-gib 128`.

For tests: `STEAMAC_DEFAULTS_DOMAIN=<domain>` substitutes the settings domain; `--selftest-settings
--selftest-out DIR` opens the window without a VM and writes a PNG of each tab; `--control-fifo` has
`settings TAB`, `settings-dump PNG`, `set KEY VALUE` (as from the window), `restart`.

## Suspend

**How:** Settings → General → “When closing the window” → **Suspend** — closing the window then
suspends the VM instead of shutting it down; or use **FX Steam Launcher → Suspend** (Ctrl+Cmd+S,
works even when the guest has the keyboard). `krun_pause` (libkrun patch 0016) stops all vCPUs and
guest audio, the window is hidden, and a ⏸ icon appears in the menu bar: “SteamOS suspended”,
since when and how much memory is in use, **Resume**, **Shut Down SteamOS**. A suspended VM uses
no CPU (~0%); the Mac can sleep.

**Resume:** click the Dock icon, relaunch the app (Finder, `open`, `open -a`), use the menu bar
icon, or choose **Resume** from the menu. The window returns (including full-screen mode, if it was
active), mouse capture is restored; the “Resuming…” progress pill stays until the first new guest
frame (if the guest GPU is idle, as with a static Steam interface, 0.5 s; at most 2.5 s).

**Clocks:** the guest's monotonic clock does not see the pause (libkrun shifts the virtual timer,
as QEMU does) — the sched_ext scheduler and watchdogs do not fire. Immediately after resume,
`fx-clock-sync.service` sets the wall clock (a root service in the layer, using the same
`fx-progress-agent clock-sync` binary, started by udev when the port appears): the launcher writes
its time as `time <unix_ns>` to the virtio port `fx.clock`; the service adjusts only
CLOCK_REALTIME (`clock_adjtime(ADJ_SETOFFSET)`, only forward and only if it lags by more than 1 s).
After that adjustment, timesyncd synchronizes on its own.

**Quit:** Cmd+Q / Dock → Quit while suspended asks “SteamOS is suspended”: **Shut Down SteamOS**
(the guest resumes and shuts down normally) or **Cancel** (it remains suspended). Logging out,
restarting, and shutting down the Mac do not prompt.

**Limitations:** the state lives only in memory while FX Steam Launcher is running — it is not
saved to disk (guest memory and host GPU state — virglrenderer, MoltenVK, Metal — are not
serialized). Quitting the app, an app crash, logging out, or shutting down the Mac is an ordinary
SteamOS shutdown; unsaved game progress is lost. All guest memory remains occupied while the VM
is suspended. Guest network connections (online games, downloads) may drop and reconnect after a
long pause.

## SteamOS sleep

Steam → Power → **Sleep**, Steam's idle auto-sleep (Settings → Power → “Sleep after”, 1 hour by
default), and `systemctl suspend` in the guest do not put the guest kernel to sleep (there is
nothing to wake s2idle in a VM — SteamOS previously hung this way until the app exited). The layer
replaces `ExecStart` in `systemd-suspend.service` (and `systemd-suspend-then-hibernate` /
`systemd-hybrid-sleep` likewise; hibernation is disabled in `sleep.conf.d`) with
`fx-progress-agent sleep`: it runs the `system-sleep` hooks (`pre`), writes
`sleep <action> <token>` to the virtio port `fx.sleep`, and waits for a response. The launcher
suspends the VM (`krun_pause`, as with Suspend — CPU ~0%, the Mac can sleep), but the window stays
open: a “SteamOS is sleeping” card overlays the frame. A click, keypress, gamepad button, or Dock
icon wakes it: `krun_resume`, `wake <token> <unix_ns>` is sent to the guest, the command adjusts
the wall clock (as with clock-sync), runs the `post` hooks, and exits — logind sends
PrepareForSleep(false), Steam wakes; the “Waking up…” progress pill stays until the first frame.
The click or keypress that woke the guest is not passed to the guest.

Closing the window during sleep follows “When closing the window”: Suspend hides the window
(Resume subsequently wakes it too); Shut Down / Cmd+Q wakes the guest and presses the power
button once the guest's sleep task has finished (`awake <token>`; logind ignores the button while
it is running). Without the port (`--headless`, old launcher), guest sleep fails instead of
sleeping.

For tests with `--control-fifo`: `close`, `suspend`, `resume` (also wakes a sleeping guest),
`reopen`, `quit`, `wake` (like waking the Mac), `quit-prompt shutdown|cancel|dump PNG`,
`status open|close|dump PNG|item TITLE`.

## Desktop Mode

Steam → Power → **Switch to Desktop** starts KDE Plasma; the desktop's **Return to Gaming Mode** icon
goes back. On the Steam Frame image this mode is a VR desktop (`plasma-session.target` wants
SteamVR, which the VM masks), so the layer replaces it: `plasma-session.target` and
`steamac-nested-desktop.service` run Plasma as one KWin window inside the same gamescope
(`/usr/lib/steamac/nested-desktop`, like Valve's `steamos-nested-desktop`), sized to the display, so
gamescope shows it 1:1. `gamescope-onready` waits for that service: when Plasma exits, the session
ends and SDDM logs back in. Plasma gets its own runtime directory and D-Bus session bus; the layer's
`steamosctl` shim (`/usr/lib/steamac/desktop-bin`, first in its PATH) sends SteamOS commands such as
Return to Gaming Mode to the outer session bus, where steamos-manager runs. The desktop's Steam
autostart (`/usr/lib/steamac/desktop-xdg/autostart/steam.desktop`) keeps the client chosen in the
launcher instead of the stock `-deckard` (Frame client), which would download the other client on
every switch. The progress agent reports `focus desktop <w>x<h>` (the Plasma window): the launcher
keeps the relative pointer and maps it onto that window as gamescope scales it, and a boot straight
into Desktop Mode (`steamos-session-select plasma-persistent`) reports `ready` when the desktop is up.

Flatpak apps (Discover) run in bubblewrap, which mounts its own procfs in a user namespace. The kernel
allows that only while some procfs in the mount namespace is fully visible, and the initramfs binds
the synthesized `/proc/cmdline` over the real one; so it also mounts an untouched procfs at
`/run/steamac/proc` (`nosuid,nodev,noexec`). Without it every Flatpak app exits with `bwrap: Can't mount
proc on /newroot/proc: Operation not permitted`.

## Clipboard

Settings → General → **Share clipboard with SteamOS** (on by default, applies now): text (UTF-8)
and PNG images copied on the Mac can be pasted in SteamOS (Ctrl+V — in Steam's text fields, games
and Desktop Mode apps) and the other way round; limits 1 MiB of text and 16 MiB per image (larger
items are skipped with a log line). Items that password managers mark as concealed or transient
(`org.nspasteboard.ConcealedType` / `TransientType`) stay on the Mac unless **Include concealed
(password manager) items** is on. The launcher checks the pasteboard's `changeCount` on a 0.5 s
timer only while the app is active and the VM runs, and once on every activation — never in the
background, while suspended or asleep; images from SteamOS land on the Mac as PNG + TIFF.

Transport: the virtio-console port `fx.clipboard`, framed binary messages (`HELLO` / `STATE` /
`SET` with sequence numbers / `ACK`; `host/launcher/Sources/steamac-vm/Clipboard.swift`,
`guest/progress-agent/src/clipboard.rs`). In the guest the user service
`fx-clipboard-agent.service` (`fx-progress-agent clipboard`, wanted by the gaming and the Desktop
Mode session) owns and watches `CLIPBOARD` (XFixes; TARGETS, UTF8_STRING, text/plain;charset=utf-8,
TEXT, STRING, image/png, INCR above 256 KiB) on **both** gamescope Xwayland servers (`:0` Steam,
`:1` games): gamescope syncs plain text between them itself by taking the selection over, but not
images or INCR-sized text. In Desktop Mode it also uses the Plasma session's Wayland clipboard
through `zwlr_data_control_manager_v1` (`ext_data_control_manager_v1` if present); KWin bridges it
to X11 apps there while an X11 window is active. Echo suppression is by content: each side
remembers the content it last sent or took over, so one copy is one transfer however often
gamescope, KWin or Klipper re-announce it. The selection present when a display appears (e.g.
Klipper's restored history) is not sent to the Mac; the shared content is offered there instead.
`--control-fifo` has `chord KEYCODE ctrl` (e.g. `chord 9 ctrl` = Ctrl+V in the guest) and
`set shareClipboard on|off`.

## Controller

Any controller macOS's GameController framework supports (Xbox, DualSense, DualShock 4, MFi, …)
drives one gamepad in SteamOS; Settings → Controller picks which one. The pad is not a virtio-input
device: the launcher sends it over the virtio-console port `fx.pad` to the guest's root service
`fx-pad.service` (`fx-progress-agent pad`, started by udev when the port appears), which creates it
with uinput. So it follows the Mac while the VM runs: it appears when a controller connects (Steam
shows “Controller Connected”), disappears when the last one goes, and changes kind with it.
Settings → Controller → **Appears in SteamOS as** (`--pad auto|xbox360|dualsense|dualshock4` for
one run):

- **Automatic** (default): the same kind as the controller that drives it — DualSense (or Edge) →
  DualSense, DualShock 4 → DualShock 4, anything else → Xbox 360 controller;
- **Xbox 360 controller**: what the kernel's `xpad` driver exposes (`045e:028e`);
- **DualSense** / **DualShock 4**: what `hid-playstation` / `hid-sony` expose for a USB pad
  (`054c:0ce6` / `054c:09cc`, version `0x8111`, face buttons by position, digital L2/R2 besides the
  analog triggers). Steam's SDL maps it as a PS5 / PS4 controller and shows PlayStation glyphs.

**Rumble.** The pad has `FF_RUMBLE`, like the real drivers, so SDL and Steam rumble it — games
through Steam Input reach it via Steam's virtual Xbox pad. uinput leaves playback to its user-space
driver: `fx-pad` implements the kernel's ff-memless rules (delay, length, repetitions, re-upload,
effects adding up) and sends the combined level, `rumble <strong> <weak>`, to the launcher, which
plays it with GameController haptics: the strong motor on the left handle, the weak one on the
right (one level everywhere on controllers without separate handles); nothing while the VM is
paused. Port protocol: `guest/progress-agent/src/pad.rs`. Touchpad, gyro, lightbar and adaptive
triggers are HID features of the real controller that this evdev device does not carry.

**DualSense passthrough.** When a DualSense (or Edge) drives the pad and it appears as a
DualSense, Settings → Controller → **Pass a DualSense through** (on by default, applies now) gives
SteamOS the controller itself instead of the uinput pad. The launcher opens it as a raw HID device
(IOHIDManager, without seizing it: GameController still selects it and wakes a sleeping guest) and
`fx-pad` recreates it with `/dev/uhid`: same report descriptor, vendor/product, and USB or Bluetooth
bus. The guest's `hid-playstation` driver binds to it as to a plugged-in controller (gamepad,
touchpad, motion sensors, lightbar and player LEDs, mute LED) and Steam uses its own HIDAPI
DualSense driver on `/dev/hidraw*`, so Steam Input gets touchpad, gyro and the mute button, and
drives rumble, lightbar and adaptive triggers itself. Input reports go to the guest as they are
(`hid-input`); output reports, GET_REPORT and SET_REPORT go back to the controller (`hid-output`,
`hid-get` / `hid-get-reply`, `hid-set` / `hid-set-reply`, hex with the report ID first). While the
guest falls behind, older input reports are dropped instead of queued: each carries the whole
state. Swap A/B and the stick dead zone do not apply to a passed-through controller. GameController
does not say which HID device a controller is: with several DualSenses connected, the first one
found is passed through. Older guest layers without `caps hid` keep getting the uinput pad.

`--control-fifo` test commands: `pad on` (a pad without a controller, as `--input-selftest` uses),
`pad off`, `pad test` (A + left stick), `pad state` (the guest's pad, its last rumble level, whether
the guest takes HID devices, connected DualSenses and input reports passed through).

## FX Steam Launcher.app

`host/launcher/build.sh` (and `./build.sh host`) builds `work/out/FX Steam Launcher.app` in
addition to `work/out/steamac-vm` (`host/launcher/bundle.sh`): `es.fxgam.steamac`, libraries
(libkrun, libvirglrenderer, libMoltenVK, libepoxy) in `Contents/Frameworks` via `@rpath`, and in
`Contents/Resources` — gvproxy, the `Image` kernel, `initramfs.cpio.gz`, `steamac-layer.img`,
desync, and Valve's CA for disk creation (licenses are in `Resources/licenses`); the icon:
`host/launcher/AppIcon.icon` (an Icon Composer document) is compiled by `actool` into `Assets.car`
(Liquid Glass on macOS 26, ready-made renders for macOS 15), with a fallback `AppIcon.icns`;
ad-hoc signing with hypervisor + disable-library-validation entitlements. The app can be moved to
`/Applications`.

Launching from Finder (without arguments) uses the kernel, initramfs, and layer from the bundle,
and the SteamOS disk from Settings → Advanced → Disk image. By default:
`~/Library/Application Support/es.fxgam.steamac/steamos.img`; otherwise, the repository's
`work/out/steamos.img` (next to the bundle or where it was built). If there is no disk, a
first-launch window offers **Create New Disk…** (see the next section) or **Use Existing Disk…**
(the image is used in place and never copied; `scripts/build-image.sh` also builds one). In this
mode, the guest console and launcher log are written to
`~/Library/Logs/es.fxgam.steamac/steamac-vm.log`; SIGUSR1 frame dumps go there too. `./run.sh`
and `work/out/steamac-vm` work as before (window settings also apply to them unless overridden by
flags).

If the image is on an external disk, on the first launch from Finder macOS asks “FX Steam Launcher
would like to access files on a removable volume” — allow it (the VM waits for the disk to open
until you respond). Signing is ad-hoc, so macOS may ask again after the bundle is rebuilt.

One disk image can only be used by one VM at a time: the VM process holds an exclusive lock
(`flock`) on the writable disk until it exits, and a second launcher (another copy of the app, e.g.
a source build next to `/Applications`, or `steamac-vm`) refuses to start with “SteamOS is already
running” instead of mounting the same file systems twice (that corrupts `/home` and `/var`). The lock
outlives a killed launcher while the guest is still shutting down. Launchers built before the lock do
not check it.

If `/home` still has errors at boot (a VM killed while writing, or a disk used by two launchers that
predate the lock), SteamOS repairs it instead of stopping at “Starting SteamOS services…”: the launcher
adds `fsck.repair=yes` to the kernel command line, so systemd-fsck runs e2fsck answering yes rather than
only the safe preen fixes. Files e2fsck cannot place again end up in `/home/lost+found`.

## Languages

The launcher's interface is in English, Russian and Simplified Chinese and follows the macOS language
(System Settings → General → Language & Region, also per app under Applications). Logs, command-line
output, crash reports and problem reports stay in English. The fixed Steam stage texts of the guest
agent ("Checking for Steam updates", …) are shown translated (`BootProgress.localizedGuestText`); other
guest text (systemd lines, SteamOS itself) is not translated by the launcher.

Strings live in String Catalogs: `host/launcher/Localizable.xcstrings` (keys are the English text) and
`host/launcher/InfoPlist.xcstrings` (permission prompts). In code, SwiftUI literals (`Text("…")`,
`Button("…")`) are localized automatically; every other UI string is written as
`String(localized: "… \(value) …")` — one sentence per key, arguments interpolated, never assembled
from fragments — and text for logs or the CLI stays a plain English string. `host/launcher/build.sh`
compiles with `-emit-localized-strings`, syncs the extracted keys into the catalog (new keys are
added, removed ones marked stale — commit the catalog with the code), prints untranslated keys and
format-argument mismatches (`host/launcher/l10n.py check`), and compiles the catalogs into
`<lang>.lproj` next to `work/out/steamac-vm` and in the app's `Contents/Resources`. `dist.sh` refuses
a release with an incomplete language. Translating outside Xcode: `host/launcher/l10n.py export ru
todo.json` lists what is missing, `host/launcher/l10n.py import ru done.json` adds
`{"key": "text"}` or `{"key": {"plural": {"one": …, "few": …, "many": …, "other": …}}}`; Xcode can
also open the catalogs directly. To check a language without changing the system one:
`work/out/steamac-vm -AppleLanguages '(ru)' …`.

## Creating the SteamOS disk without Docker

The app user does not need Docker: the launcher creates the disk itself — through the first-launch
window's **Create New Disk…** or **Settings → Advanced → Create New Disk…** (stable/rc
branch, home size, location, password for user `steamos`; progress, Stop, and Resume). Only stable
and rc are offered: beta/preview/main may use Valve's development signing key, which is not trusted
by the launcher. A saved unsupported branch falls back to stable and is logged. The same
without a window:

```sh
work/out/steamac-vm --create-disk ~/steamos.img [--branch stable] [--home-gib 64] [--password PW] [--keep-cache] [--accept-eula]
```

Nothing is downloaded until the user accepts Valve's terms: “End User License Agreement for
SteamOS and Steam Client Back-Up Image” (the same text as on the Steam Frame image page,
`https://store.steampowered.com/steamos/download/?ver=steamframe`: personal use only, no
redistribution) and the Steam Subscriber Agreement. In the window this is a checkbox with links
to both texts — Create is unavailable without it; on the command line it is `--accept-eula`,
without which `--create-disk` prints the links and exits with code 2. Acceptance (date and
agreement URL) is stored in the settings domain and remains valid until the agreement URL in the
code (`SteamOSLicense.eulaURL`) changes.

External APFS, Mac OS Extended, and exFAT volumes can hold the disk. FAT32/MS-DOS is rejected
before downloading because of its 4 GiB per-file limit (the temporary rootfs alone is 10 GiB).
Read-only volumes and folders you can't write to are also rejected. Unlike APFS, exFAT has no sparse files: it needs space for the
full selected disk size plus the temporary rootfs and download cache, even before games are installed;
the launcher checks this space before reconstructing the rootfs.
These expected rejections (including an existing destination file or a busy download cache) are logged, not sent as errors
to Sentry. Unexpected creation failures still report: Foundation errors group by domain and code,
with the original technical diagnostic in the event details rather than pointers/task IDs in the title.

If a download cannot reach Valve securely, the window explains that a VPN, proxy, or network filter
may be interfering: try disabling it or using another network. Update checks give the same advice
for GitHub. Technical details stay in the launcher log. HTTPS uses macOS's standard certificate
validation and TLS settings; the pinned Valve CA below verifies the downloaded bundle, not HTTPS.

`rc` stays available, but Valve sometimes signs its latest build with the development key
`steamos-dev-images` instead of the production CA. That build is not accepted: the launcher explains
that it cannot verify this development signature and asks you to choose `stable` or try again later.
This expected rejection is logged only; all other signature failures still report to Sentry.

1. `https://steamdeck-atomupd.steamos.cloud/meta/holo/steamos/aarch64/vr/<branch>.json` → the latest
   candidate (`update_path`, `chunks_store_path`).
2. The `.raucb` (~2 MB) is downloaded; Security.framework verifies its CMS signature only against
   Valve's pinned CA `CN=steamdeck-images` (`scripts/keys/steamdeck-images.pem`, SHA-256 fingerprint
   embedded in the code); the system trust store is not used. A custom squashfs reader (using zstd
   from the pinned zstd release, `fetch-zstd.sh`) extracts `manifest.raucm` and `rootfs.img.caibx`;
   `compatible=steamos-aarch64`, the version, and the slot size are checked.
3. Official desync (`fetch-desync.sh`, pinned version and sha256) assembles the 10 GB `rootfs.img`
   from Valve's chunk stores (~4.4 GB of data); the chunk cache is `desync/` in
   `~/Library/Caches/es.fxgam.steamac` for a disk on the home volume, otherwise in `<disk>.cache` next
   to the disk (an external drive then needs no internal space for it; the folder is removed after
   success). The partial `<disk>.rootfs-tmp` remains too, so Stop/Resume (or rerunning the command
   after Ctrl+C) continues where it left off. One creation per cache at a time: a second one (another
   window or `--create-disk`) stops with “another SteamOS disk is being created” (`flock` on
   `creation.lock` in the cache folder) instead of sharing the chunk cache and temporary files.
4. A sparse disk file: protective MBR + GPT (primary and backup, CRC32) with exactly the names,
   order, types, sizes, and alignment of `scripts/steps/40-disk.sh`, and random PARTUUIDs. In one
   pass, `rootfs.img` is hashed (sha256 must match the signed manifest), and nonzero blocks of 16
   KiB are written to rootfs-A and rootfs-B; the other partitions are zeros. The disk appears
   under its final name only after all checks. Existing files are not overwritten; on exFAT,
   which lacks atomic exclusive rename, the launcher checks the destination while holding its
   creation lock, then renames it. Do not create or move another file to that same destination
   with a non-launcher program during creation: that check and rename are not atomic against it.
5. `<disk without .img>.provision.img` is placed alongside it — cpio newc containing
   `provision.env` (build, PARTUUIDs, SHA-512 crypt password hash, machine-id) and `rootfs.caibx`
   (format: “Payload v1” in the provisioning contract). While this file exists, the launcher
   attaches it read-only (vdc) and adds `steamac.provision=1`: initramfs formats
   esp/efi-X/var-X/home, makes the rootfs-B fsid unique, writes partsets/bootconf/bootenv/var,
   and reports `provision done` — the launcher then removes the payload; subsequent boots do not
   use it.

Space: ~14 GB on the disk volume during creation (~9 GB afterward), ~6 GB of cache (deleted after
success unless `--keep-cache` is specified). Checks: `work/out/steamac-vm --selftest-provision` —
GPT against the Docker-built disk (`work/out/steamos.img` is opened read-only;
`--reference-disk IMG`), CMS/squashfs against the `work/cache/rootfs` cache, cpio, SHA-512 crypt.
The self-test also checks network messages, stable error fingerprints and log-only location
rejections. To exercise an actual TLS failure without sending any events, point
`STEAMAC_PROVISION_TEST_TLS_URL=https://localhost:PORT/` at a local server with an untrusted
certificate when running `--selftest-provision`; it prints the message, title and fingerprint.

## Steam client

Which Steam client SteamOS launches is selected in the launcher: the first-launch window, the
**Create SteamOS Disk** window, and **Settings → Advanced → Steam client** (applies on next start,
“Restart VM to apply”); for a single launch, use `--steam-client frame|deck|deckbeta`. The launcher
passes the selection on every boot in the kernel cmdline as `steamac.steam_client=…`;
`/usr/lib/steamac/steam-client` in the layer reads it each time Steam starts. The Steam service
remains the stock SteamOS service (`steam.service`); the layer adds only a
`steam.service.d/50-steamac.conf` drop-in to it. Before startup, `steam-client` copies the stock
`/usr/share/deckard/RUNSTEAM.sh` to `~/.local/share/Steam/` — unchanged for the Frame client with
a remembered account, while in `deck`/branch/sign-in modes it removes only the lines containing
the `-deckard` and `-vrgamepadui` arguments from the copy. Valve's files are not included in the
layer.

| Option | What it is | Pros and cons |
|---|---|---|
| **Steam Deck client** (`deck`, by default) | public ARM64 Steam Deck client, `steamdeck_stable` branch (the same build as the public `steam_client_linuxarm64`; not officially announced for ARM) | normal sign-in with an on-screen QR code; a public client branch rather than an internal beta |
| **Steam Deck client (beta)** (`deckbeta`) | `steamdeck_publicbeta` branch | like `deck`, but beta |
| **Steam Frame client** (`frame`) | Valve's beta client for Steam Frame (`linux_arm64_beta_<hash>`, flags `-deckard -vrgamepadui`) — as in the image | the client the image ships; an internal beta for a device not yet released; signing in uses sign-in mode (below) |

Changing the option makes Steam download a different client on the next start (up to ~1 GB,
progress in the boot overlay); when switching back to Frame, the Steam bootstrapper switches
automatically based on the `-deckard` flag. A manual `/etc/steamac/steam-client-branch` inside
SteamOS (any client branch) still works when `frame` is selected (or when the launcher passes no
parameter — older versions, a custom `--cmdline`); the launcher's `deck` / `deckbeta` selection
takes precedence over the file.

## Vulkan driver

The host Vulkan driver behind Venus is chosen in **Settings → Advanced → Vulkan driver** (applies on
next start) or for one launch with `--vulkan-driver moltenvk|kosmickrisp`. The default is KosmicKrisp
where the Mac and the build have it (macOS 26+, a build made on macOS 26+), MoltenVK otherwise; a
driver chosen in Settings stays. virglrenderer opens the
driver at runtime (no Vulkan loader): the launcher sets `VKR_VULKAN_DRIVER` to
`@rpath/libMoltenVK.dylib` or `@rpath/libvulkan_kosmickrisp.dylib` before the VM starts. The boot
overlay shows the driver (“Venus → KosmicKrisp”); crash reports carry `vulkan_driver` and the
driver's patch revision.

Before Metal initialises, the launcher checks that its runtime compiler's module cache
(`DARWIN_USER_CACHE_DIR/<bundle id>/com.apple.metalfe`, including existing hash directories and
`.pcm` files) is writable. If permissions, ACLs or immutable file flags block it, the launcher logs
the failing path and redirects Metal to `~/Library/Caches/es.fxgam.steamac/metal-compiler`.
It does not delete the old cache or change its permissions. This uses Metal's optional cache-path
SPI; if the override is unavailable or the replacement is also unwritable, that is logged and
shader compilation errors remain reportable. `work/out/steamac-vm --selftest-metal-cache` reproduces
the `monolithic_metal.pcm: Operation not permitted` failure in a private immutable cache, then
verifies actual Metal source compilation with the replacement (no VM or Sentry events).

| Option | What it is | Pros and cons |
|---|---|---|
| **KosmicKrisp** — Mesa on Metal 4 · macOS 26+ (`kosmickrisp`, default where available) | `host/kosmickrisp/`: Mesa main + open MRs (geometry shaders !44786, transform feedback !44928, tiled images in host-pointer memory !44929, device-local memory type !44221, linear render targets !44782/!44222) + steamac's patches (explicit LINEAR row pitch, LINEAR input attachments, `fillModeNonSolid`, which DXVK requires, 8-sample requests as 4, single texel alignment for texel buffers and timestamp pools over several Metal counter heaps, which vkd3d-proton requires; occlusion queries past one 32768-entry visibility buffer and timestamp pools on counter heaps shared by every guest device of the process (Metal allows 32 per process), so query pools of Dota 2 / Counter-Strike 2 no longer fail to create; sparse binding/residency on Metal 4 placement sparse resources and sampler min/max reduction emulated in shaders before Apple10, which give vkd3d-proton Tiled Resources Tier 2 and so D3D12 feature level 12_0) | faster: Stellar Blade Demo ~29 FPS against ~18 on MoltenVK on an M1 Max (split-screen video: `docs/media/stellar-blade-moltenvk-vs-kosmickrisp.mp4`); Steam UI, DXVK games and Stellar Blade Demo (D3D12, vkd3d-proton) run, its first run spends ~28 min compiling shaders on an M1 Max. macOS 26+ only; built only when the build host runs macOS 26+, otherwise MoltenVK is used. Known gaps (host repros): transform feedback with strip geometry shaders and its overflow counter (draft MR); within one render pass, depth writes to unmapped tiles stay in tile memory and later draws of the pass test against them (Tiled Resources Tier 2 allows this cache; vkd3d-proton's `test_sparse_depth_stencil_rendering` expects them dropped); no sparse 3D textures (Metal's 3D tiles are not Vulkan's standard 3D blocks), hence no Tiled Resources Tier 3 |
| **MoltenVK** — Metal 3 · macOS 15+ (`moltenvk`) | `host/moltenvk/`: the UTM fork + steamac's patches | every supported Mac; the default on macOS 15 and in builds without KosmicKrisp (source builds on macOS 15; the release DMG includes KosmicKrisp since 1.7) |

Switching changes the Venus driver identity (pipeline cache UUID), so Steam and games rebuild their
shader caches. A pipeline the host driver cannot build is a placeholder in virglrenderer: its draws
and dispatches are dropped, the driver never sees `VK_NULL_HANDLE`.

Every host-visible guest allocation is a POSIX shm whose file descriptors stay open in the VM
process (about four per mapped allocation), and a Finder launch starts with a soft limit of 256
descriptors: past a few dozen such allocations games lost their GPU context (STEAMAC-G, Left 4 Dead
2). The VM process raises its soft limit to `kern.maxfilesperproc` at start (logged as “file
descriptors: soft limit 256 → N”); virglrenderer logs the errno of a failed shm or descriptor
operation (“… failed: Too many open files (RLIMIT_NOFILE 256)”).

Checks without a VM: `host/kosmickrisp/build.sh` runs `host/moltenvk/probe` and the repros
(`REPRO_DRIVER=kosmickrisp host/moltenvk/repro/run.sh <dylib>`, through the Khronos loader, test
only) on the staged driver; `host/virglrenderer/build.sh` runs `venus_check` with each installed driver.

## Signing in

The Steam Frame client's sign-in screen is designed for a headset: “Tap to confirm” pairs with a
phone over Bluetooth LE, and “Scan QR code” opens a VR window — neither works in the VM (only the
password remains). Therefore, with the Steam Frame client, while `config/loginusers.vdf` has no
remembered account (new disk, signing out, signing in without “Remember me”), `steam-client`
starts Steam without `-deckard`/`-vrgamepadui`: the bootstrapper switches itself to the public
ARM64 Steam Deck client (`steamdeck_stable`), and sign-in shows an on-screen QR code (Steam Mobile
App → Steam Guard → scan) alongside the password form. After signing in with “Remember me”, Steam
restarts once and returns to the Steam Frame client (each client switch downloads up to ~1 GB;
progress is visible in the boot overlay). Without access to `client-update.steamstatic.com`,
sign-in mode is not enabled.

`RecvMsgClientLogOnResponse() : 'Try another CM'` lines in `connection_log.txt` on the sign-in
screen are normal: the CM server drops a connection without an account sign-in after ~60 s, and
the client reconnects.

## Distribution (DMG)

`host/launcher/dist.sh` turns the built `work/out/FX Steam Launcher.app` into the downloadable
`work/out/dist/FX-Steam-Launcher-<version>.dmg` (the app + a link to `/Applications`). A copy of the
bundle without the `SteamacBuildOut` key (the path to this build tree) is re-signed with Developer ID,
hardened runtime, and a secure timestamp: first all nested Mach-O files (`Frameworks/*.dylib`, helper
programs in `Resources`), then the bundle with `steamac-vm.entitlements` (hypervisor,
disable-library-validation, and audio-input — without the latter, hardened runtime silently blocks the
microphone). The app is notarized and stapled, then the DMG is signed, notarized, and stapled —
Gatekeeper allows it through even offline (the usual “downloaded from the Internet” prompt still
appears on first launch).

```sh
host/launcher/build.sh      # fresh bundle
host/launcher/dist.sh       # signing, notarization, DMG
```

A notarytool profile must be stored in Keychain once:
`xcrun notarytool store-credentials steamac-notary --apple-id <Apple ID> --team-id V25VKGTW55
--password <app-specific password>`. Variables: `STEAMAC_SIGN_IDENTITY` (by default, the only
“Developer ID Application” in Keychain), `NOTARY_PROFILE` (by default, `steamac-notary`);
`--no-notarize` — signing only, for local checks (Gatekeeper will reject a downloaded copy).

Licenses: `bundle.sh` puts all third-party license texts for bundled components and the
`THIRD-PARTY-NOTICES.txt` index (component, version, SPDX, location in the bundle, sources; generated
by `host/launcher/licenses.sh` in `work/out/licenses`, including libkrun crates and Go modules from
gvproxy/desync) in `Contents/Resources/licenses`, plus the project's `LICENSE` and `NOTICE` in
`licenses/steamac/`. `dist.sh` calls `scripts/gpl-sources.sh` and places
`work/out/dist/FX-Steam-Launcher-<version>-gpl-sources.tar` alongside the DMG — the complete source
code of GPL components (the kernel with patches and configuration, busybox from the Debian snapshot,
dosfstools, e2fsprogs, btrfs-progs, build scripts, `README.txt`); attach it to the GitHub release
alongside the DMG. For an older release: `scripts/gpl-sources.sh v1.2`.

## Crash reports (Sentry)

The launcher sends crash reports and a few errors to the developers' own Sentry server
(`sentry.fxgam.es`, sentry-cocoa 9.30.0 SDK via SwiftPM). Enabled by default; disable it with the
**Send crash reports and diagnostics** checkbox in Settings → General, in the first-launch window,
or in the Create SteamOS Disk window (the “What is sent” link displays the list below). When disabled,
the SDK does not start at all and makes no network connections (reports already saved on disk remain
there and are not sent). For one launch: `--no-crash-reports` or `STEAMAC_SENTRY=0`.

What is sent:

- Crashes of the supervisor and VM processes (signal/abort, unhandled exceptions): cause, thread
  stacks, list of loaded libraries. This includes Metal/MoltenVK asserts, libkrun/virglrenderer
  aborts, and Rust panics propagated through the libkrun C API. A VM process crash report is sent on
  the next VM launch;
- A few errors (no more than once per fingerprint per process, subject to a global limit; the same
  fingerprint is not sent again for at least a day, or 30 days for shader compilation errors): the
  guest GPU context becomes fatal/device lost (vkr “fatal decoder state”, “device lost”), MoltenVK
  pipeline compilation errors (`[mvk-error] … compile failed`; if MoltenVK printed MSL source
  (`[mvk-msl] …`: the first 40 lines and lines around the error), it is sent in extra `msl_source`,
  not in breadcrumbs; the vkr line “pipeline … creation failed on host” is a breadcrumb only), a
  Rust panic in libkrun (`thread … panicked at`), failure of initial disk provisioning (`provision
  failed`), failure to create a disk, unexpected VM exit (nonzero exit code or signal when shutdown
  was not requested by the user), and the idle indicator's “SteamOS is not responding”;
- VM exit due to SIGTERM/SIGINT/SIGHUP (logging out, `kill`, ^C before handlers are installed) is not
  a crash: only a log line, with no event and no Report a Problem window. Neither is SIGPIPE (both
  processes ignore it: a closed output pipe — the terminal, or the supervisor's stderr channel after
  the supervisor was killed — only fails the write; the VM process then logs to
  `~/Library/Logs/es.fxgam.steamac/steamac-vm.log` or drops the lines, and lets the guest finish
  shutting down; STEAMAC-10). SIGKILL generates a
  warning-level `vm-killed` event, “VM process killed (SIGKILL — memory pressure or force quit)”: 
  whether the kernel killed it for memory (jetsam, `NOTE_EXIT_DETAIL` from the supervisor's kqueue),
  VM memory and the VM process footprint at exit/peak, host `vm_stat` numbers (free/compressed/wired,
  swap), `kern.memorystatus_level`, and the history of memory pressure levels since launch
  (transitions are also written to the log: `memory pressure: …`). Force Quit from the app menu is a
  requested exit, not a report;
- Every event includes the last ~200 lines of launcher stderr as breadcrumbs (`[steamac-vm]`,
  `[mvk-*]`, libkrun/virglrenderer warnings, startup stages) and tags: version
  (`es.fxgam.steamac@<CFBundleShortVersionString>+<git sha>`), environment, and `build_kind` tag:
  `release` — only a `dist.sh` build with notarization (Info.plist `SteamacDistTeamID`, and the
  running code's signature is Developer ID for that team, checked with `SecCodeCheckValidity`),
  `source-build` — any other `.app` (`bundle.sh`, ad-hoc/re-signed copies, `dist.sh --no-notarize`),
  `development` — `work/out/steamac-vm` outside the bundle; macOS, Mac model, GPU, vCPU/RAM, display
  mode, build UUIDs of libkrun / virglrenderer / MoltenVK, `MVK_PATCH_REVISION`, kernel version,
  SteamOS BUILD_ID and layer release (from initramfs lines), the `appid` of the game in guest focus
  (while it is in focus), and a random installation ID.

Not sent: guest console (hvc0), user and computer names (`/Users/<name>` → `~`, name and hostname are
redacted), IP address (`sendDefaultPii=false`, the server does not expose IP addresses), locale/time
zone, Steam account, game titles (App ID only), or files. The supervisor routes its stderr through a
channel (everything still appears in the terminal/log), so it also sees the last lines from a crashed
VM process.

Testing: `--sentry-test-event` (a test event from the supervisor and VM process; the VM process also
sends a pending crash report and exits), `--sentry-test-crash abort|segv|metal|panic|kill|term|shader`
(the VM process crashes: `abort()` inside a C call, `EXC_BAD_ACCESS` in `memset`, Metal assert, Rust
panic in `krun_start_enter` due to an overly long kernel command line — `panic` requires `--kernel`
and, if necessary, `--initrd`; `kill`/`term` — the VM process kills itself with SIGKILL (`vm-killed`
report) or SIGTERM (no report or window); `shader` — prints an example MoltenVK compilation error
with `[mvk-msl]` and a vkr line, then exits). These events have `environment=development` and the
`test=true` tag. `STEAMAC_SENTRY_DEBUG=1` prints the SDK debug log (server responses).

Symbols: `build.sh` puts dSYMs for `steamac-vm` and bundled libraries in `work/out/dSYMs` (libkrun,
virglrenderer, and MoltenVK are built without DWARF — they contain only symbol tables). `dist.sh`
uploads them and the app binaries with `sentry-cli --url https://sentry.fxgam.es debug-files upload`
if `SENTRY_AUTH_TOKEN`, `SENTRY_ORG`, and `SENTRY_PROJECT` are set; otherwise it logs that the upload
was skipped.

## Update check

When the app starts (once per launch, not on every VM reboot, and no more than once every 6 hours —
even across launches), the launcher requests the latest release in the background without delaying
startup from `https://api.github.com/repos/fxgl/steamac/releases/latest` (unauthenticated, 10 s
timeout; drafts and prereleases are excluded) and compares its `vX.Y[.Z]` tag with its own version
(`CFBundleShortVersionString`, numerically: 1.3.10 > 1.3.9). If a new version is available, a window
appears next to the VM window (not over it if there is room on screen; without taking focus — the
keyboard and captured mouse remain with the VM): “FX Steam Launcher X.Y is available — you have …”,
with the release description and buttons **Download** (opens the release's `.dmg` in a browser, or
the release page otherwise), **Skip This Version** (this version is no longer offered at startup),
and **Remind Me Later** (offers it again at the next check). The app menu's **Check for Updates…**
item (while the available version has not been skipped, “Update Available: X.Y…” with a New badge,
opens this window) checks immediately — without the 6-hour limit and including skipped versions —
and reports “You're up to date” or an error; network and HTTP errors at startup are only logged
(`update: …`). Disable it with the **Check for updates at startup** checkbox in Settings → General
(effective immediately). The dev launcher `work/out/steamac-vm` does not check at startup (the menu
works); source builds (`bundle.sh`) and releases do.

Privacy: the request goes only to `api.github.com` (GitHub) and includes only `User-Agent:
FXSteamLauncher/<version>` (plus standard HTTP headers and the previous response's ETag, so GitHub can
reply “not modified”); no Mac or user identifiers, cookies, or Sentry. The check time, ETag, response,
and skipped version are stored in settings (`updateLastCheck`, `updateETag`, `updateCachedBody`,
`updateCachedURL`, `updateSkippedVersion`).

Tests: `STEAMAC_UPDATE_URL` overrides the URL (release JSON or a `/releases` array, `http(s)://` or
`file://`; it also enables the startup check for the dev launcher), `STEAMAC_FAKE_VERSION` overrides
the launcher version; FIFO `--control-fifo`: `update check|startup|state`, `update press
download|skip|later|ok|releases`, `update dump PNG` (the window and `-with-vm.png` — together with the
VM window, as shown on screen).

## Report a Problem

If something does not work, send a report to the developers directly from the launcher:
**Help → Report a Problem…** (or from the app menu), the **Report a Problem…** button in
Settings → General, the **Report…** link on the “SteamOS is not responding…” card, and the
**Report…** button in the “FX Steam Launcher stopped unexpectedly” window that appears after
the VM exits unexpectedly (crash, error). The dialog has:
email (required, remembered on this Mac so the developers can reply), a description (what you did,
what you expected, what happened), and checkboxes for attachments:

- **Include launcher logs** (enabled) — messages from the launcher, libkrun, virglrenderer, and MoltenVK
  for this session (the last ~2 MB, both processes) and `perf:`/`stall:` lines; paths `/Users/<name>` → `~`,
  the user and computer names, email addresses, and IP addresses are redacted;
- **Include SteamOS logs (system journal, Steam/Proton logs)** (enabled) — the guest console (hvc0) for
  the session and a `steamos-logs.tar.gz` archive collected by the guest agent: the systemd journal
  for the current boot (`journalctl -b`, the last 5000 lines, plus the user journal), `coredumpctl list`/`info`,
  `dmesg`, `systemctl --failed`, `os-release`, `layer-release`, `/proc/cmdline`, `df`/`free`, tails of
  Steam client logs (`console_log`, `stderr`, `bootstrap_log`, `compat_log`, `connection_log`,
  `webhelper`, `cef_log`, `shader_log`, `steamui_*`) and Proton logs (`~/steam-*.log` from `PROTON_LOG=1`,
  `version` and `config_info` of prefixes in `compatdata`), FEX tool build ID / Steam manifest /
  configuration, an opt-in FEX log, memory limits, and the last 512 KiB of American Truck
  Simulator's `game.log.txt`. For an ATS emulator crash, set its Steam launch options to
  `FEX_SILENTLOG=0 FEX_OUTPUTLOG=/home/steamos/fex-amtrucks.log %command%`, reproduce, and report;
  the collector includes the last 512 KiB of that log. Remove the launch options afterwards.
  FEX re-raises a crash of the emulated game from its JIT code, so the core's stack shows only an
  anonymous AArch64 address. To record where the x86_64 code faulted, set the game's launch options to
  `LD_PRELOAD=/usr/lib/steamac/x86_64/fault-report.so:$LD_PRELOAD %command%`, reproduce, and report.
  On SIGSEGV/SIGBUS/SIGILL/SIGFPE/SIGABRT the library writes the x86_64 RIP, the fault address,
  the registers, a backtrace with the module and offset of every frame, and the memory map to
  `~/.local/state/steamac/fault-report.txt`. The file stays under 256 KiB and the report includes it
  as `fex/fault-report.txt`. Then the game's own handler or the default action runs, so the crash and
  its core dump are unchanged. Without the launch option the library is never loaded.
  Completed crash metadata is exported by a root hook for `steamos` only (root-owned, mode 0640);
  raw cores remain private and are never attached. `coredump-pending.txt` identifies dumps still
  running: reports do not wait for them; send another report once they finish. Namespace-aware
  stack extraction resolves pressure-vessel libraries where symbols are available (FEX JIT code
  may still be unsymbolized). Core processing limits are not lowered: oversized cores would lose
  their backtraces, and `Storage=none` still writes a full temporary core. Steam IDs (`[U:1:…]`,
  7656119…), Steam account/persona names and email addresses are replaced with placeholders before
  packaging; `collect-notes.txt` lists what could be read. Over SSH, the same scrubbed archive is
  available with `/usr/lib/steamac/fx-progress-agent collect > /tmp/steamos-logs.tar.gz`;
- **Include a screenshot of the VM window** (disabled by default: the image may show your Steam
  account name and friends).

`system-info.txt` (app and macOS versions, Mac model, GPU, build UUIDs of libkrun/virglrenderer/MoltenVK,
kernel, SteamOS BUILD_ID, layer release, disk sizes, VM settings, collection notes) and `settings.txt`
(saved settings and command-line overrides; the SSH password is stored in Keychain and never included
in the report, nor are game titles) are always attached. **Show What Will Be Sent** assembles the report
and opens its folder in Finder — exactly its contents are sent.

The report goes to Sentry (`sentry.fxgam.es`, the same project) as User Feedback: email, description, a
link to the latest error event in this session (if any), and files as attachments, in one envelope sent
directly to the envelope endpoint so the server's response is visible. It also works with crash reports
disabled (an explicit user action: the SDK and crash handler do not start in that case). Attachments are
limited to 20 MB (older portions of logs are trimmed first, then the screenshot and SteamOS archive are
dropped); on an HTTP 413 response, the limit is halved and the report is sent again. After sending, a
short Report ID is shown (the first 8 characters of the event ID). If sending fails, the folder remains
at `~/Library/Logs/es.fxgam.steamac/reports/<date>-<ID>/` (`report.json` with the email and description
plus files); the dialog offers **Retry** and **Reveal in Finder**, and the folder can be emailed.

How it works: the supervisor always pipes stderr from both processes and writes it to
`/tmp/steamac-<pid>/launcher.log` (timestamped, rotated at 4 MB); the VM process writes the hvc0
console to `console.log` alongside it; the directory is removed when the launcher exits. Guest logs
are requested over the same `fx.progress` port in the reverse direction: the launcher writes
`collect-logs <id>`, the agent (running as the session user, with access only to what that user can read)
responds with `logs-begin <id> <size>`, lines of `logs <id> <base64>`, and
`logs-end <id> <sha256>` (or `logs-failed <id> <reason>`); the launcher assembles the archive and
verifies its size and SHA-256. If there is no response within 20 s or the agent is not running (no
heartbeat), the report is sent without guest logs, with a note in `system-info.txt`.

Testing: `--control-fifo PATH`, commands `report open`, `report fill EMAIL TEXT…` (event tagged
`test=true`), `report include launcher|steamos|screenshot on|off`, `report preview`, `report send`,
`report retry`, `report dsn DSN|default`, `report dump PNG`, `report close`; `STEAMAC_REPORT_DSN`
overrides the DSN (failure path), `STEAMAC_SENTRY_DEBUG=1` prints the server's response. Post-crash
window: `--sentry-test-crash abort` with `STEAMAC_REPORT_DUMP=<dir>` (PNGs of the window and dialog,
then it closes on its own; `STEAMAC_REPORT_TEST_SEND=1` also sends a test report).

## How it works

| Directory | Contents |
|---|---|
| `host/moltenvk/` | MoltenVK utmapp `geometry-shaders` @05604465 + patches: depth_clip_enable, YCbCr arrays, null descriptors, geometry shader emulation for zink/DXVK (vertex stride, instancing, adjacency, fans, SCALED formats, `gl_in`), transform feedback (DXVK stream output) and its queries (SO statistics), query result availability on copy (DXVK occlusion queries via Venus), atomics on vector components at buffer addresses (BDA, vkd3d-proton), texel buffers with offsets at any texel (vkd3d-proton), writes to small push-descriptor buffers with robustness2, variable-count descriptor arrays as runtime arrays (Metal kept 32 MB per vkd3d-proton heap array and program), allocation of auxiliary buffers, deferred release of Metal resources, patch hash in the pipeline cache UUID, `VK_NULL_HANDLE` descriptor sets in binds, fragment outputs converted to their color attachment's numeric type; tests in `repro/` run under Metal validation (also on KosmicKrisp: `REPRO_DRIVER=kosmickrisp`); `bench/run.sh <libdir>…` compares performance of changes between builds; `bench/shaders.sh <dump or pack>` measures a game's shader compilation (SPIR-V → MSL, MSL → Metal library, pipeline states; cold/warm, threads) from a MoltenVK shader dump or a 10% sample made with `bench/pack.py` |
| `host/kosmickrisp/` | KosmicKrisp (Mesa main @ce576c29) + open Mesa MRs and steamac patches (see “Vulkan driver”), built without LLVM at runtime (`-Dllvm=disabled`, `mesa_clc` from a first build), `-Db_ndebug=true`; macOS 26+ only |
| `host/libepoxy/` | libepoxy 1.5.10, upstream macOS Meson options, built for macOS 15.0 instead of copying a Homebrew bottle |
| `host/virglrenderer/` | virglrenderer UTM `macos-next` + merge with upstream main (venus-protocol 1.1.3) + LINEAR modifier, shm import as host memory, stubs for failed pipelines (draws dropped in virglrenderer), recreation of rejected cache, deferred shm unmap, thread QoS, Vulkan driver opened at runtime (`VKR_VULKAN_DRIVER`) |
| `host/libkrun/` | libkrun v1.19.6 + patches: `VIRTIO_GPU_F_BLOB_ALIGNMENT` (16K), SME mask for M4, 2D resources without virgl, `SET_SCANOUT_BLOB`, SHM blob mapping, Venus fence signaling, virglrenderer logs, `krun_display_resize` (resolution changes on the fly), vCPU/GPU thread QoS |
| `host/launcher/` | `steamac-vm` (Swift/AppKit): Metal window (optional MetalFX super resolution), “FX STEAM LAUNCHER” overlay with boot/shutdown progress, guest resolution = window size (× the screen's backing scale with Retina resolution) at constant DPI (EDID from the physical screen size), keyboard/mouse/tablet, the guest's Xbox 360 / DualSense / DualShock 4 pad from GameController.framework with rumble or a DualSense passed through as raw HID (`fx.pad`), network via gvproxy, VM restart on guest reboot, `--perf-stats` |
| `guest/kernel/` | Linux 7.2.9, everything built in, 4K pages, 16K blob-node alignment, Apple TSO for FEX; uhid, hidraw and `hid-playstation` (with the LED classes it needs) for the passed-through DualSense |
| `guest/mesa/` | Venus ICD for aarch64 (Proton, gamescope, zink) and x86_64/i386 (FEX graphics provider); x86_64 fault reporter for emulated games (`/usr/lib/steamac/x86_64/fault-report.so`) |
| `guest/initramfs/` | boot stage = “bootloader”: A/B slot selection with attempt counter, partsets, overlays for `/etc` and `/usr`; initial provisioning of the launcher-created disk (`steamac.provision=1`: static mkfs.fat, mke2fs, btrfstune in initramfs); `steamac.ssh=0` — no SSH server; launcher config payload (`steamac.config=1`) — new `steamos` password; `steamac.tz=` — the Mac's time zone in `/etc/localtime`; untouched procfs at `/run/steamac/proc` for Flatpak sandboxes |
| `guest/layer/` | VM layer over `/usr` (read-only erofs): file-based `splctl`, safe post-install for RAUC, `VARIANT_ID=steamdeck`, gamescope session on DRM, Desktop Mode (Plasma nested in gamescope), masks for Frame hardware services, `fx-progress-agent` progress agent (Rust, `guest/progress-agent/`, `fx.progress` virtio-console port) and its root services (`fx.clock`, `fx.sleep`, the uinput or uhid gamepad on `fx.pad`), short shutdown timeouts, QR-code Steam sign-in mode (Steam Deck client, while there is no remembered account), optional Steam client branch (`/etc/steamac/steam-client-branch`), Steam Shader Pre-Caching disabled by default (`steam-shader-defaults`) |
| `scripts/` | build of `work/out/steamos.img`: GPT with Valve's partition layout (esp, efi-A/B, rootfs-A/B, var-A/B, home); `scripts/test/provision-test-disk.sh` — dev test of provisioning against a disk from Docker; `scripts/test/vkd3d-tiled.sh` — dev end-to-end check of D3D12 tiled resources and the feature level (vkd3d-proton tests of Proton 11.0, `d3d12-caps`, `vk-minmax`) in a throwaway VM |

MoltenVK also fixes fragment helpers that discard from an otherwise empty SPIR-V block
(STEAMAC-1Q). `host/moltenvk/repro/msl_helpers.c` checks both direct and nested helpers:
discarded pixels stay clear and do not write storage buffers; surviving pixels render normally.
It renames user-defined `log10(float)` helpers to avoid Metal's builtin overload (STEAMAC-1R);
the same repro reads back the compute helper's results, not just successful pipeline creation.

`vkCmdBindDescriptorSets` with a `VK_NULL_HANDLE` among the sets (legal with graphics pipeline
libraries) no longer crashes the VM when the command buffer is submitted (Counter-Strike 2 binds
five sets with the fourth null, STEAMAC-25): as on RADV, a null set binds nothing and takes no
dynamic offsets (`repro/invalid_usage.c`).

A fragment output of another numeric type than its color attachment (a Left 4 Dead 2 pipeline from
DXVK writes an unsigned output to an `R32_SINT` attachment, STEAMAC-2C; Vulkan leaves the values
undefined) failed in Metal, and the pipeline's draws were skipped; it is now declared with the
attachment's type and its bits are written (`repro/frag_output.c`).

The SteamOS root filesystem is not modified: all changes come from initramfs and the layer. Thus
official Valve updates (RAUC + atomupd) install into the other slot and roll back normally — verified
with the 20260922 → 20260928 update and rollback.

## Status

Verified:

- SteamOS boots to `graphical.target`, autologin, gamescope session; networking (DHCP via gvproxy,
  downloading a 583 MB Steam client update), SSH;
- Venus in the guest: `Virtio-GPU Venus (Apple M4 Max)`, Vulkan 1.4; render test (compute + clear/copy)
  and display output through KMS match the reference pixel for pixel;
- all required DXVK features from Proton 11 / DXVK 3.x are visible in the guest (geometryShader,
  shaderCullDistance, depthClipEnable, robustness2 + nullDescriptor, maintenance5/6, …);
- keyboard, tablet, mouse, and the virtual pad are visible in SteamOS; as a DualSense, Steam's SDL
  maps it as `PS5 Controller` (type PS5) and shows PlayStation glyphs; the pad appears, disappears
  and changes kind while the VM runs; rumble from SDL and from Steam's virtual pad reaches the
  launcher (`rumble 49152 16384` for 1.5 s, then 0); playing it on a physical controller is not
  verified yet;
- DualSense passthrough, guest side: a uhid DualSense with the real USB report descriptor, fed by a
  stand-in for the launcher, binds `hid-playstation` (gamepad, touchpad, motion sensors, headset
  jack, RGB and player LEDs); touch position and touchpad click reach the touchpad device, the mute
  button toggles the mute LED through an output report back to the Mac side, and Steam opens
  `/dev/hidraw*` with its HIDAPI driver (`Controller using HIDAPI driver, vid=0x054c, pid=0x0ce6`).
  The Mac side (IOHIDManager, a physical DualSense over USB or Bluetooth) is not verified yet;
- Desktop Mode: Switch to Desktop, the Plasma desktop with mouse input (also letterboxed), Return to
  Gaming Mode, booting straight into the desktop; Flatpak sandboxes start;
- A→B update via official OTA and rollback;
- GL via zink (glamor in Xwayland, glxgears ~60 FPS), Steam UI (gamepad UI, CEF with GPU)
  renders in the VM window;
- Steam sign-in, installation of Proton 11.0-2 (ARM64) and FEX, running a DX11 game (Death's Door)
  through DXVK → Venus → MoltenVK;
- guest resolution follows the window size at constant DPI; fast shutdown (2–4 s);
- Heroes of Might and Magic: Olden Era (Unity, DX11) — 7 minutes without errors (offline test).

Stutters on the first pass are Metal compilation (~50–100 ms per new pipeline); subsequent passes take
~1 ms. On reboot after an abrupt shutdown, initramfs checks and repairs FAT on esp/efi.

## Limitations

- DirectX 12 (vkd3d-proton): feature level 12_0 on KosmicKrisp (tiled resources tier 2: sparse binding and
  residency on Metal 4 placement sparse resources), 11_0 on MoltenVK; SM 6.0 on both (no SM 6.2+ on Apple GPUs).
  Within one render pass, depth written to unbound tiles of a sparse depth attachment stays in Apple's tile memory.
  Stellar Blade Demo (UE4) runs at 1280×800, 60 FPS on an M4 Max; the first run spends minutes compiling shaders. The
  x86 emulator in Proton ARM64 (FEX) stopped it once after 20 minutes (DEP check in its protected .exe).
- Audio: virtio-snd → CoreAudio (default device or one selected in settings), latency ≈65 ms on built-in
  speakers. At boot, playback automatically exposes up to 8 PCM channels from the output device's
  configured speaker layout, including height speakers (e.g. 5.1.2) when explicitly identified by
  CoreAudio. An unclassified/discrete layout falls back to mono/stereo; 8 channels alone do not imply
  5.1.2 or Dolby Atmos encoding. Before WirePlumber starts, `audio-layout` reads the VirtIO ALSA
  playback map and overrides SteamOS's platform stereo policy with the matching Pro Audio output.
  The VirtIO Pro Audio nodes use timer scheduling and separate playback/capture groups because
  their host devices have independent clocks. Device/default/layout changes are checked once a second: playback
  is rebuilt with physical speaker routing, and missing speakers are downmixed with headroom.
  Guest channel capabilities/maps stay fixed for that boot because virtio-snd/ALSA cache them;
  switching to a device with more channels or a different speaker layout requires restarting the VM
  to expose the new layout to games. `STEAMAC_SND_TRACE=1` logs detected guest and device maps;
  `STEAMAC_SND_DUMP` records guest PCM before speaker mapping. The microphone remains mono/stereo
  and has not been tested.
- Anti-cheat systems that block VMs will not work.
- `logicOp` is unavailable (the private Metal API in the MoltenVK fork does not build); zink emits a warning.

## License

The project code is licensed under Apache License 2.0 (`LICENSE`), © 2026 FX GAMES FZ LLC. Exceptions
are listed in `NOTICE`: Linux kernel patches and configuration — GPL-2.0-only, virglrenderer and Mesa
patches — MIT (as in those projects), five gamescope session files derived from Valve's
`deckard-steamvr-session` package — MIT © Valve Corporation; the Valve CA certificate and screenshots
in `docs/media` are not covered by the project license. License texts are in `LICENSES/`.

SteamOS is not part of the project and is not distributed with it: the app downloads a signed image
from Valve's servers after the user accepts Valve's license (see “Creating the SteamOS disk without
Docker”).

Steam, the Steam logo, SteamOS, Steam Deck, and Steam Frame are trademarks and/or registered trademarks
of Valve Corporation in the United States and/or other countries. The project is not affiliated with or
endorsed by Valve Corporation.
