#!/usr/bin/env python3
"""scripts/web-serve.py: GET /api/board (the dashboard tiles). Guard: variant web, session or (dashboardOpen + private address + Host name), shape."""
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

TILES = "Apps\tJellyfin\thttp://10.10.95.30:8096\tFilms, series\tjellyfin\tjellyfin\nAdministration\tGrafana\thttp://g:3000\t-\t-\tgrafana\n"


class FakeAuth:
    locked = False

    def __init__(self, cfg):
        self.cfg = cfg

    def storage_locked(self):
        return self.locked

    def domain_password_ok(self, user, password):
        return False

    def domain_is_admin(self, user):
        return False

    def local_password_ok(self, user, password):
        return user == "adminuser" and password == "pw"


class Board(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.settings = os.path.join(self.tmp, "settings")
        os.makedirs(self.settings)
        self.set("dashboard", "web")
        self.set("dashboardOpen", "true")
        self.set("hostName", "homeserver")
        caps = os.path.join(self.tmp, "caps")
        with open(caps, "w") as f:
            f.write("dashboard\n")
        fake = "/nonexistent/hs"
        self.real_run = ws._run
        ws._run = lambda cmd, stdin=None, timeout=10: ((0, os.environ["HS_FAKE_TILES"]) if cmd[-2:] == ["services", "tiles"] else
                                                       (0, os.environ.get("HS_FAKE_STATS", "")) if cmd[-2:] == ["services", "stats"] else (1, ""))
        os.environ.update({"HS_SETTINGS_DIR": self.settings, "HS_CAPABILITIES_FILE": caps, "HS_FAKE_TILES": TILES,
                           "HS_INCUS_UI_FILE": os.path.join(self.tmp, "incus-ui"), "HS_STATE_DIR": self.tmp,
                           "HS_MACHINE_FILE": os.path.join(self.tmp, "machine.toml"), "HS_SITE_NAME_FILE": os.path.join(self.tmp, "site")})
        with open(os.environ["HS_MACHINE_FILE"], "w") as f:
            f.write('[adDomain]\nrealm = "HOME.LAN"\n')
        with open(os.environ["HS_SITE_NAME_FILE"], "w") as f:
            f.write("main\n")
        cfg = ws.Config()
        cfg.fail_delay, cfg.hs, cfg.trust_proxy = 0, fake, True
        self.auth = FakeAuth(cfg)
        self.app = ws.App(cfg, self.auth)
        self.srv = ws.Server(("127.0.0.1", 0), ws.make_handler(self.app))
        self.port = self.srv.server_address[1]
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.cookie = None

    def tearDown(self):
        ws._run = self.real_run
        self.srv.shutdown()
        self.srv.server_close()

    def set(self, key, value):
        with open(os.path.join(self.settings, key), "w") as f:
            f.write(value + "\n")

    def login(self):
        c = http.client.HTTPConnection("127.0.0.1", self.port)
        c.request("POST", "/api/login", json.dumps({"realm": "local", "user": "adminuser", "password": "pw"}),
                  {"Content-Type": "application/json", "Origin": "http://127.0.0.1:%d" % self.port})
        self.cookie = c.getresponse().getheader("Set-Cookie").split(";")[0]
        c.close()

    def get(self, path="/api/board", fwd=None, host="192.168.1.9", cookie=False):
        h = {"Host": host}
        if fwd:
            h["X-Forwarded-For"] = fwd
        if cookie:
            h["Cookie"] = self.cookie
        c = http.client.HTTPConnection("127.0.0.1", self.port)
        c.request("GET", path, headers=h)
        r = c.getresponse()
        d = json.loads(r.read() or b"{}")
        c.close()
        return r.status, d

    def test_not_web(self):
        self.set("dashboard", "homepage")
        self.assertEqual(self.get(fwd="192.168.1.5")[0], 404)
        os.unlink(os.path.join(self.settings, "dashboard"))
        self.assertEqual(self.get(fwd="192.168.1.5")[0], 404)

    def test_public_address_refused(self):
        s, d = self.get(fwd="8.8.8.8")
        self.assertEqual((s, d["error"]), (403, "only from the home network or Tailscale"))

    def test_private_addresses_ok(self):
        for ip in ("192.168.1.5", "100.101.1.2", "10.1.2.3", "172.16.4.4", "fd7a:115c:a1e0::1", "::ffff:192.168.1.5"):
            self.assertEqual(self.get(fwd=ip)[0], 200, ip)
        for ip in ("172.32.0.1", "100.128.0.1", "1.1.1.1", "2001:db8::1"):
            self.assertEqual(self.get(fwd=ip)[0], 403, ip)

    def test_forwarded_for_ignored_without_trust(self):
        self.app.cfg.trust_proxy = False
        # the real peer (127.0.0.1) counts, the forwarded public address is not believed
        self.assertEqual(self.get(fwd="8.8.8.8")[0], 200)
        self.app.cfg.trust_proxy = True
        self.assertEqual(self.get(fwd="8.8.8.8")[0], 403)

    def test_private_client_unit(self):
        self.assertTrue(ws.private_client("127.0.0.1") and ws.private_client("::1") and ws.private_client("fe80::1"))
        self.assertFalse(ws.private_client("") or ws.private_client("garbage") or ws.private_client("8.8.8.8"))

    def test_open_off_needs_session(self):
        self.set("dashboardOpen", "false")
        s, d = self.get(fwd="192.168.1.5")
        self.assertEqual((s, d["error"]), (403, "open dashboard is off: hs config set dashboardOpen true"))
        self.login()
        self.assertEqual(self.get(fwd="8.8.8.8", cookie=True)[0], 200)

    def test_session_from_public_address(self):
        self.login()
        self.assertEqual(self.get(fwd="8.8.8.8", host="evil.example", cookie=True)[0], 200)

    def test_host_header(self):
        for host in ("192.168.1.9:8480", "[fd7a::1]:8480", "homeserver", "homeserver:8480", "homeserver.local", "main.home.lan",
                     "jellyfin.main.home.lan", "homeserver.tail1234.ts.net"):
            self.assertEqual(self.get(fwd="192.168.1.5", host=host)[0], 200, host)
        for host in ("evil.example", "evil.example:8480", "homeserver.evil.example", "other.tail1234.ts.net", "main.home.lan.evil.com"):
            self.assertEqual(self.get(fwd="192.168.1.5", host=host)[0], 403, host)

    def test_shape(self):
        s, d = self.get(fwd="192.168.1.5")
        self.assertEqual(s, 200)
        self.assertEqual((d["schema"], d["locked"], d["incus_ui"]), (1, False, True))
        self.assertEqual(len(d["tiles"]), 2)
        jf, gr = d["tiles"]
        self.assertEqual((jf["service"], jf["group"], jf["title"], jf["description"], jf["icon"], jf["stats"]),
                         ("jellyfin", "Apps", "Jellyfin", "Films, series", "jellyfin", []))
        self.assertEqual((gr["description"], gr["icon"], gr["href"]), ("", "", "http://g:3000"))

    def test_stats_merged_only_ok(self):
        T = "\t"
        os.environ["HS_FAKE_STATS"] = "\n".join([
            T.join(["jellyfin", "0", "Streams", "ok", "2", "-"]),
            T.join(["jellyfin", "1", "Films", "failed", "-", "-"]),
            T.join(["jellyfin", "2", "Disk", "ok", "5", "GB"]),
            T.join(["ghost", "0", "Nothing", "ok", "9", "-"]),
            T.join(["grafana", "0", "Key", "nokey", "-", "-"])]) + "\n"
        try:
            d = self.get(fwd="192.168.1.5")[1]
        finally:
            os.environ.pop("HS_FAKE_STATS", None)
        jf, gr = d["tiles"]
        self.assertEqual(jf["stats"], [{"label": "Streams", "value": "2", "unit": ""}, {"label": "Disk", "value": "5", "unit": "GB"}])
        self.assertEqual(gr["stats"], [])

    def test_incus_ui_off(self):
        with open(os.environ["HS_INCUS_UI_FILE"], "w") as f:
            f.write("off\n")
        self.assertFalse(self.get(fwd="192.168.1.5")[1]["incus_ui"])

    def test_locked(self):
        self.auth.locked = True
        s, d = self.get(fwd="192.168.1.5")
        self.assertEqual((s, d["locked"], d["tiles"]), (200, True, []))

    def test_no_query_no_cors(self):
        c = http.client.HTTPConnection("127.0.0.1", self.port)
        c.request("GET", "/api/board?fresh=1&x=y", headers={"Host": "192.168.1.9", "X-Forwarded-For": "192.168.1.5", "Origin": "http://evil"})
        r = c.getresponse()
        r.read()
        self.assertEqual(r.status, 200)
        self.assertIsNone(r.getheader("Access-Control-Allow-Origin"))
        self.assertIn("no-store", r.getheader("Cache-Control") or "")

    def test_sys_read_still_needs_session(self):
        self.assertEqual(self.get("/api/sys/services/tiles", fwd="192.168.1.5")[0], 401)


if __name__ == "__main__":
    unittest.main()
