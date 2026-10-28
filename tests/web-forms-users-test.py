#!/usr/bin/env python3
"""scripts/web-serve.py: the `users` area of CHANGES (new user, password, group, membership, deletes, flush). Real server, fake _run."""
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

SECRET = "Sup3r secret pw!"


class FakeAuth:
    def __init__(self, cfg):
        self.cfg = cfg

    def storage_locked(self):
        return False

    def domain_password_ok(self, user, password):
        return user == "anna" and password == "pw"

    def domain_is_admin(self, user):
        return user == "anna"

    def local_password_ok(self, user, password):
        return False


class Users(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        with open(os.path.join(self.tmp, "index.html"), "w") as f:
            f.write("app")
        cfg = ws.Config()
        cfg.root, cfg.workgroup, cfg.realm, cfg.fail_delay, cfg.hs = self.tmp, "HOME", "ad.home.lan", 0, "/nonexistent/hs"
        self.app = ws.App(cfg, FakeAuth(cfg))
        self.srv = ws.Server(("127.0.0.1", 0), ws.make_handler(self.app))
        self.port = self.srv.server_address[1]
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.calls = []
        self.real_run = ws._run

        def fake(cmd, stdin=None, timeout=10):
            self.calls.append((cmd, stdin))
            return 0, "status\tok\nheading\tx\n"
        ws._run = fake
        s, d, r = self.raw("POST", "/api/login", {"realm": "domain", "user": "anna", "password": "pw"})
        self.ck = {"Cookie": (r.getheader("Set-Cookie") or "").split(";")[0], "X-CSRF-Token": json.loads(d)["csrf"]}
        self.calls.clear()

    def tearDown(self):
        ws._run = self.real_run
        self.srv.shutdown()
        self.srv.server_close()

    def raw(self, method, path, body, headers=None):
        h = {"Content-Type": "application/json", "Origin": "http://127.0.0.1:%d" % self.port, **(headers or {})}
        c = http.client.HTTPConnection("127.0.0.1", self.port)
        c.request(method, path, json.dumps(body), h)
        r = c.getresponse()
        data = r.read()
        c.close()
        return r.status, data, r

    def post(self, verb, args, **extra):
        return self.raw("POST", "/api/" + verb, {"area": "users", "args": args, **extra}, self.ck)[0]

    def ok(self, args, verb="plan", **extra):
        n = len(self.calls)
        self.assertEqual(self.post(verb, args, **extra), 200, args)
        self.assertEqual(len(self.calls), n + 1, args)

    def refused(self, args, verb="plan", **extra):
        n = len(self.calls)
        self.assertEqual(self.post(verb, args, **extra), 400, (args, extra))
        self.assertEqual(len(self.calls), n, args)

    def test_allowed_shapes(self):
        for a in (["anna", "lock"], ["anna", "unlock"], ["newuser", "user-add"], ["newuser", "user-add", "--full", "Anna Mueller"],
                  ["newuser", "user-add", "--group", "Staff", "--group", "Domain Admins", "--full", "A B"], ["Crew", "group-add", "--access", "media=read", "--access", "photos=full"],
                  ["anna", "password"], ["Staff", "group-add"], ["anna", "user-delete"], ["Domain Admins", "group-delete"],
                  ["all", "flush"], ["anna", "membership", "--change", "anna:Staff=add"],
                  ["Domain Admins", "membership", "--change", "anna:Domain Admins=remove", "--change", "bob:Domain Admins=add"]):
            self.ok(a)
            self.ok(a, verb="start")

    def test_argv_is_exact(self):
        self.ok(["Domain Admins", "membership", "--change", "bob:Domain Admins=add"], verb="start", confirm="x y")
        self.assertEqual(self.calls[-1][0], ["/nonexistent/hs", "sys", "users", "start", "Domain Admins", "membership", "--change",
                                             "bob:Domain Admins=add", "--confirm", "x y"])

    def test_refused_shapes(self):
        for a in ([], ["anna"], ["anna", "bogus"], ["1anna", "user-add"], ["-x", "user-add"], ["a;b", "user-add"], ["anna", "user-add", "--full"],
                  ["anna", "user-add", "--full", "-rf"], ["anna", "user-add", "--full", "A\nB"], ["anna", "user-add", "--full", "a", "--full", "b"],
                  ["anna", "user-add", "--evil", "x"], ["anna", "lock", "--full", "x"], ["anna", "password", "extra"],
                  ["anna", "membership", "--change"], ["anna", "membership", "--change", "anna:Staff=toggle"],
                  ["anna", "membership", "--change", "anna:-Staff=add"], ["anna", "membership", "--change", "a:b=add;ls"],
                  ["anna", "membership", "--change", "anna:Staff=add", "--full", "x"], ["../x", "group-delete"], ["x", "flush"],
                  ["newuser", "user-add", "--group"], ["newuser", "user-add", "--group", "-x"], ["newuser", "user-add", "--group", "a;b"],
                  ["newuser", "user-add", "--group", "x" * 70], ["anna", "lock", "--group", "Staff"], ["anna", "password", "--group", "Staff"],
                  ["Crew", "group-add", "--access"], ["Crew", "group-add", "--access", "media"], ["Crew", "group-add", "--access", "media=none"],
                  ["Crew", "group-add", "--access", "media=admin"], ["Crew", "group-add", "--access", "../x=read"], ["Crew", "group-add", "--access", "me;dia=read"],
                  ["Crew", "group-add", "--access", "Media=read"], ["Crew", "group-delete", "--access", "media=read"], ["anna", "lock", "--access", "media=read"],
                  ["Crew", "group-add", "--group", "Staff"], ["newuser", "user-add", "--access", "media=read"],
                  ["anna", "user-delete", "--confirm", "anna"], ["anna", "group-add", "--full", "x"], ["a" * 40, "user-add"]):
            self.refused(a)
            self.refused(a, verb="start")

    def test_argv_with_groups_and_access(self):
        self.ok(["newuser", "user-add", "--group", "Domain Admins"], verb="start", stdin=SECRET)
        self.assertEqual(self.calls[-1][0], ["/nonexistent/hs", "sys", "users", "start", "newuser", "user-add", "--group", "Domain Admins"])
        self.ok(["Crew", "group-add", "--access", "media=read"], verb="start")
        self.assertEqual(self.calls[-1][0], ["/nonexistent/hs", "sys", "users", "start", "Crew", "group-add", "--access", "media=read"])
        self.refused(["Crew", "group-add", "--access", "media=read"], stdin=SECRET)

    def test_stdin_only_where_the_script_reads_it(self):
        self.ok(["newuser", "user-add"], stdin=SECRET)
        self.ok(["anna", "password"], verb="start", stdin=SECRET)
        for a in (["anna", "lock"], ["Staff", "group-add"], ["anna", "user-delete"], ["Staff", "group-delete"], ["all", "flush"],
                  ["anna", "membership", "--change", "anna:Staff=add"]):
            self.refused(a, stdin=SECRET)
            self.refused(a, verb="start", stdin=SECRET)

    def test_stdin_shape(self):
        for bad in ("a\nb", "", "x" * 300, "a\x00b", 5, ["x"]):
            self.refused(["anna", "password"], stdin=bad)

    def test_password_is_on_stdin_only(self):
        self.ok(["newuser", "user-add", "--full", "New User"], verb="start", stdin=SECRET)
        cmd, stdin = self.calls[-1]
        self.assertEqual(stdin, (SECRET + "\n").encode())
        self.assertFalse(any(SECRET in a for a in cmd))

    def test_password_not_in_logs(self):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            self.ok(["anna", "password"], verb="start", stdin=SECRET)
        self.assertIn("anna password", buf.getvalue())
        self.assertNotIn(SECRET, buf.getvalue())

    def test_other_areas_unchanged(self):
        self.assertEqual(self.raw("POST", "/api/plan", {"area": "ct", "args": ["docker", "stop"], "stdin": SECRET}, self.ck)[0], 400)
        self.assertEqual(self.raw("POST", "/api/plan", {"area": "shares", "args": ["media", "snapshot"]}, self.ck)[0], 200)


if __name__ == "__main__":
    unittest.main()
