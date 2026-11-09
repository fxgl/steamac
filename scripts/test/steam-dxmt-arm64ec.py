#!/usr/bin/env python3
"""Native tool packaging: architecture checks, stock isolation, upgrades and rollback."""
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
        self.root = Path(self.tmp.name)
        self.steam = self.root / "Steam"
        self.source = self.steam / "steamapps/common/Proton 11.0 (ARM64)"
        self.payload = self.root / "payload"
        self.dest = self.steam / "compatibilitytools.d" / native.DIRECTORY
        for name in ("proton", "version", "toolmanifest.vdf", "files/bin-arm64/wine",
                     "files/lib/wine/aarch64-unix/ntdll.so"):
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("stock " + name)
        (self.source / "files/share/default_pfx_arm64/drive_c/windows/system32").mkdir(parents=True)
        for arch in ("aarch64", "x86_64"):
            (self.source / f"files/lib/wine/{arch}-windows").mkdir()
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

    def test_stock_is_untouched_and_legacy_installer_skips_nested_tool(self):
        before = self.snapshot()
        self.assertTrue(self.install())
        wine = self.dest / "tool/files/lib/wine"
        for arch in ("aarch64", "x86_64"):
            self.assertEqual((wine / f"dxvk/{arch}-windows/d3d11.dll").read_bytes()[64:80], bytes(16))
            self.assertEqual((wine / f"{arch}-windows/winemetal.dll").read_bytes()[64:80], b"Wine builtin DLL")
            self.assertEqual((wine / f"dxvk/{arch}-windows/d3d9.dll").read_bytes(), b"stock d3d9")
        link = self.dest / "tool/files/share/default_pfx_arm64/drive_c/windows/system32/winemetal.dll"
        self.assertTrue(link.is_symlink())
        self.assertEqual(link.read_bytes(), pe())
        env = dict(os.environ, HOME=str(self.root), STEAMAC_STEAM_ROOT=str(self.steam),
                   STEAMAC_CMDLINE=str(self.root / "cmdline"), STEAMAC_COMPAT_DEFAULT="/usr/bin/true")
        (self.root / "cmdline").write_text("steamac.gfx=vulkan")
        result = subprocess.run(["bash", str(SCRIPT.with_name("steam-gfx-path"))], env=env, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(link.exists())
        self.assertEqual(before, self.snapshot())

    def test_update_and_noop(self):
        self.install()
        marker = self.dest / native.RECEIPT
        timestamp = marker.stat().st_mtime_ns
        self.assertFalse(self.install())
        self.assertEqual(marker.stat().st_mtime_ns, timestamp)
        (self.source / "version").write_text("new Proton")
        self.assertTrue(self.install())
        self.assertIn("new Proton", (self.dest / "tool/version").read_text())
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

    def test_failed_copy_keeps_previous_tool(self):
        self.install()
        before = (self.dest / native.RECEIPT).read_bytes()
        (self.source / "version").write_text("update")
        with patch.object(native.shutil, "copytree", side_effect=OSError("disk full")):
            with self.assertRaises(OSError):
                self.install()
        self.assertEqual((self.dest / native.RECEIPT).read_bytes(), before)
        self.assertEqual(list(self.dest.parent.glob(".dxmt-arm64ec-*")), [])


if __name__ == "__main__":
    unittest.main()
