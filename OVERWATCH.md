# Overwatch 2 on FX Steam Launcher (DXMT path)

How I got Overwatch 2 playable on an M5 MacBook Pro (24 GB, macOS 27). This branch is FX Steam Launcher `main` plus everything I changed. It's unofficial and use-at-your-own-risk. Written with an AI coding assistant (Claude).

**Result (best sessions):** ~100–109 FPS average at a 120 cap, 1% lows around 50, no GPU crashes, launcher RAM 16–20 GB. The starting point was not launching at all, then 55 FPS with 1% lows of 14–16, crashes on hero switches, and 23–26 GB of RAM.

## What's in this branch

| Where | What |
|---|---|
| `host/dxmt/patches/0028-*.patch` | DXMT fixes, applied by the normal DXMT build after 0001–0027. A bounds check on vertex reads and a stream-output fix stop the GPU crashes. The shader IR is freed after load, saving about 8.6 GB. Pipelines are recorded and rebuilt during the loading screen. Plus pipeline-wait logging. |
| `wmtr/src/wmtr_host.m`, `wmtr_client.c` | The bridge between the VM and the Mac. It recovers when a GPU queue gets stuck instead of hanging, keeps graphics compiles from starving compute compiles (utility QoS), and logs slow calls and slow GPU work. |
| `host/launcher/...` | Batches mouse motion at 250 Hz (the Mac sent up to 6,000 events a second, which froze frames). Logs live FPS every 30 s, logs long frames, and feeds FPS stats for DXMT games. |
| `guest/fex/overwatch-fex-fixes.patch` | FEX fixes the game needs to start: a CPU flags bit, a deadlock on unreadable pages (FEX-Emu/FEX#6141), and cross-process writes. **Not built automatically, see below.** |
| `guest/dmi-identity.sh` | Gives the VM a Mac hardware identity (SMBIOS/DMI) for the anti-cheat. Reference only. |
| `scripts/overwatch/` | My test and install scripts: `launcher-install.sh`, `game-restart.sh`, `watch.sh`, samplers and probes. |

## Setup

1. Build the launcher as described in the main README. The DXMT patch is picked up automatically.
2. **FEX:** build FEX at commit `be66e03d` with `guest/fex/overwatch-fex-fixes.patch` applied, inside the VM. Then replace the FEX binaries in Steam's `steamapps/common/FEX-Emu` tool, and back up the originals first. Steam can overwrite them when it updates that tool.
3. **Game profile** for Overwatch (Settings → Games, launch options/env):
   `DXMT_ASYNC_PIPELINES=1 DXMT_METALFX_SPATIAL_SWAPCHAIN=1`
4. **VM memory: 10 GB** (Settings → VM). FEX's translated code alone reaches 2–4 GB, and at 8 GB the VM swaps, which shows up as half-second freezes.
5. Keep mouse auto-capture on for the game, and quit big background apps like Docker Desktop.

## Still rough

- The first time you see a new map or hero, it stutters while shaders compile. They're cached after that, and the recorded pipelines get rebuilt during the next loading screen.
- About a 0.5 s freeze when switching out of the fullscreen game. That's the macOS Space animation.
- FEX memory grows during long sessions.
