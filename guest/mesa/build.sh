#!/usr/bin/env bash
# Builds the guest Venus (virtio) Vulkan ICD and a zink-only GL stack for the Steam Frame
# SteamOS image, from the pinned Mesa; the GL build carries the backports in patches/:
#   aarch64 (native: Steam, Proton ARM64EC/WoW64 unix side, gamescope, zink)
#   x86_64 + i386 (FEX-emulated x86 apps; installed into the fex-mesa pressure-vessel provider),
#   plus the x86_64 fault reporter for emulated games (/usr/lib/steamac/x86_64/fault-report.so)
# Output: work/out/mesa-venus/ = tree rooted at guest "/" + MANIFEST.txt.
# Verification runs against the stock rootfs in a chroot: by default the signature- and
# sha256-verified OTA rootfs that `scripts/build-image.sh rootfs` caches in work/cache/rootfs/.
#
# Usage: guest/mesa/build.sh [--clean] [step...]
#   steps: fetch aarch64 x86 verify   (default: all, in that order)
#   --clean  drop the cached source volume and all outputs first
# Env overrides: ROOTFS_IMG (stock SteamOS rootfs image, btrfs).
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
set -a
# shellcheck source=versions.env
source "$HERE/versions.env"
set +a

OUT=$REPO/work/out/mesa-venus
WORK=$REPO/work/build/mesa-venus
STEAMOS_BUILDID=$(. "$REPO/scripts/config.env" && echo "$STEAMOS_BUILDID")
ROOTFS_IMG=${ROOTFS_IMG:-$REPO/work/cache/rootfs/$STEAMOS_BUILDID/rootfs.img}
SRC_VOLUME=steamac-mesa-src

clean=0
steps=()
for arg in "$@"; do
    case $arg in
        --clean) clean=1 ;;
        fetch|aarch64|x86|verify) steps+=("$arg") ;;
        *) echo "unknown argument: $arg" >&2; exit 64 ;;
    esac
done
[ ${#steps[@]} -gt 0 ] || steps=(fetch aarch64 x86 verify)

if [ "$clean" = 1 ]; then
    docker volume rm -f "$SRC_VOLUME" >/dev/null
    rm -rf "$OUT" "$WORK"
fi
mkdir -p "$OUT" "$WORK"

artifacts() { python3 "$REPO/scripts/guest-artifacts.py" "$@"; }
# Starting any Mesa operation invalidates the release tree receipt. Per-arch
# receipts allow a verify-only run, but never bless an old architecture build.
artifacts invalidate mesa
fetched=0
fetch_sources() {
    docker run --rm --platform linux/arm64 \
        -e MESA_URL -e MESA_COMMIT -e VENUS_PROTOCOL_URL -e VENUS_PROTOCOL_COMMIT \
        -v "$SRC_VOLUME:/src" -v "$HERE/container:/scripts:ro" \
        "$TOOLS_IMAGE" sh /scripts/fetch-mesa.sh
    fetched=1
}

log() { printf '\n=== %s\n' "$*"; }

for step in "${steps[@]}"; do
    case $step in
    fetch)
        log "fetch mesa $MESA_COMMIT"
        fetch_sources
        ;;
    aarch64)
        log "build aarch64 (log: $WORK/build-aarch64.log)"
        inputs=$(artifacts begin mesa-aarch64)
        [[ $fetched == 1 ]] || fetch_sources
        rm -rf "$OUT/usr/lib/libvulkan_virtio.so" "$OUT/usr/share/vulkan" "$OUT/usr/lib/dri" "$OUT/usr/lib/gbm" \
            "$OUT/usr/share/glvnd" "$OUT/usr/share/drirc.d"
        rm -f "$OUT"/usr/lib/libgallium-*.so "$OUT"/usr/lib/libGLX_mesa.so* "$OUT"/usr/lib/libEGL_mesa.so* \
            "$OUT"/usr/lib/libgbm.so*
        docker run --rm --platform linux/arm64 \
            -v "$SRC_VOLUME:/src:ro" -v "$HERE/patches:/patches:ro" -v "$HERE/container:/scripts:ro" \
            -v "$OUT:/out" -v "$WORK:/work" \
            "$AARCH64_IMAGE" bash /scripts/build-aarch64.sh > "$WORK/build-aarch64.log" 2>&1 \
            || { tail -40 "$WORK/build-aarch64.log"; exit 1; }
        artifacts finish mesa-aarch64 "$inputs"
        ;;
    x86)
        log "build x86_64 + i386 (log: $WORK/build-x86.log)"
        inputs=$(artifacts begin mesa-x86)
        [[ $fetched == 1 ]] || fetch_sources
        rm -rf "$OUT/usr/share/guestos" "$OUT/usr/lib/steamac"
        docker run --rm --platform linux/amd64 \
            -e STEAMOS_X86_MIRROR -e STEAMOS_X86_BRANCH -e FEX_PROVIDER -e HOLO_KEYRING_PKG -e HOLO_KEYRING_SHA256 \
            -v "$SRC_VOLUME:/src:ro" -v "$HERE/patches:/patches:ro" -v "$HERE/container:/scripts:ro" \
            -v "$OUT:/out" -v "$WORK:/work" \
            "$X86_IMAGE" bash /scripts/build-x86.sh > "$WORK/build-x86.log" 2>&1 \
            || { tail -40 "$WORK/build-x86.log"; exit 1; }
        artifacts finish mesa-x86 "$inputs"
        ;;
    verify)
        log "manifest + verify against $ROOTFS_IMG (log: $WORK/verify.log)"
        inputs=$(artifacts begin mesa)
        [ -f "$ROOTFS_IMG" ] || { echo "missing stock rootfs image: $ROOTFS_IMG" >&2; exit 1; }
        # An override may be useful for diagnostics, but cannot produce a release
        # receipt for a different rootfs than the one pinned in config.env.
        rootfs_sha=$(. "$REPO/scripts/config.env" && echo "$STEAMOS_ROOTFS_SHA256")
        echo "$rootfs_sha  $ROOTFS_IMG" | shasum -a 256 -c -
        docker run --rm --platform linux/arm64 --privileged \
            -e MESA_URL -e MESA_COMMIT -e VENUS_PROTOCOL_COMMIT -e AARCH64_IMAGE -e X86_IMAGE \
            -e STEAMOS_X86_MIRROR -e STEAMOS_X86_BRANCH -e FEX_PROVIDER \
            -v "$ROOTFS_IMG:/rootfs.img:ro" -v "$HERE/patches:/patches:ro" -v "$HERE/container:/scripts:ro" \
            -v "$OUT:/out" -v "$WORK:/work" \
            "$TOOLS_IMAGE" sh -c 'sh /scripts/manifest.sh && sh /scripts/verify.sh' 2>&1 | tee "$WORK/verify.log"
        artifacts finish mesa "$inputs"
        ;;
    esac
done
log "done: $OUT"
