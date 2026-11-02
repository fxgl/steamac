# Shared by build-aarch64.sh and build-x86.sh (bash). Source tree: /src/mesa (read-only);
# backported fixes: /patches (guest/mesa/patches, applied to a copy for the GL build only).

# Venus-only Mesa: no GL/EGL/GBM (built separately below), no LLVM,
# X11 + Wayland WSI. xlib-lease off to keep NEEDED in line with the image's Turnip
# (libX11-xcb only, no libX11/libXrandr).
MESA_OPTS=(
    --prefix=/usr
    --buildtype=release
    -Db_ndebug=true
    --wrap-mode=nodownload
    -Dvulkan-drivers=virtio
    -Dgallium-drivers=
    -Dplatforms=x11,wayland
    -Dllvm=disabled
    -Dvideo-codecs=
    -Dopengl=false
    -Dglx=disabled
    -Degl=disabled
    -Dgbm=disabled
    -Dgles1=disabled
    -Dgles2=disabled
    -Dvulkan-layers=
    -Dtools=
    -Dbuild-tests=false
    -Dvalgrind=disabled
    -Dlibunwind=disabled
    -Dlmsensors=disabled
    -Dxlib-lease=disabled
    -Dspirv-tools=disabled
    -Dzstd=enabled
    -Dzlib=enabled
    -Dexpat=enabled
    # VK_KHR_display EDID metadata only (no display WSI in the VM); linking it tied the ICD to
    # the image's soname: SteamOS 0.6.0 ships libdisplay-info.so.3 only, the 0.4.x build needed
    # .so.1 and did not load (STEAMAC-72). verify.sh check_stable_needed.
    -Ddisplay-info=disabled
    -Dshader-cache=enabled
)

# build_venus <builddir> <libdir> <destdir> [meson args...]
build_venus() {
    local builddir=$1 libdir=$2 destdir=$3
    shift 3
    rm -rf "$builddir" "$destdir"
    meson setup "$builddir" /src/mesa "${MESA_OPTS[@]}" --libdir="$libdir" "$@"
    ninja -C "$builddir"
    DESTDIR="$destdir" meson install -C "$builddir" --strip --no-rebuild --tags runtime
}

# zink-only GL stack (libgallium, GLX through glvnd, EGL, GBM, the DRI loader stubs) that
# replaces the image's own: the stock libgallium's zink lacks the fixes in /patches. It goes
# over the stock files of the same names, and only those (install_gl), so no stock GL frontend
# ever loads our libgallium or the other way round. No LLVM: zink does not use it.
GL_OPTS=(
    --prefix=/usr
    --buildtype=release
    -Db_ndebug=true
    --wrap-mode=nodownload
    -Dgallium-drivers=zink
    -Dvulkan-drivers=
    -Dplatforms=x11,wayland
    -Dopengl=true
    -Dglx=dri
    -Degl=enabled
    -Dgbm=enabled
    -Dglvnd=enabled
    -Dgles1=disabled
    -Dgles2=enabled
    -Dllvm=disabled
    -Dvideo-codecs=
    -Dtools=
    -Dbuild-tests=false
    -Dvalgrind=disabled
    -Dlibunwind=disabled
    -Dlmsensors=disabled
    -Dspirv-tools=disabled
    -Dzstd=enabled
    -Dzlib=enabled
    -Dexpat=enabled
    -Dshader-cache=enabled
)

# gl_source: /tmp/mesa-gl = /src/mesa with /patches applied, created once per container
gl_source() {
    [ -d /tmp/mesa-gl ] && return
    cp -a /src/mesa /tmp/mesa-gl.tmp
    local p
    for p in /patches/*.patch; do
        echo "applying $(basename "$p")"
        patch -d /tmp/mesa-gl.tmp -p1 --forward --no-backup-if-mismatch < "$p"
    done
    mv /tmp/mesa-gl.tmp /tmp/mesa-gl
}

# build_gl <builddir> <libdir> <destdir> [meson args...]
build_gl() {
    local builddir=$1 libdir=$2 destdir=$3
    shift 3
    gl_source
    rm -rf "$builddir" "$destdir"
    meson setup "$builddir" /tmp/mesa-gl "${GL_OPTS[@]}" --libdir="$libdir" "$@"
    ninja -C "$builddir"
    DESTDIR="$destdir" meson install -C "$builddir" --strip --no-rebuild
}

# install_gl <destdir> <libdir> <root>: the GL files of a build_gl tree into <root>/usr,
# the same set the image's Mesa package installs (libGLX_mesa/libEGL_mesa/libgbm with their
# symlinks, libgallium, gbm/dri_gbm.so, the dri/*_dri.so loader stubs, the glvnd EGL vendor
# file, the Mesa and zink drirc defaults). The image's Turnip drirc and tools stay.
install_gl() {
    local src=$1/usr/$2 dst=$3/usr/$2 share=$3/usr/share
    mkdir -p "$dst/dri" "$dst/gbm" "$share/glvnd/egl_vendor.d" "$share/drirc.d"
    cp -a "$src"/libgallium-*.so "$src"/libGLX_mesa.so* "$src"/libEGL_mesa.so* "$src"/libgbm.so* "$dst/"
    cp -a "$src"/dri/*_dri.so "$dst/dri/"
    cp -a "$src"/gbm/dri_gbm.so "$dst/gbm/"
    install -m 0644 "$1"/usr/share/glvnd/egl_vendor.d/50_mesa.json "$share/glvnd/egl_vendor.d/"
    install -m 0644 "$1"/usr/share/drirc.d/00-mesa-defaults.conf "$1"/usr/share/drirc.d/00-zink-defaults.conf \
        "$share/drirc.d/"
}
