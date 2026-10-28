#!/usr/bin/env python3
"""scripts/web-serve.py: the CHANGES entry for the proxyserver buttons. Only `update` and `watch`, nothing else, never stdin or arguments;
and the key never appears in a read or the session answer (only whether the buttons are on)."""
import importlib.util
import os
import re
import unittest

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("web_serve", os.path.join(here, "..", "scripts", "web-serve.py"))
ws = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ws)


def ok(args, confirm=None, stdin=None, area="vps"):
    return ws.validate_change({"area": area, "args": args, "confirm": confirm, "stdin": stdin}) is not None


class Vps(unittest.TestCase):
    def test_the_two_verbs(self):
        self.assertTrue(ok(["update"]))
        self.assertTrue(ok(["watch"]))

    def test_everything_else_is_refused(self):
        bad = [
            [], ["status"], ["notify-test"], ["help"], ["shell"], ["bash"], ["UPDATE"], ["Update"], [" update"], ["update "],
            ["update;id"], ["update && id"], ["update\nid"], ["update\n"], ["$(id)"], ["`id`"], ["update", "--force"], ["update", "extra"],
            ["watch", "-o", "ProxyCommand=id"], ["-o", "ProxyCommand=id"], ["--", "update"], ["update", "watch"], ["", "update"], ["root@evil", "update"],
            ["key"], ["host", "evil"], ["../update"],
        ]
        for b in bad:
            self.assertFalse(ok(b), b)

    def test_no_stdin_no_confirm_word_for_update_or_watch(self):
        self.assertFalse(ok(["update"], stdin="secret"))
        self.assertFalse(ok(["watch"], stdin="x"))
        self.assertFalse(ok(["update"], confirm="a\nb"))

    def test_the_host_is_not_a_parameter(self):
        # nothing in the entry takes a host, a key or an option: the pattern list is exactly one fixed word
        entry = ws.CHANGES["vps"]
        self.assertEqual(len(entry), 1)
        self.assertEqual(len(entry[0]), 1)
        self.assertEqual(entry[0][0], r"^(update|watch)$")

    def test_no_read_for_the_key(self):
        for words in ws.READS:
            self.assertNotIn("vps", words)

    def test_registry_rows(self):
        reg = os.path.join(here, "..", "scripts", "lib", "registry.tsv")
        rows = {}
        with open(reg, encoding="utf-8") as f:
            for line in f:
                c = line.rstrip("\n").split("\t")
                if c[0] in ("sys", "user"):
                    rows[c[1]] = c
        for name, script, fixed in (("sys vps plan <action>", "vps-change.sh", "plan {1} {rest}"), ("sys vps start <action>", "vps-change.sh", "start {1} {rest}")):
            self.assertIn(name, rows)
            self.assertEqual(rows[name][2:4], [script, fixed], name)
        self.assertEqual(rows["vps key"][2], "vps.sh")

    def test_the_server_never_reads_the_key_file(self):
        src = open(os.path.join(here, "..", "scripts", "web-serve.py"), encoding="utf-8").read()
        self.assertIsNone(re.search(r"vps-key", src), "web-serve.py must not know the key file")


if __name__ == "__main__":
    unittest.main()
