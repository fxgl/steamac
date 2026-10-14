#!/bin/sh
# Build KosmicKrisp (Mesa's Vulkan driver on Metal 4), steamac's alternative host Vulkan driver.
#
#   host/kosmickrisp/build.sh        build/refresh work/out/host/lib/libvulkan_kosmickrisp.dylib
#   host/kosmickrisp/build.sh clean  drop the source/build tree (next build is from scratch)
#
# Needs macOS 26+ on Apple silicon (Metal 4); ./build.sh host skips it on older macOS. MoltenVK
# (host/moltenvk) stays the default driver; the launcher selects KosmicKrisp with
# --vulkan-driver kosmickrisp (or Settings) on macOS 26+.
#
# Source: Mesa main at MESA_COMMIT (2026-10-05) + patches/ (git format-patch series, applied in
# order; upstream MRs as of 2026-10-06):
#   0001-0015  mesa!44928 (draft, Willie Abrams): VK_EXT_transform_feedback, on top of mesa!44786
#              (Junmin Lee): geometry shaders through poly (0001-0008 are !44786's commits). The
#              docs/relnotes hunk of 0015 is dropped (conflict, docs only).
#   0016       mesa!44929 (Willie Abrams): tiled images in host pointer imports. virglrenderer imports
#              every host-visible or exportable guest allocation as host memory, and KosmicKrisp's
#              only memory type is host visible: an OPTIMAL image bound to it asserted.
#   0017       mesa!44221 (karlmark): a device-local-only memory type, so non-exported images get a
#              private Metal heap instead of host-pointer memory.
#   0018       mesa!44782 (Matthew Periut, closed unmerged): LINEAR color attachments and blit
#              destinations (zink/glamor render into LINEAR dma-buf scanout images; virglrenderer
#              passes the host's linear tiling features through).
#   0019       steamac: the explicit row pitch of imported LINEAR dma-buf images (as MoltenVK 0012).
#   0020       mesa!44222 (karlmark): linear textures are created 2D with a 2D array view for input
#              attachments (Metal aborts on buffer-backed arrays).
#   0021       steamac: LINEAR images may be input attachments (0018 kept refusing them). zink and
#              Gamescope WSI swapchains ask for that usage; refused, the guest WSI found no DRM
#              modifier and vkCreateSwapchainKHR failed (mangoapp, X11 clients).
#   0022       steamac: fillModeNonSolid (polygonMode LINE as Metal's line fill, POINT as lines like
#              MoltenVK). DXVK skips devices without it, so no D3D9/10/11 game started.
#   0023       steamac: unsupported sample counts (8) use the largest supported one (as MoltenVK 0024):
#              Metal failed such pipelines and Venus dropped their draws.
#   0024       steamac: single texel alignment for texel buffer views (as MoltenVK 0029): the texture
#              starts 16-byte aligned below the view, shaders add the texel offset from the descriptor.
#              vkd3d-proton (D3D12) requires it.
#   0025       steamac: timestamp query pools split over Metal counter heaps of 4096 (Metal's limit):
#              vkd3d-proton's 8192-query pools failed, Venus lost them and Stellar Blade's GPU context died.
#   0026       steamac: device and queue losses are printed on stderr ("MESA: error: VK_ERROR_DEVICE_LOST: ...",
#              with the Metal error of a failed command buffer). Release builds lost the device silently:
#              Venus only logged "vkQueueSubmit resulted in CS error" (STEAMAC-G, M4 Max).
#   0027       steamac: sparse residency queries in shaders (OpImageSparse* -> MSL sparse_sample/sparse_read/
#              sparse_gather, MinLod -> min_lod_clamp): shaderResourceResidency.
#   0028       steamac: sparse binding and residency (D3D12 tiled resources through vkd3d-proton): Metal 4
#              placement sparse textures/buffers, 64 KiB pages of placement heaps mapped by vkQueueBindSparse
#              through MTL4CommandQueue updateTextureMappings/updateBufferMappings; standard 2D block shapes,
#              strict non-resident reads, per-layer mip tails from the first level smaller than a tile;
#              sparse resources bind only the device-local memory type (never a host-pointer import).
#              Not available: sparse 3D (Metal's 3D tiles are one slice deep, not Vulkan's standard 3D
#              blocks), sparse MSAA. Within one render pass, depth writes to unbound tiles stay in tile
#              memory for later draws of the pass (D3D12 Tiled Resources Tier 2 allows that cache).
#   0029       steamac: sampler min/max reduction (VK_EXT_sampler_filter_minmax, filterMinmaxSingleComponentFormats)
#              before Apple10, where Metal's reductionMode is unsupported: point samplers plus a shader
#              footprint reduction (exact for 1D/2D/3D/arrays; anisotropy ignored, cube corners approximated).
#              With 0027/0028 vkd3d-proton reports Tiled Resources Tier 2, hence feature level 12_0.
#   0030       steamac: unmaps of sparse buffer pages are applied. Metal held back MTL4CommandQueue unmaps of
#              placement sparse buffers (and texture buffers) until the queue mapped a page of a resident
#              resource: an unmap ending a vkQueueBindSparse left the page mapped (vkd3d-proton's
#              test_update_tile_mappings_remap_stress). A bind submit that unmapped buffer pages ends by
#              mapping the queue's resident one page buffer.
#   0031       steamac: texel buffer views of sparse buffers. Metal makes no texture from a placement sparse
#              buffer (nil; vkd3d-proton's typed views of reserved buffers, ClearUnorderedAccessViewUint, lost
#              the Venus context): views are placement sparse texture buffers from the page below the view,
#              mapped like the buffer's pages (recorded per buffer, mapped heaps retained) at creation and on
#              every later bind.
#   0032       steamac: sparse sample residency for LODs past the last level. Metal samples the last level
#              but reported the missing level past it not resident (vkd3d-proton's texture_feedback
#              SampleGrad); sparse samples limit the LOD to the view's last level (level/min_lod_clamp/the
#              implicit LOD through the bias) and take the last level's residency for gradients past it.
#   0033       steamac: VK_EXT_image_view_min_lod advertised by default (was MESA_KK_EXPERIMENTAL=image_view_min_lod;
#              hk's lowering: a 16-bit descriptor load and a max per sample when minLod is enabled, fetches below
#              the minimum LOD read zero). vkd3d-proton's ResourceMinLODClamp needs it (test_view_min_lod 706/706;
#              without it vkd3d-proton rebases views, 10 failures).
#   0034       steamac: residency of sparse loads through texel buffer views (Metal has no sparse read of texture
#              buffers: CheckAccessFullyMapped after typed buffer loads always reported resident, vkd3d-proton's
#              test_buffer_feedback_instructions / test_sparse_default_mapping). Sparse residency buffers get an R8Uint
#              placement sparse 2D array texture whose 64 KiB tiles are the buffer's pages, mapped to the same heap
#              pages by the same queue mapping updates; texel buffer descriptors grow to 32 bytes and sparse loads take
#              the residency of a sparse_read of their page's tile. Metal crashes in updateTextureMappings when a
#              texture mapping update follows a buffer/texture-buffer one that followed a texture one: the queue
#              signals and waits for an event in between (a signal alone let later buffer unmaps be overtaken).
#   0035       steamac: sparse residency through views with baseMipLevel > 0, and of gathers. Metal reports
#              such a view's residency for the image's level/LOD without the base (fetch, explicit LOD,
#              imageLoad; gradient and implicit LODs only in their clamps), and a gather resident when its
#              footprint crosses into an unbound tile. Such views get residency views from level 0 (storage
#              image descriptors grow to 16 bytes); sparse operations through them take the residency of the
#              same operation on that view at level/LOD + base, with the sampler's LOD clamps applied in the
#              shader (samplers get an unclamped copy when they could matter); gathers take that of a
#              bilinear sample of their level through a LINEAR unclamped copy of the sampler.
#   0036       steamac: sampler min/max emulation (0029) only for draws/dispatches with a reduction sampler
#              bound. It cost every sample, also through ordinary samplers (twice the GPU time of
#              sampling-bound shaders, 1.3-1.6x their compile time). Pipelines sampling from descriptor sets
#              get a program without the emulation (immutable samplers resolved at compile time) and one
#              with it, used while a bound set (per-set count of reduction samplers, never decremented)
#              holds one; the second program's MSL is built at creation, its Metal compile happens on first
#              use (first at creation once a set of the pipeline's layout got a reduction sampler: descriptor
#              heaps). Update-after-bind sets that get one after recording make the submission re-record the
#              command buffer; one-time-submit buffers use the emulating program for them. MESA_KK_DEBUG=minmax
#              logs reduction samplers, emulating/plain programs compiled and re-recordings.
#   0037       steamac: query pools past Metal's limits. All occlusion queries of a device shared one visibility
#              result buffer of 32768 (Metal's maximum visibility query offset, 256 KB), and every timestamp
#              pool took counter heaps of its own while Metal allows 32 per process, which every guest device
#              shares under virglrenderer: further pools failed to create, and Venus' next vkCmdBeginQuery /
#              vkCmdResetQueryPool on one was a CS error (STEAMAC-G: Dota 2, Counter-Strike 2). Occlusion
#              results live in chunks of 32768 created as needed (16 per device; a render pass writes the
#              chunk of its active query, a query of another chunk restarts the Metal render pass); timestamp
#              pools take 32-entry chunks of 32 process-wide counter heaps of 4096.
#   0038       steamac: a command queue error first logs the failed command buffer's GPU time and the semaphore
#              waits submitted before their signal that are still unsignalled (value, current value, age; the
#              queue keeps the last 8). STEAMAC-G: M3/M4/M5 lose devices with MTL4CommandQueueErrorTimeout after
#              Steam's UI starts; on an M1 Max a Metal 4 queue wait that is never signalled ends after 4.0 s
#              without an error, so the message has to tell such a wait from GPU work that ran too long.
#   0039       steamac: a command queue error also logs the failed command buffer's guest application, its
#              commit-to-start delay or that it never started (raw GPU times), the queue's last completion,
#              the Metal error's userInfo, the devices alive and the last ones created/destroyed in the
#              process, and once the Metal/IOGPU/AGX error messages of the process' os_log (the IOGPU
#              reason: Metal 4 reports page faults, hangs and recovery victims as one Timeout code). STEAMAC-G
#              timeouts follow Steam's hellovr_vulkan probe teardown by 0.3-1.1 s. MESA_KK_DEBUG=commits logs
#              late/long command buffers and device lifetimes. Queue teardown waits for every feedback
#              handler (they could run after vkDestroyDevice).
#   0040       steamac: the base texture of every image plane (and of the 2D array alias of 3D images), block-texel view
#              subresource texture and texel buffer view texture is in the device's residency set, from bind/creation
#              until before its release (sparse images as before). Metal 4 takes an attachment as resident only when
#              its base texture object is in a residency set, not its heap, the buffer it was made from (host pointer
#              imports) or the bound view; KosmicKrisp only added heaps and buffers, and Metal API validation reported
#              every render pass (9033 times in one Steam boot). STEAMAC-G: M3+ timeouts follow Steam's first MSAA
#              targets/window images and window resizes. Repro: host/moltenvk/repro residency.c.
#   0041       steamac: direct draws without an index buffer that need an unroll (a flat varying with the last vertex
#              provoking, fans) get their indices from the CPU at recording; the unroll kernel ended the render pass
#              around every such draw (attachments stored, compute pass, attachments loaded). STEAMAC-G: zink keeps
#              GL's last provoking vertex, and Steam's web helper composites its first frame as 12 such rectangles
#              into its LINEAR 2560x1600 window buffer: 13 render passes, 43 ms of GPU time on an M1 Max, where M3+
#              GPUs lose the device (the GPU's recovery; 11 draws: 27 ms -> 0.37 ms). Command buffers keep a record
#              (render passes, compute encoders, draws/dispatches, KK operations and kernels, program MSL hashes and
#              L/D/S/A/B/W features); a command queue error prints the failed one's and, once per process, every
#              command buffer of the process on the GPU with it and its outcome (Hang / InnocentVictim from the
#              error's userInfo), plus MSL excerpts of programs with loops/atomics/barriers of the one that hung.
#              0039's os_log reading is dropped (<private>, and it delayed the loss by 2-4 s). MESA_KK_DEBUG=cbs
#              logs every command buffer's record. Repro: host/moltenvk/repro provoking_last.c.
#   0042       steamac: R32G32B32_UINT/SINT/SFLOAT uniform texel buffers (R32 texture buffers of three texels per
#              element, flagged in the descriptor's texel offset; fetches read three texels, alpha 1). vkd3d-proton views
#              12-byte structured buffers as R32G32B32_UINT texel buffers without checking format features, and
#              kk_CreateBufferView dereferenced the missing Metal format (STEAMAC-2Z: The Witcher 3 crashed the VM).
#              Views of other formats no texture buffer backs read as null descriptors (one warning per format).
#              Repro: host/moltenvk/repro texel_buffer.c 4.
#   0043       steamac: unrolls of direct draws (indexed, or past 0041's CPU limit) allocate their indices from a heap
#              of their own in command buffer memory, sized at recording; the device's 128 MB geometry heap, reset to
#              its start by the first unroll of every command buffer and render pass, stays for indirect draws,
#              tessellation and geometry shaders. Resetting it is only safe while the queue runs every pass after the
#              previous one ended (end_encoder's barrier), which it does: two command buffers unrolling different
#              indices, the first waiting for a semaphore at its submission, keep their own (provoking_last.c 3.).
#              No 128 MB heap for processes that only unroll direct draws (zink's).
#   0044       steamac: unroll kernels (and draw predicates) run before the render pass instead of ending it
#              (attachments stored, compute pass, attachments loaded around every such draw). STEAMAC-G: with 0041
#              Steam's web helper still had 194 command buffers unrolling indexed draws (zink's last provoking vertex
#              with flat varyings), the longest 13.8 ms on an M1 Max with 37 render passes. Index, indirect and
#              predicate data cannot be written inside a render pass, so dispatches recorded with pre_gfx while a render
#              encoder is open go into a compute pass in a Metal command buffer of its own, committed right before the
#              render encoder's (a render encoder starts a Metal command buffer when the current one has an encoder; a
#              command buffer commits all of its Metal command buffers in order). Tessellation, geometry shaders and the
#              unrolls a passthrough GS reads still end the render encoder; the geometry heap is reset for the render
#              encoder that uses it and freed when it ends. Repro: host/moltenvk/repro provoking_last.c (11 indexed
#              draws: 12 render passes, 2.2 ms -> 1 render pass, 0.33 ms).
#   0045       steamac: query pools without 0037's per-device occlusion and per-process timestamp ceilings. Occlusion
#              results had 16 chunks of 32768 per device (524288 queries: exactly 128 of vkd3d-proton's occlusion pools
#              of 4096); the chunk table now has 4096 entries (2^27 queries, 32 GB: memory runs out first). Timestamp
#              pools held entries of Metal's 32 counter heaps of 4096 per process for their lifetime (all timestamp pools
#              of every guest application together: 131072 queries; D3D12 timestamp query heaps are pools of the heap's
#              size); entries now belong to command buffers (16 per chunk, taken while recording timestamp writes,
#              returned at reset/free), pools take none; a write finding none left makes its queries available with 0
#              (logged once). vkCreateQueryPool failures log their reason, VkResult, type and count in release builds
#              (STEAMAC-2X: Path of Exile 2's GPU context died on "vkCmdResetQueryPool resulted in CS error" after a
#              query pool failed to create). Compute encoder timestamps use Metal's precise granularity: relaxed sampled
#              only the first 4 of an encoder, the rest resolved their entry's old contents (hidden while entries were
#              per pool; vkd3d-proton's test_query_timestamp_write_after_read). Repro: host/moltenvk/repro queries.c
#              (300 occlusion pools of 4096 with 40 timestamp pools of 8192, one render pass over queries of five
#              occlusion pools; 3 x 4096 command buffers writing a timestamp each; 16 timestamps back to back).
#   0046       steamac: render encoders start a Metal command buffer of their own (0044) only in renderings whose draws
#              recorded pre_gfx work, and the pre_gfx pass goes at the end of the Metal command buffer they started
#              after. A Metal command buffer costs ~55 us of GPU time on an M1 Max: with one per render pass Steam's
#              web helper's command buffer of 77 blits took 12.6 ms instead of 0042's 6.5 (STEAMAC-G). A rendering's
#              first render encoder starts at its first use when it would follow other encoders, so that the first
#              draw's unrolls run ahead of it in the same Metal command buffer. Records count Metal command buffers.
#              Repro: host/moltenvk/repro provoking_last.c 5 (a clear, 8 blits, 8 render passes: one Metal command
#              buffer, 1.7 ms as with 0042; 0001-0045: 2.2-4.3 ms).
#   0047       steamac: KK_WORKAROUND_11 (one MTL4Compiler per MTLDevice, shared by all Vulkan devices) stays on macOS 27.
#              Upstream turns it off from 27.0.0 (FB22683138 fixed in beta 5), which betas 1-4 report too: there
#              virglrenderer (a device per Venus context) crashed in libmalloc's heap corruption trap with two contexts'
#              vkCreateDevice compiling libkk pipelines on their own compilers at once as a guest session started
#              (STEAMAC-31/13: beta 1 on an M4 Pro, beta 4 on an M3 Max; STEAMAC-39: a render pipeline, protection
#              fault in AGX). A shared compiler compiles as concurrently. A thread compiling for Metal is named after
#              its compile ("kk <kind> <MSL hashes> compiler <n>: <k> in flight on <m>", shown in crash reports);
#              MESA_KK_DEBUG=compiles logs every compile. Repro: host/moltenvk/repro compilers.c.
#   0048       steamac: subgroup operations in the vertex stage (simd_* functions are legal in MSL vertex functions,
#              only the attributes are not). Dragon's Dogma 2 uses wave ops in vertex shaders. Repro: wave_vertex.c.
#   0049       steamac: 64-bit buffer atomics (min/max lowered to MSL's void atomic_max/min_explicit on device
#              atomic_ulong); the operations MSL cannot express fail at pipeline creation. Repro: atomic64.c.
#   0050       steamac: the device keeps compiled MSL libraries, keyed by the source (a title asks for the same
#              program ~100 times: Dragon's Dogma 2 87,243 -> 6,244 library compiles in a warm launch).
#   0051       steamac: a pipeline's programs are compiled on a pool of threads (MESA_KK_COMPILE_THREADS) instead of the
#              ring thread; draws, dispatches and binds compile or wait for them.
#   0052       steamac: equal pipelines share their compiled Metal pipeline states (single-flight tables per device).
#   0053       steamac: destroying a shader whose program is still queued or compiling no longer waits for it; the
#              worker frees it. Dragon's Dogma 2's pipeline ring thread spent 73% of its time in vkDestroyPipeline
#              waiting for compiles, which kept Metal at ~2 compiles in flight.
#   0054       steamac: the graphics state hash covers the depth/stencil formats, the color attachment count and
#              location map and the depth clip/clamp lowering (pipelines that differed only there shared shaders
#              through a VkPipelineCache).
#   0055       steamac: the device's in-memory pipeline cache and Mesa's disk cache (translated MSL), so a pipeline is
#              translated SPIR-V -> NIR -> MSL once, not on every creation and every launch.
#   0056       steamac: MESA_KK_DEBUG=compiles lines carry start and end times ("[t <start> <end>]", ms).
#   0057       steamac: the first use of a program that is still queued compiles it right away instead of waiting
#              for the queue ahead of it (a bind under virglrenderer's shared submission lock froze the guest).
#              0053 + 0057, Dragon's Dogma 2 first launch, every cache cleared, M5 Max: the game's compile screen
#              takes ~8.5 min and gameplay renders at ~9 min, with ~7.5-9 Metal compiles in flight (62 min before
#              0051; 0052 alone reached 16% of the compile screen in 6 min).
#   0058       steamac: 64-bit image atomics (VK_EXT_shader_image_atomic_int64, shaderImageInt64Atomics): R64_UINT/
#              R64_SINT storage images as R32G32_UINT, image umax/umin lowered to Metal's void texture atomic_max/min
#              on ulong4, every other 64-bit image atomic rejected at pipeline creation (the buffer case is 0049).
#              Needed by UE5's D3D12 SM6 path (Nanite) through vkd3d-proton; MESA_KK_DEBUG=noimageint64atomics
#              turns it off. Repro case 27 (image_atomic64.c).
#
# Two meson builds: (1) the host compiler tools mesa_clc + vtn_bindgen2 against Homebrew LLVM
# (shared) and SPIRV-LLVM-Translator, installed into work/build/host-kosmickrisp/clc; (2) the driver
# with -Dllvm=disabled -Dmesa-clc=system (its own kk_clc is built in-tree), release,
# -Db_ndebug=true (a Mesa assert reached from the guest would abort the VMM) and
# MACOSX_DEPLOYMENT_TARGET=26.0. The dylib links only system libraries and frameworks.
#
# The staged dylib is checked before installation: host/moltenvk/probe (required features) and
# host/moltenvk/repro (REPRO_DRIVER=kosmickrisp), both through the Khronos loader (Homebrew
# vulkan-loader, test only).
#
# Output (work/out/host):
#   lib/libvulkan_kosmickrisp.dylib   install_name @rpath/libvulkan_kosmickrisp.dylib, ad-hoc signed.
#                                     Exports only the loader-ICD interface (vk_icd*);
#                                     virglrenderer opens it through VKR_VULKAN_DRIVER (its 0013).
#   KOSMICKRISP.txt                   provenance (Mesa commit, patches, patch revision)
# Installed by temp file + rename (a running VM may have the old dylib mapped).
set -eu

