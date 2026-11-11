#!/usr/bin/env python3
"""Nested Plasma shell recovery after QtWayland's non-signal exit (STEAMAC-AJ)."""
import contextlib
import importlib.machinery
import importlib.util
import io
from pathlib import Path
import signal
import subprocess
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "guest/layer/usr/lib/steamac/desktop-shell"
loader = importlib.machinery.SourceFileLoader("desktop_shell", str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
shell = importlib.util.module_from_spec(spec)
loader.exec_module(shell)


class DesktopShellTests(unittest.TestCase):
    def drive(self, statuses, durations=None, terminate=False, launching=False):
        now = 0
        starts = []
        handlers = {}
        sent = []
        durations = iter(durations or [0] * len(statuses))
        statuses = iter(statuses)

        def set_signal(signum, handler):
            old = handlers.get(signum, signal.SIG_DFL)
            handlers[signum] = handler
            return old

        class Child:
            def __init__(self, command):
                starts.append(command)
                self.status = next(statuses)
                if launching:
                    handlers[signal.SIGTERM](signal.SIGTERM, None)

            def wait(self):
                nonlocal now
                if terminate:
                    handlers[signal.SIGTERM](signal.SIGTERM, None)
                now += next(durations)
                return self.status

            def poll(self):
                return None

            def send_signal(self, signum):
                sent.append(signum)

            def terminate(self):
                self.send_signal(signal.SIGTERM)

        def sleep(seconds):
            nonlocal now
            now += seconds

        output = io.StringIO()
        with patch.object(shell.signal, "signal", set_signal), \
                patch.object(shell.subprocess, "Popen", Child), \
                patch.object(shell.time, "monotonic", lambda: now), \
                patch.object(shell.time, "sleep", sleep), contextlib.redirect_stderr(output):
            result = shell.supervise(["/usr/bin/plasmashell", "--no-respawn"])
        self.assertTrue(all(handler == signal.SIG_DFL for handler in handlers.values()))
        return result, starts, sent, output.getvalue()

    def test_qt_wayland_exit_restarts_shell(self):
        result, starts, _, log = self.drive([255, 0])  # QtWayland _exit(-1), no KCrash signal
        self.assertEqual(result, 0)
        self.assertEqual(len(starts), 2)
        self.assertIn("status=255", log)
        self.assertTrue(all(command[-1] == "--no-respawn" for command in starts))

    def test_normal_exit_and_session_signals_do_not_restart(self):
        for status in [0, -signal.SIGTERM, -signal.SIGINT, -signal.SIGHUP]:
            with self.subTest(status=status):
                self.assertEqual(len(self.drive([status])[1]), 1)

    def test_restart_storm_is_bounded(self):
        result, starts, _, log = self.drive([255, 255, 255])
        self.assertEqual(result, 1)
        self.assertEqual(len(starts), 3)
        self.assertIn("restart limit reached", log)

    def test_old_failures_age_out(self):
        self.assertEqual(len(self.drive([255, 255, 255, 0], [0, 0, 61, 0])[1]), 4)

    def test_shutdown_reaches_child_without_restart(self):
        for launching in [False, True]:
            result, starts, sent, _ = self.drive([255], terminate=not launching, launching=launching)
            self.assertEqual((result, len(starts), sent), (0, 1, [signal.SIGTERM]))

    def test_real_non_signal_failure_hits_restart_limit(self):
        command = [sys.executable, "-c", "import sys; sys.exit(255)"]
        with patch.object(shell.time, "sleep"), patch.object(shell.subprocess, "Popen", wraps=subprocess.Popen) as spawn:
            # Exercise real child exit status handling without launching a desktop.
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(shell.supervise(command), 1)
        self.assertEqual(spawn.call_count, 3)

    def test_override_is_private_and_retains_wayland_permissions(self):
        override = ROOT / "guest/layer/usr/lib/steamac/desktop-xdg/autostart/org.kde.plasmashell.desktop"
        text = override.read_text()
        self.assertIn("Exec=/usr/lib/steamac/desktop-shell\n", text)
        self.assertIn("X-systemd-skip=true", text)
        self.assertIn("zkde_screencast_unstable_v1", text)
        self.assertFalse((ROOT / "guest/layer/usr/lib/systemd/user/plasma-plasmashell.service.d").exists())


if __name__ == "__main__":
    unittest.main()
