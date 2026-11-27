#!/bin/sh
# STEAMAC-B6/B7/B8/B9: a storage-image write in a loop's continue block with robustImageAccess2.
# SPIRV-Cross 0064 must emit the continue block as structured code: the guarded write's
# `if (...) { ... }` was comma-joined into the for-loop increment (`expected ')'` in Metal).
# Usage: sh sentry-b6-continue.sh <spirv-cross CLI> [output directory]
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
spvc=${1:?SPIRV-Cross CLI required}
work=${2:-"$here/../../../work/scratch/sentry-b6-continue"}
mkdir -p "$work"
spirv-as --target-env vulkan1.1 "$here/shaders/sentry-b6-continue-write.comp.spvasm" -o "$work/b6.spv"
spirv-val --target-env vulkan1.1 "$work/b6.spv"
for version in 20400 30000; do
    case "$version" in 20400) std=macos-metal2.4 ;; 30000) std=metal3.0 ;; esac
    for robust in robust plain; do
        flag=; [ "$robust" = robust ] && flag=--msl-robust-image-access2
        out="$work/b6-$robust-$version"
        # shellcheck disable=SC2086
        "$spvc" "$work/b6.spv" --msl --msl-version "$version" $flag --output "$out.metal"
        if grep -q 'for (.*if (' "$out.metal"; then
            echo "FAIL $robust MSL $version: a scoped statement in the for-loop increment" >&2
            exit 1
        fi
        xcrun -sdk macosx metal "-std=$std" -c "$out.metal" -o "$out.air"
    done
done
xcrun clang -fobjc-arc -framework Foundation -framework Metal "$here/sentry_b6_continue.m" -o "$work/runtime"
"$work/runtime" "$work/b6-robust-30000.metal"
"$work/runtime" "$work/b6-plain-30000.metal"
printf '%s\n' 'PASS: B6 continue-block image writes compile with and without robustImageAccess2 and write 0-7'
