#!/bin/sh
# Diagnostic coverage only: no claim to reproduce STEAMAC-7Q/7R's AGX crashes.
set -eu
[ "${REPRO_DRIVER:-kosmickrisp}" = kosmickrisp ] || exit 2
here=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../../.." && pwd)
kk=${1:?usage: REPRO_DRIVER=kosmickrisp metal-diagnostics.sh <dylib>}
case $kk in /*) ;; *) kk=$PWD/$kk ;; esac
work=$(mktemp -d "${TMPDIR:-/tmp}/kk-metal-diagnostics.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
inc=$root/work/build/host-moltenvk/src/Package/Release/MoltenVK/include
loader=$(brew --prefix vulkan-loader)/lib
xcrun clang -std=c11 -Wall -Werror -O1 -I"$inc" "$here/metal_diagnostics.c" \
	-L"$loader" -lvulkan -Wl,-rpath,"$loader" -o "$work/metal_diagnostics"
printf '{"file_format_version":"1.0.1","ICD":{"library_path":"%s","api_version":"1.4.0"}}\n' "$kk" > "$work/icd.json"
export VK_DRIVER_FILES=$work/icd.json MTL_DEBUG_LAYER=1 MTL_DEBUG_LAYER_ERROR_MODE=assert
unset VK_ICD_FILENAMES MESA_KK_DEBUG
"$work/metal_diagnostics" > "$work/bounded.log" 2>&1 || { cat "$work/bounded.log"; exit 1; }
# An M1 previously logged neither render descriptors nor counter resolves.
renders=$(grep -c '^kk: encoder render shape=.* cmd=' "$work/bounded.log" || true)
resolves=$(grep -c '^kk: counter resolve thread=' "$work/bounded.log" || true)
ready=$(grep -c '^kk: counter resolve ready thread=' "$work/bounded.log" || true)
notes=$(grep -c '^kk: counter resolve: 64 logged' "$work/bounded.log" || true)
if [ "$renders" -lt 1 ] || [ "$resolves" != 64 ] || [ "$ready" != 64 ] || [ "$notes" != 1 ] ||
	! grep -q '^kk: encoder render memory allocated=.* recommended=' "$work/bounded.log" ||
	grep -q ' invalid=1$' "$work/bounded.log"; then
	cat "$work/bounded.log"
	echo "FAIL metal_diagnostics: render=$renders resolve=$resolves ready=$ready notes=$notes"
	exit 1
fi
MESA_KK_DEBUG=cbs "$work/metal_diagnostics" > "$work/full.log" 2>&1 || { cat "$work/full.log"; exit 1; }
full=$(grep -c '^kk: counter resolve thread=' "$work/full.log" || true)
full_ready=$(grep -c '^kk: counter resolve ready thread=' "$work/full.log" || true)
if [ "$full" -le 64 ] || [ "$full" != "$full_ready" ] || grep -q ' invalid=1$' "$work/full.log"; then
	cat "$work/full.log"
	echo "FAIL metal_diagnostics: full resolve=$full ready=$full_ready"
	exit 1
fi
if [ -n "${METAL_DIAGNOSTICS_LOG_DIR:-}" ]; then
	mkdir -p "$METAL_DIAGNOSTICS_LOG_DIR"
	cp "$work/bounded.log" "$work/full.log" "$METAL_DIAGNOSTICS_LOG_DIR/"
fi
echo "OK metal_diagnostics: bounded $resolves/$ready with $notes cap note; cbs $full/$full_ready; render descriptors and memory logged"