MESA_REPO=https://gitlab.freedesktop.org/mesa/mesa.git
MESA_COMMIT=ce576c29ed90822ea15564e1e60cb48e455881bb
MAKO_VERSION=1.3.10
PYYAML_VERSION=6.0.3
PACKAGING_VERSION=25.0
BREW_DEPS="meson ninja pkgconf llvm spirv-llvm-translator spirv-tools vulkan-loader glslang"

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
work=$root/work/build/host-kosmickrisp
src=$work/src
clc=$work/clc
out=$root/work/out/host

if [ "${1:-}" = clean ]; then
	rm -rf "$work"
	exit 0
fi

[ "$(uname -m)" = arm64 ] || { echo "KosmicKrisp needs Apple silicon" >&2; exit 1; }
macos=$(sw_vers -productVersion | cut -d. -f1)
[ "$macos" -ge 26 ] || { echo "KosmicKrisp needs macOS 26 or newer (Metal 4); this is macOS $macos" >&2; exit 1; }
xcrun --find metal > /dev/null

for dep in $BREW_DEPS; do
	brew list --versions "$dep" > /dev/null 2>&1 || brew install "$dep"
done
python=
for v in 3.14 3.13 3.12 3.11 3.10; do
	if command -v "python$v" > /dev/null 2>&1; then
		python=$(command -v "python$v")
		break
	fi
