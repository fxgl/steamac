#!/usr/bin/env python3
"""Regression checks for Steam's separate install-scoped UI resolution setting."""
from contextlib import contextmanager
from pathlib import Path
import runpy
import shutil
import subprocess
import sys
import tempfile
from unittest.mock import patch
import unittest

ROOT = Path(__file__).resolve().parents[2]
HOOK_PATH = ROOT / "guest/layer/usr/lib/steamac/steam-native-resolution"
hook = runpy.run_path(str(HOOK_PATH))
KEY = tuple(part.lower() for part in hook["KEY"])
GAME = tuple(part.lower() for part in hook["GAME_KEY"])
DEFAULT_ACCOUNT = '"UserLocalConfigStore" { "Gamescope" { "GameResolutionGlobal" "Default" } }'


def entries(text):
    return hook["vdf"]()["vdf_entries"](text)[0]


@contextmanager
def session(mode=(3840, 2160)):
    """A fresh HOME whose display currently has `mode` (a callable may change it later)."""
    with tempfile.TemporaryDirectory() as home, patch.dict("os.environ", HOME=home):
        display = {"mode": mode}
        with patch.dict(hook["preserve_game_defaults"].__globals__, preferred_mode=lambda: display["mode"]):
            yield Path(home) / ".local/share/Steam", display


