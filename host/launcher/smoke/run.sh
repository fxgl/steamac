#!/usr/bin/env bash
# Smoke-boot work/out/Image + the busybox initramfs with work/out/steamac-vm and check the
# guest console for the expected markers. Writes work/smoke/<mode>/{console.txt,frame.png[,frame-window.png]}.
#
#   host/launcher/smoke/run.sh            # window: display + injected input + close -> power key
#   host/launcher/smoke/run.sh --headless # headless: display (PNG on SIGUSR1) + guest timeout poweroff
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
OUT="$ROOT/work/out"
S="$ROOT/work/smoke"
MODE=window
[[ "${1:-}" == "--headless" ]] && MODE=headless

[[ -x "$OUT/steamac-vm" ]] || { echo "build host/launcher first (build.sh)" >&2; exit 1; }
[[ -f "$OUT/Image" ]] || { echo "missing $OUT/Image (guest/kernel)" >&2; exit 1; }
[[ -f "$OUT/smoke/initramfs.cpio.gz" ]] || "$HERE/build-initramfs.sh"

mkdir -p "$S/$MODE"
rm -f "$S/vda.img" "$S/vdb.img" "$S/$MODE"/*.png
truncate -s 64m "$S/vda.img"
truncate -s 16m "$S/vdb.img"

args=(--kernel "$OUT/Image" --initrd "$OUT/smoke/initramfs.cpio.gz"
      --disk "$S/vda.img" --disk "$S/vdb.img:ro" --cpus 4 --mem 2048 --ssh-port 0
      --frame-dump "$S/$MODE/frame.png")
if [[ $MODE == headless ]]; then
    args+=(--headless --cmdline "console=tty0 console=hvc0 loglevel=4 smoke.timeout=15")
else
    args+=(--input-selftest 6 --cmdline "console=tty0 console=hvc0 loglevel=4 smoke.timeout=60")
fi

LOG="$S/$MODE/console.txt"
"$OUT/steamac-vm" "${args[@]}" </dev/null >"$LOG" 2>&1 &
vm=$!
# SIGUSR1 at 9 s (frame dump); hard kill after 120 s. Both helpers end on their own once the VM is gone.
( for i in $(seq 120); do
      sleep 1
      kill -0 "$vm" 2>/dev/null || exit 0
      [[ $i -eq 9 ]] && kill -USR1 "$vm"
  done
  kill -KILL "$vm" ) >/dev/null 2>&1 &
set +e
wait "$vm"
rc=$?
set -e

markers=(
    "init running on hvc0"
    "vdb 32768 sectors ro=1"
    "fb0: virtio_gpudrmfb"
    "lease of 192.168.127.2"
    "internet: fetched"
    "frame dumped to"
)
if [[ $MODE == headless ]]; then
    markers+=("timeout -> poweroff")
else
    markers+=(
        "pad[create 0003 045e 028e 0114 "
        "window dumped to"
        "progress: kernel"
        "progress: shutdown"
        "input[steamac virtio keyboard] type=1 code=30 value=1"
        "input[steamac virtio mouse] type=1 code=272 value=1"
        "input[steamac virtio mouse] type=2 code=8 value=1"
        "pad[ev 1:304:1 3:0:32767]"
        "pad2[create 0003 045e 028e 0114 "
        "pad2[ev 1:304:1 3:0:32767]"
        "gpio-keys key pressed"
    )
fi
fail=0
for m in "${markers[@]}"; do
    if grep -qF -- "$m" "$LOG"; then echo "ok    $m"; else echo "MISS  $m"; fail=1; fi
done
[[ $rc -eq 0 ]] && echo "ok    steamac-vm exit status 0" || { echo "FAIL  steamac-vm exit status $rc"; fail=1; }
# The reaper stops gvproxy right after steamac-vm exits; allow it a moment.
for _ in 1 2 3 4 5 6; do pgrep -f "steamac-$vm/" >/dev/null || break; sleep 0.5; done
if pgrep -f "steamac-$vm/" >/dev/null; then echo "FAIL  gvproxy left running"; fail=1; else echo "ok    gvproxy cleaned up"; fi
[[ -e "/tmp/steamac-$vm" ]] && { echo "FAIL  /tmp/steamac-$vm left behind"; fail=1; }
echo "console: $LOG"
ls "$S/$MODE"/*.png 2>/dev/null || true
[[ $fail -eq 0 ]] && echo "SMOKE PASS ($MODE)" || { echo "SMOKE FAIL ($MODE)"; exit 1; }
