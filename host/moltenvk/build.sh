#!/bin/sh
# Build MoltenVK for the host Venus renderer (virglrenderer -> MoltenVK -> Metal).
#
#   host/moltenvk/build.sh        build/refresh work/out/host (MoltenVK dylib, ICD json, headers)
#   host/moltenvk/build.sh clean  drop the source/build tree (next build is from scratch)
#
# Inputs (all pinned):
#   MoltenVK     utmapp/MoltenVK branch geometry-shaders @ 05604465 (UTM's pin,
#                patches/sources in utmapp/UTM): v1.4.1 + geometry shaders via Metal
#                mesh shaders, robustness2 RBA2/RIA2/nullDescriptor, shaderCullDistance
#                flag, VK_EXT_transform_feedback
#   SPIRV-Cross  utmapp/SPIRV-Cross @ 939b40b3 (the fork's ExternalRevisions pin)
#   patches/moltenvk/     applied in order on MoltenVK (git format-patch series)
#   patches/spirv-cross/  applied in order on SPIRV-Cross, passed to fetchDependencies
#                         via --spirv-cross-root
#   Local 1.9.8 follow-up:
#   MoltenVK 0045 (STEAMAC-76/77): Venus HOST_ALLOCATION optimal 3D images had no
#   placement heap for 2D aliases (TF2 MVKImageViewPlane::newMTLTexture crash).
#   volume_views imported clear/readback reproduced SIGSEGV; placement-backed
#   optimal storage preserves imported/plain dynamic-rendering slice contents.
#   SPIRV-Cross 0051 (STEAMAC-75): packing outputs by Location alone lost Index=1,
#   reproducing Metal's missing color(0), index(1) error. sentry-75-dual-source.sh
#   validates all four plain/packed source combinations and reads blended pixels.
#   MoltenVK 0046 retains Vulkan blend factors and reflected output indices on
#   pipeline failure; sentry_75_reflection.cpp checks both indices on those SPVs.
#   The original 1.9.8 fragment was absent; the 1.9.9 recurrence is covered below.
#   MoltenVK 0047 (STEAMAC-41): a 173-line object shader lost its middle, bindings
#   and entry point in bounded diagnostics. Preserve complete small shaders and
#   failed Metal descriptors; run.sh's link-log checks templates, shader middle
#   and descriptors. Diagnostic-only: no proven workaround for Apple's compiler.
#   MoltenVK 0048 (STEAMAC-6V/87/88/2M/81): library compilation bypassed 0047,
#   while a second compute error prematurely closed the launcher's report. Keep
#   complete library/pipeline shaders up to 64 KiB / 1536 lines, compute descriptors,
#   and a single diagnostic stream. Launcher fields retain 128 KiB independently
#   instead of cutting small vertex shaders and descriptors off at 8000 characters.
#   Existing pull-model regression shaders still need full source from the new 6V
#   report; no speculative shader workaround or Apple-compiler workaround is applied.
#   MoltenVK 0049 (STEAMAC-83/89): combining tessellation and geometry selected
#   incompatible paths and emitted the unassigned vertex capture slot buffer(255).
#   Reject this unsupported combination before Metal compilation instead of silently
#   dropping its required geometry stage. pipeline_limits tessgeom reproduces the
#   old error with a four-stage, no-fragment layered pass. This is a diagnostic,
#   not tessellation-to-geometry support or a fix for the separately observed hang.
#   Local 1.9.10 follow-up:
#   MoltenVK 0050 / SPIRV-Cross 0052 (STEAMAC-75 recurrence): the complete fragment
#   writes only the primary color while blend state uses OneMinusSource1Alpha.
#   Vulkan permits an absent secondary output (undefined value), but Metal rejects
#   the pipeline. Reflect original Index=1 locations before masking/packing and
#   choose zero for absent secondary inputs by translating only SRC1 blend factors.
#   frag_output dual-source checks all four factors, masked Location=1, real packed
#   and array secondary outputs, GPU pixels, and serialized pipeline-cache reuse.
#   MoltenVK 0051 / SPIRV-Cross 0053 (STEAMAC-8J): no original shader was retained,
#   but sample-rate projected sampling reproduces the exact missing
#   llvm.agx2.sample.itrproj.1xf symbol on M1 Max. On M1 only, use pull-model
#   interpolation at get_sample_position(sample_id), preserving division and
#   interpolation positions while avoiding Apple's broken projected-sample fusion.
#   sentry-8j-projected.sh checks plain/helper/block/array/noperspective/explicit
#   sample inputs, native interpolation pixels, 1x/4x MSAA and all Metal math modes;
#   pipeline_limits projected exercises the Vulkan-to-Metal pipeline path.
#   SPIRV-Cross 0054 (STEAMAC-87/88/2M candidate): flattening a stage interface
#   block ignored explicit Locations after its first member, turning Locations
#   0/2 into user(locn0)/user(locn1). Restart the location range at each decorated
#   member, retaining array/matrix strides and Component sharing. The private
#   sentry-block-locations.sh regression fails before the patch and passes after:
#   16 validated vertex/fragment shaders match SPIR-V and all 16 block/standalone
#   combinations link in Metal. This proves a translator bug, not these events'
#   root cause: their SPIR-V is absent, 87's repeated identical locations were not
#   reproduced, and 2M also used tessellation. Keep all three reports unresolved.
#   Xcode        command line tools + Metal toolchain (built and tested with Xcode 26.3)
#
# Build is UTM's (scripts/build_dependencies.sh build_moltenvk): ./fetchDependencies --macos
# then `make macos` (Release, universal), then the arm64 slice is extracted.
#
# Metal private API (MVK_USE_METAL_PRIVATE_API=1: logicOp, wideLines, ...) is NOT enabled, same
# as UTM and Homebrew: the fork's geometry-shader mesh pipeline path does not compile with it
# (MTLMeshRenderPipelineDescriptor has no logicOperation*/sampleMask private properties).
# See MOLTENVK.txt.
#
# Output (work/out/host):
#   lib/libMoltenVK.dylib                     arm64, install_name @rpath/libMoltenVK.dylib, ad-hoc signed
#   share/vulkan/icd.d/MoltenVK_icd.json      library_path ../../../lib/libMoltenVK.dylib
#   include/MoltenVK/                         mvk_vulkan.h, mvk_private_api.h, ... (they
#                                             include <vulkan/...>, from the Vulkan SDK/Homebrew
#                                             vulkan-headers or from the MoltenVK package in
#                                             work/build/host-moltenvk/src/Package/Release/MoltenVK/include)
#   MOLTENVK.txt                              provenance + enabled features
# The dylib is first staged in work/build/host-moltenvk/stage and verified there: the probe in
# probe/ (fails when a feature steamac depends on is missing) and the repros in repro/ (all of
# gamescope 3.16.28's cs_*.comp pipelines + a pixel check, also with robustBufferAccess2; zink-style
# geometry shaders + pixel checks; draws with a VK_NULL_HANDLE pipeline bound; robustBufferAccess2
# bounds; null set layouts and unsupported sample counts; ... see repro/run.sh). Only then is it
# installed, by temp file + rename (a running VM may have the old dylib mapped).
set -eu

