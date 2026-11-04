#!/usr/bin/env bash
# Fetch the pinned ENet sources into Sources/CEnet/enet and its headers into Sources/CEnet/include/enet
# (both gitignored), compiled into the launcher by the CEnet target (the committed
# include/module.modulemap exports enet.h to Swift). The Moonlight streaming host's control stream
# (GameStream port 47999, Stream/StreamControl.swift) is ENet over UDP; the pin is the fork
# moonlight-common-c builds its client from (cgutman/enet, branch moonlight; MIT), so both ends
# speak the same ENet.
# Idempotent: re-downloads only if the unpacked version stamp does not match.
set -euo pipefail

COMMIT=aca87840b57f045a1f7f9299e4b1b9b8e2a5e2f1
SHA256=6bb1a151e6d21e1756baeff5a95eaf85a5b6731aeda6d0bc255651192ba4a32d   # enet-$COMMIT.tar.gz
URL="https://github.com/cgutman/enet/archive/${COMMIT}.tar.gz"

HERE=$(cd "$(dirname "$0")" && pwd)
DEST="$HERE/Sources/CEnet/enet"
HEADERS="$HERE/Sources/CEnet/include/enet"
STAMP="$DEST/VERSION"

if [[ "$(cat "$STAMP" 2>/dev/null)" == "$COMMIT $SHA256" && -f "$HEADERS/enet.h" ]]; then
    echo "enet $COMMIT already at $DEST"
    exit 0
fi

tmp="$HERE/Sources/CEnet/.enet.$$"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp"
curl -fsSL --retry 3 -o "$tmp/enet.tar.gz" "$URL"
got=$(shasum -a 256 "$tmp/enet.tar.gz" | awk '{print $1}')
if [[ "$got" != "$SHA256" ]]; then
    echo "enet checksum mismatch: got $got want $SHA256" >&2
    exit 1
fi
tar -xzf "$tmp/enet.tar.gz" -C "$tmp"
src="$tmp/enet-$COMMIT"
mkdir -p "$tmp/out"
mv "$src/LICENSE" "$src/callbacks.c" "$src/compress.c" "$src/host.c" "$src/list.c" \
    "$src/packet.c" "$src/peer.c" "$src/protocol.c" "$src/unix.c" "$tmp/out/"
echo "$COMMIT $SHA256" > "$tmp/out/VERSION"
rm -rf "$DEST" "$HEADERS"
mv "$src/include/enet" "$HEADERS"
mv "$tmp/out" "$DEST"
echo "enet $COMMIT -> $DEST, $HEADERS"
