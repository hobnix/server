#!/usr/bin/env python3
import os, subprocess, sys, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
HELPER = os.path.join(os.path.dirname(HERE), "scripts", "lib", "iommu.py")


class Iommu(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.sys = os.path.join(self.tmp.name, "sys")
        os.makedirs(self.sys)
        self.cmd = os.path.join(self.tmp.name, "cmdline")
        self.cmdline("quiet")

    def tearDown(self):
        self.tmp.cleanup()

    def cmdline(self, text):
        with open(self.cmd, "w") as f:
            f.write(text + "\n")

    def dev(self, group, addr, cls, ids, driver=None, boot=None):
        d = os.path.join(self.sys, "devices", addr)
        os.makedirs(d, exist_ok=True)
        ven, did = ids.split(":")
        for n, v in (("class", "0x%s00" % cls), ("vendor", "0x" + ven), ("device", "0x" + did)):
            with open(os.path.join(d, n), "w") as f:
                f.write(v + "\n")
        if boot is not None:
            with open(os.path.join(d, "boot_vga"), "w") as f:
                f.write("%d\n" % boot)
        if driver:
            os.makedirs(os.path.join(self.sys, "bus/pci/drivers", driver), exist_ok=True)
            os.symlink(os.path.join(self.sys, "bus/pci/drivers", driver), os.path.join(d, "driver"))
        gd = os.path.join(self.sys, "kernel/iommu_groups", str(group), "devices")
        os.makedirs(gd, exist_ok=True)
        os.symlink(d, os.path.join(gd, addr))

    def run_(self, mode):
        env = dict(os.environ, HS_SYS_DIR=self.sys, HS_CMDLINE=self.cmd)
        p = subprocess.run([sys.executable, "-I", HELPER, mode], env=env, capture_output=True, text=True)
        return p.returncode, [l.split("\t") for l in p.stdout.splitlines()]

    def test_groups_listing(self):
        self.dev(14, "0000:01:00.1", "04", "10de:10f0", "snd_hda_intel")
        self.dev(14, "0000:01:00.0", "03", "10de:1b80", "nouveau", boot=0)
        self.dev(1, "0000:00:01.0", "06", "8086:1901")
        rc, rows = self.run_("groups")
        self.assertEqual(rc, 0)
        self.assertEqual(rows[0], ["1", "0000:00:01.0", "0600", "8086:1901", "-", "0"])
        self.assertEqual([r[1] for r in rows], ["0000:00:01.0", "0000:01:00.0", "0000:01:00.1"])
        self.assertEqual(rows[1][4], "nouveau")

    def test_iommu_off(self):
        rc, rows = self.run_("check")
        self.assertEqual(rc, 0)
        self.assertEqual(rows[0][:3], ["warn", "iommu-off", "-"])

    def test_clean_gpu_in_own_group(self):
        self.dev(2, "0000:01:00.0", "03", "10de:1b80", "vfio-pci", boot=0)
        self.dev(2, "0000:00:01.0", "06", "8086:1901")   # bridge in the same group does not count
        rc, rows = self.run_("check")
        self.assertEqual(rows, [])

    def test_boot_gpu_shared_group_host_driver(self):
        self.dev(5, "0000:01:00.0", "03", "10de:1b80", "nvidia", boot=1)
        self.dev(5, "0000:01:00.1", "04", "10de:10f0", "snd_hda_intel")
        rc, rows = self.run_("check")
        codes = [(r[1], r[2]) for r in rows]
        self.assertIn(("boot-gpu", "0000:01:00.0"), codes)
        self.assertIn(("shared-group", "0000:01:00.0"), codes)
        self.assertIn(("host-driver", "0000:01:00.0"), codes)

    def test_cmdline_off(self):
        self.dev(2, "0000:01:00.0", "03", "10de:1b80", "vfio-pci", boot=0)
        self.cmdline("quiet intel_iommu=off")
        _, rows = self.run_("check")
        self.assertEqual(rows[0][1], "iommu-cmdline")

    def test_platform_devices_skipped(self):
        gd = os.path.join(self.sys, "kernel/iommu_groups/3/devices")
        os.makedirs(os.path.join(gd, "platform-foo"))
        _, rows = self.run_("groups")
        self.assertEqual(rows, [])

    def test_missing_sys(self):
        env = dict(os.environ, HS_SYS_DIR=os.path.join(self.tmp.name, "nope"))
        p = subprocess.run([sys.executable, "-I", HELPER, "groups"], env=env, capture_output=True, text=True)
        self.assertEqual(p.returncode, 2)


if __name__ == "__main__":
    unittest.main()
