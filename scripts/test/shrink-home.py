#!/usr/bin/env python3
"""Run the initramfs's real shrink_home/shrink_abort (guest/initramfs/init) against stubs.

The functions are cut out of the script, not copied: only what they call (chroot, mount,
poweroff, getarg ...) is replaced. The checks cover the one-shot path the host relies on: the
e2fsck status, the block size, the size check, and that every failure powers off instead of
dropping into a shell.

Set SHRINK_HOME_REAL_TOOLS to the existing builder image tag to also run the exact
shrink function with Linux e2fsprogs on a disposable ext4 file in a container.
"""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
INIT = (ROOT / "guest/initramfs/init").read_text()
match = re.search(r"^shrink_home\(\) \{.*?^shrink_home\n", INIT, re.MULTILINE | re.DOTALL)
assert match, "shrink_home not found in guest/initramfs/init"
helpers = re.search(r"^shrink_result\(\) \{.*?(?=^wait_part esp)", INIT, re.MULTILINE | re.DOTALL)
assert helpers, "shrink result helpers not found in guest/initramfs/init"
FUNCTIONS = helpers.group(0) + match.group(0)

STUBS = r"""
LOG=$STUB_LOG
msg()  { echo "msg: $*" >> "$LOG"; }
warn() { echo "warn: $*" >> "$LOG"; }
fatal() { echo "FATAL: $*" >> "$LOG"; exit 99; }
getarg() {
    case "$1" in
        steamac.shrink-home) echo "$GIB" ;;
        steamac.shrink-home-partuuid) echo "$SHRINK_UUID" ;;
    esac
}
part_dev() { echo "${REAL_HOME:-/dev/vda7}"; }
part_field() { echo "$DISK_UUID"; }
mount() { echo "mount $*" >> "$LOG"; }
umount() { echo "umount $*" >> "$LOG"; }
sync() { echo "sync" >> "$LOG"; }
fx_find_port() { :; }
fx_say() { echo "fx: $*" >> "$LOG"; }
poweroff() { echo "POWEROFF" >> "$LOG"; exit 0; }
chroot() {
    shift   # the root
    path=$1; tool=${1##*/}; shift
    echo "chroot $tool $*" >> "$LOG"
    if [ -n "$REAL_HOME" ]; then "$path" "$@"; return; fi
    case "$tool" in
        e2fsck)    FSCK_CALLS=$((${FSCK_CALLS:-0} + 1))
                   if [ "$FSCK_CALLS" -eq 1 ]; then return "${E2FSCK_RC:-0}"; fi
                   return "${REPAIR_RC:-0}" ;;
        tune2fs)   echo "Block size:               ${BLOCK_SIZE-4096}"
                   echo "Block count:              ${BLOCK_COUNT-16777216}" ;;
        resize2fs) case "$1" in
                       -P) echo "Estimated minimum size of the filesystem: ${MIN_BLOCKS:-1000}" ;;
                       *)  return "${RESIZE_RC:-0}" ;;
                   esac ;;
    esac
}
"""


def run(gib="8", forced="stop", **env):
    with tempfile.TemporaryDirectory() as directory:
        log = Path(directory) / "log"
        log.write_text("")
        script = STUBS + FUNCTIONS.replace("\nshrink_home\n", "\n") + "\nshrink_home\necho REACHED-END >> \"$LOG\"\n"
        result = subprocess.run(["/bin/sh", "-c", script], capture_output=True, text=True,
                                env={"STUB_LOG": str(log), "GIB": gib, "FORCED": forced, "PATH": "/usr/bin:/bin", **env})
        return result.returncode, log.read_text().splitlines()


def commands(lines, tool):
    return [l for l in lines if l.startswith(f"chroot {tool} ")]


