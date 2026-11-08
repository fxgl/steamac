#!/bin/bash
# Proton 7's flat DXVK layout and both Wine unixlib layouts.
set -eu
S=$(cd "$(dirname "$0")/../.." && pwd)/guest/layer/usr/lib/steamac/steam-gfx-path
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export STEAMAC_STEAM_ROOT="$T/steam" STEAMAC_DXMT_DIR="$T/payload" STEAMAC_GFX_STATE="$T/state" STEAMAC_CMDLINE="$T/cmdline" STEAMAC_COMPAT_DEFAULT=/usr/bin/true
mkdir -p "$STEAMAC_DXMT_DIR/"{x86_64-windows,x86_64-unix}
for f in d3d11 dxgi d3d10core winemetal; do head -c 300 /dev/zero | tr '\0' m > "$STEAMAC_DXMT_DIR/x86_64-windows/$f.dll"; done
printf unixlib > "$STEAMAC_DXMT_DIR/x86_64-unix/winemetal.so"
for layout in split flat; do
 P="$STEAMAC_STEAM_ROOT/steamapps/common/Proton-7-$layout"; W="$P/dist/lib64/wine"
 mkdir -p "$W/dxvk" "$W/x86_64-windows" "$P/dist/share/default_pfx/drive_c/windows/system32"
 if [[ $layout == split ]]; then U="$W/x86_64-unix"; mkdir -p "$U"; else U="$W"; touch "$W/ntdll.so"; fi
 for f in d3d11 dxgi d3d10core; do printf 'original-%s' "$f" > "$W/dxvk/$f.dll"; done
 echo 7 > "$P/version"
done
run() { printf '%s' "$1" > "$STEAMAC_CMDLINE"; bash "$S"; }
run steamac.gfx=dxmt
for layout in split flat; do
 W="$STEAMAC_STEAM_ROOT/steamapps/common/Proton-7-$layout/dist/lib64/wine"
 U="$W"; [[ $layout != split ]] || U="$W/x86_64-unix"
 cmp "$U/winemetal.so" "$STEAMAC_DXMT_DIR/x86_64-unix/winemetal.so"
 cmp "$W/../../share/default_pfx/drive_c/windows/system32/winemetal.dll" "$STEAMAC_DXMT_DIR/x86_64-windows/winemetal.dll"
 [[ $(head -c 64 "$W/dxvk/d3d11.dll" | tr -d m) == '' ]]
done
run steamac.gfx=dxmt
run steamac.gfx=vulkan
for layout in split flat; do
 W="$STEAMAC_STEAM_ROOT/steamapps/common/Proton-7-$layout/dist/lib64/wine"
 for f in d3d11 dxgi d3d10core; do [[ $(cat "$W/dxvk/$f.dll") == "original-$f" ]]; done
 [[ ! -e $W/winemetal.so && ! -e $W/x86_64-unix/winemetal.so ]]
 [[ ! -L $W/../../share/default_pfx/drive_c/windows/system32/winemetal.dll ]]
done
echo 'PASS: legacy DXVK installation, template links, repeat application and restoration'
