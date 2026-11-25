<p align="center"><img src="docs/media/icon.png" width="96" height="96" alt=""></p>

<h1 align="center">FX Steam Launcher</h1>

<p align="center">
Valve's official ARM64 SteamOS — the Steam Frame build — in a lightweight VM on Apple Silicon.<br>
GPU-accelerated Windows games, any controller, native sound.
</p>

<p align="center">
<a href="https://github.com/fxgl/steamac/releases/latest"><b>Download</b></a> ·
<a href="https://fxgl.github.io/steamac/">Website</a> ·
<a href="https://fxgl.github.io/steamac/games.html">Game statistics</a> ·
<a href="manual/README.md">Manual</a>
</p>

<p align="center"><b>English</b> · <a href="README.ru.md">Русский</a> · <a href="README.zh.md">简体中文</a></p>

![Steam's gamepad UI running in FX Steam Launcher](docs/media/shot-library.jpg)

## Install

1. Download the DMG from [Releases](https://github.com/fxgl/steamac/releases/latest), open it and drag
   FX Steam Launcher to Applications. It is signed and notarized by Apple.
2. Launch it and choose **Create New Disk…**: pick the SteamOS branch, the size of the games partition
   and the Steam client, and accept Valve's SteamOS license and the Steam Subscriber Agreement. The
   launcher downloads Valve's signed image (~4.5 GB), checks it and writes the disk.
3. Sign in to Steam and install games. Steam brings Proton 11 (ARM64) and FEX itself.

You need a Mac with Apple silicon, macOS 15 or later, and ~20 GB free to create the disk. The disk is
sparse and grows as you install games. Updates install from inside the app.

## What works

- **DirectX 9/10/11** through DXVK, **DirectX 12** through vkd3d-proton, OpenGL through zink.
- **x86-64 Windows and Linux games** through Proton 11 for ARM64 and FEX, with Apple's hardware TSO.
- **Controllers**: Xbox, DualSense (also passed through with touchpad, gyro and adaptive triggers),
  DualShock 4, MFi and the Steam Controller, with rumble. Mouse capture for mouse-look.
- **Sound** through CoreAudio, up to 12 channels (5.1, 7.1, 7.1.4), and the microphone.
- **Suspend** to memory, **Desktop Mode**, a shared **clipboard** and **folder**, **Moonlight** streaming
  and **Steam Remote Play** on your network.
- Two Vulkan drivers: **KosmicKrisp** (Metal 4, macOS 26+, the default there) and **MoltenVK** (Metal 3).

Which games run and how well, reported by players: [game statistics](https://fxgl.github.io/steamac/games.html).

## Limitations

- Games that need DirectX 12 feature level 12_1 or shader model 6.6 (Unreal Engine 5) don't start.
- Anti-cheat that blocks virtual machines won't let you in.
- A new effect stutters once while Metal compiles it (~50–100 ms); after that it is cached.

More in [Status and limitations](manual/status.md).

## How it works

```
game (DX9/10/11) ─ DXVK (Proton 11, x86 via FEX) ─ Vulkan
   └─ guest Mesa Venus ─ virtio-gpu (blob, 16K alignment)
        └─ libkrun ─ virglrenderer (Venus) ─ MoltenVK | KosmicKrisp ─ Metal
```

libkrun boots Valve's signed SteamOS image on Hypervisor.framework, without QEMU. The SteamOS root
filesystem is never modified, so official A/B updates work as on a Steam Deck. Every component and patch
set is listed in [How it works](manual/architecture.md).

## Build from source

```sh
git clone https://github.com/fxgl/steamac
cd steamac
./build.sh    # MoltenVK, KosmicKrisp, virglrenderer, libkrun, launcher, guest kernel, Mesa, disk
./run.sh      # SteamOS in a window
```

You need Xcode 26+, Homebrew, rustup and OrbStack (or Docker with arm64 and privileged containers).
The full guide is in [Building from source](manual/building.md).

## Manual

| Topic | What's inside |
|---|---|
| [Using the launcher](manual/using.md) | The app, uninstalling, languages, the Steam client, signing in |
| [Settings](manual/settings.md) | Every tab of the Settings window and per-game profiles |
| [Controllers](manual/controllers.md) | Gamepads, DualSense passthrough, Steam Controller, mouse and keyboard |
| [Vulkan drivers](manual/vulkan-drivers.md) | MoltenVK and KosmicKrisp: what each supports and how to switch |
| [Streaming and Remote Play](manual/streaming.md) | LAN networking, Steam Remote Play and Moonlight |
| [Suspend and sleep](manual/suspend-and-sleep.md) | Suspending SteamOS in memory and SteamOS's own sleep |
| [Desktop Mode](manual/desktop-mode.md) | Plasma desktop inside the VM |
| [Clipboard and shared folder](manual/clipboard-and-shared-folder.md) | Sharing text, images and a Mac folder with SteamOS |
| [Crash reports, updates and game statistics](manual/privacy-and-updates.md) | What is sent, when, and how to turn it off |
| [Report a Problem](manual/report-a-problem.md) | What a problem report contains and how to send one |

## Contributing

Bug reports, game reports, translations and patches are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md).

## License

The project code is licensed under Apache License 2.0 (`LICENSE`), © 2026 FX GAMES FZ LLC. Exceptions
are listed in `NOTICE`: Linux kernel patches and configuration — GPL-2.0-only, virglrenderer and Mesa
patches — MIT (as in those projects), five gamescope session files derived from Valve's
`deckard-steamvr-session` package — MIT © Valve Corporation; the Valve CA certificate and screenshots
in `docs/media` are not covered by the project license. License texts are in `LICENSES/`.

SteamOS is not part of the project and is not distributed with it: the app downloads a signed image
from Valve's servers after the user accepts Valve's license (see “Creating the SteamOS disk without
Docker”).

Steam, the Steam logo, SteamOS, Steam Deck, and Steam Frame are trademarks and/or registered trademarks
of Valve Corporation in the United States and/or other countries. The project is not affiliated with or
endorsed by Valve Corporation.
