"""In-browser terminal for the web interface (used by web-serve.py): a hand-written RFC 6455 WebSocket, one-use tickets, the
limits, and the pty-backed shell. Standard library only. POSIX-only pieces (pty, pwd, fcntl, termios) are imported where they are
used, so the framing and the session logic run on any system with a fake `spawn` (tests/web-terminal-test.py).

The shell never runs as root and never inside web-serve.py: pty_spawn() starts `systemd-run --pty` as the local account, in its own
transient unit, so it is what an SSH login gives (sudo works, /tmp is the real one). Nothing here logs keystrokes or output.

The shell itself lives in a tmux session (own tmux server, socket "hs-web", in the unit hs-web-tmux), one per web user and target:
closing the page, a popout or a dropped connection only ends the tmux CLIENT, and the next terminal for that target attaches to the
same session. Without tmux installed the terminal falls back to a shell that ends with the connection.
"""
import base64
import hashlib
import json
import os
import re
import secrets
import select
import shlex
import socket
import struct
import threading
import time

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
MAX_FRAME = 64 * 1024            # payload of one frame (and of one assembled message)
OP_CONT, OP_TEXT, OP_BINARY, OP_CLOSE, OP_PING, OP_PONG = 0x0, 0x1, 0x2, 0x8, 0x9, 0xA
TICKET_TTL = 30
MAX_PENDING = 32                 # tickets waiting to be used
MAX_TOTAL, MAX_PER_SESSION = 4, 2
COLS = (1, 500)
ROWS = (1, 200)
TARGET_RE = re.compile(r"^[a-z][a-z0-9-]{0,40}$")
KEY_RE = re.compile(r"^[A-Za-z0-9+/]{22}==$")
HOST_RE = re.compile(r"^(?:[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?|\[[0-9A-Fa-f:]{2,45}\])(?::[0-9]{1,5})?$")
TMUX_SOCKET, TMUX_UNIT = "hs-web", "hs-web-tmux"
INSTANCE_SHELL = "if command -v bash >/dev/null 2>&1; then exec bash -l; else exec sh -l; fi"

# close codes: 1000 normal, 1001 going away, 1002 protocol error, 1003 bad data, 1007 bad text, 1008 policy, 1009 too big, 1011 error;
# 4001..4003 are ours (private range) so the page can say why
CLOSE_IDLE, CLOSE_LIFETIME, CLOSE_SESSION = 4001, 4002, 4003


class ProtocolError(Exception):
    def __init__(self, code, reason=""):
        super().__init__(reason)
        self.code, self.reason = code, reason


# ─────────────────────────── framing ───────────────────────────
def accept_key(key):
    return base64.b64encode(hashlib.sha1((key + GUID).encode("ascii")).digest()).decode("ascii")


def valid_key(key):
    return bool(key) and KEY_RE.fullmatch(key) is not None and len(base64.b64decode(key)) == 16


def encode_frame(opcode, payload=b""):
    """A server frame (never masked), FIN set."""
    n = len(payload)
    head = bytes([0x80 | opcode])
    if n < 126:
        head += bytes([n])
    elif n < 65536:
        head += bytes([126]) + struct.pack(">H", n)
    else:
        head += bytes([127]) + struct.pack(">Q", n)
    return head + payload


def close_frame(code, reason=""):
    return encode_frame(OP_CLOSE, struct.pack(">H", code) + reason.encode("utf-8")[:100])


