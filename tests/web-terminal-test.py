#!/usr/bin/env python3
"""scripts/web_terminal.py + the terminal glue in scripts/web-serve.py: WebSocket framing, tickets, limits, the upgrade against the
real server on a free port with a fake shell (a socketpair that echoes). No pty, no systemd: runs on Windows too."""
import http.client
import importlib.util
import json
import os
import socket
import struct
import tempfile
import threading
import time
import unittest

here = os.path.dirname(os.path.abspath(__file__))
scripts = os.path.join(here, "..", "scripts")
spec = importlib.util.spec_from_file_location("web_serve", os.path.join(scripts, "web-serve.py"))
ws = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ws)
wt = ws.wt
os.environ["HS_WEB_QUIET"] = "1"


# ─────────────────────────── helpers ───────────────────────────
def mask_frame(op, payload=b"", fin=True, mask=b"\x01\x02\x03\x04", masked=True, rsv=0, length=None):
    """A client frame."""
    n = len(payload) if length is None else length
    b0 = (0x80 if fin else 0) | rsv | op
    head = bytes([b0])
    mbit = 0x80 if masked else 0
    if n < 126:
        head += bytes([mbit | n])
    elif n < 65536:
        head += bytes([mbit | 126]) + struct.pack(">H", n)
    else:
        head += bytes([mbit | 127]) + struct.pack(">Q", n)
    if not masked:
        return head + payload
    return head + mask + bytes(c ^ mask[i % 4] for i, c in enumerate(payload))


def read_frame(sock, timeout=5):
    """One server frame -> (opcode, payload). Server frames are never masked."""
    sock.settimeout(timeout)

    def need(n):
        buf = b""
        while len(buf) < n:
            chunk = sock.recv(n - len(buf))
            if not chunk:
                raise EOFError
            buf += chunk
        return buf
    b0, b1 = need(2)
    n = b1 & 0x7F
    assert not b1 & 0x80
    if n == 126:
        n = struct.unpack(">H", need(2))[0]
    elif n == 127:
        n = struct.unpack(">Q", need(8))[0]
    return b0 & 0x0F, need(n)


def read_until(sock, want, timeout=5):
    """Collect binary output until `want` appears; returns the text. Fails at the timeout."""
    end, got = time.time() + timeout, b""
    while want not in got:
        assert time.time() < end, "never saw %r in %r" % (want, got)
        op, data = read_frame(sock, timeout)
        if op == wt.OP_BINARY:
            got += data
    return got


class FakeMaster:
    """Stands in for the pty master: a socketpair end; the other end echoes everything (and says hi first)."""
    made = []

    def __init__(self):
        self.a, self.b = socket.socketpair()
        self.resizes, self.closed = [], threading.Event()
        FakeMaster.made.append(self)
        threading.Thread(target=self._echo, daemon=True).start()

    def _echo(self):
        try:
            self.b.sendall(b"adminuser@homeserver:~$ ")
            while True:
                d = self.b.recv(4096)
                if not d:
                    return
                self.b.sendall(d)
        except OSError:
            pass

    def fileno(self):
        return self.a.fileno()

    def read(self):
        return self.a.recv(4096)

    def write(self, data):
        self.a.sendall(data)

    def resize(self, cols, rows):
        self.resizes.append((cols, rows))

    def close(self):
        self.closed.set()
        for s in (self.a, self.b):
            try:
                s.close()
            except OSError:
                pass


class FakeAuth:
    def __init__(self, cfg):
        self.cfg, self.locked = cfg, False

    def storage_locked(self):
        return self.locked

    def domain_password_ok(self, user, password):
        return user == "anna" and password == "pw"

    def domain_is_admin(self, user):
        return user == "anna"

    def local_password_ok(self, user, password):
        return user == "adminuser" and password == "local pw"


