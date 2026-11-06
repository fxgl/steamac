#!/bin/sh
# STEAMAC-G 949d5c67: reproduce Metal's 256-level bracket limit through KK.
# Usage: host/moltenvk/repro/sentry-g-brackets.sh <libvulkan_kosmickrisp.dylib>
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../../.." && pwd)
work=${REPRO_WORK:-$root/work/build/host-kosmickrisp/repro-brackets}
kk=${1:?usage: $0 <libvulkan_kosmickrisp.dylib>}
case $kk in /*) ;; *) kk=$PWD/$kk ;; esac
mkdir -p "$work"
loader=$(brew --prefix vulkan-loader)/lib
inc=$root/work/build/host-moltenvk/src/Package/Release/MoltenVK/include
xcrun clang -std=c11 -Wall -Werror -O1 -I"$inc" "$here/sentry-g-brackets.c" \
	-L"$loader" -lvulkan -Wl,-rpath,"$loader" -o "$work/sentry-g-brackets"
printf '{"file_format_version":"1.0.1","ICD":{"library_path":"%s","api_version":"1.4.0"}}\n' \
	"$kk" > "$work/kosmickrisp_icd.json"
export VK_DRIVER_FILES="$work/kosmickrisp_icd.json"
unset VK_ICD_FILENAMES
export MTL_DEBUG_LAYER=1 MTL_DEBUG_LAYER_ERROR_MODE=assert MESA_SHADER_CACHE_DISABLE=true
for mode in ${REPRO_BRACKET_MODES:-ladder nested jumps alu}; do
	python3 "$here/sentry_g_brackets.py" "$work/$mode.comp" "$mode"
	glslangValidator -V --target-env vulkan1.3 --quiet "$work/$mode.comp" -o "$work/$mode.spv"
	spirv-val --target-env vulkan1.3 "$work/$mode.spv"
	"$work/sentry-g-brackets" "$work/$mode.spv" "$mode"
done
