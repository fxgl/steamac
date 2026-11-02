#!/usr/bin/env python3
"""Check manager-assignment parsing without reading a host or guest /proc tree.

Run with: python3 scripts/test/vcpu-affinity-config.py
"""
import contextlib
import io
from pathlib import Path
import runpy
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).with_name("vcpu-affinity.py")


class ConfigurationChecked(Exception):
    """Stop at process discovery, after both manager configurations passed."""


class AffinityConfigTests(unittest.TestCase):
    def run_checker(self, assignment, restricted_manager=None):
        def config(command, **kwargs):
            manager = command[-1].split("/")[-1].removesuffix(".conf")
            body = assignment if restricted_manager in (None, manager) else "CPUAffinity="
            return (f"# /usr/lib/systemd/{manager}.conf.d/50-steamac-vcpu-affinity.conf\n"
                    f"[Manager]\n{body}\n")

        def read_text(path, *args, **kwargs):
            return {
                "/sys/devices/system/cpu/online": "0-4\n",
                "/proc/sys/kernel/random/boot_id": "test-boot\n",
            }[str(path)]

        with patch.object(Path, "read_text", read_text), \
                patch.object(Path, "iterdir", side_effect=ConfigurationChecked), \
                patch("subprocess.check_output", side_effect=config) as cat_config, \
                contextlib.redirect_stdout(io.StringIO()):
            if restricted_manager:
                with self.assertRaisesRegex(SystemExit, f"{restricted_manager} manager mask not reset"):
                    runpy.run_path(str(SCRIPT), run_name="__main__")
            else:
                with self.assertRaises(ConfigurationChecked):
                    runpy.run_path(str(SCRIPT), run_name="__main__")
                self.assertEqual(cat_config.call_count, 2)

    def test_compact_restriction_is_recognized(self):
        for manager in ("system", "user"):
            with self.subTest(manager=manager):
                self.run_checker("CPUAffinity=\nCPUAffinity=0-4", manager)

    def test_spaced_restriction_is_recognized(self):
        for manager in ("system", "user"):
            with self.subTest(manager=manager):
                self.run_checker("CPUAffinity=\nCPUAffinity = 0-4", manager)

    def test_empty_reset_preserves_assignment_order(self):
        for reset in ("CPUAffinity=", "CPUAffinity =", "  CPUAffinity \t= \t"):
            with self.subTest(reset=reset):
                self.run_checker(f"CPUAffinity=0-4\n{reset}")

    def test_comments_other_keys_and_bare_key_are_ignored(self):
        self.run_checker("CPUAffinity=\n# CPUAffinity = 0-4\n;CPUAffinity=0-4\n"
                         "OtherCPUAffinity=0-4\nCPUAffinityExtra=0-4\nCPUAffinity")


if __name__ == "__main__":
    unittest.main()
