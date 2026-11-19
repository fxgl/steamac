#!/bin/sh
# STEAMAC-AK/AP/AN/AX: command storage diagnostics, not a reproduction of the
# reported IOGPU allocation abort. Uses a private executable/ICD and no VM.
set -eu
[ "${REPRO_DRIVER:-kosmickrisp}" = kosmickrisp ] || exit 2
here=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../../.." && pwd)
kk=${1:?usage: REPRO_DRIVER=kosmickrisp command-allocator.sh <dylib>}
case $kk in /*) ;; *) kk=$PWD/$kk ;; esac
work=$(mktemp -d "${TMPDIR:-/tmp}/kk-command-allocator.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
inc=$root/work/build/host-moltenvk/src/Package/Release/MoltenVK/include
loader=$(brew --prefix vulkan-loader)/lib
xcrun clang -std=c11 -Wall -Werror -O1 -I"$inc" "$here/command_allocator.m" \
    -L"$loader" -lvulkan -Wl,-rpath,"$loader" -framework Foundation -framework Metal \
    -o "$work/command_allocator"
printf '{"file_format_version":"1.0.1","ICD":{"library_path":"%s","api_version":"1.4.0"}}\n' "$kk" > "$work/icd.json"
export VK_DRIVER_FILES=$work/icd.json MTL_DEBUG_LAYER=1 MTL_DEBUG_LAYER_ERROR_MODE=assert
export MTL_HUD_ENABLED=0
unset VK_ICD_FILENAMES MESA_KK_DEBUG REPRO_ALLOCATOR_PAIRS REPRO_ALLOCATOR_ROUNDS
MESA_KK_DEBUG=cbs "$work/command_allocator" > "$work/full.log" 2>&1 || { cat "$work/full.log"; exit 1; }
REPRO_ALLOCATOR_PAIRS=1024 REPRO_ALLOCATOR_ROUNDS=4 "$work/command_allocator" > "$work/bounded.log" 2>&1 || { cat "$work/bounded.log"; exit 1; }
python3 - "$work/full.log" "$work/bounded.log" <<'PY'
import pathlib, re, sys
full, bounded = [pathlib.Path(p).read_text() for p in sys.argv[1:]]
records = [line for line in full.splitlines() if 'kk: command storage ' in line]
limited = [line for line in bounded.splitlines() if 'kk: command storage ' in line]
assert len(records) >= 80, f'FAIL: missing per-recording storage diagnostics ({len(records)})'
assert 1 <= len(limited) <= 16, f'FAIL: missing/unbounded growth snapshots ({len(limited)})'
assert any('before=end-recording ' in line for line in records)
assert any('before=end-encoder ' in line or 'before=render ' in line or 'before=compute ' in line for line in limited)
for line in records + limited:
    fields = dict(re.findall(r'([a-z-]+)=([0-9]+)(?: |$)', line))
    for key in ['bytes', 'pre-bytes', 'render', 'compute', 'metal-encoders', 'pre-encoders',
                'metal-buffers', 'upload-bos', 'upload-bytes', 'large-bos', 'large-bytes',
                'pool-free-bos', 'pool-free-allocators', 'pool-free-cbs',
                'residency-count', 'residency-bytes', 'metal-allocated']:
        assert key in fields, f'FAIL: missing {key}: {line}'
    assert int(fields['bytes']) > 0 and int(fields['residency-count']) > 0
    if 'before=end-recording ' in line:
        assert int(fields['metal-encoders']) == int(fields['render']) + int(fields['compute'])
for text in [full, bounded]:
    assert 'OK command_allocator:' in text
    sample = re.search(r'(\d+) rounds warm=(\d+) final=(\d+)', text)
    assert sample and int(sample[3]) <= int(sample[2]) + 8 * 1024 * 1024
    print('command_allocator:', sample[0])
print(f'OK command storage: {len(records)} explicit snapshots, {len(limited)} bounded growth snapshots; real Metal heaps and residency queried')
PY
if [ -n "${COMMAND_ALLOCATOR_LOG_DIR:-}" ]; then
    mkdir -p "$COMMAND_ALLOCATOR_LOG_DIR"
    cp "$work/full.log" "$work/bounded.log" "$COMMAND_ALLOCATOR_LOG_DIR/"
fi