done
[ -n "$python" ] || { echo "Mesa needs Python >= 3.10 (brew install python)" >&2; exit 1; }

mkdir -p "$work"

# --- source at the pinned commit + patches
if [ ! -d "$src/.git" ]; then
	git init -q "$src"
	git -C "$src" remote add origin "$MESA_REPO"
fi
if ! git -C "$src" cat-file -e "$MESA_COMMIT^{commit}" 2> /dev/null; then
	git -C "$src" fetch -q --depth 1 origin "$MESA_COMMIT"
fi
git -C "$src" checkout -q -f --detach "$MESA_COMMIT"
git -C "$src" clean -q -fdx
for p in "$here"/patches/*.patch; do
	echo ">> applying $(basename "$p")"
	git -C "$src" apply --whitespace=nowarn "$p"
done
patch_rev=$(cat "$here"/patches/*.patch | shasum -a 256 | cut -c1-8)

# --- build-time python (Mesa needs Mako, PyYAML, packaging)
if [ ! -x "$work/venv/bin/python3" ] || ! "$work/venv/bin/python3" -c 'import sys; sys.exit(sys.version_info < (3, 10))'; then
	rm -rf "$work/venv"
	"$python" -m venv "$work/venv"
fi
"$work/venv/bin/pip" -q install "mako==$MAKO_VERSION" "pyyaml==$PYYAML_VERSION" "packaging==$PACKAGING_VERSION"

# --- (1) host compiler tools: mesa_clc + vtn_bindgen2
rm -rf "$work/build-clc" "$clc"
PATH="$work/venv/bin:$PATH:$(brew --prefix llvm)/bin" meson setup "$work/build-clc" "$src" \
	--prefix="$clc" --buildtype=release -Db_ndebug=true \
	-Dplatforms= -Dvulkan-drivers= -Dgallium-drivers= -Dopengl=false -Dglx=disabled \
	-Degl=disabled -Dgbm=disabled -Dzstd=disabled \
	-Dllvm=enabled -Dshared-llvm=enabled \
	-Dmesa-clc=enabled -Dinstall-mesa-clc=true \
	-Dprecomp-compiler=enabled -Dinstall-precomp-compiler=true
PATH="$work/venv/bin:$PATH:$(brew --prefix llvm)/bin" ninja -C "$work/build-clc" install > /dev/null

# --- (2) the driver
rm -rf "$work/build"
PATH="$clc/bin:$work/venv/bin:$PATH" MACOSX_DEPLOYMENT_TARGET=26.0 meson setup "$work/build" "$src" \
	--buildtype=release -Db_ndebug=true \
	-Dplatforms=macos -Dvulkan-drivers=kosmickrisp -Dgallium-drivers= -Dopengl=false \
	-Dglx=disabled -Degl=disabled -Dgbm=disabled -Dzstd=disabled -Dexpat=disabled \
	-Dllvm=disabled -Dspirv-tools=disabled -Dmesa-clc=system -Dprecomp-compiler=enabled \
	--prefer-static
PATH="$clc/bin:$work/venv/bin:$PATH" MACOSX_DEPLOYMENT_TARGET=26.0 ninja -C "$work/build"
built=$work/build/src/kosmickrisp/vulkan/libvulkan_kosmickrisp.dylib

# --- stage
stage=$work/stage
rm -rf "$stage"
mkdir -p "$stage/lib"
staged=$stage/lib/libvulkan_kosmickrisp.dylib
cp "$built" "$staged"
install_name_tool -id @rpath/libvulkan_kosmickrisp.dylib "$staged"
if otool -L "$staged" | sed 1,2d | grep -qv -e '^[[:space:]]*/usr/lib/' -e '^[[:space:]]*/System/'; then
	echo "libvulkan_kosmickrisp links non-system libraries:" >&2
	otool -L "$staged" >&2
	exit 1
