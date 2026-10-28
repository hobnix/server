#!/usr/bin/env bash
# Watcher for the VPS (runs there, not on the home server; plain bash + curl, no hs).
# Raises the alarm when the home server or its way to the internet is gone, seen from OUTSIDE:
#   1. no "still alive" message on the heartbeat topic for MAX_AGE_MIN minutes (health-check.sh
#      sends one every 15 minutes: power cut, crash, network or router down),
#   2. a public address answers with "no connection" or a 5xx error (Cloudflare tunnel, cloudflared,
#      Zoraxy or a container behind it is down). Any other answer (also 404) means "reachable".
# It tells you through ALERT_URL (ntfy topic: the notifyUrl of the server), when the set of
# problems changes, once a day as a reminder, and when all is well again.
# Config: /etc/hs-watch.conf or environment variables (HEARTBEAT_URL[_FILE], ALERT_URL[_FILE], SITES, MAX_AGE_MIN);
# run every 5 minutes by a timer. The proxyserver repo (NixOS, modules/watch.nix) carries a copy of this file: change both.
set -uo pipefail

conf=${HS_WATCH_CONF:-/etc/hs-watch.conf}
# the one place that talks to ntfy (scripts/lib/ntfy.sh of the home server repo; a copy sits next to this file on the VPS)
me=$(dirname "${BASH_SOURCE[0]}")
for lib in "${HS_NTFY_LIB:-}" "$me/ntfy.sh" "$me/../scripts/lib/ntfy.sh"; do
  # shellcheck source=/dev/null
  [ -n "$lib" ] && [ -r "$lib" ] && { . "$lib"; break; }
done
declare -F ntfy_send >/dev/null || { echo "hs-watch: ntfy.sh not found next to $0" >&2; exit 1; }
state=${HS_WATCH_STATE:-/var/lib/hs-watch/state}
# shellcheck source=/dev/null
[ -r "$conf" ] && . "$conf"
HEARTBEAT_URL=${HEARTBEAT_URL:-}
ALERT_URL=${ALERT_URL:-}
# the topics are secrets: they may be files instead (NixOS: modules/watch.nix of the proxyserver repo)
[ -n "$HEARTBEAT_URL" ] || [ -z "${HEARTBEAT_URL_FILE:-}" ] || HEARTBEAT_URL=$(tr -d '[:space:]' < "$HEARTBEAT_URL_FILE" 2>/dev/null || true)
[ -n "$ALERT_URL" ] || [ -z "${ALERT_URL_FILE:-}" ] || ALERT_URL=$(tr -d '[:space:]' < "$ALERT_URL_FILE" 2>/dev/null || true)
SITES=${SITES:-}               # space separated, e.g. "https://example.com https://wiki.example.com"
MAX_AGE_MIN=${MAX_AGE_MIN:-45}
REMIND=${REMIND:-86400}
dry=false; [ "${1:-}" = --dry-run ] && dry=true

[ -n "$ALERT_URL" ] || { echo "hs-watch: ALERT_URL (or ALERT_URL_FILE) is not set in $conf" >&2; exit 1; }
now=$(date +%s)
problems=()
last_beat=""      # epoch of the newest heartbeat message in the window (for the status document)
site_rows=""      # name, url, code, since: for the status document (scripts/lib/edge_facts.py)

# 1. heartbeat. A poll that itself fails (ntfy.sh unreachable from here) says nothing about the server: no alarm.
if [ -n "$HEARTBEAT_URL" ]; then
  if beat=$(curl -fsS -m 20 "${HEARTBEAT_URL%/}/json?poll=1&since=${MAX_AGE_MIN}m" 2>/dev/null); then
    grep -q '"event":"message"' <<<"$beat" ||
      problems+=("no sign of life from the home server for $MAX_AGE_MIN minutes (power, network, crash?)")
    last_beat=$(grep -o '"time":[0-9]*' <<<"$beat" | tail -n1 | cut -d: -f2)
  else
    echo "hs-watch: could not ask $HEARTBEAT_URL, heartbeat not judged" >&2
    # keep an alarm that is already raised, so a flaky poll neither clears nor repeats it
    prev=$(tail -n +2 "$state" 2>/dev/null | grep '^no sign of life' || true)
    [ -z "$prev" ] || problems+=("$prev")
  fi
fi

# 2. public addresses
for site in $SITES; do
  code=$(curl -s -o /dev/null -m 20 -w '%{http_code}' "$site" 2>/dev/null || true)
  case "$code" in
    000|"" ) problems+=("$site does not answer at all") ;;
    5??    ) problems+=("$site answers with error $code") ;;
  esac
  # when the answer last changed: the old row of this site, if it said the same
  since=$(awk -F'	' -v u="$site" -v c="${code:-000}" '$2 == u && $3 == c { print $4; exit }' "$state.sites" 2>/dev/null || true)
  site_rows+="$(printf '%s	%s	%s	%s' "${site#*://}" "$site" "${code:-000}" "${since:-$now}")"$'
'
done

# What the status document shows (scripts/lib/edge_facts.py): when this run happened, the newest heartbeat, the answer of every site.
# Written at every run, also when nothing is sent below.
if ! $dry; then
  mkdir -p "$(dirname "$state")" 2>/dev/null || true
  printf '%s
' "$now" > "$state.run" 2>/dev/null || true
  printf '%s
' "${last_beat:--}" > "$state.beat" 2>/dev/null || true
  printf '%s' "$site_rows" > "$state.sites" 2>/dev/null || true
fi

new=""
[ ${#problems[@]} -eq 0 ] || new=$(printf '%s\n' "${problems[@]}" | sort)
last=0; old=""
if [ -r "$state" ]; then last=$(head -n1 "$state"); old=$(tail -n +2 "$state"); fi
[[ "$last" =~ ^[0-9]+$ ]] || last=0

send() {   # title, message, priority, category
  if $dry; then echo "would send [$3/$4] $1: $2"; return 0; fi
  NTFY_TIMEOUT=20 ntfy_send "$ALERT_URL" "$1" "$2" "$4" "$3" 2>/dev/null ||
    { echo "hs-watch: could not send to $ALERT_URL" >&2; return 1; }
}

if [ "$new" != "$old" ] && [ -n "$new" ]; then
  send "home server: ${#problems[@]} problem(s) seen from outside" "$(echo '**The home server does not look healthy from outside**'; printf '%s\n' "${problems[@]}")" urgent alarm || exit 1
elif [ "$new" != "$old" ]; then
  send "home server: reachable again" "**Reachable again.** The problems seen from outside are gone." default ok || exit 1
elif [ -n "$new" ] && [ $((now - last)) -ge "$REMIND" ]; then
  send "home server: still ${#problems[@]} problem(s)" "$(echo '**Still not healthy from outside**'; printf '%s\n' "${problems[@]}")" high problem || exit 1
else
  echo "Nothing to send."; exit 0
fi
$dry || { mkdir -p "$(dirname "$state")" && printf '%s\n%s\n' "$now" "$new" > "$state"; }
