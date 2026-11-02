#!/usr/bin/env bash
# help: turn Docker on from the web interface: what would happen (plan), then do it (start)
# help.de: Docker über die Weboberfläche einschalten: was passieren würde (plan), dann ausführen (start)
# args: plan|start setup --set <key>=<value>...
# System command (hs sys docker plan|start setup), for the interface and tests. It never asks and prints plain key<TAB>value lines like
# gateway-setup.sh. The keys are the ones of the steps in capabilities/docker/capability.toml: dockerManager (webui|arcane|portainer|none)
# and dockerSize (s|m|l). The work is done by `hs docker enable` (scripts/docker.sh); this script only checks and translates.
#   plan: exit 0 = allowed, 1 = refused. It changes NOTHING (docker.sh enable --dry-run). Output: status ok|refused, reason<TAB><text> |
#     heading|step|note<TAB><line>, long<TAB>yes. Refused when Docker is on already, when an instance called docker exists, or for a bad value.
#   start: the same checks, then `hs docker enable --yes --job`: the container is made in a background job (status started, unit).
# Test knobs: HS_DOCKER_SCRIPT (stands in for docker.sh), and the knobs of docker.sh.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/capability.sh"

refuse() { printf 'status\trefused\nreason\t%s\n' "$1"; exit 1; }
docker_sh() { if [ -n "${HS_DOCKER_SCRIPT:-}" ]; then "$HS_DOCKER_SCRIPT" "$@"; else bash "$here/docker.sh" "$@"; fi; }
last_line() {   # the reason: the last line that starts with the failure glyph (not the dim "Fix:" line under it); else the last line
  local all; all=$(cat)
  { grep '^[[:space:]]*✗' <<<"$all" || true; } | tail -n 1 | sed -e 's/^[[:space:]]*✗[[:space:]]*//' | grep . || tail -n 1 <<<"$all"
}

verb=${1:-}; action=${2:-}
case "$verb" in plan|start) ;; *) echo "usage: docker-setup.sh plan|start setup --set <key>=<value>..." >&2; exit 1 ;; esac
[ "$action" = setup ] || refuse "unknown action (setup)"
shift 2

manager= size=
while [ $# -gt 0 ]; do
  [ "$1" = --set ] && [ $# -ge 2 ] || refuse "unknown argument: $1"
  case "$2" in
    dockerManager=webui|dockerManager=arcane|dockerManager=portainer|dockerManager=none) manager=${2#*=} ;;
    dockerSize=s|dockerSize=m|dockerSize=l) size=${2#*=} ;;
    dockerManager=*) refuse "dockerManager must be webui, arcane, portainer or none" ;;
    dockerSize=*) refuse "dockerSize must be s, m or l" ;;
    *) refuse "only dockerManager and dockerSize can be set here" ;;
  esac
  shift 2
done
[ -n "$manager$size" ] || refuse "nothing to set (dockerManager, dockerSize)"
args=(--manager "${manager:-webui}")
[ -z "$size" ] || args+=(--size "$size")

if capability_on docker; then refuse "Docker is on already."; fi
export HS_PLAIN=1 HS_LANG=en HS_CALLER=web
rc=0; out=$(docker_sh enable --dry-run "${args[@]}" </dev/null 2>&1) || rc=$?
[ "$rc" = 0 ] || refuse "$(last_line <<<"$out")"

if [ "$verb" = plan ]; then
  printf 'status\tok\nheading\tTurn Docker on\n'
  while IFS= read -r l; do
    case "$l" in
      ''|'──'*) ;;
      '    '*) printf 'note\t%s\n' "${l#"${l%%[![:space:]]*}"}" ;;
      *) printf 'step\t%s\n' "${l#"${l%%[![:space:]]*}"}" ;;
    esac
  done <<<"$out"
  printf 'command\ths docker enable --yes --job\n'
  printf 'long\tyes\n'
  exit 0
fi

rc=0; out=$(docker_sh enable --yes --job "${args[@]}" </dev/null 2>&1) || rc=$?
[ "$rc" = 0 ] || refuse "$(last_line <<<"$out")"
unit=$(sed -n 's/^.*Started in the background: //p' <<<"$out" | head -n 1)
printf 'status\tstarted\n'
[ -z "$unit" ] || printf 'unit\t%s\n' "$unit"