class Base(unittest.TestCase):
    terminal = True

    def setUp(self):
        FakeMaster.made = []
        self.tmp = tempfile.mkdtemp()
        with open(os.path.join(self.tmp, "index.html"), "w") as f:
            f.write("<html>app</html>")
        cfg = ws.Config()
        cfg.root, cfg.workgroup, cfg.realm, cfg.fail_delay = self.tmp, "HOME", "ad.home.lan", 0
        cfg.hs = "/nonexistent/hs"
        cfg.terminal = self.terminal
        cfg.term_check = 0.1
        self.cfg, self.auth = cfg, FakeAuth(cfg)
        self.app = ws.App(cfg, self.auth)
        self.app.term_spawn = lambda target, name=None: FakeMaster()
        self.srv = ws.Server(("127.0.0.1", 0), ws.make_handler(self.app))
        self.port = self.srv.server_address[1]
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.socks = []

    def tearDown(self):
        for s in self.socks:
            s.close()
        self.srv.shutdown()
        self.srv.server_close()

    # --- http
    def req(self, method, path, body=None, headers=None, cookie=None, origin=True, csrf=None):
        c = http.client.HTTPConnection("127.0.0.1", self.port)
        h = dict(headers or {})
        if body is not None:
            h["Content-Type"] = "application/json"
        if origin:
            h["Origin"] = "http://127.0.0.1:%d" % self.port
        if cookie:
            h["Cookie"] = "hs_session=" + cookie
        if csrf:
            h["X-CSRF-Token"] = csrf
        c.request(method, path, json.dumps(body) if body is not None else None, h)
        r = c.getresponse()
        data = r.read()
        c.close()
        try:
            obj = json.loads(data)
        except ValueError:
            obj = None
        return r.status, obj, r

    def login(self, realm="local", user="adminuser", pw="local pw"):
        st, obj, r = self.req("POST", "/api/login", {"realm": realm, "user": user, "password": pw})
        self.assertEqual(st, 200, obj)
        cookie = r.getheader("Set-Cookie").split(";")[0].split("=", 1)[1]
        return cookie, obj["csrf"], obj

    def ticket(self, cookie, csrf, target="host"):
        st, obj, _ = self.req("POST", "/api/terminal", {"target": target}, cookie=cookie, csrf=csrf)
        self.assertEqual(st, 200, obj)
        return obj["ticket"]

    # --- websocket
    def upgrade(self, ticket, cookie, origin="same", key="dGhlIHNhbXBsZSBub25jZQ==", host=None, extra=""):
        s = socket.create_connection(("127.0.0.1", self.port), timeout=5)
        self.socks.append(s)
        host = host or "127.0.0.1:%d" % self.port
        lines = ["GET /api/terminal/ws?ticket=%s HTTP/1.1" % ticket, "Host: " + host, "Upgrade: websocket", "Connection: Upgrade",
                 "Sec-WebSocket-Version: 13"]
        if key:
            lines.append("Sec-WebSocket-Key: " + key)
        if origin == "same":
            lines.append("Origin: http://" + host)
        elif origin:
            lines.append("Origin: " + origin)
        if cookie:
            lines.append("Cookie: hs_session=" + cookie)
        s.sendall(("\r\n".join(lines) + "\r\n" + extra + "\r\n").encode())
        buf = b""
        while b"\r\n\r\n" not in buf:
            d = s.recv(4096)
            if not d:
                break
            buf += d
        head, _, rest = buf.partition(b"\r\n\r\n")
        status = int(head.split()[1])
        return s, status, head.decode(), rest

    def open_ws(self, cookie, csrf, target="host"):
        s, status, head, rest = self.upgrade(self.ticket(cookie, csrf, target), cookie)
        self.assertEqual(status, 101, head)
        return s, head, rest


