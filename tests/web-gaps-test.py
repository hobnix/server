#!/usr/bin/env python3
"""scripts/web-serve.py: the allowlists for the gap-filling round (another disk, DNS names, router view, ports, off-site copy buttons):
what passes and what is refused in CHANGES, and that the new reads are listed and are real `sys` rows."""
import importlib.util
import os
import unittest

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("web_serve", os.path.join(here, "..", "scripts", "web-serve.py"))
ws = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ws)


def ok(area, args, confirm=None, stdin=None):
    return ws.validate_change({"area": area, "args": args, "confirm": confirm, "stdin": stdin}) is not None


class Changes(unittest.TestCase):
    def test_temp_mount(self):
        for good in (["sdg1", "temp-mount"], ["nvme1n1p1", "temp-mount"], ["sdg1", "temp-mount", "--name", "usb-stick"]):
            self.assertTrue(ok("disk", good), good)
        bad = [
            ["sdg1", "temp-mount", "--rw"],                   # read-only is the only mode
            ["sdg1", "temp-mount", "--name"],
            ["sdg1", "temp-mount", "--name", "Big Disk"],
            ["sdg1", "temp-mount", "--name", "a/b"],
            ["sdg1", "temp-mount", "--name", "x", "--name", "y"],
            ["/dev/sdg1", "temp-mount"],
            ["../sdg1", "temp-mount"],
            ["SDG1", "temp-mount"],
            ["sdg1;reboot", "temp-mount"],
            ["-r", "temp-mount"],
            ["temp-mount"],
        ]
        for b in bad:
            self.assertFalse(ok("disk", b), b)

    def test_temp_copy_and_eject(self):
        self.assertTrue(ok("disk", ["usb-stick", "temp-copy", "--to", "photos"]))
        self.assertTrue(ok("disk", ["sdg1", "temp-copy"]))            # the plan answers "needs to"
        self.assertTrue(ok("disk", ["usb-stick", "temp-eject"]))
        bad = [
            ["usb-stick", "temp-copy", "--to", "../photos"],
            ["usb-stick", "temp-copy", "--to", "Photos"],
            ["usb-stick", "temp-copy", "--to", "a", "--to", "b"],
            ["usb-stick", "temp-copy", "--delete"],
            ["usb-stick", "temp-eject", "--force"],
            ["usb stick", "temp-eject"],
            ["/mnt/temp/x", "temp-eject"],
            ["usb-stick", "temp-format"],
            ["usb-stick", "temp-eject", "extra"],
        ]
        for b in bad:
            self.assertFalse(ok("disk", b), b)
        # the old shape keeps working and stays tight
        self.assertTrue(ok("disk", ["sda", "test", "short"]))
        self.assertFalse(ok("disk", ["sda", "test", "medium"]))

    def test_no_stdin_no_confirm_word_for_these(self):
        self.assertFalse(ok("disk", ["sdg1", "temp-mount"], stdin="x"))
        self.assertFalse(ok("dns", ["sync"], stdin="x"))

    def test_dns_sync(self):
        self.assertTrue(ok("dns", ["sync"]))
        for bad in (["sync", "--yes"], ["sync", "--dry-run"], ["list"], ["add", "x"], [], ["SYNC"], ["sync;ls"]):
            self.assertFalse(ok("dns", bad), bad)

    def test_offsite_buttons_only_now_and_off(self):
        self.assertTrue(ok("backup", ["offsite-now"]))
        self.assertTrue(ok("backup", ["offsite-off"]))
        # the backup disk is set up from the page (red: the kernel name of the disk is typed); the disk is a by-id name
        self.assertTrue(ok("backup", ["init", "--disk", "ata-WDC_WD40EFRX_WD-1234"]))
        # an address can carry a password (rest:https://user:pw@host), so setting one stays a terminal job
        for bad in (["offsite-set", "--repo", "sftp:me@nas:/backup"], ["offsite-set"], ["offsite-now", "--repo", "x"], ["init", "--bogus", "sdb"], ["init", "--disk", "a/b"]):
            self.assertFalse(ok("backup", bad), bad)

    def test_restore_files_is_the_share_restore(self):
        # the Backup page's "Restore files…" form uses `shares <share> restore`: the files land in the share `restored`
        self.assertTrue(ok("shares", ["photos", "restore", "--snapshot", "latest"]))
        self.assertTrue(ok("shares", ["photos", "restore", "--snapshot", "1a2b3c4d", "--path", "2024/summer"]))
        for bad in (["photos", "restore", "--snapshot", "latest", "--path", "../etc"], ["photos", "restore", "--to", "/"],
                    ["photos", "restore", "--snapshot", "a;b"], ["Photos", "restore", "--snapshot", "latest"]):
            self.assertFalse(ok("shares", bad), bad)


class Reads(unittest.TestCase):
    def test_listed(self):
        for words in (("unifi", "networks"), ("unifi", "clients"), ("ports", "list"), ("dns", "list")):
            self.assertIn(words, ws.READS)
            self.assertEqual(ws.READS[words]["kind"], "tsv")
            self.assertNotIn("args", ws.READS[words])
        # the two reads that need an address argument and could never work without it are gone
        self.assertNotIn(("unifi", "used"), ws.READS)
        self.assertNotIn(("unifi", "reserved"), ws.READS)

    def test_registry_rows(self):
        reg = os.path.join(here, "..", "scripts", "lib", "registry.tsv")
        rows = {}
        with open(reg, encoding="utf-8") as f:
            for line in f:
                c = line.rstrip("\n").split("\t")
                if c[0] == "sys":
                    rows[c[1]] = c
        for name, script, fixed in (("sys unifi networks", "unifi.sh", "networks"), ("sys unifi clients", "unifi.sh", "clients"),
                                    ("sys ports list", "ports.sh", "--list"), ("sys dns list", "dns.sh", "raw"),
                                    ("sys dns plan <action>", "dns-change.sh", "plan {1} {rest}"),
                                    ("sys dns start <action>", "dns-change.sh", "start {1} {rest}")):
            self.assertIn(name, rows)
            self.assertEqual(rows[name][2:4], [script, fixed], name)


if __name__ == "__main__":
    unittest.main()
