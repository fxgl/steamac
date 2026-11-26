#!/bin/bash
# Watch an Overwatch session through the launcher log; print only lines worth acting on:
# live game FPS (launcher builds with "game frames:"), GPU errors and queue recoveries, guest stalls,
# macOS memory pressure and the end-of-session stats. Everything also lands in ow-compare/watch-<date>.log.
# ("perf: flush" lines time the launcher's own scanout, not DXMT game frames, so they are skipped.)
L=~/Library/Logs/es.fxgam.steamac/steamac-vm.log
OUT=${OW_LOGS:-$HOME/overwatch-logs}/watch-$(date +%m%d-%H%M).log
tail -n0 -F "$L" 2>/dev/null \
  | grep --line-buffered -E "game frames:|slow call|slow gpu|queue recovery|pausing recovery|wmtr-gpu-fault|stall: (gpu idle|guest not)|memory pressure:|game stats: 2357570 (ended|started)" \
  | while IFS= read -r line; do
      t=$(date +%H:%M:%S); echo "$t $line" >> "$OUT"
      case "$line" in *wmtr-gpu-fault*) g=$((g+1)); [ $g -gt 3 ] && continue;; esac  # first few faults only; the log keeps the rest
      echo "$t ${line:0:200}"
    done
