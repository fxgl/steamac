#!/usr/bin/env bash
# Build the DXMT graphics path from pinned sources: the host executor library and the guest payload.
#
#   host/dxmt/build.sh [step...]     steps: fetch llvm native host pe client payload (default: all, in order)
#   host/dxmt/build.sh clean         drop work/build/dxmt* and the unpacked source (keeps work/cache downloads
#                                    and the installed LLVM 15 under work/out/host/llvm15)
#
#   fetch    DXMT at DXMT_COMMIT (host/dxmt/pin.env) + host/dxmt/patches + its mingw-directx-headers submodule
#            -> work/src/dxmt
#   llvm     LLVM $LLVM_VERSION from the release tarball, static, no targets/tools (the configuration of DXMT's
#            own CI) -> work/out/host/llvm15. About 10 min on an M2; skipped when already installed for this pin.
#   native   DXMT's native meson build (airconv) -> work/build/dxmt-native
#   host     wmtr: libwmtr_host.dylib (executor + DXMT's winemetal_unix.c + airconv), its tests (make test),
#            installed into work/out/host/lib (host/launcher/bundle.sh picks it up from there)
#   pe       DXMT's Windows dlls (d3d11, dxgi, d3d10core, winemetal) cross-built with llvm-mingw against the Wine
#            8.16 build DXMT's CI uses (its winebuild marks them Wine builtins) -> work/out/dxmt-pe
#   client   the guest's winemetal.so unixlib (x86-64 ELF, wmtr virtio-gpu transport) + make test-linux, in a
#            linux/amd64 container (Docker/OrbStack, like guest/mesa) -> wmtr/build/x86_64-linux
#   payload  make -C wmtr dxmt-payload -> work/out/dxmt (installed into the layer by scripts/steps/30-layer.sh)
#
# Host lifetime boundary (STEAMAC-5W/5X, 58/59): virtual autorelease pools and fallback retains belong
# to one guest context, never to process-global reply-slot numbers. Typed object-field metadata
# (wmtr/gen/gen_objects.py) validates receivers, embedded command resources and pipeline inputs before
# Objective-C dispatch; worker calls lease live objects. A handle the registry does not know is refused
# only if it is not a live heap block (garbage, freed): objects from calls the metadata does not cover
# go through, as refusing them handed DXMT nil libraries and Metal aborted on a nil vertex function
# (1.9.6, STEAMAC-6S/6W/3/6T). A render pipeline without a vertex function is refused (nil pipeline,
# draws dropped). Encoders still open when a context is destroyed are ended before release (Metal
# aborted the VM, STEAMAC-6Z/70). Late encoders on committed command buffers and Objective-C exceptions
# lose only that context. `make test` includes a real-object multi-context regression; the marshalling
# loopback still uses fake handles.
# wmtr_dxmt_test drives DXMT's own guest API (winemetal_thunks.c) over the wmtr client into the
# production libwmtr_host (DXMT's winemetal_unix.c, validation on, real Metal): blit, compute and
# render lists headed by a Nop like dxmt_context.cpp's, a library from metallib bytes through
# DispatchData_alloc_init + MTLDevice_newLibrary drawing a triangle, MTLBuffer_updateContents on a
# buffer made outside the remoted calls, and a context destroyed with a render encoder open, all
# checked on the GPU's results. 1.9.5 refused every blit and compute list (Death's Door: black frame,
# magenta menu arrows); 1.9.6 aborts on the nil vertex function and the open encoder.
# WMTR_PRESENT_TRACE=1 logs actual drawable presentedTime/submit time/minimum duration for display
# pacing investigations; the launcher's display-pacing diagnostics distinguish physical and guest Hz.
#
# Needs: Apple silicon macOS with Xcode (and its Metal toolchain: xcodebuild -downloadComponent MetalToolchain),
# Rosetta (the pinned Wine's winebuild is x86_64), Homebrew (meson ninja cmake pkgconf zstd), Docker for `client`.
# Without the Metal toolchain set DXMT_PREBUILT_METAL to a directory with dxmt_command.metallib and
# air_{msad,samplepos,tessellation}.air built from the same .metal sources (DXMT's prebuilt_metal_dir option).
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../.." && pwd)
# shellcheck source=pin.env
. "$here/pin.env"

