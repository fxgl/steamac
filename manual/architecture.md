# How it works

**English** · [Русский](ru/architecture.md) · [简体中文](zh/architecture.md)

← [Manual](README.md)

| Directory | Contents |
|---|---|
| `host/moltenvk/` | MoltenVK utmapp `geometry-shaders` @05604465 + patches: depth_clip_enable, YCbCr arrays, null descriptors, geometry shader emulation for zink/DXVK (vertex stride, instancing, adjacency, fans, SCALED formats, packed vertex formats: 10-10-10-2, RG11B10F, RGB9E5, BGRA8, `gl_in`), transform feedback (DXVK stream output) and its queries (SO statistics), query result availability on copy (DXVK occlusion queries via Venus), atomics on vector components at buffer addresses (BDA, vkd3d-proton), component-packed vertex outputs under tessellation (dxil-spirv, Rift Apart), texel buffers with offsets at any texel (vkd3d-proton), writes to small push-descriptor buffers with robustness2, variable-count descriptor arrays as runtime arrays (Metal kept 32 MB per vkd3d-proton heap array and program), allocation of auxiliary buffers, deferred release of Metal resources, patch hash in the pipeline cache UUID, `VK_NULL_HANDLE` descriptor sets in binds, fragment outputs converted to their color attachment's numeric type, zeros for vertex shader inputs without a vertex attribute, integer vertex inputs read through float formats, null-checked YCbCr helper samplers, unsupported texel buffer formats rejected; tests in `repro/` run under Metal validation (also on KosmicKrisp: `REPRO_DRIVER=kosmickrisp`); `bench/run.sh <libdir>…` compares performance of changes between builds; `bench/shaders.sh <dump or pack>` measures a game's shader compilation (SPIR-V → MSL, MSL → Metal library, pipeline states; cold/warm, threads) from a MoltenVK shader dump or a 10% sample made with `bench/pack.py` |
| `host/kosmickrisp/` | KosmicKrisp (Mesa main @ce576c29) + open Mesa MRs and steamac patches (see [Vulkan drivers](vulkan-drivers.md#vulkan-drivers)), built without LLVM at runtime (`-Dllvm=disabled`, `mesa_clc` from a first build), `-Db_ndebug=true`; macOS 26+ only |
| `host/dxmt/` | Pinned DXMT + patches, static LLVM 15, native airconv, Windows DLL cross-build and guest payload; `build.sh fetch llvm native host pe client payload` |
| `wmtr/` | BSD-3-Clause winemetal remoting: guest `winemetal.so` over virtio-gpu to `libwmtr_host.dylib` (DXMT/LLVM linked in), presenting a CAMetalLayer inside the VM view |
| `host/libepoxy/` | libepoxy 1.5.10, upstream macOS Meson options, built for macOS 15.0 instead of copying a Homebrew bottle |
| `host/virglrenderer/` | virglrenderer UTM `macos-next` + merge with upstream main (venus-protocol 1.1.3) + LINEAR modifier, shm import as host memory, stubs for failed pipelines (draws dropped in virglrenderer), recreation of rejected cache, deferred shm unmap, thread QoS, Vulkan driver opened at runtime (`VKR_VULKAN_DRIVER`) |
| `host/libkrun/` | libkrun v1.19.6 + patches: `VIRTIO_GPU_F_BLOB_ALIGNMENT` (16K), SME mask for M4, 2D resources without virgl, `SET_SCANOUT_BLOB`, SHM blob mapping, Venus fence signaling, virglrenderer logs, `krun_display_resize` (resolution changes on the fly), vCPU/GPU thread QoS |
| `host/launcher/` | `steamac-vm` (Swift/AppKit): Metal window (optional MetalFX super resolution), “FX STEAM LAUNCHER” overlay with boot/shutdown progress, guest resolution = window size (× the screen's backing scale with Retina resolution) at constant DPI (EDID from the physical screen size), keyboard/mouse/tablet, the guest's Xbox 360 / DualSense / DualShock 4 pad from GameController.framework with rumble or a DualSense passed through as raw HID (`fx.pad`), network via gvproxy, VM restart on guest reboot, `--perf-stats` |
| `guest/kernel/` | Linux 7.2.9, everything built in, 4K pages, 16K blob-node alignment, Apple TSO for FEX; uhid, hidraw and `hid-playstation` (with the LED classes it needs) for the passed-through DualSense |
| `guest/mesa/` | From the pinned Mesa: Venus ICD for aarch64 (Proton, gamescope, zink) and x86_64/i386 (FEX graphics provider); zink GL stack (libgallium, GLX/EGL/GBM) over the stock one in both, with backports in `guest/mesa/patches/` (Mesa 6abefa51: zink rebuilds the pipeline when only the vertex layout changes; without `VK_EXT_vertex_input_dynamic_state`, which Venus on Metal lacks, GL games otherwise draw with stale vertex formats); x86_64 fault reporter for emulated games (`/usr/lib/steamac/x86_64/fault-report.so`) |
| `guest/initramfs/` | boot stage = “bootloader”: A/B slot selection with attempt counter, partsets, overlays for `/etc` and `/usr`; initial provisioning of the launcher-created disk (`steamac.provision=1`: static mkfs.fat, mke2fs, btrfstune in initramfs); `steamac.ssh=0` — no SSH server; launcher config payload (`steamac.config=1`) — new `steamos` password; `steamac.tz=` — the Mac's time zone in `/etc/localtime`; untouched procfs at `/run/steamac/proc` for Flatpak sandboxes; `steamac.share=` — runtime mount unit for the shared folder (virtio-fs `macshare`, see [Shared folder](clipboard-and-shared-folder.md#shared-folder)) |
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
(Uncharted, STEAMAC-3Q; `repro/texel_buffer.c`); a texel buffer view wider than Metal's 2^28 texels fails
with `VK_ERROR_OUT_OF_DEVICE_MEMORY` instead of aborting in Metal's descriptor validation (STEAMAC-9E/79).
A failed graphics pipeline logs each stage's entry
point, shader hash and reflected interface, for link failures and compiler errors that carry no MSL.

The SteamOS root filesystem is not modified: all changes come from initramfs and the layer. Thus
official Valve updates (RAUC + atomupd) install into the other slot and roll back normally — verified
with the 20260922 → 20260928 update and rollback.

The layer's Venus ICDs link only sonames that SteamOS updates keep (`guest/mesa/container/verify.sh`
`check_stable_needed`); they do not use libdisplay-info. SteamOS 0.6.0 (preview channel, 20261020)
replaced `libdisplay-info.so.1` with `.so.3`: the 1.9.7 ICD no longer loaded, gamescope found no Vulkan
device and the VM stayed at “Starting Steam client” (STEAMAC-72). Verified with the stable → preview
update to 20261020 (0.6.0): Steam starts on the updated slot.
