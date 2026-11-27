# Capture and replay a KosmicKrisp pipeline

[Fossilize](https://github.com/ValveSoftware/Fossilize) records Vulkan pipeline creation inputs in a
`.foz` archive, including shader modules, layouts, and specialization constants. Replay can select a
single pipeline by hash, which lets you retry a compiler failure or compare driver builds without
launching the application each time. The target driver must support the captured pipeline's Vulkan
features.

A [Vulkan pipeline cache](https://docs.vulkan.org/refpages/latest/refpages/source/vkGetPipelineCacheData.html)
holds opaque driver data that can speed up later pipeline creation on a compatible driver. The
existing [NIR cache repro](../moltenvk/repro/nir_cache.c) tests reading and reloading that data.
Fossilize gives the driver the creation inputs again and can export a fresh cache. For bugs that
depend on draw calls, resource contents, or submission order, use a command capture tool such as
[GFXReconstruct](https://github.com/LunarG/gfxreconstruct).

## Build the capture tools

Use an Apple silicon Mac with the Xcode toolchain, CMake, Ninja, and a completed
`host/kosmickrisp/build.sh` build. Run the following blocks from the repository root in one shell.

```sh
mkdir -p work
w=$(mktemp -d "$PWD/work/fossilize.XXXXXX")
git init -q "$w/src"
git -C "$w/src" remote add origin https://github.com/ValveSoftware/Fossilize.git
git -C "$w/src" fetch --depth 1 origin 556da9ff7d7616704dda515756219ab1dab693ec
git -C "$w/src" checkout --detach FETCH_HEAD
git -C "$w/src" submodule update --init --recursive --depth 1
```

At this revision the build includes a helper that needs Linux headers on macOS, although the macOS
CLI already disables its multi-process replay mode. Exclude the helper in the local Fossilize checkout.

```sh
git -C "$w/src" apply <<'PATCH'
diff --git a/CMakeLists.txt b/CMakeLists.txt
--- a/CMakeLists.txt
+++ b/CMakeLists.txt
@@ -78,3 +78,3 @@
-if (NOT ANDROID)
+if (NOT ANDROID AND NOT APPLE)
     target_sources(fossilize PRIVATE fossilize_external_replayer.cpp fossilize_external_replayer.hpp)
 endif()
PATCH
cmake -S "$w/src" -B "$w/build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DFOSSILIZE_TESTS=OFF -DFOSSILIZE_REPLAYER_SPIRV_VAL=OFF
cmake --build "$w/build" --target VkLayer_fossilize fossilize-replay fossilize-list fossilize-convert-db
```

## Capture, inspect, and replay

Capture the synthetic shader in the NIR cache repro. The layer is enabled for this invocation only.
The repro should print `dispatch readback 42`.

```sh
icd="$PWD/work/build/host-kosmickrisp/stage/kosmickrisp_icd.json"
loader="$(brew --prefix vulkan-loader)/lib"
repro=host/moltenvk/repro
glslangValidator -V --quiet "$repro/shaders/nir_cache.comp" -o "$w/nir_cache.spv"
xcrun clang -std=c11 -O2 -I"$(brew --prefix vulkan-headers)/include" \
  "$repro/nir_cache.c" -L"$loader" -lvulkan -Wl,-rpath,"$loader" -o "$w/nir_cache"
VK_DRIVER_FILES="$icd" VK_ADD_IMPLICIT_LAYER_PATH="$w/build/layer" \
  FOSSILIZE=1 FOSSILIZE_DUMP_PATH="$w/nir-cache" MESA_SHADER_CACHE_DISABLE=true \
  "$w/nir_cache" "$w/nir_cache.spv" 0

cli="$w/build/cli"
foz=$(find "$w" -maxdepth 1 -name 'nir-cache.*.foz' -print)
hash=$("$cli/fossilize-list" "$foz" --tag 7)
mkdir -p "$w/inspect"
"$cli/fossilize-convert-db" "$foz" "$w/inspect"
```

The list command returns one compute pipeline hash for this archive. The decoded JSON shows the
pipeline and the shader and layout hashes it refers to. Run the command below twice with the
same cache path to check the round trip. Both runs should report one compute pipeline. The first
run should report one cache miss and the second one cache hit.

```sh
DYLD_LIBRARY_PATH="$loader" VK_DRIVER_FILES="$icd" MESA_SHADER_CACHE_DISABLE=true \
  "$cli/fossilize-replay" --num-threads 1 --pipeline-hash "$hash" \
  --on-disk-pipeline-cache "$w/cache.bin" "$foz"
```

Keep the archive, decoded objects, and cache under `work/`. For larger captures, start with a single
hash or a small pipeline range. Cache export allocates a buffer equal to the reported cache size.
When investigating cache growth such as [issue #107](https://github.com/fxgl/steamac/issues/107),
measure the size query independently and bound the buffer before timing the copy. Replay recreates
pipeline objects. Measuring GPU work or deferred compilation also requires exercising the pipeline.

For a game running in the VM, capture at the Vulkan loader inside the SteamOS guest. This guide's
native repro verifies the capture and replay loop on the Mac. Record timings alongside a game
capture. The archive stores creation inputs, and `MESA_KK_DEBUG=compiles` logs Metal compiler
timings on the host.
