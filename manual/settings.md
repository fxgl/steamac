# Settings

**English** · [Русский](ru/settings.md) · [简体中文](zh/settings.md)

← [Manual](README.md)

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
| General | boot/shutdown overlay; “Still working…” indicator on GPU idle; “When FX Steam Launcher is in the background”: **Mute sound** (on by default: `krun_snd_set_volume(…, mute)` with a gradual ~150 ms fade-out; volume is restored when returning to the window) and **Pause the game** (off by default: the guest agent freezes only the game in focus — `systemctl --user freeze app-steam-app<appid>-*.scope`, cgroup v2; Steam, downloads, and updates continue running; online games may disconnect). While the agent confirms the freeze (`game-frozen`/`game-thawed`), the window is dimmed, with a “Game paused · Click to resume” card and “— paused” in the title; clicking the window resumes the game and is not passed to the guest; crash reports (`--no-crash-reports`, see [Crash reports](privacy-and-updates.md#crash-reports-sentry)); **Check for updates at startup** (on by default, see [Update check](privacy-and-updates.md#update-check)); frame statistics logging (`--perf-stats`); **Use the Mac's keyboard layouts in Desktop Mode** (on by default, see [Desktop Mode](desktop-mode.md#desktop-mode)) | full screen at startup; **Use the Mac's time zone and clock format** (on by default; see [Building and running](building.md#building-and-running)) |
| Display | guest follows window size; Apple's Metal Performance HUD in the upper-right corner of the window (Ctrl+Cmd+P, View → Show Metal Performance HUD); **MetalFX super resolution** (off by default): Apple's MetalFX spatial upscaler scales the guest picture to the window's pixel size whenever the window has more pixels than the guest (2× on Retina screens, scaled or fullscreen windows) instead of linear / nearest scaling; it runs on the guest frame in the launcher, so it works for every game and the Steam UI | physical size source (auto from display / DPI / mm — `--dpi`, `--display-mm`), refresh rate (`--refresh`), window size (`--display`): standard 16:10, 16:9, 21:9 and 3:2 resolutions from 1280 × 800 (Steam Deck) to 3840 × 2560 (those that do not fit on the display are marked “larger than this screen”; the window is shrunk as before), “Fit to screen” (largest size for the display, recalculated on every launch), or “Custom…” (W × H fields); **Retina resolution** (optional, off by default): the guest display gets the screen's pixel density (window points × the screen's backing scale, taken at boot; the scale is lowered so no side exceeds 8192 px) at the same EDID physical size, so SteamOS scales its UI up to the same size with sharp text — but games draw 4× the pixels and each frame copy is 4× larger; recommended instead: Retina resolution off + MetalFX super resolution (a 2× upscale on Retina screens) |
| Mouse | auto-capture in games; game list (name from `appmanifest_<appid>.acf`, Default/Auto/Off, remove) | — |
| Controller | which physical controller (GameController) drives the virtual pad (first connected or selected), whether SteamOS gets a pad and what it appears as (`--no-gamepad`, `--pad`, see [Controllers](controllers.md#controllers)), whether a DualSense is passed through as itself, whether further controllers are players 2–4, swap A/B and X/Y, stick dead zone, live input test | — |
| Sound | output device (System default follows macOS, or a specific CoreAudio device), volume/mute, Low/Normal/Safe buffer — via `krun_snd_set_*` (looked up with `dlsym`; with an older libkrun the fields are disabled with an explanation) | sound (`--no-sound`) |
| Games | **Share game statistics** (off until you agree, see [Game statistics](privacy-and-updates.md#game-statistics)); known games and games with recorded sessions: per-game profiles (graphics, Vulkan driver, launch options; see below), sessions, play time, last session's FPS / 1% low / game memory / Vulkan driver, your optional rating (Runs well / Playable with issues / Starts, but unplayable / Does not start) and a per-game **Share** switch | profiles may require restarting Steam or the VM (see below) |
| Advanced | — | vCPU (`--cpus`), RAM (`--mem`), SSH enable/disable + port (`--ssh-port`, `--no-ssh`) and generated password, network (`--no-net`), disk image (`--disk`), Create New Disk…, Steam client (`--steam-client`, see [Steam client](using.md#steam-client)), Vulkan driver (`--vulkan-driver`, see [Vulkan drivers](vulkan-drivers.md#vulkan-drivers)), Allow DXMT (D3D11 on the Mac's Metal), experimental (`--wmtr-lib`, `--no-wmtr`, see [Vulkan drivers](vulkan-drivers.md#vulkan-drivers)), shared folder + mount point in SteamOS + use as a Steam library (`--share`, `--share-mount`, `--no-share`, `--share-library`, `--no-share-library`, see [Shared folder](clipboard-and-shared-folder.md#shared-folder)) |

With **Retina resolution** on, a fullscreen guest can use the full native resolution of 5K and
6K displays (for example, 5120 × 2880 on Studio Display or 6016 × 3384 on Pro Display XDR at
their default Retina scaling), rather than being limited to 4094 px on the long side. This can
increase GPU load if you already had Retina resolution enabled.

Gamescope [blocks exactly 4096 × 2160](https://github.com/ValveSoftware/gamescope/blob/a962a4dc136369708657605f87057ba3f9991fda/src/Backends/DRMBackend.cpp#L1008-L1026)
at any refresh rate, so SteamOS Gaming Mode uses the 4095 × 2159 fallback for that size.

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

**Less capacity (Shrink Disk):** **Settings → Advanced → Shrink Disk…** lowers home capacity when
used data still fits (refuses otherwise). Ext4 must shrink **before** GPT/truncate: a one-shot boot
with `steamac.shrink-home=N` + `steamac.slot=stop` runs `e2fsck`/`resize2fs` in initramfs, powers
off, then the host rewrites GPT and truncates the image. If the filesystem already fits, the host
truncates immediately. Terminal (filesystem already fits, VM stopped):
`work/out/steamac-vm --shrink-disk /path/to/steamos.img --home-gib 192`.

**Reclaim space on the Mac:** after uninstalling games (or after a large Grow), the sparse
`steamos.img` can stay large on disk even though SteamOS no longer needs those blocks.
**Settings → Advanced → Reclaim Disk Space…** (SteamOS running) asks the guest to `fstrim`
`/home` (and `/var` when mounted); virtio-blk DISCARD punches holes in the Mac image. Capacity
is unchanged — allocated size can drop **only when the image is on APFS**. HFS+ and exFAT cannot
reclaim space this way; the launcher checks the volume before starting. APFS clones and snapshots
may retain the freed blocks, so the Mac's free space need not increase by the same amount.
Shrink Disk changes capacity; Reclaim only punches holes.

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
duplicate name wins. Invalid input stays visible with an error and is not saved or sent. An empty field
means the profile adds no overrides (the field no longer shows a `VKD3D_CONFIG=dxr` example that looked
like a forced value, STEAMAC-8X). The Metal Performance HUD shows the Mac's drawable size, which can
differ from the game's rendering resolution.

Opening **Settings → Games** does not fetch recommendations. Clicking **Get Recommendation** or
**Retry** sends the game's Steam App ID and this Mac's RAM, GPU core count and performance core
count to the statistics service, regardless of the **Share game statistics** setting. The service
uses those **My Mac** limits to find profiles from Macs no more powerful than this one and ranks
them by `(runs well + 0.5 × playable with issues) / all ratings`, then higher launch success and fewer
early exits; at least two distinct installs are required (details in [Game statistics](privacy-and-updates.md#game-statistics)).
A matching profile is shown as **Recommended: … — Apply**. Only **Apply** changes the profile.

DXMT requires **Settings → Advanced → Allow DXMT (D3D11 on the Mac's Metal)** and a VM boot with
that permission. While it is off, a DXMT profile is shown as not in effect and offers **Allow DXMT…**
with the existing security warning; it cannot select a DXMT compatibility tool on a Vulkan-only boot.
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
