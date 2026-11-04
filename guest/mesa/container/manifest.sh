#!/bin/sh
# Runs in TOOLS_IMAGE. Writes /out/MANIFEST.txt describing the guest tree in /out.
set -eu
apk add --no-cache -q binutils coreutils grep >/dev/null

m=/out/MANIFEST.txt
{
cat <<EOF
steamac guest Mesa tree: Venus (virtio-gpu) Vulkan ICD + patched zink GL stack
==============================================================================
Overlay: copy usr/ onto guest "/" (paths below are final in-guest paths). MANIFEST.txt is not part of the overlay.
Built by guest/mesa/build.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)

Mesa:            $MESA_URL @ $MESA_COMMIT (26.3.0-devel, contains 4cf0989083d "venus: honor the virtio-gpu blob alignment", MR !44783)
venus-protocol:  v1.1.3 @ $VENUS_PROTOCOL_COMMIT
aarch64 build:   $AARCH64_IMAGE (holo-deckard base-devel = Steam Frame userspace)
x86 builds:      $X86_IMAGE re-pointed at $STEAMOS_X86_MIRROR/{core,extra,multilib}-$STEAMOS_X86_BRANCH
Meson (Venus):   -Dvulkan-drivers=virtio -Dgallium-drivers= -Dplatforms=x11,wayland -Dllvm=disabled -Dvideo-codecs= --buildtype=release
Meson (GL):      -Dgallium-drivers=zink -Dvulkan-drivers= -Dglx=dri -Degl=enabled -Dgbm=enabled -Dglvnd=enabled -Dllvm=disabled (full lists: guest/mesa/container/common.sh)
Mesa patches:    $(cd /patches && ls *.patch | tr '\n' ' ')(guest/mesa/patches, applied to Venus and GL on top of the commit above)

Files (path | ELF machine/class | size | sha256):
EOF
cd /out
find usr -type f | sort | while read -r f; do
    case $f in
        *.so|*.so.*) arch=$(readelf -h "$f" | sed -n 's/^ *Machine: *//p')
              cls=$(readelf -h "$f" | sed -n 's/^ *Class: *//p')
              desc="$arch/$cls" ;;
        */vulkan/icd.d/*) desc="ICD manifest -> $(sed -n 's/.*"library_path": *"\([^"]*\)".*/\1/p' "$f"), library_arch $(sed -n 's/.*"library_arch": *"\([^"]*\)".*/\1/p' "$f")" ;;
        */glvnd/egl_vendor.d/*) desc="glvnd EGL vendor -> $(sed -n 's/.*"library_path": *"\([^"]*\)".*/\1/p' "$f")" ;;
        *) desc="data" ;;
    esac
    printf '/%s | %s | %s | %s\n' "$f" "$desc" "$(stat -c %s "$f")" "$(sha256sum "$f" | cut -d' ' -f1)"
done
cat <<EOF

ICD path semantics: /usr/share/vulkan/icd.d/virtio_icd.aarch64.json is read by the native loader.
The fex-mesa jsons use the provider-root-relative convention of the stock freedreno_icd.{x86_64,x86}.json
next to them (pressure-vessel graphics provider / FEX rootfs resolve /usr/lib* inside $FEX_PROVIDER).

Who loads which build: Proton 11 on aarch64 runs files/bin-arm64 (ARM64EC/WoW64 Wine with FEX as a DLL), so
DXVK/vkd3d in Windows games reach the native aarch64 loader -> /usr/lib/libvulkan_virtio.so. x86/x86-64 Linux
binaries run under the FEX compat tool (Steam app 3127680) + Steam Linux Runtime with STEAM_COMPAT_GRAPHICS_PROVIDER
= the fex-mesa provider, whose stock Vulkan driver is an emulated x86 Turnip -> they need the x86_64/i386 builds.