class Parser:
    """Incremental client-frame parser: feed(bytes) -> list of (opcode, payload) whole messages (continuations are joined).
    Raises ProtocolError for anything a client must not send."""

    def __init__(self, max_frame=MAX_FRAME):
        self.buf, self.max_frame = bytearray(), max_frame
        self.msg_op, self.msg = None, bytearray()

    def feed(self, data):
        self.buf += data
        out = []
        while True:
            ev = self._one()
            if ev is None:
                return out
            if ev is not False:
                out.append(ev)

    def _one(self):
        b = self.buf
        if len(b) < 2:
            return None
        fin, op, masked, n = bool(b[0] & 0x80), b[0] & 0x0F, bool(b[1] & 0x80), b[1] & 0x7F
        if b[0] & 0x70:
            raise ProtocolError(1002, "reserved bits")
        if op not in (OP_CONT, OP_TEXT, OP_BINARY, OP_CLOSE, OP_PING, OP_PONG):
            raise ProtocolError(1002, "bad opcode")
        if not masked:
            raise ProtocolError(1002, "client frames must be masked")
        pos = 2
        if n == 126:
            if len(b) < 4:
                return None
            n, pos = struct.unpack(">H", bytes(b[2:4]))[0], 4
        elif n == 127:
            if len(b) < 10:
                return None
            n, pos = struct.unpack(">Q", bytes(b[2:10]))[0], 10
        if op >= 8 and (n > 125 or not fin):
            raise ProtocolError(1002, "bad control frame")
        if n > self.max_frame:
            raise ProtocolError(1009, "frame too big")
        if len(b) < pos + 4 + n:
            return None
        mask = bytes(b[pos:pos + 4])
        payload = bytearray(b[pos + 4:pos + 4 + n])
        del b[:pos + 4 + n]
        if n:
            # XOR with the repeating mask, in one big-int operation (fast enough for 64 KiB)
            key = (mask * (n // 4 + 1))[:n]
            payload = bytearray((int.from_bytes(payload, "big") ^ int.from_bytes(key, "big")).to_bytes(n, "big"))
        if op >= 8:
            return (op, bytes(payload))
        if op == OP_CONT:
            if self.msg_op is None:
                raise ProtocolError(1002, "unexpected continuation")
        else:
            if self.msg_op is not None:
                raise ProtocolError(1002, "new message inside a fragmented one")
            self.msg_op = op
        self.msg += payload
        if len(self.msg) > self.max_frame:
            raise ProtocolError(1009, "message too big")
        if not fin:
            return False
        op, data = self.msg_op, bytes(self.msg)
        self.msg_op, self.msg = None, bytearray()
        if op == OP_TEXT:
            try:
                data.decode("utf-8")
            except UnicodeDecodeError:
                raise ProtocolError(1007, "text is not UTF-8")
        return (op, data)


def parse_control(text):
    """A text message -> ('resize', cols, rows) or None (anything else is ignored). Bounds are checked here."""
    try:
        obj = json.loads(text)
    except ValueError:
        return None
    if not isinstance(obj, dict) or obj.get("type") != "resize":
        return None
    c, r = obj.get("cols"), obj.get("rows")
    if isinstance(c, bool) or isinstance(r, bool) or not isinstance(c, int) or not isinstance(r, int):
        return None
    if not (COLS[0] <= c <= COLS[1] and ROWS[0] <= r <= ROWS[1]):
        return None
    return ("resize", c, r)


# ─────────────────────────── tickets and limits ───────────────────────────
def valid_target(target):
    return isinstance(target, str) and TARGET_RE.fullmatch(target) is not None


def csp_connect(host, secure):
    """The connect-src value: 'self' plus the websocket of this very host, only when the Host header is a plain host[:port]."""
    if not isinstance(host, str) or not HOST_RE.fullmatch(host):
        return "'self'"
    return "'self' wss://%s" % host if secure else "'self' wss://%s ws://%s" % (host, host)


class Terminals:
    """One-use tickets (30 s, bound to a session and a target) and the count of open terminals."""

    def __init__(self, ttl=TICKET_TTL, total=MAX_TOTAL, per_session=MAX_PER_SESSION):
        self.lock, self.tickets, self.open = threading.Lock(), {}, {}
        self.ttl, self.total, self.per_session = ttl, total, per_session

    def issue(self, sess, target):
        now = time.time()
        with self.lock:
            for k in [k for k, v in self.tickets.items() if v[2] < now]:
                del self.tickets[k]
            if len(self.tickets) >= MAX_PENDING:
                return None
            t = secrets.token_urlsafe(24)
            self.tickets[t] = (sess, target, now + self.ttl)
            return t

    def redeem(self, ticket, sess):
        """-> target, or None. The ticket is gone after the first try, right or wrong."""
        with self.lock:
            v = self.tickets.pop(ticket, None) if isinstance(ticket, str) else None
        if v is None or v[2] < time.time() or not sess or not secrets.compare_digest(v[0], sess):
            return None
        return v[1]

    def acquire(self, sess):
        with self.lock:
            if sum(self.open.values()) >= self.total or self.open.get(sess, 0) >= self.per_session:
                return False
            self.open[sess] = self.open.get(sess, 0) + 1
            return True

    def release(self, sess):
        with self.lock:
            n = self.open.get(sess, 0) - 1
            if n > 0:
                self.open[sess] = n
            else:
                self.open.pop(sess, None)


# ─────────────────────────── the session over a socket ───────────────────────────
class TerminalSession:
    """Pumps bytes between the websocket `conn` and the shell's master object. `spawn()` returns an object with
    fileno(), read() -> bytes (b"" = the shell ended), write(bytes), resize(cols, rows), close(). Tests pass a fake.
    `alive()` says whether the web session is still good; it is asked every `check` seconds."""

    def __init__(self, conn, spawn, alive=lambda: True, idle=1800, lifetime=28800, check=3.0):
        self.conn, self.spawn, self.alive = conn, spawn, alive
        self.idle, self.lifetime, self.check = idle, lifetime, check
        self.master = None
        self.parser = Parser()
        self.closed_by = ""

    def open(self):
        self.master = self.spawn()

    def _send(self, data):
        self.conn.sendall(data)

    def run(self):
        """Blocks until the terminal ends; always closes the master. Returns why it ended."""
        why = "error"
        t0 = last_input = last_check = time.time()
        try:
            self.conn.settimeout(15)
            while True:
                now = time.time()
                if now - last_input > self.idle:
                    return self._end(CLOSE_IDLE, "idle", "idle")
                if now - t0 > self.lifetime:
                    return self._end(CLOSE_LIFETIME, "time limit", "time limit")
                if now - last_check >= self.check:
                    last_check = now
                    if not self.alive():
                        return self._end(CLOSE_SESSION, "session ended", "session ended")
                try:
                    ready, _, _ = select.select([self.conn, self.master], [], [], min(0.5, self.check))
                except (OSError, ValueError):
                    return "error"
                if self.master in ready:
                    try:
                        data = self.master.read()
                    except OSError:
                        data = b""
                    if not data:
                        return self._end(1000, "shell ended", "shell ended")
                    self._send(encode_frame(OP_BINARY, data))
                if self.conn in ready:
                    try:
                        chunk = self.conn.recv(65536)
                    except socket.timeout:
                        continue
                    if not chunk:
                        return "client left"
                    try:
                        events = self.parser.feed(chunk)
                    except ProtocolError as e:
                        return self._end(e.code, e.reason, "protocol error")
                    for op, payload in events:
                        if op == OP_CLOSE:
                            try:
                                self._send(close_frame(1000))
                            except OSError:
                                pass
                            return "client closed"
                        if op == OP_PING:
                            self._send(encode_frame(OP_PONG, payload))
                        elif op == OP_BINARY:
                            last_input = time.time()
                            if payload:
                                self.master.write(payload)
                        elif op == OP_TEXT:
                            ctl = parse_control(payload.decode("utf-8"))
                            if ctl:
                                self.master.resize(ctl[1], ctl[2])
        except OSError:
            return why
        finally:
            self.close()

    def _end(self, code, reason, why):
        try:
            self._send(close_frame(code, reason))
        except OSError:
            pass
        return why

    def close(self):
        m, self.master = self.master, None
        if m is not None:
            try:
                m.close()
            except OSError:
                pass


# ─────────────────────────── the real shell ───────────────────────────
def session_name(user, target):
    """The tmux session of one web user and target (tmux names may not hold '.' or ':')."""
    return "w-%s-%s" % (re.sub(r"[^A-Za-z0-9_-]", "_", str(user))[:40], target)


def shell_argv(target, shell, incus="incus"):
    if target == "host":
        return [shell, "-l"]
    return [incus, "exec", target, "--", "sh", "-c", INSTANCE_SHELL]


def tmux_attach_script(name, inner, tmux="tmux"):
    """sh -c text: wait (up to 3 s) for the tmux server unit, then attach to the session or create it running `inner`."""
    t = shlex.quote(tmux)
    return ("for i in $(seq 30); do %s -L %s show -gv status >/dev/null 2>&1 && break; sleep 0.1; done; "
            "exec %s -L %s new-session -A -s %s %s \\; set -g status off \\; set -g mouse on \\; set -g window-size latest"
            # tmux owns the mouse (wheel scrolls its history): no tmux right-click menus (the page has none either), and a
            # selection is sent to the browser as an OSC 52 clipboard sequence (Terminal.svelte puts it on the clipboard)
            " \\; set -g set-clipboard on \\; unbind -n MouseDown3Pane \\; unbind -n M-MouseDown3Pane \\; unbind -n MouseDown3Status \\; unbind -n MouseDown3StatusLeft \\; unbind -n MouseDown3StatusRight"
            % (t, TMUX_SOCKET, t, TMUX_SOCKET, shlex.quote(name), shlex.quote(shlex.join(inner))))


def build_command(target, user, home, shell, unit, incus="incus", systemd_run="systemd-run", name=None, tmux="tmux"):
    """The argv of the real terminal. Host: the account's login shell in a transient unit running as that account.
    Instance: `incus exec` as that same account (which is in the incus group), bash if the instance has it, else sh.
    With `name` the shell runs in the tmux session of that name and the unit only holds the tmux client."""
    inner = shell_argv(target, shell, incus)
    if name:
        inner = ["sh", "-c", tmux_attach_script(name, inner, tmux)]
    return [systemd_run, "--quiet", "--pty", "--collect", "--wait", "--send-sighup", "--unit", unit,
            "-p", "User=" + user, "-p", "WorkingDirectory=" + home, "-E", "TERM=xterm-256color", "--"] + inner


def ensure_tmux_server(user, home, tmux, systemd_run):
    """Start the tmux server in a unit of its own, so a session outlives the client's unit. Already running = fails quietly."""
    import subprocess
    try:
        subprocess.run([systemd_run, "--quiet", "--collect", "--unit", TMUX_UNIT, "-p", "User=" + user, "-p", "WorkingDirectory=" + home,
                        "--", tmux, "-L", TMUX_SOCKET, "-D"], capture_output=True, timeout=15)
    except (OSError, subprocess.SubprocessError):
        pass


class PtyMaster:
    def __init__(self, fd, pid, unit=None, stop=None):
        self.fd, self.pid, self.unit, self.stop = fd, pid, unit, stop
        self.done = False

    def fileno(self):
        return self.fd

    def read(self):
        return os.read(self.fd, 16384)

    def write(self, data):
        while data:
            n = os.write(self.fd, data)
            data = data[n:]

    def resize(self, cols, rows):
        import fcntl
        import termios
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    def close(self):
        """No shell survives: hang up the pty, signal the child, stop the transient unit, reap."""
        if self.done:
            return
        self.done = True
        import signal
        try:
            os.close(self.fd)
        except OSError:
            pass
        try:
            os.kill(self.pid, signal.SIGHUP)
        except OSError:
            pass
        if self.unit and self.stop:
            try:
                self.stop(self.unit)
            except Exception:
                pass
        end = time.time() + 3
        while time.time() < end:
            try:
                if os.waitpid(self.pid, os.WNOHANG)[0]:
                    return
            except ChildProcessError:
                return
            time.sleep(0.05)
        try:
            os.kill(self.pid, signal.SIGKILL)
            os.waitpid(self.pid, 0)
        except OSError:
            pass


def _stop_unit(unit):
    import subprocess
    subprocess.run(["systemctl", "stop", unit + ".service"], capture_output=True, timeout=15)


def pty_spawn(target, local_user, argv=None, name=None):
    """Start the real terminal on a pty. `argv` replaces the command (tests/web-terminal-pty.sh runs /bin/cat).
    `name` = the tmux session to attach to or create (persistent); without tmux on the system it is ignored."""
    import fcntl
    import pty
    import shutil
    import termios
    unit = None
    if argv is None:
        import pwd
        pw = pwd.getpwnam(local_user)
        unit = "hs-web-term-" + secrets.token_hex(4)
        systemd_run = shutil.which("systemd-run") or "/run/current-system/sw/bin/systemd-run"
        tmux = shutil.which("tmux") or "/run/current-system/sw/bin/tmux"
        if name and os.access(tmux, os.X_OK):
            ensure_tmux_server(local_user, pw.pw_dir, tmux, systemd_run)
        else:
            name = None
        argv = build_command(target, local_user, pw.pw_dir, pw.pw_shell, unit,
                             incus=shutil.which("incus") or "/run/current-system/sw/bin/incus",
                             systemd_run=systemd_run, name=name, tmux=tmux)
    pid, fd = pty.fork()
    if pid == 0:
        try:
            os.execvpe(argv[0], argv, {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "TERM": "xterm-256color"})
        finally:
            os._exit(127)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    return PtyMaster(fd, pid, unit, _stop_unit)
