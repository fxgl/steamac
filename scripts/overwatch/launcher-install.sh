#!/bin/bash
# Install work/out/steamac-vm into the FX Steam Launcher app and restart it with Overwatch.
# Closes the game first (the launcher refuses to quit cleanly while it runs). Backs up the old binary.
set -u
T=$(dirname "$0")
A="/Applications/FX Steam Launcher.app"; exe="$A/Contents/MacOS/steamac-vm"; FW="$A/Contents/Frameworks"
NEW=$(cd "$(dirname "$0")/../.." && pwd)/work/out/steamac-vm
B=${OW_LOGS:-$HOME/overwatch-logs}/launcher-backups; mkdir -p "$B"
ENT="$B/entitlements.plist"
codesign -d --entitlements :- "$A" > "$ENT" 2>/dev/null
grep -q hypervisor "$ENT" || { echo "could not read the app's entitlements"; exit 1; }

$T/g 'P=$(pgrep -f "[r]eaper SteamLaunch AppId=2357570" | head -1); [ -n "$P" ] && kill $P; sleep 6; for p in $(pgrep -f "[S]:.steamapps.common.Overwatch.Overwatch.exe"); do kill -9 $p; done; true' </dev/null
osascript -e 'tell application "FX Steam Launcher" to quit'
for i in $(seq 1 60); do pgrep -f "^$exe" >/dev/null || break; sleep 2; done
pgrep -f "^$exe" >/dev/null && { echo "launcher did not quit"; exit 1; }

# MEM_MIB=<n>: VM memory for the next start (written while the launcher is closed, so it is not overwritten)
[ -n "${MEM_MIB:-}" ] && { defaults write es.fxgam.steamac memMiB -int "$MEM_MIB"; echo "memMiB=$(defaults read es.fxgam.steamac memMiB)"; }
cp "$exe" "$B/steamac-vm.$(date +%m%d-%H%M)"
cp "$NEW" "$exe"
WH=$(cd "$(dirname "$0")/../.." && pwd)/wmtr/build/libwmtr_host.dylib
[ "$WH" -nt "$FW/libwmtr_host.dylib" ] && { cp "$FW/libwmtr_host.dylib" "$B/libwmtr_host.$(date +%m%d-%H%M).dylib"; cp "$WH" "$FW/libwmtr_host.dylib"; echo "wmtr host updated"; }
while read -r rp; do install_name_tool -delete_rpath "$rp" "$exe" 2>/dev/null; done < <(otool -l "$exe" | awk '/cmd LC_RPATH/ {getline; getline; print $2}')
install_name_tool -add_rpath @executable_path/../Frameworks "$exe" 2>/dev/null
otool -L "$exe" | awk 'NR > 1 {print $1}' | grep "^@rpath/" | while read -r dep; do [ -e "$FW/${dep#@rpath/}" ] || echo "MISSING $dep"; done
codesign --force --sign - --entitlements "$ENT" "$A" 2>&1 | tail -1
codesign --verify --strict "$A" && echo "signature ok" || exit 1

open -a "FX Steam Launcher" --args --control-fifo $(cd "$(dirname "$0")" && pwd)/ctl.fifo
ok=0; for i in $(seq 1 72); do $T/g 'pgrep -x steam >/dev/null && test -f /tmp/.fx-progress-ready-1000' </dev/null 2>/dev/null && { ok=1; break; }; sleep 5; done
echo vm_ready=$ok; [ $ok = 1 ] || exit 1
sleep 10; $T/g 'steam -ifrunning -applaunch 2357570 >/dev/null 2>&1' </dev/null
for i in $(seq 1 60); do e=$($T/g 'P=$(pgrep -f "[S]:.steamapps.common.Overwatch.Overwatch.exe" | head -1); [ -n "$P" ] && tr "\0" "\n" < /proc/$P/environ | grep -E "^DXMT_" | tr "\n" " "' </dev/null 2>/dev/null); [ -n "$e" ] && { echo "game env: $e"; break; }; sleep 5; done
echo "autoCapture=$(defaults read es.fxgam.steamac autoCapture.2357570 2>/dev/null)"
