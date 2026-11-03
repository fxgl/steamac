#!/bin/bash
# Step 50 (builder container): inspect the three outputs read-only.
#   - GPT table, partition names/GUIDs, filesystem types + labels/UUIDs
#   - esp / efi-X / var-X content (A/B state, bootconf, partsets, /etc upper)
#   - rootfs-A sha256 still equals the signed OTA image (pristine check)
#   - initramfs listing, layer listing (loop-mounted erofs)
set -euo pipefail
. /src/scripts/config.env
. /src/scripts/steps/lib.sh

IMG=/work/out/steamos.img
LAYER=/work/out/steamac-layer.img
INITRD=/work/out/initramfs.cpio.gz
LOOPS=(); MNTS=()
cleanup() {
    for ((i = ${#MNTS[@]} - 1; i >= 0; i--)); do umount "${MNTS[i]}" 2>/dev/null || :; done
    for l in "${LOOPS[@]}"; do losetup -d "$l" 2>/dev/null || :; done
}
trap cleanup EXIT
hdr() { echo; echo "===== $*"; }

hdr "GPT ($IMG)"
sgdisk -p "$IMG"
for n in 1 2 3 4 5 6 7 8; do
    sgdisk -i "$n" "$IMG" | awk -v n="$n" '/Partition GUID code/{t=$4} /unique GUID/{u=$4} /Partition name/{sub(/^Partition name: /,""); nm=$0} END{printf "  %s %-10s type=%s partuuid=%s\n", n, nm, t, u}'
done

declare -A DEV
names=()
while read -r num start end; do
    l=$(newloop -r --offset $((start * 512)) --sizelimit $(((end - start + 1) * 512)) "$IMG")
    LOOPS+=("$l")
    nm=$(sgdisk -i "$num" "$IMG" | sed -n "s/^Partition name: '\(.*\)'/\1/p")
    DEV[$nm]=$l; names+=("$nm")
done < <(sgdisk -p "$IMG" | awk '/^ +[0-9]+ /{print $1, $2, $3}')

hdr "filesystems"
for nm in "${names[@]}"; do
    printf "  %-9s %s\n" "$nm" "$(blkid -o export "${DEV[$nm]}" | grep -E '^(TYPE|LABEL|UUID)=' | tr '\n' ' ')"
done
dumpe2fs -h "${DEV[home]}" 2>/dev/null | grep -E 'features|Reserved block count|Character encoding' | sed 's/^/  home: /'

mnt() { mkdir -p "$2"; mount "${@:3}" "$1" "$2"; MNTS+=("$2"); }
M=$(mktemp -d)
for nm in esp efi-A efi-B var-A var-B; do mnt "${DEV[$nm]}" "$M/$nm" -o ro; done

hdr "esp"
(cd "$M/esp" && find . -type f | sort)
echo "--- esp:/steamac/bootenv"; cat "$M/esp/steamac/bootenv"
echo "--- esp:/SteamOS/conf/A.conf"; cat "$M/esp/SteamOS/conf/A.conf"
for s in A B; do
    hdr "efi-$s partsets"
    for f in "$M/efi-$s"/SteamOS/partsets/*; do echo "[${f##*/}]"; sed 's/^/  /' "$f"; done
done
for s in A B; do
    hdr "var-$s"
    (cd "$M/var-$s" && find . -path ./lost+found -prune -o -print | sort | sed 's/^/  /')
    echo "  shadow steamos entry: $(grep '^steamos:' "$M/var-$s/lib/overlays/etc/upper/shadow" | cut -d: -f1,2 | cut -c1-24)..."
done

hdr "rootfs-A pristine check (sha256 of the partition == signed OTA rootfs)"
sum=$(sha256sum < "${DEV[rootfs-A]}" | cut -d' ' -f1)
echo "  rootfs-A $sum"
[[ $sum == "$STEAMOS_ROOTFS_SHA256" ]] && echo "  OK: matches manifest.raucm sha256" || { echo "  MISMATCH (expected $STEAMOS_ROOTFS_SHA256)"; exit 1; }
btrfs inspect-internal dump-super "${DEV[rootfs-B]}" | grep -E '^(fsid|label)' | sed 's/^/  rootfs-B /'
btrfs inspect-internal dump-super "${DEV[rootfs-A]}" | grep -E '^(fsid|label)' | sed 's/^/  rootfs-A /'

hdr "initramfs ($INITRD)"
zcat "$INITRD" | cpio -t --quiet 2>/dev/null | grep -v '^bin/.' | sort | tr '\n' ' '; echo
echo "  applets: $(zcat "$INITRD" | cpio -t --quiet 2>/dev/null | grep -c '^bin/.')"
T=$(mktemp -d); (cd "$T" && zcat "$INITRD" | cpio -id --quiet)
cmp "$T/init" /src/guest/initramfs/init && echo "  /init == guest/initramfs/init"
file "$T/bin/busybox" | sed 's/^/  /'
rm -rf "$T"

hdr "layer ($LAYER)"
L=$(newloop -r "$LAYER"); LOOPS+=("$L")
mnt "$L" "$M/layer" -t erofs -o ro
for manager in system user; do
    conf=usr/lib/systemd/$manager.conf.d/99-steamac-vcpu-affinity.conf
    cmp "/src/guest/layer/$conf" "$M/layer/$conf"
    echo "  $conf matches guest layer source"
done
(cd "$M/layer" && find . -not -type d | sort | sed 's/^/  /')
echo "  $(cat "$M/layer/usr/lib/steamac/layer-release")"
