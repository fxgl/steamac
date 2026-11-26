#!/bin/bash
# Timing run while the user plays (no restart): per second, the VM's busiest game threads, VM major page
# faults, mouse reports; the Mac's GPU busy %, pageins and launcher CPU. Joined by time with the launcher's
# 30 s "game frames:" lines into ow-compare/timing-<date>.txt.
# Usage: timing-run.sh [seconds]
set -u
T=$(dirname "$0"); N=${1:-180}
OUT=${OW_LOGS:-$HOME/overwatch-logs}/timing-$(date +%m%d-%H%M); mkdir -p "$OUT"
L=~/Library/Logs/es.fxgam.steamac/steamac-vm.log
start_line=$(wc -l < "$L" | tr -d " ")

$T/g "python3 - $N" > "$OUT/guest.txt" 2>&1 </dev/null <<'EOF' &
import os, sys, time, select, struct
n = int(sys.argv[1])
pid = next(p for p in os.listdir('/proc') if p.isdigit() and 'Overwatch.exe' in open(f'/proc/{p}/cmdline','rb').read().decode('latin1') and 'S:' in open(f'/proc/{p}/cmdline','rb').read().decode('latin1'))
hz = os.sysconf('SC_CLK_TCK')
def threads():
    r = {}
    for t in os.listdir(f'/proc/{pid}/task'):
        try: s = open(f'/proc/{pid}/task/{t}/stat').read()
        except OSError: continue
        name = s[s.index('(')+1:s.rindex(')')]; f = s[s.rindex(')')+2:].split()
        r[t] = (name, int(f[11]) + int(f[12]))
    return r
def majflt(): return int(next(l.split()[1] for l in open('/proc/vmstat') if l.startswith('pgmajfault')))
mouse = open('/dev/input/event2', 'rb', buffering=0); os.set_blocking(mouse.fileno(), False)
prev, pm = threads(), majflt()
for _ in range(n):
    end = time.time() + 1; reports = 0
    while time.time() < end:
        r, _, _ = select.select([mouse], [], [], max(0, end - time.time()))
        if r:
            try:
                d = mouse.read(24 * 64) or b''
                reports += sum(1 for i in range(0, len(d) - 23, 24) if struct.unpack('qqHHi', d[i:i+24])[2] == 0)
            except BlockingIOError: pass
    cur, cm = threads(), majflt()
    busy = sorted(((cur[t][1] - prev[t][1]) * 100 // hz, cur[t][0]) for t in cur if t in prev)[-4:][::-1]
    total = sum((cur[t][1] - prev[t][1]) for t in cur if t in prev) * 100 // hz
    print(int(time.time()), f"game_cpu={total}%", f"majflt={cm - pm}", f"mouse={reports}", " ".join(f"{nm}:{c}" for c, nm in busy), flush=True)
    prev, pm = cur, cm
EOF

LP=$(pgrep -f "MacOS/steamac-vm" | head -1)
pi=$(vm_stat | awk '/Pageins/ {gsub("\\.","",$2); print $2}')
for i in $(seq 1 "$N"); do
  sleep 1
  g=$(ioreg -r -c IOAccelerator -d 1 | grep -o '"Device Utilization %"=[0-9]*' | tr -dc '0-9')
  p=$(vm_stat | awk '/Pageins/ {gsub("\\.","",$2); print $2}')
  c=$(ps -o %cpu= -p "$LP" | tr -d ' ')
  echo "$(date +%s) gpu=$g% mac_pageins=$((p - pi)) launcher_cpu=$c%"; pi=$p
done > "$OUT/host.txt"
wait
tail -n +"$start_line" "$L" | grep -E "game frames:|stall:|queue recovery|memory pressure" > "$OUT/launcher.txt"

python3 - "$OUT" <<'EOF'
import sys, collections
d = sys.argv[1]; rows = collections.defaultdict(list)
for f in ('guest.txt', 'host.txt'):
    for l in open(f'{d}/{f}'):
        p = l.split(' ', 1)
        if p[0].isdigit(): rows[int(p[0])].append(p[1].strip())
with open(f'{d}/joined.txt', 'w') as o:
    for t in sorted(rows): o.write(f"{t} " + " | ".join(rows[t]) + "\n")
print(open(f'{d}/launcher.txt').read())
EOF
echo "data: $OUT"
