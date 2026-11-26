#!/bin/bash
# Temporary test: give the VM the /sys/class/dmi/id files a firmware-booted machine has
# (host Mac's real vendor/model), so Wine's SMBIOS isn't blank. Undo: sudo bash ~/dmi-test.sh undo (or reboot).
set -euo pipefail
F=/run/steamac-fakeclass
if [ "${1:-}" = undo ]; then
  umount -R /sys/class && umount -R "$F" && rmdir "$F" && echo "undone"; exit
fi
[ -e /sys/class/dmi ] && { echo "/sys/class/dmi already exists; nothing to do"; exit 1; }
mkdir -p "$F"; mount -t tmpfs -o mode=755 steamac-fakeclass "$F"
for d in /sys/class/*; do n=${d##*/}; mkdir "$F/$n"; mount --bind "$d" "$F/$n"; done
I="$F/dmi/id"; mkdir -p "$I"
w() { printf '%s\n' "$2" > "$I/$1"; chmod 444 "$I/$1"; }
w sys_vendor "Apple Inc.";     w product_name "MacBook Pro"; w product_version "Mac17,2"
w product_family "MacBook Pro"; w product_sku "Mac17,2"
w board_vendor "Apple Inc.";   w board_name "Mac17,2";       w board_version "1.0"
w bios_vendor "Apple Inc.";    w bios_version "20457.41.3";   w bios_date "11/01/2026"
w chassis_vendor "Apple Inc."; w chassis_type "10";           w chassis_version "Mac17,2"
mount --rbind "$F" /sys/class
ls /sys/class/dmi/id && cat /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/board_name && echo "applied"
