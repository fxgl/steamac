#!/usr/bin/env python3
"""Host-side VDF, mount gating, filesystem and once-per-path checks for steam-share-library."""
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
SCRIPT = Path(__file__).resolve().parents[2] / "guest/layer/usr/lib/steamac/steam-share-library"
loader = importlib.machinery.SourceFileLoader("steam_share_library", str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
share = importlib.util.module_from_spec(spec)
loader.exec_module(share)
EXISTING = ('"libraryfolders"\n{\n\t"0" { "path" "/internal" "contentid" "123" "totalsize" "456" "apps" { "42" "789" } }\n'
            '\t"3" { "path" "/other" "label" "keep" } // preserve\n}\n')


class ShareLibraryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / "Steam"
        self.mount = Path(self.tmp.name) / "Mac Share"
        self.mount.mkdir()
        self.library = self.mount / "SteamLibrary"
        self.config = self.root / "steamapps/libraryfolders.vdf"
        self.marker = self.root / "config/steamac-share-library.json"

    def write_config(self, text=EXISTING):
        self.config.parent.mkdir(parents=True, exist_ok=True)
        self.config.write_text(text)

    def test_no_file_creates_internal_and_shared_library(self):
        share.register_library(self.root, self.mount)
        values, _ = share.vdf_entries(self.config.read_text())
        self.assertEqual(values[("libraryfolders", "0", "path")][0], str(self.root))
        self.assertEqual(values[("libraryfolders", "1", "path")][0], str(self.library))
        self.assertNotIn(("libraryfolders", "1", "contentid"), values)
        self.assertTrue((self.library / "steamapps").is_dir())
        self.assertEqual(json.loads(self.marker.read_text()), [str(self.library)])
        self.assertEqual(list(self.mount.glob(".steamac-library-*")), [])

    def test_existing_libraries_preserved_and_next_free_index(self):
        self.write_config()
        self.config.chmod(0o640)
        share.register_library(self.root, self.mount)
        text = self.config.read_text()
        self.assertIn('\t"4"\n', text)
        self.assertEqual(text[:text.index('\t"4"\n')] + '}\n', EXISTING)
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o640)

    def test_existing_path_not_duplicated(self):
        for entry in ['"7" { "path" ' + share.vdf_quote(str(self.library)) + ' }',
                      '"7" ' + share.vdf_quote(str(self.library) + '/')]:
            original = '"LibraryFolders" { ' + entry + ' } // retained\n'
            changed = share.add_library(original, self.library, self.root)
            self.assertEqual(changed, original)
        self.write_config(original)
        share.register_library(self.root, self.mount)
        self.assertEqual(self.config.read_text(), original)
        self.assertTrue(self.marker.exists())

    def test_legacy_file_used_only_without_authoritative_file(self):
        legacy = self.root / "config/libraryfolders.vdf"
        legacy.parent.mkdir(parents=True)
        legacy.write_text(EXISTING)
        share.register_library(self.root, self.mount)
        self.assertIn('"/other"', self.config.read_text())
        self.assertEqual(legacy.read_text(), EXISTING)

    def test_removed_library_stays_removed_even_after_switching_paths(self):
        share.register_library(self.root, self.mount)
        self.write_config()
        other = self.mount / "other-share"
        other.mkdir()
        share.register_library(self.root, other)
        after_other = self.config.read_bytes()
        with patch.object(share, "supports_symlinks", side_effect=AssertionError("must not touch removed library")):
            share.register_library(self.root, self.mount)
        self.assertEqual(self.config.read_bytes(), after_other)
        self.assertEqual(json.loads(self.marker.read_text()), [str(self.library), str(other / "SteamLibrary")])

    def test_unmounted_or_disabled_share_never_changes_files(self):
        cmdline = Path(self.tmp.name) / "cmdline"
        env = {"STEAMAC_CMDLINE": str(cmdline), "STEAMAC_STEAM_ROOT": str(self.root)}
        for args in ['steamac.share=/home/steamos/MacShare steamac.share_library=1',
                     'steamac.share=/home/steamos/MacShare steamac.share_library=0',
                     'steamac.share_library=1']:
            cmdline.write_text(args)
            with patch.dict(os.environ, env), patch.object(share.subprocess, "run", return_value=subprocess.CompletedProcess([], 1)) as findmnt:
                share.main()
            self.assertFalse(self.root.exists())
            self.assertEqual(list(self.mount.iterdir()), [])
            if 'share_library=1' in args and 'steamac.share=' in args:
                self.assertEqual(findmnt.call_args.args[0], ['findmnt', '--mountpoint', '/home/steamos/MacShare', '--types', 'virtiofs', '--noheadings'])
            else:
                findmnt.assert_not_called()

    def test_mounted_flag_calls_registration_and_rejects_invalid_paths(self):
        cmdline = Path(self.tmp.name) / "cmdline"
        with patch.dict(os.environ, {"STEAMAC_CMDLINE": str(cmdline), "STEAMAC_STEAM_ROOT": str(self.root)}), \
                patch.object(share.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)), \
                patch.object(share, "register_library") as register:
            cmdline.write_text('steamac.share=/home/steamos/MacShare steamac.share_library=1')
            share.main()
            register.assert_called_once_with(self.root, Path('/home/steamos/MacShare'))
            for bad in ['/home/steamos/', '/home/steamos/a/../b', '/home/steamos//a', '/tmp/share', '/home/steamos/a/']:
                cmdline.write_text('steamac.share=' + bad + ' steamac.share_library=1')
                with self.assertRaises(ValueError):
                    share.main()

    def test_unsupported_symlinks_or_bad_vdf_leave_list_and_marker_alone(self):
        self.write_config()
        with patch.object(Path, "symlink_to", side_effect=OSError("not supported")):
            with self.assertRaises(OSError):
                share.register_library(self.root, self.mount)
        self.assertEqual(self.config.read_text(), EXISTING)
        self.assertFalse(self.marker.exists())
        self.assertFalse(self.library.exists())
        self.assertEqual(list(self.mount.iterdir()), [])
        for bad in ['"libraryfolders" {', '}', '"other" {}', '"libraryfolders" { "1" {} "1" {} }']:
            self.write_config(bad)
            with self.assertRaises(ValueError):
                share.register_library(self.root, self.mount)
            self.assertEqual(self.config.read_text(), bad)
            self.assertFalse(self.marker.exists())

    def test_quoted_paths_comments_and_single_line_vdf(self):
        library = Path('/home/steamos/quotes"and\\slashes/SteamLibrary')
        text = '"libraryfolders" { "0" "/internal" } // retained\n'
        changed = share.add_library(text, library, self.root)
        values, _ = share.vdf_entries(changed)
        self.assertEqual(values[("libraryfolders", "1", "path")][0], str(library))
        self.assertTrue(changed.endswith('} // retained\n'))

    def test_entrypoint_errors_do_not_block_steam(self):
        result = subprocess.run([sys.executable, str(SCRIPT)], env={**os.environ, "STEAMAC_CMDLINE": str(self.mount / "absent")}, capture_output=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn(b'could not register', result.stderr)


if __name__ == "__main__":
    unittest.main()
