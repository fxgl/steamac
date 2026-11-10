#!/usr/bin/env bash
# The DXMT source offer: host/dxmt/pin.env names a tarball whose SHA-256 matches, host/dxmt/patches/ apply on it
# in order, they are exactly scripts/export-dxmt-patches.sh's export of the pinned StonkGuy/dxmt commit (same
# patch files, and base + patches = that commit's tree), and a source archive built by scripts/gpl-sources.sh
# carries all three pieces. DXMT_PIN_OFFLINE=1 skips the fork comparison (no network).
#   scripts/test/dxmt-source-pin.sh [path to a gpl-sources tar to inspect]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
. "$ROOT/host/dxmt/pin.env"
tmp=$(mktemp -d "$ROOT/work/scratch.XXXXXX" 2>/dev/null || { mkdir -p "$ROOT/work"; mktemp -d "$ROOT/work/scratch.XXXXXX"; })
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

[[ $DXMT_COMMIT =~ ^[[:xdigit:]]{40}$ ]] || fail 'DXMT_COMMIT is not a full commit id'
[[ $DXMT_URL == *"$DXMT_COMMIT"* ]] || fail 'DXMT_URL does not name DXMT_COMMIT'
tarball="$ROOT/work/cache/dxmt/dxmt-$DXMT_COMMIT.tar.gz"
mkdir -p "$(dirname "$tarball")"
[[ -f $tarball ]] || curl -fsSL --retry 3 -o "$tarball" "$DXMT_URL"
echo "$DXMT_SHA256  $tarball" | shasum -a 256 -c - >/dev/null || fail 'tarball SHA-256 differs from pin.env'
echo 'ok: pinned tarball checksum'

mkdir "$tmp/src"
tar -xzf "$tarball" -C "$tmp/src" --strip-components=1
# its own repository: `git apply` inside this checkout's work/ would resolve paths against this repository
git -C "$tmp/src" init -q
n=0
for p in "$ROOT"/host/dxmt/patches/*.patch; do
    git -C "$tmp/src" apply "$p" || fail "$(basename "$p") does not apply on the pinned DXMT"
    n=$((n + 1))
done
echo "ok: $n patches apply in order on the pinned source"
[[ -f $tmp/src/COPYING.LIB && -f $tmp/src/src/airconv/airconv_public.h ]] || fail 'pinned source lacks the licence or airconv'

if [[ ${DXMT_PIN_OFFLINE:-0} != 1 ]]; then
    [[ $DXMT_FORK_COMMIT =~ ^[[:xdigit:]]{40}$ ]] || fail 'DXMT_FORK_COMMIT is not a full commit id'
    "$ROOT/scripts/export-dxmt-patches.sh" "$tmp/export" >/dev/null || fail 'cannot export the pinned fork commit'
    diff -r "$tmp/export" "$ROOT/host/dxmt/patches" >/dev/null \
        || fail 'host/dxmt/patches/ differs from the export of DXMT_FORK_COMMIT (run scripts/export-dxmt-patches.sh)'
    echo 'ok: host/dxmt/patches/ is the export of the pinned fork commit'
    repo=${DXMT_FORK_CHECKOUT:-$ROOT/work/cache/dxmt-fork.git}
    mkdir "$tmp/fork"
    git -C "$repo" archive "$DXMT_FORK_COMMIT" | tar -x -C "$tmp/fork"
    # submodule directories are empty in both (the tarball carries no submodules either)
    diff -r -x .git "$tmp/fork" "$tmp/src" >"$tmp/tree.diff" 2>&1 || { head -5 "$tmp/tree.diff" >&2; fail 'pinned source + patches differs from the fork commit'; }
    echo 'ok: pinned source + patches = the fork commit'
fi

# Exercise the source-offer block without downloading anything or building a release.
# Keep Wine's upstream source pin distinct from the prebuilt ARM64EC Wine tools.
python3 - "$ROOT" "$tmp" <<'PY'
from pathlib import Path
import os
import re
import shutil
import subprocess
import sys

root, stage = map(Path, sys.argv[1:])
build = (root / "host/dxmt/build.sh").read_text()
pins = dict(re.findall(r"^(WINE_ARM64EC(?:_SOURCE)?_(?:URL|SHA256))=(\S+)$", build, re.M))
assert pins["WINE_ARM64EC_URL"].endswith("/wine-11.2/wine-11.2.tar.gz")
assert pins["WINE_ARM64EC_SOURCE_URL"] == "https://dl.winehq.org/wine/source/11.x/wine-11.2.tar.xz"
for key in ("WINE_ARM64EC_SHA256", "WINE_ARM64EC_SOURCE_SHA256"):
    assert re.fullmatch(r"[0-9a-f]{64}", pins[key]), key
assert 'fetch_file "$WINE_ARM64EC_SOURCE_URL" "$WINE_ARM64EC_SOURCE_SHA256" "$cache/wine-11.2.tar.xz"' in build
repo = stage / "repo/host/dxmt"
repo.mkdir(parents=True)
for name in ("build.sh", "pin.env"):
    shutil.copyfile(root / "host/dxmt" / name, repo / name)
offer = (root / "scripts/gpl-sources.sh").read_text()
block = offer[offer.index("dxmt_notes="):offer.index("# Resolve busybox-static")]
script = 'set -euo pipefail\ncopy_source() { printf "%s|%s|%s\\n" "$2" "$3" "$4"; }\n'
result = subprocess.run(["bash", "-c", script + block + '\nprintf "%s\\n" "$dxmt_notes"'],
                        env=dict(os.environ, ROOT=str(root), ST=str(stage), REF="HEAD"),
                        text=True, capture_output=True)
assert result.returncode == 0, result.stderr
expected = "|".join((pins["WINE_ARM64EC_SOURCE_URL"], pins["WINE_ARM64EC_SOURCE_SHA256"], "wine-11.2.tar.xz"))
assert expected in result.stdout.splitlines(), result.stdout
assert "sources/wine-11.2.tar.xz" in result.stdout
print("ok: Wine 11.2 build/source pins and offline source offer agree")
PY

if [[ -n ${1:-} ]]; then
    listing=$(tar -tf "$1")
    for want in "sources/dxmt-$DXMT_COMMIT.tar.gz" sources/wine-11.2.tar.xz repo/host/dxmt/pin.env repo/host/dxmt/patches/ repo/wmtr/Makefile README.txt; do
        grep -qF "$want" <<<"$listing" || fail "$1 lacks $want"
    done
    tar -xOf "$1" README.txt | grep -q "dxmt-$DXMT_COMMIT" || fail 'README.txt does not describe the DXMT source'
    echo 'ok: source archive carries DXMT source, patches, pin and wmtr'
fi
