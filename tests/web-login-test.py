#!/usr/bin/env python3
"""scripts/web-serve.py: sign-in rules, sessions, CSRF, throttle, theme. Real HTTP server on a free port, fake helpers."""
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


class FakeAuth:
    """Domain: anna (admin) and bob (no admin), password 'pw'. Local: adminuser, password 'local pw'."""

    def __init__(self, cfg):
        self.cfg, self.locked = cfg, False

    def storage_locked(self):
        return self.locked

    def domain_password_ok(self, user, password):
        if user == "carol":
            return None          # the helper could not decide
        return user in ("anna", "bob") and password == "pw"

    def domain_is_admin(self, user):
        return user == "anna"

    def local_password_ok(self, user, password):
        return user == "adminuser" and password == "local pw"


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        os.makedirs(os.path.join(self.tmp, "assets"))
        with open(os.path.join(self.tmp, "index.html"), "w") as f:
            f.write("<html>app</html>")
        with open(os.path.join(self.tmp, "assets", "a.js"), "w") as f:
            f.write("x")
        cfg = ws.Config()
        cfg.root, cfg.workgroup, cfg.realm, cfg.fail_delay = self.tmp, "HOME", "ad.home.lan", 0
        cfg.hs = "/nonexistent/hs"
        self.cfg = cfg
        self.auth = FakeAuth(cfg)
        self.app = ws.App(cfg, self.auth)
        self.srv = ws.Server(("127.0.0.1", 0), ws.make_handler(self.app))
        self.port = self.srv.server_address[1]
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def tearDown(self):
        self.srv.shutdown()
        self.srv.server_close()

    def req(self, method, path, body=None, headers=None, origin=True, ctype="application/json"):
        h = dict(headers or {})
        if body is not None:
            h["Content-Type"] = ctype
        if method == "POST" and origin:
            h.setdefault("Origin", "http://127.0.0.1:%d" % self.port)
        c = http.client.HTTPConnection("127.0.0.1", self.port)
        c.request(method, path, json.dumps(body) if body is not None else None, h)
        r = c.getresponse()
        data = r.read()
        out = (r.status, data, r)
        c.close()
        return out

    def login(self, realm="domain", user="anna", password="pw", **kw):
        s, d, r = self.req("POST", "/api/login", {"realm": realm, "user": user, "password": password}, **kw)
        return s, (json.loads(d) if d[:1] == b"{" else d), r

    @staticmethod
    def cookie(r):
        c = r.getheader("Set-Cookie") or ""
        return c.split(";")[0]


class Login(Base):
    def test_domain_admin_signs_in(self):
        s, d, r = self.login()
        self.assertEqual(s, 200)
        self.assertEqual(d["user"], "HOME\\anna")
        c = r.getheader("Set-Cookie")
        for part in ("HttpOnly", "SameSite=Strict", "Path=/"):
            self.assertIn(part, c)
        s2, d2, _ = self.req("GET", "/api/session", headers={"Cookie": self.cookie(r)})
        self.assertEqual(s2, 200)
        self.assertEqual(json.loads(d2)["csrf"], d["csrf"])

    def test_helper_trouble_is_a_503_and_is_not_counted_as_a_wrong_password(self):
        for _ in range(8):
            self.assertEqual(self.login(user="carol")[0], 503)
        self.assertEqual(self.login()[0], 200)       # no lock-out from the trouble

    def test_wrong_password(self):
        s, d, r = self.login(password="nope")
        self.assertEqual(s, 401)
        self.assertIsNone(r.getheader("Set-Cookie"))

    def test_domain_user_who_is_not_admin_is_refused(self):
        s, d, r = self.login(user="bob")
        self.assertEqual(s, 403)
        self.assertIn("Domain Admins", d["error"])
        self.assertIsNone(r.getheader("Set-Cookie"))

    def test_local_admin(self):
        s, d, r = self.login(realm="local", user="adminuser", password="local pw")
        self.assertEqual((s, d["user"]), (200, "adminuser"))

    def test_local_realm_only_for_the_one_account(self):
        s, _, _ = self.login(realm="local", user="anna", password="pw")
        self.assertEqual(s, 401)

    def test_locked_storage_closes_the_domain_door_and_ends_domain_sessions(self):
        _, _, r = self.login()
        ck = self.cookie(r)
        self.auth.locked = True
        s, _, _ = self.login()
        self.assertEqual(s, 409)
        self.assertEqual(self.req("GET", "/api/session", headers={"Cookie": ck})[0], 401)
        s, d, _ = self.login(realm="local", user="adminuser", password="local pw")
        self.assertEqual(s, 200)

    def test_bad_input(self):
        for bad in ({"realm": "domain", "user": "a b", "password": "x"}, {"realm": "x", "user": "anna", "password": "pw"},
                    {"realm": "domain", "user": "anna"}, {"realm": "domain", "user": "HOME\\anna", "password": "pw"}):
            self.assertEqual(self.req("POST", "/api/login", bad)[0], 400, bad)

    def test_throttle(self):
        for _ in range(5):
            self.assertEqual(self.login(password="bad")[0], 401)
        s, d, r = self.login(password="bad")
        self.assertEqual(s, 429)
        self.assertTrue(int(r.getheader("Retry-After")) >= 1)
        self.assertEqual(self.login()[0], 429)       # even the right password waits


