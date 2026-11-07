#!/bin/sh
# Standalone Vulkan pixels + cache regression for the STEAMAC-2M/88 width accommodation.
# Usage after integrating into host/moltenvk/repro:
#   sh host/moltenvk/repro/stage-widths.sh <absolute-libdir> [absolute-output-dir]
# Optional VULKAN_INCLUDE overrides the built MoltenVK headers.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../../.." && pwd)
libdir=${1:?usage: stage-widths.sh absolute-libdir [absolute-output-dir]}
work=${2:-$root/work/scratch/stage-widths-repro}
inc=${VULKAN_INCLUDE:-$root/work/build/host-moltenvk/src/Package/Release/MoltenVK/include}
mkdir -p "$work/spv"

compile_pair() {
    producer=$1 consumer=$2 kind=$3 mode=$4 component=$5
    glslangValidator -V --quiet --target-env vulkan1.3 \
        -DWIDTH="$consumer" -DPWIDTH="$producer" -DKIND="$kind" -DMODE="$mode" -DCOMPONENT="$component" \
        "$here/shaders/stage_widths/width.frag" \
        -o "$work/spv/p$producer-q$consumer-t$kind-m$mode-c$component.frag.spv"
}

# Every producer in this matrix is compiled once this invocation, including on a rerun.
for kind in 0 1 2; do
    for mode in 0 1 2; do
        for producer in 1 2 3 4; do
            glslangValidator -V --quiet --target-env vulkan1.3 \
                -DWIDTH="$producer" -DPWIDTH="$producer" -DKIND="$kind" -DMODE="$mode" -DCOMPONENT=0 \
                "$here/shaders/stage_widths/width.vert" \
                -o "$work/spv/p$producer-t$kind-m$mode-c0.vert.spv"
        done
        for pair in 3:3 3:4 3:2 4:3 4:4 2:4 1:3 2:3; do
            compile_pair "${pair%:*}" "${pair#*:}" "$kind" "$mode" 0
        done
    done
    for producer in 2 3; do
        glslangValidator -V --quiet --target-env vulkan1.3 \
            -DWIDTH="$producer" -DPWIDTH="$producer" -DKIND="$kind" -DMODE=0 -DCOMPONENT=1 \
            "$here/shaders/stage_widths/width.vert" -o "$work/spv/p$producer-t$kind-m0-c1.vert.spv"
    done
    compile_pair 2 3 "$kind" 0 1
    compile_pair 3 2 "$kind" 0 1
done
xcrun clang -std=c11 -Wall -Werror -O1 -I"$inc" "$here/stage_widths.c" \
    -L"$libdir" -lMoltenVK -Wl,-rpath,"$libdir" -o "$work/stage_widths"
export MTL_DEBUG_LAYER=1 MTL_DEBUG_LAYER_ERROR_MODE=assert MVK_CONFIG_LOG_LEVEL=1
"$work/stage_widths" "$work/spv"
