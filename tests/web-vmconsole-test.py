#!/usr/bin/env python3
"""scripts/web_vmconsole.py + the console glue in scripts/web-serve.py (ADR 0021): the Incus VGA console fetched through a FAKE Incus API
(no incus, no unix socket), the ticket rules, the upgrade against the real server on a free port, and the relay between the browser
WebSocket and the stream "from Incus" (a socketpair that answers). NOT VERIFIED against a real Incus VM."""
import importlib.util
import os
import socket
import struct
import sys
import threading
import time
import unittest

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("web_terminal_test", os.path.join(here, "web-terminal-test.py"))
tt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tt)
vc, wt = tt.ws.vc, tt.wt
OP = "/1.0/operations/0b1c2d3e-0000-4000-8000-123456789abc"


class FakeIncus:
    """The two calls web_vmconsole makes. The stream side answers every binary message with b"echo:" + message, unmasked."""
    instances = {"win11": ("virtual-machine", "Running"), "off-vm": ("virtual-machine", "Stopped"), "jellyfin": ("container", "Running")}

    def __init__(self):
        self.calls, self.sent, self.sockets, self.secrets = [], [], [], {}

    def call(self, method, path, body=None):
        self.calls.append((method, path, body))
        if method == "GET":
            t = self.instances.get(path.rsplit("/", 1)[1])
            if not t:
                return {"type": "error", "status_code": 404, "error": "not found"}
            return {"type": "sync", "status_code": 200, "metadata": {"type": t[0], "status": t[1]}}
        return {"type": "async", "operation": OP, "metadata": {"metadata": {"fds": {"0": "datasecret1", "control": "ctlsecret1"}}}}

    def websocket(self, path):
        self.calls.append(("WS", path, None))
        a, b = socket.socketpair()
        self.sockets.append(b)
        threading.Thread(target=self._peer, args=(path, b), daemon=True).start()
        return a, b""

    def _peer(self, path, s):
        parser = wt.Parser()
        try:
            while True:
                d = s.recv(65536)
                if not d:
                    return
                for op, payload in parser.feed(d):          # client frames to Incus are masked, so wt.Parser reads them
                    self.sent.append((path, op, payload))
                    if op == wt.OP_BINARY and "datasecret1" in path:
                        s.sendall(wt.encode_frame(wt.OP_BINARY, b"echo:" + payload))
        except (OSError, wt.ProtocolError):
            pass


class Base(tt.Base):
    def setUp(self):
        super().setUp()
        self.incus = self.app.incus = FakeIncus()

    def vticket(self, cookie, csrf, target="win11", expect=200):
        st, obj, _ = self.req("POST", "/api/vmconsole", {"target": target}, cookie=cookie, csrf=csrf)
        self.assertEqual(st, expect, obj)
        return obj.get("ticket")

    def vupgrade(self, ticket, cookie, **kw):
        # like Base.upgrade, with the console path -> (socket, status)
        s = socket.create_connection(("127.0.0.1", self.port), timeout=5)
        self.socks.append(s)
        host = "127.0.0.1:%d" % self.port
        lines = ["GET /api/vmconsole/ws?ticket=%s HTTP/1.1" % ticket, "Host: " + host, "Upgrade: websocket", "Connection: Upgrade",
                 "Sec-WebSocket-Version: 13", "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==", "Origin: " + kw.get("origin", "http://" + host)]
        if cookie:
            lines.append("Cookie: hs_session=" + cookie)
        s.sendall(("\r\n".join(lines) + "\r\n\r\n").encode())
        buf = b""
        while b"\r\n\r\n" not in buf:
            d = s.recv(4096)
            if not d:
                break
            buf += d
        head = buf.partition(b"\r\n\r\n")[0]
        return s, int(head.split()[1])


