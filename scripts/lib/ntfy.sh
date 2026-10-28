# shellcheck shell=bash
# The one place that talks to ntfy: every push message of the home server (notify.sh, the heartbeat in
# health-check.sh, vps/hs-watch.sh) goes through ntfy_send. Plain bash + curl, no hs library, because
# hs-watch.sh runs on the VPS. The proxyserver repo carries a COPY of this file (modules/notify/ntfy.sh): change both
# (tests/ntfy-style.sh compares them when ../proxyserver is next to this repo).
#
# A message has a CATEGORY, not an icon; the table below gives icon (an ntfy emoji short code) and default priority:
#   alarm      rotating_light          urgent   something is down, seen from outside, a failed unit
#   lock       closed_lock_with_key    urgent   the server waits for the vault passphrase
#   problem    warning                 high     health problems, a failed update
#   ok         white_check_mark        default  all clear, update finished, unlocked
#   start      arrow_up                low      server started, update started
#   stop       arrow_down              low      rebooting, shutting down
#   info       information_source      default  everything else
#   heartbeat  heartbeat               min      the "still alive" ping
# Tags = icon + host name (the host tag tells the home server's messages from the VPS's). Body = markdown (ntfy_md)
# plus an italic footer with host and time (not on the heartbeat).

ntfy_category() {   # ntfy_category <name>: sets NTFY_ICON and NTFY_PRIO
  case "$1" in
    alarm)     NTFY_ICON=rotating_light;        NTFY_PRIO=urgent ;;
    lock)      NTFY_ICON=closed_lock_with_key;  NTFY_PRIO=urgent ;;
    problem)   NTFY_ICON=warning;               NTFY_PRIO=high ;;
    ok)        NTFY_ICON=white_check_mark;      NTFY_PRIO=default ;;
    start)     NTFY_ICON=arrow_up;              NTFY_PRIO=low ;;
    stop)      NTFY_ICON=arrow_down;            NTFY_PRIO=low ;;
    heartbeat) NTFY_ICON=heartbeat;             NTFY_PRIO=min ;;
    *)         NTFY_ICON=information_source;    NTFY_PRIO=default ;;
  esac
}

ntfy_category_for() {   # ntfy_category_for <priority>: the category of a caller that names only a priority
  case "$1" in
    urgent) echo alarm ;;
    high)   echo problem ;;
    low)    echo start ;;
    *)      echo info ;;
  esac
}

# ntfy_md <message>: plain lines -> markdown. Per line: a line that already is markdown (bold lead, bullet, heading,
# quote, backticks) stays; with more than one line the others become bullets; "Details: <command>" style endings are
# set in `code`; < and > are escaped (a bare <share> would be taken for HTML and vanish). Idempotent.
ntfy_md() {
  local msg=$1 n line out=""
  n=$(printf '%s\n' "$msg" | grep -c .) || true
  ! grep -q '^$' <<<"$msg" || n=1   # a blank line = laid out in paragraphs by the author: no bullets
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ""|'**'*|'- '*|'#'*|'>'*|'* '*|'1. '*) ;;
      *'`'*) [ "$n" -le 1 ] || line="- $line" ;;
      *)
        line=${line//</\\<}; line=${line//>/\\>}
        line=$(sed -E 's/(Details|Run|Try|Start one|Replace it with|Set who may use it|Done with it\?|Look at): (.+)$/\1: `\2`/; s/\.`$/`./' <<<"$line")
        [ "$n" -le 1 ] || line="- $line"
        ;;
    esac
    out+="$line"$'\n'
  done <<<"$msg"
  printf '%s' "${out%$'\n'}"
}

ntfy_body() {   # ntfy_body <message> <category>: the markdown body as it is sent
  local body footer
  body=$(ntfy_md "$1")
  if [ "$2" != heartbeat ]; then
    footer="_${NTFY_HOST:-$(hostname 2>/dev/null || echo server)} · $(date '+%Y-%m-%d %H:%M')_"
    body+=$'\n\n'"$footer"
  fi
  printf '%s' "$body"
}

# ntfy_send <url> <title> <message> [category] [priority]
# priority empty = the category's default. Fails (curl's status) when the message did not arrive; callers decide
# whether that matters. curl's own error text goes to stderr.
ntfy_send() {
  local url=$1 title=$2 msg=$3 cat=${4:-info} prio=${5:-} host
  ntfy_category "$cat"
  prio=${prio:-$NTFY_PRIO}
  host=$(printf '%s' "${NTFY_HOST:-$(hostname 2>/dev/null || echo server)}" | tr 'A-Z ' 'a-z-')
  curl -fsS -m "${NTFY_TIMEOUT:-10}" \
    -H "Title: $title" -H "Priority: $prio" -H "Tags: $NTFY_ICON,$host" -H "Markdown: yes" \
    --data-raw "$(ntfy_body "$msg" "$cat")" "$url" >/dev/null
}
