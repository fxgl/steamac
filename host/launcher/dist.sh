#!/usr/bin/env bash
# Distributable FX Steam Launcher: a copy of work/out/FX Steam Launcher.app (build.sh / bundle.sh)
# re-signed with a Developer ID (hardened runtime, secure timestamp), notarized and stapled, inside
# a signed, notarized and stapled DMG with an /Applications link:
#   work/out/dist/FX Steam Launcher.app
#   work/out/dist/FX-Steam-Launcher-<CFBundleShortVersionString>.dmg
# The copy drops the dev-only SteamacBuildOut Info.plist key (this build tree's path) and gets the
# in-app update configuration (SparkleUpdates): SUFeedURL, SUPublicEDKey, SUVerifyUpdateBeforeExtraction
# and SURequireSignedFeed. Nested code is signed inside-out before the bundle: every loose Mach-O
# (Frameworks dylibs, helper tools in Resources, Sparkle's Autoupdate), then nested bundles deepest
# first (Sparkle's Updater.app, Sparkle.framework), so code added to bundle.sh later is covered
# without changes here. host/launcher/appcast.sh publishes the DMG to the update feed.
#
#   host/launcher/dist.sh [--no-notarize] [--no-sentry-upload]
#
# Env:
#   STEAMAC_SIGN_IDENTITY  codesign identity, SHA-1 or name (default: the keychain's only valid
#                          "Developer ID Application"; signed by SHA-1, so an expired or revoked
#                          certificate of the same name does not make codesign's lookup ambiguous)
#   NOTARY_PROFILE         notarytool keychain profile (default steamac-notary), created once with
#                          xcrun notarytool store-credentials steamac-notary \
#                              --apple-id <Apple ID> --team-id <team> --password <app-specific password>
#   --no-notarize          sign only (local tests; Gatekeeper rejects downloaded copies)
#   --no-sentry-upload     do not upload debug files (only implied by --no-notarize)
#   SENTRY_AUTH_TOKEN      required for a notarized build: upload the debug files of every Mach-O the
#   SENTRY_ORG             app ships (work/out/dSYMs from build.sh + the executables and libraries
#   SENTRY_PROJECT         themselves) with sentry-cli to https://sentry.fxgam.es, matched by Mach-O UUID.
#                          1.9 shipped without them (no SENTRY_* set, only a "NOT uploaded" line), so
#                          crashes in steamac-vm and libkrun stayed unsymbolicated: checked before
#                          signing now, and every shipped Mach-O must pass sentry-cli debug-files check.
#                          The dSYMs are kept as work/out/dist/FX-Steam-Launcher-<version>-dSYMs (later
#                          builds replace work/out/dSYMs).
#   SPARKLE_FEED_URL       the appcast (default https://fxgl.github.io/steamac/appcast.xml)
#   SPARKLE_PUBLIC_KEY     its EdDSA public key (default: the keychain's, generate_keys -p; Sparkle's
#                          generate_keys in host/launcher/.build/artifacts/sparkle/Sparkle/bin creates
#                          the key pair once; back the private key up with generate_keys -x FILE).
#                          Required for a notarized build; without it a --no-notarize build keeps
#                          the GitHub release check.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT="$ROOT/work/out"
NAME="FX Steam Launcher"
SRC="$OUT/$NAME.app"
DIST="$OUT/dist"
ENTITLEMENTS="$HERE/steamac-vm.entitlements"

die() { echo "dist.sh: $*" >&2; exit 1; }

notarize=1
sentry_upload=1
for arg in "$@"; do
    case $arg in
        --no-notarize) notarize=0; sentry_upload=0 ;;
        --no-sentry-upload) sentry_upload=0 ;;
        *) die "usage: $0 [--no-notarize] [--no-sentry-upload]" ;;
    esac
done
[[ -d $SRC ]] || die "missing $SRC (run host/launcher/build.sh)"
# Crash reports of a release need its symbols: fail before signing, not after notarizing.
if [[ $sentry_upload == 1 ]]; then
    [[ -n ${SENTRY_AUTH_TOKEN:-} && -n ${SENTRY_ORG:-} && -n ${SENTRY_PROJECT:-} ]] \
        || die "set SENTRY_AUTH_TOKEN, SENTRY_ORG and SENTRY_PROJECT (debug files for crash reports), or pass --no-sentry-upload"
    command -v sentry-cli >/dev/null || die "sentry-cli not found (brew install getsentry/tools/sentry-cli)"
    [[ $(dwarfdump --uuid "$SRC/Contents/MacOS/steamac-vm" | awk '{print $2; exit}') == \
       $(dwarfdump --uuid "$OUT/dSYMs/steamac-vm.dSYM" 2>/dev/null | awk '{print $2; exit}') ]] \
        || die "work/out/dSYMs/steamac-vm.dSYM is not the app's steamac-vm: rebuild with build.sh"
fi
# An already assembled app is not an escape hatch around guest provenance.
# Check its own sealed resource bytes and receipts before touching dist/.
python3 "$ROOT/scripts/guest-artifacts.py" check-bundle "$SRC/Contents/Resources"
# Releases ship every UI string in every language (build.sh only warns).
python3 "$HERE/l10n.py" check --strict

