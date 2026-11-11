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
    def test_legacy_cap_matches_steam(self):
        for mode, expected in [((3840, 2160), (1920, 1080)), ((2560, 1600), (1920, 1200)),
                               ((3440, 1440), (1920, 1080)), ((1280, 800), (1280, 800)),
                               ((1920, 1200), (1920, 1200)), ((1920, 1080), (1920, 1080))]:
            self.assertEqual(hook["legacy_resolution"](*mode), expected)

    def test_game_default_only_and_per_game_values_untouched(self):
        for value in (None, "", "Default", "Native", "1280x720", "5120x2880"):
            entry = '' if value is None else '"GameResolutionGlobal" "' + value + '"'
            text = '"UserLocalConfigStore" { "Gamescope" { ' + entry + ' } "Apps" { "1172620" { "ResolutionOverride" "Native" } } }'
            changed = hook["game_resolution"](text, (1920, 1080))
            values, _ = hook["vdf"]["vdf_entries"](changed)
            key = tuple(part.lower() for part in hook["GAME_KEY"])
            self.assertEqual(values[key][0], "1920x1080" if value in (None, "", "Default") else value)
            self.assertIn('"ResolutionOverride" "Native"', changed)

    def test_accounts_added_after_install_and_later_choices(self):
        with tempfile.TemporaryDirectory() as home, patch.dict("os.environ", HOME=home):
            hook["main"]()
            root = Path(home) / ".local/share/Steam"
            config = root / "userdata/123/config/localconfig.vdf"
            config.parent.mkdir(parents=True)
            original = '"UserLocalConfigStore" { "Gamescope" { "GameResolutionGlobal" "Default" } }'
            config.write_text(original)
            with patch.dict(hook["preserve_game_defaults"].__globals__, preferred_mode=lambda: (3840, 2160)):
                hook["main"]()
                self.assertIn('"1920x1080"', config.read_text())
                config.write_text(original)
                hook["main"]()
                self.assertEqual(config.read_text(), original)
                self.assertTrue((config.parent / "steamac-native-resolution").exists())

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
