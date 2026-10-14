#!/bin/sh
# Pipeline-compilation throughput of a host Vulkan driver, on a synthetic pipeline set.
#
#   host/moltenvk/bench/shader-compile/run.sh [modules]                 MoltenVK (work/out/host/lib)
#   REPRO_DRIVER=kosmickrisp host/moltenvk/bench/shader-compile/run.sh <libvulkan_kosmickrisp.dylib> [modules]
#
# Measures, with the driver's shader compilation on the critical path (as a game's first run is):
#   cold      one pipeline per module, timed one at a time
#   warm      the same modules again (the compiled-program cache)
#   threaded  the same modules on THREADS threads (default 4) — does compilation overlap?
#
# MODULES is the number of pipelines *per set*; the run generates twice that (the cold/warm set and
# a distinct set for the threaded pass). MODULES=200 by default — a run at that size is seconds to a
# couple of minutes, not the tens of minutes a game takes.
# Host-side knobs worth an A/B (both read by KosmicKrisp at device creation):
#   MESA_KK_DISABLE_WORKAROUNDS=11   one MTL4Compiler per device instead of a shared one
#   MESA_KK_DEBUG=compiles           log every compile with its MSL hashes and "<k> in flight"
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../../.." && pwd)
driver=${REPRO_DRIVER:-moltenvk}
modules=${MODULES:-200}
threads=${THREADS:-4}
# How many times the arithmetic block is repeated in each shader: 1 is a small shader (~20 ms per
# compile), 20 or more approaches the size of a real game's shaders (Dragon's Dogma 2's take ~1-2 s
# each, estimated from the compile threads' MSL hashes changing about every 8 s with three in
# flight).
repeat=${REPEAT:-1}
# Per-run nonce: unique per invocation (the shell's pid is included, so two runs in the same second
# still compile distinct shaders). Override NONCE= to repeat exactly and measure the cache-hit path.
nonce=${NONCE:-$(date +%s)-$$}
# Scratch (generated shaders, the ICD file, the binaries). Override it to run two instances at
# once: they would otherwise share the directory, clobber each other's shaders and ICD, and
# measure each other's wreckage.
work=${BENCH_WORK:-$root/work/build/host-moltenvk/shader-compile}

case $driver in
moltenvk)
	libdir=${1:-$root/work/out/host/lib}
	inc=$root/work/build/host-moltenvk/src/Package/Release/MoltenVK/include
	link="-L$libdir -lMoltenVK -Wl,-rpath,$libdir"
	;;
kosmickrisp)
	kk=${1:?usage: REPRO_DRIVER=kosmickrisp $0 <libvulkan_kosmickrisp.dylib> [modules]}
	inc=$root/work/build/host-moltenvk/src/Package/Release/MoltenVK/include
	loader=$(brew --prefix vulkan-loader)/lib
	link="-L$loader -lvulkan -Wl,-rpath,$loader"
	mkdir -p "$work"
	printf '{"file_format_version": "1.0.1", "ICD": {"library_path": "%s", "api_version": "1.4.0"}}\n' \
		"$kk" > "$work/kosmickrisp_icd.json"
	export VK_DRIVER_FILES="$work/kosmickrisp_icd.json"
	unset VK_ICD_FILENAMES
	;;
*)
	echo "REPRO_DRIVER must be moltenvk or kosmickrisp" >&2
	exit 2
	;;
esac

brew list --versions glslang > /dev/null 2>&1 || brew install glslang
spv=$work/spv
rm -rf "$spv"
mkdir -p "$spv"
total=$((modules * 2))
echo ">> generating and compiling $total shaders ($modules per set, nonce $nonce)"
i=0
while [ "$i" -lt "$total" ]; do
	k=$(awk -v i="$i" 'BEGIN { printf "%.7f", 0.1 + i * 0.0000123 }')
	{
		sed -n '1,/@BODY@/p' "$here/shaders/bench.comp.in" | sed '$d'
		r=0
		while [ "$r" -lt "$repeat" ]; do cat "$here/shaders/body.snippet"; r=$((r + 1)); done
		sed -n '/@BODY@/,$p' "$here/shaders/bench.comp.in" | sed '1d'
	} | sed -e "s/@K@/$k/" -e "s/@NONCE@/$nonce/" > "$spv/bench$i.comp"
	glslangValidator -V --quiet --target-env vulkan1.3 "$spv/bench$i.comp" -o "$spv/bench$i.comp.spv"
	rm -f "$spv/bench$i.comp"
	echo "bench$i.comp.spv" >> "$spv/modules.txt"
	i=$((i + 1))
done

# shellcheck disable=SC2086
xcrun clang -std=c11 -Wall -Werror -O2 -I"$inc" "$here/compile_bench.c" $link -o "$work/compile_bench"
THREADS=$threads "$work/compile_bench" "$spv" "$modules"
