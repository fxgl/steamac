#!/bin/sh
# Compile reconstructed Sentry shaders with a private patched SPIRV-Cross, then Metal.
# Usage: sh host/moltenvk/repro/sentry-msl.sh <SPIRV-Cross source> <CMake build> [output directory]
# Never invokes the MoltenVK build or installs a driver. Requires glslangValidator,
# spirv-as, spirv-val, Xcode's Metal toolchain, and an already-built SPIRV-Cross CLI.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../../.." && pwd)
src=${1:?SPIRV-Cross source directory required}
build=${2:?SPIRV-Cross CMake build directory required}
work=${3:-"$root/work/scratch/spvcmsl/regression"}
mkdir -p "$work"
spvc="$build/spirv-cross"

assemble() {
    spirv-as --target-env vulkan1.1 "$here/shaders/$1" -o "$work/$2.spv"
    spirv-val --target-env vulkan1.1 "$work/$2.spv"
}
glsl() {
    glslangValidator -V --target-env vulkan1.1 "$here/shaders/$1" -o "$work/$2.spv"
    spirv-val --target-env vulkan1.1 "$work/$2.spv"
}
metal() {
    xcrun -sdk macosx metal "-std=$2" -c "$work/$1.metal" -o "$work/$1.air"
}
cli() {
    name=$1
    version=$2
    standard=$3
    shift 3
    "$spvc" "$work/$name.spv" --msl --msl-version "$version" --output "$work/$name.metal" "$@"
    metal "$name" "$standard"
}

# 6D: raw scalar BDA pointer, including the helper parameter shape in the report.
assemble sentry-bda-atomic.comp.spvasm bda
cli bda 30200 metal3.2
cp "$work/bda.metal" "$work/bda-runtime.metal"
cli bda 20400 macos-metal2.4
cli bda 30200 metal3.2 --msl-argument-buffers --msl-argument-buffer-tier 1
cli bda 40000 metal4.0

# Preserve the previously fixed physical vector-component and image atomic forms.
glsl bda_vec_atomic.comp bda-vector
cli bda-vector 30200 metal3.2
glsl rba_atomic_store.comp texture-buffer-atomic
cli texture-buffer-atomic 30200 metal3.2 --msl-texture-buffer-native
cli texture-buffer-atomic 20400 macos-metal2.4 --msl-texture-buffer-native

# 5C: MSL 3.2+ uses the fence; earlier languages retain the barrier fallback.
glsl sentry-subgroup-fence.comp fence
cli fence 30200 metal3.2
cp "$work/fence.metal" "$work/fence-runtime.metal"
cli fence 20400 macos-metal2.4
cli fence 30100 metal3.1
cli fence 40000 metal4.0

# 5M: the deployed translator accepts the duplicate builtin aliases used by zink.
# Current spirv-val rejects those aliases (VUID 09658), so this reconstruction
# deliberately tests translator resilience without claiming Vulkan validation.
spirv-as --target-env vulkan1.1 "$here/shaders/sentry-5m-duplicate-primitive-id.tesc.spvasm" -o "$work/primitive-id.spv"
cli primitive-id 20100 macos-metal2.1 --msl-multi-patch-workgroup
test "$(grep -c 'uint gl_PrimitiveID = min(gl_GlobalInvocationID.x / 4, spvIndirectParams\[1\] - 1);' "$work/primitive-id.metal")" = 1

# 2N: extracted builtin helpers, nested write references, and explicit ordinary
# arrays, with fixed masks, per-sample masking, and native-array lowering.
assemble sentry-2n-sample-mask-helper.frag.spvasm sample-mask
assemble sentry-2n-sample-mask-nested.frag.spvasm sample-mask-nested
glsl sentry-2n-sample-mask-array.frag sample-mask-array
for name in sample-mask sample-mask-nested sample-mask-array; do
    cli "$name" 20100 macos-metal2.1
    cli "$name" 20100 macos-metal2.1 --msl-additional-fixed-sample-mask 1
    cli "$name" 20100 macos-metal2.1 --msl-force-sample-rate-shading
    cli "$name" 20100 macos-metal2.1 --msl-additional-fixed-sample-mask 1 --msl-force-sample-rate-shading
    cli "$name" 20100 macos-metal2.1 --msl-additional-fixed-sample-mask 1 --msl-force-native-arrays
done

