#!/bin/sh
# STEAMAC-AS: reconstructed shared float operations, native device control, GPU semantics.
# Usage: sh sentry-as-shared-float.sh <spirv-cross CLI> [output directory]
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
spvc=${1:?SPIRV-Cross CLI required}
work=${2:-"$here/../../../work/scratch/Mvk8/shared-float"}
mkdir -p "$work"
spirv-as --target-env vulkan1.1 "$here/shaders/sentry-as-shared-float.comp.spvasm" -o "$work/shared.spv"
spirv-val --target-env vulkan1.1 "$work/shared.spv"
glslangValidator -V --target-env vulkan1.1 "$here/shaders/sentry-as-device-float.comp" -o "$work/device.spv"
spirv-val --target-env vulkan1.1 "$work/device.spv"
for version in 20400 30000 40000; do
    case "$version" in 20400) std=macos-metal2.4 ;; 30000) std=metal3.0 ;; 40000) std=metal4.0 ;; esac
    "$spvc" "$work/shared.spv" --msl --msl-version "$version" --output "$work/shared-$version.metal"
    xcrun -sdk macosx metal "-std=$std" -c "$work/shared-$version.metal" -o "$work/shared-$version.air"
    if grep -q 'threadgroup atomic_float' "$work/shared-$version.metal"; then exit 1; fi
    "$spvc" "$work/device.spv" --msl --msl-version "$version" --output "$work/device-$version.metal"
    grep -q 'device atomic_float' "$work/device-$version.metal"
    # Native float device fetch_add is an MSL 3 operation, unchanged by this fix.
    if [ "$version" != 20400 ]; then
        xcrun -sdk macosx metal "-std=$std" -c "$work/device-$version.metal" -o "$work/device-$version.air"
    fi
done
xcrun clang -fobjc-arc -framework Foundation -framework Metal "$here/sentry_as_shared_float.m" -o "$work/runtime"
"$work/runtime" "$work/shared-30000.metal"
printf '%s\n' 'PASS: AS shared float atomics in MSL 2.4/3/4; device atomics retained'
