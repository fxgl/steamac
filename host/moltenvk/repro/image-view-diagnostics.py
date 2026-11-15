#!/usr/bin/env python3
"""STEAMAC-G/A: compare real R8 support, preserve invalid-view rejection evidence.

Run with a built image_views executable. VK_DRIVER_FILES selects KosmicKrisp.
This checks diagnostics, not a claimed repair of the unknown guest producer.
"""
import re
import subprocess
import sys


def run(*args):
    result = subprocess.run([sys.argv[1], *args], capture_output=True, text=True)
    output = result.stdout + result.stderr
    assert result.returncode == 0, output
    return output


features = run("format-features")
print(features.strip())
properties = re.findall(r"format (9|37): linear=(0x[0-9a-f]+) optimal=(0x[0-9a-f]+)", features)
assert len(properties) == 2 and properties[0][1:] == properties[1][1:], features
queries = re.findall(r"format (9|37): tiling=([01]) .* result=(-?\d+)", features)
assert len(queries) == 4 and all(result == "0" for _, _, result in queries), features
output = run()
for case in ("sentry-r8-control-1664", "sentry-r8-control-1920", "sentry-r8-control-1952",
             "invalid-sentry-format-1920", "invalid-sentry-format-1952",
             "invalid-sentry-format-usage-1920", "invalid-bc3-rgba8",
             "invalid-bc3-block-rgba8", "bc3-srgb", "bc3-block-rgba32"):
    assert "OK image_views " + case in output, output
expected = (
    "image-only=0x0 view-only=0x0",
    "image view texel blocks image=1x1/4B view=1x1/1B block-texel-compatible=0",
    "image view texel blocks image=4x4/16B view=1x1/4B block-texel-compatible=0",
    "image view texel blocks image=4x4/16B view=1x1/4B block-texel-compatible=1",
)
missing = [message for message in expected if message not in output]
assert not missing, "missing diagnostics: " + repr(missing)
print("image-view-diagnostics: PASS (R8 clear/readback, BC3 controls, rejection evidence)")
