#!/usr/bin/env bash
# Assemble this fork alongside the original installation. An installed upstream
# app provides its matched libkrun/GPU binaries and licensed SteamOS resources.
# Build the Swift executable from this repository; never modify the installed app.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
upstream_app=${STEAMAC_BASE_APP:-/Applications/FX Steam Launcher.app}
base_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$upstream_app/Contents/Info.plist")
[[ "$base_version" == 1.9.13 ]] || { echo 'Use FX Steam Launcher 1.9.13 resources (STEAMAC_BASE_APP); older GPU libraries do not match the guest backports.' >&2; exit 1; }
sdk=${STEAMAC_KRUN_INCLUDE:-$root/work/build/launcher-sdk/include}
out="$root/work/out"
app="$out/Steamac Bazzite.app"
[[ -f "$sdk/libkrun.h" ]] || { echo 'Set STEAMAC_KRUN_INCLUDE to the patched libkrun v1.19.6 headers.' >&2; exit 1; }
for resource in Image initramfs.cpio.gz steamac-layer.img gvproxy desync; do
    [[ -f "$upstream_app/Contents/Resources/$resource" ]]
done
"$here/fetch-zstd.sh"
"$here/fetch-enet.sh"
"$here/fetch-nanors.sh"
mkdir -p "$out"
swift build -c release --package-path "$here" -Xcc "-I$sdk" \
    -Xlinker "-L$upstream_app/Contents/Frameworks" -Xlinker -lkrun.1
bin=$(swift build -c release --package-path "$here" --show-bin-path)/steamac-vm
stage="$out/.bazzite-app.$$"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage"
ditto "$upstream_app" "$stage/Steamac Bazzite.app"
tmp="$stage/Steamac Bazzite.app"
cp "$bin" "$tmp/Contents/MacOS/steamac-vm"
exe="$tmp/Contents/MacOS/steamac-vm"
chmod u+w "$exe"
# SwiftPM may reference either Sentry.framework or its static library.
for framework in Sentry Sparkle; do
    if [[ -d "$(dirname "$bin")/$framework.framework" ]]; then
        rm -rf "$tmp/Contents/Frameworks/$framework.framework"
        ditto "$(dirname "$bin")/$framework.framework" "$tmp/Contents/Frameworks/$framework.framework"
    fi
done
while read -r rp; do
    install_name_tool -delete_rpath "$rp" "$exe"
done < <(otool -l "$exe" | awk '/cmd LC_RPATH/ {getline; getline; print $2}')
install_name_tool -add_rpath @executable_path/../Frameworks "$exe"
# A copied release's Sparkle feed/key belongs to upstream. This fork uses its
# own GitHub release checker until it has its own signed update feed.
python3 - "$tmp/Contents/Info.plist" "$root" <<'PY'
import plistlib,subprocess,sys
p,root=sys.argv[1:]
with open(p,'rb') as f: info=plistlib.load(f)
for key in ('SUFeedURL','SUPublicEDKey','SteamacBuildOut'): info.pop(key,None)
info.update(CFBundleIdentifier='io.github.naozumi520.steamac-bazzite',
            CFBundleName='Steamac Bazzite',CFBundleDisplayName='Steamac Bazzite',
            SteamacGitCommit=subprocess.check_output(['git','-C',root,'rev-parse','HEAD'],text=True).strip(),
            SteamacReleaseDefaults=True)
with open(p,'wb') as f: plistlib.dump(info,f)
PY
cp "$root/LICENSE" "$tmp/Contents/Resources/licenses/steamac-fork-LICENSE.txt"
for fw in "$tmp/Contents/Frameworks/"*.framework; do
    [[ -d "$fw" ]] || continue
    codesign --force --deep --sign - --timestamp=none "$fw"
done
codesign --force --sign - --timestamp=none --entitlements "$here/steamac-vm.entitlements" "$tmp"
codesign --verify --deep --strict "$tmp"
[[ ! -e "$app" ]] || { echo "Already exists: $app" >&2; exit 1; }
mv "$tmp" "$app"
echo "Built $app"
