#!/bin/sh
# STEAMAC-AV: half2 array locations fetch independently, including mixed format conversion.
# Usage: sh sentry-av-array-input.sh <SPIRV-Cross source> <CMake build> [output directory]
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
src=${1:?SPIRV-Cross source required}
build=${2:?SPIRV-Cross build required}
work=${3:-"$here/../../../work/scratch/Mvk8/array-input"}
mkdir -p "$work"
xcrun clang++ -std=c++14 -I"$src" "$here/sentry_av_array_input.cpp" \
    "$build/libspirv-cross-msl.a" "$build/libspirv-cross-glsl.a" "$build/libspirv-cross-core.a" -o "$work/compile"
xcrun clang -fobjc-arc -framework Foundation -framework Metal "$here/sentry_av_array_input.m" -o "$work/runtime"
glslangValidator -V --target-env vulkan1.1 "$here/shaders/sentry-av-array-input.vert" -o "$work/array.spv"
spirv-val --target-env vulkan1.1 "$work/array.spv"
for format in 8 4 1 12; do
    "$work/compile" "$work/array.spv" "$work/array-$format.metal" "$format"
    "$work/runtime" "$work/array-$format.metal" "$format"
done
printf '%s\n' 'PASS: AV array vertex inputs, half/float/normalized/packed formats'
