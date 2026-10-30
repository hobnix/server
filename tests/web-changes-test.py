#!/usr/bin/env python3
"""scripts/web-serve.py: What's new. The read `changes list` is allowlisted and a `sys` row; GET/POST /api/changes/seen: session, CSRF, revision check,
one revision per user, file mode 0600."""
import http.client
import importlib.util
import json
import os
import stat
import tempfile
import threading
import unittest

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("web_serve", os.path.join(here, "..", "scripts", "web-serve.py"))
ws = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ws)
os.environ["HS_WEB_QUIET"] = "1"

REV_A, REV_B = "a" * 40, "b" * 40


class FakeAuth:
    def __init__(self, cfg):
        self.cfg = cfg

    def storage_locked(self):
        return False

    def domain_password_ok(self, user, password):
        return password == "pw"

    def domain_is_admin(self, user):
        return True

    def local_password_ok(self, user, password):
        return password == "pw"


class Changes(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.file = os.path.join(self.tmp, "web-changes-seen.json")
        os.environ["HS_WEB_CHANGES_SEEN_FILE"] = self.file
        os.environ["HS_STATE_DIR"] = self.tmp
        self.start()

    def start(self):
        cfg = self.cfg = ws.Config()
        cfg.workgroup = "HOME"
        cfg.fail_delay, cfg.hs, cfg.root, cfg.session_file = 0, "/nonexistent/hs", self.tmp, ""
        self.app = ws.App(cfg, FakeAuth(cfg))
        self.srv = ws.Server(("127.0.0.1", 0), ws.make_handler(self.app))
        self.port = self.srv.server_address[1]
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.alice = self.login("local", self.cfg.local_user)
        self.bob = self.login("domain", "bob")

    def stop(self):
        self.srv.shutdown()
        self.srv.server_close()

    def tearDown(self):
        self.stop()
        os.environ.pop("HS_WEB_CHANGES_SEEN_FILE", None)
        os.environ.pop("HS_STATE_DIR", None)

    def login(self, realm, user):
        c = http.client.HTTPConnection("127.0.0.1", self.port)
        c.request("POST", "/api/login", json.dumps({"realm": realm, "user": user, "password": "pw"}),
                  {"Content-Type": "application/json", "Origin": "http://127.0.0.1:%d" % self.port})
        r = c.getresponse()
        cookie, csrf = r.getheader("Set-Cookie").split(";")[0], json.loads(r.read())["csrf"]
        c.close()
        return cookie, csrf

    def get(self, who=None):
        c = http.client.HTTPConnection("127.0.0.1", self.port)
        c.request("GET", "/api/changes/seen", headers={"Cookie": who[0]} if who else {})
        r = c.getresponse()
        out = r.status, json.loads(r.read())
        c.close()
        return out

    def post(self, body, who=None, csrf=True):
        h = {"Content-Type": "application/json", "Origin": "http://127.0.0.1:%d" % self.port}
        if who:
            h["Cookie"] = who[0]
            if csrf:
                h["X-CSRF-Token"] = who[1]
        c = http.client.HTTPConnection("127.0.0.1", self.port)
        c.request("POST", "/api/changes/seen", json.dumps(body), h)
        r = c.getresponse()
        out = r.status, json.loads(r.read())
        c.close()
        return out

    def test_read_is_allowlisted_and_a_sys_row(self):
        self.assertIn(("changes", "list"), ws.READS)
        with open(os.path.join(here, "..", "scripts", "lib", "registry.tsv"), encoding="utf-8") as f:
            rows = [l.split("\t") for l in f.read().splitlines() if l and not l.startswith("#")]
        self.assertTrue(any(r[0] == "sys" and r[1] == "sys changes list" for r in rows))

    def test_read_query_is_checked(self):
        _, argv, _ = self.app.reads.resolve(["changes", "list"], {"from": [REV_A]})
        self.assertEqual(argv, ["changes", "list", "--from", REV_A])
        _, argv, _ = self.app.reads.resolve(["changes", "list"], {"since": ["2026-10-01"]})
        self.assertEqual(argv, ["changes", "list", "--since", "2026-10-01"])
        self.assertIsNone(self.app.reads.resolve(["changes", "list"], {"from": ["--all"]}))
        self.assertIsNone(self.app.reads.resolve(["changes", "list"], {"since": ["yesterday"]}))

    def test_needs_a_session(self):
        self.assertEqual(self.get()[0], 401)
        self.assertEqual(self.post({"rev": REV_A})[0], 401)

    def test_post_needs_the_csrf_token(self):
        self.assertEqual(self.post({"rev": REV_A}, self.alice, csrf=False)[0], 403)
        self.assertEqual(self.get(self.alice), (200, {"rev": ""}))

    def test_bad_revision(self):
        for rev in ("", "abc", "A" * 40, "a" * 39, "a" * 41, "../" + "a" * 37, None, 5):
            self.assertEqual(self.post({"rev": rev}, self.alice)[0], 400, rev)
        self.assertEqual(self.post({}, self.alice)[0], 400)

    def test_round_trip_per_user_and_file_mode(self):
        self.assertEqual(self.get(self.alice), (200, {"rev": ""}))
        self.assertEqual(self.post({"rev": REV_A}, self.alice), (200, {"ok": True}))
        self.assertEqual(self.get(self.alice), (200, {"rev": REV_A}))
        self.assertEqual(self.get(self.bob), (200, {"rev": ""}))
        self.assertEqual(self.post({"rev": REV_B}, self.bob), (200, {"ok": True}))
        self.assertEqual(self.get(self.alice)[1]["rev"], REV_A)
        self.assertEqual(self.get(self.bob)[1]["rev"], REV_B)
        if os.name != "nt":      # Windows has no unix modes
            self.assertEqual(stat.S_IMODE(os.stat(self.file).st_mode), 0o600)
        with open(self.file, encoding="utf-8") as f:
            self.assertEqual(json.load(f), {self.cfg.local_user: REV_A, self.cfg.workgroup + "\\bob": REV_B})

    def test_survives_a_restart(self):
        self.post({"rev": REV_A}, self.alice)
        self.stop()
        self.start()
        self.assertEqual(self.get(self.alice), (200, {"rev": REV_A}))

    def test_memory_only(self):
        self.stop()
        os.environ["HS_WEB_CHANGES_SEEN_FILE"] = ""
        os.remove(self.file) if os.path.exists(self.file) else None
        self.start()
        self.assertEqual(self.post({"rev": REV_A}, self.alice)[0], 200)
        self.assertEqual(self.get(self.alice)[1]["rev"], REV_A)
        self.assertFalse(os.path.exists(self.file))


if __name__ == "__main__":
    unittest.main()
