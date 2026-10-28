#!/usr/bin/env python3
"""scripts/web-serve.py: the `ssh-key` area of CHANGES and READS (add and remove an SSH key of adminuser). Real server, fake _run."""
import http.client
import importlib.util
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

BODY = "AAAAC3NzaC1lZDI1NTE5AAAAIMX8lpQjQb6PbJgJdm04fmlDL3jrFU36bP2ND8YejjS"
KEY = "ssh-ed25519 " + BODY + " anna@pc"


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


class SshKey(unittest.TestCase):
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
        c.request(method, path, json.dumps(body) if body is not None else None, h)
        r = c.getresponse()
        data = r.read()
        c.close()
        return r.status, data, r

    def post(self, verb, args, **extra):
        return self.raw("POST", "/api/" + verb, {"area": "ssh-key", "args": args, **extra}, self.ck)[0]

    def ok(self, args, verb="plan", **extra):
        n = len(self.calls)
        self.assertEqual(self.post(verb, args, **extra), 200, args)
        self.assertEqual(len(self.calls), n + 1, args)

    def refused(self, args, verb="plan", **extra):
        n = len(self.calls)
        self.assertEqual(self.post(verb, args, **extra), 400, (args, extra))
        self.assertEqual(len(self.calls), n, args)

    def test_allowed_shapes(self):
        for a in (["add", KEY], ["add", "ssh-ed25519 " + BODY], ["add", "ssh-rsa " + "A" * 700 + "=="],
                  ["add", "ecdsa-sha2-nistp256 " + BODY + " my laptop 2026"],
                  ["add", "sk-ssh-ed25519@openssh.com " + BODY + " yubikey"],
                  ["remove", "SHA256:TbUAkW4ks6wA0NRwPTMmFp65xWLKiikve17EnDDVpaE"], ["remove", "anna@pc"], ["remove", "old rsa key"]):
            self.ok(a)
            self.ok(a, verb="start", confirm="remove")

    def test_argv_is_exact(self):
        self.ok(["add", KEY], verb="start")
        self.assertEqual(self.calls[-1][0], ["/nonexistent/hs", "sys", "ssh-key", "start", "add", KEY])
        self.ok(["remove", "anna@pc"], verb="start", confirm="remove")
        self.assertEqual(self.calls[-1][0], ["/nonexistent/hs", "sys", "ssh-key", "start", "remove", "anna@pc", "--confirm", "remove"])

    def test_refused_shapes(self):
        bad = [[], ["add"], ["remove"], ["wipe", KEY], ["add", KEY, "extra"], ["remove", "a", "b"],
               ["add", ""], ["add", "hello world"], ["add", "ssh-ed25519"], ["add", "ssh-ed25519 " + BODY + " "],
               ["add", "ssh-dss " + BODY], ["add", "-----BEGIN OPENSSH PRIVATE KEY-----"], ["add", "ssh-ed25519 short"],
               ["remove", ""], ["remove", "-rf"], ["remove", "--confirm"], ["remove", " lead"], ["remove", "a" * 200]]
        for a in bad:
            self.refused(a)
            self.refused(a, verb="start")

    def test_injection(self):
        for a in ('command="rm -rf /" ' + KEY,          # an options prefix would give the key more power
                  "no-pty " + KEY, 'from="*" ' + KEY,
                  KEY + "\n" + KEY, KEY + "\nssh-rsa " + BODY, "\n" + KEY, KEY + "\n", KEY + "\r", KEY + "\t",
                  KEY + ' "x', KEY + " $(id)", KEY + " `id`", KEY + "; ls", KEY + " | cat", KEY + " & ls", KEY + " > /x", KEY + " \\x",
                  KEY + " ${HOME}", "ssh-ed25519 " + BODY + "$(id)", "ssh-ed25519 " + BODY + " a'b",
                  "ssh-ed25519\t" + BODY, "ssh-ed25519  " + BODY, KEY + "\x00", KEY + " " + "c" * 101,
                  "ssh-ed25519 " + "A" * 800, "ssh-ed25519 " + BODY + " " + "x" * 900):
            self.refused(["add", a])
            self.refused(["add", a], verb="start")
        for r in ("a\nb", "a;b", "a$(id)", "a`id`", "a|b", 'a"b', "a'b", "../x", "x" * 150, "SHA256:a\nb", "a\tb", "a>b", "a&b"):
            self.refused(["remove", r])
            self.refused(["remove", r], verb="start", confirm="remove")

    def test_confirm_shape(self):
        self.refused(["remove", "anna@pc"], verb="start", confirm="a;b")
        self.refused(["remove", "anna@pc"], verb="start", confirm="x" * 100)

    def test_stdin_never_passes(self):
        self.refused(["add", KEY], stdin="secret")
        self.refused(["remove", "anna@pc"], verb="start", stdin="secret")

    def test_read_is_listed(self):
        self.assertEqual(ws.READS[("ssh-key", "list")]["kind"], "tsv")
        s, d, r = self.raw("GET", "/api/sys/ssh-key/list", None, self.ck)
        self.assertEqual(s, 200)
        self.assertEqual(self.calls[-1][0], ["/nonexistent/hs", "sys", "ssh-key", "list"])

    def test_other_areas_unchanged(self):
        self.assertEqual(self.raw("POST", "/api/plan", {"area": "ct", "args": ["add", KEY]}, self.ck)[0], 400)


if __name__ == "__main__":
    unittest.main()
