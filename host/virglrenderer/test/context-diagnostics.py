#!/usr/bin/env python3
"""STEAMAC-G: fatal Venus logs identify the context, not a nearby process.

Usage: python3 context-diagnostics.py /path/libvirglrenderer.1.dylib
Uses the renderer API and in-process server, without a VM. Two contexts name the
same missing command-buffer ID; a third fails without an object lookup. Every
fatal command and lookup must retain its original text and name its own context.
"""
import ctypes as C
import os
import struct
import sys
import time


class Callbacks(C.Structure):
    _fields_ = [("version", C.c_int)] + [(name, C.c_void_p) for name in (
        "write_fence", "create_gl_context", "destroy_gl_context", "make_current",
        "get_drm_fd", "write_context_fence", "get_server_fd", "get_egl_display")]


lib = C.CDLL(os.path.abspath(sys.argv[1]))
logs = []
LOG = C.CFUNCTYPE(None, C.c_int, C.c_char_p, C.c_void_p)
FENCE = C.CFUNCTYPE(None, C.c_void_p, C.c_uint32)


@LOG
def logger(level, message, data):
    text = message.decode(errors="replace")
    logs.append(text)
    if "CS error" in text or "look up object" in text:
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
create = api("virgl_renderer_context_create_with_flags", C.c_int,
             C.c_uint32, C.c_uint32, C.c_uint32, C.c_char_p)
destroy = api("virgl_renderer_context_destroy", None, C.c_uint32)
submit = api("virgl_renderer_submit_cmd", C.c_int, C.c_void_p, C.c_int, C.c_int)
api("virgl_set_log_callback", None, LOG, C.c_void_p, C.c_void_p)(logger, None, None)
callbacks = Callbacks(version=3, write_fence=C.cast(fence, C.c_void_p))
contexts = []
failures = []
assert init(None, (1 << 6) | (1 << 7) | (1 << 8) | (1 << 9), C.byref(callbacks)) == 0
try:
    for ctx, name, reply in ((101, b"Xwayland", False), (102, b"explorer.exe", False),
                             (103, b"reply-test", True)):
        assert create(ctx, 4, len(name), name) == 0
        contexts.append(ctx)
        start = len(logs)
        if reply:
            # SetReply: header, non-NULL description pointer, resource, offset, size.
            wire = struct.pack("<IIQIQQ", 178, 1, 1, 3967, 0, 16)
            command = "vkSetReplyCommandStreamMESA"
        else:
            # EndRendering: header and a non-NULL, nonexistent VkCommandBuffer.
            wire = struct.pack("<IIQ", 214, 0, 123)
            command = "vkCmdEndRendering"
        data = C.create_string_buffer(wire)
        assert submit(data, ctx, len(wire) // 4) == 0
        fatal = command + " resulted in CS error"
        deadline = time.monotonic() + 5
        while not any(fatal in line for line in logs[start:]):
            assert time.monotonic() < deadline, "timeout waiting for " + fatal
            time.sleep(0.001)
        identity = "[context %d (%s)]" % (ctx, name.decode())
        expected = [fatal]
        if not reply:
            expected.append("failed to look up object 123 of type 6")
        for message in expected:
            matching = [line for line in logs[start:] if message in line]
            if not matching or not all(identity in line for line in matching):
                failures.append("missing %s on %s: %r" % (identity, message, matching))
finally:
    for ctx in contexts:
        destroy(ctx)
    cleanup(None)
assert not failures, "\n".join(failures)
print("context-diagnostics: PASS (two colliding object IDs, three fatal contexts)")
