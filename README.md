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
./build.sh          # Vulkan stack: MoltenVK, virglrenderer, libkrun, launcher, kernel, Mesa, disk
./build.sh dxmt     # DXMT + wmtr host executor and guest payload; then rebuild layer and launcher (below)
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

Gaming Mode defaults the Steam UI to the virtual display's native resolution, including Retina,
instead of Steam's separate 1920 × 1080 UI cap. Before Steam starts,
`/usr/lib/steamac/steam-native-resolution` supplies a missing
`InstallConfigStore/Gamescope/EnableSteamNativeExternalResolution` value in `config.vdf`.
An explicit on/off choice in Steam is preserved. The global game resolution setting controls
games separately; choosing 5120 × 2880 there does not raise the Steam UI resolution. The
launcher's existing 4094-pixel maximum display side still applies.

Steam's idle screensaver (Settings → Display → Screensaver in Game Mode) is off in the VM. After a
few minutes without input Steam puts its `Screensaver_uid<n>` window in front of a running game,
gamescope moves focus to it and the next clicks land in Steam until Escape. The launcher's mouse,
tablet and keyboard reset Steam's timer, but a game left alone on a long loading screen or played in
VR (headset input never reaches Steam) is idle to Steam; macOS keeps its own screensaver and display
sleep. Before Steam starts, `/usr/lib/steamac/steam-idle-screensaver` (ExecStartPre of
`steam.service`) writes `"IdleScreensaverACSeconds" "0"` and `"IdleScreensaverBatterySeconds" "0"`
(`InstallConfigStore/Software/Valve/Steam/System` in `config.vdf`; 0 = never) where they are
missing, once per Steam installation (marker `config/steamac-idle-screensaver`), so a screensaver
timeout chosen later in Steam's settings stays.

