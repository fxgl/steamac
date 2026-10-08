#!/usr/bin/env bash
# Assemble work/out/FX Steam Launcher.app (called by build.sh with the freshly built binary):
#   Contents/MacOS/steamac-vm           launcher, rpath @executable_path/../Frameworks only
#   Contents/Frameworks/*.dylib         libkrun, libvirglrenderer, libMoltenVK, libvulkan_kosmickrisp
#                                       (when built: host/kosmickrisp, macOS 26+) + their non-system
#                                       dependencies (libepoxy), install names @rpath/<name>
#   Contents/Resources/                 gvproxy, Image, initramfs.cpio.gz, steamac-layer.img,
#                                       desync + steamdeck-images.pem (Valve RAUC CA) for
#                                       "Create New Disk…", generated licenses/ notices,
#                                       Assets.car + AppIcon.icns (app icon, see below)
# The SteamOS disk is not bundled (Settings > Advanced "Disk image" / "Create New Disk…"). Ad-hoc
# signed with the hypervisor + disable-library-validation entitlements. Built in a temp dir,
# then moved in place.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT="$ROOT/work/out"
KRUN_PREFIX="${KRUN_PREFIX:-$OUT/host}"
BIN="${1:?usage: bundle.sh <steamac-vm binary>}"
NAME="FX Steam Launcher"
APP="$OUT/$NAME.app"
STAGE="$OUT/.bundle.$$"
TMP="$STAGE/$NAME.app"

# Fail before notices/staging (and before touching an existing app).
python3 "$ROOT/scripts/guest-artifacts.py" check-release
for f in Image initramfs.cpio.gz steamac-layer.img host/bin/gvproxy host/bin/desync; do
    [[ -f "$OUT/$f" ]] || { echo "bundle.sh: missing $OUT/$f" >&2; exit 1; }
done
"$HERE/licenses.sh"  # fail before modifying the existing app if a notice is unavailable
[[ -f "$OUT/licenses/THIRD-PARTY-NOTICES.txt" ]] || { echo 'bundle.sh: missing notices index' >&2; exit 1; }

rm -rf "$STAGE"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$TMP/Contents/MacOS" "$TMP/Contents/Frameworks" "$TMP/Contents/Resources"

# build.sh's Info.plist carries the build identity crash reports use (SteamacGitCommit, ...).
PLIST="$HERE/.build/Info.plist"
[[ -f $PLIST ]] || PLIST="$HERE/Info.plist"
cp "$PLIST" "$TMP/Contents/Info.plist"
# Lets the app find the repo's work/out/steamos.img as its default disk when moved elsewhere.
/usr/libexec/PlistBuddy -c "Add :SteamacBuildOut string $OUT" "$TMP/Contents/Info.plist"
# Release defaults (AppBundle.releaseDefaults): SSH off, generated guest password, no default
# password on created disks. The dev launcher work/out/steamac-vm (embedded Info.plist) has none.
/usr/libexec/PlistBuddy -c "Add :SteamacReleaseDefaults bool true" "$TMP/Contents/Info.plist"
printf 'APPL????' > "$TMP/Contents/PkgInfo"

exe="$TMP/Contents/MacOS/steamac-vm"
cp "$BIN" "$exe"
chmod u+w "$exe"