# ─────────────────────────── framing ───────────────────────────
class Framing(unittest.TestCase):
    def feed(self, *chunks, **kw):
        p = wt.Parser(**kw)
        out = []
        for c in chunks:
            out += p.feed(c)
        return out

    def test_accept_key_is_the_rfc_example(self):
        self.assertEqual(wt.accept_key("dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")

    def test_key_shape(self):
        self.assertTrue(wt.valid_key("dGhlIHNhbXBsZSBub25jZQ=="))
        for bad in ("", "abc", "dGhlIHNhbXBsZSBub25jZQ", "!!!!!!!!!!!!!!!!!!!!!!=="):
            self.assertFalse(wt.valid_key(bad), bad)

    def test_masked_text_and_binary(self):
        self.assertEqual(self.feed(mask_frame(wt.OP_TEXT, b"hi")), [(wt.OP_TEXT, b"hi")])
        self.assertEqual(self.feed(mask_frame(wt.OP_BINARY, b"\x00\xff")), [(wt.OP_BINARY, b"\x00\xff")])

    def test_unmasked_is_refused(self):
        with self.assertRaises(wt.ProtocolError) as cm:
            self.feed(mask_frame(wt.OP_BINARY, b"x", masked=False))
        self.assertEqual(cm.exception.code, 1002)

    def test_lengths(self):
        for n in (0, 125, 126, 127, 65535, 65536):
            data = bytes(i % 251 for i in range(n))
            self.assertEqual(self.feed(mask_frame(wt.OP_BINARY, data)), [(wt.OP_BINARY, data)], n)

    def test_oversize_is_1009_before_the_payload_arrives(self):
        with self.assertRaises(wt.ProtocolError) as cm:
            self.feed(mask_frame(wt.OP_BINARY, b"", length=65537)[:10])
        self.assertEqual(cm.exception.code, 1009)
        with self.assertRaises(wt.ProtocolError) as cm:
            self.feed(mask_frame(wt.OP_BINARY, b"", length=2 ** 40)[:10])
        self.assertEqual(cm.exception.code, 1009)

    def test_oversize_by_fragments(self):
        p = wt.Parser(max_frame=10)
        p.feed(mask_frame(wt.OP_BINARY, b"123456", fin=False))
        with self.assertRaises(wt.ProtocolError) as cm:
            p.feed(mask_frame(wt.OP_CONT, b"123456"))
        self.assertEqual(cm.exception.code, 1009)

    def test_split_across_reads(self):
        raw = mask_frame(wt.OP_BINARY, b"abcdef")
        self.assertEqual(self.feed(*[raw[i:i + 1] for i in range(len(raw))]), [(wt.OP_BINARY, b"abcdef")])

    def test_two_frames_in_one_read(self):
        self.assertEqual(self.feed(mask_frame(wt.OP_BINARY, b"a") + mask_frame(wt.OP_BINARY, b"b")), [(wt.OP_BINARY, b"a"), (wt.OP_BINARY, b"b")])

    def test_fragmentation_with_a_ping_between(self):
        out = self.feed(mask_frame(wt.OP_BINARY, b"ab", fin=False), mask_frame(wt.OP_PING, b"p"), mask_frame(wt.OP_CONT, b"cd", fin=False),
                        mask_frame(wt.OP_CONT, b"ef"))
        self.assertEqual(out, [(wt.OP_PING, b"p"), (wt.OP_BINARY, b"abcdef")])

    def test_continuation_without_start_and_nested_start(self):
        with self.assertRaises(wt.ProtocolError):
            self.feed(mask_frame(wt.OP_CONT, b"x"))
        with self.assertRaises(wt.ProtocolError):
            self.feed(mask_frame(wt.OP_BINARY, b"x", fin=False), mask_frame(wt.OP_TEXT, b"y"))

    def test_control_frames(self):
        self.assertEqual(self.feed(mask_frame(wt.OP_PONG, b"z")), [(wt.OP_PONG, b"z")])
        self.assertEqual(self.feed(mask_frame(wt.OP_CLOSE, struct.pack(">H", 1000))), [(wt.OP_CLOSE, struct.pack(">H", 1000))])
        with self.assertRaises(wt.ProtocolError):
            self.feed(mask_frame(wt.OP_PING, b"x" * 126))
        with self.assertRaises(wt.ProtocolError):
            self.feed(mask_frame(wt.OP_PING, b"x", fin=False))

    def test_bad_opcodes_and_reserved_bits(self):
        for op in (3, 4, 7, 0xB, 0xF):
            with self.assertRaises(wt.ProtocolError, msg=op):
                self.feed(mask_frame(op, b"x"))
        with self.assertRaises(wt.ProtocolError):
            self.feed(mask_frame(wt.OP_BINARY, b"x", rsv=0x40))

    def test_text_must_be_utf8(self):
        with self.assertRaises(wt.ProtocolError) as cm:
            self.feed(mask_frame(wt.OP_TEXT, b"\xff\xfe"))
        self.assertEqual(cm.exception.code, 1007)

    def test_encode_frame_lengths(self):
        self.assertEqual(wt.encode_frame(wt.OP_BINARY, b"ab"), b"\x82\x02ab")
        self.assertEqual(wt.encode_frame(wt.OP_BINARY, b"x" * 126)[:4], b"\x82\x7e\x00\x7e")
        self.assertEqual(wt.encode_frame(wt.OP_BINARY, b"x" * 65536)[:10], b"\x82\x7f" + struct.pack(">Q", 65536))

    def test_resize_bounds(self):
        ok = lambda c, r: wt.parse_control(json.dumps({"type": "resize", "cols": c, "rows": r}))
        self.assertEqual(ok(80, 24), ("resize", 80, 24))
        self.assertEqual(ok(1, 1), ("resize", 1, 1))
        self.assertEqual(ok(500, 200), ("resize", 500, 200))
        for c, r in ((0, 24), (80, 0), (501, 24), (80, 201), (-1, 5), (1.5, 5), ("80", 24), (True, 24), (None, 24)):
            self.assertIsNone(ok(c, r), (c, r))
        for junk in ("nope", "[]", "{}", '{"type":"other","cols":80,"rows":24}', '{"type":"resize"}', '"resize"'):
            self.assertIsNone(wt.parse_control(junk), junk)

    def test_csp_connect(self):
        self.assertEqual(wt.csp_connect("hs.local:8480", False), "'self' wss://hs.local:8480 ws://hs.local:8480")
        self.assertEqual(wt.csp_connect("hs.tail.ts.net", True), "'self' wss://hs.tail.ts.net")
        self.assertIn("[::1]:8480", wt.csp_connect("[::1]:8480", False))
        for bad in ("", "a b", "evil.com;script-src *", "a/b", "*.x.com", "x.com:99999999", "h'ost", "a,b"):
            self.assertEqual(wt.csp_connect(bad, False), "'self'", bad)


# ─────────────────────────── tickets ───────────────────────────
class Tickets(unittest.TestCase):
    def test_one_use(self):
        t = wt.Terminals()
        k = t.issue("sess", "host")
        self.assertEqual(t.redeem(k, "sess"), "host")
        self.assertIsNone(t.redeem(k, "sess"))

    def test_expiry(self):
        t = wt.Terminals(ttl=0.05)
        k = t.issue("sess", "host")
        time.sleep(0.1)
        self.assertIsNone(t.redeem(k, "sess"))

    def test_bound_to_session_and_burnt_by_a_wrong_try(self):
        t = wt.Terminals()
        k = t.issue("a", "host")
        self.assertIsNone(t.redeem(k, "b"))
        self.assertIsNone(t.redeem(k, "a"))          # the wrong try used it up
        self.assertIsNone(t.redeem("nonsense", "a"))
        self.assertIsNone(t.redeem(None, "a"))
        self.assertIsNone(t.redeem(t.issue("a", "x"), ""))

    def test_target_is_kept(self):
        t = wt.Terminals()
        self.assertEqual(t.redeem(t.issue("a", "jellyfin"), "a"), "jellyfin")

    def test_targets(self):
        for ok in ("host", "jellyfin", "dc1", "a-b-c"):
            self.assertTrue(wt.valid_target(ok), ok)
        for bad in ("", "../x", "a b", "Host", "UPPER", "1abc", "-x", "a/b", "a" * 42, None, 5, ["host"]):
            self.assertFalse(wt.valid_target(bad), bad)

    def test_limits(self):
        t = wt.Terminals()
        self.assertTrue(t.acquire("a"))
        self.assertTrue(t.acquire("a"))
        self.assertFalse(t.acquire("a"))             # 2 per session
        self.assertTrue(t.acquire("b"))
        self.assertTrue(t.acquire("b"))
        self.assertFalse(t.acquire("c"))             # 4 in total
        t.release("a")
        self.assertTrue(t.acquire("c"))

    def test_pending_tickets_are_capped(self):
        t = wt.Terminals()
        got = [t.issue("a", "host") for _ in range(wt.MAX_PENDING + 3)]
        self.assertEqual(got.count(None), 3)


# ─────────────────────────── the command line ───────────────────────────
class Command(unittest.TestCase):
    def test_host(self):
        argv = wt.build_command("host", "adminuser", "/home/adminuser", "/run/current-system/sw/bin/zsh", "hs-web-term-ab12")
        self.assertEqual(argv, ["systemd-run", "--quiet", "--pty", "--collect", "--wait", "--send-sighup", "--unit", "hs-web-term-ab12",
                                "-p", "User=adminuser", "-p", "WorkingDirectory=/home/adminuser", "-E", "TERM=xterm-256color", "--",
                                "/run/current-system/sw/bin/zsh", "-l"])

    def test_instance(self):
        argv = wt.build_command("jellyfin", "adminuser", "/home/adminuser", "/bin/zsh", "u", incus="/x/incus")
        i = argv.index("--")
        self.assertEqual(argv[i + 1:i + 6], ["/x/incus", "exec", "jellyfin", "--", "sh"])
        self.assertIn("exec bash -l", argv[-1])
        self.assertIn("exec sh -l", argv[-1])
        self.assertNotIn("root", " ".join(argv[:i]).replace("--", ""))

    def test_persistent_session(self):
        name = wt.session_name("Wolf.gang", "host")
        self.assertEqual(name, "w-Wolf_gang-host")
        argv = wt.build_command("host", "adminuser", "/home/adminuser", "/bin/zsh", "u", name=name, tmux="/x/tmux")
        i = argv.index("--")
        self.assertEqual(argv[i + 1:i + 3], ["sh", "-c"])
        script = argv[-1]
        self.assertIn("exec /x/tmux -L hs-web new-session -A -s w-Wolf_gang-host", script)
        self.assertIn("'/bin/zsh -l'", script)
        self.assertIn("\; set -g status off", script)


# ─────────────────────────── the sign-in glue ───────────────────────────
class Ticket(Base):
    def test_features_in_login_and_session(self):
        cookie, csrf, obj = self.login()
        self.assertEqual({k: obj["features"][k] for k in ("terminal", "vps")}, {"terminal": True, "vps": False})
        self.assertIsInstance(obj["features"]["capabilities"], list)   # host-dependent (/etc/hs/capabilities)
        st, obj, _ = self.req("GET", "/api/session", cookie=cookie)
        self.assertEqual({k: obj["features"][k] for k in ("terminal", "vps")}, {"terminal": True, "vps": False})
        self.assertIsInstance(obj["features"]["capabilities"], list)   # host-dependent (/etc/hs/capabilities)

    def test_ticket_rules(self):
        cookie, csrf, _ = self.login()
        self.assertEqual(self.req("POST", "/api/terminal", {"target": "host"}, csrf=csrf)[0], 401)
        self.assertEqual(self.req("POST", "/api/terminal", {"target": "host"}, cookie=cookie)[0], 403)                       # no CSRF token
        self.assertEqual(self.req("POST", "/api/terminal", {"target": "host"}, cookie=cookie, csrf="wrong")[0], 403)
        self.assertEqual(self.req("POST", "/api/terminal", {"target": "host"}, cookie=cookie, csrf=csrf, origin=False)[0], 403)
        self.assertEqual(self.req("POST", "/api/terminal", {"target": "host"}, cookie=cookie, csrf=csrf, origin=False, headers={"Origin": "http://evil.example"})[0], 403)
        for bad in ("", "../x", "a b", "HOST", "Jelly", None, 5):
            self.assertEqual(self.req("POST", "/api/terminal", {"target": bad}, cookie=cookie, csrf=csrf)[0], 400, bad)
        self.assertEqual(self.req("POST", "/api/terminal", {}, cookie=cookie, csrf=csrf)[0], 400)
        self.assertEqual(self.req("POST", "/api/terminal", {"target": "host"}, cookie=cookie, csrf=csrf)[0], 200)
        c = http.client.HTTPConnection("127.0.0.1", self.port)           # not JSON
        c.request("POST", "/api/terminal", b"x", {"Origin": "http://127.0.0.1:%d" % self.port, "Cookie": "hs_session=" + cookie, "X-CSRF-Token": csrf})
        self.assertEqual(c.getresponse().status, 400)

    def test_instance_ticket_refused_while_locked_host_still_works(self):
        cookie, csrf, _ = self.login()
        self.auth.locked = True
        st, obj, _ = self.req("POST", "/api/terminal", {"target": "jellyfin"}, cookie=cookie, csrf=csrf)
        self.assertEqual(st, 409)
        self.assertEqual(self.req("POST", "/api/terminal", {"target": "host"}, cookie=cookie, csrf=csrf)[0], 200)

    def test_domain_session_cannot_open_while_locked(self):
        cookie, csrf, _ = self.login("domain", "anna", "pw")
        self.auth.locked = True
        self.assertEqual(self.req("POST", "/api/terminal", {"target": "host"}, cookie=cookie, csrf=csrf)[0], 401)

    def test_csp_names_this_host_only(self):
        st, obj, r = self.req("GET", "/api/hello", headers={"Host": "hs.example:8480"})
        csp = r.getheader("Content-Security-Policy")
        self.assertIn("connect-src 'self' wss://hs.example:8480 ws://hs.example:8480;", csp)
        st, obj, r = self.req("GET", "/api/hello", headers={"Host": "evil.com;script-src *"})
        self.assertIn("connect-src 'self';", r.getheader("Content-Security-Policy"))


class Off(Base):
    terminal = False

    def test_everything_is_refused_and_features_say_so(self):
        cookie, csrf, obj = self.login()
        self.assertEqual({k: obj["features"][k] for k in ("terminal", "vps")}, {"terminal": False, "vps": False})
        self.assertIsInstance(obj["features"]["capabilities"], list)   # host-dependent (/etc/hs/capabilities)
        self.assertEqual(self.req("POST", "/api/terminal", {"target": "host"}, cookie=cookie, csrf=csrf)[0], 403)
        s, status, head, _ = self.upgrade("x", cookie)
        self.assertEqual(status, 403)
        st, obj, r = self.req("GET", "/api/hello")
        self.assertIn("connect-src 'self';", r.getheader("Content-Security-Policy"))


# ─────────────────────────── the upgrade ───────────────────────────
class Upgrade(Base):
    def test_refusals(self):
        cookie, csrf, _ = self.login()
        t = lambda: self.ticket(cookie, csrf)
        self.assertEqual(self.upgrade("nope", cookie)[1], 403)                                  # unknown ticket
        self.assertEqual(self.upgrade("", cookie)[1], 403)
        self.assertEqual(self.upgrade(t(), None)[1], 403)                                       # no session cookie
        self.assertEqual(self.upgrade(t(), cookie, origin=None)[1], 403)                        # no Origin
        self.assertEqual(self.upgrade(t(), cookie, origin="http://evil.example")[1], 403)       # wrong Origin
        self.assertEqual(self.upgrade(t(), cookie, key=None)[1], 400)                           # no key
        self.assertEqual(self.upgrade(t(), cookie, key="short")[1], 400)
        other, ocsrf, _ = self.login()
        self.assertEqual(self.upgrade(t(), other)[1], 403)                                      # ticket of another session
        self.assertEqual(FakeMaster.made, [])

    def test_no_upgrade_headers(self):
        cookie, csrf, _ = self.login()
        c = http.client.HTTPConnection("127.0.0.1", self.port)
        c.request("GET", "/api/terminal/ws?ticket=" + self.ticket(cookie, csrf), headers={"Origin": "http://127.0.0.1:%d" % self.port, "Cookie": "hs_session=" + cookie})
        self.assertEqual(c.getresponse().status, 400)

    def test_ticket_is_one_use_on_the_wire(self):
        cookie, csrf, _ = self.login()
        k = self.ticket(cookie, csrf)
        s, status, head, _ = self.upgrade(k, cookie)
        self.assertEqual(status, 101)
        self.assertEqual(self.upgrade(k, cookie)[1], 403)

    def test_expired_ticket(self):
        self.app.terminals.ttl = 0.05
        cookie, csrf, _ = self.login()
        k = self.ticket(cookie, csrf)
        time.sleep(0.15)
        self.assertEqual(self.upgrade(k, cookie)[1], 403)

    def test_session_ended_between_ticket_and_upgrade(self):
        cookie, csrf, _ = self.login()
        k = self.ticket(cookie, csrf)
        self.req("POST", "/api/logout", {}, cookie=cookie, csrf=csrf)
        self.assertEqual(self.upgrade(k, cookie)[1], 403)

    def test_locked_instance_refused_at_upgrade(self):
        cookie, csrf, _ = self.login()
        k = self.ticket(cookie, csrf, "jellyfin")
        self.auth.locked = True
        self.assertEqual(self.upgrade(k, cookie)[1], 409)

    def test_handshake_and_echo(self):
        cookie, csrf, _ = self.login()
        s, head, rest = self.open_ws(cookie, csrf)
        self.assertIn("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", head)
        s.sendall(rest and b"" or b"")
        read_until(s, b"homeserver:~$ ")
        s.sendall(mask_frame(wt.OP_BINARY, b"ls\r"))
        self.assertIn(b"ls\r", read_until(s, b"ls\r"))
        s.sendall(mask_frame(wt.OP_PING, b"hey"))
        while True:
            op, data = read_frame(s)
            if op == wt.OP_PONG:
                self.assertEqual(data, b"hey")
                break
        self.assertEqual(len(FakeMaster.made), 1)

    def test_resize_reaches_the_shell_and_junk_does_not(self):
        cookie, csrf, _ = self.login()
        s, _, _ = self.open_ws(cookie, csrf)
        m = FakeMaster.made[0]
        for msg in ({"type": "resize", "cols": 100, "rows": 30}, {"type": "resize", "cols": 0, "rows": 30}, {"type": "resize", "cols": 9999, "rows": 3},
                    {"type": "other"}, {"type": "resize", "cols": "80", "rows": 24}):
            s.sendall(mask_frame(wt.OP_TEXT, json.dumps(msg).encode()))
        s.sendall(mask_frame(wt.OP_TEXT, b"not json"))
        s.sendall(mask_frame(wt.OP_BINARY, b"sync\r"))
        read_until(s, b"sync\r")
        self.assertEqual(m.resizes, [(100, 30)])

    def test_unmasked_frame_ends_with_1002_and_the_shell_is_closed(self):
        cookie, csrf, _ = self.login()
        s, _, _ = self.open_ws(cookie, csrf)
        s.sendall(mask_frame(wt.OP_BINARY, b"x", masked=False))
        while True:
            op, data = read_frame(s)
            if op == wt.OP_CLOSE:
                self.assertEqual(struct.unpack(">H", data[:2])[0], 1002)
                break
        self.assertTrue(FakeMaster.made[0].closed.wait(3))

    def test_client_close_is_answered_and_cleans_up(self):
        cookie, csrf, _ = self.login()
        s, _, _ = self.open_ws(cookie, csrf)
        s.sendall(mask_frame(wt.OP_CLOSE, struct.pack(">H", 1000)))
        while True:
            op, data = read_frame(s)
            if op == wt.OP_CLOSE:
                break
        self.assertTrue(FakeMaster.made[0].closed.wait(3))

    def test_dropped_connection_cleans_up(self):
        cookie, csrf, _ = self.login()
        s, _, _ = self.open_ws(cookie, csrf)
        s.close()
        self.assertTrue(FakeMaster.made[0].closed.wait(3))

    def test_shell_exit_closes_the_socket_normally(self):
        cookie, csrf, _ = self.login()
        s, _, _ = self.open_ws(cookie, csrf)
        FakeMaster.made[0].b.shutdown(socket.SHUT_RDWR)            # the shell ends (close() alone would not signal EOF while _echo is blocked in recv)
        while True:
            op, data = read_frame(s)
            if op == wt.OP_CLOSE:
                self.assertEqual(struct.unpack(">H", data[:2])[0], 1000)
                break

    def test_instance_target_is_passed_to_spawn(self):
        seen = []
        self.app.term_spawn = lambda target, name=None: (seen.append(target), FakeMaster())[1]
        cookie, csrf, _ = self.login()
        self.open_ws(cookie, csrf, "jellyfin")
        self.assertEqual(seen, ["jellyfin"])

    def test_spawn_failure_is_a_500_and_frees_the_slot(self):
        def boom(target):
            raise OSError("no systemd-run")
        self.app.term_spawn = boom
        cookie, csrf, _ = self.login()
        s, status, head, _ = self.upgrade(self.ticket(cookie, csrf), cookie)
        self.assertEqual(status, 500)
        deadline = time.time() + 3
        while time.time() < deadline and self.app.terminals.open:
            time.sleep(0.02)
        self.assertEqual(self.app.terminals.open, {})

    def test_limits_two_per_session_four_in_total(self):
        cookie, csrf, _ = self.login()
        a = [self.open_ws(cookie, csrf)[0] for _ in range(2)]
        s, status, head, _ = self.upgrade(self.ticket(cookie, csrf), cookie)
        self.assertEqual(status, 429)
        c2, csrf2, _ = self.login()
        [self.open_ws(c2, csrf2)[0] for _ in range(2)]
        c3, csrf3, _ = self.login()
        self.assertEqual(self.upgrade(self.ticket(c3, csrf3), c3)[1], 429)
        a[0].close()                                      # a slot frees up again
        deadline = time.time() + 3
        while time.time() < deadline and self.app.terminals.open.get(cookie, 0) > 1:
            time.sleep(0.02)
        self.assertEqual(self.upgrade(self.ticket(c3, csrf3), c3)[1], 101)

    def test_idle_timeout(self):
        self.cfg.term_idle = 0.4
        cookie, csrf, _ = self.login()
        s, _, _ = self.open_ws(cookie, csrf)
        while True:
            op, data = read_frame(s)
            if op == wt.OP_CLOSE:
                self.assertEqual(struct.unpack(">H", data[:2])[0], wt.CLOSE_IDLE)
                break
        self.assertTrue(FakeMaster.made[0].closed.wait(3))

    def test_typing_keeps_it_alive(self):
        self.cfg.term_idle = 0.6
        cookie, csrf, _ = self.login()
        s, _, _ = self.open_ws(cookie, csrf)
        for _ in range(5):
            time.sleep(0.25)
            s.sendall(mask_frame(wt.OP_BINARY, b"k"))
        read_until(s, b"kkkkk")
        self.assertFalse(FakeMaster.made[0].closed.is_set())

    def test_lifetime_limit(self):
        self.cfg.term_max = 0.4
        cookie, csrf, _ = self.login()
        s, _, _ = self.open_ws(cookie, csrf)
        while True:
            op, data = read_frame(s)
            if op == wt.OP_CLOSE:
                self.assertEqual(struct.unpack(">H", data[:2])[0], wt.CLOSE_LIFETIME)
                break

    def test_logout_ends_the_terminal(self):
        cookie, csrf, _ = self.login()
        s, _, _ = self.open_ws(cookie, csrf)
        self.assertEqual(self.req("POST", "/api/logout", {}, cookie=cookie, csrf=csrf)[0], 200)
        while True:
            op, data = read_frame(s)
            if op == wt.OP_CLOSE:
                self.assertEqual(struct.unpack(">H", data[:2])[0], wt.CLOSE_SESSION)
                break
        self.assertTrue(FakeMaster.made[0].closed.wait(3))

    def test_session_expiry_ends_the_terminal(self):
        cookie, csrf, _ = self.login()
        s, _, _ = self.open_ws(cookie, csrf)
        self.app.sessions.items[cookie]["created"] -= self.cfg.max_age + 10
        while True:
            op, data = read_frame(s)
            if op == wt.OP_CLOSE:
                self.assertEqual(struct.unpack(">H", data[:2])[0], wt.CLOSE_SESSION)
                break

    def test_domain_session_ends_when_the_storage_locks(self):
        cookie, csrf, _ = self.login("domain", "anna", "pw")
        s, _, _ = self.open_ws(cookie, csrf)
        self.auth.locked = True
        while True:
            op, data = read_frame(s)
            if op == wt.OP_CLOSE:
                self.assertEqual(struct.unpack(">H", data[:2])[0], wt.CLOSE_SESSION)
                break

    def test_instance_terminal_ends_when_the_storage_locks_host_one_does_not(self):
        cookie, csrf, _ = self.login()
        h, _, _ = self.open_ws(cookie, csrf, "host")
        i, _, _ = self.open_ws(cookie, csrf, "jellyfin")
        self.auth.locked = True
        while True:
            op, data = read_frame(i)
            if op == wt.OP_CLOSE:
                break
        h.sendall(mask_frame(wt.OP_BINARY, b"still\r"))
        read_until(h, b"still\r")

    def test_an_open_terminal_does_not_refresh_the_web_session(self):
        cookie, csrf, _ = self.login()
        self.open_ws(cookie, csrf)
        seen = self.app.sessions.items[cookie]["seen"]
        time.sleep(0.5)
        self.assertEqual(self.app.sessions.items[cookie]["seen"], seen)


if __name__ == "__main__":
    unittest.main()