class Csrf(Base):
    def test_login_needs_same_origin_and_json(self):
        body = {"realm": "domain", "user": "anna", "password": "pw"}
        self.assertEqual(self.req("POST", "/api/login", body, origin=False)[0], 403)
        self.assertEqual(self.req("POST", "/api/login", body, headers={"Origin": "http://evil.example"})[0], 403)
        self.assertEqual(self.req("POST", "/api/login", body, ctype="text/plain")[0], 400)

    def test_logout_needs_the_token(self):
        _, d, r = self.login()
        ck = {"Cookie": self.cookie(r)}
        self.assertEqual(self.req("POST", "/api/logout", {}, headers=ck)[0], 403)
        self.assertEqual(self.req("POST", "/api/logout", {}, headers=dict(ck, **{"X-CSRF-Token": d["csrf"]}))[0], 200)
        self.assertEqual(self.req("GET", "/api/session", headers=ck)[0], 401)

    def test_session_without_cookie(self):
        self.assertEqual(self.req("GET", "/api/session")[0], 401)


class Pages(Base):
    def test_hello_needs_no_login(self):
        s, d, _ = self.req("GET", "/api/hello")
        d = json.loads(d)
        self.assertEqual(s, 200)
        self.assertTrue(d["domain"]["available"])
        self.assertEqual(d["local_user"], "adminuser")
        self.auth.locked = True
        d = json.loads(self.req("GET", "/api/hello")[1])
        self.assertTrue(d["locked"])
        self.assertFalse(d["domain"]["available"])

    def test_index_carries_what_the_sign_in_page_needs(self):
        with open(os.path.join(self.tmp, "index.html"), "w") as f:
            f.write('<head><meta name="hs-hello" content="" /></head>')
        body = self.req("GET", "/")[1].decode()
        self.assertNotIn('content=""', body)
        import html as h
        raw = body.split('content="', 1)[1].split('"', 1)[0]
        d = json.loads(h.unescape(raw))
        self.assertEqual((d["domain"]["workgroup"], d["domain"]["available"], d["local_user"], d["locked"]), ("HOME", True, "adminuser", False))
        self.assertNotIn("facts", d)

    def test_no_domain_configured(self):
        self.cfg.workgroup = ""
        self.assertIsNone(json.loads(self.req("GET", "/api/hello")[1])["domain"])
        self.assertEqual(self.login()[0], 409)

    def test_static_and_fallback(self):
        self.assertEqual(self.req("GET", "/")[1], b"<html>app</html>")
        self.assertEqual(self.req("GET", "/disks/bulk")[1], b"<html>app</html>")
        self.assertEqual(self.req("GET", "/assets/a.js")[0], 200)
        self.assertEqual(self.req("GET", "/assets/missing.js")[0], 404)
        self.assertEqual(self.req("GET", "/nothing.png")[0], 404)
        for evil in ("/../../etc/passwd", "/%2e%2e/%2e%2e/etc/passwd", "/..%2f..%2fetc%2fpasswd"):
            s, d, _ = self.req("GET", evil)
            self.assertNotIn(b"root:", d)

    def test_security_headers(self):
        _, _, r = self.req("GET", "/")
        self.assertIn("frame-ancestors 'none'", r.getheader("Content-Security-Policy"))
        self.assertEqual(r.getheader("X-Content-Type-Options"), "nosniff")

    def test_unknown_api_and_methods(self):
        self.assertEqual(self.req("GET", "/api/nothing")[0], 404)
        self.assertEqual(self.req("POST", "/api/session", {})[0], 404)


TAB, NL = chr(9), chr(10)
PLAN_WITH_COMMITS = NL.join(["status" + TAB + "ok", "heading" + TAB + "update", "section" + TAB + "New changes", "text" + TAB + "abc123 fix something",
                             "step" + TAB + "build", "command" + TAB + "x", "long" + TAB + "yes"]) + NL


# reads and change areas whose script/registry rows are still to be written (each is removed from here when its row exists)
PENDING_READS = set()
PENDING_CHANGES = set()


