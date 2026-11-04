#!/usr/bin/env bash
# Publish work/out/dist/FX-Steam-Launcher-<version>.dmg (dist.sh) to the in-app update feed
# (SparkleUpdates): docs/appcast.xml, served as https://fxgl.github.io/steamac/appcast.xml once
# committed and pushed (GitHub Pages).
#
#   host/launcher/appcast.sh [--local URL] [generate_appcast options, e.g. --phased-rollout-interval 86400]
#
# The GitHub release v<version> must already carry the DMG, byte for byte the file the feed signs.
# Sparkle's generate_appcast (the SwiftPM artifact: the same Sparkle version the app embeds) keeps
# the archives and the feed in work/out/updates, starting from the committed docs/appcast.xml:
#   - the new item: the DMG's EdDSA signature and length, the minimum macOS (LSMinimumSystemVersion),
#     the release's Markdown notes (gh release view) embedded, the download URL on that release;
#   - delta updates from up to 3 earlier versions whose DMGs are in work/out/updates (the kernel and
#     most helpers rarely change), renamed without spaces (GitHub renames uploaded assets that have
#     them) and uploaded to the release;
#   - the whole feed signed (SURequireSignedFeed): never edit docs/appcast.xml by hand; run this
#     script again or re-sign the file with sign_update.
# The private EdDSA key stays in the keychain (generate_keys); never in this repository or CI.
#
# --local URL: a test feed in work/out/updates-local whose downloads are URL/<file> (a local HTTP
# server on that directory); no GitHub, docs/ untouched. Run the app with
# STEAMAC_UPDATE_FEED=URL/appcast.xml, or build it with dist.sh's SPARKLE_FEED_URL=URL/appcast.xml.
# Env SPARKLE_KEY_FILE: the private key from that file instead of the keychain (a throwaway test key
# whose public half went into the app as dist.sh's SPARKLE_PUBLIC_KEY).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT="$ROOT/work/out"
DIST="$OUT/dist"
SPARKLE_BIN="$HERE/.build/artifacts/sparkle/Sparkle/bin"
REPO=fxgl/steamac
SITE=https://fxgl.github.io/steamac/

die() { echo "appcast.sh: $*" >&2; exit 1; }

local_prefix=
if [[ ${1:-} == --local ]]; then
    [[ -n ${2:-} ]] || die "--local needs the URL the test feed's files are served from"
    local_prefix=${2%/}/
    shift 2
fi
[[ -x $SPARKLE_BIN/generate_appcast ]] || die "missing $SPARKLE_BIN (run host/launcher/build.sh)"
app="$DIST/FX Steam Launcher.app"
[[ -d $app ]] || die "missing $app (run host/launcher/dist.sh)"
plist="$app/Contents/Info.plist"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$plist" >/dev/null 2>&1 \
    || die "$app has no SUPublicEDKey: dist.sh built it without in-app updates"
key_args=()
[[ -z ${SPARKLE_KEY_FILE:-} ]] || key_args=(--ed-key-file "$SPARKLE_KEY_FILE")
dmg_name="FX-Steam-Launcher-$version.dmg"
dmg="$DIST/$dmg_name"
[[ -f $dmg ]] || die "missing $dmg"
notes="FX-Steam-Launcher-$version.md"

if [[ -z $local_prefix ]]; then
    command -v gh >/dev/null || die "gh not found (brew install gh)"
    tag="v$version"
    size=$(gh release view "$tag" -R "$REPO" --json assets -q ".assets[] | select(.name == \"$dmg_name\") | .size") \
        || die "no GitHub release $tag"
    [[ -n $size ]] || die "release $tag has no $dmg_name: attach the DMG first"
    [[ $size == "$(stat -f %z "$dmg")" ]] || die "release $tag's $dmg_name ($size bytes) is not $dmg ($(stat -f %z "$dmg") bytes)"
    dir="$OUT/updates"
    prefix="https://github.com/$REPO/releases/download/$tag/"
    mkdir -p "$dir"
    # The committed feed is the truth (another machine may have published since).
    if [[ -f $ROOT/docs/appcast.xml ]]; then cp "$ROOT/docs/appcast.xml" "$dir/appcast.xml"; else rm -f "$dir/appcast.xml"; fi
    gh release view "$tag" -R "$REPO" --json body -q .body >"$dir/$notes"
