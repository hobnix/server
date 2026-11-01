#!/usr/bin/env python3
"""Live state: a small RESP2 client over a unix socket (no redis-py), the topic list and the CLI behind `hs sys live`.
Shared by scripts/live-collect.py (the one writer) and scripts/web-serve.py (the reader). Only the raw text of a `hs sys` read is stored:
the value of hs:v1:<topic> is JSON {"ts", "gen", "rc", "out", "err", "ts_err"}. Channels: hs:v1:changed ("<topic> <gen>"),
hs:v1:refresh ("<topic>" or "*").
  python3 live_state.py refresh <topic>|@<group>...|--all   ask the collector to read again (exit 0 always); @<group> = every topic of
                                                     that change area (and of `any`), see live-topics.tsv columns 5 and 6
  python3 live_state.py status                       topic, interval, age (-1 none), gen, rc, err or -, ts_err or -
  python3 live_state.py check                        problems: live:down / live:stale:<topic> TAB text (exit 1 when there are some)
"""
import json
import os
import socket
import subprocess
import sys
import threading
import time

KEY = "hs:v1:%s"
CHANGED = "hs:v1:changed"
REFRESH = "hs:v1:refresh"
HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_SOCKET = "/run/redis-hobnix/redis.sock"


def socket_path():
    return os.environ.get("HS_LIVE_SOCKET", DEFAULT_SOCKET)


def encode(*args):
    out = [b"*%d\r\n" % len(args)]
    for a in args:
        b = a if isinstance(a, bytes) else str(a).encode()
        out.append(b"$%d\r\n%s\r\n" % (len(b), b))
    return b"".join(out)


class Resp:
    """One connection. Every failure is an OSError."""

    def __init__(self, path=None, timeout=1.0):
        self.path = path or socket_path()
        self.timeout = timeout
        self.buf = b""
        try:
            self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.sock.settimeout(timeout)
            self.sock.connect(self.path)
        except (OSError, AttributeError) as e:
            raise OSError("cannot connect to %s: %s" % (self.path, e))

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass

    def _fill(self):
        try:
            data = self.sock.recv(65536)
        except socket.timeout:
            raise OSError("timeout")
        if not data:
            raise OSError("connection closed")
        self.buf += data

    def _line(self):
        while b"\r\n" not in self.buf:
            self._fill()
        line, self.buf = self.buf.split(b"\r\n", 1)
        return line

    def _exact(self, n):
        while len(self.buf) < n + 2:
            self._fill()
        data, self.buf = self.buf[:n], self.buf[n + 2:]
        return data

    def read(self):
        line = self._line()
        kind, rest = line[:1], line[1:]
        if kind == b"+":
            return rest.decode()
        if kind == b"-":
            raise OSError("redis: " + rest.decode())
        if kind == b":":
            return int(rest)
        if kind == b"$":
            n = int(rest)
            return None if n < 0 else self._exact(n).decode("utf-8", "replace")
        if kind == b"*":
            n = int(rest)
            return None if n < 0 else [self.read() for _ in range(n)]
        raise OSError("bad reply " + repr(line[:20]))

    def cmd(self, *args):
        try:
            self.sock.sendall(encode(*args))
        except socket.timeout:
            raise OSError("timeout")
        return self.read()

    def subscribe(self, channel):
        """Yields (channel, message) until the connection fails (OSError). Waits without a timeout between messages."""
        self.cmd("SUBSCRIBE", channel)
        self.sock.settimeout(None)
        while True:
            m = self.read()
            if isinstance(m, list) and len(m) == 3 and m[0] == "message":
                yield m[1], m[2]


def ext_live():
    """(rows, info) of the live reads that extension packages declare (scripts/hs_ext.py); nothing when that cannot be read"""
    try:
        import hs_ext
        return hs_ext.ext_live_rows()
    except Exception:       # a broken package must never take the core topics down
        return [], {}


def topics(path=None):
    """[(topic, words list, interval seconds, lock mode run|skip)] from live-topics.tsv, plus the live reads of the extension packages that are on
    (only for the real file: a test that passes its own path gets just that file)."""
    own = path is not None
    path = path or os.path.join(HERE, "lib", "live-topics.tsv")
    rows = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            c = line.split("\t")
            if len(c) < 3:
                continue
            rows.append((c[0], c[1].split(), int(c[2]), c[3] if len(c) > 3 and c[3] else "run"))
    if not own:
        known = {r[0] for r in rows}
        rows += [r for r in ext_live()[0] if r[0] not in known]
    return rows


