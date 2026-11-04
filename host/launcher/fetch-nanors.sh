#!/usr/bin/env bash
# Fetch the pinned nanors sources into Sources/CNanors/nanors (gitignored), compiled into the
# launcher by the CNanors target (include/cnanors.h is its Swift-facing API). The Moonlight streaming
# host's video and audio FEC (Reed-Solomon over GF(2^8)) must produce the parity Moonlight decodes;
# the pin is the nanors commit moonlight-common-c builds its client from (MIT).
# Idempotent: re-downloads only if the unpacked version stamp does not match.
set -euo pipefail

COMMIT=a9b1636f9c98dbfdd0daeaf6982ccd24d1c30f29
SHA256=cb12a4598d5a99f6bcc4633b684fdac7a87c7d627a81d986080840c63fd2db0f   # nanors-$COMMIT.tar.gz
URL="https://github.com/sleepybishop/nanors/archive/${COMMIT}.tar.gz"

HERE=$(cd "$(dirname "$0")" && pwd)
DEST="$HERE/Sources/CNanors/nanors"
STAMP="$DEST/VERSION"

if [[ "$(cat "$STAMP" 2>/dev/null)" == "$COMMIT $SHA256" ]]; then
    echo "nanors $COMMIT already at $DEST"
    exit 0
fi

tmp="$HERE/Sources/CNanors/.nanors.$$"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp"
curl -fsSL --retry 3 -o "$tmp/nanors.tar.gz" "$URL"
got=$(shasum -a 256 "$tmp/nanors.tar.gz" | awk '{print $1}')
if [[ "$got" != "$SHA256" ]]; then
    echo "nanors checksum mismatch: got $got want $SHA256" >&2
    exit 1
fi
tar -xzf "$tmp/nanors.tar.gz" -C "$tmp"
src="$tmp/nanors-$COMMIT"
mkdir -p "$tmp/out/deps"
mv "$src/LICENSE" "$src/rs.c" "$src/rs.h" "$tmp/out/"
mv "$src/deps/obl" "$tmp/out/deps/"
echo "$COMMIT $SHA256" > "$tmp/out/VERSION"
rm -rf "$DEST"
mv "$tmp/out" "$DEST"
echo "nanors $COMMIT -> $DEST"
