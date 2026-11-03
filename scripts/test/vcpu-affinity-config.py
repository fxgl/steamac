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
            return (f"# /usr/lib/systemd/{manager}.conf.d/99-steamac-vcpu-affinity.conf\n"
                    f"[Manager]\n{body}\n")

        def read_text(path, *args, **kwargs):
            return {
                "/sys/devices/system/cpu/online": "0-4\n",
                "/proc/sys/kernel/random/boot_id": "test-boot\n",
            }[str(path)]

        with patch.object(Path, "read_text", read_text), \
                patch.object(Path, "iterdir", side_effect=ConfigurationChecked), \
                patch("subprocess.check_output", side_effect=config) as cat_config, \
                patch("sys.argv", [str(SCRIPT)]), \
                contextlib.redirect_stdout(io.StringIO()):
            if restricted_manager:
                with self.assertRaisesRegex(SystemExit, f"{restricted_manager} manager mask not reset"):
                    runpy.run_path(str(SCRIPT), run_name="__main__")
            else:
                with self.assertRaises(ConfigurationChecked):
                    runpy.run_path(str(SCRIPT), run_name="__main__")
                self.assertEqual(cat_config.call_count, 2)

    def run_guest(self, arguments, missing=None, vanished=None):
        def config(command, **kwargs):
            manager = command[-1].split("/")[-1].removesuffix(".conf")
            return (f"# /usr/lib/systemd/{manager}.conf.d/99-steamac-vcpu-affinity.conf\n"
                    "[Manager]\nCPUAffinity=\n")

        def read_text(path, *args, **kwargs):
            if str(path) == vanished:
                raise ProcessLookupError()
            if path.name == "cgroup":
                return "0::/\n"
            if path.name == "comm":
                return {"10": "systemd", "20": "gamescope-wl", "30": "steam"}[path.parent.name]
            return {"/sys/devices/system/cpu/online": "0-4\n",
                    "/proc/sys/kernel/random/boot_id": "test-boot\n",
                    "/sys/fs/cgroup/cpuset.cpus.effective": "0-4\n"}[str(path)]

        def iterdir(path):
            if str(path) == missing:
                raise FileNotFoundError()
            if str(path) == "/proc":
                return iter(Path(f"/proc/{pid}") for pid in (10, 20, 30))
            return iter([path / path.parent.name])

        output = io.StringIO()
        with patch.object(Path, "read_text", read_text), \
                patch.object(Path, "read_bytes", lambda path: b"systemd\0--user\0" if path.parent.name == "10" else b"app\0"), \
                patch.object(Path, "iterdir", iterdir), \
                patch.object(Path, "exists", return_value=True), \
                patch("os.sched_getaffinity", return_value=set(range(5)), create=True), \
                patch("subprocess.check_output", side_effect=config), \
                patch("sys.argv", [str(SCRIPT), *arguments]), \
                contextlib.redirect_stdout(output):
            runpy.run_path(str(SCRIPT), run_name="__main__")
        return output.getvalue()

    def test_invalid_game_pids_fail_cleanly(self):
        for value in ("invalid", "0", "-1", ""):
            with self.subTest(pid=value), self.assertRaisesRegex(SystemExit, "^FAIL: invalid game PID"):
                self.run_guest([value])

    def test_missing_game_pid_fails_cleanly(self):
        with self.assertRaisesRegex(SystemExit, "^FAIL: game pid=40 exited or does not exist"):
            self.run_guest(["40"], missing="/proc/40/task")

    def test_game_exit_during_cgroup_read_fails_cleanly(self):
        with self.assertRaisesRegex(SystemExit, "^FAIL: game pid=40 exited during cgroup inspection"):
            self.run_guest(["40"], vanished="/proc/40/cgroup")

    def test_live_game_still_passes(self):
        self.assertIn("PASS: managers, Gamescope, Steam and supplied game threads", self.run_guest(["40"]))

    def test_no_game_still_reports_partial(self):
        self.assertIn("PARTIAL:", self.run_guest([]))

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
