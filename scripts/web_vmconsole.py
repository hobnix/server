"""Graphical VM console for the web interface (used by web-serve.py), ADR 0021: the console of an Incus virtual machine (the SPICE stream
of its virtual graphics card) is fetched from Incus's own API over the local unix socket and relayed to the browser over one WebSocket.

No port of the VM is ever opened: Incus hands out a one-use secret per stream, the relay uses it on the unix socket, and the browser only
talks to hs-web, with the same rules as the browser terminal (signed in, CSRF, one-use ticket bound to the web session, same origin, limits,
idle and lifetime timeouts, closed when the web session ends). Nothing here logs the stream. Standard library only; the framing of the
browser side is shared with scripts/web_terminal.py. Everything that talks to Incus goes through an `api` object (IncusApi), so tests/
web-vmconsole-test.py runs the whole path with a fake. NOT VERIFIED against a real Incus VM yet.
"""
import base64
import json
import os
import re
import select
import socket
import struct
import time

import web_terminal as wt

INCUS_SOCKET = "/var/lib/incus/unix.socket"
MAX_UPSTREAM = 4 * 1024 * 1024       # one assembled message from Incus (a screen update); the browser side keeps wt.MAX_FRAME
MAX_TOTAL, MAX_PER_SESSION = 2, 1    # graphical consoles are heavy: fewer than terminals
OP_URL_RE = re.compile(r"^/1\.0/operations/[0-9a-f-]{36}$")
SECRET_RE = re.compile(r"^[A-Za-z0-9_-]{8,256}$")
valid_name = wt.valid_target


class ConsoleError(Exception):
    """A refusal with an HTTP status and a message that is safe to show the user."""

    def __init__(self, status, message):
        super().__init__(message)
        self.status, self.message = status, message


def consoles():
    """The ticket book for graphical consoles (own limits, separate from the terminals)."""
    return wt.Terminals(total=MAX_TOTAL, per_session=MAX_PER_SESSION)


