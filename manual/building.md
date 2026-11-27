# Building from source

**English** · [Русский](ru/building.md) · [简体中文](zh/building.md)

← [Manual](README.md)

## Requirements

- Apple Silicon Mac, macOS 15+, ~150 GB of free space (the disk image is sparse).
  The launcher needs Hypervisor.framework on the Mac itself: inside a macOS virtual machine (Paravirtual GPU,
  `kern.hv_vmm_present`) or without `kern.hv_support` it explains that and exits before starting the VM
  instead of reporting libkrun's `krun_start_enter failed: -22` (STEAMAC-15).
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
start over. Each check measures GPU idle time and heartbeat age at one instant, so a check the Mac
itself delayed (paging, a busy main thread) does not age only the heartbeat into “not responding”
(STEAMAC-8). The Reclaim Disk Space confirmation, error and result dialogs are sheets or separate windows, not
modal loops that stop the main queue (which delivers heartbeats) while SteamOS runs.

| Keys in the window | |
|---|---|
| Ctrl+Cmd+F | full screen (macOS turns on Game Mode: Info.plist declares a game — `LSApplicationCategoryType` `public.app-category.games`, `GCSupportsGameMode`, `LSSupportsGameMode`; `gamepolicyd` logs “Game mode status is now on”) |
| Ctrl+Cmd+G | manually capture / release the mouse |
| Ctrl+Cmd+P | toggle Apple's Metal Performance HUD (FPS, frame interval, GPU time, memory); also View → Show Metal Performance HUD and Settings > Display. The HUD library is loaded only if the HUD is on when the VM boots: turning it on takes effect after a restart, turning it off hides it at once and unloads it at the next restart. Apple's HUD has crashed the VM with KosmicKrisp (Metal 4) on macOS 26, even with the overlay hidden (STEAMAC-59/7K/7Q/9X/9Y), so turning it on with KosmicKrisp asks for confirmation; as an alternative without Apple's HUD, Settings > General > Log frame-pacing statistics records guest display timing (not game FPS). Crash reports carry the requested and effective HUD state, whether its library was injected, and the driver |
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

These and all other settings are in the [**Settings** window](settings.md#settings-window), domain
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

External APFS, Mac OS Extended, and exFAT volumes can hold the disk; APFS is recommended. FAT32/MS-DOS is
rejected before downloading because of its 4 GiB per-file limit (the temporary rootfs alone is 10 GiB), and
so are NTFS, network filesystems and unknown filesystem drivers (STEAMAC-8S: an NTFS driver refused the
92 GB disk with “File too large” after an hour of downloading); a late file-size refusal is explained and
logged, not sent to Sentry.
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
connection loss, and system TLS rejection) follow the same policy as exhausted desync download retries,
including a timeout while reading a chunk's HTTP response body (STEAMAC-92), and so does a metadata response
that is not JSON (empty, truncated, an HTML portal or proxy page) or an HTTP rejection, logged with its HTTP
status, Content-Type, length and first 160 bytes (STEAMAC-AQ: `NSCocoaErrorDomain 3840` from `stable.json`;
valid JSON with an incompatible schema still reports). If desync cannot store a
chunk in the cache (`invalid argument` on an exFAT cache, STEAMAC-90/91), the log records the failing
cache shard's state (mode, entry and temporary-file counts, read errors) for diagnosis.
HTTPS certificate validation is never bypassed. Unexpected creation and bundle-signature failures still report,
with the original technical diagnostic in event details. If the bundled desync is missing, unreadable or
not executable (STEAMAC-8K), the window explains that the installation is incomplete: reinstall from the
official DMG into Applications and check security software. One warning per installation records
translocation, desync's presence and permissions, the code-signature result and bundle-relative
Resources names and sizes; the bundle's absolute path stays in the local log and no crash-report dialog opens.
The warning also records whether the bundle, `Contents` and `Resources` still exist (type and errno): an
app moved, deleted or replaced while running loses all three (STEAMAC-AE), so the guidance asks to quit
FX Steam Launcher completely before replacing or moving it, then reopen it from Applications.
The launcher logs the target/cache filesystem type. A chunk-cache rename collision is retried once with a
single worker and no cache. A rootfs hash mismatch is checked again with a sequential read to distinguish bad
sparse-extent metadata from bad file bytes. If the bytes are bad, the temporary rootfs and chunk cache are
deleted and downloaded again once, serially without a cache; both disk slots are cleared before retrying.
A second integrity failure remains reportable; no disk is published without matching the signed manifest.
It records the sequential SHA-256 and the first 1 MiB block where a source reread differs from rootfs-A
(offset and both block digests), so unstable reads can be told from copy errors (STEAMAC-9F/9H).
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

