#!/usr/bin/env bash
# The real pty path of the browser terminal: scripts/web_terminal.py starts /bin/cat on a pty (instead of systemd-run), a keystroke comes back
# echoed, a resize reaches the pty, and closing the session ends the child. Linux only; needs no root and no systemd.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! have python3; then skip "python3 missing"; finish; exit 0; fi
if ! python3 -c 'import pty, fcntl, termios' 2>/dev/null; then skip "no pty module here (Windows?)"; finish; exit 0; fi

echo "-- real pty"
cat > "$WORK/pty-test.py" <<'X'
import importlib.util, os, signal, struct, sys, time
spec = importlib.util.spec_from_file_location("wt", os.environ["ROOT"] + "/scripts/web_terminal.py")
wt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wt)

m = wt.pty_spawn("host", "nobody", argv=["/bin/cat"])
pid = m.pid
try:
    m.write(b"hello\n")
    got, end = b"", time.time() + 5
    while b"hello" not in got and time.time() < end:
        got += m.read()
    assert b"hello" in got, got
    m.resize(120, 40)
    import fcntl, termios
    rows, cols, _, _ = struct.unpack("HHHH", fcntl.ioctl(m.fd, termios.TIOCGWINSZ, b"\0" * 8))
    assert (cols, rows) == (120, 40), (cols, rows)
finally:
    m.close()
time.sleep(0.2)
try:
    os.kill(pid, 0)
    print("child still alive")
    sys.exit(1)
except OSError:
    pass
print("ok")
X
if out=$(ROOT=$ROOT timeout 30 python3 -I "$WORK/pty-test.py" 2>&1); then check_eq "echo, resize and teardown on a real pty" "ok" "$out"; else fail "real pty: $out"; fi
finish
