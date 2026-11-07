#!/usr/bin/env python3
"""Extract the complete STEAMAC-57 MSL, optionally changing only its physical vec3 storage.
The packed control isolates the padding cause; it is not the translator implementation.
Usage: python3 sentry_57_capture.py <event.json> [--packed-control]
"""
import argparse
import json
import re
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("event")
parser.add_argument("--packed-control", action="store_true")
args = parser.parse_args()
with open(args.event, encoding="utf-8") as stream:
    event = json.load(stream)
capture = event["context"]["msl_stage_5"]
header, _, numbered = capture.partition("\n")
if "capture=full" not in header:
    raise SystemExit("event does not contain a complete shader capture")
source = "\n".join(re.sub(r"^\d+: ?", "", line) for line in numbered.splitlines()) + "\n"
if args.packed_control:
    source, substitutions = re.subn(
        r"(struct LDS_Layout\s*\{\s*float ao;\s*)float3( normal;\s*float depth;\s*\};)",
        r"\1packed_float3\2", source,
    )
    if substitutions != 1:
        raise SystemExit("expected exactly one captured LDS_Layout storage declaration")
sys.stdout.write(source)
