# Vulkan drivers

**English** · [Русский](ru/vulkan-drivers.md) · [简体中文](zh/vulkan-drivers.md)

← [Manual](README.md)

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
verifies actual Metal source compilation with the replacement (no VM or Sentry events). The choice is
made only before Metal initialises: a cache that becomes unwritable later cannot be redirected in the
running process, so reports carry the startup decision (`metal_cache` tag) and read-only metadata of
the failing `monolithic_metal.pcm` path (STEAMAC-7W). MoltenVK does not support pipelines that combine
tessellation with a geometry shader; they fail with `VK_ERROR_FEATURE_NOT_PRESENT` instead of compiling
with an invalid buffer binding (STEAMAC-83).

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
round-trips a shader with over a million defs in the KosmicKrisp build). Selections nested deeper than 128
are emitted as guarded sibling blocks, because Metal rejects source nested past 256 brackets (a
STEAMAC-G report; `sentry-g-brackets.sh` checks a 320-case divergent ladder on the GPU). For a repeatable
KosmicKrisp stall, `MESA_KK_DEBUG=syncs,cbs` set when starting the macOS launcher (not as a game
argument) traces queue synchronization and every CPU wait longer than one second (STEAMAC-94).
A buffer copy with a NULL source or destination buffer is skipped with one warning instead of crashing the
VM process (Dota 2, STEAMAC-9S/9T; `host/kosmickrisp/test/copy-buffer-null.py`).
A graphics pipeline without a vertex shader fails to create, with its stages logged, instead of crashing
the VM process when bound (STEAMAC-AH; `REPRO_CASE=sentry-ah host/moltenvk/repro/run.sh`). A view of a
single-layer 2D image whose layer count overflows (Zink's `0+65536`) keeps that one layer instead of
killing the GPU context; a view in an incompatible format (RGBA8 image, R8 view) is still refused, and the
log names the guest application and the full view arguments (STEAMAC-G). A reply stream on a resource the
context does not have stays fatal; virglrenderer logs whether it was detached from that context (and how
long ago), never attached, or not shared memory (`host/virglrenderer/test/reply-resource.py`, STEAMAC-G).
Fatal-command and failed-lookup lines name the guest context (id and process name), so the context that died is
no longer guessed from neighbouring `destroying context … (explorer.exe)` lines; rejected image views also log the
real format features and block compatibility (STEAMAC-G: R8 views of RGBA8 Zink images, still refused). Before
creating Metal encoders KosmicKrisp logs bounded high-water snapshots of its command allocators, encoders and
upload memory (`REPRO_CASE=command-allocator`), and the launcher records which Apple Metal instrumentation is
loaded (`metal_instrumentation` tag: `libMetalMetricsInterpose` also loads through macOS frame pacing with the
HUD off) and a VM-tag breakdown when the VM footprint grows by more than 8 GiB in 30 s (STEAMAC-AK/AP/AN/AX:
an IOGPU command-storage allocation failed after the footprint jumped from 52 to 95 GB; cause not yet known).
A render pipeline whose vertex function does not resolve in its library fails like any other compile failure,
logged with the name, the library's functions and the program's MSL hashes, instead of Metal's process abort
`vertexFunction must not be nil` (STEAMAC-BN/BP; `REPRO_CASE=sentry-bn`). A render pass whose framebuffer names
an image view destroyed before the pass began is logged with the attachment, format and framebuffer before
Mesa's common code dereferences the freed view (STEAMAC-BJ/BK, DOOM 2016: `transition_attachment` read the
view's image as NULL; who destroyed it is not yet known; `REPRO_CASE=sentry-bj`).
A graphics pipeline whose color attachment format KosmicKrisp does not advertise as renderable (BC6H) fails
creation, logged, instead of Metal aborting with “not color renderable” (STEAMAC-BN/D5, Hunt: Showdown;
`REPRO_CASE=sentry-bn-bc6h`), and so does a mesh-shader pipeline, which KosmicKrisp cannot run and which has
no input assembly state (STEAMAC-CG/CH, Final Fantasy VII Rebirth: `kk_gather_program` read it as NULL;
`REPRO_CASE=sentry-cg-mesh`). Occlusion query pools keep their heap indices in host memory, so an
overwritten GPU-visible index (after a GPU address fault in AC Valhalla, STEAMAC-7C/7D) is logged and
restored instead of crashing `vkResetQueryPool`; what wrote it is not yet known.
Mesa's barrier fallback on macOS let `util_queue_finish` hang a device teardown (shader disk cache);
`host/kosmickrisp/test/util_queue_finish.c` runs in the KosmicKrisp build. MoltenVK: a pipeline blending
an attachment Metal cannot blend (R32_UINT) fails (STEAMAC-3A); vertex-stage auxiliary buffers are
packed into Metal's 31 buffer slots (STEAMAC-67); full 32-bit specialization constant IDs work
(STEAMAC-6A); an optimal image in imported host memory gets a placement heap, so 2D views of a 3D image
used as render attachments no longer dereference a missing heap (STEAMAC-76/77); failed pipelines log
complete small shaders, Metal descriptors, blend state and fragment output indices (STEAMAC-41/75);
dual-source blend factors on an attachment whose shader has no secondary output use zero for it, which
Vulkan leaves undefined and Metal rejected (STEAMAC-75); on M1, sample-qualified perspective projection
interpolates at `get_sample_position(sample_id)`, avoiding Metal's missing `llvm.agx2.sample.itrproj`
intrinsic (STEAMAC-8J). SPIRV-Cross fixes the MSL errors of STEAMAC-33/6D/6E/5M/5K/2N/5C/6V, keeps a
dual-source blend output's second index when it packs outputs (STEAMAC-75), keeps explicit
interface-block member Locations with gaps (Locations 0 and 2 became `locn0`/`locn1`), and declares an
object shader's payload `locations` as `uint[32][4]` (same layout): Apple's compiler crashed on partial
stores into `uint4 locations[32]`, reported as an internal error or an interrupted XPC connection
(STEAMAC-41/R); interrupted compiler-service reports carry host memory pressure and swap (STEAMAC-3X).
`vec3` members of Workgroup (shared) arrays are stored packed, as Vulkan's padding rule sizes them, so a
968-element `{float; vec3; float}` array needs 19360 bytes instead of Metal's 46464 > 32768 (STEAMAC-57).
A vertex output narrower than the fragment input at the same Location (float3 → float4) is widened to
the input's width; missing varyings and different numeric types remain unsupported (STEAMAC-2M/88).
A shader function named `rgb9e5` is renamed so it no longer collides with Metal's `rgb9e5` pixel type
(STEAMAC-A9), and a geometry/mesh stage writing only `ClipDistance` also writes the `user(clip0)` copy
the fragment shader reads (STEAMAC-A2).
Red Dead Redemption 2's Vulkan renderer creates pipeline-statistics query pools although MoltenVK does not
offer them; they are now created and return zeros (the feature stays off) instead of failing and killing
the GPU context, timestamp pools larger than 4096 queries use several Metal sample buffers, and host-memory
images copied through a CPU shadow use the real texel/block row pitch (the AGX `bytes_per_row` assertion,
STEAMAC-AG/G; `REPRO_CASE=sentry-ag`). A command buffer that fails on the GPU logs its encoders and shaders.
Floating-point atomics on workgroup (`shared`) memory, which Metal only offers on device memory, are emulated
with `atomic_uint` bit casts and a compare-and-swap loop (STEAMAC-AS), and geometry/tessellation vertex
fetch reads array- and matrix-typed vertex inputs one location at a time with each location's format
(`half2[2]`, STEAMAC-AV; `sentry-as-shared-float.sh`, `sentry-av-array-input.sh`).
MoltenVK keeps separate Component-qualified vertex outputs and the matching fragment inputs distinct next to
width-linked varyings, fixing 1.9.14's duplicated `locnN` / invalid vertex return type regression
(STEAMAC-87/BB; `REPRO_CASE=sentry-87-components`, pixel-checked for plain and block declarations, both
width directions and serialized pipeline-cache reuse).
More than 32 VkDevices alive at once no longer abort MoltenVK: Metal allows 32 residency sets per command
queue and MoltenVK's queues are shared by every device, so each device's residency set now goes with its
command buffers (STEAMAC-3/D8/D9; `REPRO_CASE=queue-residency`, 40 devices). The M1 workaround for projected
sampling of sample-rate inputs (undefined `llvm.agx2.sample.itrproj.1xf`) now also applies on M2
(STEAMAC-CA, M2 Max; verified on M1 only). A loop whose continue block writes an image with
robustImageAccess2 is emitted as a structured loop instead of an `expected ')'` for-loop header
(STEAMAC-B6/B7/B8/B9; `sentry-b6-continue.sh`, GPU readback).
`host/moltenvk/repro/sentry-msl.sh` compiles each reconstructed shader. wmtr (DXMT) refuses only
garbage or freed object handles, ends encoders a game left open when its context goes away (also past
65,536 live objects, STEAMAC-70), and refuses a render pipeline without a vertex function
(STEAMAC-6S/6Z); `wmtr/tests/wmtr_dxmt_test.m` drives DXMT's own command lists through the shipped
executor on the GPU.

Shared Vulkan images on KosmicKrisp use imported shared pages rather than a private tiled heap
(#58, temporary workaround for Mesa !44929). Only explicitly external host-memory images take this
path: queries advertise one mip, one layer and single-sample linear backing, even for `OPTIMAL`;
ordinary host-visible imports keep their tiled heaps. Guest Venus and virglrenderer preserve this
contract only for the KosmicKrisp renderer; MoltenVK's legacy-tiling refusal is unchanged.
`host/moltenvk/repro/shared_image.c` checks both directions between two devices (host shm imports,
real exported/imported Vulkan fds in Linux). This verifies the sharing primitive, not MSFS 2024:
MoltenVK's host `OPTIMAL` case skips its known row-pitch limitation rather than aborting.

**Allow DXMT (D3D11 on the Mac's Metal), experimental.** Settings → Advanced → **Allow DXMT (D3D11 on
the Mac's Metal)** is off by default and applies on next start (`--wmtr-lib PATH` or `--no-wmtr` for one launch).
The app bundles `libwmtr_host.dylib`; the guest layer carries DXMT's
`{d3d11,dxgi,d3d10core,winemetal}.dll` and `winemetal.so`. If macOS cannot supply a Metal drawable (for
example a zero-size layer or a drawable timeout), DXMT skips that frame instead of presenting `nil`, which
Metal turns into an assertion that ended the VM (STEAMAC-98); a bounded log line records it and rendering
continues with the next drawable. With the toggle on, the launcher offers
libkrun's wmtr virtio-gpu context (patch 0013, capset 30) and boots with `steamac.gfx=dxmt`.
The guest's `steam-gfx-path` swaps DXMT into every installed x86-64 Proton and watches for Proton
installs and updates; turning the toggle off boots with `steamac.gfx=vulkan` and restores Proton's
original files. With the optional ARM64EC payload, `steam-dxmt-arm64ec` prepares a separate
**SteamMac DXMT (ARM64EC)** compatibility tool from installed **Proton 11.0 (ARM64)**. It uses
upstream DXMT's ARM64X DLLs and an AArch64 ELF `winemetal.so`, keeping Wine and DXMT native while
FEX translates the game's x86-64 code. The thin tool uses symlinks into the installed Proton,
about 13 MB of DXMT files and private prefix/fixup entries, not a full 1.9 GB copy. The original
Proton files stay untouched and updates reach the links directly. Proton takes its directory from
the path it is started as and copies its DXVK set into
the prefix on every launch, so DXMT's `d3d11`/`dxgi`/`d3d10core` at that path in the tool reach the
prefix, and a game set back to Steam's default gets DXVK again at its next start. Wine itself stays
the stock build; `winemetal` comes from the tool via `WINEDLLPATH`, and the tool's `run` entry point
keeps a `winemetal.dll` entry in the game's prefix. The tool is rebuilt before Steam starts when the
Proton or payload changes; updates are deferred while a game is using it. Missing or unsupported
Proton sources invalidate the managed tool; mappings fall back instead of following dangling or
mismatched links. SteamPipe's empty-directory and read-only fixups are applied to private prefix
templates and affected entries (copying other files only when their permissions need fixing),
even before stock Proton's first launch.
Its nested `tool/` directory keeps the legacy x86-64 installer away from it.

Before Steam starts, `steam-compat-default` gives **only games whose profile selects DXMT** a
per-game mapping to the native tool when available, or **Proton 10.0** otherwise, at priority 250,
and only on a DXMT-enabled boot. The old x86-64-only payload cannot initialize winemetal under
ARM64EC Wine; both the native PE DLLs and the native Unix library are required.
Eligible titles are installed Windows games (`libraryfolders.vdf` and `appcache/appinfo.vdf`:
type game/demo/application, oslist with windows but not linux) without a user-owned tool choice.
Every other game keeps Steam's default tool, **Proton 11.0 ARM64**, with DXVK/vkd3d-proton on Venus.
The old blanket mappings are removed on the first Steam start; subsequent profile changes or
newly installed games are applied at the next Steam start. User edits in Steam remain untouched.
This is not just a DLL choice: some games crash under x86-64 Proton 10.0 + FEX regardless of the
DLLs used. Stellar Blade Demo (3564860), for example, ends SEH recursion with
`virtual_setup_exception stack overflow` there, but runs on Proton 11.0 ARM64.
For the fallback path, Steam downloads Proton 10.0 (x86-64, under FEX in Steam Linux Runtime 3.0) on the first DXMT game
launch, and `steam-gfx-path --watch` puts DXMT into it. The **x86-64** builds of Proton Experimental
and Proton 11.0 need the x86-64 Steam Linux Runtime 4.0 (`SteamLinuxRuntime_4`, app 4183110).
Do not confuse them with **Proton Experimental (ARM64)** or **Proton 11.0 (ARM64)**: these use
the separate ARM64 runtime
(`SteamLinuxRuntime_4-arm64`, app 4185400), which Steam installs on ARM64. Select the tool whose
name explicitly ends in **(ARM64)** in the game's **Properties → Compatibility**; the Steam Deck
client also offers ARM64 Experimental, so switching to the Frame client is not required for it.
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
Native ARM64EC tool vs Proton 10.0 + DXMT, M5 Max (macOS 27, VM with 12 vCPUs / 32 GB at 120 Hz,
KosmicKrisp, FX Steam Launcher 1.9.13 with the ARM64EC layer; frames shown from `WMTR_FRAMES`, three
interleaved runs per tool). Death's Door gameplay (scripted keyboard input through uinput: walking,
rolling, sword and bow, 26 s from the same save) holds 120 FPS on both with no frame over 50 ms; VM
CPU was 330-345% native and 406-432% on Proton 10.0 (median 342% vs 406%, about 16% less), worst
frame 17-32 ms vs 19-49 ms. Super Battle Golf (Unity 6000.3.10f1) holds 120 FPS on its title screen
on both (VM CPU 251-279% vs 239-254%: the title screen does not separate them). d3d11bench (x86-64,
launched through Steam, 20 s, medians) 140 / 138 FPS with 100 draws and 16 passes, 270 / 267 with
2000 draws and 4 render passes. The native tool starts a game about 1.5 s sooner.
Unity logs an unsupported `ID3D11Fence` creation on both tools and keeps running.
DXMT's winemetal calls cross virtio-gpu to an
executor **inside the VM process on the Mac**, which presents a `CAMetalLayer` in the VM view.
That layer would cover the guest compositor's cursor; the launcher draws the game's own cursor above
it instead, with gamescope-compatible sizing. Cursor tracking is host-gated and DXMT-only: it runs
only when game focus permits the overlay and an actual wmtr layer is attached and visible, not
merely because Allow DXMT is on (see [Cursor on the DXMT path](architecture.md#cursor-on-the-dxmt-path)).
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
host/dxmt/build.sh pe-arm64ec client-arm64 payload-arm64ec    # add native Proton 11 support
scripts/build-image.sh layer                               # include the guest payload
host/launcher/build.sh                                     # bundle executor + refreshed layer
```

`fetch` verifies the pinned DXMT/DirectX-header tarballs and applies `host/dxmt/patches`;
`llvm` builds static LLVM 15.0.7 (about 10 minutes on an M2, reused while the pin matches).
`native` builds airconv in `work/build/dxmt-native`; `host` builds/tests/installs the executor to
`work/out/host/lib/libwmtr_host.dylib`. `pe` cross-builds the four DLLs into `work/out/dxmt-pe`;
`client` builds/tests `wmtr/build/x86_64-linux/winemetal.so` in Docker; `payload` stages
`work/out/dxmt/{x86_64-windows,x86_64-unix}` for `/usr/lib/steamac/dxmt/` in the guest layer.
Steps can be rerun individually; `host/dxmt/build.sh` with no arguments runs the default x86-64 steps.
The three optional ARM64EC steps use the pinned Wine 11.2 build tools and upstream
`build-arm64ec.txt`, build/test the Unix client in a native ARM64 container, and stage
`work/out/dxmt/{aarch64-windows,aarch64-unix}` alongside the x86-64 payload. The host executor
is shared by both architectures. Packaging and mapping checks:
`python3 scripts/test/steam-dxmt-arm64ec.py`, `python3 scripts/test/steam-compat-default.py`,
and `bash scripts/test/steam-gfx-path.sh`. The device/readback smoke test is
`wmtr/tests/d3d11_device_test.c`; run its x86-64 executable under the native DXMT tool on a
boot with the wmtr executor enabled.

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
For pipeline creation bugs, see [capturing and replaying a pipeline with Fossilize](../host/kosmickrisp/FOSSILIZE.md).
