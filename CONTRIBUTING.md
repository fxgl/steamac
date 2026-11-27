# Contributing

Thanks for helping. There are several ways to contribute, and most of them need no code.

## Report a problem

The fastest route is **Help → Report a Problem…** in the launcher. It attaches the launcher and
SteamOS logs (with personal data redacted) and goes straight to the developers. What it contains is
described in [Report a Problem](manual/report-a-problem.md).

For a GitHub issue, include:

- the launcher version and your Mac (chip, RAM, macOS version);
- the Vulkan driver (KosmicKrisp or MoltenVK) and, for games, whether DXMT was on;
- what you did, what you expected and what happened;
- the game's name and Steam app ID, if a game is involved.

## Report how a game runs

Turn on game statistics in **Settings → Games** and rate the games you play. The aggregated results
appear on the [statistics page](https://fxgl.github.io/steamac/games.html) and feed the recommended
per-game profiles. What is collected is listed in
[Crash reports, updates and game statistics](manual/privacy-and-updates.md).

## Translate

The project is maintained in English, Russian and Simplified Chinese:

- the launcher: `host/launcher/Localizable.xcstrings` and `InfoPlist.xcstrings`;
- the README (`README.md`, `README.ru.md`, `README.zh.md`) and the manual (`manual/`, `manual/ru/`,
  `manual/zh/`), which keep the same files and sections in every language;
- the website (`docs/`), where every string carries one `<span lang>` per language.

If you change text in one language and cannot translate it, say so in the pull request.

## Build and run

You need a Mac with Apple silicon, macOS 15 or later, Xcode 26+, Homebrew, rustup and OrbStack
(or Docker with arm64 and privileged containers).

```sh
./build.sh          # everything: host stack, guest kernel, Mesa, disk image
./build.sh host     # only the macOS side
./build.sh guest    # only the guest side
./run.sh            # SteamOS in a window
```

Each step is idempotent and can be re-run on its own. Details, including the Homebrew packages and
how to rebuild single guest artifacts, are in [Building from source](manual/building.md).

## Where things live

| Directory | What it is |
|---|---|
| `host/launcher/` | The macOS app (Swift/AppKit): window, input, sound, settings, updates |
| `host/libkrun/` | The VMM, with patches in `patches/` |
| `host/virglrenderer/` | Venus on the host, with patches |
| `host/moltenvk/`, `host/kosmickrisp/` | The two Vulkan-on-Metal drivers, with patches |
| `host/dxmt/`, `wmtr/` | Direct3D 11 straight to Metal (experimental) |
| `guest/` | Guest kernel, Mesa, initramfs and the read-only layer over SteamOS |
| `scripts/` | Disk image build and test scripts (`scripts/test/`) |
| `services/game-stats/` | The public game statistics API |
| `docs/` | The website (GitHub Pages) |

Each component, its pinned upstream and what its patches do are described in
[How it works](manual/architecture.md).

## Pull requests

- Branch from `main` and open the pull request against `main`.
- Keep one logical change per commit. Start the subject with the area it touches, as in the history:
  `launcher: …`, `libkrun: …`, `MoltenVK: …`, `KosmicKrisp: …`, `Site: …`, `README: …`.
- Patches to upstream projects go into that component's `patches/` series as numbered files
  (`0026-short-description.patch`). Mention the number in the commit subject.
- Say how you tested it: Mac, macOS version, Vulkan driver and the games or scripts you ran.
- If the change affects what users see or do, update the README and the manual in all three languages,
  or say which ones still need translating.

## License

By contributing you agree that your contribution is licensed under the license applicable to the part
of the project it changes: Apache-2.0 by default; GPL-2.0-only for Linux kernel patches and
configuration (`guest/kernel/patches/`, `guest/kernel/config/`, `guest/kernel/config-steamac`);
MIT for Mesa and virglrenderer patches (`guest/mesa/`, `host/virglrenderer/patches/`) and the
Valve-derived gamescope session files; LGPL-2.1-or-later (LGPL-2.1+) for DXMT patches (`host/dxmt/patches/`);
and BSD-3-Clause for the DXMT remoting layer (`wmtr/`). See [NOTICE](NOTICE) and [LICENSES/](LICENSES/).
