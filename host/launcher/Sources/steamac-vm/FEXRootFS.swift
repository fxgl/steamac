import Foundation

/// Official FEX userspace installer shared with the Bazzite image.
enum FEXRootFS {
    static let installer = #"""
#!/usr/bin/env bash
# Install the official FEX Fedora rootfs outside the immutable system image.
set -euo pipefail
base="$HOME/.local/share/steamac"
root="$base/fex-rootfs"
if [[ -x "$root/usr/bin/env" && -x "$root/usr/bin/sh" ]]; then exit 0; fi
mkdir -p "$base"
exec 9>"$base/fex-rootfs.lock"
flock 9
if [[ -x "$root/usr/bin/env" && -x "$root/usr/bin/sh" ]]; then exit 0; fi
stage=$(mktemp -d "$base/.fex-rootfs.XXXXXX")
trap 'rm -rf "$stage"' EXIT
curl --fail --location --retry 3 --output "$stage/rootfs.sqsh" \
    https://rootfs.fex-emu.gg/Fedora_44/2026-08-11/Fedora_44.sqsh
# Verify the XXH3 digest published in FEX's RootFS_links.json.
python3 - "$stage/rootfs.sqsh" <<'VERIFY'
import ctypes, ctypes.util, mmap, sys
lib = ctypes.CDLL(ctypes.util.find_library("xxhash"))
lib.XXH3_64bits.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
lib.XXH3_64bits.restype = ctypes.c_uint64
with open(sys.argv[1], "r+b") as f, mmap.mmap(f.fileno(), 0) as data:
    buf = (ctypes.c_char * len(data)).from_buffer(data)
    actual = lib.XXH3_64bits(buf, len(data))
    del buf
    if actual != 0xfda4aaeab0fa69ba:
        raise SystemExit("FEX rootfs checksum mismatch")
VERIFY
unsquashfs -no-progress -d "$stage/root" "$stage/rootfs.sqsh"
test -x "$stage/root/usr/bin/env"
test -x "$stage/root/usr/bin/sh"
if [[ -e "$root" ]]; then echo "Refusing to replace incomplete rootfs: $root" >&2; exit 1; fi
mv "$stage/root" "$root"
"""#
}
