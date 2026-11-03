#!/bin/sh
# Focused STEAMAC-G diagnostics regression; no VM and no deliberate GPU hang.
# REPRO_DRIVER=kosmickrisp sh host/moltenvk/repro/gpu-diagnostics.sh <dylib> [patched Mesa source]
# Checks raw-clock classification and bounded dispatch records, then exercises real
# direct/indirect submissions and the existing runtime device-loss reporting path.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../../.." && pwd)
[ "${REPRO_DRIVER:-}" = kosmickrisp ] || { echo 'REPRO_DRIVER=kosmickrisp is required' >&2; exit 2; }
kk=${1:?usage: gpu-diagnostics.sh <dylib> [patched Mesa source]}
case $kk in /*) ;; *) kk=$PWD/$kk ;; esac
src=${2:-$root/work/build/host-kosmickrisp/src}
work=$(mktemp -d "${TMPDIR:-/tmp}/steamac-gpu-diagnostics.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
xcrun clang -std=c11 -Wall -Wextra -Werror "$src/src/kosmickrisp/vulkan/tests/steamac_gpu_diagnostics.c" -o "$work/records"
"$work/records"
echo 'OK   GPU timestamp classification and bounded dispatch records'
loader=$(brew --prefix vulkan-loader)/lib
inc=$root/work/build/host-moltenvk/src/Package/Release/MoltenVK/include
printf '{"file_format_version":"1.0.1","ICD":{"library_path":"%s","api_version":"1.4.0"}}\n' "$kk" > "$work/icd.json"
export VK_DRIVER_FILES="$work/icd.json"
unset VK_ICD_FILENAMES
export MTL_DEBUG_LAYER=1 MTL_DEBUG_LAYER_ERROR_MODE=assert
mkdir "$work/spv"
for shader in "$here"/shaders/wgsize/*.spvasm; do
    spirv-as --target-env vulkan1.3 "$shader" -o "$work/spv/$(basename "$shader" .spvasm).spv"
done
for program in wgsize device_lost; do
    xcrun clang -std=c11 -Wall -Werror -O1 -I"$inc" "$here/$program.c" -L"$loader" -lvulkan -Wl,-rpath,"$loader" -o "$work/$program"
done
"$work/wgsize" "$work/spv"
"$work/device_lost"