class Client(unittest.TestCase):
    def test_client_frames_are_masked_and_parse(self):
        for n in (0, 5, 125, 126, 70000):
            f = vc.client_frame(wt.OP_BINARY, b"x" * n)
            self.assertTrue(f[1] & 0x80)
            self.assertEqual(wt.Parser(max_frame=80000).feed(f), [(wt.OP_BINARY, b"x" * n)])

    def test_server_parser(self):
        p = vc.ServerParser()
        two = wt.encode_frame(wt.OP_BINARY, b"abc") + wt.encode_frame(wt.OP_PING, b"p")
        out = []
        for i in range(len(two)):                       # byte by byte
            out += p.feed(two[i:i + 1])
        self.assertEqual(out, [(wt.OP_BINARY, b"abc"), (wt.OP_PING, b"p")])
        frag = bytes([0x02, 2]) + b"ab" + bytes([0x80, 2]) + b"cd"
        self.assertEqual(vc.ServerParser().feed(frag), [(wt.OP_BINARY, b"abcd")])

    def test_server_parser_refuses(self):
        for bad in (b"\x82\x81\x00\x00\x00\x00x",        # masked
                    b"\xf2\x00",                          # reserved bits
                    b"\x83\x00",                          # bad opcode
                    b"\x00\x00",                          # continuation without start
                    b"\x89\x7e\x00\x80"):                 # control frame too long
            with self.assertRaises(wt.ProtocolError):
                vc.ServerParser().feed(bad)
        with self.assertRaises(wt.ProtocolError):
            vc.ServerParser(limit=10).feed(wt.encode_frame(wt.OP_BINARY, b"x" * 11))


class Api(unittest.TestCase):
    def test_check_vm(self):
        api = FakeIncus()
        vc.check_vm(api, "win11")
        for name, status in (("off-vm", 409), ("jellyfin", 409), ("ghost", 404), ("Bad Name", 400), ("../x", 400), (None, 400), ("", 400)):
            with self.assertRaises(vc.ConsoleError) as cm:
                vc.check_vm(api, name)
            self.assertEqual(cm.exception.status, status, name)

    def test_open_console_asks_for_vga_and_uses_the_secrets(self):
        api = FakeIncus()
        data, control = vc.open_console(api, "win11")
        post = [c for c in api.calls if c[0] == "POST"][0]
        self.assertEqual(post[1:], ("/1.0/instances/win11/console", {"type": "vga", "width": 0, "height": 0}))
        ws_paths = [c[1] for c in api.calls if c[0] == "WS"]
        self.assertEqual(ws_paths, [OP + "/websocket?secret=ctlsecret1", OP + "/websocket?secret=datasecret1"])

    def test_open_console_refuses_odd_answers(self):
        class Odd(FakeIncus):
            def __init__(self, ans):
                super().__init__()
                self.ans = ans

            def call(self, method, path, body=None):
                return super().call(method, path, body) if method == "GET" else self.ans
        for ans in ({}, {"operation": "/evil", "metadata": {"metadata": {"fds": {"0": "datasecret1", "control": "ctlsecret1"}}}},
                    {"operation": OP, "metadata": {"metadata": {"fds": {"0": "a b&x=1", "control": "ctlsecret1"}}}},
                    {"operation": OP, "metadata": {"metadata": {"fds": {"0": "datasecret1"}}}}):
            with self.assertRaises(vc.ConsoleError):
                vc.open_console(Odd(ans), "win11")


