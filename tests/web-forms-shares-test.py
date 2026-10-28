#!/usr/bin/env python3
"""scripts/web-serve.py: the `shares` entries of CHANGES that the share forms use (add, perm, rename, delete, purge, restore)."""
import importlib.util
import os
import unittest

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("web_serve", os.path.join(here, "..", "scripts", "web-serve.py"))
ws = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ws)

SID = "S-1-5-21-1111111111-2222222222-3333333333-1105"


def ok(args, area="shares"):
    return ws.validate_change({"area": area, "args": args}) is not None


class Shapes(unittest.TestCase):
    def test_add(self):
        self.assertTrue(ok(["media", "add", "--kind", "shares"]))
        self.assertTrue(ok(["media", "add", "--kind", "sensitive", "--ct", "jellyfin", "--path", "/media", "--as", "1000:1000"]))
        self.assertTrue(ok(["media", "add", "--path", "/srv/media", "--ct", "jellyfin", "--kind", "shares"]))   # any order
        self.assertTrue(ok(["media", "add"]))                       # the script answers `needs kind`

    def test_add_refused(self):
        for a in (["Media", "add", "--kind", "shares"], ["me dia", "add"], ["-x", "add"], ["../x", "add"],
                  ["media", "add", "--kind", "other"], ["media", "add", "--ct", "Jelly"], ["media", "add", "--ct", "a;b"],
                  ["media", "add", "--kind", "shares", "--kind", "sensitive"],
                  ["media", "add", "--path", "media"], ["media", "add", "--path", "/a/../b"], ["media", "add", "--path", "/.."],
                  ["media", "add", "--as", "1000"], ["media", "add", "--as", "a:b"], ["media", "add", "--confirm", "media"],
                  ["media", "add", "--kind"]):
            self.assertFalse(ok(a), a)

    def test_perm(self):
        self.assertTrue(ok(["media", "perm", "--set", SID + "=read"]))
        self.assertTrue(ok(["media", "perm", "--set", "S-1-1-0=none", "--set", SID + "=full"]))
        self.assertTrue(ok(["media", "perm"]))

    def test_perm_refused(self):
        for a in (["media", "perm", "--set", SID + "=admin"], ["media", "perm", "--set", "HOME\\anna=read"], ["media", "perm", "--set", SID],
                  ["media", "perm", "--set", "S-1-=read"], ["media", "perm", "--set", SID + "=read;x"], ["media", "perm", "--set", "x" + SID + "=read"],
                  ["media", "perm", "--set", SID + "=read\n"], ["media", "perm", "--to", "on"]):
            self.assertFalse(ok(a), a)

    def test_rename_delete_purge(self):
        self.assertTrue(ok(["media", "rename", "--to", "movies"]))
        self.assertTrue(ok(["media", "delete"]))
        self.assertTrue(ok(["media.deleted-20261012", "purge"]))
        for a in (["media", "rename"], ["media", "rename", "--to", "Movies"], ["media", "rename", "--to", "a/b"], ["media", "rename", "--to", ".."],
                  ["media", "delete", "--confirm", "x"], ["media", "purge"], ["media.deleted-2026", "purge"], ["media.deleted-20261012", "delete"],
                  ["../media.deleted-20261012", "purge"], ["media.deleted-20261012x", "purge"]):
            self.assertFalse(ok(a), a)

    def test_undelete_kept(self):
        self.assertTrue(ok(["media.deleted-20261012", "undelete"]))
        for a in (["media", "undelete"], ["media.deleted-2026", "undelete"], ["../media.deleted-20261012", "undelete"],
                  ["media.deleted-20261012", "undelete", "--confirm", "x"], ["media.deleted-20261012x", "undelete"], ["media.deleted-20261012", "restore"]):
            self.assertFalse(ok(a), a)

    def test_restore(self):
        self.assertTrue(ok(["media", "restore", "--snapshot", "latest"]))
        self.assertTrue(ok(["media", "restore", "--snapshot", "a1b2c3d4", "--path", "photos/2025 trip"]))
        self.assertTrue(ok(["media", "restore", "--snapshot", "latest", "--path", "/docs/a.txt"]))
        for a in (["media", "restore", "--snapshot", "-x"], ["media", "restore", "--snapshot", "a b"], ["media", "restore", "--snapshot", "latest", "--path", "../etc"],
                  ["media", "restore", "--snapshot", "latest", "--path", "a/../../b"], ["media", "restore", "--snapshot", "latest", "--path", "..\\x"],
                  ["media", "restore", "--snapshot", "latest", "--path", "-rf"], ["media", "restore", "--snapshot", "latest", "--path", "a;b"],
                  ["media", "restore", "--snapshot", "latest", "--path", "a$(x)"]):
            self.assertFalse(ok(a), a)

    def test_old_shapes_still_work(self):
        for a in (["media", "snapshot"], ["media", "backup", "--to", "on"], ["media", "cache", "--to", "off"], ["media", "rollback", "--snapshot", "snap1"]):
            self.assertTrue(ok(a), a)

    def test_other_areas_unchanged(self):
        self.assertFalse(ok(["media", "add"], area="ct"))
        self.assertFalse(ok(["media", "perm", "--set", SID + "=read"], area="users"))

    def test_no_stdin(self):
        self.assertIsNone(ws.validate_change({"area": "shares", "args": ["media", "add", "--kind", "shares"], "stdin": "x"}))

    def test_confirm_word_for_delete(self):
        self.assertIsNotNone(ws.validate_change({"area": "shares", "args": ["media", "delete"], "confirm": "media"}))
        self.assertIsNone(ws.validate_change({"area": "shares", "args": ["media", "delete"], "confirm": "me;dia"}))


if __name__ == "__main__":
    unittest.main(verbosity=1)
