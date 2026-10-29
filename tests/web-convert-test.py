#!/usr/bin/env python3
"""scripts/web-serve.py, the `pool ... convert` entry and `ct all update-all` of CHANGES: allowed and refused shapes, the passphrase on stdin only.
Real HTTP server on a free port, fake `_run`."""
import importlib.util
import json
import os
import unittest

here = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("web_login_test_base", os.path.join(here, "web-login-test.py"))
lt = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(lt)
ws = lt.ws


class Convert(lt.Base):
    def setUp(self):
        super().setUp()
        self.calls = []
        self.answer = (0, "status\tok\nheading\tconvert\nstep\ta step\ndanger\tALL DATA on the disk is erased after it was moved.\nconfirm_name\tdata-01\nlong\tyes\n")
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

    def test_convert_shapes(self):
        ok = [
            ["bulk", "convert", "--member", "data-01"],
            ["bulk", "convert", "--member", "data-01", "--fs", "xfs"],
            ["bulk", "convert", "--member", "data-01", "--fs", "btrfs", "--encrypt"],
            ["bulk", "convert", "--member", "data-02", "--encrypt", "--fs", "ext4"],
            ["bulk", "convert", "--member", "data-06", "--discard"],
            ["bulk", "convert", "--member", "data-06", "--fs", "xfs", "--discard", "--encrypt"],
        ]
        for a in ok:
            self.assertTrue(self.allowed("pool", a), a)
            self.assertTrue(self.allowed("pool", a, "/api/start", confirm="data-01"), a)
        self.calls.clear()
        bad = [
            ["bulk", "convert"],                                          # the member is named here, not answered with `needs`
            ["fast", "convert", "--member", "data-01"],                   # ZFS has nothing to convert
            ["bulk", "convert", "--member", "../x"],
            ["bulk", "convert", "--member", "a/b"],
            ["bulk", "convert", "--fs", "xfs", "--member", "data-01"],    # the member comes first
            ["bulk", "convert", "--member", "data-01", "--fs", "ntfs"],
            ["bulk", "convert", "--member", "data-01", "--fs", "xfs", "--fs", "ext4"],
            ["bulk", "convert", "--member", "data-01", "--disks", "sda"],
            ["bulk", "convert", "--member", "data-01", "--mode", "vdev"],
            ["bulk", "convert", "--member", "data-01", "--role", "parity"],
            ["bulk", "convert", "--member", "data-01", "--merge"],
            ["bulk", "convert", "--member", "data-01", "--chown"],
            ["bulk", "convert", "--member", "data-01", "--confirm", "data-01"],
            ["bulk", "convert", "--member", "data-01", "x"],
            ["bulk", "convert", "--member", "data-01", "--discard", "--discard"],
            ["bulk", "close", "--member", "data-01", "--discard"],        # --discard is for convert; close has --drain
        ]
        for a in bad:
            self.assertEqual(self.post("/api/plan", {"area": "pool", "args": a})[0], 400, a)
        self.assertEqual(self.calls, [])

    def test_existing_pool_shapes_are_unchanged(self):
        for a in (["bulk", "replace", "--member", "data-01", "--disks", "sda"], ["bulk", "remove", "--member", "data-01"], ["bulk", "adopt", "--disks", "sda"]):
            self.assertTrue(self.allowed("pool", a), a)
        self.assertEqual(self.post("/api/plan", {"area": "pool", "args": ["bulk", "remove", "--member", "data-01", "--fs", "xfs"]})[0], 400)

    def test_passphrase_only_on_stdin(self):
        pw = "correct horse battery staple"
        a = ["bulk", "convert", "--member", "data-01", "--fs", "ext4", "--encrypt"]
        self.assertTrue(self.allowed("pool", a, "/api/start", confirm="data-01", stdin=pw))
        cmd, stdin = self.calls[-1]
        self.assertEqual(stdin, (pw + "\n").encode())
        self.assertFalse(any(pw in x for x in cmd), cmd)
        self.assertEqual(cmd[-2:], ["--confirm", "data-01"])
        for bad in ("a\nb", "", "x" * 300, 5):
            self.assertEqual(self.post("/api/start", {"area": "pool", "args": a, "stdin": bad, "confirm": "data-01"})[0], 400, repr(bad))
        self.calls.clear()
        self.assertEqual(self.post("/api/start", {"area": "pool", "args": a + ["--passphrase", pw]})[0], 400)
        self.assertEqual(self.calls, [])

    def test_update_all(self):
        self.answer = (0, "status\tok\nheading\tupdate all running instances (2)\nstep\tsnapshot a, then update the software inside\nwarn\tEvery instance is snapshotted first\nlong\tyes\n")
        self.assertTrue(self.allowed("ct", ["all", "update-all"]))
        self.assertTrue(self.allowed("ct", ["all", "update-all"], "/api/start"))
        cmd = self.calls[-1][0]
        self.assertIn("start", cmd)
        self.assertEqual(cmd[-2:], ["all", "update-all"])
        d = self.post("/api/plan", {"area": "ct", "args": ["all", "update-all"]})[1]
        self.assertTrue(d["long"])
        self.assertEqual(d["confirm_name"], "")
        self.calls.clear()
        bad = [
            ["all", "update-all", "--snapshot", "x"],
            ["all", "update-all", "--confirm", "all"],
            ["all", "update-all", "extra"],
            ["all"],
            ["update-all"],
            ["All", "update-all"],
            ["all,x", "update-all"],
            ["update-all", "all"],
        ]
        for a in bad:
            self.assertEqual(self.post("/api/plan", {"area": "ct", "args": a})[0], 400, a)
        # a passphrase has no place here
        self.assertEqual(self.post("/api/start", {"area": "ct", "args": ["all", "update-all"], "stdin": "pw"})[0], 400)
        self.assertEqual(self.calls, [])

    def test_single_instance_actions_still_work(self):
        for a in (["immich", "update"], ["immich", "snapshot", "--label", "x"], ["immich", "restart"]):
            self.assertTrue(self.allowed("ct", a), a)


if __name__ == "__main__":
    unittest.main(verbosity=1)
