#!/bin/sh
# Opt-in visible window: exercise the same legacy-present/KK-Metal4 combination
# as the launcher with Apple's HUD enabled (STEAMAC-59/7K).
set -eu
[ "${REPRO_DRIVER:-kosmickrisp}" = kosmickrisp ] || exit 2
here=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../../.." && pwd)
kk=${1:?usage: REPRO_DRIVER=kosmickrisp metal-hud.sh <dylib>}
case $kk in /*) ;; *) kk=$PWD/$kk ;; esac
work=$(mktemp -d "${TMPDIR:-/tmp}/kk-metal-hud.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
inc=$root/work/build/host-moltenvk/src/Package/Release/MoltenVK/include
loader=$(brew --prefix vulkan-loader)/lib
xcrun clang -std=c11 -Wall -Werror -O1 -I"$inc" "$here/metal_hud.m" \
	-framework AppKit -framework QuartzCore -framework Metal \
	-L"$loader" -lvulkan -Wl,-rpath,"$loader" -o "$work/metal_hud"
printf '{"file_format_version":"1.0.1","ICD":{"library_path":"%s","api_version":"1.4.0"}}\n' "$kk" > "$work/icd.json"
export VK_DRIVER_FILES=$work/icd.json MTL_HUD_ENABLED=1 MTL_DEBUG_LAYER=1 MTL_DEBUG_LAYER_ERROR_MODE=assert
unset VK_ICD_FILENAMES MESA_KK_DEBUG
"$work/metal_hud"
