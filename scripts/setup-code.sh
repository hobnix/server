#!/usr/bin/env bash
# help: the one-time code of the first web setup: issue a new one on this console, show the state, or start over
# help.de: der Einmalcode der ersten Einrichtung im Browser: hier an der Konsole einen neuen ausstellen, den Stand zeigen oder neu beginnen
# args: issue | status | reset | arm | boot
# The code is printed here and nowhere else (never logged, never mailed, never sent to the web). docs/adr/0022-first-run-console-token.md.
# arm: the installer marks a fresh install as waiting for its setup (no code yet). boot: what the boot unit runs (hs-setup-code.service):
# prints the code with the addresses only while a setup is waiting, prints nothing otherwise. Addresses: <hostname>.local and the IPv4
# address(es), port HS_WEB_PORT (default 8480). Test knobs: HS_SETUP_ADDRS (the addresses, space separated, instead of asking the machine).
# The state is $HS_STATE_DIR/first-run.json (scripts/first_run.py). Test knobs: HS_FIRST_RUN_FILE, HS_STATE_DIR, HS_PYTHON.
set -uo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
py=${HS_PYTHON:-python3}
cmd=${1:-status}
port=${HS_WEB_PORT:-8480}
urls() {   # the addresses to type: the name first, the IP as the fallback when mDNS does not work on the network
  local a
  printf 'http://%s.local:%s
' "$(hostname)" "$port"
  if [ -n "${HS_SETUP_ADDRS+x}" ]; then
    for a in $HS_SETUP_ADDRS; do printf 'http://%s:%s
' "$a" "$port"; done
  else
    ip -4 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print "http://" a[1] ":'"$port"'"}'
  fi
}
case "$cmd" in
  arm)
    [ "$(id -u)" = 0 ] || [ -n "${HS_FIRST_RUN_FILE:-}" ] || fail "$(t 'This needs root: sudo hs setup-code arm')"
    "$py" "$here/first_run.py" arm ;;
  boot)
    # wait (up to a minute) for an address, so the banner has one; without it the name is still printed
    for _ in $(seq 1 ${HS_SETUP_WAIT:-30}); do
      [ -n "${HS_SETUP_ADDRS+x}" ] || ip -4 -o addr show scope global 2>/dev/null | grep -q . || { sleep 2; continue; }
      break
    done
    mapfile -t u < <(urls)
    args=(); for x in "${u[@]}"; do args+=("--url=$x"); done
    # /dev/console (the unit's stdout) reaches only the last console= of the kernel line (the screen); the serial port gets its own copy
    out=$("$py" "$here/first_run.py" issue --only-pending "${args[@]}") || exit 0
    printf '%s
' "$out"
    serial=${HS_SETUP_SERIAL-/dev/ttyS0}
    if [ -n "$serial" ] && [ -c "$serial" ] && [ -w "$serial" ]; then printf '%s
' "$out" > "$serial" 2>/dev/null || true; fi ;;
  issue|reset)
    [ "$(id -u)" = 0 ] || [ -n "${HS_FIRST_RUN_FILE:-}" ] || fail "$(t 'This needs root: sudo hs setup-code %s' "$cmd")"
    args=(); if [ "$cmd" = issue ]; then mapfile -t u < <(urls); for x in "${u[@]}"; do args+=("--url=$x"); done; fi
    "$py" "$here/first_run.py" "$cmd" "${args[@]}" || fail "$(t 'The first setup is already done. To start over: sudo hs setup-code reset')" ;;
  status)
    IFS=$'\t' read -r state detail < <("$py" "$here/first_run.py" status)
    case "$state" in
      pending) ok "$(t 'A setup code is waiting (valid for another %s s).' "$detail")" ;;
      expired) note "$(t 'The setup code has expired: sudo hs setup-code issue')" ;;
      burned)  note "$(t 'The setup code was used up by wrong tries: sudo hs setup-code issue')" ;;
      done)    ok "$(t 'The first setup is done (admin: %s).' "$detail")" ;;
      *)       note "$(t 'No first setup is waiting on this server.')" ;;
    esac ;;
  *) fail "$(t 'Usage: hs setup-code issue | status | reset')" ;;
esac
