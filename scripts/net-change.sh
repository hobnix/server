#!/usr/bin/env bash
# help: connect the router (UniFi) without asking anything: what would happen (plan), then do it (start)
# help.de: den Router (UniFi) verbinden, ohne Rückfragen: was passieren würde (plan), dann ausführen (start)
# args: plan|start setup --address <url>   (the API key is ONE LINE ON STANDARD INPUT)
# System command (hs sys net plan|start): for the interface and tests. It never asks and prints plain key<TAB>value lines like backup-change.sh.
# The work is unifi.sh's `setup --address <url> --stdin`: the address and the key are kept in a root-only file (inside the vault when there is one),
# the runtime setting networkProvider is set to unifi (which switches the capability network on) and the router is asked once for its networks.
#   setup   the key travels on standard input only, never in an argument, the environment or a log. It replaces an address and key stored before.
# plan: exit 0 = allowed, 1 = refused, 2 = something is missing (status needs, needs<TAB>address|key). Output: status ok|refused|needs,
#   reason<TAB><text>, heading|step|note|warn|command<TAB><line>, long<TAB>no. The plan reads the first line of standard input only to see that a key
#   is there; it prints nothing of it.
# start: the same checks, then the work; status done, or refused with the reason (the router did not answer, the key was refused).
# Test knobs: HS_UNIFI (stand-in for unifi.sh), HS_STATE_DIR.
set -euo pipefail
here=$(dirname "$0")
unifi=${HS_UNIFI:-$here/unifi.sh}
state=${HS_STATE_DIR:-/var/lib/hs}

refuse() { printf 'status\trefused\nreason\t%s\n' "$1"; exit 1; }

verb=${1:-}; action=${2:-}
case "$verb" in plan|start) ;; *) echo "usage: net-change.sh plan|start setup --address <url>" >&2; exit 1 ;; esac
[ "$action" = setup ] || refuse "unknown action (setup)"
shift 2 || true
address=""
while [ $# -gt 0 ]; do
  case "$1" in
    --address) [ $# -ge 2 ] || refuse "--address needs a value"; address=$2; shift 2 ;;
    *) refuse "unknown option $1" ;;
  esac
done
needs=()
[ -n "$address" ] || needs+=(address)
key=""
IFS= read -r -t 3 key || true
[ -n "$key" ] || needs+=(key)
if [ ${#needs[@]} -gt 0 ]; then
  printf 'status\tneeds\n'
  printf 'needs\t%s\n' "${needs[@]}"
  exit 2
fi
[[ "${address%/}" =~ ^https?://[A-Za-z0-9._:-]{1,100}$ ]] || refuse "That is not an address of the router (like https://10.10.10.1)."
[[ "$key" != *[[:cntrl:]]* ]] || refuse "The key has a control character."

export HS_PLAIN=1 HS_LANG=en HS_CALLER=${HS_CALLER:-ui}
unset HS_GUIDED_TTY

if [ "$verb" = start ]; then
  rc=0
  out=$(printf '%s\n' "$key" | bash "$unifi" setup --address "${address%/}" --stdin 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    reason=$(printf '%s' "$out" | sed -e 's/^[[:space:]]*//' -e 's/^[✗!] *//' | awk 'NF' | tail -n 1)
    refuse "${reason:-the router could not be connected} (the address and key may be saved already; run hs net check to look at it)"
  fi
  printf 'status\tdone\n'
  exit 0
fi

printf 'status\tok\nheading\tconnect the router at %s\n' "${address%/}"
printf 'step\tsave the address and the API key (root only, inside the vault when there is one)\n'
printf 'step\tswitch the router connection on and ask the router for its networks once\n'
if [ -e "$state/unifi" ] || [ -L "$state/unifi" ]; then printf 'warn\tThe address and key stored before are replaced.\n'; fi
printf 'note\tThe key is made in UniFi: Network, Settings, Control Plane, Integrations, Create API Key. It is full Network admin there; this server only reads the networks and writes fixed addresses inside the container network.\n'
printf 'command\ths net setup\nlong\tno\n'
exit 0
