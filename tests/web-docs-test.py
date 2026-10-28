#!/usr/bin/env python3
"""scripts/web-serve.py: /api/docs/* (the guides of the Docs page): session, capability, index, page, search, name checks. A fake docs folder."""
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

INDEX = {
    "built": "2026-10-23", "rev": "abc",
    "langs": {
        "de": {"label": "Deutsch", "start": "start", "groups": [
            {"name": "Einstieg", "pages": [{"slug": "quickstart", "title": "Quickstart", "file": "Quickstart.md"},
                                          {"slug": "rebuild", "title": "Den Server neu aufbauen", "file": "Rebuild.md"}]}]},
        "en": {"label": "English", "start": "start", "groups": [
            {"name": "Reference", "pages": [{"slug": "commands", "title": "All commands", "file": "commands.md"}]}]},
    },
}
PAGES = {
    "de/start.md": "# Homeserver\n\nWillkommen.\n",
    "de/quickstart.md": "# Quickstart\n\n## Backup einrichten\n\nDas **restic**-Passwort steht im Tresor.\n\n```\nhs backup init\n```\n",
    "de/rebuild.md": "# Rebuild\n\n- [ ] Das restic-Passwort im Passwortmanager.\n",
    "en/start.md": "# Homeserver (English)\n",
    "en/commands.md": "# Commands\n\n| Command | What |\n| --- | --- |\n| `hs backup` | restic backup |\n",
}


class FakeAuth:
    def __init__(self, cfg):
        self.cfg = cfg

    def storage_locked(self):
        return False

    def domain_password_ok(self, user, password):
        return False

    def domain_is_admin(self, user):
        return False

    def local_password_ok(self, user, password):
        return user == "adminuser" and password == "pw"


