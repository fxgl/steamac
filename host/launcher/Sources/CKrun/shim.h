// libkrun v1.19.8 C API, found via -Xcc -I<libkrun include dir> (see build.sh).
#ifndef STEAMAC_CKRUN_SHIM_H
#define STEAMAC_CKRUN_SHIM_H

#include <libkrun.h>
#include <libkrun_display.h>
#include <libkrun_input.h>
#include <util.h>     // openpty
#include <termios.h>

// Function-like/compound macros are not imported by Swift; re-export as constants.
static const uint32_t STEAMAC_COMPAT_NET_FEATURES = COMPAT_NET_FEATURES;
static const uint32_t STEAMAC_NET_FLAG_VFKIT = NET_FLAG_VFKIT;
static const uint32_t STEAMAC_VIRGL_VENUS = VIRGLRENDERER_VENUS;
static const uint32_t STEAMAC_VIRGL_NO_VIRGL = VIRGLRENDERER_NO_VIRGL;
static const uint32_t STEAMAC_KERNEL_FORMAT_RAW = KRUN_KERNEL_FORMAT_RAW;
static const uint32_t STEAMAC_DISK_FORMAT_RAW = KRUN_DISK_FORMAT_RAW;

#endif
