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

This is experimental. Integrated guest testing still shows Zink allocation
failures and stalled game loading with both host Vulkan drivers; this build
is not yet validated for gameplay. A Steam sign-in screen is not a game compatibility test.
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
FX Steam Launcher 1.9.13 app (set `STEAMAC_BASE_APP` to its path).
Older host GPU libraries do not match the integrated guest backports. Set
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

## Disk creation options

Bazzite exposes build, total disk capacity (48–2048 GiB, default 64 GiB), location,
optional `bazzite` password, and the shared Steam client selection. Its ext4 root
holds both system and games. Creation grows the final Linux partition and both
GPT tables; a per-disk initramfs hook installs a one-shot first-boot service to
expand ext4 and apply the password hash before the desktop starts. The password
is never stored as plaintext. The image remains sparse on APFS.

The installed sidecar records the expanded disk size. The verified release
initramfs is augmented locally with the setup archive; release hashes describe
the original downloads. The guest's client wrapper reads the selected client
on each boot. SteamOS-specific license acceptance and branch selection are
replaced by the Bazzite build selector; Steam's own terms remain in its client.

Validation of the new options: a 64 GiB disk booted, ext4 expanded online, and
the chosen password matched the guest shadow hash. GPT tests cover Fedora's
aligned usable range, invalid partition bounds and backup table relocation.
Settings captures include all three new options. Graphics/gameplay limitations
above remain unresolved.
