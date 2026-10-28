#!/usr/bin/env python3
"""POST /api/unlock of scripts/web-serve.py: only while locked, session + CSRF + Origin, passphrase only on stdin, throttle, bad bodies."""
import contextlib
import http.client
import importlib.util
import io
import json
import os
import tempfile
import threading
import unittest

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("web_serve", os.path.join(here, "..", "scripts", "web-serve.py"))
ws = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ws)
os.environ["HS_WEB_QUIET"] = "1"

SECRET = "correct horse 'battery' $staple"


class FakeAuth:
    def __init__(self, cfg):
        self.cfg, self.locked = cfg, True

    def storage_locked(self):
        return self.locked

    def domain_password_ok(self, user, password):
        return False

    def domain_is_admin(self, user):
        return False

    def local_password_ok(self, user, password):
        return user == "adminuser" and password == "local pw"


class Unlock(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        cfg = ws.Config()
        cfg.root, cfg.workgroup, cfg.fail_delay, cfg.hs = self.tmp, "", 0, "/nonexistent/hs"
        self.auth = FakeAuth(cfg)
        self.app = ws.App(cfg, self.auth)
        self.calls = []
        self.answer = (0, "Unlocked.\n")
        self.real_run = ws._run
        ws._run = self.fake_run
        self.srv = ws.Server(("127.0.0.1", 0), ws.make_handler(self.app))
        self.port = self.srv.server_address[1]
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.cookie, self.csrf = self.sign_in()

    def tearDown(self):
        ws._run = self.real_run
        self.srv.shutdown()
        self.srv.server_close()

    def fake_run(self, cmd, stdin=None, timeout=10):
        self.calls.append((list(cmd), stdin, timeout))
        a = self.answer
        if a[0] == 0:
            self.auth.locked = False
        return a

    def req(self, method, path, body=None, headers=None, origin=True, ctype="application/json", raw=None):
        h = dict(headers or {})
        data = raw if raw is not None else (json.dumps(body) if body is not None else None)
        if data is not None:
            h["Content-Type"] = ctype
        if method == "POST" and origin:
            h.setdefault("Origin", "http://127.0.0.1:%d" % self.port)
        c = http.client.HTTPConnection("127.0.0.1", self.port)
        c.request(method, path, data, h)
        r = c.getresponse()
        out = (r.status, r.read(), r)
        c.close()
        return out

    def sign_in(self):
        s, d, r = self.req("POST", "/api/login", {"realm": "local", "user": "adminuser", "password": "local pw"})
        assert s == 200, d
        return r.getheader("Set-Cookie").split(";")[0], json.loads(d)["csrf"]

    def unlock(self, body=None, raw=None, headers=None, **kw):
        if body is None and raw is None:
            body = {"passphrase": SECRET}
        h = {"Cookie": self.cookie, "X-CSRF-Token": self.csrf}
        h.update(headers or {})
        s, d, r = self.req("POST", "/api/unlock", body, h, raw=raw, **kw)
        try:
            return s, json.loads(d)
        except ValueError:
            return s, d

    def test_ok_passes_passphrase_on_stdin_only(self):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            s, d = self.unlock()
        self.assertEqual((s, d["status"]), (200, "ok"))
        cmd, stdin, timeout = self.calls[0]
        self.assertEqual(cmd, ["/nonexistent/hs", "sys", "unlock", "stdin"])
        self.assertEqual(stdin, (SECRET + "\n").encode())
        self.assertEqual(timeout, 180)
        self.assertNotIn(SECRET, " ".join(cmd))
        self.assertNotIn(SECRET, json.dumps(d))
        self.assertNotIn(SECRET, buf.getvalue())
        self.assertIn("web unlock: adminuser", buf.getvalue())

    def test_failure_never_echoes_passphrase(self):
        self.answer = (1, "x The passphrase opens nothing. %s\n" % SECRET)
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            s, d = self.unlock()
        self.assertEqual((s, d["status"], d["reason"]), (422, "failed", "Wrong passphrase."))
        self.assertNotIn(SECRET, json.dumps(d) + buf.getvalue())
        self.assertTrue(self.auth.locked)

    def test_other_failure_reasons(self):
        self.answer = (1, "Still locked: /dev/sdb")
        self.assertIn("stayed locked", self.unlock()[1]["reason"])
        self.answer = (1, "boom %s" % SECRET)
        s, d = self.unlock()
        self.assertEqual(d["status"], "failed")
        self.assertNotIn(SECRET, json.dumps(d))

    def test_refused_when_not_locked(self):
        self.auth.locked = False
        s, d = self.unlock()
        self.assertEqual((s, d["status"]), (409, "failed"))
        self.assertEqual(self.calls, [])

    def test_needs_session_csrf_origin(self):
        s, _, _ = self.req("POST", "/api/unlock", {"passphrase": "x"})
        self.assertEqual(s, 401)
        s, _ = self.unlock(headers={"X-CSRF-Token": "wrong"})
        self.assertEqual(s, 403)
        s, _ = self.unlock(origin=False)
        self.assertEqual(s, 403)
        s, _ = self.unlock(headers={"Origin": "http://evil.example"})
        self.assertEqual(s, 403)
        self.assertEqual(self.calls, [])

    def test_bad_bodies(self):
        for body in ({"x": 1}, {"passphrase": ""}, {"passphrase": 5}, {"passphrase": None}, {"passphrase": "a\nb"},
                     {"passphrase": "a\x00b"}, {"passphrase": "a" * 257}):
            s, _ = self.unlock(body=body)
            self.assertEqual(s, 400, body)
        s, _ = self.unlock(raw="not json")
        self.assertEqual(s, 400)
        s, _ = self.unlock(body={"passphrase": "x"}, ctype="text/plain")
        self.assertEqual(s, 400)
        self.assertEqual(self.calls, [])

    def test_throttle_after_five_failures(self):
        self.answer = (1, "The passphrase opens nothing.")
        for _ in range(5):
            self.assertEqual(self.unlock()[0], 422)
        s, d = self.unlock()
        self.assertEqual(s, 429)
        self.assertGreater(d["retry_after"], 0)
        self.assertEqual(len(self.calls), 5)

    def test_success_resets_throttle(self):
        self.answer = (1, "The passphrase opens nothing.")
        for _ in range(3):
            self.unlock()
        self.answer = (0, "")
        self.assertEqual(self.unlock()[0], 200)
        self.assertEqual(self.app.throttle.wait("unlock"), 0)

    def test_busy_while_another_unlock_runs(self):
        ws.UNLOCK_LOCK.acquire()
        try:
            s, d = self.unlock()
        finally:
            ws.UNLOCK_LOCK.release()
        self.assertEqual((s, d["status"]), (409, "busy"))
        self.assertEqual(self.calls, [])

    def test_run_failure_is_not_counted(self):
        self.answer = (127, "")
        for _ in range(6):
            s, d = self.unlock()
        self.assertEqual(s, 422)


if __name__ == "__main__":
    unittest.main()