MVK_REPO=https://github.com/utmapp/MoltenVK.git
MVK_BRANCH=geometry-shaders
MVK_COMMIT=05604465d691118cfd20f53a48ecf1aad9c12f93
SPVC_REPO=https://github.com/utmapp/SPIRV-Cross.git
SPVC_COMMIT=939b40b33a44443c404c4078823c406e3c94866f

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
work=$root/work/build/host-moltenvk
src=$work/src
spvc=$work/SPIRV-Cross
out=$root/work/out/host

if [ "${1:-}" = clean ]; then
	rm -rf "$work"
	exit 0
fi

xcrun --find metal > /dev/null

mkdir -p "$work"

# fetch_pinned <dir> <repo> <commit>: shallow checkout of one commit, patches dropped
fetch_pinned() {
	if [ ! -d "$1/.git" ]; then
		git init -q "$1"
		git -C "$1" remote add origin "$2"
	fi
	if ! git -C "$1" cat-file -e "$3^{commit}" 2> /dev/null; then
		git -C "$1" fetch -q --depth 1 origin "$3"
	fi
	git -C "$1" checkout -q -f --detach "$3"
}

# apply_series <dir> <patch dir>
apply_series() {
	for p in "$2"/*.patch; do
		echo ">> $(basename "$1"): applying $(basename "$p")"
		git -C "$1" apply "$p"
	done
}

# --- SPIRV-Cross (pinned by the fork) + patches
fetch_pinned "$spvc" "$SPVC_REPO" "$SPVC_COMMIT"
git -C "$spvc" clean -q -fdx
apply_series "$spvc" "$here/patches/spirv-cross"

# --- MoltenVK + patches (External/ survives re-runs; it is rebuilt when its inputs change)
fetch_pinned "$src" "$MVK_REPO" "$MVK_COMMIT"
test "$(cat "$src/ExternalRevisions/SPIRV-Cross_repo_revision")" = "$SPVC_COMMIT"
git -C "$src" clean -q -fdx -e /External
apply_series "$src" "$here/patches/moltenvk"
# Revision of both patch series, part of VkPhysicalDeviceProperties::pipelineCacheUUID (MoltenVK patch
# "pipeline cache UUID"): pipeline caches written with other patches (for example by guests that keep
# zink's or DXVK's caches across host updates) are rejected instead of reusing their outdated MSL.
patch_rev=$(cat "$here"/patches/moltenvk/*.patch "$here"/patches/spirv-cross/*.patch | shasum -a 256 | cut -c1-8)
printf '// Generated by host/moltenvk/build.sh\n#define MVK_PATCH_REVISION 0x%s\n' "$patch_rev" \
	> "$src/MoltenVK/MoltenVK/GPUObjects/MVKPatchRevision.h"

# --- external dependencies (SPIRV-Cross, SPIRV-Tools, Vulkan-Headers, ... -> xcframeworks)
deps_key=$(cat "$src/ExternalRevisions/"* "$here"/patches/spirv-cross/*.patch | shasum -a 256 | cut -d' ' -f1)
deps_stamp=$src/External/.steamac-deps
if [ "$(cat "$deps_stamp" 2> /dev/null)" != "$deps_key" ]; then
	rm -f "$deps_stamp"
	# Same environment scrub as UTM (env -i): no Homebrew/SDK variables leak into xcodebuild.
	(cd "$src" && env -i PATH="$PATH" HOME="$HOME" LANG="${LANG:-en_US.UTF-8}" \
		./fetchDependencies --macos --spirv-cross-root "$spvc")
	echo "$deps_key" > "$deps_stamp"
fi

# --- MoltenVK (Release, universal)
(cd "$src" && env -i PATH="$PATH" HOME="$HOME" LANG="${LANG:-en_US.UTF-8}" make macos)

pkg=$src/Package/Release/MoltenVK
built=$pkg/dynamic/dylib/macOS

# --- stage
stage=$work/stage
rm -rf "$stage"
mkdir -p "$stage/lib"
staged=$stage/lib/libMoltenVK.dylib
lipo "$built/libMoltenVK.dylib" -thin arm64 -output "$staged"
test "$(otool -D "$staged" | sed -n 2p)" = "@rpath/libMoltenVK.dylib"
codesign --force -s - "$staged"

# --- probe (links the staged dylib directly, like virglrenderer)
probe=$work/probe
xcrun clang -std=c11 -Wall -Werror -O1 -I"$pkg/include" "$here/probe/probe.c" \
	-L"$stage/lib" -lMoltenVK -Wl,-rpath,"$stage/lib" -o "$probe"
echo ">> probe: $staged"
probe_log=$work/probe.log
MVK_CONFIG_LOG_LEVEL=1 "$probe" > "$probe_log" 2>&1 || { cat "$probe_log"; exit 1; }
cat "$probe_log"
# MoltenVK validates its shader-cache (cereal) archive layouts at vkCreateInstance and prints
# [MVK-BUILD-ERROR] when a patch changed a serialized struct without updating it.
if grep -q 'MVK-BUILD-ERROR' "$probe_log"; then
	echo "probe: MoltenVK reported a build error (see above)" >&2
	exit 1
fi

# --- repros: gamescope compute pipelines, geometry shaders, null pipeline binds
echo ">> repro: gamescope compute pipelines, geometry shaders, null pipeline binds"
repro_log=$work/repro.log
"$here/repro/run.sh" "$stage/lib" > "$repro_log" 2>&1 || { cat "$repro_log"; exit 1; }
grep -v '^\[mvk-info\]\|^	' "$repro_log"

# --- install (temp + rename, never rewrite a mapped dylib in place)
mkdir -p "$out/lib" "$out/share/vulkan/icd.d" "$out/include"
lib=$out/lib/libMoltenVK.dylib
cp "$staged" "$lib.tmp.$$"
mv -f "$lib.tmp.$$" "$lib"

icd=$out/share/vulkan/icd.d/MoltenVK_icd.json
sed 's#"library_path"[[:space:]]*:[[:space:]]*"[^"]*"#"library_path": "../../../lib/libMoltenVK.dylib"#' \
	"$built/MoltenVK_icd.json" > "$icd.tmp.$$"
grep -q '"library_path": "../../../lib/libMoltenVK.dylib"' "$icd.tmp.$$"
mv -f "$icd.tmp.$$" "$icd"

rm -rf "$out/include/MoltenVK.tmp.$$"
cp -R "$pkg/include/MoltenVK" "$out/include/MoltenVK.tmp.$$"
rm -rf "$out/include/MoltenVK"
mv "$out/include/MoltenVK.tmp.$$" "$out/include/MoltenVK"

# --- provenance
mvk_version=$(sed -n 's/.*"api_version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$built/MoltenVK_icd.json")
{
	echo "MoltenVK for steamac (host Venus renderer)"
	echo
	echo "source:       $MVK_REPO"
	echo "branch:       $MVK_BRANCH"
	echo "commit:       $MVK_COMMIT  (UTM's pin; utmapp/MoltenVK = v1.4.1 + 16 commits)"
	echo "SPIRV-Cross:  $SPVC_REPO @ $SPVC_COMMIT"
	echo "ICD api_version: $mvk_version"
	echo "Xcode:        $(xcodebuild -version | tr '\n' ' ')"
	echo "built:        $(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo
	echo "Fork features (05604465): geometry shaders via Metal mesh shaders (no GS with"
	echo "  indirect draws), robustness2 robustBufferAccess2/robustImageAccess2/nullDescriptor,"
	echo "  shaderCullDistance (flag only, no culling), VK_EXT_transform_feedback (1 buffer,"
	echo "  geometryStreams faked, no transformFeedbackQueries); host-pointer imports on"
	echo "  non-host-visible memory types (osy, upstreamed as MoltenVK PR #2834)."
	echo
	echo "MoltenVK patches (host/moltenvk/patches/moltenvk):"
	for p in "$here"/patches/moltenvk/*.patch; do echo "  $(basename "$p")"; done
	echo "  0001 = KhronosGroup/MoltenVK 74850136 (reversed-depth viewport emulation;"
	echo "         prerequisite of 0002, only active on AMD Mac2 GPUs)"
	echo "  0002 = KhronosGroup/MoltenVK PR #2712 dc89e437 (VK_EXT_depth_clip_enable, conformant"
	echo "         KosmicKrisp-style emulation); Metal OpenGL-mode compensation dropped, GS stages"
	echo "         excluded from depth-clip emulation (see patch header)"
	echo "  0003 = steamac: Y'CbCr immutable-sampler arrays got the SUM of the samplers' plane counts"
	echo "         (16 NV12 samplers -> 32 'planes' -> Tex3SampSoA) instead of the maximum; broke"
	echo "         gamescope's s_ycbcr_samplers[16] (same bug in KhronosGroup/MoltenVK main)"
	echo "  0004 = steamac: nullDescriptor -> image size/levels/samples queries on null descriptors"
	echo "         return 0 (was only with robustImageAccess2; Metal reports 1 mip level for nil)"
	echo "  0005 = steamac: vkCmdBindPipeline(VK_NULL_HANDLE) (Venus replays it when host pipeline"
	echo "         creation failed) skips draws/dispatches instead of crashing the process"
	echo "  0006 = steamac: GS draw info (list/strip) was passed to Metal before it was filled in"
	echo "  0007 = steamac: geometry shaders on line lists / line strips (was 'Unsupported topology')"
	echo "  0008 = steamac: indirect and indexed-indirect draws with geometry shaders (GPU conversion"
	echo "         to mesh threadgroups), firstVertex/vertexOffset/firstInstance for GS draws"
	echo "  0009 = upstream 2da7c3cb: linear color formats renderable again on Apple GPUs (the fork"
	echo "         read renderLinearTextures before it was initialised: linear tiling lost"
	echo "         COLOR_ATTACHMENT/BLEND/BLIT_DST, breaking zink rendering into linear dma-bufs)"
	echo "  0010 = steamac: depth/stencil formats no longer report HOST_IMAGE_TRANSFER (their images"
	echo "         need private memory; with HOST_TRANSFER memoryTypeBits was 0, so zink could not"
	echo "         allocate any depth/stencil renderbuffer: GL FBOs incomplete, CEF/Skia no stencil)"
	echo "  0011 = steamac: GS object stage fetches vertices with the bound (dynamic) strides; zink's"
	echo "         provoking-vertex GS on every draw with dynamic stride read vertex 0 (all black)"
	echo "  0012 = steamac: LINEAR images use the row pitch of a chained"
	echo "         VkImageDrmFormatModifierExplicitCreateInfoEXT (virglrenderer dma-buf imports)"
	echo "  0013 = steamac: GS with *_WITH_ADJACENCY topologies (zink GL_QUADS: second triangle was"
	echo "         missing) and per-instance vertex attributes (glamor instanced rectangles)"
	echo "  0014 = steamac: GS input primitive from the shader (dynamic topology: zink pipelines with a"
	echo "         static TRIANGLE_FAN failed), triangle fans assembled by the GS object stage"
	echo "  0015 = steamac: GS object stage vertex attributes read with their memory type (SCALED/NORM"
	echo "         formats such as glamor's R16G16_SSCALED were read as float bits)"
	echo "  0016 = steamac: GS DrawInfo buffer index allocated after the vertex stage's implicit buffers"
	echo "         (was fixed at 20: collided with the buffer-size buffer with 8 vertex bindings)"
	echo "  0017 = steamac: implicit buffer indices allocated around the vertex buffers actually used"
	echo "         (high/sparse bindings wrapped or collided); fail cleanly when no index is free"
	echo "  0018 = steamac: pipelineCacheUUID includes MVK_PATCH_REVISION ($patch_rev, hash of both patch"
	echo "         series): caches written with other patches (guest zink/DXVK caches) are ignored"
	echo "  0019 = steamac: transform feedback captured by geometry shaders (buffers, counters, ordered"
	echo "         capture via count pass + scan + write pass); VS/TES capture fails pipeline creation"
	echo "  0020 = steamac: pipeline cache entries whose MSL does not compile are dropped instead of"
	echo "         failing vkCreatePipelineCache"
	echo "  0021 = steamac: GS pipelines without a fragment shader get an empty fragment function (or"
	echo "         rasterization off with static discard); Metal aborted the process otherwise"
	echo "  0022 = steamac: Metal objects of destroyed memory/buffers/images/views released (and removed"
	echo "         from the residency set) after the queues' in-flight command buffers complete"
	echo "         (semaphores signal before completion; DXVK frees chunks then: InvalidResource);"
	echo "         batched: one empty marker command buffer per queue per 2 ms of destroys"
	echo "  0023 = steamac: VK_NULL_HANDLE set layouts in pipeline layouts (independent sets, sent through"
	echo "         Venus) act as empty set layouts (MVKPipelineLayout::Create dereferenced them: SIGSEGV)"
	echo "  0024 = steamac: unsupported sample counts (8 on Apple GPUs) become the largest supported count in"
	echo "         pipelines (rasterSampleCount), images and render pass attachments, with a warning"
	echo "  0025 = steamac: the MSL of a failed shader library compile is written to stderr as '[mvk-msl] '"
	echo "         lines (first 40 lines, +-5 lines around each error location) for the launcher's reports"
	echo "  0026 = steamac: vertex input checked like Metal's always-on vertex descriptor validation before"
	echo "         pipeline creation (it aborted the VM: 'references a buffer ... that has no stride');"
	echo "         attributes of undescribed bindings fail the pipeline (also with GS emulation)"
	echo "  0027 = KhronosGroup/MoltenVK 701747d6 (PR #2794): vkCmdCopyQueryPoolResults read the availability"
	echo "         of queries from query 0 and treated queryCount as the end query; Venus copies every ended"
	echo "         query separately (query feedback), so DXVK's occlusion queries > 0 never became available"
	echo "  0028 = steamac: transform feedback queries (primitives written/needed of stream 0, added by the"
	echo "         capture's slot pass; other streams count 0), vkCmdBegin/EndQueryIndexedEXT, query results"
	echo "         with several values; transformFeedbackQueries (required by vkd3d-proton)"
	echo "  0029 = steamac: single texel alignment emulation (texel buffer views at any texel offset, required by"
	echo "         vkd3d-proton) also with Metal argument buffers: the view's texel offset is kept in the set's aux"
	echo "         buffer (discrete sets: implicit texture offset buffer, indexed by texture), SPIRV-Cross adds it;"
	echo "         buffer sizes of array updates starting past element 0 were written at the wrong elements"
	echo "  0030 = steamac: small buffers (< 64 KiB) bound without argument buffers (push descriptors) with"
	echo "         robustBufferAccess2 are bound themselves, not replaced by a 64 KiB copy of their CPU contents"
	echo "         (shader writes were lost, GPU-written data not seen; vkd3d-proton root descriptors)"
	echo "  0031 = steamac: the logged MSL of a failed compile leaves out SPIRV-Cross' helper templates (they"
	echo "         filled the 40-line head) and logs each error context line once"
	echo "  0032 = steamac: variable-count descriptor sets with buffer sizes (UBO/SSBO, texel buffers with texel"
	echo "         offsets) took one size slot per element twice; exactly sized pools ran out (vkd3d-proton's"
	echo "         descriptor heaps: VK_ERROR_OUT_OF_POOL_MEMORY, Venus stopped the game's command stream)"
	echo "  0033 = steamac: variable-count bindings of Metal 3 argument buffer sets are runtime arrays in shaders"
	echo "         (SPIRV-Cross 0027): declared with their full count (1000000, vkd3d-proton's heaps) Metal kept a"
	echo "         32 MB table per array and program (~100 MB per pipeline; Stellar Blade's VM reached 250 GB);"
	echo "         pipeline states also compile ~7x faster"
	echo "  0034 = steamac: VK_NULL_HANDLE descriptor sets in vkCmdBindDescriptorSets bind nothing and take no"
	echo "         dynamic offsets (graphics pipeline libraries; Counter-Strike 2's null fourth set crashed the VM"
	echo "         process at submission, STEAMAC-25)"
	echo "  0035 = steamac: the color attachments' numeric types by location go to SPIRV-Cross (0033)"
	echo "  0036 = steamac: vertex shader inputs without a vertex attribute read zeros (SPIRV-Cross 0034; Metal failed"
	echo "         the pipeline: 'Vertex attribute in_var_NORMAL(1) is missing from the vertex descriptor', SCS Truck"
	echo "         Simulator, STEAMAC-2Y)"
	echo "  0037 = steamac: integer vertex shader inputs fed by float vertex formats are fetched in a format-compatible"
	echo "         type and bit cast (SPIRV-Cross 0035; Metal: 'Vertex attribute BLENDINDICES1(4) of type int4 cannot be"
	echo "         read using MTLAttributeFormatFloat3', BLUE REFLECTION Second Light, STEAMAC-3N)"
	echo "  0038 = steamac: texel buffer views of formats Metal has no pixel format for fail with"
	echo "         VK_ERROR_FORMAT_NOT_SUPPORTED (was an abort in minimumLinearTextureAlignmentForPixelFormat:"
	echo "         with MTLPixelFormatInvalid, Uncharted, STEAMAC-3Q/3)"
	echo "  0039 = steamac: a failed graphics pipeline logs each stage's entry point, shader hash and reflected"
	echo "         interface locations/types (link failures and compiler errors without MSL, STEAMAC-2M/41)"
	echo "  0041 = steamac: constrained vertex stages allocate only auxiliary buffers used by their shader;"
	echo "         12 vertex buffers plus 18 discrete SSBOs left buffer sizes at buffer(255) (STEAMAC-67)"
	echo "  0042 = steamac: blending on non-blendable attachments fails before Metal descriptor validation"
	echo "         aborts the VM (STEAMAC-3A/X: blending enabled on R32_UINT)"
	echo "  0043 = steamac: failed graphics/compute pipelines log bounded MSL, source sizes and threadgroup"
	echo "         declarations; compute errors include entry/hash/workgroup and Metal shared-memory limit"
	echo "         (STEAMAC-57/41/R/3X: existing reports cannot prove the cause)"
	echo "  0044 = steamac: Vulkan specialization IDs are translated through SPIRV-Cross's Metal index map,"
	echo "         retained in serialized pipeline caches; unused IDs cannot alias compact indices (STEAMAC-6A)"
	echo "  0045 = steamac: optimal images on imported host memory or existing buffers keep their separate"
	echo "         backing in an image-owned placement heap, so 2D/3D aliases do not dereference a null heap;"
	echo "         imported and ordinary volume slice render/readback regression (STEAMAC-76/77)"
	echo "  0046 = steamac: failed graphics pipelines retain static Vulkan blend state and reflected"
	echo "         dual-source output indices (STEAMAC-75); reflection covers all four packed/plain pairs"
	echo "  0047 = steamac: failed render/mesh pipelines include their Metal descriptors; shaders up to"
	echo "         32 KiB/512 lines are complete, including helpers and the middle lost by 0043"
	echo "         (STEAMAC-41: no proven compiler workaround; diagnostic capture regression)"
	echo "SPIRV-Cross patches (host/moltenvk/patches/spirv-cross):"
	for p in "$here"/patches/spirv-cross/*.patch; do echo "  $(basename "$p")"; done
	echo "  0001/0002 = KhronosGroup/SPIRV-Cross 35f52882+da223760 and 0706157e (PR #2666), library only"
	echo "  0003 = steamac: arrays of Y'CbCr combined image-samplers with argument buffers (plane"
	echo "         indexes, plane/sampler expressions for array elements, spvDynamicImageSampler for"
	echo "         elements passed to functions, padding of multiplanar bindings, constant gather"
	echo "         component); needed by gamescope's compute shaders"
	echo "  0004 = steamac: MSL option null_descriptor (zero image queries on nil textures)"
	echo "  0005 = steamac: gl_PrimitiveIDIn / gl_PrimitiveID in the mesh-emulated geometry stage"
	echo "         (zink's passthrough GS failed to compile)"
	echo "  0006 = steamac: GS input primitive assembly (list primitives > 0 read wrong vertices;"
	echo "         strip winding)"
	echo "  0007 = steamac: robustBufferAccess2 on arrays of uniform/storage buffers (zink UBO arrays"
	echo "         did not compile), interface blocks no longer treated as buffers, GS wrappers pass"
	echo "         arrays of discrete buffers per element"
	echo "  0008 = steamac: variables named 'sampler'/'array' (MSL type names) are renamed (glamor)"
	echo "  0009 = steamac: base vertex / base instance in the GS object stage"
	echo "  0010 = steamac: an input builtin declared by several variables (zink gl_PrimitiveIDIn)"
	echo "         becomes one entry point argument"
	echo "  0011 = steamac: GS object stage vertex strides come from DrawInfo (dynamic strides)"
	echo "  0012 = steamac: vertex->geometry payload by builtin/location (GS may read any subset of"
	echo "         the vertex outputs; gl_in[] block inputs of glslang/DXVK geometry shaders work)"
	echo "  0013 = steamac: adjacency input topologies (incl. triangle-strip-adjacency vertex order)"
	echo "         and instance-rate attribute fetch in the GS object stage"
	echo "  0014 = steamac: triangle fans in the GS object stage"
	echo "  0015 = steamac: GS object stage vertex attribute conversion (8/16-bit SCALED/NORM types,"
	echo "         SNORM normalization, fill of missing components)"
	echo "  0016 = steamac: transform feedback in emulated geometry shaders (mesh stream capture,"
	echo "         implicit position for stream-output-only GS, EmitStreamVertex stream 0)"
	echo "  0017 = steamac: gl_WorkGroupSize declared for zero-initialized workgroup memory (DXVK compute"
	echo "         shaders: 'use of undeclared identifier gl_WorkGroupSize')"
	echo "  0018 = steamac: robustBufferAccess2 loads select against a zero of the logical type (packed and"
	echo "         row-major matrices unpacked first: gamescope u_ctm[]; structs 'S{}'; arrays through a"
	echo "         zeroed temporary), texture atomic_store() without '.x' and with the value first,"
	echo "         bounds use the ArrayStride of the array type and the offset of a runtime array, and"
	echo "         every use of a bounds-checked access chain is checked (read-modify-write stores)"
	echo "  0019 = steamac: atomics on vector components behind buffer device addresses go through a scalar"
	echo "         pointer, like SSBO components (they took the address of a vector element: vkd3d-proton's"
	echo "         device-creation pipeline cs_emit_nv_memory_decompression_regions failed to compile); other"
	echo "         component accesses keep the vector form (the cast made gathered loads 5% slower)"
	echo "  0020 = steamac: texture buffer offsets of argument buffers read from the buffer size array at the"
	echo "         texture's index (MoltenVK's aux buffer); robustImageAccess2 bounds of texture buffers with an"
	echo "         offset use the view's width"
	echo "  0021 = steamac: vertex/fragment entry points of multi-entry-point modules leave out the workgroup"
	echo "         variables of the module's compute entry points ('variables in the threadgroup address space"
	echo "         cannot be declared in a vertex function', also their zero initialization)"
	echo "  0022 = steamac: the gl_WorkGroupSize constant synthesized for LocalSizeId (zero-initialized"
	echo "         workgroup memory, 0017) keeps workgroup_size.x/y/z: MoltenVK dispatched 1x1x1 threadgroups"
	echo "         for every DXVK compute shader with groupshared memory (Rogue Trader tile lighting)"
	echo "  0023 = steamac: no __restrict on buffers sharing an argument buffer binding (the cast of a non-restrict"
	echo "         declaration dropped the member's qualifier and Metal rejected it: vkd3d-proton's raw SSBO heap,"
	echo "         Stellar Blade's compute pipelines)"
	echo "  0024 = steamac: access chains are not declared as potential loop temporaries (MSL declared descriptor"
	echo "         pointers loaded in a loop header, 'constant texture3d<float> _45;', which Metal rejects:"
	echo "         Stellar Blade's fragment pipelines, 'Out of video memory')"
	echo "  0025 = steamac: array/matrix user outputs of emulated geometry shaders are flattened into one mesh"
	echo "         vertex member per element (Metal: 'invalid type for mesh vertex type'; Stellar Blade's cube"
	echo "         map GS), copied into the vertex at every EmitVertex"
	echo "  0026 = steamac: a copy (OpCopyObject) of an access chain is the same lvalue: MSL dereferenced it"
	echo "         ('*_117[_192] = ...', Stellar Blade's compute pipelines) and stores through it did not count"
	echo "         as writes (a constant-initialized array became a const lookup table)"
	echo "  0027 = steamac: runtime arrays of descriptors without rich descriptors (MoltenVK's layout): the set"
	echo "         becomes a device argument buffer, buffer lengths come from the size buffer per element; a"
	echo "         runtime binding declared as a sized array in the shader uses the shader's size"
	echo "  0031 = steamac: propagate manual helper-invocation state for empty discard blocks in fragment"
	echo "         helpers (STEAMAC-1Q), including nested callers; check terminators outside the instruction loop"
	echo "  0032 = steamac: rename user-defined log10 helpers, which clash with metal::log10(float)"
	echo "         (STEAMAC-1R, compute ACES spline); preserve the helper implementation and callsites"
	echo "  0033 = steamac: fragment outputs of another numeric type than their color attachment are declared with"
	echo "         the attachment's type and bit cast (Metal: 'output of type uint4 is not compatible with a"
	echo "         MTLPixelFormatR32Sint color attachment', STEAMAC-2C)"
	echo "  0034 = steamac: location inputs of plain vertex shaders without an msl_shader_input (no vertex attribute)"
	echo "         become zero-initialized locals instead of stage_in members (option zero_missing_vertex_attributes)"
	echo "  0035 = steamac: integer location inputs read through a float vertex format (MoltenVK 0037)"
	echo "  0036 = steamac: robust sampling through a dynamic image sampler (immutable YCbCr conversion passed to a"
	echo "         helper) tests its primary plane for null (was 'no matching function is_null_texture', STEAMAC-3W)"
	echo "  0042 = steamac: flattened/component-packed captured stage I/O locals and extracted helper"
	echo "         references stay in thread address space instead of invalid device pointer casts (STEAMAC-33)"
	echo "  0043 = steamac: dynamically indexed CullDistance arrays remain local and copy scalar user(cullN)"
	echo "         outputs at return/each geometry emission, preserving captured buffer arrays (STEAMAC-6E/66)"
	echo "  0044 = steamac: raw buffer-device-address atomic operands retain their pointer value instead of"
	echo "         taking the address of a temporary pointer; emulated image lvalues still take addresses (STEAMAC-6D)"
	echo "  0045 = steamac: full-width Vulkan specialization IDs map to unused Metal uint16 function-constant"
	echo "         indices while duplicate SpecIds retain separate defaults (STEAMAC-6A; MoltenVK 0044)"
	echo "  0046 = steamac: input builtin aliases share one synthesized prologue declaration as well as one"
	echo "         entry parameter (STEAMAC-5M: duplicate gl_PrimitiveID in tessellation)"
	echo "  0047 = steamac: multisampled image mip-count queries return one (zero for null descriptors),"
	echo "         without calling Metal texture2d_ms.get_num_mip_levels (STEAMAC-5K)"
	echo "  0048 = steamac: helper aliases of SampleMask use Metal scalar uint ABI, with read-only inputs"
	echo "         passed by value for masked expressions (STEAMAC-2N)"
	echo "  0049 = steamac: subgroup memory fences use Metal thread_scope_simdgroup (not SPIR-V"
	echo "         thread_scope_subgroup), fixing MSL 3.2 shader compilation (STEAMAC-5C)"
	echo "  0050 = steamac: pull-model interpolation retains component swizzles and interface members through"
	echo "         pointer copies and split access chains (STEAMAC-6V: float initialized from float4 centroid result)"
	echo "  0051 = steamac: component-packed fragment outputs use both Location and Index, preserving"
	echo "         source 1 and distinct fixups (STEAMAC-75); four validated shaders render expected blend pixels"
	echo
	echo "Geometry shader emulation limits: no GS instancing (Invocations > 1); B8G8R8A8 and packed"
	echo "  (2_10_10_10, 11_11_10) vertex formats are not swizzled/unpacked by the object stage; vertex outputs are"
	echo "  limited to 32 locations, 8 clip and 8 cull distances; indirect GS draws are converted on"
	echo "  the GPU but drawCount comes from the CPU (no vkCmdDrawIndirectCount with GS)."
	echo "Transform feedback limits: captured only by geometry shaders (vertex/tess. eval. capture fails"
	echo "  pipeline creation), vertex stream 0 (queries of other streams count 0), no"
	echo "  vkCmdDrawIndirectByteCountEXT, indirect draws with a capturing GS capture nothing (logged) and add"
	echo "  nothing to queries; a primitive that does not fit drops every primitive of its GS invocation; each"
	echo "  capturing draw ends/restarts the Metal render pass for its ordering pass."
	echo
	echo "Not included: KhronosGroup/MoltenVK PR #2812 (indexed/indirect GS mesh draws). It is part of"
	echo "  a different geometry-shader implementation (stacked on PR #2786, rebase of #1815/#1943 with"
	echo "  its own SPIRV-Cross fork) and does not apply to the utmapp geometry-shaders branch;"
	echo "  steamac patch 0008 implements indirect GS draws for this branch instead."
	echo
	echo "Build: ./fetchDependencies --macos --spirv-cross-root <patched SPIRV-Cross>;"
	echo "  make macos; lipo -thin arm64 (UTM's recipe)."
	echo "Metal private API: OFF (MVK_USE_METAL_PRIVATE_API not set, like UTM/Homebrew), so logicOp,"
	echo "  wideLines, primitive-restart control and provoking-vertex-last are unavailable. Enabling it"
	echo "  fails to compile on this fork: the geometry-shader mesh pipeline path sets"
	echo "  logicOperationEnabledMVK/logicOperationMVK/sampleMaskMVK on MTLMeshRenderPipelineDescriptor,"
	echo "  which MoltenVK's private-API category only declares for MTLRenderPipelineDescriptor."
	echo
	echo "Probe (host/moltenvk/probe, $(sysctl -n machdep.cpu.brand_string), macOS $(sw_vers -productVersion)):"
	sed 's/^/  /' "$probe_log"
	echo
	echo "Repros (host/moltenvk/repro, Metal argument buffers on):"
	grep -v '^\[mvk-info\]\|^	' "$repro_log" | sed 's/^/  /'
} > "$out/MOLTENVK.txt"

echo ">> $lib"
otool -L "$lib"