class Reads(Base):
    def setUp(self):
        super().setUp()
        self.calls = []
        self.answer = (0, "a\tb\nc\td\n")
        self.real_run = ws._run

        def fake(cmd, stdin=None, timeout=10):
            self.calls.append(cmd)
            return self.answer
        ws._run = fake
        _, d, r = self.login()
        self.ck = {"Cookie": self.cookie(r)}
        self.calls.clear()

    def tearDown(self):
        ws._run = self.real_run
        super().tearDown()

    def get(self, path):
        s, d, _ = self.req("GET", path, headers=self.ck)
        return s, json.loads(d)

    def test_needs_a_session(self):
        self.assertEqual(self.req("GET", "/api/sys/ct/list")[0], 401)
        self.assertEqual(self.calls, [])

    def test_rows_and_argv(self):
        s, d = self.get("/api/sys/ct/list")
        self.assertEqual((s, d["rows"]), (200, [["a", "b"], ["c", "d"]]))
        self.assertEqual(self.calls[-1], ["/nonexistent/hs", "sys", "ct", "list"])

    def test_json_and_text_kinds(self):
        self.answer = (0, '{"host": "x"}')
        self.assertEqual(self.get("/api/sys/deck")[1], {"host": "x"})
        self.answer = (0, "line one\nline two\n")
        self.assertEqual(self.get("/api/sys/system/config")[1]["text"], "line one\nline two\n")
        ws.READS[("deck",)]["ttl"] = 0
        self.answer = (0, "not json")
        self.assertEqual(self.get("/api/sys/deck")[0], 502)
        ws.READS[("deck",)]["ttl"] = 8

    def test_answers_are_cached_per_question(self):
        self.get("/api/sys/ct/list")
        self.get("/api/sys/ct/list")
        self.get("/api/sys/ct/bindings/docker")
        self.get("/api/sys/ct/bindings/docker")
        self.assertEqual(len(self.calls), 2)

    def test_only_the_allowlist(self):
        for bad in ("/api/sys/ct/plan/docker/stop", "/api/sys/ct/start/docker/stop", "/api/sys/jobs/stop/hs-x", "/api/sys/state/forget/abc",
                    "/api/sys/registry", "/api/sys/ct", "/api/sys/ct/list/extra", "/api/sys/ct/bindings", "/api/sys/ct/bindings/a/b",
                    "/api/sys/ct/bindings/..", "/api/sys/ct/bindings/a;ls", "/api/sys/ct/bindings/-rf", "/api/sys/ct/bindings/a%0A", "/api/sys/"):
            self.assertEqual(self.get(bad)[0], 404, bad)
        self.assertEqual(self.calls, [])

    def test_query_options_are_checked_and_become_flags(self):
        self.answer = (0, "")
        self.assertEqual(self.get("/api/sys/logs/show?level=err&lines=50&unit=incus")[0], 200)
        self.assertEqual(self.calls[-1][2:], ["logs", "show", "--level", "err", "--lines", "50", "--unit", "incus"])
        self.assertEqual(self.get("/api/sys/logs/show?level=bad")[0], 404)
        self.assertEqual(self.get("/api/sys/logs/show?lines=1;ls")[0], 404)
        self.get("/api/sys/state/events?n=20")
        self.assertEqual(self.calls[-1][2:], ["state", "events", "20"])
        self.get("/api/sys/ct/list?evil=1")      # unknown parameters are ignored, never passed on
        self.assertEqual(self.calls[-1][2:], ["ct", "list"])

    def test_group_names_with_spaces_and_positional_options(self):
        self.get("/api/sys/users/group-access/Domain%20Admins")
        self.assertEqual(self.calls[-1][2:], ["users", "group-access", "Domain Admins"])
        self.assertEqual(self.get("/api/sys/users/group-access/a%2Fb")[0], 404)
        self.get("/api/sys/pool/info?pool=bulk")
        self.assertEqual(self.calls[-1][2:], ["pool", "info", "bulk"])
        self.get("/api/sys/backup/snapshots?tag=ct:docker")
        self.assertEqual(self.calls[-1][2:], ["backup", "snapshots", "ct:docker"])
        self.assertEqual(self.get("/api/sys/backup/snapshots?tag=--x")[0], 404)

    def test_a_failing_read_is_a_502_and_not_cached(self):
        self.answer = (1, "")
        self.assertEqual(self.get("/api/sys/ct/list")[0], 502)
        self.answer = (0, "x\n")
        self.assertEqual(self.get("/api/sys/ct/list")[0], 200)

    def test_every_entry_is_a_registry_row_and_none_changes_anything(self):
        reg = os.path.join(here, "..", "scripts", "lib", "registry.tsv")
        rows = set()
        with open(reg, encoding="utf-8") as f:
            for line in f:
                c = line.rstrip("\n").split("\t")
                if c[0] == "sys":
                    rows.add(tuple("<x>" if w.startswith("<") else w for w in c[1].split()[1:]))
        changing = {"plan", "start", "stop", "forget", "test", "collect", "delete", "purge", "measure", "unlock", "scheduled",
                    "mount-all", "event", "history-record", "alarm", "boot", "stdin", "started", "stopping"}
        for words, spec in ws.READS.items():
            if words in PENDING_READS:
                continue
            self.assertFalse(changing & set(words), words)
            key = words + tuple("<x>" for _ in spec.get("args", []))
            self.assertIn(key, rows, "%s is not a registry row" % (words,))


