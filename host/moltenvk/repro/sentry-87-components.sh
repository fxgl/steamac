#!/bin/sh
# STEAMAC-87/BB: a sparse width-link map must not merge unrelated component names.
# Plain float2+float2, interface-block float2+float2, and plain float3+float share
# location 2 while location 0 alternates matching and mismatching vector widths.
# Reuse stage_widths.c's pixel readback and serialized-cache reversal harness.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../../.." && pwd)
libdir=${1:?usage: sentry-87-components.sh absolute-libdir [absolute-output-dir]}
work=${2:-$root/work/scratch/sentry-87-components}
inc=${VULKAN_INCLUDE:-$root/work/build/host-moltenvk/src/Package/Release/MoltenVK/include}
mkdir -p "$work/spv"
for mode in 0 1 2; do
    for producer in 3 4; do
        glslangValidator -V --quiet --target-env vulkan1.3 -DWIDTH="$producer" -DMODE="$mode" \
            "$here/shaders/stage_widths/split.vert" -o "$work/spv/p$producer-t0-m$mode-c0.vert.spv"
        spirv-val --target-env vulkan1.3 "$work/spv/p$producer-t0-m$mode-c0.vert.spv"
        for consumer in 3 4; do
            glslangValidator -V --quiet --target-env vulkan1.3 \
                -DWIDTH="$consumer" -DPWIDTH="$producer" -DMODE="$mode" \
                "$here/shaders/stage_widths/split.frag" \
                -o "$work/spv/p$producer-q$consumer-t0-m$mode-c0.frag.spv"
            spirv-val --target-env vulkan1.3 "$work/spv/p$producer-q$consumer-t0-m$mode-c0.frag.spv"
        done
    done
done
xcrun clang -std=c11 -Wall -Werror -O1 -I"$inc" "$here/stage_widths.c" \
    -L"$libdir" -lMoltenVK -Wl,-rpath,"$libdir" -o "$work/sentry-87-components"
export MTL_DEBUG_LAYER=1 MTL_DEBUG_LAYER_ERROR_MODE=assert MVK_CONFIG_LOG_LEVEL=1
"$work/sentry-87-components" "$work/spv" --split-components
