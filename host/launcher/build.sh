#!/usr/bin/env bash
# Build the steamac-vm launcher (release), sign it with the hypervisor entitlement and
# install it as work/out/steamac-vm. Also fetches the pinned zstd decoder sources (compiled in),
# gvproxy and desync into work/out/host/bin and assembles work/out/FX Steam Launcher.app
# (bundle.sh; skipped with STEAMAC_NO_BUNDLE=1 or when the kernel/initramfs/layer images are
# not built yet). Debug symbols for crash reports go to work/out/dSYMs (see dist.sh).
#
# Localizations (English source, ru, zh-Hans): the compiler extracts the UI strings
# (-emit-localized-strings: SwiftUI literals, String(localized:)) and l10n.py syncs them into
# Localizable.xcstrings (new keys added, removed ones marked stale, as Xcode does: commit the
# catalog with the code), reports untranslated keys and compiles both catalogs to
# work/out/<lang>.lproj (next to the dev binary) and the .app's Resources (bundle.sh).
#
# libkrun (v1.19.6 C API, built with GPU=1 INPUT=1 BLK=1 NET=1) is taken from
# $KRUN_PREFIX (default: work/out/host, produced by host/libkrun). The binary's rpath is
# @executable_path/host/lib (= work/out/host/lib) first, then $KRUN_PREFIX/lib.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT="$ROOT/work/out"
KRUN_PREFIX="${KRUN_PREFIX:-$OUT/host}"

for h in libkrun.h libkrun_display.h libkrun_input.h; do
    [[ -f "$KRUN_PREFIX/include/$h" ]] || { echo "missing $KRUN_PREFIX/include/$h (build host/libkrun first or set KRUN_PREFIX)" >&2; exit 1; }
done
ls "$KRUN_PREFIX"/lib/libkrun*.dylib >/dev/null 2>&1 || { echo "missing $KRUN_PREFIX/lib/libkrun*.dylib" >&2; exit 1; }

# Info.plist embedded into the binary (-sectcreate) and copied into the .app by bundle.sh, plus the
# build identity crash reports use (CrashReporting): SteamacGitCommit (release name
# es.fxgam.steamac@<CFBundleShortVersionString>+<commit>), SteamacMVKPatchRevision (MoltenVK
# MVK_PATCH_REVISION, from $KRUN_PREFIX/MOLTENVK.txt) and SteamacKosmicKrispRevision (patch revision
# from $KRUN_PREFIX/KOSMICKRISP.txt, when KosmicKrisp is built).
PLIST="$HERE/.build/Info.plist"
mkdir -p "$HERE/.build"
commit=$(git -C "$ROOT" rev-parse --short=10 HEAD 2>/dev/null || echo unknown)
mvk_rev=$(sed -n 's/.*MVK_PATCH_REVISION (\([0-9a-f]\{8\}\).*/\1/p' "$KRUN_PREFIX/MOLTENVK.txt" 2>/dev/null | head -1)
kk_rev=
if [[ -f "$KRUN_PREFIX/lib/libvulkan_kosmickrisp.dylib" ]]; then
    kk_rev=$(sed -n 's/^patch revision: *\([0-9a-f]\{8\}\).*/\1/p' "$KRUN_PREFIX/KOSMICKRISP.txt" 2>/dev/null | head -1)
fi
cp "$HERE/Info.plist" "$PLIST.new"
/usr/libexec/PlistBuddy -c "Add :SteamacGitCommit string $commit" "$PLIST.new"
[[ -z $mvk_rev ]] || /usr/libexec/PlistBuddy -c "Add :SteamacMVKPatchRevision string 0x$mvk_rev" "$PLIST.new"
[[ -z $kk_rev ]] || /usr/libexec/PlistBuddy -c "Add :SteamacKosmicKrispRevision string 0x$kk_rev" "$PLIST.new"

