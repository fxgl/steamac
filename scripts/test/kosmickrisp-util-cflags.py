#!/usr/bin/env python3
"""Check flag extraction from native and compiler-cached Meson commands."""

import json
import shlex
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


HELPER = Path(__file__).resolve().parents[2] / "host/kosmickrisp/test/util-cflags.py"


class CompilerFlagsTests(unittest.TestCase):
    def test_extracts_flags_with_or_without_a_compiler_cache(self):
        with tempfile.TemporaryDirectory(prefix="kosmickrisp flags ") as directory:
            database = Path(directory) / "compile_commands.json"
            for compiler in ("cc", "/usr/bin/ccache cc", "/opt/homebrew/bin/sccache cc"):
                with self.subTest(compiler=compiler):
                    source = "../src/util/u_queue.c"
                    database.write_text(json.dumps([{
                        "directory": directory,
                        "file": source,
                        "command": f"{compiler} -Iinclude -DNDEBUG -MD -MF test.d -o test.o -c {source}",
                    }]))
                    output = subprocess.check_output([sys.executable, HELPER, directory], text=True)
                    self.assertEqual(shlex.split(output), [f"-I{directory}/include", "-DNDEBUG"])


if __name__ == "__main__":
    unittest.main()
