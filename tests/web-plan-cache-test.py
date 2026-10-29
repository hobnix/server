#!/usr/bin/env python3
"""scripts/web-serve.py, plans: the short plan cache (Plans, plan_cacheable, plan_stable), the log line without values (change_shape, _timing),
the cancel when the browser goes away (_client_gone, _run_watched, _kill_tree). Real HTTP server on a free port, fake `_run_watched`."""
import contextlib
import importlib.util
import io
import json
import os
import socket
import tempfile
import time
import unittest

here = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("web_login_test_base", os.path.join(here, "web-login-test.py"))
lt = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(lt)
ws = lt.ws

DISK = ["sda", "test", "short"]
CONV = ["bulk", "convert", "--member", "data-01", "--encrypt"]


class PlanCache(lt.Base):
    def setUp(self):
        super().setUp()
        self.app.plans.ttl = 5
        self.calls = []
        self.answer = (0, "status\tok\nheading\tx\nstep\ta\n", "run")
        self.real = ws._run_watched

        def fake(cmd, stdin=None, timeout=60, gone=None):
            self.calls.append((cmd, stdin))
            return self.answer
        ws._run_watched = fake
        _, d, r = self.login()
        self.ck = {"Cookie": self.cookie(r), "X-CSRF-Token": d["csrf"]}
        self.calls.clear()

    def tearDown(self):
        ws._run_watched = self.real
        super().tearDown()

    def post(self, path, body):
        s, d, _ = self.req("POST", path, body, headers=self.ck)
        return s, json.loads(d)

    def plan(self, area="disk", args=DISK, **extra):
        return self.post("/api/plan", dict({"area": area, "args": args}, **extra))

    def test_same_plan_once(self):
        a, b = self.plan(), self.plan()
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(a, b)
        self.plan(args=["sda", "test", "long"])
        self.assertEqual(len(self.calls), 2)

    def test_start_clears(self):
        self.plan()
        self.post("/api/start", {"area": "disk", "args": DISK})
        self.plan()
        self.assertEqual(len(self.calls), 2)

    def test_reads_clear_clears(self):
        self.plan()
        self.app.reads.clear()
        self.plan()
        self.assertEqual(len(self.calls), 2)

    def test_stdin_never_cached(self):
        for _ in range(2):
            self.plan("pool", CONV)
            self.plan("pool", CONV, stdin="secret pw")
        self.assertEqual(len(self.calls), 4)

    def test_not_stable_never_kept(self):
        for ans in [(1, "", "run"), (1, "status\tok\n", "run"), (0, "status\tok\nsecret\tpassword\tx\n", "run"), (127, "", "timeout")]:
            self.calls.clear()
            self.answer = ans
            self.app.plans.clear()
            self.plan()
            self.plan()
            self.assertEqual(len(self.calls), 2, ans)

    def test_ttl_zero(self):
        self.app.plans.ttl = 0
        self.plan()
        self.plan()
        self.assertEqual(len(self.calls), 2)

    def test_plans_unit(self):
        p = ws.Plans(5)
        k = ("disk", ("a",))
        g = p.gen
        p.clear()
        p.put(k, g, {"status": "ok"})
        self.assertIsNone(p.get(k))
        for i in range(70):
            p.put(("x", (str(i),)), p.gen, {"status": "ok"})
        self.assertLessEqual(len(p.items), 64)
        self.assertIsNotNone(p.get(("x", ("69",))))

    def test_change_shape(self):
        self.assertEqual(ws.change_shape("pool", ["bulk", "convert", "--member", "data-01", "--fs", "xfs"]), "pool bulk convert --member * --fs *")
        self.assertEqual(ws.change_shape("disk", DISK), "disk * test short")
        self.assertEqual(ws.change_shape("nonesuch", ["a"]), "nonesuch")

    def test_timing_line_has_no_values(self):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            self.plan("pool", CONV, stdin="secret pw")
        out = buf.getvalue()
        self.assertIn("web timing: plan pool bulk convert --member * --encrypt", out)
        self.assertIn(" ms ", out)
        self.assertNotIn("data-01", out)
        self.assertNotIn("secret pw", out)

    def test_client_gone(self):
        seen = []

        def fake(cmd, stdin=None, timeout=60, gone=None):
            end = time.monotonic() + 5
            while time.monotonic() < end:
                if gone():
                    seen.append(True)
                    return 127, "", "gone"
                time.sleep(0.05)
            seen.append(False)
            return 127, "", "timeout"
        ws._run_watched = fake
        body = json.dumps({"area": "disk", "args": DISK}).encode()
        head = ("POST /api/plan HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nOrigin: http://127.0.0.1:%d\r\nCookie: %s\r\nX-CSRF-Token: %s\r\n"
                "Content-Type: application/json\r\nContent-Length: %d\r\n\r\n"
                % (self.port, self.port, self.ck["Cookie"], self.ck["X-CSRF-Token"], len(body))).encode()
        c = socket.create_connection(("127.0.0.1", self.port))
        c.sendall(head + body)
        time.sleep(0.3)
        c.close()
        end = time.monotonic() + 2
        while not seen and time.monotonic() < end:
            time.sleep(0.05)
        self.assertEqual(seen, [True])

    def test_unlock_clears(self):
        _, d, r = self.login(realm="local", user="adminuser", password="local pw")      # while locked only a local admin may sign in
        self.ck = {"Cookie": self.cookie(r), "X-CSRF-Token": d["csrf"]}
        self.plan()
        self.auth.storage_locked = lambda: True
        self.post("/api/unlock", {"passphrase": "x"})      # any outcome (the real run of hs is /nonexistent)
        self.plan()
        self.assertEqual(len(self.calls), 2)

    def test_client_gone_high_fd(self):
        a, b = socket.socketpair()
        keep = []
        try:
            while a.fileno() < 1100:
                keep.append(os.dup(a.fileno()))
            hi = a.dup() if a.fileno() > 1024 else a
            self.assertFalse(ws._client_gone(hi))
            b.close()
            self.assertTrue(ws._client_gone(hi))
        except OSError:
            self.skipTest("cannot open 1100 descriptors")
        finally:
            for k in keep:
                os.close(k)
            a.close()

    @unittest.skipUnless(hasattr(os, "killpg"), "POSIX")
    def test_kill_term_ignoring_child(self):
        pidfile = os.path.join(self.tmp, "pid2")
        t0 = time.monotonic()
        cmd = "sh -c 'trap \"\" TERM; echo $$ > %s; sleep 30' & wait" % pidfile
        rc, out, how = self.real(["sh", "-c", cmd], gone=lambda: os.path.exists(pidfile) and time.monotonic() > t0 + 0.5)
        self.assertEqual(how, "gone")
        pid = int(open(pidfile).read())
        end = time.monotonic() + 2
        while time.monotonic() < end:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.05)
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    @unittest.skipUnless(hasattr(os, "killpg"), "POSIX")
    def test_real_kill(self):
        pidfile = os.path.join(self.tmp, "pid")
        t0 = time.monotonic()
        rc, out, how = self.real(["sh", "-c", "sleep 30 & echo $! > %s; wait" % pidfile], gone=lambda: time.monotonic() > t0 + 0.5)
        self.assertEqual(how, "gone")
        self.assertLess(time.monotonic() - t0, 4)
        pid = int(open(pidfile).read())
        end = time.monotonic() + 1
        while time.monotonic() < end:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.05)
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)
        self.assertEqual(self.real(["sleep", "30"], timeout=0.5)[2], "timeout")


if __name__ == "__main__":
    unittest.main()
