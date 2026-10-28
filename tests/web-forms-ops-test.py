#!/usr/bin/env python3
"""scripts/web-serve.py CHANGES for the ops forms: system reboot|shutdown, pc wake, expiry add|remove (what passes, what is refused, the plan shapes)."""
import importlib.util
import os
import tempfile
import unittest

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("web_serve", os.path.join(here, "..", "scripts", "web-serve.py"))
ws = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ws)
# the game PC calls belong to the extension package "games" (capabilities/games/capability.toml): switch it on for the allowlist
_caps = tempfile.NamedTemporaryFile("w", suffix=".caps", delete=False)
_caps.write("games\n")
_caps.close()
os.environ["HS_CAPABILITIES_FILE"] = _caps.name
os.environ["HS_STATE_DIR"] = tempfile.mkdtemp()
ws.ext_refresh(force=True)


def ok(area, args, confirm=None, stdin=None):
    return ws.validate_change({"area": area, "args": args, "confirm": confirm, "stdin": stdin}) is not None


class Changes(unittest.TestCase):
    def test_system_power(self):
        self.assertTrue(ok("system", ["reboot"]))
        self.assertTrue(ok("system", ["shutdown"]))
        self.assertTrue(ok("system", ["reboot"], confirm="reboot"))
        self.assertTrue(ok("system", ["update"]))
        for bad in (["reboot", "--force"], ["poweroff"], ["reboot;x"], ["REBOOT"], []):
            self.assertFalse(ok("system", bad), bad)
        self.assertFalse(ok("system", ["reboot"], stdin="x"))

    def test_pc_wake(self):
        self.assertTrue(ok("ext/games", ["gaming-pc", "wake"]))
        self.assertTrue(ok("ext/games", ["PC.1", "wake"]))
        for bad in (["gaming", "sleep"], ["gaming", "wake", "--wait"], ["-x", "wake"], ["a b", "wake"], ["wake"], ["../x", "wake"], ["x" * 42, "wake"]):
            self.assertFalse(ok("ext/games", bad), bad)

    def test_pc_add_remove(self):
        self.assertTrue(ok("ext/games", ["gaming", "remove"]))
        self.assertTrue(ok("ext/games", ["gaming", "add"]))                                    # the plan answers "needs mac"
        self.assertTrue(ok("ext/games", ["gaming", "add", "--mac", "aa:bb:cc:dd:ee:ff"]))
        self.assertTrue(ok("ext/games", ["gaming", "add", "--mac", "AA-BB-CC-DD-EE-FF", "--ip", "10.10.10.50"]))
        self.assertTrue(ok("ext/games", ["gaming", "add", "--ip", "10.10.10.50", "--mac", "aa:bb:cc:dd:ee:ff"]))
        bad = [
            ["gaming", "add", "--mac", "aa:bb:cc:dd:ee"],
            ["gaming", "add", "--mac", "aa:bb:cc:dd:ee:ff:00"],
            ["gaming", "add", "--mac", "aa:bb:cc:dd:ee:gg"],
            ["gaming", "add", "--mac", "aa:bb:cc:dd:ee:ff\n"],
            ["gaming", "add", "--mac", "aa:bb:cc:dd:ee:ff", "--mac", "aa:bb:cc:dd:ee:00"],
            ["gaming", "add", "--mac", "aa:bb:cc:dd:ee:ff", "--ip", "10.10.10.256"],
            ["gaming", "add", "--mac", "aa:bb:cc:dd:ee:ff", "--ip", "10.10.10"],
            ["gaming", "add", "--mac", "aa:bb:cc:dd:ee:ff", "--ip", "host.lan"],
            ["gaming", "add", "--mac", "aa:bb:cc:dd:ee:ff", "--ip", "10.0.0.1;id"],
            ["gaming", "add", "--mac", "aa:bb:cc:dd:ee:ff", "--wait"],
            ["gaming", "add", "--mac", "aa:bb:cc:dd:ee:ff", "extra"],
            ["gaming", "remove", "--yes"],
            ["gaming", "remove", "x"],
            ["../x", "add", "--mac", "aa:bb:cc:dd:ee:ff"],
            ["a b", "add", "--mac", "aa:bb:cc:dd:ee:ff"],
            ["-x", "remove"],
            ["add", "--mac", "aa:bb:cc:dd:ee:ff"],
        ]
        for b in bad:
            self.assertFalse(ok("ext/games", b), b)
        self.assertFalse(ok("ext/games", ["gaming", "add", "--mac", "aa:bb:cc:dd:ee:ff"], stdin="x"))      # nothing here takes a password

    def test_new_reads(self):
        for words in (("hardware",), ("encryption", "list"), ("vault", "usage"), ("vault", "uses"), ("ext", "games", "state")):
            self.assertEqual(ws.READS[words]["kind"], "tsv", words)
            self.assertNotIn("args", ws.READS[words], words)            # nothing from the browser reaches these commands
            self.assertNotIn("query", ws.READS[words], words)
        for words in (("encryption",), ("vault",), ("unlock", "list"), ("ext", "games"), ("pc", "state"), ("vault", "list", "x"), ("encryption", "list", "x")):
            self.assertNotIn(words, ws.READS, words)

    def test_expiry_add(self):
        self.assertTrue(ok("expiry", ["add", "DC certificate", "--date", "2028-09-01"]))
        self.assertTrue(ok("expiry", ["add", "token", "--date", "2027-01-31", "--renew", "Cloudflare dashboard > Tunnels"]))
        self.assertTrue(ok("expiry", ["add", "token", "--renew", "x", "--date", "2027-01-31"]))
        self.assertTrue(ok("expiry", ["add", "token"]))      # the plan answers "needs date"
        bad = [
            ["add", "token", "--date", "tomorrow"],
            ["add", "token", "--date", "2028-9-1"],
            ["add", "token", "--date", "2028-09-01", "--date", "2028-09-02"],
            ["add", "token", "--date", "2028-09-01", "--note", "x"],
            ["add", "token", "--date", "2028-09-01", "--renew", "a\tb"],
            ["add", "token", "--date", "2028-09-01", "--renew", "a\nb"],
            ["add", "token", "--date", "2028-09-01", "--renew", "x" * 121],
            ["add", "#x", "--date", "2028-09-01"],
            ["add", "../x", "--date", "2028-09-01"],
            ["add", "a" * 70, "--date", "2028-09-01"],
            ["add", "tok;en", "--date", "2028-09-01"],
            ["add"],
        ]
        for b in bad:
            self.assertFalse(ok("expiry", b), b)

    def test_expiry_remove(self):
        self.assertTrue(ok("expiry", ["remove", "DC certificate"]))
        for bad in (["remove"], ["remove", "x", "y"], ["remove", "$(x)"], ["remove", " x"], ["delete", "x"]):
            self.assertFalse(ok("expiry", bad), bad)

    def test_health(self):
        for good in (["ack", "backup:stale"], ["ack", "zfs:tank:scrub-old"], ["unack", "expiry:DC certificate (old):soon"], ["resume"]):
            self.assertTrue(ok("health", good), good)
        for bad in (["ack"], ["ack", "x;y"], ["ack", "$(x)"], ["ack", ":x"], ["ack", "a\tb"], ["ack", "a", "b"], ["resume", "x"],
                    ["unack"], ["frob", "x"], ["ack", "x" * 102]):
            self.assertFalse(ok("health", bad), bad)

    def test_service_add(self):
        self.assertTrue(ok("routes", ["add", "wiki", "--port", "3000", "--container", "wiki"]))
        self.assertTrue(ok("routes", ["add", "wiki", "--port", "80", "--host", "10.0.0.5", "--title", "Wiki", "--names", "wiki,notes",
                                      "--exposure", "public-ok", "--public-path", "/hook", "--public-path", "/api", "--want", "reverse-proxy,dashboard"]))
        bad = [
            ["add", "Wiki", "--port", "80", "--host", "x"],
            ["add", "wiki", "--port", "80x", "--host", "x"],
            ["add", "wiki", "--port", "80", "--host", "x;y"],
            ["add", "wiki", "--port", "80", "--host", "x", "--exposure", "open"],
            ["add", "wiki", "--port", "80", "--host", "x", "--port", "81"],
            ["add", "wiki", "--port", "80", "--host", "x", "--public-path", "/a/../b;"],
            ["add", "wiki", "--port", "80", "--host", "x", "--title", "a\nb"],
            ["add", "wiki", "--port", "80", "--host", "x", "--icon"],
            ["add", "wiki", "--port", "80", "--host", "x", "--scheme", "ftp"],
            ["add"],
        ]
        for b in bad:
            self.assertFalse(ok("routes", b), b)
        self.assertFalse(ok("routes", ["add", "wiki", "--port", "80", "--host", "x"], stdin="x"))     # nothing here takes a password

    def test_offer(self):
        self.assertTrue(ok("peers", ["offer", "cousin", "media"]))
        self.assertTrue(ok("peers", ["offer", "cousin", "media", "--new-password"]))
        for b in (["offer", "Cousin", "media"], ["offer", "cousin"], ["offer", "cousin", "media", "--yes"], ["offer", "cousin", "me dia"],
                  ["offer", "cousin", "media", "--new-password", "--new-password"]):
            self.assertFalse(ok("peers", b), b)
        self.assertFalse(ok("peers", ["offer", "cousin", "media"], stdin="x"))      # the password is made on the server, never sent

    def test_secret_lines(self):
        d = ws.parse_change("status\tdone\nsecret\tlogin\tremote-bob\nsecret\tdomain\tHOME\nsecret\thost\tme.local\nsecret\tpassword\tPw-Aa1\nsecret\tother\tx\n", 0)
        self.assertEqual(d["secret"], {"login": "remote-bob", "domain": "HOME", "host": "me.local", "password": "Pw-Aa1"})
        self.assertNotIn("secret", ws.parse_change("status\tdone\n", 0))

    def test_plan_shapes(self):
        d = ws.parse_change("status\tok\nheading\treboot the server\nstep\ta\nwarn\tLOCKED\ndanger\tgoes down\ncommand\tbash power.sh reboot --yes\n"
                            "confirm_name\treboot\nlong\tno\n", 0)
        self.assertEqual(d["status"], "ok")
        self.assertEqual(d["confirm_name"], "reboot")
        self.assertFalse(d["long"])
        self.assertEqual([s[0] for s in d["steps"]], ["step", "warn", "danger"])
        d = ws.parse_change("status\trefused\nreason\tNot now\nreason\tbackup is running\n", 1)
        self.assertEqual(d["status"], "refused")
        d = ws.parse_change("status\tneeds\nneeds\tdate\n", 2)
        self.assertEqual(d["needs"], ["date"])
        d = ws.parse_change("status\tdone\n", 0)
        self.assertEqual(d["status"], "done")
        d = ws.parse_change("status\tstarted\nunit\ths-job-system-reboot-031500\n", 0)
        self.assertRegex(d["unit"], ws.UNIT)


if __name__ == "__main__":
    unittest.main()
