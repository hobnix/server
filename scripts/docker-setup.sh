#!/usr/bin/env bash
# help: turn Docker on from the web interface: what would happen (plan), then do it (start)
# help.de: Docker über die Weboberfläche einschalten: was passieren würde (plan), dann ausführen (start)
# args: plan|start setup --set <key>=<value>... | plan|start mount <share|remote:peer> --path <p> [--as uid:gid]
# System command (hs sys docker plan|start setup), for the interface and tests. It never asks and prints plain key<TAB>value lines like
# gateway-setup.sh. The keys are the ones of the steps in capabilities/docker/capability.toml: dockerManager (webui|arcane|portainer|none)
# and dockerSize (s|m|l). The work is done by `hs docker enable` (scripts/docker.sh); this script only checks and translates.
#   plan: exit 0 = allowed, 1 = refused. It changes NOTHING (docker.sh enable --dry-run). Output: status ok|refused, reason<TAB><text> |
#     heading|step|note<TAB><line>, long<TAB>yes. Refused when hobnix owns the container already (listed as on without a container is fine), when an instance called docker exists, or for a bad value.
#   start: the same checks, then `hs docker enable --yes --job`: the container is made in a background job (status started, unit).
#   mount: the folder of a share in Docker (hs sys docker plan|start mount <share|remote:peer> --path /shares/<share> [--as uid:gid]).
#     --as defaults to the user the container maps already (raw.idmap), else 1000:1000. The plan runs the checks of `docker.sh mount --dry-run`,
#     and for a local share whose mapping changes warns that Docker restarts, with every running app; start is `docker.sh mount --yes --job`.
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

mapped_as() {   # the user the container docker maps onto the share owner already (raw.idmap), as uid:gid; nothing when none
  local m u g
  m=$("${HS_INCUS:-incus}" config get docker raw.idmap 2>/dev/null </dev/null || true)
  u=$(sed -n 's/^uid 1000 \([0-9][0-9]*\)$/\1/p' <<<"$m" | head -n 1)
  g=$(sed -n 's/^gid 100 \([0-9][0-9]*\)$/\1/p' <<<"$m" | head -n 1)
  if [ -n "$u" ] && [ -n "$g" ]; then printf '%s:%s\n' "$u" "$g"; fi
}

mount_main() {   # mount_main <plan|start> <share|remote:peer> --path <p> [--as uid:gid]
  local verb=$1 src=${2:-} path= as= have apps out rc l args unit
  shift 2 || refuse "no share given"
  while [ $# -gt 0 ]; do
    case "$1" in
      --path) [ $# -ge 2 ] || refuse "--path needs a value"; path=$2; shift 2 ;;
      --as) [ $# -ge 2 ] || refuse "--as needs a value"; as=$2; shift 2 ;;
      *) refuse "unknown argument: $1" ;;
    esac
  done
  [ -n "$src" ] && [ -n "$path" ] || refuse "a share and --path are needed"
  have=$(mapped_as)
  case "$src" in
    remote:*) [ -z "$as" ] || refuse "a remote share is read only and takes no --as" ;;
    *) [ -n "$as" ] || as=${have:-1000:1000} ;;
  esac
  args=(mount "$src" "$path"); [ -z "$as" ] || args+=(--as "$as")
  export HS_PLAIN=1 HS_LANG=en HS_CALLER=web
  rc=0; out=$(docker_sh "${args[@]}" --dry-run </dev/null 2>&1) || rc=$?
  [ "$rc" = 0 ] || refuse "$(last_line <<<"$out")"
  if [ "$verb" = plan ]; then
    printf 'status\tok\nheading\tGive Docker a folder\n'
    while IFS= read -r l; do
      case "$l" in
        '  '[0-9]*'. '*) printf 'step\t%s\n' "${l#"${l%%[![:space:]]*}"}" ;;
      esac
    done <<<"$out"
    if [ -n "$as" ] && [ "$as" != "$have" ]; then   # the mapping changes: Docker restarts, and every app with it
      apps=$(docker_sh --list </dev/null 2>/dev/null | awk -F'\t' '$4 == "running" { printf "%s%s", (n++ ? ", " : ""), $1 }' || true)
      printf 'warn\tDocker restarts, and with it every app: %s\n' "${apps:-none is running now}"
    fi
    printf 'command\ths docker mount %s %s%s --yes --job\nlong\tyes\n' "$src" "$path" "${as:+ --as $as}"
    exit 0
  fi
  rc=0; out=$(docker_sh "${args[@]}" --yes --job </dev/null 2>&1) || rc=$?
  [ "$rc" = 0 ] || refuse "$(last_line <<<"$out")"
  unit=$(sed -n 's/^.*Started in the background: //p' <<<"$out" | head -n 1)
  printf 'status\tstarted\n'
  [ -z "$unit" ] || printf 'unit\t%s\n' "$unit"
  exit 0
}

verb=${1:-}; action=${2:-}
case "$verb" in plan|start) ;; *) echo "usage: docker-setup.sh plan|start setup --set <key>=<value>... | mount <share|remote:peer> --path <p>" >&2; exit 1 ;; esac
case "$action" in
  setup) ;;
  mount) shift 2; mount_main "$verb" "$@" ;;
  *) refuse "unknown action (setup, mount)" ;;
esac
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

# on = hobnix owns the container (docker.sh --status); docker only LISTED in machine.toml or dockerManager set, without a container, may be set up
if docker_sh --status 2>/dev/null </dev/null | grep -qx "owned$(printf '	')yes"; then refuse "Docker is on already."; fi
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
