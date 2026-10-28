#!/usr/bin/env bash
# wait_page (scripts/recipes/_lib.sh): waits for the web page of the container, fails with where to look. A stub recipe sources the real
# _lib.sh with a fake incus; the "container" is localhost. No root, no server.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test HS_STATE_DIR=$WORK/state
mkdir -p "$WORK/bin" "$HS_STATE_DIR"
printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/bin/incus"; chmod +x "$WORK/bin/incus"
export PATH="$WORK/bin:$PATH" HS_INCUS=$WORK/bin/incus
cat > "$WORK/stub.sh" <<STUB
#!/usr/bin/env bash
# recipe: Demo: a stub for the test
set -euo pipefail
scripts=$SCRIPTS
state=\$HS_STATE_DIR
ct=demo
. "\$scripts/recipes/_lib.sh"
ip=127.0.0.1; PORT=\$DEMO_PORT
wait_page Demo "journalctl -u demo" \${DEMO_ARGS:-}
echo reached
STUB
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
out=$(DEMO_PORT=$port RECIPE_WAIT_TRIES=1 bash "$WORK/stub.sh" 2>&1 || true)
check_out "nothing listens: it fails and says where to look" "Demo does not answer at http://127.0.0.1:$port. Look at: incus exec demo -- journalctl -u demo" echo "$out"
check "and does not go on" bash -c '! grep -q reached <<<"$1"' _ "$out"
python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1 & srv=$!
sleep 1
out=$(DEMO_PORT=$port RECIPE_WAIT_TRIES=5 bash "$WORK/stub.sh" 2>&1 || true)
kill "$srv" 2>/dev/null || true
check_out "a page answers: it goes on" "reached" echo "$out"

echo "-- options"
cat > "$WORK/srv.py" <<'PY'
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        code, body = {"/ok": (200, b"fine"), "/bad": (500, b"oops"), "/pong": (200, b"pong"), "/gone": (404, b"")}.get(self.path, (200, b"root"))
        self.send_response(code); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
port2=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
python3 "$WORK/srv.py" "$port2" & srv2=$!
sleep 1
try() { DEMO_PORT=$port2 DEMO_ARGS="$1" RECIPE_WAIT_TRIES=2 bash "$WORK/stub.sh" 2>&1 || true; }
check_out "any answer counts, also an error status (the default)" "reached" try "--path /bad"
check_out "--ok refuses an error status" "does not answer" try "--path /bad --ok"
check_out "--ok accepts a success" "reached" try "--path /ok --ok"
check_out "--status 200 accepts 200" "reached" try "--path /ok --status 200"
check_out "--status 200 refuses 404" "does not answer" try "--path /gone --status 200"
check_out "--match finds the text in the body" "reached" try "--path /pong --match pong"
check_out "--match without the text fails" "does not answer" try "--path /ok --match pong"
check_out "--plain gives the shorter waiting text" "Waiting for Demo to answer$" try "--plain"
check_out "an unknown option is refused" "unknown option" try "--bogus"
kill "$srv2" 2>/dev/null || true
finish