class UnixSocket(unittest.TestCase):
    """IncusApi against a tiny HTTP server on a real unix socket (what Incus does: JSON answers and the 101 upgrade)."""

    def setUp(self):
        import tempfile
        self.dir = tempfile.mkdtemp()
        self.path = os.path.join(self.dir, "u.sock")
        self.srv = socket.socket(socket.AF_UNIX)
        self.srv.bind(self.path)
        self.srv.listen(4)
        self.seen = []
        threading.Thread(target=self._serve, daemon=True).start()

    def tearDown(self):
        self.srv.close()

    def _serve(self):
        while True:
            try:
                c, _ = self.srv.accept()
            except OSError:
                return
            req = b""
            while b"\r\n\r\n" not in req:
                req += c.recv(4096)
            head = req.decode()
            self.seen.append(head.split("\r\n")[0])
            if "Upgrade: websocket" in head:
                key = [ln.split(": ")[1] for ln in head.split("\r\n") if ln.startswith("Sec-WebSocket-Key")][0]
                bad = "bad" in head.split("\r\n")[0]
                c.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n"
                           % ("nope" if bad else wt.accept_key(key))).encode() + wt.encode_frame(wt.OP_BINARY, b"hello"))
            else:
                body = b'{"type":"sync","metadata":{"type":"virtual-machine","status":"Running"}}'
                c.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % len(body) + body)
                c.close()

    def test_call(self):
        api = vc.IncusApi(self.path)
        self.assertEqual(api.call("GET", "/1.0/instances/win11")["metadata"]["type"], "virtual-machine")
        vc.check_vm(api, "win11")
        self.assertEqual(self.seen[0], "GET /1.0/instances/win11 HTTP/1.1")

    def test_websocket_handshake_keeps_early_bytes(self):
        s, rest = vc.IncusApi(self.path).websocket("/1.0/operations/x/websocket?secret=abc")
        s.close()
        self.assertEqual(vc.ServerParser().feed(rest), [(wt.OP_BINARY, b"hello")])

    def test_websocket_wrong_accept_is_refused(self):
        with self.assertRaises(vc.ConsoleError):
            vc.IncusApi(self.path).websocket("/bad")


class Ticket(Base):
    def test_needs_session_and_csrf(self):
        self.assertEqual(self.req("POST", "/api/vmconsole", {"target": "win11"})[0], 401)
        cookie, csrf, _ = self.login()
        self.assertEqual(self.req("POST", "/api/vmconsole", {"target": "win11"}, cookie=cookie)[0], 403)
        self.assertEqual(self.req("POST", "/api/vmconsole", {"target": "win11"}, cookie=cookie, csrf=csrf, origin=False)[0], 403)

    def test_only_running_vms(self):
        cookie, csrf, _ = self.login()
        self.assertTrue(self.vticket(cookie, csrf))
        self.vticket(cookie, csrf, "jellyfin", 409)
        self.vticket(cookie, csrf, "off-vm", 409)
        self.vticket(cookie, csrf, "ghost", 404)
        self.vticket(cookie, csrf, "No Way", 400)
        self.assertFalse([c for c in self.incus.calls if c[0] in ("POST", "WS")])     # a ticket starts no console

    def test_locked_storage(self):
        cookie, csrf, _ = self.login()
        self.auth.locked = True
        self.vticket(cookie, csrf, expect=409)

    def test_incus_down(self):
        def boom(*a, **k):
            raise ConnectionRefusedError
        self.incus.call = boom
        cookie, csrf, _ = self.login()
        self.vticket(cookie, csrf, expect=502)


class Off(Base):
    terminal = False

    def test_switch_off(self):
        cookie, csrf, _ = self.login()
        self.vticket(cookie, csrf, expect=403)
        s, status = self.vupgrade("x", cookie)
        self.assertEqual(status, 403)