class Changes(Base):
    PLAN = ("status\tok\nheading\trun Health check now\nstep\tstart hs-health-check.service at once\nnote\tThe unit follows its own conditions.\n"
            "command\tsystemctl start --no-block hs-health-check.service\nlong\tyes\n")

    def setUp(self):
        super().setUp()
        self.calls = []
        self.answer = (0, self.PLAN)
        self.real_run = ws._run

        def fake(cmd, stdin=None, timeout=10):
            self.calls.append(cmd)
            return self.answer
        ws._run = fake
        _, d, r = self.login()
        self.ck = {"Cookie": self.cookie(r), "X-CSRF-Token": d["csrf"]}
        self.calls.clear()

    def tearDown(self):
        ws._run = self.real_run
        super().tearDown()

    def post(self, path, body, headers=None):
        s, d, _ = self.req("POST", path, body, headers=self.ck if headers is None else headers)
        return s, json.loads(d)

    RUN = {"area": "jobs", "args": ["run", "hs-health-check.service"]}

    def test_plan_is_parsed(self):
        s, d = self.post("/api/plan", self.RUN)
        self.assertEqual(s, 200)
        self.assertEqual((d["status"], d["heading"], d["long"], d["exit"]), ("ok", "run Health check now", True, 0))
        self.assertEqual(d["steps"], [["step", "start hs-health-check.service at once"], ["note", "The unit follows its own conditions."]])
        self.assertEqual(self.calls[-1], ["/nonexistent/hs", "sys", "jobs", "plan", "run", "hs-health-check.service"])

    def test_a_refusal_keeps_its_reason(self):
        self.answer = (1, "status\trefused\nreason\tHealth check is running already.\n")
        d = self.post("/api/plan", self.RUN)[1]
        self.assertEqual((d["status"], d["reason"], d["exit"]), ("refused", "Health check is running already.", 1))
        self.answer = (127, "")
        self.assertIn("exit 127", self.post("/api/plan", self.RUN)[1]["reason"])

    def test_danger_plan_and_start_with_confirm(self):
        self.answer = (0, "status\tok\nheading\tstop Parity sync\nstep\tstop it\ndanger\tHalf way is bad.\ncommand\tsystemctl stop x\nconfirm_name\tstop\nlong\tno\n")
        d = self.post("/api/plan", {"area": "jobs", "args": ["stop", "hs-bulk-sync.service"]})[1]
        self.assertEqual((d["confirm_name"], d["steps"][-1][0]), ("stop", "danger"))
        self.answer = (0, "status\tstarted\nunit\ths-bulk-sync.service\n")
        d = self.post("/api/start", {"area": "jobs", "args": ["stop", "hs-bulk-sync.service"], "confirm": "stop"})[1]
        self.assertEqual((d["status"], d["unit"]), ("started", "hs-bulk-sync.service"))
        self.assertEqual(self.calls[-1][2:], ["jobs", "start", "stop", "hs-bulk-sync.service", "--confirm", "stop"])

    def test_session_and_csrf_are_required(self):
        self.assertEqual(self.post("/api/start", self.RUN, headers={})[0], 401)
        self.assertEqual(self.post("/api/start", self.RUN, headers={"Cookie": self.ck["Cookie"]})[0], 403)
        self.assertEqual(self.post("/api/start", self.RUN, headers={"Cookie": self.ck["Cookie"], "X-CSRF-Token": "x"})[0], 403)
        self.assertEqual(self.calls, [])

    def test_only_the_allowlist(self):
        bad = [{"area": "jobs", "args": ["delete", "hs-x"]},
               {"area": "jobs", "args": ["run", "sshd.service"]}, {"area": "jobs", "args": ["run", "hs-x;ls"]},
               {"area": "jobs", "args": ["run"]}, {"area": "jobs", "args": ["run", "hs-x", "extra"]},
               {"area": "jobs", "args": "run"}, {"area": "jobs", "args": ["run", 5]}, {"args": ["run", "hs-x"]},
               {"area": "jobs", "args": ["run", "hs-x"], "confirm": "a;b"}, {"area": "jobs", "args": ["run", "hs-x\n"]}]
        for b in bad:
            self.assertEqual(self.post("/api/start", b)[0], 400, b)
            self.assertEqual(self.post("/api/plan", b)[0], 400, b)
        self.assertEqual(self.calls, [])

    def test_instance_actions(self):
        ok = [["docker", "restart"], ["docker", "snapshot"], ["docker", "snapshot", "--label", "before-update"], ["dc1", "stop"]]
        for args in ok:
            self.assertEqual(self.post("/api/plan", {"area": "ct", "args": args})[0], 200, args)
            self.assertEqual(self.calls[-1][2:], ["ct", "plan"] + args)
        n = len(self.calls)
        bad = [["docker", "restore"], ["docker", "set", "--ram", "1"], ["Docker", "stop"], ["docker", "stop", "--force"],
               ["docker", "snapshot", "--label", "a b"], ["docker", "snapshot", "--name", "x"], ["../x", "stop"], ["docker"]]
        for args in bad:
            self.assertEqual(self.post("/api/start", {"area": "ct", "args": args})[0], 400, args)
        self.assertEqual(len(self.calls), n)

    def test_section_and_text_lines_of_a_plan_are_kept(self):
        self.answer = (0, PLAN_WITH_COMMITS)
        d = self.post("/api/plan", {"area": "system", "args": ["update"]})[1]
        self.assertEqual(d["steps"], [["section", "New changes"], ["text", "abc123 fix something"], ["step", "build"]])

    def test_more_change_areas(self):
        ok = [("backup", ["now"]), ("backup", ["init", "--disk", "ata-WDC_WD40EFRX_WD-1234"]), ("config", ["sync"]), ("config", ["migrate"]),
              ("admin", ["test-push"]), ("admin", ["fans-clean", "--seconds", "12"]),
              ("recipes", ["qbittorrent", "run", "--set", "VPN_TYPE=wireguard", "--set", "WG_ADDR=10.2.0.2/32"]), ("backup", ["drill", "--count", "5"]), ("backup", ["browse", "--to", "on"]),
              ("backup", ["toggle", "--name", "media", "--kind", "shares", "--to", "off"]),
              ("shares", ["media", "snapshot"]), ("shares", ["media", "backup", "--to", "on"]), ("shares", ["media", "rollback", "--snapshot", "auto-2026-10-11"]),
              ("users", ["anna", "lock"]), ("system", ["sync"]), ("system", ["scrub", "--pool", "fast"]), ("system", ["update"]),
              ("ct", ["docker", "update"]), ("ct", ["docker", "restore", "--snapshot", "snap1"]),
              ("config", ["set", "webAccent", "#4fb286"]), ("config", ["set", "language", "de"])]
        for area, args in ok:
            self.assertEqual(self.post("/api/plan", {"area": area, "args": args})[0], 200, (area, args))
        n = len(self.calls)
        bad = [("backup", ["init", "--disk", "a/b"]), ("backup", ["init", "--bogus", "x"]), ("backup", ["offsite-set", "--repo", "sftp:x"]), ("backup", ["browse", "--to", "maybe"]),
               ("shares", ["media", "perm", "--set", "x=full"]), ("shares", ["Media", "snapshot"]),
               ("system", ["sync", "--pool", "a;b"]),
               ("config", ["set", "sshKeys", "x"]), ("config", ["set", "hostName", "x"]), ("config", ["set", "language", "a;b"]),
               ("config", ["set", "language", "x" * 100]), ("pool", ["bulk", "remove"])]
        for area, args in bad:
            self.assertEqual(self.post("/api/start", {"area": area, "args": args})[0], 400, (area, args))
        self.assertEqual(len(self.calls), n)

    def test_tail_is_a_read_that_is_not_cached(self):
        self.answer = (0, "state\trunning\nline\thello\nnext\t1\n")
        for _ in range(2):
            s, d, _ = self.req("GET", "/api/sys/jobs/tail/hs-health-check.service?from=0", headers=self.ck)
            self.assertEqual(json.loads(d)["rows"][0], ["state", "running"])
        self.assertEqual(len(self.calls), 2)
        self.assertEqual(self.calls[-1][2:], ["jobs", "tail", "hs-health-check.service", "0"])
        self.assertEqual(self.req("GET", "/api/sys/jobs/tail/sshd?from=0", headers=self.ck)[0], 404)

    def stream(self, path, headers=None):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        c.request("GET", path, headers=self.ck if headers is None else headers)
        r = c.getresponse()
        body = r.read().decode()
        c.close()
        return r.status, r, body

    def test_stream_pushes_the_journal_and_ends_with_the_unit(self):
        self.cfg.stream_every = 0.01
        seq = [(0, "state\trunning\nnext\t0\n"),
               (0, "state\trunning\nline\tone\nnext\t1\n"),
               (0, "state\trunning\nnext\t1\n"),
               (0, "state\trunning\nline\ttwo\nnext\t2\n"),
               (0, "state\tok\nexit\t0\nnext\t2\n")]
        calls = []

        def fake(cmd, stdin=None, timeout=10):
            calls.append(cmd)
            return seq[min(len(calls) - 1, len(seq) - 1)]
        ws._run = fake
        s, r, body = self.stream("/api/sys/jobs/stream/hs-health-check.service?from=0")
        self.assertEqual(s, 200)
        self.assertEqual(r.getheader("Content-Type"), "text/event-stream")
        self.assertIsNone(r.getheader("Content-Length"))
        self.assertEqual(r.getheader("Cache-Control"), "no-store")
        events = [json.loads(line[6:]) for line in body.splitlines() if line.startswith("data: ") and line != "data: {}"]
        lines = [row[1] for e in events for row in e["rows"] if row[0] == "line"]
        self.assertEqual(lines, ["one", "two"])
        self.assertEqual(events[-1]["rows"][0], ["state", "ok"])
        self.assertTrue(body.rstrip().endswith("event: end\ndata: {}"))
        # each look resumes where the last one stopped (the `next` row), and only the tail read is run
        self.assertEqual([c[2:] for c in calls], [["jobs", "tail", "hs-health-check.service", n] for n in ("0", "0", "1", "1", "2")])
        self.assertEqual(self.app.streams, 0)

    def test_stream_gives_up_on_a_unit_that_does_not_exist(self):
        self.cfg.stream_every = 0.01
        self.answer = (0, "state\tunknown\nnext\t0\n")
        s, r, body = self.stream("/api/sys/jobs/stream/hs-nothing.service")
        self.assertEqual(s, 200)
        self.assertTrue(body.rstrip().endswith("event: end\ndata: {}"))
        self.assertEqual(len(self.calls), 4)

    def test_stream_rules(self):
        self.assertEqual(self.stream("/api/sys/jobs/stream/hs-x.service", headers={})[0], 401)
        for bad in ("/api/sys/jobs/stream/sshd", "/api/sys/jobs/stream/hs-x.service?from=-1", "/api/sys/jobs/stream/hs-x.service?from=a",
                    "/api/sys/jobs/stream/hs-x%2F..", "/api/sys/jobs/stream/"):
            self.assertEqual(self.stream(bad)[0], 404, bad)
        self.assertEqual(self.calls, [])
        self.app.streams = self.cfg.stream_max
        s, r, body = self.stream("/api/sys/jobs/stream/hs-x.service")
        self.assertEqual(s, 503)
        self.app.streams = 0

    def test_stream_ends_when_the_session_does(self):
        self.cfg.stream_every = 0.01
        self.answer = (0, "state\trunning\nnext\t0\n")
        n = []

        def fake(cmd, stdin=None, timeout=10):
            n.append(1)
            if len(n) == 3:
                self.app.sessions.drop(self.ck["Cookie"].split("=", 1)[1])
            return self.answer
        ws._run = fake
        s, r, body = self.stream("/api/sys/jobs/stream/hs-x.service")
        self.assertEqual(s, 200)
        self.assertEqual(len(n), 3)
        self.assertTrue(body.rstrip().endswith("event: end\ndata: {}"))

    def test_updates_is_a_plain_read(self):
        self.answer = (0, "behind\t3\nahead\t0\nupstream\torigin/main\nfetched\t1\n")
        s, d, _ = self.req("GET", "/api/sys/system/updates", headers=self.ck)
        self.assertEqual(s, 200)
        self.assertEqual(json.loads(d)["rows"][0], ["behind", "3"])
        self.assertEqual(self.calls[-1][2:], ["system", "updates"])

    def test_every_change_is_a_registry_pair(self):
        reg = os.path.join(here, "..", "scripts", "lib", "registry.tsv")
        with open(reg, encoding="utf-8") as f:
            paths = [line.split("\t")[1] for line in f if line.startswith("sys\t")]
        for area in ws.CHANGES:
            if area in PENDING_CHANGES:
                continue
            for verb in ("plan", "start"):
                self.assertTrue(any(p.startswith("sys %s %s " % (area, verb)) for p in paths), (area, verb))


