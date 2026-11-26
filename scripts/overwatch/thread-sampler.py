# Runs in the VM: every 20 ms, for the game's 6 busiest threads, CPU ticks gained, state and current syscall.
# Output lines: epoch_ms tid name dcpu state syscall_nr  (only threads that are not idle-sleeping in a poll, plus all every 1 s).
import os, sys, time
n = float(sys.argv[1]) if len(sys.argv) > 1 else 120
pid = next(p for p in os.listdir('/proc') if p.isdigit() and b'Overwatch.exe' in open(f'/proc/{p}/cmdline','rb').read() and b'S:' in open(f'/proc/{p}/cmdline','rb').read())
def read(tid):
    try:
        s = open(f'/proc/{pid}/task/{tid}/stat').read()
        name = s[s.index('(')+1:s.rindex(')')]; f = s[s.rindex(')')+2:].split()
        sc = open(f'/proc/{pid}/task/{tid}/syscall').read().split()[0]
        return name, f[0], int(f[11]) + int(f[12]), sc
    except OSError: return None
tids = os.listdir(f'/proc/{pid}/task')
first = {t: read(t) for t in tids}; time.sleep(1); second = {t: read(t) for t in tids}
busy = sorted((second[t][2] - first[t][2], t) for t in tids if first.get(t) and second.get(t))[-6:]
watch = [t for _, t in busy]
print("watching", [(t, second[t][0], c) for c, t in busy], flush=True)
prev = {t: read(t) for t in watch}; end = time.time() + n
while time.time() < end:
    time.sleep(0.02)
    now = int(time.time() * 1000)
    out = []
    for t in watch:
        r = read(t)
        if not r or not prev.get(t): continue
        out.append(f"{t}:{r[1]}:{r[2]-prev[t][2]}:{r[3]}")
        prev[t] = r
    print(now, " ".join(out), flush=True)