# LLVM release tarball (airconv's compiler, statically linked into libwmtr_host.dylib)
LLVM_URL=https://github.com/llvm/llvm-project/releases/download/llvmorg-$LLVM_VERSION/llvm-project-$LLVM_VERSION.src.tar.xz
LLVM_SHA256=8b5fcb24b4128cf04df1b0b9410ce8b1a729cb3c544e6da885d234280dedeac6
# DXMT's include/native/directx submodule at the commit DXMT_COMMIT records
DXHEADERS_COMMIT=9df86f2341616ef1888ae59919feaa6d4fad693d
DXHEADERS_URL=https://github.com/misyltoad/mingw-directx-headers/archive/$DXHEADERS_COMMIT.tar.gz
DXHEADERS_SHA256=9c1b8bbfd2d6c758fac4d93c2808a46bc1eee429fe656b4f21b29e02615aa8aa
# Toolchains of DXMT's CI (.github/workflows/ci.yml: WINE_URL, LLVM_MINGW_VERSION)
WINE_URL=https://github.com/3Shain/wine/releases/download/v8.16-3shain/wine.tar.gz
WINE_SHA256=289c7f19e270a3d3d0a6fdb07691b176c70a0795f6811e5255cba82425de4f10
LLVM_MINGW="llvm-mingw-20260908-ucrt-macos-universal"
LLVM_MINGW_URL=https://github.com/mstorsjo/llvm-mingw/releases/download/20260908/$LLVM_MINGW.tar.xz
LLVM_MINGW_SHA256=d1dc5d1ecf3a3ced5ed5544c72f1acd0c8e84eb3024d520ecc6b143eec62a149
# Guest unixlib container: the linux/amd64 manifest within Debian trixie's pinned 913f6706... index.
# Pin the platform manifest, not the index: the client is always x86-64 (including Apple silicon Docker),
# and an existing arm64 copy of that index must not collide with the amd64 pull. GCC 14 accepts DXMT's
# C23 fixed-underlying-type enums; wmtr_glibc_compat.h keeps the resulting symbols <= 2.14.
CLIENT_IMAGE=docker.io/library/debian@sha256:bcf83fd8af414eda0c0a99d25a4e61dedd88e7aac7f7bc519d04555ff0c40ec5
BREW_DEPS="meson ninja cmake pkgconf zstd"
# Like libepoxy, virglrenderer and libkrun: the launcher's floor, whatever the build host's SDK is
# (host/launcher/bundle.sh rejects a library with a higher LC_BUILD_VERSION minos).
export MACOSX_DEPLOYMENT_TARGET=15.0

cache=$root/work/cache/dxmt
src=$root/work/src/dxmt
llvm=$root/work/out/host/llvm15
native=$root/work/build/dxmt-native
pebuild=$root/work/build/dxmt-pe
pe=$root/work/out/dxmt-pe
toolchains=$root/work/cache/toolchains
jobs=${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc)}

log() { printf '\n=== %s\n' "$*"; }
die() { echo "host/dxmt/build.sh: $*" >&2; exit 1; }

fetch_file() { # url sha256 dest
    [ -f "$3" ] || { mkdir -p "$(dirname "$3")"; curl -fsSL --retry 3 -o "$3.part" "$1" && mv "$3.part" "$3"; }
    echo "$2  $3" | shasum -a 256 -c - >/dev/null || die "checksum mismatch: $3 (delete it to re-download)"
}

metal_opts() {
    if [ -n "${DXMT_PREBUILT_METAL:-}" ]; then
        for f in dxmt_command.metallib air_msad.air air_samplepos.air air_tessellation.air; do
            [ -f "$DXMT_PREBUILT_METAL/$f" ] || die "DXMT_PREBUILT_METAL lacks $f"
        done
        echo "-Dprebuilt_metal_dir=$(cd "$DXMT_PREBUILT_METAL" && pwd)"
    elif ! xcrun -sdk macosx -f metal >/dev/null 2>&1; then
        die "no Metal toolchain (xcodebuild -downloadComponent MetalToolchain) and no DXMT_PREBUILT_METAL"
    fi
}