class HelperLine(unittest.TestCase):
    """What the real Auth sends to ntlm_auth: the domain in front of the user (a bare name is refused by winbind), the password escaped."""

    def run_with(self, stdout):
        seen = {}

        class P:
            returncode = 0
            stderr = b""

        P.stdout = stdout

        def fake(cmd, input=None, capture_output=True, timeout=None):
            seen["cmd"], seen["input"] = cmd, input
            return P
        real = ws.subprocess.run
        ws.subprocess.run = fake
        try:
            cfg = ws.Config()
            cfg.workgroup = "HOME"
            ok = ws.Auth(cfg).domain_password_ok("anna", "pw with %")
        finally:
            ws.subprocess.run = real
        return ok, seen

    def test_line_and_arguments(self):
        ok, seen = self.run_with(b"OK" + bytes([10]))
        self.assertTrue(ok)
        self.assertEqual(seen["input"], b"HOME" + bytes([92]) + b"anna pw%20with%20%25" + bytes([10]))
        self.assertIn("--helper-protocol=squid-2.5-basic", seen["cmd"])
        self.assertNotIn("pw", " ".join(seen["cmd"]))

    def test_answers(self):
        self.assertIs(self.run_with(b"ERR" + bytes([10]))[0], False)
        self.assertIsNone(self.run_with(b"BH something broke" + bytes([10]))[0])
        self.assertIsNone(self.run_with(b"")[0])


