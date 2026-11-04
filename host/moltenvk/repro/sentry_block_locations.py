#!/usr/bin/env python3
"""Compare a translated stage's MSL user attributes to its SPIR-V interface."""
import collections
import re
import subprocess
import sys
from pathlib import Path

spv, metal, storage = sys.argv[1:]
assembly = subprocess.check_output(["spirv-dis", spv], text=True)
types = {}
constants = {}
decorations = collections.defaultdict(dict)
members = collections.defaultdict(dict)
variables = []
for line in assembly.splitlines():
    tokens = line.split()
    if not tokens or tokens[0] == ";":
        continue
    if tokens[0] == "OpDecorate":
        decorations[tokens[1]][tokens[2]] = tokens[3:]
    elif tokens[0] == "OpMemberDecorate":
        members[(tokens[1], int(tokens[2]))][tokens[3]] = tokens[4:]
    elif len(tokens) >= 3 and tokens[1] == "=":
        name, _, op, *args = tokens
        if op.startswith("OpType"):
            types[name] = (op, args)
        elif op == "OpConstant" and types[args[0]][0] == "OpTypeInt":
            constants[name] = int(args[1])
        elif op == "OpVariable" and args[1] == storage:
            variables.append((name, args[0]))

expected = []
def flatten(type_id, location, component=0):
    op, args = types[type_id]
    if op == "OpTypePointer":
        return flatten(args[1], location, component)
    if op == "OpTypeStruct":
        for index, child in enumerate(args):
            decor = members[(type_id, index)]
            if "BuiltIn" in decor:
                continue
            if "Location" in decor:
                location = int(decor["Location"][0])
            location = flatten(child, location, int(decor.get("Component", [0])[0]))
        return location
    if op in ("OpTypeArray", "OpTypeMatrix"):
        count = constants[args[1]] if op == "OpTypeArray" else int(args[1])
        for _ in range(count):
            location = flatten(args[0], location, component)
        return location
    if location is None:
        raise SystemExit(f"FAIL: missing SPIR-V location for {type_id}")
    expected.append(f"locn{location}" + (f"_{component}" if component else ""))
    return location + 1

for name, type_id in variables:
    decor = decorations[name]
    if "BuiltIn" not in decor:
        flatten(type_id, int(decor["Location"][0]) if "Location" in decor else None,
                int(decor.get("Component", [0])[0]))
actual = re.findall(r"\[\[user\((locn\d+(?:_\d+)?)\)", Path(metal).read_text())
if collections.Counter(actual) != collections.Counter(expected):
    raise SystemExit(f"FAIL: {metal}: SPIR-V {sorted(expected)}, MSL {sorted(actual)}")
print(f"PASS: {metal}: {','.join(sorted(actual))}")