GL stack: the image's (and provider's) stock zink lacks the fixes in guest/mesa/patches, so the same
frontends and libgallium are built from the pinned Mesa with them and replace the stock files of the same
names (libGLX_mesa, libEGL_mesa, libgbm, libgallium-*.so, gbm/dri_gbm.so, dri/*_dri.so, glvnd 50_mesa.json,
drirc 00-mesa/00-zink defaults) in /usr/lib and in the provider's usr/lib + usr/lib32. Frontends and libgallium
must come from one build (private interface); the stock Turnip, its drirc and the freedreno tools stay.

NEEDED:
EOF
find usr -type f \( -name '*.so' -o -name '*.so.*' \) | sort | while read -r f; do
    printf '/%s: %s\n' "$f" "$(readelf -d "$f" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | tr '\n' ' ')"
done
cat <<EOF

Highest required symbol versions:
EOF
find usr -type f \( -name '*.so' -o -name '*.so.*' \) | sort | while read -r f; do
    vers=$(readelf -V -W "$f" | grep -oE 'Name: (GLIBC|GLIBCXX|CXXABI)_[0-9.]+' | cut -d' ' -f2 | sort -u)
    top=
    for p in GLIBC GLIBCXX CXXABI; do
        v=$(printf '%s\n' "$vers" | grep "^${p}_" | sort -V | tail -1 || true)
        [ -n "$v" ] && top="$top $v"
    done
    printf '/%s:%s\n' "$f" "$top"
done
cat <<EOF

Build dependency versions (pacman -Q inside the build containers):
[aarch64]
$(cat /work/packages-aarch64.txt 2>/dev/null; cat /work/toolchain-aarch64.txt 2>/dev/null)
[x86_64 + i386]
$(cat /work/packages-x86.txt 2>/dev/null; cat /work/toolchain-x86.txt 2>/dev/null)

Required guest environment (for GuestImage)
-------------------------------------------
Vulkan ICD selection: none. The loader finds virtio_icd.*.json next to the stock freedreno_icd.*.json;
  Turnip finds no msm/kgsl device (and no DRM native-context capset on a Venus-only virtio-gpu), so it is
  skipped and Venus binds /dev/dri/renderD128. Do NOT set VK_DRIVER_FILES/VK_ICD_FILENAMES globally: the
  values leak into pressure-vessel/FEX, where an aarch64 json path is wrong for the x86 provider.
GL: MESA_LOADER_DRIVER_OVERRIDE=zink
  libgallium (ours, as the stock one) has zink but no virtio_gpu (virgl) driver; without the override the DRI loader
  looks for virtio_gpu_dri.so and GL fails. The variable passes into pressure-vessel and also selects the
  provider's x86 zink (-> x86 Venus) for FEX-emulated GL apps. Put it in mesavars.sh (EnvironmentFile
  of steam/gamescope/steamvr units) and in the session environment (environment.d) for all GL clients.
MESA_GL_VERSION_OVERRIDE=4.6 / MESA_GLSL_VERSION_OVERRIDE=460: keep. zink's native GL version follows the host
  Vulkan features Venus passes through (geometryShader gates GL 3.2, tessellation GL 4.0); KosmicKrisp reaches 4.6.
  Stock MoltenVK has no geometryShader; the host/moltenvk UTM fork emulates it. The override is an exact version,
  so a lower value caps KosmicKrisp too: 4.3 broke American Truck Simulator, which requests a 4.6 core context.
VRAM report layer: ENABLE_MESA_VRAM_REPORT_LIMIT=1 + VK_VRAM_REPORT_LIMIT_DEVICE_ID=0x5143:0x43051401 only
  matches the Adreno, so it is a no-op on Venus. Venus passes the host vendorID/deviceID through; MoltenVK
  reports vendorID 0x106b and a deviceID that encodes the macOS version and Apple GPU family, so it must be
  read at runtime. To keep the 4096 MiB clamp set VK_VRAM_REPORT_LIMIT_DEVICE_ID to the output of:
    vulkaninfo --summary 2>/dev/null | awk '\$1=="vendorID"{v=\$3} \$1=="deviceID"{d=\$3} \$1=="driverID" && \$3=="DRIVER_ID_MESA_VENUS"{print v ":" d; exit}'
Turnip-only variables (VRCOMPOSITOR_TU_DEBUG, TU_AUTOTUNE_FLAGS, TU_DEBUG): ignored by Venus; dropping them
  is fine (no effect either way).
EOF
} > "$m"
echo "wrote $m"
