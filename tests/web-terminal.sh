#!/usr/bin/env bash
# In-browser terminal (scripts/web_terminal.py + the glue in scripts/web-serve.py): WebSocket framing, one-use tickets, limits, the upgrade
# against the real server with a fake shell. No pty and no systemd needed (tests/web-terminal-pty.sh does the real pty on Linux).
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! have python3; then skip "python3 missing"; finish; exit 0; fi

echo "-- web terminal"
if out=$(python3 -I "$ROOT/tests/web-terminal-test.py" 2>&1); then pass "web terminal tests ($(grep -E '^Ran ' <<<"$out"))"; else fail "web terminal tests: $(tail -n 25 <<<"$out")"; fi
finish
