#!/usr/bin/env python3
"""Replay captured shaders with the payload ABI emitted by the tested translator."""
import pathlib
import re
import sys

emitted = pathlib.Path(sys.argv[1]).read_text()
fixtures = pathlib.Path(sys.argv[2])
output = pathlib.Path(sys.argv[3])
pattern = r"struct spvGSVertex\s*\{[^}]*\};"
match = re.search(pattern, emitted)
if match is None:
    raise SystemExit("translator did not emit an object payload")
payload = match.group()
for stage in ("object", "mesh", "fragment"):
    source = (fixtures / f"sentry-41-payload-{stage}.metal").read_text()
    if stage != "fragment":
        source, count = re.subn(pattern, lambda _: payload, source)
        if count != 1:
            raise SystemExit(f"expected one payload vertex struct in {stage}")
    (output / f"{stage}.metal").write_text(source)
