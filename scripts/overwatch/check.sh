#!/bin/bash
# GPU errors and recoveries this game session; launcher memory.
T=$(dirname "$0")
$T/g 'L=~/protonlogs/steam-2357570.log; echo "faults=$(grep -a "Device error" $L | grep -c "Address Fault") hangs=$(grep -a "Device error" $L | grep -c "Hang Error") ignored=$(grep -a "Device error" $L | grep -c Submissions) running=$(pgrep -fc "[S]:.steamapps.common.Overwatch.Overwatch.exe")"' </dev/null
grep "memory: t=" ~/Library/Logs/es.fxgam.steamac/steamac-vm.log | tail -1 | grep -o "footprint=[0-9]* resident=[0-9]* internal=[0-9]* compressed=[0-9]*\|malloc-in-use=[0-9]*" | tr '\n' ' '; echo