class Tls(Base):
    """Behind `tailscale serve` (HS_WEB_SECURE, HS_WEB_TRUST_PROXY): Secure cookie, HSTS, throttle by the forwarded client address."""

    def setUp(self):
        super().setUp()
        self.cfg.secure = True
        self.cfg.trust_proxy = True

    def test_secure_cookie_and_hsts(self):
        s, d, r = self.login()
        self.assertEqual(s, 200)
        self.assertIn("; Secure", r.getheader("Set-Cookie"))
        self.assertIn("max-age=", r.getheader("Strict-Transport-Security"))

    def test_a_request_from_the_home_network_stays_plain_http(self):
        """webLan: a client that connects to the page directly (not through tailscale serve on this machine) gets no Secure cookie and no HSTS."""
        import http.client
        c = http.client.HTTPConnection("127.0.0.1", self.port, source_address=("127.0.0.2", 0))
        body = json.dumps({"realm": "domain", "user": "anna", "password": "pw"})
        c.request("POST", "/api/login", body, {"Content-Type": "application/json", "Origin": "http://127.0.0.1:%d" % self.port})
        r = c.getresponse()
        r.read()
        self.assertEqual(r.status, 200)
        self.assertNotIn("Secure", r.getheader("Set-Cookie"))
        self.assertIsNone(r.getheader("Strict-Transport-Security"))
        c.close()

    def test_plain_http_has_neither(self):
        self.cfg.secure = False
        s, d, r = self.login()
        self.assertNotIn("Secure", r.getheader("Set-Cookie"))
        self.assertIsNone(r.getheader("Strict-Transport-Security"))

    def test_throttle_counts_the_forwarded_client(self):
        for _ in range(5):
            self.login(password="bad", headers={"X-Forwarded-For": "100.64.0.7"})
        s, _, _ = self.login(password="bad", headers={"X-Forwarded-For": "100.64.0.7"})
        self.assertEqual(s, 429)
        # another client behind the same proxy is not locked out by the first one's address, only by the user name
        s, _, _ = self.login(user="bob", headers={"X-Forwarded-For": "100.64.0.8"})
        self.assertEqual(s, 403)

    def test_a_forged_header_is_ignored_without_the_proxy(self):
        self.cfg.trust_proxy = False
        for _ in range(5):
            self.login(password="bad", headers={"X-Forwarded-For": "100.64.0.9"})
        self.assertEqual(self.login(password="bad", headers={"X-Forwarded-For": "100.64.0.10"})[0], 429)


