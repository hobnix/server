# shellcheck shell=bash
# What runs in the container docker, for the callers that must not disturb it (docs/PLAN-docker-instances.md). Needs setting_get (scripts/lib/settings).
# Test knob: HS_INCUS.
#   docker_manager_project <manager>   the compose project of the manager (arcane, portainer; not an app of the person): nothing for webui and none
#   docker_others_running <app>        the running things in Docker that a restart of the container would stop, other than <app> itself and the
#                                      manager: one name per line (compose project, else the container name). Exit 1 when Docker can not be
#                                      read (container stopped, Docker not running, no answer in 8 s): the caller must not go on as if nothing ran.
_dockerapps_lib=$(cd "${BASH_SOURCE[0]%/*}" && pwd)

docker_manager_project() {
  local m=${1:-} f
  f=$_dockerapps_lib/../providers/docker/$m.sh
  [ -n "$m" ] && [ -f "$f" ] || return 0
  ( . "$f"; basename "$manager_dir" )
}

docker_port_owner() {   # docker_port_owner <port> <app>: prints the other Compose project publishing <port> (? for an unlabelled owner), nothing when free
  local port=$1 app=$2 raw
  raw=$(timeout 8 "${HS_INCUS:-incus}" exec docker -- docker ps --format '{{.Label "com.docker.compose.project"}}\t{{.Ports}}' </dev/null 2>/dev/null) || return 1
  printf '%s\n' "$raw" | awk -F'\t' -v port="$port" -v app="$app" '
    $1 != app && $2 ~ (":" port "->") { print ($1 == "" ? "?" : $1); exit }'
}

docker_others_running() {
  local raw skip
  raw=$(timeout 8 "${HS_INCUS:-incus}" exec docker -- docker ps --format '{{.Label "com.docker.compose.project"}}	{{.Names}}' </dev/null 2>/dev/null) || return 1
  skip=$(docker_manager_project "$(setting_get dockerManager 2>/dev/null || true)")
  printf '%s\n' "$raw" | awk -F'\t' -v app="${1:-}" -v skip="$skip" '
    { n = ($1 != "" ? $1 : $2) }
    n == "" || n == app || (skip != "" && n == skip) || seen[n]++ { next }
    { print n }'
}