class Docs(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.docs = os.path.join(self.tmp, "docs-site")
        for rel, text in PAGES.items():
            os.makedirs(os.path.dirname(os.path.join(self.docs, rel)), exist_ok=True)
            with open(os.path.join(self.docs, rel), "w", encoding="utf-8") as f:
                f.write(text)
        with open(os.path.join(self.docs, "index.json"), "w", encoding="utf-8") as f:
            json.dump(INDEX, f)
        with open(os.path.join(self.tmp, "secret.md"), "w") as f:
            f.write("# not a guide\n")
        self.caps = os.path.join(self.tmp, "capabilities")
        with open(self.caps, "w") as f:
            f.write("docs\n")
        os.environ["HS_DOCS_OUT"] = self.docs
        os.environ["HS_CAPABILITIES_FILE"] = self.caps
        os.environ["HS_CAPABILITIES_TSV"] = os.path.join(self.tmp, "none.tsv")
        os.environ["HS_STATE_DIR"] = self.tmp
        cfg = ws.Config()
        cfg.fail_delay, cfg.hs, cfg.root = 0, "/nonexistent/hs", self.tmp
        self.cfg = cfg
        self.app = ws.App(cfg, FakeAuth(cfg))
        self.srv = ws.Server(("127.0.0.1", 0), ws.make_handler(self.app))
        self.port = self.srv.server_address[1]
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        c = http.client.HTTPConnection("127.0.0.1", self.port)
        c.request("POST", "/api/login", json.dumps({"realm": "local", "user": "adminuser", "password": "pw"}),
                  {"Content-Type": "application/json", "Origin": "http://127.0.0.1:%d" % self.port})
        self.cookie = c.getresponse().getheader("Set-Cookie").split(";")[0]
        c.close()

    def tearDown(self):
        self.srv.shutdown()
        self.srv.server_close()
        for k in ("HS_DOCS_OUT", "HS_CAPABILITIES_FILE", "HS_CAPABILITIES_TSV", "HS_STATE_DIR"):
            os.environ.pop(k, None)

    def get(self, path, cookie=True):
        c = http.client.HTTPConnection("127.0.0.1", self.port)
        c.request("GET", path, headers={"Cookie": self.cookie} if cookie else {})
        r = c.getresponse()
        body = r.read()
        ctype = r.getheader("Content-Type", "")
        c.close()
        return r.status, ctype, body

    def test_needs_a_session(self):
        for p in ("/api/docs/index", "/api/docs/page/de/quickstart", "/api/docs/search?q=restic"):
            self.assertEqual(self.get(p, cookie=False)[0], 401, p)

    def test_off_without_the_capability(self):
        with open(self.caps, "w") as f:
            f.write("metrics\n")
        for p in ("/api/docs/index", "/api/docs/page/de/quickstart", "/api/docs/search?q=restic"):
            s, _, body = self.get(p)
            self.assertEqual(s, 404, p)
            self.assertIn("switched off", json.loads(body)["error"])

    def test_index(self):
        s, ctype, body = self.get("/api/docs/index")
        self.assertEqual(s, 200)
        self.assertTrue(ctype.startswith("application/json"))
        self.assertEqual(json.loads(body)["langs"]["de"]["groups"][0]["pages"][0]["slug"], "quickstart")

    def test_index_not_built(self):
        os.remove(os.path.join(self.docs, "index.json"))
        s, _, body = self.get("/api/docs/index")
        self.assertEqual(s, 404)
        d = json.loads(body)
        self.assertEqual((d["error"], d["hint"]), ("not built", "hs docs build"))

    def test_page_is_markdown(self):
        s, ctype, body = self.get("/api/docs/page/de/quickstart")
        self.assertEqual(s, 200)
        self.assertTrue(ctype.startswith("text/markdown"))
        self.assertIn("## Backup einrichten", body.decode("utf-8"))

    def test_page_names_are_checked(self):
        for p in ("/api/docs/page/fr/quickstart", "/api/docs/page/de/Quickstart", "/api/docs/page/de/..%2f..%2fsecret",
                  "/api/docs/page/de/quickstart.md", "/api/docs/page/de/nichtda", "/api/docs/page/de", "/api/docs/page/de/a/b",
                  "/api/docs/page/..%2fsecret/x"):
            self.assertEqual(self.get(p)[0], 404, p)

    def test_a_link_inside_the_folder_cannot_leave_it(self):
        try:
            os.symlink(os.path.join(self.tmp, "secret.md"), os.path.join(self.docs, "de", "leak.md"))
        except (OSError, NotImplementedError):
            self.skipTest("no symlinks here")
        self.assertEqual(self.get("/api/docs/page/de/leak")[0], 404)

    def test_search_finds_text_headings_and_titles(self):
        s, _, body = self.get("/api/docs/search?q=restic")
        self.assertEqual(s, 200)
        hits = json.loads(body)["hits"]
        slugs = {(h["lang"], h["slug"]) for h in hits}
        self.assertEqual(slugs, {("de", "quickstart"), ("de", "rebuild"), ("en", "commands")})
        top = json.loads(self.get("/api/docs/search?q=Backup+einrichten")[2])["hits"][0]
        self.assertEqual((top["slug"], top["anchor"]), ("quickstart", "backup-einrichten"))
        by_title = json.loads(self.get("/api/docs/search?q=neu+aufbauen")[2])["hits"]
        self.assertEqual(by_title[0]["slug"], "rebuild")

    def test_search_snippet_has_no_markup(self):
        hits = json.loads(self.get("/api/docs/search?q=Passwort")[2])["hits"]
        text = " ".join(h["snippet"] for h in hits)
        self.assertNotIn("**", text)
        self.assertNotIn("[ ]", text)

    def test_search_limits(self):
        self.assertEqual(json.loads(self.get("/api/docs/search?q=r")[2])["hits"], [])
        self.assertEqual(json.loads(self.get("/api/docs/search?q=" + "x" * 90)[2])["hits"], [])
        self.assertEqual(json.loads(self.get("/api/docs/search?q=restic&lang=en")[2])["hits"][0]["lang"], "en")
        self.assertEqual(json.loads(self.get("/api/docs/search?q=restic&lang=zz")[2])["hits"].__len__(), 3)

    def test_code_blocks_are_not_headings(self):
        with open(os.path.join(self.docs, "de", "start.md"), "a", encoding="utf-8") as f:
            f.write("\n```\n# kein Titel\nrestic im Code\n```\n")
        hits = json.loads(self.get("/api/docs/search?q=kein+Titel&lang=de")[2])["hits"]
        self.assertTrue(all(h["heading"] != "kein Titel" for h in hits))

    def test_unknown_route(self):
        self.assertEqual(self.get("/api/docs/nothing")[0], 404)

    def test_features_names_the_capability(self):
        s, _, body = self.get("/api/session")
        self.assertIn("docs", json.loads(body)["features"]["capabilities"])


if __name__ == "__main__":
    unittest.main()
