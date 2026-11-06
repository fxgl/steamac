#!/usr/bin/env python3
"""STEAMAC-94: compile the real kk_timeline_wait against a deterministic clock.
Usage: python3 host/kosmickrisp/test/sync-diagnostics.py <Mesa source directory>
No GPU needed; the bridge stub checks deadlines and diagnostic invocation, not
Metal/Vulkan behavior. Run against the before and after source trees.
"""
import pathlib
import subprocess
import sys
import tempfile

source = pathlib.Path(sys.argv[1], "src/kosmickrisp/vulkan/kk_sync.c").read_text()
start = source.index("static VkResult\nkk_timeline_wait(")
end = source.index("\nconst struct vk_sync_type", start)
function = source[start:end]
harness = r'''
#include <assert.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#define OS_TIMEOUT_INFINITE UINT64_MAX
#define VK_SUCCESS 0
#define VK_TIMEOUT 2
#define KK_DEBUG(flag) enabled
#define container_of(ptr, type, member) ((type *)((char *)(ptr) - offsetof(type, member)))
typedef int VkResult;
struct vk_sync { int unused; };
struct vk_device { int unused; };
struct kk_queue { int unused; };
struct kk_device { struct vk_device vk; bool has_queue; struct kk_queue queue; };
struct kk_sync_timeline { struct vk_sync base; void *mtl_handle; };
enum vk_sync_wait_flags { WAIT_COMPLETE = 0 };
static bool enabled;
static uint64_t now, waits[4];
static unsigned calls, logs, snapshots;
static int complete_at;
static uint64_t os_time_get_nano(void) { return now; }
static int mtl_shared_event_wait_until_signaled_value(void *event, uint64_t value, uint64_t ms) {
    (void)event; (void)value;
    assert(calls < 4); waits[calls++] = ms;
    if (complete_at == (int)calls) { now += 500000000; return 1; }
    if (ms != UINT64_MAX) now += ms * 1000000;
    return 0;
}
static uint64_t mtl_shared_event_get_signaled_value(void *event) { (void)event; return 0; }
static void kk_device_app_name(struct kk_device *dev, char *out, size_t n) { (void)dev; snprintf(out, n, "test"); }
#define mesa_logi(...) do { logs++; } while (0)
static void kk_queue_log_sync_wait(struct kk_queue *queue) { (void)queue; snapshots++; }
'''
main = r'''
static void reset(bool trace, int complete) {
    enabled = trace; complete_at = complete; now = 10000000000ull;
    calls = logs = snapshots = 0; memset(waits, 0, sizeof(waits));
}
int main(void) {
    struct kk_device dev = { .has_queue = true };
    struct kk_sync_timeline sync = {0};
    reset(true, 0);
    assert(kk_timeline_wait(&dev.vk, &sync.base, 5, WAIT_COMPLETE, now + 2500000000ull) == VK_TIMEOUT);
    assert(logs == 2 && snapshots == 1);
    assert(calls == 2 && waits[0] == 1000 && waits[1] == 1500);
    reset(true, 2);
    assert(kk_timeline_wait(&dev.vk, &sync.base, 5, WAIT_COMPLETE, OS_TIMEOUT_INFINITE) == VK_SUCCESS);
    assert(logs == 2 && snapshots == 1 && calls == 2 && waits[1] == UINT64_MAX);
    reset(true, 1);
    assert(kk_timeline_wait(&dev.vk, &sync.base, 5, WAIT_COMPLETE, OS_TIMEOUT_INFINITE) == VK_SUCCESS);
    assert(calls == 1 && logs == 0 && snapshots == 0);
    reset(true, 0);
    assert(kk_timeline_wait(&dev.vk, &sync.base, 5, WAIT_COMPLETE, now) == VK_TIMEOUT);
    assert(calls == 1 && waits[0] == 0 && logs == 0 && snapshots == 0);
    reset(false, 1);
    assert(kk_timeline_wait(&dev.vk, &sync.base, 5, WAIT_COMPLETE, OS_TIMEOUT_INFINITE) == VK_SUCCESS);
    assert(calls == 1 && waits[0] == UINT64_MAX && logs == 0 && snapshots == 0);
    puts("PASS CPU sync diagnostics: finite deadline, infinite wait, early completion, zero poll, tracing off");
}
'''
with tempfile.TemporaryDirectory(prefix="steamac-sync-") as directory:
    path = pathlib.Path(directory)
    (path / "test.c").write_text(harness + function + main)
    subprocess.run(["xcrun", "clang", "-std=c11", "-Wno-unused-function", "-Wno-unused-variable", str(path / "test.c"), "-o", str(path / "test")], check=True)
    subprocess.run([str(path / "test")], check=True)