step_fetch() {
    log "fetch DXMT ${DXMT_COMMIT:0:12} + $(ls "$here"/patches/*.patch | wc -l | tr -d ' ') patches"
    fetch_file "$DXMT_URL" "$DXMT_SHA256" "$cache/dxmt-$DXMT_COMMIT.tar.gz"
    fetch_file "$DXHEADERS_URL" "$DXHEADERS_SHA256" "$cache/mingw-directx-headers-$DXHEADERS_COMMIT.tar.gz"
    rm -rf "$src"; mkdir -p "$src"
    tar -xzf "$cache/dxmt-$DXMT_COMMIT.tar.gz" -C "$src" --strip-components=1
    mkdir -p "$src/include/native/directx"
    tar -xzf "$cache/mingw-directx-headers-$DXHEADERS_COMMIT.tar.gz" -C "$src/include/native/directx" --strip-components=1
    # its own repository, so `git apply` does not resolve paths against this checkout
    git -C "$src" init -q
    for p in "$here"/patches/*.patch; do git -C "$src" apply "$p" || die "$(basename "$p") does not apply"; done
    # meson's vcs_tag runs `git describe`; give it the fork commit the patches reproduce
    git -C "$src" add -A && git -C "$src" -c user.name=build -c user.email=build@localhost \
        commit -q -m "DXMT ${DXMT_FORK_COMMIT:0:12} (pinned base + host/dxmt/patches)"
}

step_llvm() {
    if [ "$(cat "$llvm/.pin" 2>/dev/null)" = "$LLVM_SHA256" ]; then log "llvm $LLVM_VERSION: installed"; return; fi
    log "llvm $LLVM_VERSION (log: $root/work/build/llvm15/build.log)"
    local tarball=$cache/llvm-project-$LLVM_VERSION.src.tar.xz b=$root/work/build/llvm15
    fetch_file "$LLVM_URL" "$LLVM_SHA256" "$tarball"
    rm -rf "$b" "$llvm"; mkdir -p "$b/src"
    tar -xJf "$tarball" -C "$b/src" --strip-components=1 \
        "llvm-project-$LLVM_VERSION.src/llvm" "llvm-project-$LLVM_VERSION.src/cmake" "llvm-project-$LLVM_VERSION.src/third-party"
    # DXMT's CI flags (setup-llvm-darwin-arm64), minus assertions
    cmake -B "$b/build" -S "$b/src/llvm" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$llvm" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 -DLLVM_HOST_TRIPLE=arm64-apple-darwin \
        -DCMAKE_CXX_FLAGS="-D_LIBCPP_KEEP_TRANSITIVE_INCLUDES_LLVM23" \
        -DLLVM_TARGETS_TO_BUILD="" -DLLVM_BUILD_TOOLS=Off -DLLVM_INCLUDE_BENCHMARKS=Off \
        -DLLVM_INCLUDE_TESTS=Off -DLLVM_INCLUDE_EXAMPLES=Off -DLLVM_ENABLE_ZSTD=Off \
        -DLLVM_VERSION_PRINTER_SHOW_HOST_TARGET_INFO=Off > "$b/build.log" 2>&1 \
        || { tail -30 "$b/build.log"; die "llvm configure failed"; }
    { cmake --build "$b/build" -j "$jobs" && cmake --install "$b/build"; } >> "$b/build.log" 2>&1 \
        || { tail -30 "$b/build.log"; die "llvm build failed"; }
    echo "$LLVM_SHA256" > "$llvm/.pin"
    rm -rf "$b"
}

step_native() {
    log "DXMT native (airconv)"
    [ -f "$src/meson.build" ] || die "no DXMT source: run the fetch step"
    [ -f "$llvm/.pin" ] || die "no LLVM 15: run the llvm step"
    # shellcheck disable=SC2046
    meson setup --wipe "$native" "$src" --buildtype release -Dnative_llvm_path="$llvm" $(metal_opts) >/dev/null
    ninja -C "$native" src/airconv/darwin/libairconv.a libs/DXBCParser/libDXBCParserNative.a
}

step_host() {
    log "wmtr host library"
    local mk=(DXMT="$src" DXMT_BUILD="$native" LLVM="$llvm" PREFIX="$root/work/out/host")
    make -C "$root/wmtr" "${mk[@]}" host install
    make -C "$root/wmtr" "${mk[@]}" test
}

step_pe() {
    log "DXMT PE dlls (llvm-mingw, Wine builtins)"
    arch -x86_64 /usr/bin/true 2>/dev/null || die "Rosetta is needed for the pinned winebuild: softwareupdate --install-rosetta"
    fetch_file "$WINE_URL" "$WINE_SHA256" "$cache/wine-8.16-3shain.tar.gz"
    fetch_file "$LLVM_MINGW_URL" "$LLVM_MINGW_SHA256" "$cache/$LLVM_MINGW.tar.xz"
    if [ "$(cat "$toolchains/.pin" 2>/dev/null)" != "$WINE_SHA256 $LLVM_MINGW_SHA256" ]; then
        rm -rf "$toolchains"; mkdir -p "$toolchains/wine"
        tar -xzf "$cache/wine-8.16-3shain.tar.gz" -C "$toolchains/wine"
        tar -xJf "$cache/$LLVM_MINGW.tar.xz" -C "$toolchains"
        echo "$WINE_SHA256 $LLVM_MINGW_SHA256" > "$toolchains/.pin"
    fi
    # shellcheck disable=SC2046
    PATH="$toolchains/$LLVM_MINGW/bin:$PATH" meson setup --wipe "$pebuild" "$src" --cross-file "$src/build-win64.txt" \
        --buildtype release --strip --prefix "$pebuild/install" -Dwine_install_path="$toolchains/wine" \
        -Dbuild_unixlib=false $(metal_opts) >/dev/null
    PATH="$toolchains/$LLVM_MINGW/bin:$PATH" meson compile -C "$pebuild" -j "$jobs"
    PATH="$toolchains/$LLVM_MINGW/bin:$PATH" meson install -C "$pebuild" >/dev/null
    rm -rf "$pe"; mkdir -p "$pe"
    for f in d3d11 dxgi d3d10core winemetal; do
        dll=$pebuild/install/x86_64-windows/$f.dll
        # winebuild --builtin stamps "Wine builtin DLL" into the DOS stub; Wine treats it as a builtin only then
        grep -q 'Wine builtin DLL' "$dll" || die "$f.dll is not marked as a Wine builtin"
        install -m 644 "$dll" "$pe/$f.dll"
    done
}

step_client() {
    log "guest winemetal.so (linux/amd64 container)"
    command -v docker >/dev/null || die "the client step needs Docker (OrbStack)"
    docker run --rm --platform linux/amd64 -e DEBIAN_FRONTEND=noninteractive -e OWNER="$(id -u):$(id -g)" \
        -v "$root/wmtr:/wmtr" -v "$src:/dxmt:ro" "$CLIENT_IMAGE" sh -euc '
        apt-get update -qq && apt-get install -y -qq --no-install-recommends gcc libc6-dev make binutils >/dev/null
        make -C /wmtr CC=gcc DXMT=/dxmt client-linux test-linux; chown -R "$OWNER" /wmtr/build'
}

step_payload() {
    log "payload -> work/out/dxmt"
    make -C "$root/wmtr" DXMT_PE="$pe" PAYLOAD="$root/work/out/dxmt" dxmt-payload
    (cd "$root/work/out/dxmt" && find . -type f | sort | xargs shasum -a 256)
}

if [ "${1:-}" = clean ]; then
    rm -rf "$src" "$native" "$pebuild" "$root/wmtr/build" "$root/work/build/llvm15"
    exit 0
fi
steps=("$@")
[ ${#steps[@]} -gt 0 ] || steps=(fetch llvm native host pe client payload)
# fetch, client and payload also run on a Linux host (the guest half of a build split over two machines)
case " ${steps[*]} " in *" llvm "*|*" native "*|*" host "*|*" pe "*)
    for dep in $BREW_DEPS; do
        brew list --versions "$dep" >/dev/null 2>&1 || brew install "$dep"
    done ;;
esac
for s in "${steps[@]}"; do
    case $s in
        fetch|llvm|native|host|pe|client|payload) "step_$s" ;;
        *) die "unknown step: $s (fetch llvm native host pe client payload | clean)" ;;
    esac
done
log "done"
