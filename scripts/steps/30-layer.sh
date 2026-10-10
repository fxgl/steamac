#!/bin/bash
# Step 30 (builder container): work/out/steamac-layer.img
# Read-only erofs image; its usr/ becomes the top lowerdir of the guest /usr
# overlay (lowerdir=<layer>/usr:<rootfs>/usr), see guest/initramfs/init.
# Contents: guest/layer/usr (steamac files) + work/out/mesa-venus/usr (Venus
# ICDs and the x86_64 fault reporter from guest/mesa; required unless
# ALLOW_NO_VENUS=1) + the fx-progress-agent binary built by step 25 from
# guest/progress-agent.
set -euo pipefail
. /src/scripts/config.env

OUT=/work/out/steamac-layer.img
VENUS=/work/out/mesa-venus
ST=$(mktemp -d)
trap 'rm -rf "$ST"' EXIT

cp -a /src/guest/layer/usr "$ST/usr"

if [[ -d $VENUS/usr ]]; then
    cp -a "$VENUS/usr/." "$ST/usr/"
    [[ -f $ST/usr/lib/steamac/x86_64/fault-report.so ]] \
        || { echo "[layer] $VENUS lacks usr/lib/steamac/x86_64/fault-report.so: rebuild guest/mesa (x86 step)" >&2; exit 1; }
    venus_info=$(cd "$VENUS/usr" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -c1-16)
    echo "[layer] included Venus tree from $VENUS ($venus_info)"
elif [[ ${ALLOW_NO_VENUS:-} == 1 ]]; then
    venus_info="ABSENT (ALLOW_NO_VENUS=1)"
    echo "[layer] WARNING: $VENUS/usr missing, building layer WITHOUT Venus (ALLOW_NO_VENUS=1)" >&2
else
    echo "[layer] $VENUS/usr missing: build guest/mesa first (or ALLOW_NO_VENUS=1 for a test layer)" >&2
    exit 1
fi

AGENT=/work/cache/progress-agent/fx-progress-agent
[[ -x $AGENT ]] || { echo "[layer] $AGENT missing: run step 25 (scripts/build-image.sh layer does)" >&2; exit 1; }
install -m 0755 "$AGENT" "$ST/usr/lib/steamac/fx-progress-agent"
for target in gamescope-session.target plasma-session.target; do
    [[ -L $ST/usr/lib/systemd/user/$target.wants/fx-progress-agent.service ]] \
        || { echo "[layer] fx-progress-agent.service is not wanted by $target" >&2; exit 1; }
    [[ -L $ST/usr/lib/systemd/user/$target.wants/fx-clipboard-agent.service ]] \
        || { echo "[layer] fx-clipboard-agent.service is not wanted by $target" >&2; exit 1; }
done
# Desktop Mode: our plasma-session.target replaces the Frame's VR desktop target
# (SteamVR units are masked); gamescope-session runs the nested desktop, whose
# Steam autostart keeps the selected client.
[[ -f $ST/usr/lib/systemd/user/plasma-session.target && -f $ST/usr/lib/systemd/user/steamac-nested-desktop.service ]] \
    && ! grep -q '^Wants=.*steamvr' "$ST/usr/lib/systemd/user/plasma-session.target" \
    && grep -q 'steamac-nested-desktop.service' "$ST/usr/lib/steamos/gamescope-session" \
    && grep -q '^Exec=/usr/lib/steamac/steam-client --desktop' "$ST/usr/lib/steamac/desktop-xdg/autostart/steam.desktop" \
    || { echo "[layer] Desktop Mode units (plasma-session.target, steamac-nested-desktop.service, Steam autostart) missing" >&2; exit 1; }
# Same binary, root mode: started by udev for the launcher's fx.clock port.
grep -q 'fx-progress-agent clock-sync' "$ST/usr/lib/systemd/system/fx-clock-sync.service" \
    && grep -q 'fx-clock-sync.service' "$ST/usr/lib/udev/rules.d/70-fx-progress.rules" \
    || { echo "[layer] fx-clock-sync.service / its udev rule missing" >&2; exit 1; }
