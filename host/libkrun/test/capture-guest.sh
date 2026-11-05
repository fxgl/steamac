#!/bin/bash
# Run INSIDE a fresh throwaway SteamOS VM with virtio-snd enabled.
# First free hw:0,0: systemctl --user stop wireplumber pipewire-pulse pipewire
# A working microphone records 3 s; an unavailable/denied/stuck host input must
# return EIO, not a control timeout or broken queue. Playback must still work.
set -euo pipefail
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
for attempt in 1 2 3; do
    before=$SECONDS
    rc=0
    timeout -k 2 5 arecord -D hw:0,0 -f S16_LE -r 48000 -c 2 -d 3 \
        "$scratch/capture.wav" >"$scratch/capture.log" 2>&1 || rc=$?
    cat "$scratch/capture.log"
    if ((rc == 0)); then
        # 3 seconds of 48 kHz, stereo S16 plus the WAV header.
        (( $(stat -c %s "$scratch/capture.wav") >= 576044 ))
    elif ((rc == 1)); then
        grep -q 'Input/output error' "$scratch/capture.log"
    else
        echo "FAIL: capture exited $rc (timeout/signal is not an error response)" >&2
        exit 1
    fi
    ((SECONDS - before <= 5))
    echo "capture $attempt: completed (status $rc)"
done
timeout -k 2 5 aplay -D hw:0,0 -t raw -f S16_LE -r 48000 -c 2 -d 1 /dev/zero
dmesg >"$scratch/dmesg"
if grep -E 'virtio_snd.*(control message.*timeout|invalid I/O queue state)' "$scratch/dmesg"; then
    echo 'FAIL: capture poisoned the virtio-snd control/I/O queues' >&2
    exit 1
fi
echo 'PASS: capture completes or fails promptly; queues and playback survive'
