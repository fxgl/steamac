#!/usr/bin/env python3
"""Generate divergent deep-control-flow and long-ALU controls (STEAMAC-G)."""
import sys
from pathlib import Path

CASES = 320
out = Path(sys.argv[1])
mode = sys.argv[2]
source = ["#version 450", "layout(local_size_x = 32) in;",
          "layout(set = 0, binding = 0, std430) buffer Results { uint values[]; };",
          "void main() {", "uint key = gl_GlobalInvocationID.x;"]
if mode in ("ladder", "jumps"):
    if mode == "jumps":
        source += ["uint value = key + 1000u;",
                   "for (uint round = 0u; round < 3u; ++round) {", "uint merged;"]
        body = [
            "merged = 0u;",
            "for (uint j = 0u; j < 4u; ++j) {",
            "if (j == 1u) continue;",
            "merged += key + j;",
            "if (j == 2u) break;", "}",
            "atomicAdd(values[INDEX], merged + round);",
            "if ((key & 3u) == 0u) break;",
            "if ((key & 3u) == 1u) continue;",
            "if ((key & 3u) == 2u) {",
            "atomicAdd(values[322], value + merged); return;", "}",
            "value += merged;",
        ]
    else:
        body = ["atomicAdd(values[INDEX], key + 1u);"]
    for i in range(CASES + 1):
        source.append((f"{'else ' if i else ''}if (key == {i}u) {{"
                       if i < CASES else "else {"))
        source += [line.replace("INDEX", str(i)) for line in body]
        source.append("}")
    if mode == "jumps":
        source += ["value ^= round + 17u;", "}", "atomicAdd(values[321], value);"]
elif mode == "nested":
    source.append("uint value = key;")
    for i in range(CASES):
        source += [f"if (key >= {i}u) {{", f"value ^= {i + 1}u;",
                   f"atomicAdd(values[{i}], value);"]
    for i in reversed(range(CASES)):
        source += ["} else { atomicAdd(values[320], value); }", f"value += {i + 1}u;"]
    source.append("atomicAdd(values[321], value);")
elif mode == "alu":
    source.append("uint value = key;")
    source += ["value = (value ^ (value >> 13u)) * 1664525u + 1013904223u;"] * 2048
    source.append("values[key] = value;")
else:
    raise ValueError(mode)
source.append("}")
out.write_text("\n".join(source) + "\n")
