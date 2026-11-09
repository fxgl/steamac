#!/usr/bin/env python3
"""Prepare the captured SPIR-V shape and check native/user clip copies at EmitVertex."""
import pathlib
import re
import sys


def require(condition, message):
    if not condition:
        raise SystemExit(f"FAIL: {message}")


if sys.argv[1] == "prepare":
    template, count, output = sys.argv[2:]
    require(count in ("1", "2"), "expected one or two clip planes")
    pathlib.Path(output).write_text(pathlib.Path(template).read_text().replace("@CLIP_COUNT@", count))
elif sys.argv[1] == "check":
    geometry, fragment, count, enabled = sys.argv[2:]
    count, enabled = int(count), bool(int(enabled))
    geometry = pathlib.Path(geometry).read_text()
    fragment = pathlib.Path(fragment).read_text()
    native = re.findall(r"\bfloat\s+(\w+)\s+\[\[clip_distance\]\]\s*\[(\d+)\];", geometry)
    require(len(native) == 1 and int(native[0][1]) == count,
            "mesh output must retain exactly one native clip_distance array")
    varying = r"\bfloat\s+(\w+)\s+\[\[user\(clip(\d+)\)\]\];"
    mesh_users = re.findall(varying, geometry)
    fragment_users = re.findall(varying, fragment)
    expected = set(range(count)) if enabled else set()
    for stage, users in (("mesh", mesh_users), ("fragment", fragment_users)):
        require(len(users) == len(expected) and {int(index) for _, index in users} == expected,
                f"{stage} scalar user(clipN) interface does not match {sorted(expected)}")
    emits = list(re.finditer(r"(?m)^\s*meshStream\.EmitVertex\(\);", geometry))
    require(emits, "fixture must emit geometry vertices")
    for emit in emits:
        before = geometry[:emit.start()].rstrip().splitlines()
        copies = "\n".join(before[-count:])
        for name, index in mesh_users:
            copy = (rf"meshStream\.vertexData\.{re.escape(name)}\s*=\s*"
                    rf"meshStream\.vertexData\.{re.escape(native[0][0])}\[{index}\];")
            require(re.search(copy, copies),
                    f"clip{index} must copy the native array immediately before each emitted vertex")
    print(f"PASS: {count} native clip planes, user copies {'enabled' if enabled else 'disabled'}")
else:
    raise SystemExit("expected prepare or check")
