#!/usr/bin/env bash
# Variant "unifi" of the network capability (capabilities/network/NOTES.md): the verbs the recipes use, over scripts/unifi.sh.
#   info | ready | used <ip> | reserved <mac> | set-ip <mac> <ip> [name]
set -euo pipefail
here=$(dirname "$0")/../..
. "$here/lib/secret.sh"
state=${HS_STATE_DIR:-/var/lib/hs}
case "${1:-}" in
  info) printf 'unifi\tUniFi router\n' ;;
  ready)
    [ "$(secret_state "$state/unifi")" != locked ] || exit 3
    [ -r "$state/unifi" ] ;;
  used|reserved|set-ip) exec bash "$here/unifi.sh" "$@" ;;
  *) echo "usage: unifi.sh info|ready|used <ip>|reserved <mac>|set-ip <mac> <ip> [name]" >&2; exit 2 ;;
esac