class Theme(unittest.TestCase):
    def test_default_is_the_design(self):
        t = ws.theme_tokens("#9184d9")
        self.assertEqual(t["--color-accent"], "#9184d9")
        self.assertEqual(t["--color-accent-900"], "#2b2741")
        self.assertEqual(t["--color-section"], "#262a60")

    def test_bad_value_falls_back(self):
        self.assertEqual(ws.theme_tokens("purple")["--color-accent"], "#9184d9")
        self.assertFalse(ws.valid_accent("#fff"))
        self.assertTrue(ws.valid_accent("#E06C75"))

    def test_roundtrip(self):
        for h in ("#9184d9", "#e06c75", "#4fb286", "#2b2741"):
            self.assertEqual(ws.oklch_to_hex(*ws.hex_to_oklch(h)), h)

    def test_other_accent_keeps_the_lightness_steps_and_changes_hue(self):
        t = ws.theme_tokens("#4fb286")
        self.assertEqual(t["--color-accent"], "#4fb286")
        ref = [ws.hex_to_oklch(ws.REF_RAMP[k])[0] for k in sorted(ws.REF_RAMP)]
        got = [ws.hex_to_oklch(t["--color-accent-%d" % k])[0] for k in sorted(ws.REF_RAMP)]
        for a, b in zip(ref, got):
            self.assertAlmostEqual(a, b, delta=0.03)
        self.assertNotEqual(t["--color-accent-800"], ws.REF_RAMP[800])
        h_ref = ws.hex_to_oklch(ws.REF_RAMP[500])[2]
        h_new = ws.hex_to_oklch(t["--color-accent-500"])[2]
        self.assertGreater(abs(h_ref - h_new), 30)
        self.assertTrue(all(v.startswith("#") and len(v) == 7 for v in t.values()))

    def test_css(self):
        self.assertTrue(ws.theme_css("#4fb286").startswith(":root {\n  --color-accent: #4fb286;"))

    def test_favicon_has_the_accent_and_follows_the_scheme(self):
        svg = ws.favicon_svg("#4FB286")
        self.assertIn('stroke="#4fb286"', svg)
        self.assertIn("prefers-color-scheme:dark", svg)
        self.assertIn('stroke="#9184d9"', ws.favicon_svg("not a colour"))


