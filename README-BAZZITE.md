# Bazzite ARM64 guest backend

This fork keeps steamac's original first-run and Create New Disk interface, adds
an Operating system picker, and downloads Bazzite builds from
[Naozumi520/bazzite Releases](https://github.com/Naozumi520/bazzite/releases).
Compatible releases contain `bazzite-steamac.json` (schema 1), a gzip raw GPT disk,
a matching 4K kernel, and the Fedora bootc deployment's initramfs. The picker
includes prereleases and ignores releases without this manifest.

The downloader checks HTTPS repository ownership, manifest fields, exact asset
sizes and SHA-256, rejects oversized/truncated decompression, preserves sparse
blocks, and never overwrites an existing destination. SHA-256 against an HTTPS
release is integrity verification, not independent signature verification.
Keep `<disk>.bazzite/` beside your disk; it contains the matching boot files and
bootc command line. Bazzite uses the Fedora initramfs, direct Plasma desktop,
absolute pointer input, and no SteamOS `/usr` layer. SteamOS keeps its existing
creation and boot path. Explicit kernel/initrd/cmdline options take precedence.

This is experimental. A Steam sign-in screen is not a game compatibility test.
Full Bazzite Game Mode, Proton, FEX graphics provider, audio/controller behavior,
persistence and updates/rollback need end-to-end validation. Fedora Mesa must be
built with steamac's Venus blob alignment support; stock Fedora Mesa is not
sufficient. The custom kernel currently lacks SELinux; this guest disables it.
Do not apply bootc updates that change the boot deployment until the sidecar
refresh/rollback path is implemented.

## Build

Use the patched libkrun v1.19.6 headers from this tree's `host/libkrun` build.
`host/launcher/build-bazzite-app.sh` builds Swift from this checkout and assembles
`work/out/Steamac Bazzite.app` using the matched libraries/resources from an
installed FX Steam Launcher (override `STEAMAC_BASE_APP`). Set
`STEAMAC_KRUN_INCLUDE` to your header directory. It leaves the installed app
untouched. All existing third-party notices are carried into the resulting app.
The app is ad-hoc signed for local use; it is not Developer ID notarized.

This fork has a separate preferences/bundle identifier, points its GitHub update
checker to this fork, removes the original Sparkle update feed/key, and defaults
crash reporting off. It does not silently replace itself with upstream releases.

The command-line download path uses the same implementation as the UI:

```sh
steamac-vm --create-bazzite /path/to/bazzite.img --bazzite-build RELEASE_TAG
steamac-vm --selftest-bazzite
```

The guest agent adds `FX_PROGRESS_DESKTOP_NATIVE=1` for a direct KWin desktop.
The Fedora build of this agent is compiled from this fork, without copying
Arch/SteamOS dynamic libraries.