fi
nm -gU "$staged" | grep -q ' _vk_icdGetInstanceProcAddr$'
codesign --force -s - "$staged"

# --- probe + repros on the staged dylib (Khronos loader, test only)
icd=$work/stage/kosmickrisp_icd.json
printf '{"file_format_version": "1.0.1", "ICD": {"library_path": "%s", "api_version": "1.4.0"}}\n' \
	"$staged" > "$icd"
loader=$(brew --prefix vulkan-loader)/lib
probe=$work/probe
xcrun clang -std=c11 -Wall -Werror -O1 -I"$root/work/build/host-moltenvk/src/Package/Release/MoltenVK/include" \
	"$root/host/moltenvk/probe/probe.c" -L"$loader" -lvulkan -Wl,-rpath,"$loader" -o "$probe"
echo ">> probe: $staged"
VK_DRIVER_FILES=$icd "$probe"
echo ">> repro (REPRO_DRIVER=kosmickrisp)"
repro_log=$work/repro.log
REPRO_DRIVER=kosmickrisp "$root/host/moltenvk/repro/run.sh" "$staged" > "$repro_log" 2>&1 ||
	{ cat "$repro_log"; exit 1; }
grep -v '^	' "$repro_log" | grep -v 'Metal API Validation Enabled'

# --- install (temp + rename, never rewrite a mapped dylib in place)
mkdir -p "$out/lib"
lib=$out/lib/libvulkan_kosmickrisp.dylib
cp "$staged" "$lib.tmp.$$"
mv -f "$lib.tmp.$$" "$lib"