class Upgrade(Base):
    def test_refusals(self):
        cookie, csrf, _ = self.login()
        self.assertEqual(self.vupgrade("nope", cookie)[1], 403)
        self.assertEqual(self.vupgrade(self.vticket(cookie, csrf), None)[1], 403)                          # no cookie
        self.assertEqual(self.vupgrade(self.vticket(cookie, csrf), cookie, origin="http://evil.example")[1], 403)
        other, _, _ = self.login()
        self.assertEqual(self.vupgrade(self.vticket(cookie, csrf), other)[1], 403)                         # another session's ticket
        self.assertFalse([c for c in self.incus.calls if c[0] in ("POST", "WS")])                         # nothing reached Incus

    def test_terminal_ticket_does_not_open_a_console(self):
        cookie, csrf, _ = self.login()
        k = self.ticket(cookie, csrf)                      # a terminal ticket
        self.assertEqual(self.vupgrade(k, cookie)[1], 403)

    def test_ticket_one_use(self):
        cookie, csrf, _ = self.login()
        k = self.vticket(cookie, csrf)
        self.assertEqual(self.vupgrade(k, cookie)[1], 101)
        self.assertEqual(self.vupgrade(k, cookie)[1], 403)

    def test_stream_both_ways(self):
        cookie, csrf, _ = self.login()
        s, status = self.vupgrade(self.vticket(cookie, csrf), cookie)
        self.assertEqual(status, 101)
        s.sendall(tt.mask_frame(wt.OP_BINARY, b"RFB?"))
        op, data = tt.read_frame(s)
        self.assertEqual((op, data), (wt.OP_BINARY, b"echo:RFB?"))
        # the page's text messages are not forwarded
        s.sendall(tt.mask_frame(wt.OP_TEXT, b'{"type":"resize"}'))
        s.sendall(tt.mask_frame(wt.OP_PING, b"hey"))
        self.assertEqual(tt.read_frame(s), (wt.OP_PONG, b"hey"))
        sent = [x for x in self.incus.sent if x[1] == wt.OP_BINARY]
        self.assertEqual([x[2] for x in sent], [b"RFB?"])
        self.assertIn("datasecret1", sent[0][0])

    def test_client_close_closes_incus_streams(self):
        cookie, csrf, _ = self.login()
        s, status = self.vupgrade(self.vticket(cookie, csrf), cookie)
        s.sendall(tt.mask_frame(wt.OP_CLOSE, b"\x03\xe8"))
        self.assertEqual(tt.read_frame(s)[0], wt.OP_CLOSE)
        deadline = time.time() + 3
        while time.time() < deadline and not [x for x in self.incus.sent if x[1] == wt.OP_CLOSE]:
            time.sleep(0.05)
        self.assertTrue([x for x in self.incus.sent if x[1] == wt.OP_CLOSE])

    def test_incus_ends_the_console(self):
        cookie, csrf, _ = self.login()
        s, status = self.vupgrade(self.vticket(cookie, csrf), cookie)
        for sock in self.incus.sockets:
            sock.shutdown(socket.SHUT_RDWR)          # close() alone would not wake the peer thread blocked in recv
        self.assertEqual(tt.read_frame(s)[0], wt.OP_CLOSE)

    def test_session_ends_closes_the_console(self):
        cookie, csrf, _ = self.login()
        s, status = self.vupgrade(self.vticket(cookie, csrf), cookie)
        self.req("POST", "/api/logout", {}, cookie=cookie, csrf=csrf)
        op, data = tt.read_frame(s, 5)
        self.assertEqual(op, wt.OP_CLOSE)
        self.assertEqual(struct.unpack(">H", data[:2])[0], wt.CLOSE_SESSION)

    def test_limit_one_per_session(self):
        cookie, csrf, _ = self.login()
        s, status = self.vupgrade(self.vticket(cookie, csrf), cookie)
        self.assertEqual(status, 101)
        self.assertEqual(self.vupgrade(self.vticket(cookie, csrf), cookie)[1], 429)

    def test_idle_timeout(self):
        self.app.cfg.term_idle = 0.3
        cookie, csrf, _ = self.login()
        s, status = self.vupgrade(self.vticket(cookie, csrf), cookie)
        op, data = tt.read_frame(s, 5)
        self.assertEqual(struct.unpack(">H", data[:2])[0], wt.CLOSE_IDLE)

    def test_incus_refuses_the_console(self):
        cookie, csrf, _ = self.login()
        k = self.vticket(cookie, csrf)
        self.incus.instances = dict(self.incus.instances, win11=("virtual-machine", "Stopped"))      # stopped in between
        self.assertEqual(self.vupgrade(k, cookie)[1], 409)
        deadline = time.time() + 3
        while time.time() < deadline and self.app.vmconsoles.open:                                    # the handler releases after it answered
            time.sleep(0.02)
        self.assertEqual(self.app.vmconsoles.open, {})                                                # the slot is free again


if __name__ == "__main__":
    unittest.main()