# Valid identities only, as "<SHA-1> <name>".
valid=$(security find-identity -v -p codesigning \
    | sed -n 's/^ *[0-9]*) \([0-9A-F]\{40\}\) "\(Developer ID Application: .*\)"$/\1 \2/p' | sort -u)
want=${STEAMAC_SIGN_IDENTITY:-}
if [[ -n $want ]]; then
    match=$(awk -v w="$want" '$1 == w || substr($0, 42) == w' <<<"$valid")
else
    match=$valid
fi
[[ -n $match ]] || die "no valid \"Developer ID Application\" identity${want:+ matching '$want'} in the keychain"
[[ $(wc -l <<<"$match") -eq 1 ]] \
    || die "several Developer ID identities, pick one (SHA-1 or name) with STEAMAC_SIGN_IDENTITY:"$'\n'"$match"
sign_id=${match%% *}
identity=${match#* }
team=$(sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p' <<<"$identity")
[[ -n $team ]] || die "cannot read the team ID from identity '$identity'"

profile=${NOTARY_PROFILE:-steamac-notary}
if [[ $notarize == 1 ]]; then
    # Fail before signing if the credentials are missing.
    xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1 \
        || die "notarytool profile '$profile' is not usable; create it with:
  xcrun notarytool store-credentials $profile --apple-id <Apple ID> --team-id $team --password <app-specific password>
(or set NOTARY_PROFILE, or pass --no-notarize for a local test build)"
fi

# In-app updates (SparkleUpdates): releases always carry the feed and its public key.
SPARKLE_BIN="$HERE/.build/artifacts/sparkle/Sparkle/bin"
feed=${SPARKLE_FEED_URL:-https://fxgl.github.io/steamac/appcast.xml}
ed_key=${SPARKLE_PUBLIC_KEY:-$("$SPARKLE_BIN/generate_keys" -p 2>/dev/null || true)}
if [[ -z $ed_key ]]; then
    [[ $notarize == 0 ]] || die "no Sparkle EdDSA key in the keychain (in-app updates); create the key pair once with
  $SPARKLE_BIN/generate_keys
back up the private key (generate_keys -x <file>, keep it offline), or set SPARKLE_PUBLIC_KEY"
    echo "no Sparkle EdDSA key: this test build keeps the GitHub release check"
fi

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SRC/Contents/Info.plist")
DMG_NAME="FX-Steam-Launcher-$version.dmg"
mkdir -p "$DIST"
GPL_SOURCES="$DIST/FX-Steam-Launcher-$version-gpl-sources.tar"
"$ROOT/scripts/gpl-sources.sh"
[[ -f $GPL_SOURCES ]] || die "source archive does not match app version $version"
WORK="$DIST/.work.$$"
rm -rf "$WORK"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"
APP="$WORK/$NAME.app"
ditto "$SRC" "$APP"
/usr/libexec/PlistBuddy -c 'Delete :SteamacBuildOut' "$APP/Contents/Info.plist" 2>/dev/null || true
# Official builds report crash events as environment "release" only when this key names the team
# whose Developer ID signed the running code (CrashReporting.buildKind); everything else, including
# --no-notarize test builds, reports "source-build".
if [[ $notarize == 1 ]]; then
    /usr/libexec/PlistBuddy -c "Add :SteamacDistTeamID string $team" "$APP/Contents/Info.plist"
fi
if [[ -n $ed_key ]]; then
    for entry in "SUFeedURL string $feed" "SUPublicEDKey string $ed_key" \
                 "SUVerifyUpdateBeforeExtraction bool true" "SURequireSignedFeed bool true"; do
        /usr/libexec/PlistBuddy -c "Add :$entry" "$APP/Contents/Info.plist"
    done
    echo "in-app updates from $feed (EdDSA public key $ed_key)"
fi

echo "=== signing with \"$identity\" (hardened runtime)"
sign() { codesign --force --timestamp --options runtime --sign "$sign_id" "$@"; }
main_exe="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
bundles=()      # nested bundles, deepest first
bundle_exes=()  # their main executables (signed with the bundle)
while IFS= read -r -d '' b; do
    bundles+=("$b")
    case $b in
        *.framework) bundle_exes+=("$b/Versions/$(readlink "$b/Versions/Current")/$(basename "$b" .framework)") ;;
        *) bundle_exes+=("$b/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$b/Contents/Info.plist")") ;;
    esac
done < <(find "$APP/Contents" -depth -type d \( -name '*.app' -o -name '*.framework' -o -name '*.xpc' \) -print0)
nested=()
while IFS= read -r -d '' f; do
    [[ $f == "$main_exe" ]] && continue
    for e in ${bundle_exes[@]+"${bundle_exes[@]}"}; do [[ $f == "$e" ]] && continue 2; done
    file -b "$f" | grep -q '^Mach-O' && nested+=("$f")
done < <(find "$APP/Contents" -type f -print0)
for f in "${nested[@]}"; do sign "$f"; done
for b in ${bundles[@]+"${bundles[@]}"}; do sign "$b"; done
sign --entitlements "$ENTITLEMENTS" "$APP"

codesign --verify --deep --strict "$APP"
for f in "$main_exe" "${nested[@]}" ${bundles[@]+"${bundles[@]}"}; do
    info=$(codesign -dv "$f" 2>&1)
    grep -q "TeamIdentifier=$team" <<<"$info" || die "${f#"$APP/"}: not signed by team $team"
    grep -q 'flags=0x10000(runtime)' <<<"$info" || die "${f#"$APP/"}: hardened runtime flag missing"
    grep -q '^Timestamp=' <<<"$info" || die "${f#"$APP/"}: no secure timestamp"
    echo "  ok ${f#"$APP/"}"
done
codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -p - | sed 's/^/  /'

# notarize <file>: submit, wait, print the log and fail unless Accepted.
notarize() {
    local json id status
    json=$(xcrun notarytool submit "$1" --keychain-profile "$profile" --wait --output-format json) || true
    id=$(plutil -extract id raw -o - - <<<"$json" 2>/dev/null || true)
    status=$(plutil -extract status raw -o - - <<<"$json" 2>/dev/null || true)
    echo "  notarytool: ${id:-?} ${status:-no status}"
    if [[ $status != Accepted ]]; then
        echo "$json" >&2
        [[ -n $id ]] && xcrun notarytool log "$id" --keychain-profile "$profile" >&2
        die "notarization of ${1##*/} failed"
    fi
}

if [[ $notarize == 1 ]]; then
    echo "=== notarizing the app"
    ditto -c -k --keepParent "$APP" "$WORK/app.zip"
    notarize "$WORK/app.zip"
    xcrun stapler staple -q "$APP"
    xcrun stapler validate -q "$APP"
    spctl -a -t exec -vv "$APP"
fi

echo "=== building $DMG_NAME"
mkdir -p "$WORK/dmg"
ditto "$APP" "$WORK/dmg/$NAME.app"
ln -s /Applications "$WORK/dmg/Applications"
hdiutil create -quiet -volname "$NAME" -srcfolder "$WORK/dmg" -fs HFS+ -format ULFO -ov "$WORK/$DMG_NAME"
codesign --force --timestamp --sign "$sign_id" "$WORK/$DMG_NAME"

if [[ $notarize == 1 ]]; then
    echo "=== notarizing the DMG"
    notarize "$WORK/$DMG_NAME"
    xcrun stapler staple -q "$WORK/$DMG_NAME"
    xcrun stapler validate -q "$WORK/$DMG_NAME"
    spctl -a -t open --context context:primary-signature -vv "$WORK/$DMG_NAME"
fi

rm -rf "$DIST/$NAME.app" "$DIST/$DMG_NAME"
mv "$APP" "$DIST/$NAME.app"
mv "$WORK/$DMG_NAME" "$DIST/$DMG_NAME"
echo "built $DIST/$DMG_NAME ($(du -h "$DIST/$DMG_NAME" | cut -f1), sha256 $(shasum -a 256 "$DIST/$DMG_NAME" | cut -d' ' -f1))"
echo "GPL sources: $GPL_SOURCES ($(du -h "$GPL_SOURCES" | cut -f1), sha256 $(shasum -a 256 "$GPL_SOURCES" | cut -d' ' -f1))"
[[ $notarize == 1 ]] || echo "NOT notarized (--no-notarize): Gatekeeper blocks this DMG once downloaded"
[[ -z $ed_key ]] || echo "update feed: after attaching $DMG_NAME to the GitHub release v$version, run host/launcher/appcast.sh"

# Debug files for symbolicated crash reports (CrashReporting.swift). Never a hardcoded token.
if [[ $sentry_upload == 0 ]]; then
    echo "debug files NOT uploaded to Sentry (--no-notarize / --no-sentry-upload)"
else
    # Every Mach-O the app ships (executable, Frameworks, helpers in Resources), each checked usable
    # by sentry-cli (symbol table and unwind info) and uploaded with the build's dSYMs.
    machos=()
    while IFS= read -r -d '' f; do
        dwarfdump --uuid "$f" >/dev/null 2>&1 || continue
        [[ $(sentry-cli debug-files check "$f") == *"Usable: yes"* ]] || die "no usable debug information in $f"
        machos+=("$f")
    done < <(find "$DIST/$NAME.app/Contents" -type f \( -perm -u+x -o -name '*.dylib' \) -print0)
    kept="$DIST/FX-Steam-Launcher-$version-dSYMs"
    rm -rf "$kept"
    cp -R "$OUT/dSYMs" "$kept"
    echo "=== uploading debug files of ${#machos[@]} Mach-O files + $kept to sentry.fxgam.es ($SENTRY_ORG/$SENTRY_PROJECT)"
    sentry-cli --url https://sentry.fxgam.es debug-files upload --org "$SENTRY_ORG" --project "$SENTRY_PROJECT" \
        --wait "$kept" "${machos[@]}"
fi