def account(root, number, text=DEFAULT_ACCOUNT):
    config = root / f"userdata/{number}/config/localconfig.vdf"
    config.parent.mkdir(parents=True, exist_ok=True)
    config.write_text(text)
    return config


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
            self.assertEqual(entries(changed)[GAME][0], "1920x1080" if value in (None, "", "Default") else value)
            self.assertIn('"ResolutionOverride" "Native"', changed)

    def test_native_ui_waits_for_the_first_account(self):
        # A fresh install has no account config; the first session must not turn the native UI on
        # ahead of the cap: Steam creates the config while it runs and only a later start can edit it.
        with session() as (root, _):
            config = root / "config/config.vdf"
            marker = config.parent / "steamac-native-resolution"
            hook["main"]()
            self.assertFalse(config.exists() or marker.exists())
            hook["main"]()
            self.assertFalse(config.exists() or marker.exists())
            local = account(root, 123)
            hook["main"]()
            self.assertEqual(entries(local.read_text())[GAME][0], "1920x1080")
            self.assertEqual(entries(config.read_text())[KEY][0], "1")
            self.assertTrue(marker.exists())

    def test_accounts_added_after_install_and_later_choices(self):
        with session() as (root, _):
            account(root, 1)
            hook["main"]()
            later = account(root, 123)
            hook["main"]()
            self.assertIn('"1920x1080"', later.read_text())
            later.write_text(DEFAULT_ACCOUNT)
            hook["main"]()
            self.assertEqual(later.read_text(), DEFAULT_ACCOUNT)
            self.assertTrue((later.parent / "steamac-native-resolution").exists())

    def test_seeded_value_follows_the_display_until_the_user_changes_it(self):
        with session((1280, 800)) as (root, display):
            local = account(root, 123)
            hook["main"]()
            self.assertEqual(entries(local.read_text())[GAME][0], "1280x800")
            display["mode"] = (3840, 2160)
            hook["main"]()
            self.assertEqual(entries(local.read_text())[GAME][0], "1920x1080")
            display["mode"] = (2560, 1600)
            hook["main"]()
            self.assertEqual(entries(local.read_text())[GAME][0], "1920x1200")
            display["mode"] = (1280, 800)
            hook["main"]()
            self.assertEqual(entries(local.read_text())[GAME][0], "1280x800")
            # The user picks a value: it stays, however the display changes afterwards.
            chosen = local.read_text().replace('"1280x800"', '"2560x1440"')
            local.write_text(chosen)
            display["mode"] = (3840, 2160)
            hook["main"]()
            self.assertEqual(local.read_text(), chosen)
            # ... even when the user later picks the value that happens to be the old cap.
            local.write_text(chosen.replace('"2560x1440"', '"1280x800"'))
            hook["main"]()
            self.assertEqual(entries(local.read_text())[GAME][0], "1280x800")

    def test_removed_key_and_explicit_values_are_not_followed(self):
        with session((1280, 800)) as (root, display):
            removed = account(root, 1)
            explicit = account(root, 2, '"UserLocalConfigStore" { "Gamescope" { "GameResolutionGlobal" "Native" } }')
            hook["main"]()
            removed.write_text('"UserLocalConfigStore" { "Gamescope" { } }')
            display["mode"] = (3840, 2160)
            hook["main"]()
            self.assertNotIn(GAME, entries(removed.read_text()))
            self.assertEqual(entries(explicit.read_text())[GAME][0], "Native")

    def test_unreadable_account_does_not_stop_the_others(self):
        with session() as (root, _):
            broken = account(root, 1, '"UserLocalConfigStore" {')
            good = account(root, 2)
            hook["main"]()
            self.assertEqual(entries(good.read_text())[GAME][0], "1920x1080")
            self.assertFalse((broken.parent / "steamac-native-resolution").exists())
            self.assertEqual(broken.read_text(), '"UserLocalConfigStore" {')
            self.assertTrue((root / "config/steamac-native-resolution").exists())
            # Fixed later: handled on the next start.
            broken.write_text(DEFAULT_ACCOUNT)
            hook["main"]()
            self.assertEqual(entries(broken.read_text())[GAME][0], "1920x1080")

    def test_only_unreadable_accounts_keep_the_ui_off(self):
        with session() as (root, _):
            account(root, 1, '"UserLocalConfigStore" {')
            hook["main"]()
            self.assertFalse((root / "config/config.vdf").exists())

    def test_no_display_mode_skips_accounts_and_keeps_the_ui_off(self):
        with session() as (root, display):
            local = account(root, 1)

            def no_mode():
                raise ValueError("no preferred DRM display mode")
            with patch.dict(hook["preserve_game_defaults"].__globals__, preferred_mode=no_mode):
                hook["main"]()
            self.assertEqual(local.read_text(), DEFAULT_ACCOUNT)
            self.assertFalse((root / "config/config.vdf").exists())
            hook["main"]()
            self.assertEqual(entries(local.read_text())[GAME][0], "1920x1080")

    def test_fresh_install_uses_install_root(self):
        text = hook["native_resolution"]('"InstallConfigStore" {}')
        values = entries(text)
        self.assertEqual(values[KEY][0], "1")
        self.assertEqual(len(values), 1)

    def test_existing_config_and_game_resolution_untouched(self):
        original = ('"InstallConfigStore" { "Software" { "Valve" { "Steam" { '
                    '"Gamescope" { "GameResolutionGlobal" "5120x2880" } } } } } // keep\n')
        text = hook["native_resolution"](original)
        self.assertIn('"GameResolutionGlobal" "5120x2880"', text)
        self.assertTrue(text.endswith('} // keep\n'))
        self.assertEqual(hook["native_resolution"](text), text)
        self.assertEqual(entries(text)[KEY][0], "1")

    def test_explicit_user_choice_wins(self):
        for value in ("0", "1"):
            text = '"InstallConfigStore" { "gamescope" { "EnableSteamNativeExternalResolution" "' + value + '" } }'
            self.assertEqual(hook["native_resolution"](text), text)

    def test_malformed_config_is_rejected(self):
        for text in ('"InstallConfigStore" {', '"UserLocalConfigStore" {}'):
            with self.assertRaises(ValueError):
                hook["native_resolution"](text)

    def test_marker_preserves_removed_key_and_reinstall_reapplies(self):
        with session() as (root, _):
            account(root, 1)
            hook["main"]()
            config = root / "config/config.vdf"
            marker = config.parent / "steamac-native-resolution"
            self.assertEqual(marker.read_text(), "1\n")
            user = '"InstallConfigStore" { "Other" "keep" }\n'
            config.write_text(user)
            hook["main"]()
            self.assertEqual(config.read_text(), user)
            marker.unlink()
            hook["main"]()
            self.assertEqual(entries(config.read_text())[KEY][0], "1")

    def test_existing_choice_gets_marker_and_malformed_config_does_not(self):
        with session() as (root, _):
            config = root / "config/config.vdf"
            config.parent.mkdir(parents=True)
            marker = config.parent / "steamac-native-resolution"
            config.write_text('"InstallConfigStore" {')
            with self.assertRaises(ValueError):
                hook["main"]()
            self.assertFalse(marker.exists())
            # An explicit choice needs no account first: nothing is enabled.
            user = '"InstallConfigStore" { "Gamescope" { "EnableSteamNativeExternalResolution" "0" } }'
            config.write_text(user)
            hook["main"]()
            self.assertEqual(config.read_text(), user)
            self.assertTrue(marker.exists())

    def test_startup_preserves_permissions_and_later_off_choice(self):
        with session() as (root, _):
            account(root, 1)
            hook["main"]()
            config = root / "config/config.vdf"
            config.chmod(0o600)
            # Subsequent starts retain Steam's later explicit off choice.
            text = config.read_text().replace('"1"', '"0"')
            config.write_text(text)
            hook["main"]()
            self.assertEqual(config.read_text(), text)
            self.assertEqual(config.stat().st_mode & 0o777, 0o600)

    def test_missing_vdf_helper_is_logged_not_raised(self):
        with tempfile.TemporaryDirectory() as directory:
            lonely = Path(directory) / "steam-native-resolution"
            shutil.copy(HOOK_PATH, lonely)
            result = subprocess.run([sys.executable, str(lonely)], capture_output=True, text=True,
                                    env={"HOME": directory, "PATH": ""})
            self.assertEqual(result.returncode, 0)
            self.assertIn("leaving remaining settings unchanged", result.stderr)
            self.assertNotIn("Traceback", result.stderr)


if __name__ == "__main__":
    unittest.main()