is_system() { [[ "$1" == /usr/lib/* || "$1" == /System/* ]]; }

# Copy a dylib (and, recursively, its non-system dependencies) into Frameworks.
FW="$TMP/Contents/Frameworks"
copy_lib() {
    local src="$1" name
    name=$(basename "$src")
    [[ -f "$FW/$name" ]] && return 0
    cp -L "$src" "$FW/$name"
    chmod u+w "$FW/$name"
    install_name_tool -id "@rpath/$name" "$FW/$name" 2>/dev/null
    local dep
    while read -r dep; do
        is_system "$dep" && continue
        local base
        base=$(basename "$dep")
        if [[ "$dep" == @rpath/* ]]; then
            [[ "$base" == "$name" ]] && continue
            [[ -f "$KRUN_PREFIX/lib/$base" ]] || { echo "bundle.sh: $name needs $dep, not in $KRUN_PREFIX/lib" >&2; exit 1; }
            copy_lib "$KRUN_PREFIX/lib/$base"
        else
            [[ -f "$dep" ]] || { echo "bundle.sh: $name needs $dep (not found)" >&2; exit 1; }
            install_name_tool -change "$dep" "@rpath/$base" "$FW/$name" 2>/dev/null
            copy_lib "$dep"
        fi
    done < <(otool -L "$FW/$name" | awk 'NR > 1 {print $1}')
    # Dependencies resolve next to each other. otool -l prints an LC_RPATH entry as
    # "path @loader_path (offset 12)"; adding an existing one is an error.
    if ! otool -l "$FW/$name" | awk '$1 == "path" && $2 == "@loader_path" { found = 1 } END { exit !found }'; then
        install_name_tool -add_rpath @loader_path "$FW/$name"
    fi
}

# virglrenderer opens the Vulkan driver at runtime (@rpath, Settings > Advanced "Vulkan driver"):
# MoltenVK always, KosmicKrisp when it was built (macOS 26+ build hosts).
libs=(libkrun.1.dylib libvirglrenderer.1.dylib libMoltenVK.dylib)
[[ -f "$KRUN_PREFIX/lib/libvulkan_kosmickrisp.dylib" ]] && libs+=(libvulkan_kosmickrisp.dylib)
for lib in "${libs[@]}"; do
    copy_lib "$KRUN_PREFIX/lib/$lib"
done

# The executable: only the bundle's Frameworks on its rpath.
while read -r rp; do
    install_name_tool -delete_rpath "$rp" "$exe" 2>/dev/null   # (re-signed below)
done < <(otool -l "$exe" | awk '/cmd LC_RPATH/ {getline; getline; print $2}')
install_name_tool -add_rpath @executable_path/../Frameworks "$exe" 2>/dev/null
while read -r dep; do
    is_system "$dep" && continue
    [[ "$dep" == @rpath/* ]] || { echo "bundle.sh: steamac-vm links $dep" >&2; exit 1; }
    [[ -f "$FW/$(basename "$dep")" ]] || { echo "bundle.sh: $dep not bundled" >&2; exit 1; }
done < <(otool -L "$exe" | awk 'NR > 1 {print $1}')

# Resources (APFS clones where possible; the layer and kernel are rebuilt by the guest scripts).
for f in Image initramfs.cpio.gz steamac-layer.img; do
    cp -c "$OUT/$f" "$TMP/Contents/Resources/$f" 2>/dev/null || cp "$OUT/$f" "$TMP/Contents/Resources/$f"
    cp "$OUT/$f.inputs.json" "$TMP/Contents/Resources/$f.inputs.json"
done
cp "$OUT/host/bin/gvproxy" "$TMP/Contents/Resources/gvproxy"
cp "$OUT/host/bin/desync" "$TMP/Contents/Resources/desync"
chmod 755 "$TMP/Contents/Resources/gvproxy" "$TMP/Contents/Resources/desync"
cp "$ROOT/scripts/keys/steamdeck-images.pem" "$TMP/Contents/Resources/steamdeck-images.pem"
mkdir -p "$TMP/Contents/Resources/licenses"
cp -R "$OUT/licenses/." "$TMP/Contents/Resources/licenses/"
# Localizations (e.g. zh-Hans.lproj/Localizable.strings + InfoPlist.strings): plain copy,
# no Xcode build step needed.
for lproj in "$HERE"/Resources/*.lproj; do
    [[ -d "$lproj" ]] || continue
    cp -R "$lproj" "$TMP/Contents/Resources/"
done

# App icon: AppIcon.icon (Icon Composer document) compiled by Xcode 26's actool into Assets.car
# (layered Liquid Glass icon for macOS 26, pre-rendered squircle renditions for macOS 15) and an
# AppIcon.icns fallback; Info.plist names them (CFBundleIconName / CFBundleIconFile = AppIcon).
if ! log=$(xcrun actool "$HERE/AppIcon.icon" --compile "$TMP/Contents/Resources" --platform macosx \
        --minimum-deployment-target 15.0 --app-icon AppIcon \
        --output-partial-info-plist "$STAGE/icon-info.plist" 2>&1) \
        || [[ ! -f "$TMP/Contents/Resources/Assets.car" || ! -f "$TMP/Contents/Resources/AppIcon.icns" ]]; then
    echo "$log" >&2
    echo "bundle.sh: actool did not compile $HERE/AppIcon.icon (needs Xcode 26 or newer)" >&2
    exit 1
fi
rm -f "$STAGE/icon-info.plist"

# Newer build hosts must not silently raise the bundle's minimum macOS version.
# KosmicKrisp is the only exception: Settings gates its runtime dlopen on macOS 26+.
python3 - "$TMP" <<'PY'
from pathlib import Path
import plistlib
import re
import subprocess
import sys

app = Path(sys.argv[1])
with (app / 'Contents/Info.plist').open('rb') as f:
    minimum = plistlib.load(f)['LSMinimumSystemVersion']

def version(text):
    parts = tuple(int(p) for p in text.split('.'))
    return parts + (0,) * (3 - len(parts))

magic = {b'\xfe\xed\xfa\xce', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xcf\xfa\xed\xfe',
         b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'}
failures = []
for directory in ('MacOS', 'Frameworks', 'Resources'):
    for path in sorted((app / 'Contents' / directory).rglob('*')):
        if not path.is_file():
            continue
        with path.open('rb') as f:
            if f.read(4) not in magic:
                continue
        limit = '26.0' if path == app / 'Contents/Frameworks/libvulkan_kosmickrisp.dylib' else minimum
        result = subprocess.run(['xcrun', 'vtool', '-show-build', str(path)],
                                capture_output=True, text=True)
        minos = re.findall(r'^\s*minos\s+([0-9.]+)\s*$', result.stdout, re.M)
        relative = path.relative_to(app)
        if result.returncode or not minos:
            failures.append(f'{relative}: cannot read LC_BUILD_VERSION minos: {result.stderr.strip()}')
        elif any(version(v) > version(limit) for v in minos):
            failures.append(f'{relative}: LC_BUILD_VERSION minos {", ".join(minos)} exceeds macOS {limit}')
if failures:
    sys.exit('bundle.sh: deployment target check failed:\n  ' + '\n  '.join(failures))
print(f'bundle.sh: Mach-O deployment targets <= macOS {minimum} (KosmicKrisp <= 26.0)')
PY

# Recheck the copied receipts and bytes before sealing the app. A concurrent
# guest rebuild during assembly must not publish mismatched resources.
python3 "$ROOT/scripts/guest-artifacts.py" check-bundle "$TMP/Contents/Resources"

# Sign inside-out: libraries, helper executables, then the bundle (executable + sealed resources).
for f in "$FW"/*.dylib "$TMP/Contents/Resources/gvproxy" "$TMP/Contents/Resources/desync"; do
    codesign --force --sign - --timestamp=none "$f"
done
codesign --force --sign - --timestamp=none --entitlements "$HERE/steamac-vm.entitlements" "$TMP"
codesign --verify --deep --strict "$TMP"

rm -rf "$APP"
mv "$TMP" "$APP"
rmdir "$STAGE"
trap - EXIT
echo "built $APP"