# ─────────────────────────── a WebSocket client (towards Incus) ───────────────────────────
def client_frame(opcode, payload=b""):
    """A frame we send to Incus: masked, FIN set (RFC 6455: clients must mask)."""
    n = len(payload)
    head = bytes([0x80 | opcode])
    if n < 126:
        head += bytes([0x80 | n])
    elif n < 65536:
        head += bytes([0x80 | 126]) + struct.pack(">H", n)
    else:
        head += bytes([0x80 | 127]) + struct.pack(">Q", n)
    mask = os.urandom(4)
    key = (mask * (n // 4 + 1))[:n]
    body = (int.from_bytes(payload, "big") ^ int.from_bytes(key, "big")).to_bytes(n, "big") if n else b""
    return head + mask + body


class ServerParser:
    """Frames from Incus (never masked) -> list of (opcode, payload), fragments joined. Raises wt.ProtocolError."""

    def __init__(self, limit=MAX_UPSTREAM):
        self.buf, self.limit = bytearray(), limit
        self.msg_op, self.msg = None, bytearray()

    def feed(self, data):
        self.buf += data
        out = []
        while True:
            b = self.buf
            if len(b) < 2:
                return out
            fin, op, n = bool(b[0] & 0x80), b[0] & 0x0F, b[1] & 0x7F
            if b[0] & 0x70 or b[1] & 0x80 or op not in (0, 1, 2, 8, 9, 10):
                raise wt.ProtocolError(1002, "bad frame from the console")
            pos = 2
            if n == 126:
                if len(b) < 4:
                    return out
                n, pos = struct.unpack(">H", bytes(b[2:4]))[0], 4
            elif n == 127:
                if len(b) < 10:
                    return out
                n, pos = struct.unpack(">Q", bytes(b[2:10]))[0], 10
            if n > self.limit or (op >= 8 and (n > 125 or not fin)):
                raise wt.ProtocolError(1009, "frame too big")
            if len(b) < pos + n:
                return out
            payload = bytes(b[pos:pos + n])
            del b[:pos + n]
            if op >= 8:
                out.append((op, payload))
                continue
            if op == 0:
                if self.msg_op is None:
                    raise wt.ProtocolError(1002, "unexpected continuation")
            else:
                if self.msg_op is not None:
                    raise wt.ProtocolError(1002, "new message inside a fragmented one")
                self.msg_op = op
            self.msg += payload
            if len(self.msg) > self.limit:
                raise wt.ProtocolError(1009, "message too big")
            if fin:
                out.append((self.msg_op, bytes(self.msg)))
                self.msg_op, self.msg = None, bytearray()


# ─────────────────────────── Incus ───────────────────────────
class IncusApi:
    """Incus's REST API on its unix socket (we run as root: the socket is root's). `call` -> the parsed JSON answer;
    `websocket` -> (socket after the handshake, bytes already read past the headers)."""

    def __init__(self, path=INCUS_SOCKET, timeout=10):
        self.path, self.timeout = path, timeout

    def _connect(self):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(self.timeout)
        s.connect(self.path)
        return s

    @staticmethod
    def _head(sock):
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = sock.recv(4096)
            if not chunk or len(buf) > 65536:
                raise ConsoleError(502, "The virtual machine service did not answer.")
            buf += chunk
        head, _, rest = buf.partition(b"\r\n\r\n")
        return head.decode("latin-1"), rest

    def call(self, method, path, body=None):
        data = json.dumps(body).encode() if body is not None else b""
        s = self._connect()
        try:
            req = "%s %s HTTP/1.1\r\nHost: incus\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n" % (method, path, len(data))
            s.sendall(req.encode("ascii") + data)
            head, rest = self._head(s)
            while True:
                chunk = s.recv(65536)
                if not chunk:
                    break
                rest += chunk
                if len(rest) > 1 << 20:
                    break
        finally:
            s.close()
        try:
            return json.loads(rest.decode("utf-8") or "{}")
        except ValueError:
            raise ConsoleError(502, "The virtual machine service answered something unreadable.")

    def websocket(self, path):
        s = self._connect()
        try:
            key = base64.b64encode(os.urandom(16)).decode("ascii")
            s.sendall(("GET %s HTTP/1.1\r\nHost: incus\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\n"
                       "Sec-WebSocket-Key: %s\r\n\r\n" % (path, key)).encode("ascii"))
            head, rest = self._head(s)
            lines = head.split("\r\n")
            hdr = {k.strip().lower(): v.strip() for k, _, v in (ln.partition(":") for ln in lines[1:])}
            if " 101 " not in lines[0] + " " or hdr.get("sec-websocket-accept") != wt.accept_key(key):
                raise ConsoleError(502, "The console stream was refused.")
            s.settimeout(None)
            return s, rest
        except BaseException:
            s.close()
            raise


def check_vm(api, name):
    """Raise ConsoleError unless `name` is a running virtual machine."""
    if not valid_name(name):
        raise ConsoleError(400, "That console is not allowed.")
    ans = api.call("GET", "/1.0/instances/%s" % name)
    md = ans.get("metadata") if isinstance(ans, dict) else None
    if not isinstance(md, dict) or ans.get("status_code", 200) >= 400:
        raise ConsoleError(404, "There is no such instance.")
    if md.get("type") != "virtual-machine":
        raise ConsoleError(409, "Only virtual machines have a graphical console. A container has the terminal.")
    if md.get("status") != "Running":
        raise ConsoleError(409, "The virtual machine is not running.")


def open_console(api, name):
    """Ask Incus for the VGA console of a running VM -> (data, control), each (socket, leftover bytes)."""
    check_vm(api, name)
    op = api.call("POST", "/1.0/instances/%s/console" % name, {"type": "vga", "width": 0, "height": 0})
    url = op.get("operation") if isinstance(op, dict) else None
    meta = ((op.get("metadata") or {}).get("metadata") or {}) if isinstance(op, dict) else {}
    fds = meta.get("fds") if isinstance(meta, dict) else None
    if not isinstance(url, str) or not OP_URL_RE.fullmatch(url) or not isinstance(fds, dict):
        raise ConsoleError(502, "The virtual machine service gave no console.")
    secrets_ = [fds.get("0"), fds.get("control")]
    if not all(isinstance(x, str) and SECRET_RE.fullmatch(x) for x in secrets_):
        raise ConsoleError(502, "The virtual machine service gave no console.")
    opened = []
    try:
        for sec in (secrets_[1], secrets_[0]):      # control first: Incus waits for every stream before it starts
            opened.append(api.websocket("%s/websocket?secret=%s" % (url, sec)))
    except BaseException:
        for s, _ in opened:
            s.close()
        raise
    return opened[1], opened[0]


# ─────────────────────────── the relay ───────────────────────────
class VgaRelay:
    """Pumps messages between the browser WebSocket `conn` and the Incus stream. Browser binary messages go to Incus as binary frames,
    Incus's go to the browser; text messages from the browser are ignored (there is no control channel for the page yet)."""

    def __init__(self, conn, data, control, alive=lambda: True, idle=1800, lifetime=28800, check=3.0):
        self.conn, (self.up, first), (self.ctl, _) = conn, data, control
        self.alive, self.idle, self.lifetime, self.check = alive, idle, lifetime, check
        self.browser, self.upstream = wt.Parser(), ServerParser()
        self.first = first

    def _end(self, code, reason, why):
        try:
            self.conn.sendall(wt.close_frame(code, reason))
        except OSError:
            pass
        return why

    def _from_upstream(self, chunk):
        for op, payload in self.upstream.feed(chunk):
            if op == wt.OP_CLOSE:
                return self._end(1000, "console ended", "console ended")
            if op == wt.OP_PING:
                self.up.sendall(client_frame(wt.OP_PONG, payload))
            elif op in (wt.OP_BINARY, wt.OP_TEXT):
                self.conn.sendall(wt.encode_frame(wt.OP_BINARY, payload))
        return None

    def run(self):
        """Blocks until the console ends; always closes both streams. Returns why it ended."""
        t0 = last_input = last_check = time.time()
        try:
            self.conn.settimeout(15)
            if self.first:
                why = self._from_upstream(self.first)
                if why:
                    return why
            while True:
                now = time.time()
                if now - last_input > self.idle:
                    return self._end(wt.CLOSE_IDLE, "idle", "idle")
                if now - t0 > self.lifetime:
                    return self._end(wt.CLOSE_LIFETIME, "time limit", "time limit")
                if now - last_check >= self.check:
                    last_check = now
                    if not self.alive():
                        return self._end(wt.CLOSE_SESSION, "session ended", "session ended")
                try:
                    ready, _, _ = select.select([self.conn, self.up, self.ctl], [], [], min(0.5, self.check))
                except (OSError, ValueError):
                    return "error"
                if self.ctl in ready:
                    try:
                        if not self.ctl.recv(4096):      # the control stream carries nothing we need; closed = Incus is done
                            return self._end(1000, "console ended", "console ended")
                    except OSError:
                        return self._end(1011, "console error", "error")
                if self.up in ready:
                    try:
                        chunk = self.up.recv(65536)
                    except OSError:
                        chunk = b""
                    if not chunk:
                        return self._end(1000, "console ended", "console ended")
                    try:
                        why = self._from_upstream(chunk)
                    except wt.ProtocolError as e:
                        return self._end(1011, e.reason, "protocol error")
                    if why:
                        return why
                if self.conn in ready:
                    try:
                        chunk = self.conn.recv(65536)
                    except socket.timeout:
                        continue
                    if not chunk:
                        return "client left"
                    try:
                        events = self.browser.feed(chunk)
                    except wt.ProtocolError as e:
                        return self._end(e.code, e.reason, "protocol error")
                    for op, payload in events:
                        if op == wt.OP_CLOSE:
                            try:
                                self.conn.sendall(wt.close_frame(1000))
                            except OSError:
                                pass
                            return "client closed"
                        if op == wt.OP_PING:
                            self.conn.sendall(wt.encode_frame(wt.OP_PONG, payload))
                        elif op == wt.OP_BINARY and payload:
                            last_input = time.time()
                            self.up.sendall(client_frame(wt.OP_BINARY, payload))
        except OSError:
            return "error"
        finally:
            self.close()

    def close(self):
        for s in (self.up, self.ctl):
            try:
                s.sendall(client_frame(wt.OP_CLOSE, struct.pack(">H", 1000)))
            except OSError:
                pass
            try:
                s.close()
            except OSError:
                pass
