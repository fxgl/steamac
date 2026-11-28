#!/bin/bash
# Mac-side sampler for freeze hunting: every 0.25 s, pageins / swapins / compressions since the last sample and the
# launcher's CPU time gained (ms, all its processes). Lines: epoch_ms pageins swapins compressions decompressions launcher_cpu_ms
# Usage: host-sampler.sh SECONDS > file
N=${1:-300}
stat() { vm_stat | awk '/Pageins/{p=$2} /Swapins/{s=$2} /Compressions/{c=$2} /Decompressions/{d=$2} END{gsub("\\.","",p);gsub("\\.","",s);gsub("\\.","",c);gsub("\\.","",d);print p, s, c, d}'; }
cpu() { ps -o time= -p "$(pgrep -d, -x steamac-vm)" 2>/dev/null | awk -F'[:.]' '{ms += ($1*60 + $2)*1000 + $3*10} END{print ms+0}'; }
read p0 s0 c0 d0 < <(stat); u0=$(cpu)
end=$(( $(date +%s) + N ))
while [ "$(date +%s)" -lt "$end" ]; do
  sleep 0.25
  read p s c d < <(stat); u=$(cpu)
  echo "$(python3 -c 'import time;print(int(time.time()*1000))') $((p-p0)) $((s-s0)) $((c-c0)) $((d-d0)) $((u-u0))"
  p0=$p; s0=$s; c0=$c; d0=$d; u0=$u
done
