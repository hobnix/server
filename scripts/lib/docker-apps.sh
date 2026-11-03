# shellcheck shell=bash
# What runs in the container docker, for the callers that must not disturb it (docs/PLAN-docker-instances.md). Needs setting_get (scripts/lib/settings).
# Test knob: HS_INCUS.
#   docker_manager_project <manager>   the compose project of the manager (arcane, portainer; not an app of the person): nothing for webui and none
#   docker_others_running <app>        the running things in Docker that a restart of the container would stop, other than <app> itself and the
#                                      manager: one name per line (compose project, else the container name). Exit 1 when Docker can not be
#                                      read (container stopped, Docker not running, no answer in 8 s): the caller must not go on as if nothing ran.
#   docker_app_dir <app>               the folder of the app inside docker, ONE exec: $DOCKER_APPS_ROOT/stacks/<app> when it holds a docker-compose.yml,
#                                      else the legacy /opt/apps/<app> (an app that is there keeps its compose AND data there), else
#                                      $DOCKER_APPS_ROOT/recipes/<app>; exit 1 when none
#   docker_apps_mounted                exit 0 when $DOCKER_APPS_ROOT is a mountpoint inside docker (one exec): no new app goes there otherwise
#   docker_app_kind <app>              web | recipe | legacy (where docker_app_dir found it); exit 1 when none
#   docker_new_app_dir <app> web|recipe  where a NEW app goes: $DOCKER_APPS_ROOT/stacks/<app> or recipes/<app> (no exec, the folder is not made)
# The share `apps` (host /fast/shares/apps) is mounted in docker at /shares/apps (docs/PLAN-docker-instances.md).
_dockerapps_lib=$(cd "${BASH_SOURCE[0]%/*}" && pwd)
DOCKER_APPS_ROOT=${HS_DOCKER_APPS_ROOT:-/shares/apps}   # the HS_ knobs are for tests
DOCKER_APPS_LEGACY=${HS_DOCKER_APPS_LEGACY:-/opt/apps}

docker_app_find() {   # docker_app_find <app>: prints "kind<TAB>folder" (web|recipe|legacy), exit 1 when the app has no folder
  local app=${1:-} out
  [[ "$app" =~ ^[a-z0-9][a-z0-9_-]{0,40}$ ]] || return 1
  out=$(timeout 8 "${HS_INCUS:-incus}" exec docker -- sh -c '
    a=$1; r=$2; l=$3
    if [ -f "$r/stacks/$a/docker-compose.yml" ]; then printf "web\t%s\n" "$r/stacks/$a"
    elif [ -d "$l/$a" ]; then printf "legacy\t%s\n" "$l/$a"
    elif [ -d "$r/recipes/$a" ]; then printf "recipe\t%s\n" "$r/recipes/$a"
    else exit 1
    fi' sh "$app" "$DOCKER_APPS_ROOT" "$DOCKER_APPS_LEGACY" </dev/null 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}
docker_apps_mounted() {
  timeout 8 "${HS_INCUS:-incus}" exec docker -- sh -c 'mountpoint -q "$1"' sh "$DOCKER_APPS_ROOT" </dev/null >/dev/null 2>&1
}
docker_app_dir() { local r; r=$(docker_app_find "$1") || return 1; printf '%s\n' "${r#*$'\t'}"; }
docker_app_kind() { local r; r=$(docker_app_find "$1") || return 1; printf '%s\n' "${r%%$'\t'*}"; }
docker_new_app_dir() {   # docker_new_app_dir <app> web|recipe
  case "${2:-}" in
    web) printf '%s/stacks/%s\n' "$DOCKER_APPS_ROOT" "$1" ;;
    recipe) printf '%s/recipes/%s\n' "$DOCKER_APPS_ROOT" "$1" ;;
    *) return 1 ;;
  esac
}

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
