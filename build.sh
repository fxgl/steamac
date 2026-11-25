#!/usr/bin/env bash
# Build everything steamac needs, in dependency order. Each step is idempotent and can be
# re-run on its own (see manual/building.md). Needs: macOS 15+ on Apple silicon, Xcode, Homebrew,
# rustup, OrbStack (or another Docker with arm64 + privileged containers).
#
#   ./build.sh            host stack, guest kernel, guest Venus Mesa, disk image
#   ./build.sh host       only the macOS side (MoltenVK, KosmicKrisp on macOS 26+, libepoxy,
#                         virglrenderer, libkrun, launcher)
#   ./build.sh guest      only the guest side (kernel, rootfs, Mesa, initramfs, layer, disk)
#   ./build.sh dxmt       DXMT host executor + guest dlls/unixlib (requires Rosetta and linux/amd64 Docker)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

host() {
    host/moltenvk/build.sh
    # KosmicKrisp needs Metal 4 (macOS 26+); without it the app offers MoltenVK only.
    if (($(sw_vers -productVersion | cut -d. -f1) >= 26)); then
        host/kosmickrisp/build.sh
    else
        echo "KosmicKrisp skipped: needs macOS 26 or newer" >&2
    fi
    host/libepoxy/build.sh
    host/virglrenderer/build.sh
    host/libkrun/build.sh
    host/launcher/build.sh
}

guest() {
    guest/kernel/build.sh
    scripts/build-image.sh builder rootfs      # verified OTA rootfs, needed by the Mesa verify step
    guest/mesa/build.sh
    scripts/build-image.sh initramfs layer disk check
}

case ${1:-all} in
    host) host ;;
    guest) guest ;;
    dxmt) host/dxmt/build.sh ;;
    all) host; guest ;;
    *) echo "usage: $0 [all|host|guest|dxmt]" >&2; exit 64 ;;
esac
