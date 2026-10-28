#!/usr/bin/env python3
"""scripts/web-serve.py: the CHANGES entry "node" (add, remove, key) and the read node/keyline. A remote node gets no word from here: the entry only names
the list on THIS server; the key line is read, never the key."""
import importlib.util
import os
import re
import unittest

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("web_serve", os.path.join(here, "..", "scripts", "web-serve.py"))
ws = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ws)


def ok(args, confirm=None, stdin=None, area="node"):
    return ws.validate_change({"area": area, "args": args, "confirm": confirm, "stdin": stdin}) is not None


class Node(unittest.TestCase):
    def test_what_passes(self):
        for good in (["add", "cousin", "cousin.tail.ts.net"], ["add", "cousin", "10.0.0.9", "--kind", "peer"], ["add", "edge1", "edge1.example.org", "--kind", "edge", "--port", "2222"],
                     ["remove", "cousin"], ["key", "cousin"], ["key", "cousin", "--new"]):
            self.assertTrue(ok(good), good)

    def test_everything_else_is_refused(self):
        bad = [
            [], ["add"], ["add", "cousin"], ["add", "Cousin", "host.example"], ["add", "a b", "host.example"], ["add", "-x", "host.example"],
            ["add", "cousin", "-oProxyCommand=id"], ["add", "cousin", "a b"], ["add", "cousin", "host;id"], ["add", "cousin", "host", "--kind", "shell"],
            ["add", "cousin", "host", "--kind"], ["add", "cousin", "host", "--port", "x"], ["add", "cousin", "host", "--bogus", "1"],
            ["add", "cousin", "host", "--kind", "peer", "--kind", "vps"],
            ["remove"], ["remove", "../x"], ["remove", "x", "--yes"], ["remove", "a", "b"], ["key"], ["key", "x", "--yes"], ["key", "x", "--new", "--new"],
            ["status", "cousin"], ["show", "cousin"], ["update", "cousin"], ["run", "cousin", "id"], ["exec", "cousin"], ["key", "cousin;id"], ["key", "cousin\nid"],
        ]
        for b in bad:
            self.assertFalse(ok(b), b)

    def test_no_stdin(self):
        self.assertFalse(ok(["key", "cousin"], stdin="secret"))
        self.assertFalse(ok(["add", "cousin", "host"], stdin="secret"))

    def test_the_vps_buttons_stay(self):
        self.assertTrue(ok(["update"], area="vps"))
        self.assertTrue(ok(["watch"], area="vps"))
        self.assertEqual(ws.CHANGES["vps"], [[r"^(update|watch)$"]])

    def test_the_read(self):
        spec = ws.READS[("node", "keyline")]
        self.assertEqual(spec["kind"], "tsv")
        self.assertEqual(len(spec["args"]), 1)

    def test_registry_rows(self):
        reg = os.path.join(here, "..", "scripts", "lib", "registry.tsv")
        rows = {}
        with open(reg, encoding="utf-8") as f:
            for line in f:
                c = line.rstrip("\n").split("\t")
                if c[0] in ("sys", "user"):
                    rows[c[1]] = c
        for name, script, fixed in (("sys node plan <action>", "node-change.sh", "plan {1} {rest}"), ("sys node start <action>", "node-change.sh", "start {1} {rest}"),
                                    ("sys node keyline <name>", "node.sh", "--keyline {1}")):
            self.assertIn(name, rows)
            self.assertEqual(rows[name][2:4], [script, fixed], name)

    def test_the_server_never_names_a_key_file(self):
        src = open(os.path.join(here, "..", "scripts", "web-serve.py"), encoding="utf-8").read()
        self.assertIsNone(re.search(r"node-key-", src), "web-serve.py must not know the key files")


if __name__ == "__main__":
    unittest.main()
