#!/usr/bin/env python3
"""Check 0021's shader-model prerequisite records in a captured launcher log.

Run after test/shader_model.c through Venus. Before 0021 the record is absent;
after it, the gate calculation and all fields must agree with the Vulkan probe.
"""
import re
import sys
from pathlib import Path


def check(text):
    # Terminal captures can wrap the host record; newline is not a field delimiter.
    text = re.sub(r"\r?\n", " ", text)
    records = re.findall(
        r'shader-model caps: device="[^"]+" (.*?denormPreserve32=\d+)', text
    )
    if not records:
        raise ValueError("missing shader-model caps diagnostic")
    for record in records:
        fields = dict(re.findall(r"(\w+)=(0x[0-9a-fA-F]+|\d+)", record))
        values = {key: int(value, 0) for key, value in fields.items()}
        required = (
            "SM60", "subgroupSize", "ops", "missingOps", "stages", "missingStages",
            "scalarBlockLayout", "uniformBufferStandardLayout", "shaderInt16",
            "denormIndependence", "denormFTZ32", "denormPreserve32",
        )
        for key in required:
            if key not in values:
                raise ValueError(f"missing {key}")
        missing_ops = 0x9f & ~values["ops"]
        missing_stages = 0x30 & ~values["stages"]
        supported = (
            values["subgroupSize"] >= 4 and not missing_ops and not missing_stages
            and (values["scalarBlockLayout"] or values["uniformBufferStandardLayout"])
            and values["shaderInt16"]
        )
        if values["missingOps"] != missing_ops or values["missingStages"] != missing_stages:
            raise ValueError("subgroup missing masks disagree with reported capabilities")
        if values["SM60"] != bool(supported):
            raise ValueError("SM60 disagrees with the exact vkd3d-proton predicate")
    return len(records)


if __name__ == "__main__":
    try:
        if len(sys.argv) != 2:
            raise ValueError("usage: shader_model_expect.py LAUNCHER_LOG")
        count = check(Path(sys.argv[1]).read_text())
        print(f"PASS: {count} complete shader-model prerequisite records")
    except (OSError, ValueError) as error:
        sys.exit(f"FAIL: {error}")
