#!/usr/bin/env python3
"""scripts/web-serve.py, the `pool` and `disk` areas of CHANGES (forms Add disks, Replace, Remove, self-tests): what is allowed, what is refused,
and that a passphrase only ever travels on stdin. Real HTTP server on a free port, fake `_run`."""
import importlib.util
import json
import os
import unittest

here = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("web_login_test_base", os.path.join(here, "web-login-test.py"))
lt = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(lt)
ws = lt.ws

ID1 = "ata-WDC_WD40EFRX-68N32N0_WD-WCC7K1234567"
ID2 = "ata-ST4000VN008-2DR166_ZDH0ABCD"


class Storage(lt.Base):
    def setUp(self):
        super().setUp()
        self.calls = []
        self.answer = (0, "status\tok\nheading\tadd\nstep\ta step\ndanger\tALL DATA on x will be erased.\nconfirm_name\tfast\nlong\tno\n")
        self.real_run = ws._run

        def fake(cmd, stdin=None, timeout=10):
            self.calls.append((cmd, stdin))
            return self.answer
        ws._run = fake
        _, d, r = self.login()
        self.ck = {"Cookie": self.cookie(r), "X-CSRF-Token": d["csrf"]}
        self.calls.clear()

    def tearDown(self):
        ws._run = self.real_run
        super().tearDown()

    def post(self, path, body):
        s, d, _ = self.req("POST", path, body, headers=self.ck)
        return s, json.loads(d)

    def allowed(self, area, args, path="/api/plan", **extra):
        return self.post(path, dict({"area": area, "args": args}, **extra))[0] == 200

    # ── pool ──
    def test_add_shapes(self):
        ok = [
            ["fast", "add", "--disks", ID1 + "," + ID2],
            ["bulk", "add", "--disks", ID1, "--role", "data"],
            ["bulk", "add", "--disks", ID1, "--role", "parity", "--fs", "xfs", "--encrypt"],
            ["bulk", "add", "--encrypt", "--fs", "btrfs", "--role", "data", "--disks", ID1],
            ["bulk", "add"],
            ["bulk", "adopt", "--disks", ID1, "--merge", "--chown"],
            ["bulk", "replace", "--member", "data-01", "--disks", ID2],
            ["fast", "replace", "--member", ID1, "--disks", ID2],
            ["bulk", "replace", "--member", "data-01", "--disks", ID2, "--fs", "ext4", "--encrypt"],
            ["bulk", "replace", "--member", "data-01"],
            ["fast", "remove", "--member", ID1, "--mode", "detach"],
            ["bulk", "remove", "--member", "parity-1"],
        ]
        for a in ok:
            self.assertTrue(self.allowed("pool", a), a)
            self.assertTrue(self.allowed("pool", a, "/api/start", confirm="bulk"), a)
        self.assertEqual(self.calls[0][0], ["/nonexistent/hs", "sys", "pool", "plan"] + ok[0])

    def test_refused_shapes(self):
        bad = [
            ["bulk", "add", "--disks", "/dev/sda"],                 # a path
            ["bulk", "add", "--disks", "../sda"],
            ["bulk", "add", "--disks", "a..b"],
            ["bulk", "add", "--disks", "sda;reboot"],
            ["bulk", "add", "--disks", "--role"],
            ["bulk", "add", "--disks", "sda,"],
            ["bulk", "add", "--disks", ""],
            ["bulk", "add", "--disks", "sda", "--disks", "sdb"],     # twice
            ["bulk", "add", "--role", "boot"],
            ["bulk", "add", "--fs", "ntfs"],
            ["bulk", "add", "--merge"],                              # an adopt option on add
            ["bulk", "add", "--confirm", "bulk"],                    # the server adds that itself
            ["bulk", "add", "--member", "data-01"],
            ["bulk", "adopt", "--encrypt"],
            ["bulk", "adopt", "--role", "data"],
            ["bulk", "replace", "--mode", "vdev"],
            ["bulk", "replace"],
            ["bulk", "remove"],
            ["bulk", "remove", "--mode", "vdev", "--member", "data-01"],      # the member comes first
            ["bulk", "replace", "--member", "data-01", "--merge"],
            ["bulk", "remove", "--member", "data-01", "--disks", "sda"],
            ["bulk", "remove", "--member", "data-01", "--encrypt"],
            ["bulk", "remove", "--member", "data-01", "--mode", "gone"],
            ["bulk", "remove", "--member", "../x"],
            ["shares", "add"],                                       # not a pool
            ["Bulk", "add"],
            ["bulk", "wipe"],
            ["bulk"],
            ["bulk", "add", "extra"],
        ]
        for a in bad:
            self.assertEqual(self.post("/api/plan", {"area": "pool", "args": a})[0], 400, a)
        self.assertEqual(self.calls, [])

    def test_stdin_only_where_the_entry_says_so_and_never_in_argv(self):
        pw = "correct horse battery staple"
        add = ["fast", "add", "--disks", ID1 + "," + ID2]
        self.assertTrue(self.allowed("pool", ["bulk", "add", "--disks", ID1, "--role", "data", "--encrypt"], "/api/start", confirm="bulk", stdin=pw))
        cmd, stdin = self.calls[-1]
        self.assertEqual(stdin, (pw + "\n").encode())
        self.assertFalse(any(pw in a for a in cmd), cmd)
        self.assertTrue(self.allowed("pool", ["bulk", "replace", "--member", "data-01", "--disks", ID2, "--encrypt"], "/api/start", confirm="data-01", stdin=pw))
        # adopt, remove and disk tests take no passphrase
        for area, args in (("pool", ["bulk", "adopt", "--disks", ID1]), ("pool", ["bulk", "remove", "--member", "data-01"]), ("disk", ["sda", "test", "short"])):
            self.assertEqual(self.post("/api/start", {"area": area, "args": args, "stdin": pw})[0], 400, area)
        # a passphrase may not be a second line, nor empty or huge
        for bad in ("a\nb", "", "x" * 300, 5):
            self.assertEqual(self.post("/api/start", {"area": "pool", "args": add, "stdin": bad})[0], 400, repr(bad))
        # a passphrase in the arguments is a pattern miss, not a leak into the command
        self.calls.clear()
        self.assertEqual(self.post("/api/start", {"area": "pool", "args": add + ["--passphrase", pw]})[0], 400)
        self.assertEqual(self.calls, [])

    def test_confirm_goes_after_the_arguments(self):
        self.post("/api/start", {"area": "pool", "args": ["fast", "add", "--disks", ID1 + "," + ID2], "confirm": "fast"})
        self.assertEqual(self.calls[-1][0][-2:], ["--confirm", "fast"])
        self.assertEqual(self.calls[-1][0][3], "start")
        self.assertEqual(self.post("/api/start", {"area": "pool", "args": ["fast", "add"], "confirm": "a;b"})[0], 400)

    def test_plan_with_a_danger_line_is_parsed(self):
        d = self.post("/api/plan", {"area": "pool", "args": ["fast", "add", "--disks", ID1]})[1]
        self.assertEqual((d["status"], d["confirm_name"]), ("ok", "fast"))
        self.assertEqual(d["steps"][-1][0], "danger")
        self.answer = (2, "status\tneeds\nneeds\tdisks\nneeds\trole\n")
        d = self.post("/api/plan", {"area": "pool", "args": ["bulk", "add"]})[1]
        self.assertEqual((d["status"], d["needs"]), ("needs", ["disks", "role"]))

    # ── disk ──
    def test_disk_test_shapes(self):
        for disk in ("sda", "nvme0n1", ID1, "usb-Seagate_Backup_123:0"):
            for kind in ("short", "long"):
                self.assertTrue(self.allowed("disk", [disk, "test", kind]), (disk, kind))
        self.assertEqual(self.calls[0][0], ["/nonexistent/hs", "sys", "disk", "plan", "sda", "test", "short"])
        self.assertTrue(self.allowed("disk", ["sda", "test", "long"], "/api/start"))
        self.assertEqual(self.calls[-1][0][3], "start")
        for bad in (["/dev/sda", "test", "short"], ["../sda", "test", "short"], ["sda/../sdb", "test", "short"], ["a..b", "test", "short"],
                    ["--help", "test", "short"], ["sda", "test", "medium"], ["sda", "format", "short"], ["sda", "test"], ["sda"],
                    ["sda", "test", "short", "--confirm", "x"], ["sda;x", "test", "short"], ["", "test", "short"]):
            self.assertEqual(self.post("/api/plan", {"area": "disk", "args": bad})[0], 400, bad)

    def test_disk_wipe_shapes(self):
        self.assertTrue(self.allowed("disk", ["sdc", "wipe"]))
        self.assertTrue(self.allowed("disk", [ID1, "wipe"], "/api/start"))
        for bad in (["/dev/sdc", "wipe"], ["../sdc", "wipe"], ["sdc", "wipe", "--force"], ["sdc", "wipe", "short"], ["--help", "wipe"]):
            self.assertEqual(self.post("/api/plan", {"area": "disk", "args": bad})[0], 400, bad)

    def test_changes_have_registry_rows(self):
        reg = os.path.join(here, "..", "scripts", "lib", "registry.tsv")
        with open(reg, encoding="utf-8") as f:
            paths = [line.split("\t")[1] for line in f if line.startswith("sys\t")]
        for area in ("pool", "disk"):
            for verb in ("plan", "start"):
                self.assertTrue(any(p.startswith("sys %s %s " % (area, verb)) for p in paths), (area, verb))


if __name__ == "__main__":
    unittest.main(verbosity=1)