else
    dir="$OUT/updates-local"
    prefix=$local_prefix
    mkdir -p "$dir"
    printf '## FX Steam Launcher %s\n\nLocal test feed.\n' "$version" >"$dir/$notes"
fi
rm -f "$dir/$dmg_name"
cp -c "$dmg" "$dir/$dmg_name" 2>/dev/null || cp "$dmg" "$dir/$dmg_name"
before="$OUT/.appcast-before.$$.xml"   # outside $dir: generate_appcast reads the feeds there
trap 'rm -f "$before"' EXIT
[[ ! -f $dir/appcast.xml ]] || cp "$dir/appcast.xml" "$before"

echo "=== generate_appcast $version ($prefix)"
"$SPARKLE_BIN/generate_appcast" ${key_args[@]+"${key_args[@]}"} --download-url-prefix "$prefix" --versions "$version" \
    --embed-release-notes --maximum-deltas 3 --link "$SITE" --full-release-notes-url "https://github.com/$REPO/releases" \
    "$@" "$dir"
# generate_appcast signs an update only when its SUPublicEDKey is the signing key's public half.
python3 - "$dir/appcast.xml" "$prefix$dmg_name" <<'PY' || die "the feed has no EdDSA signature for $dmg_name: the app's SUPublicEDKey is not the signing key's"
import sys
import xml.etree.ElementTree as ET
path, url = sys.argv[1:]
sparkle = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
enclosures = [e for e in ET.parse(path).iter('enclosure') if e.get('url') == url]
sys.exit(0 if enclosures and all(e.get(sparkle + 'edSignature') for e in enclosures) else 1)
PY

# generate_appcast rewrites the items of earlier versions whose archives are here (kept for the
# deltas) with this release's download prefix: they keep the URLs they were published with.
if [[ -f $before ]]; then
    python3 - "$before" "$dir/appcast.xml" "$version" <<'PY'
import sys
import xml.etree.ElementTree as ET
before, path, version = sys.argv[1:]
ns = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
def urls(tree):
    out = {}
    for item in tree.iter('item'):
        v = item.findtext(ns + 'version')
        for e in item.iter('enclosure'):
            out[(v, e.get('url').rsplit('/', 1)[-1])] = e.get('url')
    return out
old = urls(ET.parse(before))
text = open(path, encoding='utf-8').read()
for (v, name), url in urls(ET.parse(path)).items():
    if v != version and (v, name) in old and old[(v, name)] != url:
        text = text.replace(url, old[(v, name)])
        print(f'kept {old[(v, name)]}')
open(path, 'w', encoding='utf-8').write(text)
PY
    rm -f "$before"
fi

# Deltas: "FX Steam Launcher<new>-<old>.delta" -> "FX.Steam.Launcher<new>-<old>.delta".
deltas=()
for d in "$dir/FX Steam Launcher$version-"*.delta; do
    [[ -e $d ]] || continue
    base=$(basename "$d")
    dotted=${base// /.}
    mv -f "$d" "$dir/$dotted"
    python3 - "$dir/appcast.xml" "$prefix" "$base" "$dotted" <<'PY'
import sys
from urllib.parse import quote
path, prefix, old, new = sys.argv[1:]
text = open(path, encoding='utf-8').read()
url = prefix + quote(old)
if url not in text:
    sys.exit(f'appcast.sh: {url} not in the feed')
open(path, 'w', encoding='utf-8').write(text.replace(url, prefix + new))
PY
    deltas+=("$dir/$dotted")
done
"$SPARKLE_BIN/sign_update" ${key_args[@]+"${key_args[@]}"} "$dir/appcast.xml"   # after the edits above
"$SPARKLE_BIN/sign_update" ${key_args[@]+"${key_args[@]}"} --verify "$dir/appcast.xml" || die "the feed's signature does not verify"
echo "feed: $dir/appcast.xml (${#deltas[@]} delta update(s))"

if [[ -n $local_prefix ]]; then
    echo "serve $dir at $local_prefix and run the app with STEAMAC_UPDATE_FEED=${local_prefix}appcast.xml"
    exit 0
fi
if ((${#deltas[@]})); then
    echo "=== uploading the delta updates to $tag"
    gh release upload "$tag" -R "$REPO" --clobber "${deltas[@]}"
fi
cp "$dir/appcast.xml" "$ROOT/docs/appcast.xml"
echo "docs/appcast.xml updated: commit and push it (GitHub Pages publishes it to ${SITE}appcast.xml)"
