#!/usr/bin/env bash
# help: the fixed address of an instance at the router: show, set or clear
# help.de: die feste Adresse einer Instanz am Router: anzeigen, setzen oder entfernen
# args: <container> [show | set <address> | clear] [--dry-run]
# Looks up the pinned MAC of the instance and calls unifi.sh. HS_UNIFI and HS_INCUS point tests at stand-ins.
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
unifi=${HS_UNIFI:-$here/unifi.sh}
incus=${HS_INCUS:-incus}

usage() {
  say "usage: hs net ip <container>              show the reserved address"
  say "       hs net ip <container> set <address> [--dry-run]"
  say "       hs net ip <container> clear [--dry-run]"
  exit 1
}

dry=()
args=()
for a in "$@"; do if [ "$a" = --dry-run ]; then dry=(--dry-run); else args+=("$a"); fi; done
set -- ${args[@]+"${args[@]}"}
[ $# -ge 1 ] || usage
ct=$1; verb=${2:-show}
"$incus" info "$ct" >/dev/null 2>&1 || fail "$(t "No instance called '%s'. See: hs ct list" "$ct")"
mac=$("$incus" config device get "$ct" eth0 hwaddr 2>/dev/null || true)
[ -n "$mac" ] || mac=$("$incus" config get "$ct" volatile.eth0.hwaddr 2>/dev/null || true)
[ -n "$mac" ] || fail "$(t "No MAC found for '%s'. Pin it first: hs mac %s" "$ct" "$ct")"

case "$verb" in
  show)  ip=$(bash "$unifi" reserved "$mac" || true)
         if [ -n "$ip" ]; then step "$ct"; kv "Address" "$ip"; kv "MAC" "$mac"; else note "$(t 'No address reserved for %s (%s).' "$ct" "$mac")"; fi ;;
  set)   [ $# -eq 3 ] || usage
         ip=$3
         [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "$(t "'%s' is not an IPv4 address." "$ip")"
         who=$(bash "$unifi" used "$ip" || true)
         [ -z "$who" ] || [ "$who" = "$mac" ] || fail "$(t '%s is in use: %s' "$ip" "$who")"
         bash "$unifi" set-ip "$mac" "$ip" "$ct" ${dry[@]+"${dry[@]}"}
         note "$(t 'The instance takes it over after a restart: hs ct %s restart' "$ct")" ;;
  clear) bash "$unifi" clear-ip "$mac" ${dry[@]+"${dry[@]}"}
         note "$(t 'The instance gets a new address after a restart: hs ct %s restart' "$ct")" ;;
  *)     usage ;;
esac