class ShrinkHomeTests(unittest.TestCase):
    def test_clean_filesystem_is_shrunk_and_the_vm_powers_off(self):
        code, log = run()
        self.assertEqual(code, 0)
        self.assertEqual(log[-1], "POWEROFF")
        self.assertIn("chroot resize2fs /dev/vda7 8G", log)
        self.assertIn("fx: shrink done 8", log)
        self.assertNotIn("REACHED-END", log)
        self.assertEqual(log[-3:-1], ["fx: shrink done 8", "msg: shrink-home: filesystem fits within 8G; powering off for the host's partition table rewrite"])
        self.assertEqual(log[-4], "sync")

    def test_fitting_filesystem_is_checked_but_not_grown(self):
        code, log = run(BLOCK_COUNT="1048576", E2FSCK_RC="1")
        self.assertEqual(code, 0)
        self.assertEqual(len(commands(log, "e2fsck")), 1)
        self.assertEqual(commands(log, "resize2fs"), [])
        self.assertEqual(log[-1], "POWEROFF")
        self.assertIn("fx: shrink done 8", log)

    def test_wrong_partition_uuid_refuses_before_any_writes(self):
        code, log = run(SHRINK_UUID="expected", DISK_UUID="other")
        self.assertEqual(code, 0)
        self.assertEqual(commands(log, "e2fsck"), [])
        self.assertIn("fx: shrink failed home partition does not match the shrink request", log)
        self.assertEqual(log[-1], "POWEROFF")

    def test_e2fsck_corrected_statuses_continue(self):
        # Correction/reboot status bits (including both set) still allow offline resize.
        for rc in ("1", "2", "3"):
            code, log = run(E2FSCK_RC=rc)
            self.assertEqual(log[-1], "POWEROFF", rc)
            self.assertIn("chroot resize2fs /dev/vda7 8G", log, rc)
            self.assertFalse(any("shrink-home: e2fsck failed" in l for l in log), rc)

    def test_e2fsck_failure_statuses_stop_before_resize2fs(self):
        for rc in ("4", "8", "12"):
            code, log = run(E2FSCK_RC=rc)
            self.assertEqual(log[-1], "POWEROFF", rc)
            self.assertIn(f"fx: shrink failed needs-repair: e2fsck failed (exit {rc})", log)
            self.assertEqual(commands(log, "resize2fs"), [], rc)

    def test_block_size_comes_from_the_filesystem(self):
        # 8 GiB = 2097152 blocks of 4 KiB, 8388608 of 1 KiB.
        code, log = run(BLOCK_SIZE="4096", MIN_BLOCKS="2097153")
        self.assertTrue(any("is too small" in l for l in log))
        self.assertNotIn("chroot resize2fs /dev/vda7 8G", log)
        code, log = run(BLOCK_SIZE="1024", MIN_BLOCKS="2097153")
        self.assertIn("chroot resize2fs /dev/vda7 8G", log)
        code, log = run(BLOCK_SIZE="1024", MIN_BLOCKS="8388609")
        self.assertTrue(any("is too small" in l for l in log))
        code, log = run(BLOCK_SIZE="")
        self.assertTrue(any("cannot read the block size" in l for l in log))
        self.assertEqual(log[-1], "POWEROFF")

    def test_resize2fs_failure_repairs_and_powers_off(self):
        code, log = run(RESIZE_RC="1")
        self.assertEqual(log[-1], "POWEROFF")
        self.assertEqual(len(commands(log, "e2fsck")), 2)
        self.assertTrue(any("resize2fs 8G failed" in l for l in log))
        self.assertNotIn("fx: shrink done 8", log)

    def test_failed_repair_reports_that_normal_boot_is_not_safe(self):
        code, log = run(RESIZE_RC="1", REPAIR_RC="4")
        self.assertEqual(code, 0)
        self.assertEqual(log[-1], "POWEROFF")
        self.assertEqual(len(commands(log, "e2fsck")), 2)
        self.assertIn("fx: shrink failed needs-repair: resize2fs 8G failed; repair e2fsck failed (exit 4)", log)

    def test_bad_arguments_power_off_instead_of_a_shell(self):
        for gib in ("7", "5000", "8x", "-8"):
            code, log = run(gib=gib)
            self.assertEqual(log[-1], "POWEROFF", gib)
            self.assertFalse(any(l.startswith("FATAL") for l in log), gib)
            self.assertEqual(commands(log, "e2fsck"), [], gib)

    def test_only_the_stop_slot_runs_a_shrink(self):
        code, log = run(forced="")
        self.assertEqual(log[-1], "POWEROFF")
        self.assertTrue(any("needs steamac.slot=stop" in l for l in log))
        self.assertEqual(commands(log, "e2fsck"), [])

    def test_without_the_argument_a_normal_boot_continues(self):
        code, log = run(gib="", forced="")
        self.assertEqual(code, 0)
        self.assertEqual(log, ["REACHED-END"])


@unittest.skipUnless(os.environ.get("SHRINK_HOME_REAL_TOOLS"), "set SHRINK_HOME_REAL_TOOLS to a Linux builder image")
class RealExt4Tests(unittest.TestCase):
    def test_guest_offline_resize_leaves_real_ext4_clean(self):
        script = r"""
set -e
STUB_LOG=/tmp/shrink.log GIB=8 FORCED=stop REAL_HOME=/tmp/home.img
mkdir /tmp/fixture
printf 'steamac shrink test\n' > /tmp/fixture/known
mke2fs -q -F -t ext4 -b 4096 -O 64bit,flex_bg,casefold -d /tmp/fixture "$REAL_HOME" 2359296
""" + STUBS + FUNCTIONS.removesuffix("\nshrink_home\n") + r"""
(
    set +e
    shrink_home
    exit 1
)
grep -qx 'fx: shrink done 8' "$STUB_LOG"
test "$(stat -c %s "$REAL_HOME")" -eq 8589934592
e2fsck -fn "$REAL_HOME"
debugfs -R 'dump /known /tmp/known' "$REAL_HOME"
cmp /tmp/fixture/known /tmp/known
"""
        result = subprocess.run(["docker", "run", "--rm", "-i", "--entrypoint", "sh",
                                 os.environ["SHRINK_HOME_REAL_TOOLS"], "-s"],
                                input=script, capture_output=True, text=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


class InitStructureTests(unittest.TestCase):
    def test_stop_with_shrink_reaches_the_shrink_instead_of_powering_off_early(self):
        # The old `steamac.slot=stop` branch powered off before the rootfs was assembled.
        stop = re.search(r'^\s*stop\) (.*?);;', INIT, re.MULTILINE | re.DOTALL).group(1)
        self.assertIn('getarg steamac.shrink-home', stop)
        self.assertLess(stop.index("poweroff -f"), stop.index("SLOT=${BOOT_ORDER%% *}"))
        self.assertLess(INIT.index("assemble_slot \"$SLOT\""), INIT.index("\nshrink_home\n"))
        self.assertNotIn("shrink-home-done", INIT)


if __name__ == "__main__":
    unittest.main()
