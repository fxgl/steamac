#!/usr/bin/env python3
"""Exercise production HID routing/GET_REPORT against an isolated IOKit boundary.

No VM, controller, Input Monitoring grant, or launcher build is needed. To test a
historical revision, supply --source /path/to/HIDPassthrough.swift.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source", type=Path, default=root / "host/launcher/Sources/steamac-vm/HIDPassthrough.swift")
args = parser.parse_args()
fixture = Path(__file__).with_suffix(".swift")
with tempfile.TemporaryDirectory(prefix="steamac-hid-test-") as temporary:
    directory = Path(temporary)
    source = directory / "main.swift"
    # Same-file extension reaches the private callback handlers without adding
    # test-only entry points to production. Local symbols replace IOKit's calls;
    # the production source itself is compiled unchanged.
    source.write_text(args.source.read_text() + "\n" + fixture.read_text())
    executable = directory / "hid-passthrough-test"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", str(source), "-o", str(executable)], check=True)
    raise SystemExit(subprocess.run([str(executable)], timeout=30).returncode)
