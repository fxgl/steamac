#!/bin/sh
# STEAMAC-87/88/2M candidate: block members must keep SPIR-V Location/Component.
# Usage: sh host/moltenvk/repro/sentry-block-locations.sh <spirv-cross CLI> [output directory]
# Uses only a prebuilt private translator and the Metal toolchain, never a driver build.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
spvc=${1:?SPIRV-Cross CLI required}
work=${2:-"$here/../../../work/scratch/SpvcLocations/regression"}
mkdir -p "$work"
xcrun clang -fobjc-arc -framework Foundation -framework Metal \
    "$here/sentry_block_locations.m" -o "$work/link"
for shape in 0 1 2 3; do
    for block in 0 1; do
        for stage in vert frag; do
            vertex=0
            storage=Input
            if [ "$stage" = vert ]; then vertex=1; storage=Output; fi
            name="$shape-$block-$stage"
            glslangValidator -V --target-env vulkan1.1 -S "$stage" \
                -DVERTEX="$vertex" -DBLOCK="$block" -DSHAPE="$shape" \
                "$here/shaders/sentry-block-locations.glsl" -o "$work/$name.spv"
            spirv-val --target-env vulkan1.1 "$work/$name.spv"
            "$spvc" "$work/$name.spv" --msl --msl-version 30000 --output "$work/$name.metal"
            python3 "$here/sentry_block_locations.py" "$work/$name.spv" "$work/$name.metal" "$storage"
            xcrun -sdk macosx metal -std=metal3.0 -c "$work/$name.metal" -o "$work/$name.air"
            xcrun -sdk macosx metallib "$work/$name.air" -o "$work/$name.metallib"
        done
    done
    # Testing only block/block could hide the bug by renumbering both stages alike.
    for vertex_block in 0 1; do
        for fragment_block in 0 1; do
            "$work/link" "$work/$shape-$vertex_block-vert.metallib" "$work/$shape-$fragment_block-frag.metallib"
        done
    done
done
printf '%s\n' 'PASS: block gaps, arrays, matrices, components, and reordered locations'
