#!/bin/sh
# STEAMAC-8J: projected sample-rate inputs must link, without changing interpolation.
# Usage: sh sentry-8j-projected.sh <SPIRV-Cross source> <CMake build> [output directory]
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
src=${1:?SPIRV-Cross source required}
build=${2:?SPIRV-Cross build required}
work=${3:-"$here/../../../work/scratch/sentry-8j"}
mkdir -p "$work"
xcrun clang++ -std=c++14 -I"$src" "$here/sentry_msl_compile.cpp" \
    "$build/libspirv-cross-msl.a" "$build/libspirv-cross-glsl.a" "$build/libspirv-cross-core.a" -o "$work/compile"
xcrun clang -fobjc-arc -framework Foundation -framework Metal "$here/sentry_8j_projected.m" -o "$work/projected"
for shape in 0 1 2 3 4 5; do
    for read in 0 1; do
        name="projected-$shape-$read"
        glslangValidator -V --target-env vulkan1.1 -DSHAPE="$shape" -DREAD_INTERPOLANT="$read" \
            "$here/shaders/sentry-8j-projected.frag" -o "$work/$name.spv"
        spirv-val --target-env vulkan1.1 "$work/$name.spv"
        "$work/compile" "$work/$name.spv" "$work/$name.metal" 30000 sample-offset
    done
    "$work/projected" "$work/projected-$shape-0.metal"
    "$work/compile" "$work/projected-$shape-1.spv" "$work/reference-$shape.metal" 30000
    "$work/projected" "$work/projected-$shape-1.metal" "$work/reference-$shape.metal"
done
printf '%s\n' 'PASS: sample-position interpolation avoids projected sampling fusion and matches native per-sample values'