# 33: component-packed locals remain thread variables in capture/tess/GS paths.
# 6E/66: flattened CullDistance fields and array-backed capture outputs agree.
glsl sentry-33-output-components.vert components
glsl sentry-6e-cull-block.vert cull-block
assemble sentry-6e-cull-distance.vert.spvasm cull
assemble sentry-66-cull-distance.vert.spvasm cull-one
for stem in components cull-block cull cull-one; do
    cli "$stem" 30100 metal3.1
    cli "$stem" 30100 metal3.1 --msl-capture-output
    if [ "$stem" = components ]; then cp "$work/$stem.metal" "$work/components-runtime.metal"; fi
    cli "$stem" 30100 metal3.1 --msl-vertex-for-tessellation
    cli "$stem" 30100 metal3.1 --msl-for-mesh-pipeline
done
for stage in tesc tese geom frag; do
    glsl "sentry-6e-cull-stage.$stage" "cull-$stage"
    cli "cull-$stage" 30100 metal3.1
done
cli cull-tesc 30100 metal3.1 --msl-multi-patch-workgroup
cli cull-tese 30100 metal3.1 --msl-raw-buffer-tese-input

# 6V: component pointers retain the post-interpolation swizzle through copies and
# split access chains; test all pull-model methods, then check rendered values.
for shape in components chained; do
    assemble "sentry-6v-interpolant-$shape.frag.spvasm" "interpolant-$shape"
    for version in 20300 30200 40000; do
        case "$version" in
            20300) standard=macos-metal2.3 ;;
            30200) standard=metal3.2 ;;
            40000) standard=metal4.0 ;;
        esac
        cli "interpolant-$shape" "$version" "$standard"
        if [ "$version" = 30200 ]; then
            cp "$work/interpolant-$shape.metal" "$work/interpolant-$shape-runtime.metal"
        fi
    done
done

# 6A needs the remap reflection API; 5K exercises the null-descriptor option
# passed by MoltenVK (not exposed by the standalone SPIRV-Cross CLI).
xcrun -sdk macosx clang++ -std=c++14 -I"$src" "$here/sentry_msl_compile.cpp" \
    "$build/libspirv-cross-msl.a" "$build/libspirv-cross-glsl.a" "$build/libspirv-cross-core.a" -o "$work/compile"
assemble sentry-6a-spec-id-range.comp.spvasm spec-id
"$work/compile" "$work/spec-id.spv" "$work/spec-id.metal" 30000 > "$work/spec-id-map.txt"
for mapping in 'map 0 0' 'map 65535 65535' 'map 4294967295 1' 'map 65536 2'; do
    grep -qx "$mapping" "$work/spec-id-map.txt"
done
metal spec-id metal3.0
cp "$work/spec-id.metal" "$work/spec-id-runtime.metal"
"$work/compile" "$work/spec-id.spv" "$work/spec-id.metal" 40000
metal spec-id metal4.0
xcrun -sdk macosx clang++ -std=c++14 -fobjc-arc -framework Foundation -framework Metal \
    "$here/sentry_msl_specialize.mm" -o "$work/specialize"
"$work/specialize" "$work/spec-id-runtime.metal" 1 2

assemble sentry-5k-ms-query-levels.frag.spvasm ms-levels
for version in 30000 40000; do
    case "$version" in 30000) standard=metal3.0 ;; 40000) standard=metal4.0 ;; esac
    "$work/compile" "$work/ms-levels.spv" "$work/ms-levels.metal" "$version"
    metal ms-levels "$standard"
    "$work/compile" "$work/ms-levels.spv" "$work/ms-levels.metal" "$version" null
    metal ms-levels "$standard"
    if [ "$version" = 30000 ]; then cp "$work/ms-levels.metal" "$work/ms-levels-runtime.metal"; fi
done

xcrun -sdk macosx clang -fobjc-arc -framework Foundation -framework Metal \
    "$here/sentry_msl_runtime.m" -o "$work/runtime"
"$work/runtime" bda "$work/bda-runtime.metal"
"$work/runtime" fence "$work/fence-runtime.metal"
"$work/runtime" ms-levels "$work/ms-levels-runtime.metal"
"$work/runtime" components "$work/components-runtime.metal"
"$work/runtime" interpolant "$work/interpolant-components-runtime.metal"
"$work/runtime" interpolant "$work/interpolant-chained-runtime.metal"
printf '%s\n' 'PASS: reconstructed Sentry MSL shaders'
