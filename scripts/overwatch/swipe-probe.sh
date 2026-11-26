#!/bin/bash
# 60 s probe while the user swipes: mouse reports/s in the VM, game main-thread CPU, GPU busy.
T=$(dirname "$0")
$T/g 'timeout 62 python3 -c "
import struct,time,collections,select
f=open(\"/dev/input/event2\",\"rb\",buffering=0); c=collections.Counter(); m=collections.Counter(); t0=time.time()
while time.time()-t0<60:
  r,_,_=select.select([f],[],[],0.5)
  if not r: continue
  s,us,ty,co,v=struct.unpack(\"qqHHi\",f.read(24))
  k=int(time.time()-t0)
  if ty==0: c[k]+=1
  elif ty==2: m[k]=max(m[k],abs(v))
print(\"mouse reports/s:\", \" \".join(str(c[i]) for i in range(60)))
print(\"max delta/s:    \", \" \".join(str(m[i]) for i in range(60)))
" & P=$(pgrep -f "[S]:.steamapps.common.Overwatch.Overwatch.exe" | head -1); top -b -d 2 -n 30 -H -p $P | awk "/PID USER/{if(n)printf \"%s \", top; n++; top=0; next} n && \$9+0>top {top=\$9+0}"; echo; wait' </dev/null &
for i in $(seq 1 30); do ioreg -r -c IOAccelerator -d 1 | grep -o '"Device Utilization %"=[0-9]*' | tr -dc '0-9'; echo -n " "; sleep 2; done > /tmp/gpu.$$; wait
echo "gpu busy % every 2 s: $(cat /tmp/gpu.$$)"; rm -f /tmp/gpu.$$
