#!/usr/bin/env python3
"""Venus reply streams naming a resource the context cannot reply into (STEAMAC-G).

Usage: python3 reply-resource.py /path/libvirglrenderer.1.dylib
Uses the in-process render server, no VM or installed-file changes. Every such
vkSetReplyCommandStreamMESA stays fatal; the log must say whether the resource was
detached from that context (and when) or never attached to it, and valid create,
detach and re-attach orderings must still get a real reply in the shared memory.
"""
import ctypes as C
import mmap
import os
import struct
import sys
import time


class Callbacks(C.Structure):
    _fields_ = [("version", C.c_int)] + [(name, C.c_void_p) for name in (
        "write_fence", "create_gl_context", "destroy_gl_context", "make_current",
        "get_drm_fd", "write_context_fence", "get_server_fd", "get_egl_display")]


class Blob(C.Structure):
    _fields_ = [(name, C.c_uint32) for name in (
        "res_handle", "ctx_id", "blob_mem", "blob_flags")]
    _fields_ += [("blob_id", C.c_uint64), ("size", C.c_uint64),
                 ("iovecs", C.c_void_p), ("num_iovs", C.c_uint32)]


lib = C.CDLL(os.path.abspath(sys.argv[1]))
logs = []
LOG = C.CFUNCTYPE(None, C.c_int, C.c_char_p, C.c_void_p)
FENCE = C.CFUNCTYPE(None, C.c_void_p, C.c_uint32)


@LOG
def logger(level, message, data):
    text = message.decode(errors="replace")
    logs.append(text)
    if "resource history:" in text or "reply stream" in text or "CS error" in text:
        print(text.rstrip(), file=sys.stderr)


@FENCE
def fence(cookie, value):
    pass


def api(name, result, *args):
    fn = getattr(lib, name)
    fn.restype = result
    fn.argtypes = args
    return fn


init = api("virgl_renderer_init", C.c_int, C.c_void_p, C.c_int, C.POINTER(Callbacks))
cleanup = api("virgl_renderer_cleanup", None, C.c_void_p)
create_context = api("virgl_renderer_context_create_with_flags", C.c_int,
                     C.c_uint32, C.c_uint32, C.c_uint32, C.c_char_p)
destroy_context = api("virgl_renderer_context_destroy", None, C.c_uint32)
create_blob = api("virgl_renderer_resource_create_blob", C.c_int, C.POINTER(Blob))
export_blob = api("virgl_renderer_resource_export_blob", C.c_int,
                  C.c_uint32, C.POINTER(C.c_uint32), C.POINTER(C.c_int))
attach = api("virgl_renderer_ctx_attach_resource", None, C.c_int, C.c_int)
detach = api("virgl_renderer_ctx_detach_resource", None, C.c_int, C.c_int)
unref = api("virgl_renderer_resource_unref", None, C.c_uint32)
submit = api("virgl_renderer_submit_cmd", C.c_int, C.c_void_p, C.c_int, C.c_int)
api("virgl_set_log_callback", None, LOG, C.c_void_p, C.c_void_p)(logger, None, None)
callbacks = Callbacks(version=3, write_fence=C.cast(fence, C.c_void_p))
contexts = []
resources = set()


def wait_for(predicate, description):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.001)
    raise AssertionError("timeout: " + description)


def context(ctx):
    name = ("reply-test-%d" % ctx).encode()
    assert create_context(ctx, 4, len(name), name) == 0
    contexts.append(ctx)


def blob(ctx, res, blob_id=0):
    ret = create_blob(C.byref(Blob(res_handle=res, ctx_id=ctx, blob_mem=2,
                                  blob_flags=1, blob_id=blob_id, size=16384)))
    if ret == 0:
        resources.add(res)
    return ret


def mapping(res):
    fd_type, fd = C.c_uint32(), C.c_int(-1)
    assert export_blob(res, C.byref(fd_type), C.byref(fd)) == 0
    assert fd_type.value == 3 and fd.value >= 0
    try:
        return mmap.mmap(fd.value, 16384)
    finally:
        os.close(fd.value)


def set_reply(ctx, res):
    # VkCommandTypeEXT, flags=GENERATE_REPLY, nonnull pointer (u64), then
    # VkCommandStreamDescriptionMESA {u32 resourceId, u64 offset, u64 size}.
    # Venus wire scalars are packed to 4 bytes, including 64-bit scalars.
    wire = struct.pack("<IIQIQQ", 178, 1, 1, res, 0, 16)
    data = C.create_string_buffer(wire)
    assert submit(data, ctx, len(wire) // 4) == 0


def valid(ctx, res):
    start = len(logs)
    with mapping(res) as memory:
        memory[0:4] = b"\x00" * 4
        set_reply(ctx, res)
        wait_for(lambda: memory[0:4] == struct.pack("<I", 178), "real Venus reply")
    assert not any("CS error" in line for line in logs[start:])


def invalid(ctx, res, expected):
    start = len(logs)
    set_reply(ctx, res)
    wait_for(lambda: any("vkSetReplyCommandStreamMESA resulted in CS error" in line
                         for line in logs[start:]), "fatal protocol rejection")
    excerpt = "\n".join(logs[start:])
    assert expected in excerpt, "missing diagnostic: %r in:\n%s" % (expected, excerpt)


assert init(None, (1 << 6) | (1 << 7) | (1 << 8) | (1 << 9), C.byref(callbacks)) == 0
try:
    # HOST3D blob creation is already an attach: no explicit attach or sleep.
    context(1)
    assert blob(1, 123) == 0
    valid(1, 123)
    print("immediate-create: PASS")

    # A new SetReply naming a detached resource is fatal and names the detach.
    detach(1, 123)
    invalid(1, 123, "res_id 123 was detached from context 1 (reply-test-1)")
    context(2)
    attach(2, 123)
    valid(2, 123)
    print("detach-before-set and explicit-reattach: PASS")

    # A live resource of another context grants no access.
    context(3)
    invalid(3, 123, "res_id 123 is not attached to context 3 (reply-test-3) and not among "
            "its last 0 detaches")
    print("wrong-context: PASS")

    # A failed blob creation leaves nothing attached.
    context(6)
    assert blob(6, 3967, blob_id=999) != 0
    invalid(6, 3967, "res_id 3967 is not attached to context 6 (reply-test-6)")
    print("failed-create: PASS")

    # Only a context's last 16 detaches are kept: an older one reads as not
    # attached, the 16th is still named. A fatal context stops decoding, so each
    # check gets a context of its own.
    for ctx, first, check, expected in (
            (8, 362, 362, "res_id 362 is not attached to context 8 (reply-test-8) and not "
                          "among its last 16 detaches"),
            (9, 363, 715, "res_id 715 was detached from context 9 (reply-test-9)")):
        context(ctx)
        others = range(600, 616) if ctx == 8 else range(700, 716)
        for res in (first, *others):
            assert blob(ctx, res) == 0
            detach(ctx, res)
        invalid(ctx, check, expected)
    print("bounded-detaches: PASS")
finally:
    for res in resources:
        unref(res)
    for ctx in contexts:
        destroy_context(ctx)
    cleanup(None)
print("reply-resource: PASS")
