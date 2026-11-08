#!/usr/bin/env python3
"""Exercise production HID routing/GET_REPORT against an isolated IOKit boundary.

No VM, controller, Input Monitoring grant, or launcher build is needed. The fixture
models manager-owned and independently opened devices, denied opens and removal.
The original 24 regressions also run on historical sources; newer lifecycle and
generic HID checks run only when those production capabilities are present.
To test a historical revision, supply --source /path/to/HIDPassthrough.swift.
"""
import argparse
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source", type=Path, default=root / "host/launcher/Sources/steamac-vm/HIDPassthrough.swift")
args = parser.parse_args()
fixture = Path(__file__).with_suffix(".swift")
production = args.source.read_text()
# These pure production enums live beside unrelated launcher/VM code. Extract
# complete top-level declarations, including GenericHIDRouting's self-check
# dependency, without copying their policy into the fixture.
gamepad = (root / "host/launcher/Sources/steamac-vm/Gamepad.swift").read_text()
routing = []
if "GenericHIDRouting" in production:
    for name in ("SteamControllerRouting", "GenericHIDRouting"):
        declaration = re.search(rf"^enum {name} \{{\n.*?^\}}", gamepad, re.MULTILINE | re.DOTALL)
        if declaration is None:
            parser.error(f"cannot find production enum {name} in Gamepad.swift")
        routing.append(declaration.group())
flags = []
if "IOHIDManagerOptions.independentDevices" in production:
    flags += ["-D", "HAS_INDEPENDENT_DEVICES"]
if "GenericHIDRouting" in production:
    flags += ["-D", "HAS_GENERIC_HID"]
if "func diagnosticLines()" in production:
    flags += ["-D", "HAS_HID_DIAGNOSTICS"]
if "func gameControllersChanged()" in production:
    flags += ["-D", "HAS_GAMECONTROLLER_OWNERSHIP"]
if "var needsInputMonitoring" in production:
    flags += ["-D", "HAS_INPUT_MONITORING_WARNING"]
with tempfile.TemporaryDirectory(prefix="steamac-hid-test-") as temporary:
    directory = Path(temporary)
    source = directory / "main.swift"
    # Same-file extension reaches the private callback handlers without adding
    # test-only entry points to production. Local symbols replace IOKit's calls;
    # the production source itself is compiled unchanged.
    source.write_text("\n".join([production, *routing, fixture.read_text()]))
    executable = directory / "hid-passthrough-test"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", *flags, str(source), "-o", str(executable)], check=True)
    raise SystemExit(subprocess.run([str(executable)], timeout=30).returncode)
