#!/bin/bash
# Close Overwatch, install the built DXMT DLLs into the VM payload (Proton copies via steamac-gfx-path), relaunch.
T=$(dirname "$0"); G=$T/g; B=$(cd "$(dirname "$0")/../.." && pwd)/work/build/dxmt-pe/src
$G 'P=$(pgrep -f "[r]eaper SteamLaunch AppId=2357570" | head -1); [ -n "$P" ] && kill $P; sleep 6; for p in $(pgrep -f "[S]:.steamapps.common.Overwatch.Overwatch.exe"); do kill -9 $p; done; L=~/protonlogs/steam-2357570.log; [ -f $L ] && cp $L ~/protonlogs/steam-2357570.prev.log; true' </dev/null
for f in d3d11/d3d11.dll dxgi/dxgi.dll winemetal/winemetal.dll; do $G "cat > ~/dxmt-payload/x86_64-windows/$(basename $f)" < $B/$f; done
$G 'systemctl --user restart steamac-gfx-path.service; sleep 3; P=~/dxmt-payload/x86_64-windows/d3d11.dll; D=~/.local/share/Steam/steamapps/common/Proton\ -\ Experimental/files/lib/wine/dxvk/x86_64-windows/d3d11.dll; echo "dll_synced=$([ $(cmp -l "$P" "$D" | awk "\$1<65||\$1>80" | wc -l) = 0 ] && echo yes || echo NO)"; steam -ifrunning -applaunch 2357570 >/dev/null 2>&1' </dev/null
for i in $(seq 1 60); do [ -n "$($G 'pgrep -f "[S]:.steamapps.common.Overwatch.Overwatch.exe"' </dev/null 2>/dev/null)" ] && { echo "overwatch running $(date +%T)"; exit 0; }; sleep 5; done
echo "overwatch did not start"