# Same binary, root mode: the gamepad, started by udev for the launcher's fx.pad port.
grep -q 'fx-progress-agent pad$' "$ST/usr/lib/systemd/system/fx-pad.service" \
    && grep -q 'fx-pad.service' "$ST/usr/lib/udev/rules.d/70-fx-progress.rules" \
    || { echo "[layer] fx-pad.service / its udev rule missing" >&2; exit 1; }
# ... and one instance per further player's port (fx.pad2, ...).
grep -q 'fx-progress-agent pad$' "$ST/usr/lib/systemd/system/fx-pad@.service" \
    && grep -q 'FX_PAD_PORT=/dev/virtio-ports/%i$' "$ST/usr/lib/systemd/system/fx-pad@.service" \
    && grep -q 'fx-pad@\$attr{name}.service' "$ST/usr/lib/udev/rules.d/70-fx-progress.rules" \
    || { echo "[layer] fx-pad@.service / its udev rule missing" >&2; exit 1; }
# Same binary as systemd-suspend.service's ExecStart: the launcher pauses the VM instead.
grep -q 'fx-progress-agent sleep suspend$' "$ST/usr/lib/systemd/system/systemd-suspend.service.d/50-steamac-sleep.conf" \
    || { echo "[layer] systemd-suspend.service drop-in (fx-progress-agent sleep) missing" >&2; exit 1; }

# Sanity: the pieces the initramfs and the A/B flow depend on.
for f in usr/bin/splctl usr/lib/rauc/post-install.sh usr/lib/steamac/kernelsetup.sh \
         usr/lib/steamac/rauc-shims/steamos-chroot usr/lib/steamac/steam-gfx-env \
         usr/lib/steamac/steam-shader-defaults usr/lib/steamac/steam-client \
         usr/lib/steamac/nested-desktop usr/lib/steamac/desktop-bin/kwin_wayland_wrapper \
         usr/lib/steamac/desktop-bin/steamosctl usr/lib/steamos/gamescope-session; do
    [[ -x $ST/$f ]] || { echo "[layer] $f missing or not executable" >&2; exit 1; }
    bash -n "$ST/$f"
done
[[ -f $ST/usr/lib/systemd/user/steam.service.d/50-steamac.conf ]] \
    || { echo "[layer] steam.service drop-in missing" >&2; exit 1; }
[[ ! -e $ST/usr/lib/systemd/user/steam.service && ! -e $ST/usr/share/deckard/RUNSTEAM.sh ]] \
    || { echo "[layer] proprietary stock Steam files must not be overlaid" >&2; exit 1; }
grep -q 'ExecStartPre=/usr/lib/steamac/steam-client' "$ST/usr/lib/systemd/user/steam.service.d/50-steamac.conf" \
    && grep -q 'ExecStartPost=/usr/lib/steamac/steam-client --watch' "$ST/usr/lib/systemd/user/steam.service.d/50-steamac.conf" \
    || { echo "[layer] steam.service client setup or watcher missing" >&2; exit 1; }
ls "$ST"/usr/lib/steamac/masks.d/*.list >/dev/null

# layer-release: content hash (excluding itself) so a boot log identifies the layer.
tree_hash=$(cd "$ST" && find usr -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -c1-16)
cat > "$ST/usr/lib/steamac/layer-release" <<EOF
steamac-layer content=$tree_hash rootfs-pin=$STEAMOS_BUILDID venus=$venus_info
EOF

# Directory/file modes come from the repo checkout; normalise and make root-owned.
find "$ST" -type d -exec chmod 0755 {} +
find "$ST" -type f -perm -u+x -exec chmod 0755 {} +
find "$ST" -type f ! -perm -u+x -exec chmod 0644 {} +

epoch=${SOURCE_DATE_EPOCH:-1767225600}
rm -f "$OUT.tmp"
mkfs.erofs -zlz4hc -T "$epoch" -U 5fea1f2a-0c6b-4d5e-9a1e-0000000000a1 --all-root -L steamac-layer "$OUT.tmp" "$ST" >/dev/null
mv "$OUT.tmp" "$OUT"
echo "[layer] $OUT: $(stat -c %s "$OUT") bytes; $(cat "$ST/usr/lib/steamac/layer-release")"
