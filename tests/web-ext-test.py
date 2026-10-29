#!/usr/bin/env python3
"""scripts/web-serve.py: the reads and changes an extension package declares in its capability.toml ([[web.reads]], [[web.changes]]) are
allowlisted only while the package is on, only when they are rows of the package's own commands.tsv, and never outside its namespace."""
import importlib.util
import os
import re
import shutil
import tempfile
import unittest

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("web_serve", os.path.join(here, "..", "scripts", "web-serve.py"))
ws = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ws)
os.environ["HS_WEB_QUIET"] = "1"
TAB = "\t"


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)


def package(root, name, rows, web):
    write(os.path.join(root, name, "capability.toml"),
          'name = "%s"\ntitle = "t"\ntitle_de = "t"\nkind = "feature"\nrequires = []\nprovides = []\nneeds = []\nextension = true\n%s' % (name, web))
    write(os.path.join(root, name, "commands.tsv"), "".join(TAB.join(r) + "\n" for r in rows))


class ExtPages(unittest.TestCase):
    """[web.page]: a declaration may name only reads of the package and plans of its own area"""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.pk = os.path.join(self.tmp, "packages")
        os.environ["HS_PACKAGES_DIR"] = self.pk
        os.environ["HS_CAPABILITIES_FILE"] = os.path.join(self.tmp, "caps")
        os.environ["HS_STATE_DIR"] = os.path.join(self.tmp, "state")
        write(os.path.join(self.tmp, "caps"), "demo\n")

    def tearDown(self):
        os.environ.pop("HS_PACKAGES_DIR", None)
        write(os.path.join(self.tmp, "caps"), "")
        ws.ext_refresh(force=True)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def pages(self, page):
        package(self.pk, "demo", [["sys", "sys ext demo list", "x.sh", "list", "h", "-"]],
                '[[web.reads]]\nwords = "list"\nkind = "tsv"\nttl = 10\n' + page)
        ws.ext_refresh(force=True)
        return ws.ext_pages()

    def test_a_good_page(self):
        got = self.pages('[web.page]\ntitle = "Demo"\n[[web.page.blocks]]\ntype = "table"\nread = "list"\ncolumns = []\n')
        self.assertEqual(got[0]["name"], "demo")
        self.assertIn(("ext", "demo", "list"), ws.READS)       # the reads still work next to the page

    def test_a_page_that_reads_something_undeclared_drops_the_package(self):
        got = self.pages('[web.page]\ntitle = "Demo"\n[[web.page.blocks]]\ntype = "table"\nread = "secret"\n')
        self.assertEqual(got, [])
        self.assertNotIn(("ext", "demo", "list"), ws.READS)

    def test_a_page_may_not_plan_in_another_area(self):
        got = self.pages('[web.page]\ntitle = "Demo"\n[[web.page.actions]]\nlabel = "x"\nplan = ["ct", "a", "stop"]\n')
        self.assertEqual(got, [])

    def test_an_unknown_block_type_is_refused(self):
        self.assertEqual(self.pages('[web.page]\ntitle = "Demo"\n[[web.page.blocks]]\ntype = "script"\n'), [])


