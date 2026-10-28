#!/usr/bin/env bash
# help: check an edge node (Tailscale, mail server, game host, mail queue, certificate, watcher, disk); push a message when the problems change
# help.de: prüft einen Edge-Knoten (Tailscale, Mailserver, Spielehost, Mail-Queue, Zertifikat, Wächter, Platte); schickt eine Nachricht, wenn sich die Probleme ändern
# args: [--test] [--dry-run] [--keys]
# The health check of the role "edge" (hs-health-check.service runs it instead of scripts/health-check.sh, every 15 minutes). The facts come from
# scripts/lib/edge_facts.py (problems); this script only decides what to say and when: ONE message when the set of problems changes, again once a day
# while it lasts, and "all clear" when it is over. Only the keys are compared (the texts hold numbers that change every run). The state is
# /var/lib/hs/health.state, the same file the status document counts. --keys: only the keys, one per line, sends and writes nothing.
# Unlike scripts/health-check.sh it does NOT post a heartbeat: the heartbeat topic of an edge node is the one it WATCHES (the home server posts there).
# Test knobs: HS_HEALTH_STATE, HS_NOW, the knobs of edge_facts.py and of notify.sh (HS_NOTIFY_URL).
set -euo pipefail
here=$(dirname "$0")
state=${HS_HEALTH_STATE:-/var/lib/hs/health.state}
host=$(hostname)
now=${HS_NOW:-$(date +%s)}
remind=86400

test_msg=false
dry=false
keys_only=false
while [ $# -gt 0 ]; do
  case "$1" in
    --test)    test_msg=true; shift ;;
    --dry-run) dry=true; shift ;;
    --keys)    keys_only=true; dry=true; shift ;;
    *) echo "usage: hs edge health [--test] [--dry-run]"; exit 1 ;;
  esac
done

keys=()
texts=()
while IFS=$'\t' read -r k t; do
  [ -n "$k" ] || continue
  keys+=("$k"); texts+=("$t")
done < <(python3 "$here/lib/edge_facts.py" problems)

if $keys_only; then
  [ ${#keys[@]} -eq 0 ] || printf '%s\n' "${keys[@]}"
  exit 0
fi

if [ ${#texts[@]} -eq 0 ]; then echo "No problems found."; else printf '%s\n' "${texts[@]}"; fi

send() {   # title, message, priority, category
  if $dry; then bash "$here/notify.sh" --dry-run --category "$4" "${@:1:3}"; else bash "$here/notify.sh" --category "$4" "${@:1:3}"; fi
}

if ! $dry && ! $test_msg; then bash "$here/notify.sh" --flush 2>/dev/null || true; fi

if $test_msg; then
  echo
  send "$host: test" "Test message from \`hs edge health --test\`: notifications work." default ok
  exit 0
fi

new=""
[ ${#keys[@]} -eq 0 ] || new=$(printf '%s\n' "${keys[@]}" | sort)
last=0
old=""
if [ -r "$state" ]; then
  last=$(head -n1 "$state")
  old=$(tail -n +2 "$state")
fi
[[ "$last" =~ ^[0-9]+$ ]] || last=0

if ! $dry && ! { mkdir -p "$(dirname "$state")" 2>/dev/null && [ -w "$(dirname "$state")" ]; }; then
  echo
  echo "Can't write $state (not root?): nothing is sent, showing only."
  dry=true
fi

echo
count="${#texts[@]} problem(s)"
if [ "$new" != "$old" ] && [ -n "$new" ]; then
  send "$host: $count" "$(echo '**Needs attention**'; printf '%s\n' "${texts[@]}")" high problem
elif [ "$new" != "$old" ]; then
  send "$host: all clear" "**All clear.** The problems reported earlier are gone." default ok
elif [ -n "$new" ] && [ $((now - last)) -ge "$remind" ]; then
  send "$host: still $count" "$(echo '**Still open since the last message**'; printf '%s\n' "${texts[@]}")" high problem
else
  echo "Nothing to send: unchanged since the last message."
  exit 0
fi

$dry || printf '%s\n%s\n' "$now" "$new" > "$state"
