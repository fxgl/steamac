// Configuration-path smoke test for work/out/host/lib/libkrun.1.dylib: every call the
// launcher makes before krun_start_enter() must succeed with the GPU/input build.
// It never starts a VM.
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <libkrun.h>
#include <libkrun_display.h>
#include <libkrun_input.h>

static int failures;

static void check(const char *what, long got, long want)
{
    printf("%-44s = %ld%s\n", what, got, got == want ? "" : "  <-- FAIL");
    if (got != want)
        failures++;
}

// Display backend: accepts everything, hands out one static frame.
static uint8_t frame[1280 * 800 * 4];
static int32_t disp_create(void **instance, const void *userdata, const void *reserved)
{
    (void)userdata;
    (void)reserved;
    *instance = frame;
    return 0;
}
static int32_t disp_disable(void *instance, uint32_t scanout_id)
{
    (void)instance;
    (void)scanout_id;
    return 0;
}
static int32_t disp_configure(void *instance, uint32_t scanout_id, uint32_t dw, uint32_t dh,
                              uint32_t w, uint32_t h, uint32_t format)
{
    (void)instance;
    (void)scanout_id;
    (void)dw;
    (void)dh;
    (void)w;
    (void)h;
    (void)format;
    return 0;
}
static int32_t disp_alloc(void *instance, uint32_t scanout_id, uint8_t **buffer, size_t *size)
{
    (void)instance;
    (void)scanout_id;
    *buffer = frame;
    *size = sizeof(frame);
    return 0;
}
static int32_t disp_present(void *instance, uint32_t scanout_id, uint32_t frame_id,
                            const struct krun_rect *damage)
{
    (void)instance;
    (void)scanout_id;
    (void)frame_id;
    (void)damage;
    return 0;
}

// Input backend: a device with no capabilities that never has events.
static int32_t in_create(void **instance, const void *userdata, const void *reserved)
{
    (void)userdata;
    (void)reserved;
    *instance = NULL;
    return 0;
}
static int32_t in_name(void *instance, uint8_t *buf, size_t len)
{
    (void)instance;
    const char name[] = "steamac smoke input";
    size_t n = sizeof(name) - 1 < len ? sizeof(name) - 1 : len;
    memcpy(buf, name, n);
    return (int32_t)n;
}
static int32_t in_serial(void *instance, uint8_t *buf, size_t len)
{
    (void)instance;
    (void)buf;
    (void)len;
    return 0;
}
static int32_t in_ids(void *instance, struct krun_input_device_ids *ids)
{
    (void)instance;
    memset(ids, 0, sizeof(*ids));
    return 0;
}
static int32_t in_caps(void *instance, uint8_t type, uint8_t *bitmap, size_t len)
{
    (void)instance;
    (void)type;
    memset(bitmap, 0, len);
    return 0;
}
static int32_t in_abs(void *instance, uint8_t axis, struct krun_input_absinfo *info)
{
    (void)instance;
    (void)axis;
    memset(info, 0, sizeof(*info));
    return 0;
}
static int32_t in_props(void *instance, uint8_t *bitmap, size_t len)
{
    (void)instance;
    memset(bitmap, 0, len);
    return 0;
}
static int in_ready_efd(void *instance)
{
    (void)instance;
    return -1;
}
static int32_t in_next(void *instance, struct krun_input_event *ev)
{
    (void)instance;
    (void)ev;
    return KRUN_INPUT_ERR_EAGAIN;
}

int main(void)
{
    check("krun_has_feature(KRUN_FEATURE_GPU)", krun_has_feature(KRUN_FEATURE_GPU), 1);
    check("krun_has_feature(KRUN_FEATURE_INPUT)", krun_has_feature(KRUN_FEATURE_INPUT), 1);
    check("krun_has_feature(KRUN_FEATURE_BLK)", krun_has_feature(KRUN_FEATURE_BLK), 1);
    check("krun_has_feature(KRUN_FEATURE_NET)", krun_has_feature(KRUN_FEATURE_NET), 1);

    int32_t ctx = krun_create_ctx();
    check("krun_create_ctx", ctx, 0);
    if (ctx < 0)
        return 1;

    check("krun_set_vm_config(4 vcpus, 4096 MiB)", krun_set_vm_config(ctx, 4, 4096), 0);
    check("krun_set_gpu_options2(VENUS|NO_VIRGL, 8 GiB)",
          krun_set_gpu_options2(ctx, VIRGLRENDERER_VENUS | VIRGLRENDERER_NO_VIRGL, 1ULL << 33),
          0);
    check("krun_add_display(1280x800) [display id]", krun_add_display(ctx, 1280, 800), 0);
    check("krun_display_resize(0, 1600x1000, 423x265 mm)",
          krun_display_resize(ctx, 0, 1600, 1000, 423, 265), 0);
    check("krun_display_resize(display 1) [no such display]",
          krun_display_resize(ctx, 1, 1600, 1000, 423, 265), -EINVAL);
    check("krun_display_resize(8193x1000) [too wide]",
          krun_display_resize(ctx, 0, 8193, 1000, 423, 265), -EINVAL);
    check("krun_display_resize(unknown ctx)",
          krun_display_resize(ctx + 1000, 0, 1600, 1000, 423, 265), -ENODEV);
    uint64_t ctrl_cmds = 1, ring_cmds = 1;
    check("krun_gpu_get_activity(not started) [no running context]",
          krun_gpu_get_activity(ctx, &ctrl_cmds, &ring_cmds), -ENODEV);
    check("krun_pause(not started) [no running context]", krun_pause(ctx), -ENODEV);
    check("krun_resume(not started) [no running context]", krun_resume(ctx), -ENODEV);

    struct krun_display_backend display = {
        .features = KRUN_DISPLAY_FEATURE_BASIC_FRAMEBUFFER,
        .create = disp_create,
        .vtable.basic_framebuffer = {
            .disable_scanout = disp_disable,
            .configure_scanout = disp_configure,
            .alloc_frame = disp_alloc,
            .present_frame = disp_present,
        },
    };
    check("krun_set_display_backend", krun_set_display_backend(ctx, &display, sizeof(display)),
          0);

    struct krun_input_config config = {
        .features = KRUN_INPUT_CONFIG_FEATURE_QUERY,
        .create = in_create,
        .vtable = {
            .query_device_name = in_name,
            .query_serial_name = in_serial,
            .query_device_ids = in_ids,
            .query_event_capabilities = in_caps,
            .query_abs_info = in_abs,
            .query_properties = in_props,
        },
    };
    struct krun_input_event_provider events = {
        .features = KRUN_INPUT_EVENT_PROVIDER_FEATURE_QUEUE,
        .create = in_create,
        .vtable = {
            .get_ready_efd = in_ready_efd,
            .next_event = in_next,
        },
    };
    check("krun_add_input_device",
          krun_add_input_device(ctx, &config, sizeof(config), &events, sizeof(events)), 0);

    check("krun_free_ctx", krun_free_ctx(ctx), 0);

    printf("%s\n", failures ? "FAILED" : "OK");
    return failures ? 1 : 0;
}
