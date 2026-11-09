#!/bin/sh
# STEAMAC-AD: synthetic failure-log byte/line boundaries, not a Bodycam shader replay.
# Usage: sh host/moltenvk/repro/sentry-ad-capture.sh <MoltenVK library directory> [output directory] [Vulkan include directory]
# Requires an already-built driver; never builds or installs MoltenVK.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../../.." && pwd)
libdir=$(CDPATH= cd -- "${1:?MoltenVK library directory required}" && pwd)
work=${2:-"$root/work/scratch/Mvk6.CompilerAD/capture-regression"}
inc=${3:-"$root/work/build/host-moltenvk/src/Package/Release/MoltenVK/include"}
mkdir -p "$work"
xcrun clang -std=c11 -Wall -Werror -I"$inc" "$here/sentry_ad_capture.c" \
    -L"$libdir" -lMoltenVK -Wl,-rpath,"$libdir" -o "$work/capture"
export MVK_CONFIG_LOG_LEVEL=1
python3 "$here/sentry_ad_capture.py" "$work/capture" "$work"
