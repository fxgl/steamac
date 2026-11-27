#!/usr/bin/env python3
"""Host-side parser/ownership checks; VM coverage also requires real Steam files."""
import importlib.machinery
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

path = Path(__file__).resolve().parents[2] / "guest/layer/usr/lib/steamac/mac-clock-format"
sys.dont_write_bytecode = True
sys.path.insert(0, str(path.parent))
loader = importlib.machinery.SourceFileLoader("mac_clock_format", str(path))
spec = importlib.util.spec_from_loader(loader.name, loader)
clock = importlib.util.module_from_spec(spec)
loader.exec_module(clock)
KEY = ("UserLocalConfigStore", "Software", "Valve", "Steam", "FriendsUI", "FriendsUIJSON")


class ClockFormatTests(unittest.TestCase):
    def test_missing_containers(self):
        for depth in range(1, len(KEY)):
            text = "".join('"' + k + '"\n{\n' for k in KEY[:depth]) + '"Unrelated" "keep"\n' + "}\n" * depth
            changed = clock.vdf_set(text, KEY, '{"b24HourClock":true}')
            values, _, _ = clock.vdf_entries(changed)
            self.assertEqual(json.loads(values[tuple(k.lower() for k in KEY)][0]), {"b24HourClock": True})
            self.assertIn('"Unrelated" "keep"', changed)

    def test_existing_json_keeps_other_settings(self):
        prefs = {"b24HourClock": False, "name": 'quoted "name" \\ path', "other": 3}
        text = '"UserLocalConfigStore" { "Software" { "Valve" { "Steam" { "FriendsUI" { "FriendsUIJSON" ' + clock.vdf_quote(json.dumps(prefs)) + ' } } } } } // retained\n'
        values, _, _ = clock.vdf_entries(text)
        prefs = json.loads(values[tuple(k.lower() for k in KEY)][0])
        prefs["b24HourClock"] = True
        changed = clock.vdf_set(text, KEY, json.dumps(prefs))
        values, _, _ = clock.vdf_entries(changed)
        self.assertEqual(json.loads(values[tuple(k.lower() for k in KEY)][0]), prefs)
        self.assertTrue(changed.endswith('// retained\n'))

    def test_user_override_is_sticky(self):
        marker = {}
        self.assertTrue(clock.follows(marker, None))
        marker["last"] = True
        self.assertTrue(clock.follows(marker, True))
        self.assertFalse(clock.follows(marker, False))
        self.assertFalse(clock.follows(marker, True))
        self.assertTrue(marker["user"])

    def test_malformed_vdf_is_rejected(self):
        for text in ['"UserLocalConfigStore" {', '}', '"key"', '"store" { "key" }',
                     '"store" { "key" "1" "key" "2" }', '"UserLocalConfigStore" {} "']:
            with self.assertRaises(ValueError):
                clock.vdf_entries(text)

    def test_repeated_blocks_with_distinct_values_are_allowed(self):
        values, _, _ = clock.vdf_entries('"Store" { "First" "1" } "store" { "Second" "2" }')
        self.assertEqual({key: value[0] for key, value in values.items()},
                         {("store", "first"): "1", ("store", "second"): "2"})

    def test_unterminated_quote_leaves_account_config_untouched(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            config = home / ".local/share/Steam/userdata/123/config/localconfig.vdf"
            config.parent.mkdir(parents=True)
            bad = b'"UserLocalConfigStore" {}\n"\n'
            config.write_bytes(bad)
            (home / ".config").mkdir()
            (home / ".config/plasma-localerc").write_text("[Formats]\nLC_TIME=en_GB.UTF-8\n")
            read_file = Path.read_text

            def read_text(path, *args, **kwargs):
                if path == Path("/proc/cmdline"):
                    return "steamac.clock24=1"
                return read_file(path, *args, **kwargs)

            with patch.object(Path, "read_text", read_text), patch.object(Path, "home", return_value=home), \
                    patch("sys.stderr", new_callable=io.StringIO) as log:
                clock.main()
            self.assertIn("invalid VDF token", log.getvalue())
            self.assertEqual(config.read_bytes(), bad)
            state = json.loads((home / ".config/steamac/mac-clock24.json").read_text())
            self.assertEqual(state["accounts"], {})


if __name__ == "__main__":
    unittest.main()
