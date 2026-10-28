#!/usr/bin/env python3
"""Read-only status endpoint (machine.toml: deckApi = true hs-deck-api.service).

Hands out ONE file, the JSON that scripts/deck-status.sh writes (/run/hs-deck/deck.json), and nothing else:
  GET /status.json   the document (404 until the first one exists, 503 when it is older than STALE seconds)
  GET /disks         the disk inventory from the state database (serials masked to their last four characters), same 404/503 rules
  GET /events        the latest disk events (the same)
  GET /healthz       "ok"
No other path, no POST, no directory listing, no CORS beyond GET. The firewall lets only the home networks and
Tailscale reach the port (configuration.nix); the document holds no secrets.
Usage: deck-serve.py [port] [file]      (defaults 9740, /run/hs-deck/deck.json)
"""
import http.server
import os
import sys
import time

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 9740
FILE = sys.argv[2] if len(sys.argv) > 2 else "/run/hs-deck/deck.json"
STALE = int(os.environ.get("HS_DECK_STALE", "60"))
BIND = os.environ.get("HS_DECK_BIND", "")
# The whitelist: four fixed paths, each one file that the hs-deck-status service wrote next to the status document
# (disks and events are read from the state database there, with masked serials: this process never opens the database).
FILES = {
    "/status.json": FILE,
    "/disks": os.path.join(os.path.dirname(FILE), "deck-disks.json"),
    "/events": os.path.join(os.path.dirname(FILE), "deck-events.json"),
}


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "hs-deck"
    sys_version = ""

    def _send(self, code, body, ctype="application/json"):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/healthz":
            return self._send(200, "ok\n", "text/plain")
        target = FILES.get(path)
        if target is None:
            return self._send(404, '{"error":"not found"}')
        try:
            age = time.time() - os.stat(target).st_mtime
            with open(target, "rb") as f:
                data = f.read()
        except OSError:
            return self._send(404, '{"error":"no status yet"}')
        if age > STALE:
            return self._send(503, '{"error":"status is stale"}')
        self._send(200, data)

    do_HEAD = do_GET

    def log_message(self, *args):   # the journal does not need a line per poll
        pass


if __name__ == "__main__":
    http.server.ThreadingHTTPServer((BIND, PORT), Handler).serve_forever()
