#!/usr/bin/env python3
"""scripts/web-serve.py for the file manager (fm.sh): the READS answers, the CHANGES allowlist, and the selection that travels on stdin as NUL separated bytes."""
import importlib.util
import os
import unittest

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("web_serve", os.path.join(here, "..", "scripts", "web-serve.py"))
ws = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ws)

COPY = ["copy", "--from", "disk:data-04", "--path", "shares/media/movies", "--to", "disk:data-05", "--to-path", "shares/media"]


def change(args, selection=None, confirm=None, stdin=None):
    body = {"area": "fm", "args": args, "confirm": confirm}
    if selection is not None:
        body["selection"] = selection
    if stdin is not None:
        body["stdin"] = stdin
    return ws.validate_change(body)


class Reads(unittest.TestCase):
    def test_reads(self):
        r = ws.Reads.__new__(ws.Reads)
        spec, argv, _ = ws.Reads.resolve(r, ["fm", "locations"], {})
        self.assertEqual(argv, ["fm", "locations"])
        spec, argv, _ = ws.Reads.resolve(r, ["fm", "ls", "disk:data-04"], {"path": ["shares/media"], "cursor": ["500"], "limit": ["100"]})
        self.assertEqual(argv, ["fm", "ls", "disk:data-04", "--cursor", "500", "--limit", "100", "--path", "shares/media"])
        spec, argv, _ = ws.Reads.resolve(r, ["fm", "ls", "disk:data-04"], {"path": ["/shares/media"]})
        self.assertEqual(argv, ["fm", "ls", "disk:data-04", "--path", "/shares/media"], "the page sends a path with a leading slash")
        self.assertIsNotNone(change(["copy", "--from", "disk:data-04", "--path", "/shares/media", "--to", "disk:data-05", "--to-path", "/shares/media"], ["a"]), "a leading slash in a change")
        self.assertIsNotNone(ws.Reads.resolve(r, ["fm", "pair", "disk:data-04", "pool:bulk"], {}))
        self.assertIsNotNone(ws.Reads.resolve(r, ["fm", "progress", "hs-job-fm-copy-101010"], {}))
        for bad in (["fm", "ls", "/etc"], ["fm", "ls", "disk:../x"], ["fm", "pair", "disk:data-04"], ["fm", "progress", "sshd"], ["fm", "plan"], ["fm", "start"]):
            self.assertIsNone(ws.Reads.resolve(r, bad, {}), bad)
        self.assertIsNone(ws.Reads.resolve(r, ["fm", "ls", "pool:bulk"], {"cursor": ["x"]}))
        self.assertIsNone(ws.Reads.resolve(r, ["fm", "ls", "pool:bulk"], {"path": ["a\nb"]}))


class Changes(unittest.TestCase):
    def test_shapes(self):
        self.assertIsNotNone(change(COPY, ["Avatar", "Heat"]))
        for op in ("move", "delete", "rename", "mkdir"):
            self.assertIsNotNone(change([op, "--from", "disk:data-04", "--path", "shares/media"] + (["--newname", "x"] if op in ("rename", "mkdir") else []), ["a"] if op != "mkdir" else []))
        self.assertIsNotNone(change(COPY + ["--conflict", "rename", "--verify", "checksum", "--parity-after", "--conflicts"], ["a"]))
        self.assertIsNotNone(change(["delete", "--from", "share:media", "--path", ""], ["a"], confirm="delete 1 file"))

    def test_refused(self):
        self.assertIsNone(change(["frobnicate", "--from", "disk:data-04"], ["a"]))
        self.assertIsNone(change(COPY + ["--conflict", "delete-all"], ["a"]))
        self.assertIsNone(change(["copy", "--from", "/etc", "--path", ""], ["a"]))
        self.assertIsNone(change(COPY + ["--by", "root"], ["a"]), "--by is added by the server, never by the client")
        self.assertIsNone(change(COPY + ["--sel-file", "/etc/shadow"], ["a"]), "--sel-file is internal")
        self.assertIsNone(change(COPY + ["--now"], ["a"]), "--now is internal")
        self.assertIsNone(change(COPY + ["--job-id", "x"], ["a"]))
        self.assertIsNone(change(COPY + ["--path", "x"], ["a"]), "an option twice")
        self.assertIsNone(change(COPY + ["--newname", "a/b"], ["a"]))
        self.assertIsNone(change(COPY, ["a"], confirm="rm -rf /"))

    def test_selection(self):
        got = change(COPY, ["Avatar", "Heat 2", "Zoë"])
        self.assertEqual(got[3], b"Avatar\0Heat 2\0Zo\xc3\xab\0")
        self.assertIsNone(change(COPY, ["a/b"]), "a slash in a name")
        self.assertIsNone(change(COPY, ["a\0b"]), "a NUL in a name")
        self.assertIsNone(change(COPY, [""]), "an empty name")
        self.assertIsNone(change(COPY, ["x" * 256]), "a name over 255")
        self.assertIsNone(change(COPY, "Avatar"), "a string instead of a list")
        self.assertIsNone(change(COPY, [1]), "a number in the list")
        self.assertIsNone(change(COPY, ["a"] * (ws.FM_SELECTION_MAX + 1)), "too many names")
        self.assertIsNone(change(COPY, ["a"], stdin="x"), "stdin and selection together")
        self.assertIsNone(ws.validate_change({"area": "ct", "args": ["web1", "start"], "selection": ["a"]}), "other areas take no selection")
        self.assertIsNone(change(COPY, None, stdin="line"), "a stdin line is refused for fm")

    def test_parse(self):
        d = ws.parse_change("status\tok\nheading\tcopy\nfiles\t3\nfolders\t2\nbytes\t301000\nfree_after\t500\nconflicts\t1\nparity\tyes\nconfirm_name\tdelete 3 files\nlong\tno\n"
                            "conflict\tAvatar/a.mkv\t10\t20\t100\t200\nunit\thu\n", 0)
        self.assertEqual((d["files"], d["folders"], d["bytes"], d["free_after"], d["conflicts"]), (3, 2, 301000, 500, 1))
        self.assertIs(d["parity"], True)
        self.assertEqual(d["confirm_name"], "delete 3 files")
        self.assertEqual(d["conflict_rows"], [["Avatar/a.mkv", "10", "20", "100", "200"]])
        self.assertEqual(d["unit"], "hu")


if __name__ == "__main__":
    unittest.main()
