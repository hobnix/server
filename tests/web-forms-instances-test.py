#!/usr/bin/env python3
"""scripts/web-serve.py: the `ct` entries of CHANGES that the Instances forms use (create, set, ip, add-storage, remove-storage)."""
import importlib.util
import os
import unittest

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("web_serve", os.path.join(here, "..", "scripts", "web-serve.py"))
ws = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ws)


def ok(*args, confirm=None):
    return ws.validate_change({"area": "ct", "args": list(args), "confirm": confirm}) is not None


class CtForms(unittest.TestCase):
    def test_allowed(self):
        self.assertTrue(ok("web1", "create"))
        self.assertTrue(ok("web1", "create", "--type", "vm", "--ram", "2048", "--cpu", "2", "--disk", "30", "--address", "10.10.95.25"))
        self.assertTrue(ok("web1", "create", "--address", "10.10.95.25", "--type", "docker", "--ram", "none"))
        self.assertTrue(ok("web1", "create", "--profile", "home", "--bind", "shares:media:/media", "--bind", "fast:data-1:/srv/data:ro", "--type", "docker"))
        self.assertTrue(ok("web1", "set", "--ram", "none", "--cpu", "4", "--disk", "50", "--autostart", "yes", "--docker", "no"))
        self.assertTrue(ok("web1", "ip", "--address", "10.10.95.40"))
        self.assertTrue(ok("web1", "add-storage", "--kind", "shares", "--name", "media", "--path", "/media/tv", "--readonly", "--as", "1000:1000"))
        self.assertTrue(ok("web1", "add-storage", "--kind", "fast", "--name", "data-1", "--path", "/srv/data"))
        self.assertTrue(ok("web1", "remove-storage", "--device", "media"))

    def test_refused_shapes(self):
        bad = [
            ("Web", "create"), ("web1;ls", "set"), ("-x", "create"),
            ("web1", "create", "--type", "lxc"), ("web1", "create", "--ram", "12"), ("web1", "create", "--ram", "-5"),
            ("web1", "create", "--ram", "999999999"), ("web1", "create", "--cpu", "0"), ("web1", "create", "--cpu", "300"),
            ("web1", "create", "--disk", "0"), ("web1", "create", "--disk", "5 "), ("web1", "create", "--disk", "123456"),
            ("web1", "create", "--address", "10.10.95.256"), ("web1", "create", "--address", "10.10.95"), ("web1", "create", "--address", "a.b.c.d"),
            ("web1", "create", "--ram"), ("web1", "create", "--ram", "512", "--ram", "1024"), ("web1", "create", "--bogus", "1"),
            ("web1", "create", "--profile", "x y"), ("web1", "create", "--profile", "-x"), ("web1", "create", "--profile", "a;b"),
            ("web1", "create", "--profile", "a", "--profile", "b"), ("web1", "create", "--profile"), ("web1", "create", "extra"),
            ("web1", "create", "--bind", "shares:media"), ("web1", "create", "--bind", "shares:media:media"), ("web1", "create", "--bind", "shares:media:/a/../b"),
            ("web1", "create", "--bind", "other:media:/m"), ("web1", "create", "--bind", "shares:m;x:/m"), ("web1", "create", "--bind", "shares:media:/m:rw"),
            ("web1", "create", "--bind", "shares:media:/m x"), ("web1", "create", "--bind", "shares:-m:/m"), ("web1", "create", "--bind"),
            ("web1", "set", "--profile", "home"), ("web1", "start", "--bind", "fast:x:/x"),
            ("web1", "set", "--autostart", "maybe"), ("web1", "set", "--docker", "1"), ("web1", "set", "--address", "10.10.95.2"),
            ("web1", "ip", "--address", "10.10.95.2/24"), ("web1", "ip", "--address", "10.10.95.2 --x"),
            ("web1", "add-storage", "--kind", "other", "--name", "m", "--path", "/m"),
            ("web1", "add-storage", "--kind", "shares", "--name", "m", "--path", "/a/../etc"),
            ("web1", "add-storage", "--kind", "shares", "--name", "m", "--path", "relative"),
            ("web1", "add-storage", "--kind", "shares", "--name", "m", "--path", "/a b"),
            ("web1", "add-storage", "--kind", "shares", "--name", "../m", "--path", "/m"),
            ("web1", "add-storage", "--kind", "shares", "--name", "-m", "--path", "/m"),
            ("web1", "add-storage", "--kind", "shares", "--name", "m", "--path", "/m", "--as", "root"),
            ("web1", "add-storage", "--kind", "shares", "--name", "m", "--path", "/m", "--readonly", "yes"),
            ("web1", "add-storage", "--kind", "shares", "--name", "m", "--path", "/m", "--confirm", "x"),
            ("web1", "remove-storage", "--device", "a/b"), ("web1", "remove-storage", "--device", ""),
            ("web1", "frobnicate"),
        ]
        for a in bad:
            with self.subTest(args=a):
                self.assertFalse(ok(*a))

    def test_old_shapes_still_work(self):
        for a in (("web1", "start"), ("web1", "update"), ("web1", "snapshot", "--label", "x"), ("web1", "restore", "--snapshot", "s1")):
            self.assertTrue(ok(*a), a)

    def test_no_stdin_for_ct(self):
        self.assertIsNone(ws.validate_change({"area": "ct", "args": ["web1", "create"], "stdin": "pw"}))

    def test_every_action_is_known_to_ct_change(self):
        src = open(os.path.join(here, "..", "scripts", "ct-change.sh"), encoding="utf-8").read()
        for e in ws.CHANGES["ct"]:
            if isinstance(e, dict):
                self.assertIn(e["fixed"][1].strip("^$"), src)
                for flag in e["opts"]:
                    self.assertIn(flag + ")", src)


if __name__ == "__main__":
    unittest.main()
