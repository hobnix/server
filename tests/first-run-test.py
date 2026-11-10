#!/usr/bin/env python3
"""scripts/first_run.py (token, flag, expiry, burn) and POST /api/setup in scripts/web-serve.py (real HTTP server, fake helpers)."""
import http.client
import importlib.util
import json
import os
import random
import tempfile
import threading
import unittest

here = os.path.dirname(os.path.abspath(__file__))
scripts = os.path.join(here, "..", "scripts")


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(scripts, file))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


fr = load("first_run", "first_run.py")
ws = load("web_serve", "web-serve.py")
os.environ["HS_WEB_QUIET"] = "1"


class Clock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now


class Unit(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.path = os.path.join(self.tmp, "first-run.json")
        self.clock = Clock()
        self.fr = fr.FirstRun(self.path, ttl=600, max_fails=3, clock=self.clock, rng=random.Random(1))

    def ok(self, token, user="adminuser"):
        return self.fr.redeem(token, lambda: user)

    def test_no_file_means_no_setup(self):
        self.assertEqual(self.fr.status(), {"state": "none"})
        self.assertFalse(self.fr.is_open())
        self.assertEqual(self.ok("AAAAA-AAAAA-AAAAA-AAAAA")[0], fr.NONE)

    def test_token_shape_and_file_holds_no_token(self):
        t = self.fr.issue()
        self.assertRegex(t, r"^[A-HJ-NP-Z2-9]{5}(-[A-HJ-NP-Z2-9]{5}){3}$")
        raw = open(self.path).read()
        self.assertNotIn(t, raw)
        self.assertNotIn(t.replace("-", ""), raw)
        self.assertEqual(oct(os.stat(self.path).st_mode & 0o777), "0o600")
        self.assertTrue(self.fr.is_open())

    def test_single_use(self):
        t = self.fr.issue()
        self.assertEqual(self.ok(t), (fr.OK, "adminuser"))
        self.assertEqual(self.ok(t)[0], fr.DONE)
        self.assertEqual(self.fr.status(), {"state": "done", "user": "adminuser"})
        self.assertFalse(self.fr.is_open())

    def test_typed_forms_are_accepted(self):
        t = self.fr.issue()
        self.assertEqual(self.ok(" " + t.lower().replace("-", " ") + " ")[0], fr.OK)

    def test_bound_to_the_account_the_action_returns(self):
        t = self.fr.issue()
        self.ok(t, "boss")
        self.assertEqual(self.fr.status()["user"], "boss")

    def test_failed_action_keeps_the_token(self):
        t = self.fr.issue()
        self.assertEqual(self.fr.redeem(t, lambda: None)[0], fr.FAILED)
        self.assertEqual(self.ok(t)[0], fr.OK)

    def test_expiry(self):
        t = self.fr.issue()
        self.clock.now += 599
        self.assertEqual(self.fr.status()["expires_in"], 1)
        self.clock.now += 1
        self.assertEqual(self.fr.status(), {"state": "expired"})
        self.assertEqual(self.ok(t)[0], fr.EXPIRED)

    def test_wrong_tokens_burn_the_real_one(self):
        t = self.fr.issue()
        self.assertEqual(self.ok("BBBBB-BBBBB-BBBBB-BBBBB")[0], fr.BAD)
        self.assertEqual(self.ok("garbage")[0], fr.BAD)
        self.assertEqual(self.ok(None)[0], fr.BURNED)
        self.assertEqual(self.ok(t)[0], fr.BURNED)          # even the right one is dead now
        self.assertEqual(self.fr.status(), {"state": "burned"})

    def test_reissue_replaces_old_token_and_resets_counters(self):
        old = self.fr.issue()
        self.ok("BBBBB-BBBBB-BBBBB-BBBBB")
        new = self.fr.issue()
        self.assertNotEqual(old, new)
        self.assertEqual(self.ok(old)[0], fr.BAD)
        self.assertEqual(self.ok(new)[0], fr.OK)

    def test_reboot_keeps_a_pending_setup_and_a_reissue_works(self):
        t = self.fr.issue()
        again = fr.FirstRun(self.path, ttl=600, max_fails=3, clock=self.clock)       # a new process reads the same file
        self.assertTrue(again.is_open())
        self.assertEqual(again.redeem(t, lambda: "adminuser")[0], fr.OK)

    def test_done_cannot_be_issued_again_until_reset(self):
        self.ok(self.fr.issue())
        self.assertIsNone(self.fr.issue())
        self.fr.reset()
        self.assertIsNotNone(self.fr.issue())

    def test_damaged_file_is_not_a_setup(self):
        open(self.path, "w").write("{not json")
        self.assertEqual(self.fr.status(), {"state": "none"})

    def test_password_rules(self):
        self.assertIsNotNone(fr.password_problem("short"))
        self.assertIsNotNone(fr.password_problem("x" * 300))
        self.assertIsNotNone(fr.password_problem("long enough\nline"))
        self.assertIsNone(fr.password_problem("long enough: with a colon"))


class FakeAuth:
    def __init__(self, cfg):
        self.cfg, self.passwords, self.fail = cfg, [], False

    def storage_locked(self):
        return False

    def local_password_ok(self, user, password):
        return False

    def set_local_password(self, user, password):
        if self.fail:
            return False
        self.passwords.append((user, password))
        return True


class Web(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        cfg = ws.Config()
        cfg.root, cfg.fail_delay, cfg.hs = self.tmp, 0, "/nonexistent/hs"
        cfg.first_run_file = os.path.join(self.tmp, "first-run.json")
        self.cfg = cfg
        self.auth = FakeAuth(cfg)
        self.app = ws.App(cfg, self.auth)
        self.clock = Clock()
        self.app.first_run = fr.FirstRun(cfg.first_run_file, ttl=600, max_fails=3, clock=self.clock)
        self.srv = ws.Server(("127.0.0.1", 0), ws.make_handler(self.app))
        self.port = self.srv.server_address[1]
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def tearDown(self):
        self.srv.shutdown()
        self.srv.server_close()

    def post(self, body, path="/api/setup", origin=True):
        h = {"Content-Type": "application/json"}
        if origin:
            h["Origin"] = "http://127.0.0.1:%d" % self.port
        c = http.client.HTTPConnection("127.0.0.1", self.port)
        c.request("POST", path, json.dumps(body), h)
        r = c.getresponse()
        data = json.loads(r.read() or b"{}")
        c.close()
        return r.status, data, r

    def hello(self):
        c = http.client.HTTPConnection("127.0.0.1", self.port)
        c.request("GET", "/api/hello")
        return json.loads(c.getresponse().read())

    def test_hello_says_only_whether_setup_is_open(self):
        self.assertEqual(self.hello()["setup"], {"open": False})
        self.app.first_run.issue()
        self.assertEqual(self.hello()["setup"], {"open": True})

    def test_no_flag_no_setup(self):
        st, _, _ = self.post({"token": "AAAAA-AAAAA-AAAAA-AAAAA", "password": "a long password"})
        self.assertEqual(st, 404)
        self.assertEqual(self.auth.passwords, [])

    def test_feature_off_without_a_file_path(self):
        self.cfg.first_run_file = ""
        st, _, _ = self.post({"token": "x", "password": "a long password"})
        self.assertEqual(st, 404)

    def test_happy_path_sets_password_signs_in_and_is_single_use(self):
        t = self.app.first_run.issue()
        st, d, r = self.post({"token": t, "password": "a long password"})
        self.assertEqual(st, 200)
        self.assertEqual((d["user"], d["realm"]), ("adminuser", "local"))
        self.assertIn("HttpOnly", r.getheader("Set-Cookie"))
        self.assertEqual(self.auth.passwords, [("adminuser", "a long password")])
        self.assertEqual(self.hello()["setup"], {"open": False})
        st, d, _ = self.post({"token": t, "password": "another long password"})
        self.assertEqual(st, 409)
        self.assertEqual(len(self.auth.passwords), 1)

    def test_wrong_token_then_burned(self):
        t = self.app.first_run.issue()
        for _ in range(2):
            self.assertEqual(self.post({"token": "BBBBB-BBBBB-BBBBB-BBBBB", "password": "a long password"})[0], 401)
        self.assertEqual(self.post({"token": "BBBBB-BBBBB-BBBBB-BBBBB", "password": "a long password"})[0], 403)
        self.assertEqual(self.post({"token": t, "password": "a long password"})[0], 403)
        self.assertEqual(self.auth.passwords, [])

    def test_expired(self):
        t = self.app.first_run.issue()
        self.clock.now += 601
        st, d, _ = self.post({"token": t, "password": "a long password"})
        self.assertEqual(st, 403)
        self.assertIn("expired", d["error"])

    def test_weak_password_does_not_use_the_token_up(self):
        t = self.app.first_run.issue()
        self.assertEqual(self.post({"token": t, "password": "short"})[0], 400)
        self.assertEqual(self.post({"token": t, "password": "a long password"})[0], 200)

    def test_helper_failure_keeps_the_token(self):
        t = self.app.first_run.issue()
        self.auth.fail = True
        self.assertEqual(self.post({"token": t, "password": "a long password"})[0], 500)
        self.auth.fail = False
        self.assertEqual(self.post({"token": t, "password": "a long password"})[0], 200)

    def test_origin_and_shape_are_checked(self):
        t = self.app.first_run.issue()
        self.assertEqual(self.post({"token": t, "password": "a long password"}, origin=False)[0], 403)
        self.assertEqual(self.post({"token": 5, "password": "a long password"})[0], 400)
        self.assertEqual(self.auth.passwords, [])

    def test_public_address_is_refused(self):
        t = self.app.first_run.issue()
        real = ws.private_client
        ws.private_client = lambda ip: False
        try:
            st, _, _ = self.post({"token": t, "password": "a long password"})
        finally:
            ws.private_client = real
        self.assertEqual(st, 403)
        self.assertTrue(self.app.first_run.is_open())

    def test_ip_throttle(self):
        self.app.first_run.max_fails = 100
        self.app.first_run.issue()
        codes = [self.post({"token": "BBBBB-BBBBB-BBBBB-BBBBB", "password": "a long password"})[0] for _ in range(7)]
        self.assertEqual(codes[:5], [401] * 5)
        self.assertIn(429, codes)

    def test_token_and_password_never_reach_the_log(self):
        import io
        import contextlib
        t = self.app.first_run.issue()
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            self.post({"token": "BBBBB-BBBBB-BBBBB-BBBBB", "password": "secret password 1"})
            self.post({"token": t, "password": "secret password 2"})
        out = buf.getvalue()
        for s in (t, "secret password", "BBBBB"):
            self.assertNotIn(s, out)


if __name__ == "__main__":
    unittest.main()
