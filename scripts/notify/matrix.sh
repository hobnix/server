#!/usr/bin/env bash
# notification provider: the Matrix hook (recipe matrix-hook). It draws a card from the event payload of a message
# (`hs notify --payload-file`, here CH_PAYLOAD_FILE); a message without that payload is not for it and counts as delivered.
#   matrix.sh send <priority> <title> <body>   settings CH_url (the hook address, it holds the secret), CH_PAYLOAD_FILE; exit 0 delivered, 1 not delivered, 2 not usable
#   matrix.sh fields                           key TAB label TAB text|secret TAB required|optional TAB pattern
#   matrix.sh check                            exit 0, or 2 with the reason on stderr
#   matrix.sh where                            outside | inside: the hook is a container of this server
#   matrix.sh caps                             the message classes it can carry: alarm status
# The payload is the one of the media events (pkg.<package>.*: service, name, label, icon, title, sub, fields, footer, poster_url); the look of the
# card is in scripts/recipes/files/matrix-card/, the hook only draws what this sends. The channel is written by media_notify_conf (scripts/recipes/_media.sh).
set -uo pipefail
url=${CH_url:-}

usable() {
  [ -n "$url" ] || { echo "no address (url) set" >&2; return 2; }
  [[ "$url" =~ ^https?://[^[:space:]]+$ ]] || { echo "the address is not an http:// or https:// address" >&2; return 2; }
}

# card <payload file>: the JSON the hook takes, made from the payload of the event
card() {
  python3 - "$1" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
fields = [x.split("=", 1) for x in str(p.get("fields") or "").split("\n") if "=" in x]
print(json.dumps({"hsService": p.get("service", ""), "event": p.get("label", ""), "event_icon": p.get("icon", "check-circle"),
                  "title": p.get("title", ""), "sub": p.get("sub", ""), "fields": fields, "footer": p.get("footer", ""),
                  "poster_url": p.get("poster_url", "")}))
PY
}

case "${1:-}" in
  fields) printf 'url\tAddress of the hook (has a secret in it)\tsecret\trequired\t^https?://[^ ]+$\n' ;;
  check) usable ;;
  caps) echo "alarm status" ;;
  where) echo inside ;;
  send)
    [ $# -eq 4 ] || { echo "usage: matrix.sh send <priority> <title> <body>" >&2; exit 2; }
    usable || exit 2
    f=${CH_PAYLOAD_FILE:-}
    [ -n "$f" ] && [ -r "$f" ] || exit 0       # a plain message has no card
    body=$(card "$f" 2>&1) || { printf '%s\n' "${body//$'\n'/ }" >&2; exit 2; }
    if err=$(printf '%s' "$body" | curl -fsS -m 15 -H 'Content-Type: application/json' --data-binary @- "$url" 2>&1 >/dev/null); then exit 0; fi
    printf '%s\n' "${err//$'\n'/ }" >&2
    exit 1 ;;
  *) echo "usage: matrix.sh send|fields|check|where|caps" >&2; exit 2 ;;
esac
