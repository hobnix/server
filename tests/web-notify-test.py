#!/usr/bin/env python3
"""scripts/web-serve.py for the Notifications page: the READS and the CHANGES allowlist (notify add|set|remove|test|migrate)."""
import importlib.util
import os
import unittest

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("web_serve", os.path.join(here, "..", "scripts", "web-serve.py"))
ws = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ws)


def ok(area, args, confirm=None, stdin=None):
    return ws.validate_change({"area": area, "args": args, "confirm": confirm, "stdin": stdin}) is not None


class Notify(unittest.TestCase):
    def test_reads(self):
        self.assertIn(("notify", "channels"), ws.READS)
        self.assertIn(("notify", "providers"), ws.READS)

    def test_add(self):
        self.assertTrue(ok("notify", ["add", "phone", "--provider", "ntfy", "--secret", "url"], stdin="https://ntfy.sh/topic"))
        self.assertTrue(ok("notify", ["add", "phone", "--provider", "ntfy", "--secret", "url", "--min-priority", "high", "--quiet", "ignore",
                                      "--categories", "alarm,status,digest"], stdin="https://ntfy.sh/topic"))
        self.assertTrue(ok("notify", ["add", "mail", "--provider", "email", "--set", "host=smtp.example.org", "--set", "from=a@example.org",
                                      "--set", "to=b@example.org", "--secret", "password"], stdin="pw"))
        self.assertTrue(ok("notify", ["add", "phone", "--provider", "ntfy"]))           # the plan answers "needs"
        for bad in (["add", "Phone", "--provider", "ntfy"], ["add", "phone", "--provider", "ntfy", "--min-priority", "loud"],
                    ["add", "phone", "--provider", "ntfy", "--categories", "alarm,sound"], ["add", "phone", "--provider", "ntfy", "--quiet", "no"],
                    ["add", "phone", "--provider", "ntfy", "--set", "url"], ["add", "phone", "--provider", "ntfy", "--set", "Url=x"],
                    ["add", "phone", "--provider", "ntfy", "--exec", "x"], ["add", "-x", "--provider", "ntfy"], ["add"],
                    ["add", "phone", "--provider", "ntfy", "--secret", "url", "--secret", "url"]):
            self.assertFalse(ok("notify", bad), bad)

    def test_set(self):
        self.assertTrue(ok("notify", ["set", "phone", "--enabled", "no"]))
        self.assertTrue(ok("notify", ["set", "phone", "--categories", "alarm"]))
        self.assertTrue(ok("notify", ["set", "phone", "--categories", "alarm,heartbeat", "--min-priority", "min"]))
        self.assertTrue(ok("notify", ["set", "phone", "--secret", "url"], stdin="https://ntfy.sh/new"))
        self.assertFalse(ok("notify", ["set", "phone", "--provider", "email"]))      # the provider of a channel never changes
        self.assertFalse(ok("notify", ["set", "phone", "--enabled", "maybe"]))

    def test_secret_only_where_it_belongs(self):
        self.assertFalse(ok("notify", ["remove", "phone"], stdin="x"))
        self.assertFalse(ok("notify", ["test", "phone"], stdin="x"))
        self.assertFalse(ok("notify", ["migrate"], stdin="x"))
        self.assertFalse(ok("notify", ["set", "phone", "--enabled", "no"], stdin="x\ny"))      # one line only
        self.assertFalse(ok("notify", ["add", "phone", "--provider", "ntfy"], stdin=""))

    def test_remove_test_migrate(self):
        self.assertTrue(ok("notify", ["remove", "phone"]))
        self.assertTrue(ok("notify", ["remove", "phone"], confirm="phone"))
        self.assertTrue(ok("notify", ["test", "phone"]))
        self.assertTrue(ok("notify", ["migrate"]))
        for bad in (["remove"], ["remove", "../x"], ["test", "a b"], ["migrate", "x"], ["remove", "phone", "--yes"], ["delete", "phone"]):
            self.assertFalse(ok("notify", bad), bad)


if __name__ == "__main__":
    unittest.main()