## Distribution (DMG)

`host/launcher/dist.sh` turns the built `work/out/FX Steam Launcher.app` into the downloadable
`work/out/dist/FX-Steam-Launcher-<version>.dmg` (the app + a link to `/Applications`). A copy of the
bundle without the `SteamacBuildOut` key (the path to this build tree) is re-signed with Developer ID,
hardened runtime, and a secure timestamp, inside-out: first all loose nested Mach-O files
(`Frameworks/*.dylib`, helper programs in `Resources`, Sparkle's `Autoupdate`), then nested bundles
deepest first (Sparkle's `Updater.app`, `Sparkle.framework`), then the bundle with `steamac-vm.entitlements` (hypervisor,
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

In-app updates ([Update check](privacy-and-updates.md#update-check)): `dist.sh` adds `SUFeedURL` (`SPARKLE_FEED_URL`, by default
`https://fxgl.github.io/steamac/appcast.xml`), `SUPublicEDKey` (`SPARKLE_PUBLIC_KEY`, by default fxgl's
release key `ML1BKHcTTwKlVSLtTdMvyk7Fhwg35VN1nUp+o4fezt8=`, pinned in `dist.sh`: installed copies accept
only updates it signed), `SUVerifyUpdateBeforeExtraction`, and `SURequireSignedFeed`; a notarized build
fails unless the Keychain holds that key's private half (`generate_keys -p` prints its public half). The
EdDSA key pair was created once with `host/launcher/.build/artifacts/sparkle/Sparkle/bin/generate_keys` (Sparkle's tools
come with the SwiftPM package, the same version as the embedded framework): the private key stays in the
login Keychain, never in the repository or CI. Back it up offline (`generate_keys -x <file>`;
`generate_keys -f <file>` imports it on another Mac): without it, no update can reach installed copies
any more. `build.sh` sets `CFBundleVersion` to `CFBundleShortVersionString` (Sparkle orders versions by it).
A release, in this order (the feed must never point at assets that are not uploaded yet):

```sh
host/launcher/dist.sh
gh release create v<version> work/out/dist/FX-Steam-Launcher-<version>.dmg \
    work/out/dist/FX-Steam-Launcher-<version>-gpl-sources.tar --notes-file <notes.md>
host/launcher/appcast.sh    # docs/appcast.xml, delta updates attached to the release
git commit -m "appcast: <version>" docs/appcast.xml && git push    # GitHub Pages publishes the feed
```

`appcast.sh` checks that the release's DMG is the local one (same size), then runs Sparkle's
`generate_appcast` on `work/out/updates` (the archives of earlier versions; the feed is taken from
`docs/appcast.xml`): the new item with the DMG's EdDSA signature, the minimum macOS from
`LSMinimumSystemVersion`, the release notes of the GitHub release (Markdown, embedded) and the download
URL on that release; delta updates from up to 3 earlier versions whose DMGs are in `work/out/updates`
(the kernel and most helpers rarely change), renamed without spaces (GitHub renames such assets) and
uploaded to the release; the whole feed signed. Further arguments go to `generate_appcast`, e.g.
`--phased-rollout-interval 86400` (the update reaches users over 7 days) or `--critical-update-version ''`.
Never edit `docs/appcast.xml` by hand: its signature covers the whole file. A local end-to-end test:
`dist.sh --no-notarize` with `SPARKLE_FEED_URL=http://127.0.0.1:8765/appcast.xml` and
`SPARKLE_PUBLIC_KEY=<test key>` for two versions, `SPARKLE_KEY_FILE=<test private key>
host/launcher/appcast.sh --local http://127.0.0.1:8765` after each, and
`python3 -m http.server 8765` in `work/out/updates-local`.
