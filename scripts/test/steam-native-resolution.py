#!/usr/bin/env python3
"""Regression checks for Steam's separate install-scoped UI resolution setting."""
from pathlib import Path
import runpy
import tempfile
from unittest.mock import patch
import unittest

ROOT = Path(__file__).resolve().parents[2]
hook = runpy.run_path(str(ROOT / "guest/layer/usr/lib/steamac/steam-native-resolution"))
KEY = tuple(part.lower() for part in hook["KEY"])


class NativeResolutionTests(unittest.TestCase):
    def test_fresh_install_uses_install_root(self):
        text = hook["native_resolution"]('"InstallConfigStore" {}')
        values, _ = hook["vdf"]["vdf_entries"](text)
        self.assertEqual(values[KEY][0], "1")
        self.assertEqual(len(values), 1)

    def test_existing_config_and_game_resolution_untouched(self):
        original = ('"InstallConfigStore" { "Software" { "Valve" { "Steam" { '
                    '"Gamescope" { "GameResolutionGlobal" "5120x2880" } } } } } // keep\n')
        text = hook["native_resolution"](original)
        self.assertIn('"GameResolutionGlobal" "5120x2880"', text)
        self.assertTrue(text.endswith('} // keep\n'))
        self.assertEqual(hook["native_resolution"](text), text)
        values, _ = hook["vdf"]["vdf_entries"](text)
        self.assertEqual(values[KEY][0], "1")

    def test_explicit_user_choice_wins(self):
        for value in ("0", "1"):
            text = '"InstallConfigStore" { "gamescope" { "EnableSteamNativeExternalResolution" "' + value + '" } }'
            self.assertEqual(hook["native_resolution"](text), text)

    def test_malformed_config_is_rejected(self):
        for text in ('"InstallConfigStore" {', '"UserLocalConfigStore" {}'):
            with self.assertRaises(ValueError):
                hook["native_resolution"](text)

    def test_marker_preserves_removed_key_and_reinstall_reapplies(self):
        with tempfile.TemporaryDirectory() as home, patch.dict("os.environ", HOME=home):
            hook["main"]()
            config = Path(home) / ".local/share/Steam/config/config.vdf"
            marker = config.parent / "steamac-native-resolution"
            self.assertEqual(marker.read_text(), "1\n")
            user = '"InstallConfigStore" { "Other" "keep" }\n'
            config.write_text(user)
            hook["main"]()
            self.assertEqual(config.read_text(), user)
            marker.unlink()
            hook["main"]()
            values, _ = hook["vdf"]["vdf_entries"](config.read_text())
            self.assertEqual(values[KEY][0], "1")

    def test_existing_choice_gets_marker_and_malformed_config_does_not(self):
        with tempfile.TemporaryDirectory() as home, patch.dict("os.environ", HOME=home):
            config = Path(home) / ".local/share/Steam/config/config.vdf"
            config.parent.mkdir(parents=True)
            marker = config.parent / "steamac-native-resolution"
            config.write_text('"InstallConfigStore" {')
            with self.assertRaises(ValueError):
                hook["main"]()
            self.assertFalse(marker.exists())
            user = '"InstallConfigStore" { "Gamescope" { "EnableSteamNativeExternalResolution" "0" } }'
            config.write_text(user)
            hook["main"]()
            self.assertEqual(config.read_text(), user)
            self.assertTrue(marker.exists())

    def test_startup_creates_config_and_preserves_permissions(self):
        with tempfile.TemporaryDirectory() as home, patch.dict("os.environ", HOME=home):
            hook["main"]()
            config = Path(home) / ".local/share/Steam/config/config.vdf"
            config.chmod(0o600)
            # Subsequent starts retain Steam's later explicit off choice.
            text = config.read_text().replace('"1"', '"0"')
            config.write_text(text)
            hook["main"]()
            self.assertEqual(config.read_text(), text)
            self.assertEqual(config.stat().st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
