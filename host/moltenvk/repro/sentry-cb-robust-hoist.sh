#!/bin/sh
# STEAMAC-CB/CF: a robustBufferAccess2 load in a loop whose value is used after the loop.
# SPIRV-Cross 0065 must zero the hoisted temporary where it is assigned: the bounds check
# re-applied at each use named a temporary of the loop (`use of undeclared identifier` in Metal).
# Usage: sh sentry-cb-robust-hoist.sh <spirv-cross CLI> [output directory]
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
spvc=${1:?SPIRV-Cross CLI required}
work=${2:-"$here/../../../work/scratch/sentry-cb-robust-hoist"}
mkdir -p "$work"
spirv-as --target-env vulkan1.1 "$here/shaders/sentry-cb-robust-hoist.comp.spvasm" -o "$work/cb.spv"
spirv-val --target-env vulkan1.1 "$work/cb.spv"
for version in 20400 30000; do
    case "$version" in 20400) std=macos-metal2.4 ;; 30000) std=metal3.0 ;; esac
    for robust in robust plain; do
        flag=; [ "$robust" = robust ] && flag=--msl-robust-buffer-access2
        out="$work/cb-$robust-$version"
        # shellcheck disable=SC2086
        "$spvc" "$work/cb.spv" --msl --msl-version "$version" $flag --output "$out.metal"
        xcrun -sdk macosx metal "-std=$std" -c "$out.metal" -o "$out.air"
    done
done
xcrun clang -fobjc-arc -framework Foundation -framework Metal "$here/sentry_cb_robust_hoist.m" -o "$work/runtime"
"$work/runtime" "$work/cb-robust-30000.metal" robust
"$work/runtime" "$work/cb-plain-30000.metal" plain
printf '%s\n' 'PASS: CB/CF robust loads used after their loop compile and read zero out of bounds'