class Speed(Reads):
    def test_stale_answer_is_served_and_refreshed_in_the_background(self):
        import time
        self.get("/api/sys/ct/list")
        key = ("ct", "list")
        t, v = self.app.reads.cache[key]
        self.app.reads.cache[key] = (t - 20, v)           # ttl 5, so stale, far inside 10x
        self.answer = (0, "new\tone\n")
        s, d, r = self.req("GET", "/api/sys/ct/list", headers=self.ck)
        self.assertEqual(json.loads(d)["rows"], [["a", "b"], ["c", "d"]])      # the old answer, at once
        self.assertGreaterEqual(int(r.getheader("X-HS-Age")), 19)
        for _ in range(100):
            if self.app.reads.cache[key][0] > t:
                break
            time.sleep(0.02)
        self.assertEqual(self.get("/api/sys/ct/list")[1]["rows"], [["new", "one"]])

    def test_failed_refresh_keeps_the_old_answer_and_too_old_waits(self):
        import time
        self.get("/api/sys/ct/list")
        key = ("ct", "list")
        t, v = self.app.reads.cache[key]
        self.app.reads.cache[key] = (t - 20, v)
        self.answer = (1, "")
        self.assertEqual(self.get("/api/sys/ct/list")[1]["rows"], [["a", "b"], ["c", "d"]])
        time.sleep(0.2)
        self.assertEqual(self.app.reads.cache[key][1], v)
        self.app.reads.cache[key] = (t - 1000, v)          # past the cap: waits for the (failing) fresh run
        self.assertEqual(self.get("/api/sys/ct/list")[0], 502)

    def test_ttl_zero_is_never_stale(self):
        self.answer = (0, "x\n")
        self.get("/api/sys/jobs/tail/hs-x")
        self.get("/api/sys/jobs/tail/hs-x")
        self.assertEqual(len(self.calls), 2)

    def test_clear_wins_over_a_running_refresh(self):
        reads = self.app.reads
        gen = reads.gen
        reads.clear()
        self.assertEqual(reads.gen, gen + 1)

    def test_warmer_reads_only_while_somebody_is_active(self):
        w = self.app.warmer
        self.cfg.warm_pause = 0
        self.answer = (0, "{}")      # valid for the json read too
        self.assertGreater(w.once(), 0)
        self.assertEqual(w.once(), 0)                       # everything is fresh now
        self.app.reads.clear()
        self.app.sessions.items.clear()
        self.calls.clear()
        self.assertEqual(w.once(), 0)                       # no session: nothing runs
        self.assertEqual(self.calls, [])


class SessionFile(Base):
    def test_sessions_survive_a_restart_as_hashes_in_a_0600_file(self):
        d = tempfile.mkdtemp()
        path = os.path.join(d, "sessions.json")
        self.cfg.session_file = path
        a = ws.Sessions(self.cfg)
        token = a.create("HOME\anna", "domain", "1.2.3.4")
        csrf = a.get(token, False)["csrf"]
        raw = open(path).read()
        self.assertNotIn(token, raw)
        self.assertNotIn(csrf, raw)
        if os.name == "posix":
            self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
        b = ws.Sessions(self.cfg)                          # "restart"
        s = b.get(token, False)
        self.assertEqual((s["user"], s["csrf"]), ("HOME\anna", csrf))
        self.assertIsNone(b.get("other", False))
        b.drop(token)
        self.assertIsNone(ws.Sessions(self.cfg).get(token, False))

    def test_expired_and_broken_files_are_ignored(self):
        d = tempfile.mkdtemp()
        path = os.path.join(d, "sessions.json")
        self.cfg.session_file = path
        a = ws.Sessions(self.cfg)
        token = a.create("u", "local", "")
        a.items[token]["created"] -= self.cfg.max_age + 10
        self.assertIsNone(ws.Sessions(self.cfg).get(token, False) if a._save() is None else None)
        open(path, "w").write("{not json")
        self.assertEqual(ws.Sessions(self.cfg).restored, {})


if __name__ == "__main__":
    unittest.main(verbosity=1)
