#!/usr/bin/env bash
# notification provider: ntfy. The one place channels reach ntfy; the work is ntfy_send in scripts/lib/ntfy.sh
# (mirrored in the proxyserver repo: do not change that file for this provider).
#   ntfy.sh send <priority> <title> <body>   settings CH_url (the topic address), CH_CATEGORY; exit 0 delivered, 1 not delivered, 2 not usable
#   ntfy.sh fields                           key TAB label TAB text|secret TAB required|optional TAB pattern
#   ntfy.sh check                            exit 0, or 2 with the reason on stderr
#   ntfy.sh where                            outside | inside: is the topic served by something that is not on this server?
#   ntfy.sh caps                             the message classes it can carry: alarm status heartbeat digest
set -uo pipefail
here=$(dirname "$0")
. "$here/../lib/ntfy.sh"
url=${CH_url:-}

usable() {
  [ -n "$url" ] || { echo "no address (url) set" >&2; return 2; }
  [[ "$url" =~ ^https?://[^[:space:]]+$ ]] || { echo "the address is not an http:// or https:// address" >&2; return 2; }
}

case "${1:-}" in
  fields) printf 'url\tAddress of the topic (long and random)\tsecret\trequired\t^https?://[^ ]+$\n' ;;
  check) usable ;;
  caps) echo "alarm status heartbeat digest" ;;
  where)
    usable >/dev/null 2>&1 || { echo inside; exit 0; }
    h=${url#*://}; h=${h%%/*}; h=${h##*@}; h=${h%%:*}
    me=$(hostname 2>/dev/null || true)
    case "$h" in
      localhost|127.*|10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|*.local|*.lan|*.internal|*.home.arpa) echo inside ;;
      *.*) if [ -n "$me" ] && [ "$h" = "$me" ]; then echo inside; else echo outside; fi ;;
      *) echo inside ;;
    esac ;;
  send)
    [ $# -eq 4 ] || { echo "usage: ntfy.sh send <priority> <title> <body>" >&2; exit 2; }
    usable || exit 2
    if err=$(ntfy_send "$url" "$3" "$4" "${CH_CATEGORY:-info}" "$2" 2>&1); then exit 0; fi
    printf '%s\n' "${err//$'\n'/ }" >&2
    exit 1 ;;
  *) echo "usage: ntfy.sh send|fields|check|where|caps" >&2; exit 2 ;;
esac