SWIFT_FLAGS=(
    -c release
    --package-path "$HERE"
    --scratch-path "$HERE/.build"
    -Xcc "-I$KRUN_PREFIX/include"
    -Xlinker "-L$KRUN_PREFIX/lib"
    -Xlinker -rpath -Xlinker @executable_path/host/lib
    -Xlinker -rpath -Xlinker "$KRUN_PREFIX/lib"
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$PLIST"
    -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$HERE/.build/stringsdata"
)

"$HERE/fetch-zstd.sh"
BIN="$(swift build "${SWIFT_FLAGS[@]}" --show-bin-path)/steamac-vm"
# SwiftPM does not track the -sectcreate input: relink when the plist changed.
if cmp -s "$PLIST.new" "$PLIST"; then
    rm -f "$PLIST.new"
else
    mv -f "$PLIST.new" "$PLIST"
    rm -f "$BIN"
fi
swift build "${SWIFT_FLAGS[@]}"

python3 "$HERE/l10n.py" sync "$HERE/.build/stringsdata"
python3 "$HERE/l10n.py" check
python3 "$HERE/l10n.py" compile "$HERE/.build/l10n"

# Debug files for crash reports (dist.sh uploads them with sentry-cli): the launcher's dSYM and
# dSYMs of the libraries the .app bundles (their builds carry no DWARF, so these hold the symbol
# tables), matched to the binaries by Mach-O UUID.
DSYMS="$OUT/dSYMs"
rm -rf "$DSYMS.new"
mkdir -p "$DSYMS.new"
dsymutil "$BIN" -o "$DSYMS.new/steamac-vm.dSYM"
for lib in libkrun.1.dylib libvirglrenderer.1.dylib libMoltenVK.dylib libvulkan_kosmickrisp.dylib; do
    [[ -f "$KRUN_PREFIX/lib/$lib" ]] || continue
    dsymutil "$KRUN_PREFIX/lib/$lib" -o "$DSYMS.new/$lib.dSYM" 2>&1 | grep -v 'no debug symbols in executable' >&2 || true
done
rm -rf "$DSYMS"
mv "$DSYMS.new" "$DSYMS"

mkdir -p "$OUT"
tmp="$OUT/.steamac-vm.$$"
cp -f "$BIN" "$tmp"

# Make the libkrun reference rpath-relative even if the dylib's install name is absolute.
ref=$(otool -L "$tmp" | awk '/libkrun[.0-9]*\.dylib/ {print $1; exit}')
[[ -n "$ref" ]] || { echo "steamac-vm does not link libkrun?" >&2; exit 1; }
if [[ "$ref" != @rpath/* ]]; then
    install_name_tool -change "$ref" "@rpath/$(basename "$ref")" "$tmp"
fi

codesign --force --sign - --entitlements "$HERE/steamac-vm.entitlements" "$tmp"
mv -f "$tmp" "$OUT/steamac-vm"
# Bundle.main of the bare dev binary resolves its .lproj directories next to it.
for lproj in "$HERE/.build/l10n"/*.lproj; do
    rm -rf "$OUT/$(basename "$lproj")"
    cp -R "$lproj" "$OUT/"
done

"$HERE/fetch-gvproxy.sh"
"$HERE/fetch-desync.sh"

echo "built $OUT/steamac-vm"
otool -L "$OUT/steamac-vm" | awk '/libkrun/'
codesign -d --entitlements - "$OUT/steamac-vm" 2>&1 | grep -E 'hypervisor|library-validation' || true

if [[ "${STEAMAC_NO_BUNDLE:-}" == 1 ]]; then
    echo "STEAMAC_NO_BUNDLE=1: app bundle skipped"
elif [[ -f "$OUT/Image" && -f "$OUT/initramfs.cpio.gz" && -f "$OUT/steamac-layer.img" ]]; then
    KRUN_PREFIX="$KRUN_PREFIX" "$HERE/bundle.sh" "$OUT/steamac-vm"
else
    echo "app bundle skipped: build Image, initramfs.cpio.gz and steamac-layer.img first" >&2
fi
