#!/usr/bin/env python3
"""Run the STEAMAC-9S/9T regression against a private KosmicKrisp dylib.

Usage: copy-buffer-null.py <dylib> [--expect-null-crashes]
The optional mode asserts the pre-fix SIGSEGV instead of accepting it as a pass.
"""
import json
import os
from pathlib import Path
import resource
import signal
import subprocess
import sys
import tempfile

if len(sys.argv) not in (2, 3) or (len(sys.argv) == 3 and sys.argv[2] != "--expect-null-crashes"):
    sys.exit(__doc__)
driver = Path(sys.argv[1]).resolve(strict=True)
expect_crashes = len(sys.argv) == 3
root = Path(__file__).resolve().parents[3]
loader = Path(subprocess.check_output(["brew", "--prefix", "vulkan-loader"], text=True).strip())
include = root / "work/build/host-moltenvk/src/Package/Release/MoltenVK/include"
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
failed = False
with tempfile.TemporaryDirectory(prefix="kk-copy-buffer-null-") as directory:
    scratch = Path(directory)
    binary = scratch / "copy_buffer_null"
    subprocess.run(["xcrun", "clang", "-std=c11", "-Wall", "-Wextra", "-Werror",
                    "-Wno-missing-field-initializers", "-O1", f"-I{include}",
                    str(Path(__file__).with_name("copy_buffer_null.c")),
                    f"-L{loader / 'lib'}", "-lvulkan", f"-Wl,-rpath,{loader / 'lib'}",
                    "-o", str(binary)], check=True)
    icd = scratch / "kosmickrisp_icd.json"
    icd.write_text(json.dumps({"file_format_version": "1.0.1", "ICD": {
        "library_path": str(driver), "api_version": "1.4.0"}}))
    environment = dict(os.environ, VK_DRIVER_FILES=str(icd), VK_INSTANCE_LAYERS="",
                       VK_LOADER_LAYERS_DISABLE="~all~", MTL_DEBUG_LAYER="1")
    for api in ("legacy", "copy2"):
        for kind in ("null-dst", "null-src", "null-both", "dense", "sparse"):
            name = f"{api}-{kind}"
            result = subprocess.run([str(binary), name], env=environment, text=True,
                                    capture_output=True, timeout=60)
            invalid = kind.startswith("null-")
            logs = result.stderr.count("kk: skipping invalid vkCmdCopyBuffer2")
            expected = -signal.SIGSEGV if expect_crashes and invalid else 0
            expected_logs = int(invalid and not expect_crashes)
            ok = result.returncode == expected and logs == expected_logs
            if expected == 0:
                ok = ok and f"OK {name}:" in result.stdout
            print(f"{'PASS' if ok else 'FAIL'} {name}: exit={result.returncode}, warnings={logs}")
            if result.stdout:
                print(result.stdout, end="")
            if not ok or logs:
                print(result.stderr, end="", file=sys.stderr)
            failed |= not ok
sys.exit(int(failed))
