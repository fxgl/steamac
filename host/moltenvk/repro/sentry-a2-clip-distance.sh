#!/bin/sh
# STEAMAC-A2: standalone and gl_PerVertex ClipDistance must match fragment user(clipN).
# Usage: sh host/moltenvk/repro/sentry-a2-clip-distance.sh <spirv-cross CLI> [output directory]
# Only consumes a prebuilt translator; never builds MoltenVK or SPIRV-Cross.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
spvc=${1:?SPIRV-Cross CLI required}
work=${2:-"$here/../../../work/scratch/Mvk6.ClipMesh/regression"}
mkdir -p "$work"
xcrun clang -fobjc-arc -framework Foundation -framework Metal \
    "$here/sentry_a2_clip_distance.m" -o "$work/link"
for count in 1 2; do
    for shape in plain block; do
        for users in 1 0; do
            name="$count-$shape-$users"
            for stage in vert geom frag; do
                if [ "$stage" = geom ] && [ "$shape" = plain ]; then
                    python3 "$here/sentry_a2_clip_distance.py" prepare \
                        "$here/shaders/sentry-a2-clip-plain.geom.spvasm.in" "$count" "$work/$name.geom.spvasm"
                    spirv-as --target-env vulkan1.1 "$work/$name.geom.spvasm" -o "$work/$name.geom.spv"
                else
                    case "$stage" in
                        vert) define=VERTEX ;;
                        geom) define=GEOMETRY ;;
                        frag) define=FRAGMENT ;;
                    esac
                    glslangValidator -V --target-env vulkan1.1 -S "$stage" \
                        -D"$define"=1 -DCLIP_COUNT="$count" -DUSER_COPY="$users" \
                        "$here/shaders/sentry-a2-clip-distance.glsl" -o "$work/$name.$stage.spv"
                fi
                spirv-val --target-env vulkan1.1 "$work/$name.$stage.spv"
                set --
                if [ "$stage" != frag ]; then set -- --msl-for-mesh-pipeline; fi
                if [ "$users" = 0 ]; then set -- "$@" --msl-no-clip-distance-user-varying; fi
                "$spvc" "$work/$name.$stage.spv" --msl --msl-version 30000 \
                    "$@" --output "$work/$name.$stage.metal"
            done
            # Before 0060, mesh user(clip0) is absent: Metal rejects the link
            # (M1 Max reports a compiler-service interruption for this mismatch).
            "$work/link" "$work/$name.vert.metal" "$work/$name.geom.metal" "$work/$name.frag.metal"
            python3 "$here/sentry_a2_clip_distance.py" check \
                "$work/$name.geom.metal" "$work/$name.frag.metal" "$count" "$users"
        done
    done
done
printf '%s\n' 'PASS: A2 plain/block mesh ClipDistance, one/two planes, native-only and user-copy paths'
