#!/usr/bin/env python3
"""scripts/web-serve.py: GET /api/proxy/status (the VPS status document). A tiny local http.server plays the VPS."""
import http.client
import http.server
import importlib.util
import json
import os
import threading
import time
import unittest

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("web_serve", os.path.join(here, "..", "scripts", "web-serve.py"))
ws = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ws)
os.environ["HS_WEB_QUIET"] = "1"


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


class Vps(http.server.BaseHTTPRequestHandler):
    mode = "ok"
    hits = 0

    def log_message(self, *a):
        pass

    def do_GET(self):
        Vps.hits += 1
        m = Vps.mode
        if self.path.startswith("/redir"):
            self.send_response(302)
            self.send_header("Location", "/status.json")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if m == "timeout":
            time.sleep(1.5)
        body = {"ok": json.dumps({"kind": "proxyserver", "schema": 1, "host": "vps", "problems": 0}),
                "list": "[1,2]", "text": "hello", "big": json.dumps({"x": "a" * 300000})}.get(m, "{}").encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except OSError:
            pass


class Proxy(unittest.TestCase):
    def setUp(self):
        Vps.mode, Vps.hits = "ok", 0
        self.vps = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Vps)
        threading.Thread(target=self.vps.serve_forever, daemon=True).start()
        self.vurl = "http://127.0.0.1:%d/status.json" % self.vps.server_address[1]
        cfg = ws.Config()
        cfg.fail_delay, cfg.hs, cfg.proxy_url, cfg.proxy_timeout = 0, "/nonexistent/hs", self.vurl, 0.5
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
        for s in (self.srv, self.vps):
            s.shutdown()
            s.server_close()

    def get(self, cookie=True):
        c = http.client.HTTPConnection("127.0.0.1", self.port)
        c.request("GET", "/api/proxy/status", headers={"Cookie": self.cookie} if cookie else {})
        r = c.getresponse()
        d = json.loads(r.read())
        c.close()
        return r.status, d

    def test_ok_as_is(self):
        s, d = self.get()
        self.assertEqual(s, 200)
        self.assertEqual(d["host"], "vps")

    def test_needs_session(self):
        self.assertEqual(self.get(cookie=False)[0], 401)
        self.assertEqual(Vps.hits, 0)

    def test_off(self):
        self.cfg.proxy_url = ""
        s, d = self.get()
        self.assertEqual((s, d["error"]), (404, "not configured"))
        self.assertEqual(Vps.hits, 0)

    def test_not_http_url_is_off(self):
        self.cfg.proxy_url = "file:///etc/passwd"
        self.assertEqual(self.get()[0], 404)

    def test_not_json(self):
        Vps.mode = "text"
        self.assertEqual(self.get()[0], 502)

    def test_not_a_dict(self):
        Vps.mode = "list"
        self.assertEqual(self.get()[0], 502)

    def test_too_big(self):
        Vps.mode = "big"
        self.assertEqual(self.get()[0], 502)

    def test_timeout(self):
        Vps.mode = "timeout"
        self.assertEqual(self.get()[0], 502)

    def test_unreachable(self):
        self.cfg.proxy_url = "http://127.0.0.1:1/status.json"
        self.assertEqual(self.get()[0], 502)

    def test_no_redirects(self):
        self.cfg.proxy_url = self.vurl.replace("/status.json", "/redir")
        self.assertEqual(self.get()[0], 502)
        self.assertEqual(Vps.hits, 1)

    def test_cache(self):
        self.get()
        self.get()
        self.assertEqual(Vps.hits, 1)
        self.app.proxy.at -= 100
        self.get()
        self.assertEqual(Vps.hits, 2)

    def test_request_cannot_change_the_url(self):
        c = http.client.HTTPConnection("127.0.0.1", self.port)
        c.request("GET", "/api/proxy/status?url=http://127.0.0.2/x", headers={"Cookie": self.cookie})
        r = c.getresponse()
        r.read()
        self.assertEqual(r.status, 200)
        self.assertEqual(Vps.hits, 1)


if __name__ == "__main__":
    unittest.main()
