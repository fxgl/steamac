#!/bin/sh
# STEAMAC-41/R: replay captured MSL with the payload struct emitted by SPIRV-Cross.
# Usage: sh host/moltenvk/repro/sentry-mesh-payload.sh <spirv-cross CLI> [output directory]
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
spvc=${1:?SPIRV-Cross CLI required}
work=${2:-"$here/../../../work/scratch/Mvk3/payload-regression"}
mkdir -p "$work"
glslangValidator -V --quiet "$here/shaders/sentry-41-payload.vert" -o "$work/payload.spv"
spirv-val "$work/payload.spv"
"$spvc" "$work/payload.spv" --msl --msl-version 30000 --msl-for-mesh-pipeline --output "$work/payload.metal"
python3 "$here/sentry_mesh_payload.py" "$work/payload.metal" "$here/shaders" "$work"
xcrun clang -fobjc-arc -framework Foundation -framework Metal "$here/sentry_mesh_payload.m" -o "$work/replay"
"$work/replay" "$work/object.metal" "$work/mesh.metal" "$work/fragment.metal"
