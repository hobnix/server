#!/usr/bin/env bash
# help: get into a container or VM: shell, one command, its logs, or its console
# help.de: in einen Container oder eine VM: Shell, ein einzelner Befehl, Logs oder Konsole
# args: <container> shell | exec <command...> | logs [lines] | console
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
incus=${HS_INCUS:-incus}

usage() {
  say "usage: hs ct <container> shell"
  say "       hs ct <container> exec <command...>"
  say "       hs ct <container> logs [lines]"
  say "       hs ct <container> console      (leave with Ctrl+a q)"
  exit 1
}

[ $# -ge 2 ] || usage
ct=$1; verb=$2; shift 2
"$incus" info "$ct" >/dev/null 2>&1 || fail "$(t "No instance called '%s'. See: hs ct list" "$ct")"

case "$verb" in
  shell)   exec "$incus" exec "$ct" -- su -l ;;
  exec)    [ $# -ge 1 ] || usage; exec "$incus" exec "$ct" -- "$@" ;;
  logs)    n=${1:-100}
           [[ "$n" =~ ^[0-9]+$ ]] || usage
           "$incus" exec "$ct" -- journalctl -n "$n" --no-pager 2>/dev/null || "$incus" info "$ct" --show-log ;;
  console) exec "$incus" console "$ct" ;;
  *)       usage ;;
esac
