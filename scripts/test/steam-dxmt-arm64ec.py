#!/usr/bin/env python3
"""Native tool packaging: stock isolation, the run entry point, architecture checks, upgrades and rollback."""
import importlib.machinery
import importlib.util
from pathlib import Path
import os
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "guest/layer/usr/lib/steamac/steam-dxmt-arm64ec"
loader = importlib.machinery.SourceFileLoader("native_dxmt", str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
native = importlib.util.module_from_spec(spec)
sys.dont_write_bytecode = True
loader.exec_module(native)

# Stands in for proton: records how it was started; getcompatpath creates the prefix like proton does.
PROTON = """#!/bin/sh
# g_proton = Proton(os.path.dirname(sys.argv[0]))
printf '%s|%s|%s\\n' "$0" "$WINEDLLPATH" "$*" >> "$PROTON_CALLS"
[ "$1" = getcompatpath ] && mkdir -p "$STEAM_COMPAT_DATA_PATH/pfx/drive_c/windows/system32"
exit 0
"""


def pe(machine=0xaa64):
    data = bytearray(256)
    data[:2] = b"MZ"
    struct.pack_into("<I", data, 60, 128)
    data[64:80] = b"Wine builtin DLL"
    data[128:132] = b"PE\0\0"
    struct.pack_into("<H", data, 132, machine)
    return bytes(data)


class NativeToolTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        self.steam = self.root / "Steam"
        self.source = self.steam / "steamapps/common/Proton 11.0 (ARM64)"
        self.payload = self.root / "payload"
        self.dest = self.steam / "compatibilitytools.d" / native.DIRECTORY
        for name in ("version", "files/bin-arm64/wine", "files/lib/wine/aarch64-unix/ntdll.so",
                     "files/lib/wine/aarch64-windows/kernel32.dll", "files/share/fonts/arial.ttf",
                     "steampipe_fixups.json", "dist.lock"):
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("stock " + name)
        (self.source / "proton").write_text(PROTON)
        (self.source / "proton").chmod(0o755)
        (self.source / "toolmanifest.vdf").write_text('"manifest" { "commandline" "/proton %verb%" "require_tool_appid" "4185400" }\n')
        for arch in ("aarch64", "x86_64"):
            directory = self.source / f"files/lib/wine/dxvk/{arch}-windows"
            directory.mkdir(parents=True)
            for dll in ("d3d11", "dxgi", "d3d10core", "d3d9"):
                path = directory / (dll + ".dll")
                path.write_bytes(b"stock " + dll.encode())
                path.chmod(0o444)
        (self.payload / "aarch64-windows").mkdir(parents=True)
        (self.payload / "aarch64-unix").mkdir()
        for dll in native.DLLS:
            (self.payload / "aarch64-windows" / (dll + ".dll")).write_bytes(pe())
        elf = bytearray(64)
        elf[:6] = b"\x7fELF\x02\x01"
        struct.pack_into("<H", elf, 18, 183)
        (self.payload / "aarch64-unix/winemetal.so").write_bytes(elf)

    def tearDown(self):
        self.tmp.cleanup()

    def install(self):
        return native.install(self.source, self.payload, self.dest)

    def snapshot(self):
        return {str(f.relative_to(self.source)): f.read_bytes() for f in self.source.rglob("*") if f.is_file()}

    def run_tool(self, compatdata, *args):
        calls = self.root / "calls"
        calls.unlink(missing_ok=True)
        env = dict(os.environ, STEAM_COMPAT_DATA_PATH=str(compatdata), PROTON_CALLS=str(calls))
        env.pop("WINEDLLPATH", None)
        result = subprocess.run([str(self.dest / "tool/run"), *args], env=env, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return [line.split("|") for line in calls.read_text().splitlines()]

    def test_tool_links_into_untouched_stock_proton(self):
        before = self.snapshot()
        self.assertTrue(self.install())
        tool = self.dest / "tool"
        dxvk = tool / "files/lib/wine/dxvk/aarch64-windows"
        for dll in native.DXVK:
            self.assertFalse((dxvk / (dll + ".dll")).is_symlink())
            self.assertEqual((dxvk / (dll + ".dll")).read_bytes(), pe()[:64] + bytes(16) + pe()[80:])
        self.assertEqual((dxvk / "d3d9.dll").readlink(), self.source / "files/lib/wine/dxvk/aarch64-windows/d3d9.dll")
        self.assertEqual((tool / "files/lib/wine/aarch64-unix").readlink(), self.source / "files/lib/wine/aarch64-unix")
        self.assertEqual((tool / "proton").readlink(), self.source / "proton")
        # an x86-64 winemetal.dll entry in the prefix makes Wine look in x86_64-windows
        for arch in ("aarch64", "x86_64"):
            self.assertEqual((tool / f"dxmt/{arch}-windows/winemetal.dll").read_bytes(), pe())
        self.assertIn('"/run %verb%"', (tool / "toolmanifest.vdf").read_text())
        for name in ("steampipe_fixups.json", "dist.lock"):
            self.assertFalse((tool / name).exists() or (tool / name).is_symlink())
        # the legacy x86-64 installer must leave both the stock tool and this one alone
        env = dict(os.environ, HOME=str(self.root), STEAMAC_STEAM_ROOT=str(self.steam),
                   STEAMAC_CMDLINE=str(self.root / "cmdline"), STEAMAC_COMPAT_DEFAULT="/usr/bin/true")
        (self.root / "cmdline").write_text("steamac.gfx=vulkan")
        result = subprocess.run(["bash", str(SCRIPT.with_name("steam-gfx-path"))], env=env, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(before, self.snapshot())
        self.assertFalse((dxvk / "d3d11.dll").is_symlink())

    def test_run_starts_proton_from_the_tool_and_replaces_an_old_winemetal_entry(self):
        self.install()
        compatdata = self.root / "compatdata/894020"
        system32 = compatdata / "pfx/drive_c/windows/system32"
        system32.mkdir(parents=True)
        other = self.root / "Proton 10.0 winemetal.dll"
        other.write_bytes(b"x86-64 winemetal")
        (system32 / "winemetal.dll").symlink_to(other)
        calls = self.run_tool(compatdata, "waitforexitandrun", "game.exe")
        tool = self.dest / "tool"
        self.assertEqual(calls, [[str(tool / "proton"), str(tool / "dxmt"), "waitforexitandrun game.exe"]])
        self.assertFalse((system32 / "winemetal.dll").is_symlink())
        self.assertEqual((system32 / "winemetal.dll").read_bytes(), pe())
        self.assertEqual(other.read_bytes(), b"x86-64 winemetal")

    def test_run_has_proton_create_a_new_prefix_first(self):
        self.install()
        compatdata = self.root / "compatdata/894020"
        calls = self.run_tool(compatdata, "waitforexitandrun", "game.exe")
        self.assertEqual([call[2] for call in calls], ["getcompatpath /", "waitforexitandrun game.exe"])
        self.assertEqual((compatdata / "pfx/drive_c/windows/system32/winemetal.dll").read_bytes(), pe())

    def test_refuses_a_proton_that_resolves_its_directory(self):
        (self.source / "proton").write_text(PROTON.replace("os.path.dirname(sys.argv[0])", "os.path.dirname(os.path.realpath(sys.argv[0]))"))
        with self.assertRaisesRegex(ValueError, "argv"):
            self.install()
        self.assertFalse(self.dest.exists())

    def test_update_and_noop(self):
        self.install()
        marker = self.dest / native.RECEIPT
        timestamp = marker.stat().st_mtime_ns
        self.assertFalse(self.install())
        self.assertEqual(marker.stat().st_mtime_ns, timestamp)
        # a new entry in a directory the tool keeps real must appear in it
        (self.source / "files/lib/wine/dxvk/aarch64-windows/d3d8.dll").write_bytes(b"stock d3d8")
        self.assertTrue(self.install())
        self.assertEqual((self.dest / "tool/files/lib/wine/dxvk/aarch64-windows/d3d8.dll").read_bytes(), b"stock d3d8")
        self.assertFalse((self.dest / "previous").exists())

    def test_rejects_wrong_architecture_without_changing_installed_tool(self):
        self.install()
        before = (self.dest / native.RECEIPT).read_bytes()
        (self.payload / "aarch64-windows/d3d11.dll").write_bytes(pe(0x8664))
        with self.assertRaisesRegex(ValueError, "ARM64X/ARM64EC"):
            self.install()
        self.assertEqual((self.dest / native.RECEIPT).read_bytes(), before)

    def test_refuses_unmanaged_or_running_tool(self):
        self.dest.mkdir(parents=True)
        with self.assertRaisesRegex(ValueError, "unmanaged"):
            self.install()
        self.dest.rmdir()
        self.install()
        (self.source / "version").write_text("update")
        with patch.object(native, "in_use", return_value=True):
            with self.assertRaisesRegex(ValueError, "close games"):
                self.install()

    def test_failed_build_keeps_previous_tool(self):
        self.install()
        before = (self.dest / native.RECEIPT).read_bytes()
        (self.source / "version").write_text("update")
        with patch.object(native.shutil, "copyfile", side_effect=OSError("disk full")):
            with self.assertRaises(OSError):
                self.install()
        self.assertEqual((self.dest / native.RECEIPT).read_bytes(), before)
        self.assertEqual(list(self.dest.parent.glob(".dxmt-arm64ec-*")), [])


if __name__ == "__main__":
    unittest.main()