Per-title environment that a game needs from the driver it runs on is a default, not code:
`/usr/lib/steamac/steam-title-defaults` (also an ExecStartPre of `steam.service`) puts the required
`VAR=value` words in front of a title's Steam launch options (`%command%`). It ships one entry:
Dragon's Dogma 2 (2054970) asks for D3D feature level 12_1, which vkd3d-proton derives from ROVs and
conservative rasterization — on Metal neither exists (conservative rasterization has no Metal API;
ROVs would need Metal's raster order groups mapped to `VK_EXT_fragment_shader_interlock`), and the
title only checks the level, so it is reported as `VKD3D_FEATURE_LEVEL=12_1 VKD3D_SHADER_MODEL=6_6`,
together with `VKD3D_DISABLE_EXTENSIONS=` (empty). KosmicKrisp's 64-bit atomics cover unsigned
min/max only, so `steam.service` keeps `VK_KHR_shader_atomic_int64` and
`VK_EXT_shader_image_atomic_int64` from every D3D12 title by default
(`Environment=VKD3D_DISABLE_EXTENSIONS=…` in its drop-in; a title whose shaders use another 64-bit
atomic would silently lose those pipelines, and vkd3d-proton reports shader model 6.6 from them), and
a title that fits gets them back in its own launch options. The default is Steam's inherited
environment, not a `gfx.txt` line: `steam-launch-wrapper` sets every variable of
`$XDG_RUNTIME_DIR/steam/env/gfx.txt` and then `~/.config/steam/env/gfx.txt` over the game's
environment, launch options included, so a `VKD3D_DISABLE_EXTENSIONS` written there wins for every
title. An entry applies only where the Venus device advertises the features it needs (DD2's: the
64-bit atomics, Apple8/M2 and later) and is taken back, restoring the previous launch options, when
a later Steam start finds them gone (driver switched to MoltenVK, disk moved to an M1); a failed
probe changes nothing. An existing value is only prefixed, never replaced, a value without
`%command%` is left alone, and an edit made in Steam after ours wins (marker
`~/.config/steamac/title-defaults.json`, which also keeps the previous value).
Profile `env` words override the built-in entry; without a profile override, DD2 keeps the feature-gated default.

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

Mouse (`--mouse auto`, by default): the SteamOS cursor follows the Mac cursor precisely, and the Mac
cursor is hidden over the picture so only gamescope's cursor shows (it reappears over the black bars,
the clickable progress pill and "Report…" link, menus and other windows, while booting, paused or
asleep, and outside the window). gamescope
(gaming mode) does not accept absolute coordinates, so the launcher moves it with relative deltas
without acceleration, in pixels of the surface gamescope shows: the agent sends its size with each
focus line (`focus steam 1920x1200` when Steam's Settings > Display > Resolution is not the native
one, so its UI is smaller than the display and scaled up), and the launcher maps the window onto that
surface as gamescope scales it into the display (`--selftest-pointer`). When a game has focus in the
guest (the agent sends `focus game <appid> <w>x<h>`), the
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
| General | boot/shutdown overlay; “Still working…” indicator on GPU idle; “When FX Steam Launcher is in the background”: **Mute sound** (on by default: `krun_snd_set_volume(…, mute)` with a gradual ~150 ms fade-out; volume is restored when returning to the window) and **Pause the game** (off by default: the guest agent freezes only the game in focus — `systemctl --user freeze app-steam-app<appid>-*.scope`, cgroup v2; Steam, downloads, and updates continue running; online games may disconnect). While the agent confirms the freeze (`game-frozen`/`game-thawed`), the window is dimmed, with a “Game paused · Click to resume” card and “— paused” in the title; clicking the window resumes the game and is not passed to the guest; crash reports (`--no-crash-reports`, see below); **Check for updates at startup** (on by default, see “Update check”); frame statistics logging (`--perf-stats`); **Use the Mac's keyboard layouts in Desktop Mode** (on by default, see “Desktop Mode”) | full screen at startup; **Use the Mac's time zone and clock format** (on by default, see above) |
| Display | guest follows window size; Apple's Metal Performance HUD in the upper-right corner of the window (Ctrl+Cmd+P, View → Show Metal Performance HUD); **MetalFX super resolution** (off by default): Apple's MetalFX spatial upscaler scales the guest picture to the window's pixel size whenever the window has more pixels than the guest (2× on Retina screens, scaled or fullscreen windows) instead of linear / nearest scaling; it runs on the guest frame in the launcher, so it works for every game and the Steam UI | physical size source (auto from display / DPI / mm — `--dpi`, `--display-mm`), refresh rate (`--refresh`), window size (`--display`): standard 16:10, 16:9, 21:9 and 3:2 resolutions from 1280 × 800 (Steam Deck) to 3840 × 2560 (those that do not fit on the display are marked “larger than this screen”; the window is shrunk as before), “Fit to screen” (largest size for the display, recalculated on every launch), or “Custom…” (W × H fields); **Retina resolution** (optional, off by default): the guest display gets the screen's pixel density (window points × the screen's backing scale, taken at boot; the scale is lowered so no side exceeds 4094 px) at the same EDID physical size, so SteamOS scales its UI up to the same size with sharp text — but games draw 4× the pixels and each frame copy is 4× larger; recommended instead: Retina resolution off + MetalFX super resolution (a 2× upscale on Retina screens) |
| Mouse | auto-capture in games; game list (name from `appmanifest_<appid>.acf`, Default/Auto/Off, remove) | — |
| Controller | which physical controller (GameController) drives the virtual pad (first connected or selected), whether SteamOS gets a pad and what it appears as (`--no-gamepad`, `--pad`, see “Controller”), whether a DualSense is passed through as itself, whether further controllers are players 2–4, swap A/B and X/Y, stick dead zone, live input test | — |
| Sound | output device (System default follows macOS, or a specific CoreAudio device), volume/mute, Low/Normal/Safe buffer — via `krun_snd_set_*` (looked up with `dlsym`; with an older libkrun the fields are disabled with an explanation) | sound (`--no-sound`) |
| Games | **Share game statistics** (off until you agree, see “Game statistics”); known games and games with recorded sessions: per-game profiles (graphics, Vulkan driver, launch options; see below), sessions, play time, last session's FPS / 1% low / game memory / Vulkan driver, your optional rating (Runs well / Playable with issues / Starts, but unplayable / Does not start) and a per-game **Share** switch | profiles may require restarting Steam or the VM (see below) |
| Advanced | — | vCPU (`--cpus`), RAM (`--mem`), SSH enable/disable + port (`--ssh-port`, `--no-ssh`) and generated password, network (`--no-net`), disk image (`--disk`), Create New Disk…, Steam client (`--steam-client`, see “Steam client”), Vulkan driver (`--vulkan-driver`, see “Vulkan driver”), Allow DXMT (D3D11 on the Mac's Metal), experimental (`--wmtr-lib`, `--no-wmtr`, see “Vulkan driver”) |

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

### Per-game profiles

**Settings → Games** stores a profile per Steam app id, separately from mouse auto-capture:
**Graphics** — Default (= Vulkan) / Vulkan / DXMT; **Vulkan driver** — Default (the global driver) /
KosmicKrisp / MoltenVK (only available drivers are offered); **Launch options** — space-separated
`NAME=value` words placed before `%command%`, not arbitrary shell commands. The whole string is
limited to 256 characters. Names use the prefixes `VKD3D_`, `DXVK_`, `PROTON_`, `WINE_`, `MESA_`,
`RADV_`, `VK_`, `DXMT_`, `MTL_`, `STEAMAC_`, followed by zero or more `[A-Z0-9_]` characters;
values match `[A-Za-z0-9_.,:;+-]*` (empty is allowed). Assignments are sorted by name; the last
duplicate name wins. Invalid input stays visible with an error and is not saved or sent.

**Recommended: … — Apply** fetches a profile from the statistics service using this Mac's **My Mac**
limits (GPU cores, RAM and performance cores no greater than this Mac's). Configurations are ranked
by `(runs well + 0.5 × playable with issues) / all ratings`, then higher launch success and fewer
early exits; at least two distinct installs are required (details in “Game statistics”).
Recommendations are never automatic: only **Apply** changes the profile.

DXMT requires **Settings → Advanced → Allow DXMT (D3D11 on the Mac's Metal)** and a VM boot with
that permission. While it is off, a DXMT profile is shown as not in effect and offers **Allow DXMT…**
with the existing security warning; it cannot map a game to Proton 10.0 on a Vulkan-only boot.
The Vulkan driver is selected **per VM boot**, not per process. When a game starts or gains focus
with another profile driver, the launcher offers to restart the VM with that driver and relaunch
the game once Steam is ready. This one-shot override does not change the global driver setting.

Profiles travel over the bidirectional `fx.progress` port (one line per message). Host → guest:
`profiles <base64 of UTF-8 JSON>` replaces the full set on the first agent heartbeat/ready of a boot
and after changes; `launch <appid>` starts `steam steam://rungameid/<appid>` as the session user;
`restart-steam` restarts `steam.service` only after the user agrees. The profile payload is
`{"v":1,"games":{"570":{"gfx":"dxmt","env":"PROTON_LOG=1"}}}`; default/empty fields are omitted,
and `driver` stays host-side. The guest atomically persists it in
`~/.config/steamac/game-profiles.json`. Before graphics/title preparation, the `steam-profiles-wait`
ExecStartPre waits up to 5 s for this boot's synchronization, then snapshots the latest available
set (using the persisted file on timeout). Guest → host: `profiles-ok <sha256 of JSON> applied|pending`;
`pending` means Steam is running with a different applied set and the launcher offers **Restart Steam**
or **Later**. `game-gfx <appid> dxmt|vulkan` follows `game-proton` and describes the actual Proton
graphics path, detected from its `.steamac-dxmt` marker rather than the boot permission.
Unknown verbs remain ignored so old/new host/guest combinations work.

On Steam start, profile launch words override `steam-title-defaults`' built-in entry; with no
profile `env`, Dragon's Dogma 2 retains its Venus-feature-gated default. Ownership is unchanged:
a later user edit in Steam wins; replacing or removing steamac-owned words does not accumulate
old assignments, and removal restores the previous launch options.

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

**Keyboard layouts.** With Settings > General **Use the Mac's keyboard layouts in Desktop Mode** (on
by default, applies now), Desktop Mode has the keyboard layouts enabled on the Mac, in the Input
menu's order, and switches with the Mac's input source (Globe key, Control-Space). The launcher maps
each to an XKB layout (`com.apple.keylayout.Russian` → `ru(mac)`, `RussianWin` → `ru(winkeys)`,
`German` → `de(mac)`, …; otherwise only a closed list of unambiguous first languages; unknown
sources are skipped; an input method counts as the layout it types with). At most four layouts
are sent (XKB's limit), always including the active one, as `keyboard-layout <active index> <layout(variant)>…` over
`fx.progress` on every change and whenever Desktop Mode gets the focus, again 1.5, 4 and 8 s later
(Plasma's startup selects its first layout after KWin took ours). The agent runs
`/usr/lib/steamac/desktop-keyboard` (latest request only, never blocking): it checks each layout
and variant against the guest's XKB symbols, drops unknown ones and recomputes the active index
(if the active layout was dropped, it does not switch). Like the Mac clock format, it follows
the Mac until changed in SteamOS: the first sync replaces even existing custom layouts; after
that an observed user edit of Plasma's layouts wins permanently. The marker is
`~/.config/steamac/mac-keyboard.json`; switching off the setting stops sync, without restoring
the old list. While following, it writes `kxkbrc` (including empty `DisplayNames`), asks KWin to
reload when the file changes or KWin's layout codes differ (`reloadConfig` on `org.kde.keyboard`
`/Layouts`), and selects the active layout (`org.kde.KeyboardLayouts.setLayout`) on the live nested
session bus (`nested_plasma/steamac-session-bus`; absent or stale bus means no-op). macOS often
posts its input-source notification 0.55–0.85 s after a Globe-key switch, so only while this setting
is on, Desktop Mode has focus and the launcher is active, it polls the current layout every 30 ms.
The keys stay the Mac's physical keys (evdev codes); the layout decides what they type.
Gaming mode keeps its layout.

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
drives a gamepad in SteamOS: the first connected one, or the one picked in Settings → Controller,
is player 1, and further ones are players 2–4 (“Several controllers” below). The pad is not a virtio-input
device: the launcher sends it over the virtio-console port `fx.pad` to the guest's root service
`fx-pad.service` (`fx-progress-agent pad`, started by udev when the port appears), which creates it
with uinput. So it follows the Mac while the VM runs: it appears when a controller connects (Steam
shows “Controller Connected”), disappears when its controller goes, and changes kind with it.
Settings → Controller → **Appears in SteamOS as** (`--pad auto|xbox360|dualsense|dualshock4|steamcontroller`
for one run):

- **Automatic** (default): the same kind as the controller that drives it — DualSense (or Edge) →
  DualSense, DualShock 4 → DualShock 4, anything else → Xbox 360 controller; a Steam Controller
  goes to SteamOS as itself (“Steam Controller passthrough” below);
- **Xbox 360 controller**: what the kernel's `xpad` driver exposes (`045e:028e`);
- **DualSense** / **DualShock 4**: what `hid-playstation` / `hid-sony` expose for a USB pad
  (`054c:0ce6` / `054c:09cc`, version `0x8111`, face buttons by position, digital L2/R2 besides the
  analog triggers). Steam's SDL maps it as a PS5 / PS4 controller and shows PlayStation glyphs;
- **Steam Controller**: a Steam Controller goes to SteamOS as itself, any other controller drives an
  Xbox 360 controller.

**Home / PS button diagnostics.** The launcher requests that macOS leave this button to SteamOS,
but macOS can override that preference. If it works over USB but not Bluetooth, compare
Settings → Controller's live **Home** indicator and send a report after pressing and releasing
the button on each connection. The launcher log records whether GameController exposes Home,
its system-gesture binding, button and profile callbacks, and whether the Home event was queued
for the guest pad port; `pad state` includes the current Home state. This distinguishes host input
handling from guest delivery without assuming that a Bluetooth failure is a DualSense passthrough
problem (DualShock 4 uses the virtual pad).

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

**Steam Controller passthrough.** With **Appears in SteamOS as** Automatic or Steam Controller, a
Steam Controller (2026) goes to SteamOS as itself through the same uhid path, so Steam drives its
trackpads, gyro, back buttons and haptics with its own driver. Alone it is player 1; with
**Additional controllers** on, a Steam Controller next to another controller (for example a
DualSense on player 1) becomes the next free player instead of being dropped:
- connected to the Mac over Bluetooth LE (`28de:1303`): passed through with its own IDs and the
  Bluetooth bus. GameController does not show it, so it does not need a GameController controller,
  and it cannot wake a sleeping guest (HID input is dropped while the VM is paused);
- through its Puck (`28de:1304`): interfaces 2–5 of the Puck are its controller slots, with the
  controller's own report descriptor. SDL and Steam take the Puck's controllers only by USB interface
  number, which a uhid device does not have, so the slot that carries controller state goes to
  SteamOS as a wired Steam Controller (`28de:1302`, USB bus); a slot without controller state for
  2 s is removed again (controller off, moved to another slot or to Bluetooth), and the
  GameController pad of the Puck takes over. That player's Steam Controller is passed through
  only when exactly one player's GameController controller is a Steam Controller and exactly one
  Puck slot is live; otherwise those players keep uinput pads, since the slots cannot be matched
  to their controllers reliably.

Its report descriptor has keyboard and mouse collections (the controller's desktop mode), so macOS
opens it only with System Settings → Privacy & Security → **Input Monitoring**: the launcher asks
for it and opens the device as soon as it is granted (`hid passthrough: Input Monitoring granted, reopening the HID manager`).
macOS returns a Bluetooth LE controller's 64-byte feature report 1 (Steam's command channel) as
65 bytes, so GET_REPORT buffers have headroom over the descriptor's sizes.

**Several controllers.** With Settings → Controller → **Additional controllers** (on by default,
applies now) further connected controllers are players 2–4, each with a gamepad of its own in
SteamOS, for local co-op. Every player has a virtio-console port: `fx.pad` for player 1, as above,
and `fx.pad2` … `fx.pad4`, each served by an instance of `fx-pad@.service` named after its port
(the same `fx-progress-agent pad` with `FX_PAD_PORT`, started by udev), so the protocol on a port
is the same for every player, and a pad's rumble plays on the controller that drives it. A player
gets a controller once the guest's service of that port said `hello`: a guest layer without
`fx-pad@.service` keeps the one pad. The controller chosen in Settings is player 1 unless a
Bluetooth LE Steam Controller already occupies that player. A player keeps their controller until
it disconnects (the others do not move up), and a reconnected controller takes the first free player.
A Bluetooth LE Steam Controller also keeps its player: a lower player's disconnect does not move
it up, and a newly connected GameController controller cannot displace it. Disconnecting the BLE
controller frees its player; reconnecting it takes the lowest free usable player.
**Appears in SteamOS as**, swap A/B and dead zone apply to every pad (with
Automatic each pad is the kind of its own controller). Only player 1's
DualSense is passed through, and not while another player's controller is a DualSense too
(GameController does not say which HID device is whose): both get uinput pads then. A Steam
Controller is passed through on any free usable player (see above). While the VM
runs, the live input test in Settings → Controller badges each controller with its player
(**Player 2**). Off: only player 1 is used; a BLE Steam Controller does not displace an existing
GameController controller, and a new GameController controller waits if BLE already owns that player.

`--control-fifo` test commands: `pad on` (a pad without a controller, as `--input-selftest` uses),
`pad off`, `pad test` (A + left stick) — each takes a player number (`pad on 2`; 1 if not given) —
and `pad state` (the guest's pads, their last rumble level, whether the guest takes HID devices,
connected DualSenses and Steam Controllers, and input reports passed through).

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
full selected disk size plus the temporary rootfs, even before games are installed. There the download cache also costs far
more than its ~4.4 GB of data: macOS keeps each chunk file's provenance attribute in an extra `._` file, and every file and
folder occupies whole clusters (128 KiB on a 2 TB drive), about 28 GB in all. The launcher checks this space before
reconstructing the rootfs, and on exFAT deletes the chunk cache before allocating the disk when the volume would otherwise
be too full (`--keep-cache` keeps it and needs room for both).
Expected location failures (an existing destination, busy cache, read-only volume, missing write permission,
full volume, disconnected drive, a destination or cache folder that disappears during creation, or
filesystem I/O error) are logged with guidance, not sent as errors to Sentry,
including failures after creation has started. Metadata/bundle connectivity failures (offline, DNS, timeout,
connection loss, and system TLS rejection) follow the same policy as exhausted desync download retries.
HTTPS certificate validation is never bypassed. Unexpected creation and bundle-signature failures still report,
with the original technical diagnostic in event details.
The launcher logs the target/cache filesystem type. A chunk-cache rename collision is retried once with a
single worker and no cache. A rootfs hash mismatch is checked again with a sequential read to distinguish bad
sparse-extent metadata from bad file bytes. If the bytes are bad, the temporary rootfs and chunk cache are
deleted and downloaded again once, serially without a cache; both disk slots are cleared before retrying.
A second integrity failure remains reportable; no disk is published without matching the signed manifest.
Disk creation compares the partition table read back with what it wrote, both in the private file and
after publishing the disk. A difference (STEAMAC-6J, exFAT), or a reconstructed rootfs that disappears
before the disk is allocated (STEAMAC-68), stays reportable with file identities and the differing GPT
fields; the window suggests Disk Utility First Aid or another drive.

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
   success), so Stop/Resume (or rerunning the command after Ctrl+C) continues where it left off; a
   complete `<disk>.rootfs-tmp` left by an attempt that failed later is deleted first (desync never
   reuses it, and it would take its space twice). One creation per cache at a time: a second one (another
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

Space on sparse-capable volumes: ~20 GB on the disk volume during creation (~9 GB afterward), plus ~6 GB of cache.
desync preallocates the full 10 GiB temporary rootfs on macOS, even on APFS; only the two destination slots stay sparse.
The preflight estimate includes this allocation and a safety margin (~27 GB total for SteamOS 20261007).
The cache is deleted after success unless `--keep-cache` is specified.
Checks: `work/out/steamac-vm --selftest-provision` —
GPT against the Docker-built disk (`work/out/steamos.img` is opened read-only;
`--reference-disk IMG`), CMS/squashfs against the `work/cache/rootfs` cache, cpio, SHA-512 crypt.
The self-test also checks network messages, log-only network/filesystem failures, unexpected-error reporting,
and sparse/sequential rootfs copying into both slots. To exercise an actual TLS failure without sending events,
point `STEAMAC_PROVISION_TEST_TLS_URL=https://localhost:PORT/` at a local server with an untrusted
certificate when running `--selftest-provision`; it prints the message and checks that no report is produced.

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
| **KosmicKrisp** — Mesa on Metal 4 · macOS 26+ (`kosmickrisp`, default where available) | `host/kosmickrisp/`: Mesa main + open MRs (geometry shaders !44786, transform feedback !44928, tiled images in host-pointer memory !44929, device-local memory type !44221, linear render targets !44782/!44222) + steamac's patches (explicit LINEAR row pitch, LINEAR input attachments, `fillModeNonSolid`, which DXVK requires, 8-sample requests as 4, single texel alignment for texel buffers and timestamp pools over several Metal counter heaps, which vkd3d-proton requires; R32G32B32 uniform texel buffers, as which vkd3d-proton views 12-byte structured buffers (such a view crashed the VM in The Witcher 3, STEAMAC-2Z); one Metal compiler shared by all guest devices, also on macOS 27 (on its betas 1–4 a compiler per device corrupted the heap when a guest session started, STEAMAC-31); zero-element texel buffer views become null descriptors and oversized views are clamped to Metal's per-format capacity after alignment (2^28 texels, three per RGB32 element), not to the conservative advertised limit: no invalid width reaches Metal and no asynchronous Venus creation failure kills the guest at first use (Spider-Man, Uncharted, Forza Horizon 6, Dragon's Dogma 2, STEAMAC-3J/3F/3S/3R); buffer-backed texel buffer views share their buffer's residency (over ~1M views exhausted the residency set and aborted, DOOM, Wolfenstein, STEAMAC-3V/3T); occlusion queries past one 32768-entry visibility buffer and timestamp pools on counter heaps shared by every guest device of the process (Metal allows 32 per process), so query pools of Dota 2 / Counter-Strike 2 no longer fail to create; timestamp writes outside render encoders coalesce resolves and split recordings every 16384 writes, avoiding Metal 4 command-buffer capacity failures (Ratchet & Clank: Rift Apart, #45; writes beyond 131072 still read 0); sparse binding/residency on Metal 4 placement sparse resources and sampler min/max reduction emulated in shaders before Apple10, which give vkd3d-proton Tiled Resources Tier 2 and so D3D12 feature level 12_0; a compile pool queues only the predicted plain/minmax program and compiles the other at first use; depth/stencil state is built once at creation independently of that choice, so bind never waits; translated shader caches include codegen settings such as `force_robustness`, and compiled Metal objects use bounded LRU tables with ownership-checked publication) | faster: Stellar Blade Demo ~29 FPS against ~18 on MoltenVK on an M1 Max (split-screen video: `docs/media/stellar-blade-moltenvk-vs-kosmickrisp.mp4`); Steam UI, DXVK games and Stellar Blade Demo (D3D12, vkd3d-proton) run, its first run spends ~28 min compiling shaders on an M1 Max. macOS 26+ only; built only when the build host runs macOS 26+, otherwise MoltenVK is used. Known gaps (host repros): transform feedback with strip geometry shaders and its overflow counter (draft MR); within one render pass, depth writes to unmapped tiles stay in tile memory and later draws of the pass test against them (Tiled Resources Tier 2 allows this cache; vkd3d-proton's `test_sparse_depth_stencil_rendering` expects them dropped); no sparse 3D textures (Metal's 3D tiles are not Vulkan's standard 3D blocks), hence no Tiled Resources Tier 3 |
| **MoltenVK** — Metal 3 · macOS 15+ (`moltenvk`) | `host/moltenvk/`: the UTM fork + steamac's patches | every supported Mac; the default on macOS 15 and in builds without KosmicKrisp (source builds on macOS 15; the release DMG includes KosmicKrisp since 1.7) |

Switching changes the Venus driver identity (pipeline cache UUID), so Steam and games rebuild their
shader caches. A pipeline the host driver cannot build is a placeholder in virglrenderer: its draws
and dispatches are dropped, the driver never sees `VK_NULL_HANDLE`.

The host drivers refuse the Vulkan inputs that would otherwise trip a Metal assertion that ends the
whole VM, and log the Vulkan arguments. KosmicKrisp: an image view with an empty or out-of-range layer
range, or between color formats of different block sizes, fails with `VK_ERROR_FORMAT_NOT_SUPPORTED`
(STEAMAC-62/3); a descriptor a shader uses but the pipeline layout lacks reads zero and drops writes
(STEAMAC-6H); image copies through a scratch buffer stay inside the mip and cover every volume slice
(STEAMAC-5E/5F); LINEAR images with more mips, layers, depth or samples than the format query
advertises fail in `vkCreateImage` (STEAMAC-3F/6Y); a cached precompiled NIR shader carries a BLAKE3
checked before it is deserialized, so a damaged entry is a cache miss instead of a crash. The
STEAMAC-6M/6K/7J/7H/7P crashes in `vkCreateComputePipelines` had another cause: Mesa's NIR serializer
stored source indices in 20 bits, so shaders with more than 2^20 objects came back with sources pointing at
unrelated objects; larger indices now follow in a separate word (`host/kosmickrisp/test/nir_object_ids.c`
round-trips a shader with over a million defs in the KosmicKrisp build).
Mesa's barrier fallback on macOS let `util_queue_finish` hang a device teardown (shader disk cache);
`host/kosmickrisp/test/util_queue_finish.c` runs in the KosmicKrisp build. MoltenVK: a pipeline blending
an attachment Metal cannot blend (R32_UINT) fails (STEAMAC-3A); vertex-stage auxiliary buffers are
packed into Metal's 31 buffer slots (STEAMAC-67); full 32-bit specialization constant IDs work
(STEAMAC-6A); an optimal image in imported host memory gets a placement heap, so 2D views of a 3D image
used as render attachments no longer dereference a missing heap (STEAMAC-76/77); failed pipelines log
complete small shaders, Metal descriptors, blend state and fragment output indices (STEAMAC-41/75).
SPIRV-Cross fixes the MSL errors of STEAMAC-33/6D/6E/5M/5K/2N/5C/6V and keeps a dual-source blend
output's second index when it packs outputs (STEAMAC-75)
(`host/moltenvk/repro/sentry-msl.sh` compiles each reconstructed shader). wmtr (DXMT) refuses only
garbage or freed object handles, ends encoders a game left open when its context goes away (also past
65,536 live objects, STEAMAC-70), and refuses a render pipeline without a vertex function
(STEAMAC-6S/6Z); `wmtr/tests/wmtr_dxmt_test.m` drives DXMT's own command lists through the shipped
executor on the GPU.

**Allow DXMT (D3D11 on the Mac's Metal), experimental.** Settings → Advanced → **Allow DXMT (D3D11 on
the Mac's Metal)** is off by default and applies on next start (`--wmtr-lib PATH` or `--no-wmtr` for one launch).
The app bundles `libwmtr_host.dylib`; the guest layer carries DXMT's
`{d3d11,dxgi,d3d10core,winemetal}.dll` and `winemetal.so`. With the toggle on, the launcher offers
libkrun's wmtr virtio-gpu context (patch 0018, capset 30) and boots with `steamac.gfx=dxmt`.
The guest's `steam-gfx-path` swaps DXMT into every installed x86-64 Proton and watches for Proton
installs and updates; turning the toggle off boots with `steamac.gfx=vulkan` and restores Proton's
original files. DXMT's dlls are x86-64 with a Wine unixlib, which only an x86-64 Proton loads (in Proton
11.0 (ARM64)'s ARM64EC Wine, winemetal's unix side does not come up and games report "could not load
d3d11.dll"), while this Steam client maps every Windows title to Proton 11.0 (ARM64) (`proton-stable`,
priority 85). Before Steam starts, `steam-compat-default` gives **only games whose profile selects DXMT**
a per-game `CompatToolMapping` entry for **Proton 10.0** at priority 250, and only on a DXMT-enabled
boot. Eligible titles are installed Windows games (`libraryfolders.vdf` and `appcache/appinfo.vdf`:
type game/demo/application, oslist with windows but not linux) without a user-owned tool choice.
Every other game keeps Steam's default tool, **Proton 11.0 ARM64**, with DXVK/vkd3d-proton on Venus.
The old blanket mappings are removed on the first Steam start; subsequent profile changes or
newly installed games are applied at the next Steam start. User edits in Steam remain untouched.
This is not just a DLL choice: some games crash under x86-64 Proton 10.0 + FEX regardless of the
DLLs used. Stellar Blade Demo (3564860), for example, ends SEH recursion with
`virtual_setup_exception stack overflow` there, but runs on Proton 11.0 ARM64.
Steam downloads Proton 10.0 (x86-64, under FEX in Steam Linux Runtime 3.0) on the first DXMT game
launch, and `steam-gfx-path --watch` puts DXMT into it. Proton Experimental and x86-64 Proton 11.0
need Steam Linux Runtime 4.0, which the arm64 client refuses to install ("Invalid platform").
The wildcard entry ("0") is never used: Steam applies a high-priority wildcard to its own tools
as well and emptied the FEX tool that way. Turning Allow DXMT off removes the script's mappings.
D3D12 on Proton 10.0 runs Wine under FEX instead of ARM64EC, costing CPU time.
Measured end to end on an M1 Max: Death's Door (Unity, D3D11)
starts on Proton 10.0, reports the renderer as "Apple M1 Max" and draws through the executor's layer.
Measured on that M1 Max (macOS 27, VM with 6 vCPUs / 8 GB at 120 Hz, KosmicKrisp): Death's Door's title
screen ~41 FPS on the default Proton 11.0 (ARM64) + DXVK path, ~117 on DXMT (held by the 120 Hz display);
d3d11bench with 100 draws and 16 full-screen passes 44 / 50 (Proton 10.0 + DXVK) / 100 FPS, with 2000
draws and 4 passes 133 / 139 / 115 (DXMT stops at the display's 120 Hz, the Vulkan path goes past it).
Medians of three 20 s runs launched through Steam (DXMT: six over two boots); details on the site.
DXMT's winemetal calls cross virtio-gpu to an
executor **inside the VM process on the Mac**, which presents a `CAMetalLayer` in the VM view.
That layer would cover the guest compositor's cursor; the launcher draws the game's own cursor above
it instead, with gamescope-compatible sizing. Cursor tracking is host-gated and DXMT-only: it runs
only when game focus permits the overlay and an actual wmtr layer is attached and visible, not
merely because Allow DXMT is on (see “Cursor on the DXMT path” under “How it works”).
D3D12 (vkd3d-proton) and native Vulkan remain on Venus; this path is for **D3D11/D3D10 only**, not D3D9.
DXMT still has compatibility gaps, including **no stream output**; expect first-launch shader
compilation and stutter rather than assuming Steam's Vulkan shader cache covers Metal.

**Security: while this is on, guest programs can run code on the Mac with your user's rights.**
The in-process executor and DXMT's raw-host-address protocol are not a VM security boundary.
That is why this path is off by default and experimental; an executor fault can also stop the VM.
Enable it only for guest software you trust.

Before starting the VM, the launcher sets `STEAMAC_WMTR=1`, `STEAMAC_WMTR_LIB` (the **Executor library**
override, otherwise `@rpath/libwmtr_host.dylib` from the app's Frameworks or `work/out/host/lib`) and
`WMTR_PRESENT=overlay`; all three are cleared when off. A missing/unloadable library or missing
`wmtr_host_abi_version` disables the path for that boot (logged and red in Settings; explicit
`--wmtr-lib` exits with the reason); libkrun rejects another ABI version. Problem/crash reports
carry `wmtr on|off`.

**Build DXMT.** On Apple silicon macOS, install Xcode's Metal toolchain
(`xcodebuild -downloadComponent MetalToolchain`), Rosetta (`softwareupdate --install-rosetta` for the
x86-64 Wine build tool), Homebrew and Docker/OrbStack with `linux/amd64` support for the client step.
The script installs `meson ninja cmake pkgconf zstd`. If Metal tools are unavailable,
`DXMT_PREBUILT_METAL` can name a directory containing `dxmt_command.metallib` and
`air_{msad,samplepos,tessellation}.air` built from the same pinned sources.

```sh
host/dxmt/build.sh fetch llvm native host pe client payload  # default steps, in order
scripts/build-image.sh layer                               # include the guest payload
host/launcher/build.sh                                     # bundle executor + refreshed layer
```

`fetch` verifies the pinned DXMT/DirectX-header tarballs and applies `host/dxmt/patches`;
`llvm` builds static LLVM 15.0.7 (about 10 minutes on an M2, reused while the pin matches).
`native` builds airconv in `work/build/dxmt-native`; `host` builds/tests/installs the executor to
`work/out/host/lib/libwmtr_host.dylib`. `pe` cross-builds the four DLLs into `work/out/dxmt-pe`;
`client` builds/tests `wmtr/build/x86_64-linux/winemetal.so` in Docker; `payload` stages
`work/out/dxmt/{x86_64-windows,x86_64-unix}` for `/usr/lib/steamac/dxmt/` in the guest layer.
Steps can be rerun individually; `host/dxmt/build.sh` with no arguments runs them all.

Credits: [StonkGuy](https://github.com/StonkGuy/steamac) for the wmtr remoting path and integration;
[DXMT by 3Shain (Feifan He)](https://github.com/3Shain/dxmt) for D3D11/D3D10 on Metal.
The cherry-picked fixes in `host/dxmt/patches` retain their authors: David Grinberg, osy,
Holly Hamilton, SteveTanSaMa, hanzpo, Mybono, NerRobDog, 时雨 and Jakey-Jakey
(details in the patched DXMT `STEAMAC-README.md`).

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
  the next VM launch. An uncaught Objective-C exception is grouped by its reason (the first-throw
  message and stack from stderr), not under `CPPExceptionTerminate` (STEAMAC-58);
- A few errors (no more than once per fingerprint per process, subject to a global limit; the same
  fingerprint is not sent again for at least a day, or 30 days for shader compilation errors): the
  guest GPU context becomes fatal/device lost (vkr “fatal decoder state”, “device lost”), MoltenVK
  pipeline compilation errors (`[mvk-error] … compile failed`; if MoltenVK printed MSL source
  (`[mvk-msl] …`: the first 40 lines and lines around the error), it is sent in extra `msl_source`,
  not in breadcrumbs; the vkr line “pipeline … creation failed on host” is a breadcrumb only), a
  Rust panic in libkrun (`thread … panicked at`), failure of initial disk provisioning (`provision
  failed`), failure to create a disk, unexpected VM exit (nonzero exit code or signal when shutdown
  was not requested by the user), and the idle indicator's “SteamOS is not responding”. For a VM
  process crash, the supervisor's report adds macOS's own crash report of it
  (`~/Library/Logs/DiagnosticReports/steamac-vm-*.ips`, matched by pid): the crash site in the title
  and the `crash_site` tag (reports group by it), and in extra `macos_crash_report` the exception, the
  Application Specific Information lines (libmalloc's message on a heap corruption trap) and the
  crashed thread's first 16 frames (library and symbol names);
  Not-responding reports include `stall_history`: up to 32 one-second GPU command-counter, heartbeat age,
  guest uptime/load, process CPU-time and host polling-gap samples, even with performance statistics
  off (STEAMAC-8). Missing agent heartbeats alone do not prove that the whole guest or GPU hung.
  The same samples are logged once when an idle indicator lasts 10 s, including with a live
  heartbeat, so Report a Problem can diagnose game stalls without enabling performance statistics.
  After a host scheduling gap (the launcher itself not running for seconds) the detector watches a
  fresh heartbeat window before reporting, instead of counting the gap as a guest hang.
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
  (transitions are also written to the log: `memory pressure: …`). Force Quit from the app menu (or a
  second shutdown request) is a requested exit, not a report: the VM process exits with status 3, which
  the supervisor recognizes without the `user-exit` marker file (with the Mac's disk full the marker
  could not be written, STEAMAC-15);
  `memory_history` adds up to two minutes of pre-exit VM footprint and host memory samples (every
  10 s); the separate report-time snapshot is labelled post-exit because VM memory is already freed.
  GPU-fatal and SIGKILL reports add the VM process's recent GPU/heartbeat history and process, Metal,
  Vulkan-allocation and shared-memory snapshots; these counters overlap and are not a sum. A second
  VM refused because its disk is in use exits with status 4: the explanation, no report.
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
uploads them and every Mach-O the app ships (executable, Frameworks, helpers in Resources; each must pass
`sentry-cli debug-files check`) with `sentry-cli --url https://sentry.fxgam.es debug-files upload --wait`,
and keeps the dSYMs as `work/out/dist/FX-Steam-Launcher-<version>-dSYMs`. A notarized build requires
`SENTRY_AUTH_TOKEN`, `SENTRY_ORG`, and `SENTRY_PROJECT` (checked before signing; `--no-sentry-upload` opts
out): 1.9 shipped without an upload, and crashes in `steamac-vm` and libkrun stayed unsymbolicated.

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

## Game statistics

Which games start and how fast they run on which Mac, collected from players who agree and shown
to everyone at <https://fxgl.github.io/steamac/games.html> (`docs/games.html`).

The guest agent watches Steam's game scopes (`app-steam-app<appid>-*.scope`, the same cgroups
**Pause the game** freezes) on its 1 s heartbeat and reports `game-start <appid>`, `game-mem <appid>
<anon_kib> <guest_used_kib>` every 5 s (the game's anonymous memory and the guest's used memory),
`game-proton <appid> <version>` (the prefix's `compatdata/<appid>/version`), immediately followed by
`game-gfx <appid> dxmt|vulkan` (the actual graphics path), and `game-exit <appid>`;
`game <appid> <name>` follows the first `game-start` or focus of an app id per boot. The launcher
(`GameStats.swift`) makes one report per game run: how long it ran and had focus (not paused, VM
not suspended), whether a window ever appeared and after how long (a run without one is a failed
start), frame rate from the guest's scanout-0 flush intervals while the game has focus (average,
median, 1% low, hitches over 50 ms per minute; gaps over 1 s are left out; libkrun's
`present_frame`, the same flushes `--perf-stats` reports), peak game / guest memory, the VM
process's peak `phys_footprint` on the Mac, resolution, Proton version, and the end (`exit`,
`shutdown`, `session`). Each report carries the Mac (model, chip, P and total cores, GPU cores,
RAM, macOS), the VM (vCPUs, RAM, Vulkan driver, wmtr, refresh rate, SteamOS build) and the
launcher version.
New session and rating reports use schema `v:2`, with optional `gfx` (`vulkan` or `dxmt`) and `env`
(the allowlisted launch words described in “Per-game profiles”, at most 256 characters). The actual
graphics path comes from `game-gfx`; ratings use the last session's graphics path and launch words.
The service still accepts v1 (including previously saved sessions), storing its `gfx`/`env` as NULL.
Invalid v2 assignments are rejected with HTTP 400; valid ones are sorted by name, last duplicate wins.

Every report is kept on this Mac (`~/Library/Application Support/es.fxgam.steamac/game-stats.json`,
20 sessions per game) and listed in **Settings → Games**. Nothing leaves the Mac until **Share
game statistics** is on: after the first game with a window the launcher asks once, in a window
beside the VM window that does not take the keyboard or the captured mouse (**Share** / **Don't
Share**); the switch in Settings → Games changes it at any time. While it is on, finished sessions
and ratings go to the statistics service (`POST /v1/sessions`, `POST /v1/ratings`), sessions
recorded earlier included; a game whose **Share** box is off sends nothing and its rating is
withdrawn (`"rating": "none"`). Uploads go one at a time; HTTP 400/413 drops a report, anything
else is retried after 10 minutes, at the next session end or the next boot.

Privacy: no name, user or computer name, Steam account, files or arbitrary typed text (only the
allowlisted graphics launch words above are shared); the install ID is a
random UUID used only for distinct-Mac counts and rate limits (not the crash reports' ID); the
service uses the client address only as a transient rate-limit key and never stores it.

The page publishes aggregates only, never single sessions, and lists the chips each game was tested
on. Configurations group by chip, RAM, Vulkan driver, graphics path and launch words (`gfx`/`env`;
`wmtr` is retained for compatibility). For old rows, NULL `gfx` means `vulkan` when `wmtr=0`,
but unknown when `wmtr=1`: permission to use DXMT does not prove a game used it.
Its **My Mac** filter keeps only reports from Macs that are not better than the visitor's (GPU cores,
RAM and performance cores each at most the given value; the API's `max_gpu_cores`, `max_ram_gb`,
`max_pcores`): what runs there should run here. **Open Statistics Page** in the launcher passes this
Mac's values (`?chip=…&gpu=…&ram=…&pcores=…`) and turns the filter on; the page remembers them.

`GET /v1/games/<appid>` also returns `recommended` (or `null` if no profile qualifies).
It groups `(driver, gfx, env)` across all chips within the same My Mac filters, requiring at least
two distinct installations across sessions or ratings; unknown graphics paths cannot win.
Score = `(well + 0.5 × issues) / total ratings` (zero without ratings); ties favor higher
`launch_rate`, then lower `early_exit_rate`, with missing rates last and deterministic
driver/graphics/env ordering after that. The result includes driver, graphics path, launch words,
install/session counts, ratings, median average FPS and launch rate. The site and launcher show
the recommendation, but it is never applied automatically.

Service: `services/game-stats` — a Cloudflare Worker with a D1 database (strict validation,
idempotent session IDs, 30 POSTs per minute per address, a daily cap per install, aggregates
`GET /v1/games` and `GET /v1/games/<appid>` cached for 5 minutes in D1, because the Cache API does
nothing on `workers.dev`). Deploy once:

```sh
cd services/game-stats && npm install
npx wrangler login
npx wrangler d1 create steamac-game-stats      # put the printed database_id into wrangler.toml
npx wrangler d1 migrations apply steamac-game-stats --remote
npx wrangler deploy                            # prints https://steamac-game-stats.<account>.workers.dev
```
For an existing deployment, migration `0002_profiles.sql` adds `gfx`/`env` to sessions and ratings
and updates the grouping indexes while preserving v1 data; `0003_responses.sql` adds the response
cache table. Run `npx wrangler d1 migrations apply steamac-game-stats --remote` **before**
`npx wrangler deploy`.

The Worker URL goes into `host/launcher/Info.plist` (`SteamacGameStatsURL`) and `docs/assets/games.js`
(`API`). Local: `npx wrangler d1 migrations apply steamac-game-stats --local && npx wrangler dev`,
`npm test`.

Tests: `STEAMAC_GAME_STATS_URL` overrides the service (and enables uploads in the dev launcher
`work/out/steamac-vm`, which otherwise sends nothing), `STEAMAC_GAME_STATS_FILE` the local file;
FIFO `--control-fifo`: `guest game-start <appid>` etc. feed the tracker, `stats state|flush|ask|dump
PNG|reset-question`, `stats press share|decline`, `settings games`.

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
  `dmesg`, `systemctl --failed`, `os-release`, `layer-release`, `/proc/cmdline`, `df`/`free`,
  thread IDs/states/CPU/wait channels and command names (`threads.txt`, no command arguments), tails of
  Steam client logs (`console_log`, `stderr`, `bootstrap_log`, `compat_log`, `connection_log`,
  `webhelper`, `cef_log`, `shader_log`, `steamui_*`, Steam Input's `controller`, `controller_ui` and
  `cloud_log`) and Proton logs (`~/steam-*.log` from `PROTON_LOG=1`,
  `version` and `config_info` of prefixes in `compatdata`), FEX tool build ID / Steam manifest /
  configuration, an opt-in FEX log, memory limits, memory/IO/CPU pressure (`/proc/pressure/*`),
  `/proc/vmstat` and three `vmstat` samples, SteamVR and streaming log tails (`vrserver`,
  `vrcompositor`, `vrmonitor`, `vrwebhelper`, `vrstream`, `streaming_log`, 256 KiB each, IP addresses
  redacted), and the last 512 KiB of American Truck
  Simulator's `game.log.txt`. For an ATS emulator crash, set its Steam launch options to
  `FEX_SILENTLOG=0 FEX_OUTPUTLOG=/home/steamos/fex-amtrucks.log %command%`, reproduce, and report;
  the collector includes the last 512 KiB of that log. Remove the launch options afterwards.
  Without Proton logs the archive notes that `PROTON_LOG=1 %command%` as a game's launch options,
  one reproduction and a new report are needed to see a Windows game's own failure.
  FEX re-raises a crash of the emulated game from its JIT code, so the core's stack shows only an
  anonymous AArch64 address. To record where the x86_64 code faulted, create
  `~/.local/share/Steam/steamapps/compatdata/<appid>/fex-emu/AppConfig/<executable>.json` (ATS:
  `270880/fex-emu/AppConfig/amtrucks.json`) containing
  `{"Config":{"Env":"LD_PRELOAD=/usr/lib/steamac/x86_64/fault-report.so"}}`, reproduce, and report.
  Steam launch options cannot do this: FEX's compat tool removes `LD_PRELOAD` from the environment.
  On SIGSEGV/SIGBUS/SIGILL/SIGFPE/SIGABRT the library writes the x86_64 RIP, the fault address,
  the registers, a backtrace with the module and offset of every frame, and the memory map to
  `~/.local/state/steamac/fault-report.txt`. The file stays under 256 KiB and the report includes it
  as `fex/fault-report.txt`. Then the game's own handler or the default action runs, so the crash and
  its core dump are unchanged. Without that file the library is never loaded; delete it afterwards.
  Completed crash metadata is exported by a root hook for `steamos` only (root-owned, mode 0640);
  raw cores remain private and are never attached. `coredump-pending.txt` identifies dumps still
  running: reports do not wait for them; send another report once they finish. Namespace-aware
  stack extraction resolves pressure-vessel libraries where symbols are available (FEX JIT code
  may still be unsymbolized). Core processing limits are not lowered: oversized cores would lose
  their backtraces, and `Storage=none` still writes a full temporary core. Steam IDs (`[U:1:…]`,
  7656119…, account IDs as in `userdata/<n>`), Steam account/persona names and email addresses are replaced with placeholders before
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
| `host/moltenvk/` | MoltenVK utmapp `geometry-shaders` @05604465 + patches: depth_clip_enable, YCbCr arrays, null descriptors, geometry shader emulation for zink/DXVK (vertex stride, instancing, adjacency, fans, SCALED formats, packed vertex formats: 10-10-10-2, RG11B10F, RGB9E5, BGRA8, `gl_in`), transform feedback (DXVK stream output) and its queries (SO statistics), query result availability on copy (DXVK occlusion queries via Venus), atomics on vector components at buffer addresses (BDA, vkd3d-proton), texel buffers with offsets at any texel (vkd3d-proton), writes to small push-descriptor buffers with robustness2, variable-count descriptor arrays as runtime arrays (Metal kept 32 MB per vkd3d-proton heap array and program), allocation of auxiliary buffers, deferred release of Metal resources, patch hash in the pipeline cache UUID, `VK_NULL_HANDLE` descriptor sets in binds, fragment outputs converted to their color attachment's numeric type, zeros for vertex shader inputs without a vertex attribute, integer vertex inputs read through float formats, null-checked YCbCr helper samplers, unsupported texel buffer formats rejected; tests in `repro/` run under Metal validation (also on KosmicKrisp: `REPRO_DRIVER=kosmickrisp`); `bench/run.sh <libdir>…` compares performance of changes between builds; `bench/shaders.sh <dump or pack>` measures a game's shader compilation (SPIR-V → MSL, MSL → Metal library, pipeline states; cold/warm, threads) from a MoltenVK shader dump or a 10% sample made with `bench/pack.py` |
| `host/kosmickrisp/` | KosmicKrisp (Mesa main @ce576c29) + open Mesa MRs and steamac patches (see “Vulkan driver”), built without LLVM at runtime (`-Dllvm=disabled`, `mesa_clc` from a first build), `-Db_ndebug=true`; macOS 26+ only |
| `host/dxmt/` | Pinned DXMT + patches, static LLVM 15, native airconv, Windows DLL cross-build and guest payload; `build.sh fetch llvm native host pe client payload` |
| `wmtr/` | BSD-3-Clause winemetal remoting: guest `winemetal.so` over virtio-gpu to `libwmtr_host.dylib` (DXMT/LLVM linked in), presenting a CAMetalLayer inside the VM view |
| `host/libepoxy/` | libepoxy 1.5.10, upstream macOS Meson options, built for macOS 15.0 instead of copying a Homebrew bottle |
| `host/virglrenderer/` | virglrenderer UTM `macos-next` + merge with upstream main (venus-protocol 1.1.3) + LINEAR modifier, shm import as host memory, stubs for failed pipelines (draws dropped in virglrenderer), recreation of rejected cache, deferred shm unmap, thread QoS, Vulkan driver opened at runtime (`VKR_VULKAN_DRIVER`) |
| `host/libkrun/` | libkrun v1.19.6 + patches: `VIRTIO_GPU_F_BLOB_ALIGNMENT` (16K), SME mask for M4, 2D resources without virgl, `SET_SCANOUT_BLOB`, SHM blob mapping, Venus fence signaling, virglrenderer logs, `krun_display_resize` (resolution changes on the fly), vCPU/GPU thread QoS |
| `host/launcher/` | `steamac-vm` (Swift/AppKit): Metal window (optional MetalFX super resolution), “FX STEAM LAUNCHER” overlay with boot/shutdown progress, guest resolution = window size (× the screen's backing scale with Retina resolution) at constant DPI (EDID from the physical screen size), keyboard/mouse/tablet, the guest's Xbox 360 / DualSense / DualShock 4 pad from GameController.framework with rumble or a DualSense passed through as raw HID (`fx.pad`), network via gvproxy, VM restart on guest reboot, `--perf-stats` |
| `guest/kernel/` | Linux 7.2.9, everything built in, 4K pages, 16K blob-node alignment, Apple TSO for FEX; uhid, hidraw and `hid-playstation` (with the LED classes it needs) for the passed-through DualSense |
| `guest/mesa/` | From the pinned Mesa: Venus ICD for aarch64 (Proton, gamescope, zink) and x86_64/i386 (FEX graphics provider); zink GL stack (libgallium, GLX/EGL/GBM) over the stock one in both, with backports in `guest/mesa/patches/` (Mesa 6abefa51: zink rebuilds the pipeline when only the vertex layout changes; without `VK_EXT_vertex_input_dynamic_state`, which Venus on Metal lacks, GL games otherwise draw with stale vertex formats); x86_64 fault reporter for emulated games (`/usr/lib/steamac/x86_64/fault-report.so`) |
| `guest/initramfs/` | boot stage = “bootloader”: A/B slot selection with attempt counter, partsets, overlays for `/etc` and `/usr`; initial provisioning of the launcher-created disk (`steamac.provision=1`: static mkfs.fat, mke2fs, btrfstune in initramfs); `steamac.ssh=0` — no SSH server; launcher config payload (`steamac.config=1`) — new `steamos` password; `steamac.tz=` — the Mac's time zone in `/etc/localtime`; untouched procfs at `/run/steamac/proc` for Flatpak sandboxes |
| `guest/layer/` | VM layer over `/usr` (read-only erofs): file-based `splctl`, safe post-install for RAUC, `VARIANT_ID=steamdeck`, gamescope session on DRM, Desktop Mode (Plasma nested in gamescope), masks for Frame hardware services, `fx-progress-agent` progress agent (Rust, `guest/progress-agent/`, `fx.progress` virtio-console port) and its root services (`fx.clock`, `fx.sleep`, the uinput or uhid gamepad on `fx.pad`), short shutdown timeouts, QR-code Steam sign-in mode (Steam Deck client, while there is no remembered account), optional Steam client branch (`/etc/steamac/steam-client-branch`), Steam's background shader processing on by default (`steam-shader-defaults`), Steam's idle screensaver off by default (`steam-idle-screensaver`), reset of fixed system/user manager CPU affinity masks so services inherit the VM’s available vCPUs on the next layer boot |
| `scripts/` | build of `work/out/steamos.img`: GPT with Valve's partition layout (esp, efi-A/B, rootfs-A/B, var-A/B, home); `scripts/test/provision-test-disk.sh` — dev test of provisioning against a disk from Docker; `scripts/test/vkd3d-tiled.sh` — dev end-to-end check of D3D12 tiled resources and the feature level (vkd3d-proton tests of Proton 11.0, `d3d12-caps`, `vk-minmax`) in a throwaway VM |

### Cursor on the DXMT path

On wmtr, DXMT presents the game as a `CAMetalLayer` inside the VM process on the Mac. That layer is
composited above the guest scanout, so the cursor drawn by the guest compositor is covered. Tracking
starts **off** in each guest agent. The launcher sends `cursor-track 1|0` over `fx.progress` whenever
wmtr layer visibility/attachment changes and resends the current state on progress reconnect or the
guest's startup `cursor-ready` handshake. Repeated enable resends a full cursor snapshot.
1 requires both game focus permitting game layers and an actual attached, visible wmtr
`CAMetalLayer`. Vulkan and Steam/Desktop without that overlay do not need cursor tracking; unknown
host commands remain ignored for old/new host/guest compatibility.

While enabled, the guest agent (`guest/progress-agent/src/cursor.rs`) finds the Xwayland display
whose active window's `WM_CLASS` starts with `steam_app_`; XFixes support and an active game window
are required, with no root-window fallback. It fetches the initial bitmap with
`XFixesGetCursorImage`, then updates it on XFixes cursor-change
events rather than periodically polling images; `QueryPointer` samples position at most 60 Hz,
only while needed. It sends only changes: `cursor 0|1`,
`cursor-image <w> <h> <xhot> <yhot> <base64 BGRA>`, and
`cursor-pos <x> <y> <win_w> <win_h>`. The position and size are in the focused game's X window
client pixels, not the X root: a windowed game's root can be larger than its client area. A 1×1 or
fully transparent cursor is hidden, as Wine uses for a game without a cursor.

The launcher parses these in `Progress.swift` and forwards them through `Window.swift` to `VMView` in
`Presenter.swift`, which owns a transparent `CALayer` named `steamac.cursor-overlay` at `zPosition`
1000. It is shown only while a game layer is visible and the guest cursor is visible and its position
is known; it is excluded from the game-layer and Metal HUD policies and re-attached if wmtr removes
sublayers. The bitmap becomes a premultiplied-first `CGImage`. Before mapping into the view, the
bitmap and hotspot are scaled like gamescope's `--cursor-scale-height 720`: for game-window height H,
the desired size is `clamp(36 * floor(H / 720), 36, 256)` pixels. This includes gamescope's square
downsize when either bitmap dimension exceeds the desired size, with integer-truncated hotspot
coordinates; otherwise its uniform scale is at least 1, based on desired size / bitmap height.
The layer maps the X window position into the active remoted game layer's displayed drawable
rectangle (`drawableSize` aspect-fit into the layer, the same geometry wmtr gives that layer), not
into the guest picture, so a game layer whose size or aspect differs from the guest scanout does
not shift the cursor. The compositor does the final view scaling and alpha blending.

Visibility follows the **game's own cursor**, not gamescope's 3-second idle autohide. The existing
Mac cursor policy is unchanged: auto mode hides it over the picture, and capture hides it while
grabbed; tablet mode and uncaptured `--mouse capture` can show both the Mac cursor and the guest
overlay. Captured mouse-look does not by itself hide a cursor the game still reports as visible.

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

A vertex shader input without a vertex attribute in its pipeline (an SCS Truck Simulator shader reads
`in_var_NORMAL` at location 1, which the pipeline does not describe, STEAMAC-2Y; Vulkan leaves the
values undefined) failed in Metal ("missing from the vertex descriptor"), and the pipeline's draws were
skipped; such inputs now read zeros (`repro/vertex_input.c`).

An integer vertex shader input fed by a float vertex format (BLUE REFLECTION: Second Light reads
`BLENDINDICES1` as `int4` from a `Float3`/`Float4` attribute, STEAMAC-3N) failed in Metal ("cannot be
read using MTLAttributeFormatFloat3"), and characters were invisible; the attribute is now fetched in
a format-compatible type and its bits are reinterpreted (`repro/vertex_input.c`). Robust sampling
through a helper function with an immutable YCbCr sampler no longer fails to compile
(`is_null_texture`, STEAMAC-3W; `repro/texture_helpers.c`). A texel buffer view of a format Metal has
no pixel format for fails with `VK_ERROR_FORMAT_NOT_SUPPORTED` instead of aborting the VM process
(Uncharted, STEAMAC-3Q; `repro/texel_buffer.c`). A failed graphics pipeline logs each stage's entry
point, shader hash and reflected interface, for link failures and compiler errors that carry no MSL.

The SteamOS root filesystem is not modified: all changes come from initramfs and the layer. Thus
official Valve updates (RAUC + atomupd) install into the other slot and roll back normally — verified
with the 20260922 → 20260928 update and rollback.

The layer's Venus ICDs link only sonames that SteamOS updates keep (`guest/mesa/container/verify.sh`
`check_stable_needed`); they do not use libdisplay-info. SteamOS 0.6.0 (preview channel, 20261020)
replaced `libdisplay-info.so.1` with `.so.3`: the 1.9.7 ICD no longer loaded, gamescope found no Vulkan
device and the VM stayed at “Starting Steam client” (STEAMAC-72). Verified with the stable → preview
update to 20261020 (0.6.0): Steam starts on the updated slot.

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
- Heroes of Might and Magic: Olden Era (Unity, DX11) — 7 minutes without errors (offline test);
- American Truck Simulator (native Linux x86_64 under FEX, OpenGL 4.6 core through zink) — a career loads
  and the world renders on KosmicKrisp and on MoltenVK.

Stutters on the first pass are Metal compilation (~50–100 ms per new pipeline); subsequent passes take
~1 ms. On reboot after an abrupt shutdown, initramfs checks and repairs FAT on esp/efi.

## Limitations

- DirectX 12 (vkd3d-proton): feature level 12_0 on KosmicKrisp (tiled resources tier 2: sparse binding and
  residency on Metal 4 placement sparse resources), 11_0 on MoltenVK; SM 6.0 on both (no SM 6.2+ on Apple GPUs).
  Within one render pass, depth written to unbound tiles of a sparse depth attachment stays in Apple's tile memory.
  Stellar Blade Demo (UE4) runs at 1280×800, 60 FPS on an M4 Max; the first run spends minutes compiling shaders. The
  x86 emulator in Proton ARM64 (FEX) stopped it once after 20 minutes (DEP check in its protected .exe).
- Audio: virtio-snd → CoreAudio (default device or one selected in settings), latency ≈65 ms on built-in
  speakers. At boot, playback exposes up to 12 PCM channels from the output device's configured speaker
  layout, including height speakers (e.g. 5.1.2 or 7.1.4) when CoreAudio identifies them explicitly. An
  unclassified/discrete layout, or a device with more than 32 channels, gets mono/stereo; 8 channels alone
  do not imply 5.1.2, and there is no Dolby Atmos encoding. For a multichannel layout, `audio-layout`
  reads the VirtIO ALSA playback map before WirePlumber starts and replaces SteamOS's stereo policy with
  the matching Pro Audio output (timer scheduling, separate playback/capture groups: the host devices
  have independent clocks); a stereo host keeps the stock SteamOS profile. Playback follows a new
  default or unplugged output at once and rechecks the layout once a second, routing to the physical
  speakers and downmixing missing ones with headroom. Guest channel maps stay fixed for a boot
  (virtio-snd/ALSA cache them): restart the VM to expose more channels or a new layout to games.
  `STEAMAC_SND_DUMP` records guest PCM before speaker mapping. 5.1.2 was tested on hardware, 7.1.4
  only by automated mapping tests; the microphone stays mono/stereo and has not been tested.
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