class ExtWeb(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.pk = os.path.join(self.tmp, "packages")
        self.caps = os.path.join(self.tmp, "caps")
        os.environ["HS_PACKAGES_DIR"] = self.pk
        os.environ["HS_CAPABILITIES_FILE"] = self.caps
        os.environ["HS_STATE_DIR"] = os.path.join(self.tmp, "state")
        write(self.caps, "")
        package(self.pk, "demo", [
            ["sys", "sys ext demo list", "x.sh", "list", "h", "-"],
            ["sys", "sys ext demo thing <id>", "x.sh", "thing {1}", "h", "-"],
            ["sys", "sys ext demo plan <action>", "x.sh", "plan {1}", "h", "-"],
            ["sys", "sys ext demo start <action>", "x.sh", "start {1}", "h", "-"],
        ], '''
[[web.reads]]
words = "list"
kind = "tsv"
ttl = 10

[[web.reads]]
words = "thing"
kind = "json"
ttl = 5
args = ['^[a-z]{1,8}$']

[[web.changes]]
patterns = ['^go$', '^[a-z]{1,8}$']

[[web.changes]]
fixed = ['^make$']
opts = [ { flag = "--size", pattern = '^[0-9]{1,3}$' } ]
''')

    def tearDown(self):
        for k in list(ws.READS):
            if k[0] == "ext":
                del ws.READS[k]
        for k in list(ws.CHANGES):
            if k.startswith("ext/"):
                del ws.CHANGES[k]
        shutil.rmtree(self.tmp, ignore_errors=True)

    def refresh(self, on):
        write(self.caps, "".join(n + "\n" for n in on))
        ws.ext_refresh(force=True)

    def ok(self, area, args):
        return ws.validate_change({"area": area, "args": args}) is not None

    def test_off_means_nothing_is_allowed(self):
        self.refresh([])
        self.assertNotIn(("ext", "demo", "list"), ws.READS)
        self.assertNotIn("ext/demo", ws.CHANGES)
        self.assertFalse(self.ok("ext/demo", ["go", "now"]))

    def test_on_registers_the_declared_reads_and_changes(self):
        self.refresh(["demo"])
        self.assertEqual(ws.READS[("ext", "demo", "list")], {"kind": "tsv", "ttl": 10})
        self.assertEqual(ws.READS[("ext", "demo", "thing")]["args"], ["^[a-z]{1,8}$"])
        self.assertTrue(self.ok("ext/demo", ["go", "now"]))
        self.assertTrue(self.ok("ext/demo", ["make", "--size", "12"]))
        for bad in (["go"], ["go", "NOW"], ["make", "--size", "1234"], ["make", "--size"], ["make", "--other", "1"], ["stop", "now"], []):
            self.assertFalse(self.ok("ext/demo", bad), bad)

    def test_switching_off_removes_them_again(self):
        self.refresh(["demo"])
        self.refresh([])
        self.assertNotIn(("ext", "demo", "list"), ws.READS)
        self.assertFalse(self.ok("ext/demo", ["go", "now"]))

    def test_the_overlay_of_hs_ext_enable_counts(self):
        write(os.path.join(self.tmp, "state", "capabilities-on"), "demo\n")
        ws.ext_refresh(force=True)
        self.assertIn(("ext", "demo", "list"), ws.READS)
        write(os.path.join(self.tmp, "state", "capabilities-off"), "demo\n")
        ws.ext_refresh(force=True)
        self.assertNotIn(("ext", "demo", "list"), ws.READS)

    def test_a_read_must_be_a_row_of_the_package(self):
        package(self.pk, "demo", [["sys", "sys ext demo list", "x.sh", "list", "h", "-"]], '''
[[web.reads]]
words = "list"
kind = "tsv"
ttl = 10
[[web.reads]]
words = "secret"
kind = "tsv"
ttl = 10
''')
        self.refresh(["demo"])
        self.assertNotIn(("ext", "demo", "list"), ws.READS)     # the whole declaration is ignored, not half of it

    def test_changes_need_the_plan_and_start_rows(self):
        package(self.pk, "demo", [["sys", "sys ext demo list", "x.sh", "list", "h", "-"]], '''
[[web.changes]]
patterns = ['^go$']
''')
        self.refresh(["demo"])
        self.assertNotIn("ext/demo", ws.CHANGES)

    def test_no_read_may_change_something(self):
        package(self.pk, "demo", [["sys", "sys ext demo start", "x.sh", "start", "h", "-"]], '''
[[web.reads]]
words = "start"
kind = "tsv"
ttl = 1
''')
        self.refresh(["demo"])
        self.assertNotIn(("ext", "demo", "start"), ws.READS)

    def test_a_bad_pattern_or_value_ignores_the_package(self):
        for web in ('[[web.reads]]\nwords = "list"\nkind = "tsv"\nttl = 99999\n',
                    '[[web.reads]]\nwords = "list"\nkind = "xml"\nttl = 5\n',
                    '[[web.reads]]\nwords = "list"\nkind = "tsv"\nttl = 5\nargs = ["("]\n',
                    '[[web.reads]]\nwords = "list"\nkind = "tsv"\n'):
            package(self.pk, "demo", [["sys", "sys ext demo list", "x.sh", "list", "h", "-"]], web)
            self.refresh(["demo"])
            self.assertNotIn(("ext", "demo", "list"), ws.READS, web)

    def test_a_package_cannot_declare_a_core_read(self):
        # the reads are always put under ext/<name>: there is no way to name ("ct", "list") or another package's words
        package(self.pk, "demo", [["sys", "sys ct list", "x.sh", "list", "h", "-"]], '[[web.reads]]\nwords = "../ct list"\nkind = "tsv"\nttl = 5\n')
        self.refresh(["demo"])
        self.assertFalse(any(k[:2] == ("ext", "demo") for k in ws.READS))
        self.assertIn(("ct", "list"), ws.READS)

    def test_a_folder_name_that_is_no_package_name_is_skipped(self):
        package(self.pk, "Bad_Name", [["sys", "sys ext Bad_Name list", "x.sh", "list", "h", "-"]], '[[web.reads]]\nwords = "list"\nkind = "tsv"\nttl = 5\n')
        self.refresh(["Bad_Name"])
        self.assertFalse(any(k[:2] == ("ext", "Bad_Name") for k in ws.READS))

    def test_the_sys_words_of_a_change_are_the_area(self):
        # validate_change keeps the area "ext/demo"; the call is `hs sys ext demo plan|start ...` (area.split("/"))
        self.refresh(["demo"])
        got = ws.validate_change({"area": "ext/demo", "args": ["go", "now"]})
        self.assertEqual(got[0].split("/"), ["ext", "demo"])
        self.assertIsNone(ws.validate_change({"area": "ext", "args": ["go", "now"]}))
        self.assertIsNone(ws.validate_change({"area": "ext/other", "args": ["go", "now"]}))


class RealPackages(unittest.TestCase):
    """capabilities/games and capabilities/posters, as the web interface sees them while they are on"""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        os.environ.pop("HS_PACKAGES_DIR", None)
        self.caps = os.path.join(self.tmp, "caps")
        os.environ["HS_CAPABILITIES_FILE"] = self.caps
        os.environ["HS_STATE_DIR"] = os.path.join(self.tmp, "state")
        write(self.caps, "games\nposters\ngateway\npassthrough\n")
        ws.ext_refresh(force=True)

    def tearDown(self):
        write(self.caps, "")
        ws.ext_refresh(force=True)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def ok(self, area, args, stdin=None):
        return ws.validate_change({"area": area, "args": args, "stdin": stdin}) is not None

    def test_games(self):
        for words, ttl in ((("ext", "games", "list"), 30), (("ext", "games", "state"), 15)):
            self.assertEqual(ws.READS[words], {"kind": "tsv", "ttl": ttl})
        self.assertTrue(self.ok("ext/games", ["gaming-pc", "wake"]))
        self.assertTrue(self.ok("ext/games", ["gaming", "remove"]))
        self.assertTrue(self.ok("ext/games", ["gaming", "add", "--ip", "10.10.10.50", "--mac", "aa:bb:cc:dd:ee:ff"]))
        for bad in (["gaming", "sleep"], ["-x", "wake"], ["gaming", "add", "--mac", "nonsense"], ["gaming", "add", "--ip", "10.10.10.500"]):
            self.assertFalse(self.ok("ext/games", bad), bad)

    def test_passthrough(self):
        for words, ttl in ((("ext", "passthrough", "list"), 30), (("ext", "passthrough", "state"), 15), (("ext", "passthrough", "status"), 30)):
            self.assertEqual(ws.READS[words], {"kind": "tsv", "ttl": ttl})
        a = "ext/passthrough"
        self.assertTrue(self.ok(a, ["example.com", "add", "--address", "192.168.1.20", "--proxy-protocol"]))
        self.assertTrue(self.ok(a, ["example.com", "add", "--address", "fd00::5", "--https-port", "8443", "--no-http"]))
        self.assertTrue(self.ok(a, ["example.com", "remove"]))
        # a container target: the switch sends --container-ok, the typed domain travels as `confirm` (appended as --confirm at start)
        self.assertTrue(self.ok(a, ["example.com", "add", "--address", "10.10.95.5", "--container-ok"]))
        got = ws.validate_change({"area": a, "args": ["example.com", "add", "--address", "10.10.95.5", "--container-ok"], "confirm": "example.com"})
        self.assertIsNotNone(got)
        self.assertEqual(got[2], "example.com")
        self.assertFalse(self.ok(a, ["example.com", "add", "--address", "10.10.95.5", "--container-ok", "yes"]))
        for bad in (["Example.com", "add"], ["a b", "remove"], ["example.com", "add", "--address", "1.2.3.4;x"],
                    ["example.com", "add", "--https-port", "x"], ["example.com", "wipe"]):
            self.assertFalse(self.ok(a, bad), bad)

    def test_posters(self):
        self.assertEqual(ws.READS[("ext", "posters", "list")], {"kind": "tsv", "ttl": 5})
        self.assertTrue(self.ok("ext/posters", ["generate", "--eyebrow", "a", "--title", "b", "--color", "#12ab9f", "--seed", "42", "--case", "keep"]))
        self.assertTrue(self.ok("ext/posters", ["delete", "poster-dune-42.png"]))
        for bad in (["generate", "--out", "/etc"], ["delete", "../x.png"], ["generate", "--eyebrow", "a\nb", "--title", "b"]):
            self.assertFalse(self.ok("ext/posters", bad), bad)

    def test_the_old_static_areas_are_gone(self):
        self.assertFalse(self.ok("pc", ["gaming", "wake"]))
        self.assertFalse(self.ok("poster", ["delete", "poster-dune-42.png"]))
        self.assertNotIn(("pc", "list"), ws.READS)
        self.assertNotIn(("poster", "list"), ws.READS)

    def test_the_pages_are_declared_by_the_packages_that_are_on(self):
        pages = {p["name"]: p for p in ws.ext_pages()}
        self.assertEqual(sorted(pages), ["games", "passthrough", "posters"])
        self.assertEqual(pages["games"]["title"], "Game streaming")
        self.assertEqual(pages["games"]["blocks"][0]["read"], "list")
        self.assertEqual(pages["posters"]["blocks"][0]["type"], "gallery")
        self.assertEqual(ws.features(ws.Config())["extensions"], ws.ext_pages())
        write(self.caps, "games\n")
        ws.ext_refresh(force=True)
        self.assertEqual([p["name"] for p in ws.ext_pages()], ["games"])

    def test_every_plan_a_page_declares_is_allowed_by_the_changes(self):
        # the plans of the actions, with a sample value in every {placeholder}, must pass validate_change
        sample = {"name": "gaming-pc", "file": "poster-dune-42.png", "domain": "example.com"}
        for p in ws.ext_pages():
            for b in p["blocks"]:
                for a in b.get("rowActions", []) + p.get("actions", []):
                    if "plan" in a:
                        args = [re.sub(r"\{(\w+)\}", lambda m: sample[m.group(1)], x) for x in a["plan"][1:]]
                        self.assertTrue(self.ok(a["plan"][0], args), a)

    def test_a_passthrough_domain_can_be_edited(self):
        # the Edit row action opens the same form as Add with the row; saving is `add` on a forwarded domain, which the changes already allow
        page = {p["name"]: p for p in ws.ext_pages()}["passthrough"]
        table = next(b for b in page["blocks"] if b.get("type") == "table")
        edit = next(a for a in table["rowActions"] if a.get("edit"))
        self.assertEqual(edit["form"], next(a for a in page["actions"] if a.get("primary"))["form"])
        cols = {c["key"] for c in table["columns"]}
        self.assertTrue({"domain", "address", "https", "http", "proxy"} <= cols)   # the form reads these keys of the row

    def test_off_the_pages_have_nothing(self):
        write(self.caps, "")
        ws.ext_refresh(force=True)
        self.assertEqual(ws.ext_pages(), [])
        self.assertFalse(any(k[0] == "ext" for k in ws.READS))
        self.assertFalse(any(k.startswith("ext/") for k in ws.CHANGES))


MANIFEST = """name = "app"
version = "1.0.0"
kind = "recipe"
title = "t"
[[web.reads]]
words = "status"
kind = "tsv"
ttl = 15
[web.page]
title = "App"
[[web.page.blocks]]
type = "table"
read = "status"
key = "x"
columns = [ { key = "x", label = "X" } ]
"""


class RecipePackage(unittest.TestCase):
    """a recipe package (packages/<name>/package.toml + commands.tsv) registers its reads and page only once the recipe has been applied"""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.pk = os.path.join(self.tmp, "packages")
        os.environ["HS_PACKAGES_DIR"] = self.pk
        os.environ["HS_CAPABILITIES_FILE"] = os.path.join(self.tmp, "caps")
        os.environ["HS_STATE_DIR"] = os.path.join(self.tmp, "state")
        write(os.path.join(self.tmp, "caps"), "")
        write(os.path.join(self.pk, "app", "package.toml"), MANIFEST)
        write(os.path.join(self.pk, "app", "commands.tsv"), TAB.join(["sys", "sys ext app status", "@/s.sh", "--list", "h", "-"]) + "\n")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_off_until_applied(self):
        reads, _, pages = ws.ext_load_web()
        self.assertEqual((reads, pages), ({}, []))
        write(os.path.join(self.tmp, "state", "packages", "installed.toml"), '[package.app]\nversion = "1.0.0"'+"\n")
        reads, _, pages = ws.ext_load_web()
        self.assertIn(("ext", "app", "status"), reads)
        self.assertEqual([p["name"] for p in pages], ["app"])


if __name__ == "__main__":
    unittest.main()
