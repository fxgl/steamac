#!/bin/sh
# STEAMAC-75: valid dual-source shaders with plain/component-packed outputs.
# Usage: sh host/moltenvk/repro/sentry-75-dual-source.sh <spirv-cross CLI> [output directory]
# Uses a prebuilt translator; never builds or installs a shared Vulkan driver.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
spvc=${1:?SPIRV-Cross CLI required}
work=${2:-"$here/../../../work/scratch/Mvk-dual-source/regression"}
mkdir -p "$work"
xcrun clang -fobjc-arc -framework Foundation -framework Metal \
    "$here/sentry_75_dual_source.m" -o "$work/dual-source"
for primary in 0 1; do
    for secondary in 0 1; do
        name="dual-source-$primary-$secondary"
        glslangValidator -V --target-env vulkan1.1 \
            -DPRIMARY_PACKED="$primary" -DSECONDARY_PACKED="$secondary" \
            "$here/shaders/sentry-75-dual-source.frag" -o "$work/$name.spv"
        spirv-val --target-env vulkan1.1 "$work/$name.spv"
        "$spvc" "$work/$name.spv" --msl --msl-version 30000 --output "$work/$name.metal"
        "$work/dual-source" "$work/$name.metal"
    done
done
printf '%s\n' 'PASS: primary/secondary plain and packed dual-source combinations'