# --- provenance
{
	echo "KosmicKrisp for steamac (alternative host Venus driver)"
	echo
	echo "source:          $MESA_REPO"
	echo "commit:          $MESA_COMMIT (main, 2026-10-05)"
	echo "patch revision:  $patch_rev (sha256 of host/kosmickrisp/patches/*.patch)"
	echo "driver:          $(VK_DRIVER_FILES=$icd "$probe" 2> /dev/null | sed -n 's/^driver: *//p')"
	echo "Xcode:           $(xcodebuild -version | tr '\n' ' ')"
	echo "built:           $(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo
	echo "Patches (host/kosmickrisp/patches):"
	for p in "$here"/patches/*.patch; do echo "  $(basename "$p")"; done
	echo "  0001-0015 = mesa!44928 (draft) transform feedback on mesa!44786 geometry shaders"
	echo "  0016 = mesa!44929 tiled images in host pointer imports"
	echo "  0017 = mesa!44221 device-local-only memory type"
	echo "  0018 = mesa!44782 (closed) LINEAR color attachments / blit destinations"
	echo "  0019 = steamac: explicit LINEAR row pitch of imported dma-buf images"
	echo "  0020 = mesa!44222 linear textures as 2D plus a 2D array view (input attachments)"
	echo "  0021 = steamac: LINEAR input attachments (zink / Gamescope WSI swapchains)"
	echo "  0022 = steamac: fillModeNonSolid (wireframe; DXVK requires it)"
	echo "  0023 = steamac: unsupported sample counts use the largest supported one"
	echo "  0024 = steamac: single texel alignment for texel buffer views (vkd3d-proton)"
	echo "  0025 = steamac: timestamp pools over several Metal counter heaps (4096 each; vkd3d-proton 8192)"
	echo "  0026 = steamac: device/queue losses (and their Metal error) printed on stderr"
	echo "  0027 = steamac: sparse residency queries in shaders (MSL sparse_sample/sparse_read)"
	echo "  0028 = steamac: sparse binding/residency via Metal 4 placement sparse resources (tiled resources)"
	echo "  0029 = steamac: sampler min/max reduction emulated in shaders before Apple10"
	echo "  0030 = steamac: unmaps of sparse buffer pages applied (resident one page buffer mapped after them)"
	echo "  0031 = steamac: texel buffer views of sparse buffers (placement sparse texture buffers)"
	echo "  0032 = steamac: sparse sample residency for LODs past the last level"
	echo "  0033 = steamac: VK_EXT_image_view_min_lod by default"
	echo "  0034 = steamac: residency of sparse loads through texel buffer views (residency texture per buffer)"
	echo "  0035 = steamac: sparse residency through views with baseMipLevel > 0 (residency views from level 0), and of gathers"
	echo "  0036 = steamac: sampler min/max emulation only for draws with a reduction sampler bound (second program)"
	echo "  0037 = steamac: occlusion queries past one visibility buffer (chunks), timestamp pools on shared counter heaps"
	echo "  0038 = steamac: command queue errors name the GPU time and still unsignalled semaphore waits"
	echo "  0039 = steamac: command queue errors name the device, timing and os_log GPU error; queue teardown waits for handlers"
	echo "  0040 = steamac: base textures of image planes, subresource and texel buffer view textures in the residency set"
	echo "  0041 = steamac: CPU unroll of direct non-indexed draws (no render pass split); command buffer records in queue errors"
	echo "  0042 = steamac: R32G32B32 uniform texel buffers; views of unsupported formats read as null descriptors"
	echo "  0043 = steamac: unrolls of direct draws allocate from command buffer memory, not the device geometry heap"
	echo "  0044 = steamac: unroll kernels and draw predicates in a compute pass before the render pass, not splitting it"
	echo "  0045 = steamac: no per-device occlusion / per-process timestamp pool ceilings; vkCreateQueryPool failures logged"
	echo "  0046 = steamac: Metal command buffers of their own only for render passes with pre_gfx work (blits, clears: none)"
	echo "  0047 = steamac: KK_WORKAROUND_11 (one shared MTL4Compiler) kept on macOS 27; compiling threads named after their compile"
	echo
	echo "Known gaps (host/moltenvk/repro/run.sh): transform feedback with strip geometry shaders and"
	echo "the overflow counter (draft !44928)."
} > "$out/KOSMICKRISP.txt.tmp.$$"
mv -f "$out/KOSMICKRISP.txt.tmp.$$" "$out/KOSMICKRISP.txt"

echo ">> $lib"
otool -L "$lib"
