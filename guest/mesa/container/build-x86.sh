#!/bin/bash
# Runs in X86_IMAGE (Arch Linux amd64, under Rosetta). Builds x86_64 and i386 Venus ICDs and
# the patched zink GL stack for the FEX graphics provider (/usr/share/guestos/fex-mesa) and
# the x86_64 fault reporter for emulated games (/usr/lib/steamac/x86_64/fault-report.so,
# source fault-report.c).
# Mounts: /src (mesa source, ro), /patches (ro), /scripts (ro), /out (guest tree), /work (test bins, logs).
# Env: STEAMOS_X86_MIRROR STEAMOS_X86_BRANCH FEX_PROVIDER HOLO_KEYRING_PKG HOLO_KEYRING_SHA256
set -euo pipefail
shopt -s inherit_errexit
source /scripts/common.sh

# fetch_pinned <VAR prefix>: download ${VAR}_PKG from the SteamOS mirror, check ${VAR}_SHA256, print path.
fetch_pinned() {
    local pkg_var=${1}_PKG sum_var=${1}_SHA256
    local file=/tmp/$(basename "${!pkg_var}")
    curl -fsSL --retry 5 -o "$file" "${STEAMOS_X86_MIRROR}/${!pkg_var}"
    echo "${!sum_var}  $file" | sha256sum -c - >&2
    echo "$file"
}

# Pin the whole userspace to Valve's SteamOS x86_64 snapshot (glibc 2.41, gcc 15.1.1), the same
# glibc/libstdc++ generation the fex-mesa provider ships, so no newer symbol versions leak in.
cat > /etc/pacman.conf <<EOF
[options]
Architecture = x86_64
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional
ParallelDownloads = 8
NoExtract = usr/share/help/* usr/share/doc/* usr/share/man/* usr/share/locale/* usr/share/i18n/*

[core]
Server = ${STEAMOS_X86_MIRROR}/core-${STEAMOS_X86_BRANCH}/os/\$arch
[extra]
Server = ${STEAMOS_X86_MIRROR}/extra-${STEAMOS_X86_BRANCH}/os/\$arch
[multilib]
Server = ${STEAMOS_X86_MIRROR}/multilib-${STEAMOS_X86_BRANCH}/os/\$arch
EOF
pacman-key --init >/dev/null 2>&1
pacman-key --populate archlinux >/dev/null 2>&1
# SteamOS rebuilds (glibc, systemd, ...) are signed by Valve's CI key from holo-keyring.
keyring=$(fetch_pinned HOLO_KEYRING)
pacman -U --noconfirm "$keyring"
pacman-key --populate holo >/dev/null 2>&1
pacman -Syuu --noconfirm
pacman -S --noconfirm --needed \
    base-devel meson ninja python-mako python-yaml python-packaging \
    libdrm wayland wayland-protocols libx11 libxcb libxshmfence libxrandr libxext libxfixes libxxf86vm libglvnd \
    systemd-libs zstd expat zlib xcb-proto xorgproto vulkan-headers \
    lib32-gcc-libs lib32-glibc lib32-libdrm lib32-wayland lib32-libx11 lib32-libxcb lib32-libxshmfence \
    lib32-libxrandr lib32-libxext lib32-libxfixes lib32-libxxf86vm lib32-libglvnd \
    lib32-systemd lib32-zstd lib32-expat lib32-zlib

# Paths inside the provider root; pressure-vessel/FEX resolve them relative to it,
# matching the provider's freedreno_icd.{x86_64,x86}.json.
build_venus /tmp/build-x86_64 lib /tmp/dest-x86_64
build_venus /tmp/build-i386 lib32 /tmp/dest-i386 --cross-file /scripts/i386-linux-gnu.ini
# GL: patched zink over the provider's own GL files of the same names
build_gl /tmp/build-gl-x86_64 lib /tmp/dest-gl-x86_64
build_gl /tmp/build-gl-i386 lib32 /tmp/dest-gl-i386 --cross-file /scripts/i386-linux-gnu.ini

p=/out${FEX_PROVIDER}
install -D -m 0755 /tmp/dest-x86_64/usr/lib/libvulkan_virtio.so "$p/usr/lib/libvulkan_virtio.so"
install -D -m 0644 /tmp/dest-x86_64/usr/share/vulkan/icd.d/virtio_icd.x86_64.json \
    "$p/usr/share/vulkan/icd.d/virtio_icd.x86_64.json"
install -D -m 0755 /tmp/dest-i386/usr/lib32/libvulkan_virtio.so "$p/usr/lib32/libvulkan_virtio.so"
install -D -m 0644 /tmp/dest-i386/usr/share/vulkan/icd.d/virtio_icd.x86.json \
    "$p/usr/share/vulkan/icd.d/virtio_icd.x86.json"
install_gl /tmp/dest-gl-x86_64 lib "$p"
install_gl /tmp/dest-gl-i386 lib32 "$p"

# Same toolchain/glibc as the provider (pressure-vessel runs games on the provider's glibc).
gcc -O2 -Wall -Wextra -Werror -fPIC -shared -Wl,-soname,fault-report.so -Wl,--build-id=sha1 \
    -o /tmp/fault-report.so /scripts/fault-report.c
install -D -m 0644 -s /tmp/fault-report.so /out/usr/lib/steamac/x86_64/fault-report.so

mkdir -p /work/bin
gcc -O2 -Wall -o /work/bin/vkprobe-x86_64 /scripts/vkprobe.c -ldl
gcc -m32 -O2 -Wall -o /work/bin/vkprobe-i386 /scripts/vkprobe.c -ldl
gcc -O1 -g -Wall -o /work/bin/fault-report-test /scripts/fault-report-test.c
pacman -Q glibc lib32-glibc gcc-libs lib32-gcc-libs libdrm lib32-libdrm wayland lib32-wayland libxcb lib32-libxcb \
    libxext lib32-libxext libxfixes lib32-libxfixes libxxf86vm lib32-libxxf86vm libglvnd lib32-libglvnd \
    systemd-libs lib32-systemd zstd lib32-zstd expat lib32-expat \
    meson python-mako vulkan-headers > /work/packages-x86.txt
gcc --version | head -1 > /work/toolchain-x86.txt
