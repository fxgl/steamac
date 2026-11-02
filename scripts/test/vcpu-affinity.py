#!/usr/bin/env python3
"""Read-only check in a freshly booted guest; pass newly launched game PID(s).

Usage: python3 vcpu-affinity.py [GAME_PID ...]
Run as root to inspect every thread. No affinity or cgroup settings are changed.
Do not use after manual taskset changes: this checks boot-time inheritance.
"""
import os
from pathlib import Path
import subprocess
import sys


def cpu_set(value):
    result = set()
    for item in value.strip().split(","):
        if not item:
            continue
        ends = item.split("-")
        result.update(range(int(ends[0]), int(ends[-1]) + 1))
    return result


def check(condition, message):
    if not condition:
        raise SystemExit(f"FAIL: {message}")


online_text = Path("/sys/devices/system/cpu/online").read_text().strip()
online = cpu_set(online_text)
print(f"boot_id={Path('/proc/sys/kernel/random/boot_id').read_text().strip()}")
print(f"online={online_text} ({len(online)} vCPUs)")

for manager in ("system", "user"):
    config = subprocess.check_output(
        ["systemd-analyze", "cat-config", f"systemd/{manager}.conf"], text=True)
    expected = f"/usr/lib/systemd/{manager}.conf.d/50-steamac-vcpu-affinity.conf"
    check(f"# {expected}\n" in config, f"{expected} not loaded")
    assignments = [line.split("=", 1)[1].strip() for line in config.splitlines()
                   if line.strip().startswith("CPUAffinity=")]
    check(assignments and assignments[-1] == "", f"{manager} manager mask not reset")
    print(f"{manager}: loaded {expected}; final CPUAffinity is empty")

processes = {}
for path in Path("/proc").iterdir():
    if not path.name.isdecimal():
        continue
    try:
        comm = (path / "comm").read_text().strip()
        args = (path / "cmdline").read_bytes().split(b"\0")
    except (FileNotFoundError, ProcessLookupError):
        continue
    if comm in ("gamescope-wl", "steam") or (comm == "systemd" and b"--user" in args):
        processes[int(path.name)] = comm + (" --user" if b"--user" in args else "")
check(any(name == "systemd --user" for name in processes.values()), "no user manager")
for name in ("gamescope-wl", "steam"):
    check(name in processes.values(), f"no newly started {name}")
processes[1] = "PID 1"
for arg in sys.argv[1:]:
    processes[int(arg)] = "game"

for pid, name in sorted(processes.items()):
    tasks = list(Path(f"/proc/{pid}/task").iterdir())
    masks = {}
    for task in tasks:
        try:
            mask = os.sched_getaffinity(int(task.name))
        except ProcessLookupError:
            continue  # A worker may finish while the process is being inspected.
        masks[task.name] = mask
    check(masks, f"{name} pid={pid} exited")
    limited = {tid: sorted(mask) for tid, mask in masks.items() if mask != online}
    print(f"{name} pid={pid}: {len(masks)} threads, masks="
          f"{sorted({tuple(sorted(mask)) for mask in masks.values()})}")
    check(not limited, f"{name} pid={pid} restricted threads: {limited}")
    # Walk every ancestor: an empty cpuset.cpus means inheritance, while the
    # effective file includes restrictions imposed by ancestors.
    group = Path(f"/proc/{pid}/cgroup").read_text().strip().split("0::", 1)[1]
    path = Path("/sys/fs/cgroup") / group.lstrip("/")
    while True:
        effective = path / "cpuset.cpus.effective"
        if effective.exists():
            check(cpu_set(effective.read_text()) == online, f"restricted cgroup {path}")
        if path == Path("/sys/fs/cgroup"):
            break
        path = path.parent

if len(sys.argv) == 1:
    print("PARTIAL: managers/Gamescope/Steam passed; rerun with a newly launched game PID")
else:
    print("PASS: managers, Gamescope, Steam and supplied game threads can use every online vCPU")