def topic_info(path=None):
    """{topic: {"cap": capability name or None, "groups": set of change areas}} from columns 5 and 6 of live-topics.tsv."""
    own = path is not None
    path = path or os.path.join(HERE, "lib", "live-topics.tsv")
    info = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            c = line.split("\t")
            if len(c) < 3:
                continue
            cap = c[4] if len(c) > 4 and c[4] not in ("", "-") else None
            groups = {g for g in (c[5].split(",") if len(c) > 5 else []) if g and g != "-"}
            info[c[0]] = {"cap": cap, "groups": groups}
    if not own:
        for t, i in ext_live()[1].items():
            info.setdefault(t, i)
    return info


_CAP_CACHE = {}
_CAP_LOCK = threading.Lock()
CAP_TTL = 60.0


def cap_on(name):
    """True when the capability is on (lib/capability.sh capability_on); cached for 60 s per name. None/'-' is always on."""
    if not name or name == "-":
        return True
    now = time.time()
    with _CAP_LOCK:
        hit = _CAP_CACHE.get(name)
        if hit and now - hit[0] < CAP_TTL:
            return hit[1]
    try:
        p = subprocess.run(["bash", "-c", '. "$1"; capability_on "$2"', "_", os.path.join(HERE, "lib", "capability.sh"), name],
                           capture_output=True, timeout=10)
        on = p.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        on = False
    with _CAP_LOCK:
        _CAP_CACHE[name] = (now, on)
    return on


def clean(text, limit=200):
    """one line of printable text: control characters (newline, tab, escape ...) become a space; what a package printed must never shape a check line"""
    return "".join(c if c.isprintable() else " " for c in str(text))[:limit]


def _doc(r, topic):
    raw = r.cmd("GET", KEY % topic)
    if raw is None:
        return None
    try:
        return json.loads(raw)
    except ValueError:
        return None


def cli_refresh(args, conn=None):
    try:
        names = [t[0] for t in topics()] if "--all" in args else [a for a in args]
        r = conn or Resp(timeout=1.0)
        for t in names:
            r.cmd("PUBLISH", REFRESH, t)
        r.close()
    except (OSError, ValueError):
        pass
    return 0


def cli_status(conn=None, out=None):
    out = out or sys.stdout
    try:
        r = conn or Resp(timeout=2.0)
        now = time.time()
        info = topic_info()
        for topic, _, interval, _ in topics():
            if not cap_on((info.get(topic) or {}).get("cap")):
                continue   # the capability is off: the topic is not read, so it has no row (the same rule as check)
            d = _doc(r, topic) or {}
            age = int(now - d["ts"]) if d.get("ts") else -1
            err = clean(d.get("err") or "-")
            ts_err = str(int(d["ts_err"])) if d.get("ts_err") else "-"
            out.write("%s\t%d\t%d\t%s\t%s\t%s\t%s\n" % (
                topic, interval, age, d.get("gen", 0), d.get("rc", "-"), err, ts_err))
    except OSError as e:
        sys.stderr.write("live state failed: %s\n" % e)
        return 1
    return 0


def cli_check(conn=None, out=None):
    out = out or sys.stdout
    try:
        r = conn or Resp(timeout=2.0)
        now = time.time()
        problems = []
        info = topic_info()
        for topic, _, interval, _ in topics():
            if not cap_on((info.get(topic) or {}).get("cap")):
                continue   # the capability is off: the topic is not read
            d = _doc(r, topic)
            if d is None:
                continue   # nothing read yet: the collector is still starting
            if not d.get("ts"):
                if d.get("err"):   # tried and never succeeded
                    problems.append(("live:never:" + topic, "live state '%s' has never been read: %s. Details: systemctl status hs-live" % (
                        topic, clean(d["err"]))))
                continue
            age = now - d["ts"]
            if age > 3 * interval:
                problems.append(("live:stale:" + topic, "live state '%s' is %d s old (read every %d s). Details: systemctl status hs-live" % (
                    topic, age, interval)))
    except OSError as e:
        problems = [("live:down", "the live state service is down (%s). Details: systemctl status redis-hobnix hs-live" % e)]
    for k, t in problems:
        out.write("%s\t%s\n" % (k, t))
    return 1 if problems else 0


def main(argv):
    if not argv:
        sys.stderr.write("usage: live_state.py refresh <topic>...|--all | status | check\n")
        return 2
    if argv[0] == "refresh":
        return cli_refresh(argv[1:])
    if argv[0] == "status":
        return cli_status()
    if argv[0] == "check":
        return cli_check()
    sys.stderr.write("unknown command %s\n" % argv[0])
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
