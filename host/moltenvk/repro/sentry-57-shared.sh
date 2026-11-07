#!/bin/sh
# Usage: sh sentry-57-shared.sh <libMoltenVK.dylib> <spirv-cross CLI or -> <Vulkan include dir> <output dir>
# Run against baseline and fixed builds separately. The baseline must print the advertised
# 32768-byte Vulkan limit and fail pipeline creation for the 30976-byte std430 shader.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mvk=${1:?MoltenVK dylib required}
spvc=${2:?SPIRV-Cross CLI or - for Vulkan-only testing required}
include=${3:?Vulkan include directory required}
work=${4:?private output directory required}
mkdir -p "$work"
xcrun clang -std=c11 -Wall -Werror -O1 -I"$include" "$here/sentry_57_shared.c" \
    "$mvk" "-Wl,-rpath,$(dirname -- "$mvk")" -o "$work/shared"
if [ "$spvc" != - ]; then
    xcrun clang -fobjc-arc -framework Foundation -framework Metal "$here/sentry_57_shared.m" -o "$work/metal-layout"
fi
set --
for optimization in plain optimized; do
    for shape in 0 1 2; do
        case $shape in
            0) label=event ;;
            1) label=external ;;
            2) label=nested ;;
        esac
        for initialized in 0 1; do
            name="$label-$optimization-zero$initialized"
            if [ "$optimization" = optimized ]; then
                glslangValidator -V --target-env vulkan1.3 -Os -DSHAPE="$shape" -DZERO_INIT="$initialized" \
                    "$here/shaders/sentry-57-shared.comp" -o "$work/$name.spv"
            else
                glslangValidator -V --target-env vulkan1.3 -DSHAPE="$shape" -DZERO_INIT="$initialized" \
                    "$here/shaders/sentry-57-shared.comp" -o "$work/$name.spv"
            fi
            spirv-val --target-env vulkan1.3 "$work/$name.spv"
            if [ "$spvc" != - ]; then
                "$spvc" "$work/$name.spv" --msl --msl-version 30000 --output "$work/$name.metal"
            fi
            set -- "$@" "$work/$name.spv"
        done
    done
done
spirv-as --target-env vulkan1.1 "$here/shaders/sentry-57-variable-pointers.comp.spvasm" -o "$work/pointer.spv"
spirv-val --target-env vulkan1.1 "$work/pointer.spv"
if [ "$spvc" != - ]; then
    "$spvc" "$work/pointer.spv" --msl --msl-version 30000 --output "$work/pointer.metal"
fi
set -- "$@" --pointer "$work/pointer.spv"
"$work/shared" "$@"
if [ "$spvc" != - ]; then
    for shader do
        if [ "$shader" != --pointer ]; then "$work/metal-layout" "${shader%.spv}.metal"; fi
    done
fi
