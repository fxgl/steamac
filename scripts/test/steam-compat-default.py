#!/usr/bin/env python3
"""guest/layer/usr/lib/steamac/steam-compat-default against Steam files built on the host."""
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "guest/layer/usr/lib/steamac/steam-compat-default"
_loader = importlib.machinery.SourceFileLoader("steam_compat_default", str(SCRIPT))
_spec = importlib.util.spec_from_loader(_loader.name, _loader)
assert _spec is not None
compat = importlib.util.module_from_spec(_spec)
sys.dont_write_bytecode = True
_loader.exec_module(compat)

CONFIG = '''"InstallConfigStore"
{
\t"Software"
\t{
\t\t"Valve"
\t\t{
\t\t\t"Steam"
\t\t\t{
\t\t\t\t"AutoUpdateWindowEnabled"\t\t"0"
%s\t\t\t\t"SentryFile"\t\t"C:\\\\Steam\\\\ssfn"
\t\t\t}
\t\t}
\t}
}
'''
USER_TOOL = '''\t\t\t\t"CompatToolMapping"
\t\t\t\t{
\t\t\t\t\t"883710"
\t\t\t\t\t{
\t\t\t\t\t\t"name"\t\t"proton_9"
\t\t\t\t\t\t"config"\t\t""
\t\t\t\t\t\t"priority"\t\t"250"
\t\t\t\t\t}
\t\t\t\t}
'''
# appid: (type, oslist)
APPS = {
    "894020": ("Game", "windows"),             # Death's Door: mapped
    "883710": ("Game", "windows"),             # has the user's own tool in USER_TOOL fixtures
    "3564860": ("Demo", "windows"),            # mapped
    "270880": ("Game", "windows,macos,linux"),  # native Linux build: left alone
    "3127680": ("Tool", "linux"),              # Steam's FEX tool: never mapped
    "228980": ("Tool", "windows,macos,linux"),
}


def appinfo_v29(apps):
    """A minimal appinfo.vdf v29: binary KeyValues whose keys index a trailing string table."""
    table = []

    def key(name):
        if name not in table:
            table.append(name)
        return struct.pack("<I", table.index(name))

    def kv(node):
        out = b""
        for name, value in node.items():
            if isinstance(value, dict):
                out += b"\x00" + key(name) + kv(value)
            elif isinstance(value, int):
                out += b"\x02" + key(name) + struct.pack("<i", value)
            else:
                out += b"\x01" + key(name) + value.encode() + b"\0"
        return out + b"\x08"

    body = b""
    for appid, (kind, oslist) in apps.items():
        data = kv({"appinfo": {"appid": int(appid), "common": {"name": "x", "type": kind, "oslist": oslist}}})
        entry = struct.pack("<IIQ", 2, 0, 0) + b"\0" * 20 + struct.pack("<I", 1) + b"\0" * 20 + data
        body += struct.pack("<II", int(appid), len(entry)) + entry
    body += struct.pack("<I", 0)
    strings = struct.pack("<I", len(table)) + b"".join(name.encode() + b"\0" for name in table)
    header_size = 16
    return struct.pack("<IIq", 0x07564429, 1, header_size + len(body)) + body + strings


class CompatDefaultTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.steam = root / "Steam"
        self.config = self.steam / "config/config.vdf"
        self.marker = root / "state/compat-default.json"
        self.profiles = root / ".config/steamac/game-profiles.json"
        self.profiles.parent.mkdir(parents=True)
        self.profiles.write_text(json.dumps({"v": 1, "games": {a: {"gfx": "dxmt"} for a in APPS}}))
        self.env = dict(os.environ, HOME=str(root), XDG_RUNTIME_DIR=str(root / "runtime"),
                        STEAMAC_STEAM_ROOT=str(self.steam), STEAMAC_GFX_STATE=str(root / "state"))
        (self.steam / "appcache").mkdir(parents=True)
        (self.steam / "appcache/appinfo.vdf").write_bytes(appinfo_v29(APPS))
        (self.steam / "steamapps").mkdir()
        apps = "".join('\t\t\t"%s"\t\t"1"\n' % a for a in APPS)
        (self.steam / "steamapps/libraryfolders.vdf").write_text(
            '"libraryfolders"\n{\n\t"0"\n\t{\n\t\t"path"\t\t"/x"\n\t\t"apps"\n\t\t{\n' + apps + '\t\t}\n\t}\n}\n')

    def tearDown(self):
        self.tmp.cleanup()

    def run_mode(self, mode):
        result = subprocess.run([sys.executable, str(SCRIPT), mode], env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stderr

    def write(self, text):
        self.config.parent.mkdir(parents=True, exist_ok=True)
        self.config.write_text(text)

    def mapped(self):
        return compat.mappings(self.config.read_text())

    def test_windows_games_only(self):
        self.write(CONFIG % "")
        self.run_mode("dxmt")
        self.assertEqual(self.mapped(), {a: compat.OURS for a in ("883710", "894020", "3564860")})
        self.assertIn('"SentryFile"\t\t"C:\\\\Steam\\\\ssfn"', self.config.read_text())
        self.run_mode("dxmt")   # idempotent
        self.assertEqual(len(self.mapped()), 3)
        self.run_mode("vulkan")
        self.assertEqual(self.mapped(), {})
        self.assertFalse(self.marker.exists())

    def test_never_the_wildcard(self):
        self.write(CONFIG % "")
        self.run_mode("dxmt")
        self.assertNotIn("0", self.mapped())
        self.assertNotIn("3127680", self.mapped())

    def test_users_own_tool_kept(self):
        self.write(CONFIG % USER_TOOL)
        self.run_mode("dxmt")
        self.assertEqual(self.mapped()["883710"]["name"], "proton_9")
        self.assertEqual(json.loads(self.marker.read_text())["mapped"], ["3564860", "894020"])
        self.run_mode("vulkan")
        self.assertEqual(self.mapped(), {"883710": {"name": "proton_9", "config": "", "priority": "250"}})

    def test_changed_in_steam_after_us(self):
        self.write(CONFIG % "")
        self.run_mode("dxmt")
        text = self.config.read_text()
        text = compat.set_mapping(text, "894020", {"name": "proton_11-arm64", "config": "", "priority": "250"})
        self.write(text)
        self.assertIn("changed in Steam", self.run_mode("dxmt"))
        self.run_mode("vulkan")
        self.assertEqual(self.mapped(), {"894020": {"name": "proton_11-arm64", "config": "", "priority": "250"}})

    def test_no_config_yet(self):
        self.run_mode("dxmt")
        self.run_mode("vulkan")
        self.assertFalse(self.config.exists())
        self.assertFalse(self.marker.exists())


    def test_profile_subset_removes_old_blanket_entries(self):
        self.write(CONFIG % USER_TOOL)
        # An old guest mapped every eligible Windows game. Its existing marker
        # is the authority for cleaning those entries during the new cutover.
        self.run_mode("dxmt")
        self.profiles.write_text(json.dumps({"v": 1, "games": {
            "894020": {"gfx": "dxmt"}, "3564860": {"gfx": "vulkan"},
            "883710": {"gfx": "dxmt"}, "270880": {"gfx": "dxmt"},
        }}))
        self.run_mode("dxmt")
        self.assertEqual(self.mapped(), {
            "894020": compat.OURS,
            "883710": {"name": "proton_9", "config": "", "priority": "250"},
        })
        self.assertEqual(json.loads(self.marker.read_text())["mapped"], ["894020"])
        self.profiles.write_text('{"v":1,"games":{}}')
        self.run_mode("dxmt")
        self.assertEqual(set(self.mapped()), {"883710"})
        self.assertFalse(self.marker.exists())

    def test_no_profiles_never_blanket_maps(self):
        self.profiles.unlink()
        self.write(CONFIG % "")
        self.run_mode("dxmt")
        self.assertEqual(self.mapped(), {})

    def test_non_dxmt_boot_never_maps_dxmt_profiles(self):
        self.write(CONFIG % "")
        self.run_mode("vulkan")
        self.assertEqual(self.mapped(), {})

    def test_steam_start_snapshot_wins_over_new_host_edit(self):
        self.write(CONFIG % "")
        snapshot = Path(self.env["XDG_RUNTIME_DIR"]) / "steamac/game-profiles.json"
        snapshot.parent.mkdir(parents=True)
        snapshot.write_text('{"v":1,"games":{"3564860":{"gfx":"dxmt"}}}')
        self.run_mode("dxmt")
        self.assertEqual(self.mapped(), {"3564860": compat.OURS})

    def native_tool(self):
        root = self.steam / "compatibilitytools.d/steamac-dxmt-arm64ec"
        lib = root / "tool/files/lib/wine/aarch64-unix/winemetal.so"
        lib.parent.mkdir(parents=True)
        lib.write_bytes(b"native")
        (root / ".steamac-arm64ec.json").write_text('{}')
        return root

    def test_native_tool_migrates_our_mappings_and_restores(self):
        self.write(CONFIG % USER_TOOL)
        self.run_mode("dxmt")
        self.native_tool()
        self.run_mode("dxmt")
        self.assertEqual(self.mapped()["894020"]["name"], compat.NATIVE_TOOL)
        self.assertEqual(self.mapped()["883710"]["name"], "proton_9")
        self.assertEqual(json.loads(self.marker.read_text())["tool"], compat.NATIVE_TOOL)
        self.run_mode("vulkan")
        self.assertEqual(set(self.mapped()), {"883710"})

    def test_native_tool_preserves_user_edit_and_falls_back_if_removed(self):
        self.write(CONFIG % "")
        native = self.native_tool()
        self.run_mode("dxmt")
        own = {"name": "proton_9", "config": "", "priority": "250"}
        self.write(compat.set_mapping(self.config.read_text(), "894020", own))
        (native / ".steamac-arm64ec.json").unlink()
        self.run_mode("dxmt")
        self.assertEqual(self.mapped()["894020"], own)
        self.assertEqual(self.mapped()["3564860"], compat.OURS)

if __name__ == "__main__":
    unittest.main()
