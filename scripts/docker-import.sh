#!/usr/bin/env bash
# help: -
# help.de: -
# args: <compose-file|-> --name <app> [--env-file <file>] [--dry-run] [--yes --confirm <app>] [--allow-risky] [--job]
# hs docker import: bring a compose file (docker-compose.yml from the internet, from another server) into Docker as a web-managed app.
# The plan comes first and always: services, images, ports, volumes (bind mounts; named volumes cannot be mapped), networks, the NAMES of the
# environment variables (never the values), every key hobnix does not import or has not tested, and what is dangerous. Nothing starts before the
# typed name (or --yes --confirm <app>). Levels: error (the route cannot honour it) and refuse (docker.sock, privileged, host path /, /etc, /proc,
# /sys, /boot) stop the import for good; risky (host network, pid/ipc host, cap_add SYS_ADMIN|NET_ADMIN|ALL, devices outside /dev/dri, a bind mount
# outside the app folder, security_opt unconfined, userns_mode host) needs --allow-risky AND the typed name.
# The work is done by the one existing route: the document goes to `docker-app-change.sh start <app> app-save --rev new` (it checks again and writes
# the files). The env file travels on stdin only, never as an argument. --dry-run prints the plan only: exit 0 ok, 1 refused. CLI only: no hs sys row.
# The analysis is scripts/lib/docker_import.py (reads `docker compose config --format json`, run in the container docker).
# Test knobs: HS_INCUS, HS_DOCKER_SH, HS_DOCKER_APP_CHANGE (stand in for incus, docker.sh, docker-app-change.sh), HS_DOCKER_SKIP_CHECK=1.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/ui.sh"
. "$here/lib/docker-apps.sh"

APP_RE='^[a-z0-9][a-z0-9_-]{0,40}$'
CT=docker

usage() { fail "$(t 'Usage: hs docker import <compose-file|-> --name <app> [--env-file <file>] [--dry-run] [--yes --confirm <app>] [--allow-risky] [--job]')"; }

src= name= envfile= dry=0 yes=0 confirm_arg= risky_ok=0 job=0
while [ $# -gt 0 ]; do
  case "$1" in
    --name) [ $# -ge 2 ] || usage; name=$2; shift 2 ;;
    --env-file) [ $# -ge 2 ] || usage; envfile=$2; shift 2 ;;
    --confirm) [ $# -ge 2 ] || usage; confirm_arg=$2; shift 2 ;;
    --dry-run) dry=1; shift ;;
    --yes) yes=1; shift ;;
    --allow-risky) risky_ok=1; shift ;;
    --job) job=1; shift ;;
    -h|--help) usage ;;
    -) [ -z "$src" ] || usage; src=-; shift ;;
    -*) fail "$(t 'Unknown option: %s' "$1")" ;;
    *) [ -z "$src" ] || usage; src=$1; shift ;;
  esac
done
[ -n "$src" ] && [ -n "$name" ] || usage
[[ "$name" =~ $APP_RE ]] || fail "$(t 'The app name is not valid: lower case letters, digits, - and _.')"

compose=
if [ "$src" = - ]; then
  IFS= read -r -d '' compose || true
else
  [ -f "$src" ] && [ -r "$src" ] || fail "$(t 'Cannot read the compose file: %s' "$src")"
  IFS= read -r -d '' compose <"$src" || true
fi
[ -n "$compose" ] || fail "$(t 'The compose file is empty.')"
envtext=
have_env=0
if [ -n "$envfile" ]; then
  [ -f "$envfile" ] && [ -r "$envfile" ] || fail "$(t 'Cannot read the env file: %s' "$envfile")"
  IFS= read -r -d '' envtext <"$envfile" || true
  have_env=1
fi

docker_ok() {
  [ -z "${HS_DOCKER_SKIP_CHECK:-}" ] || return 0
  local k v on=off run=no
  while IFS=$'\t' read -r k v; do
    case "$k" in state) on=$v ;; running) run=$v ;; esac
  done < <(bash "${HS_DOCKER_SH:-$here/docker.sh}" --status </dev/null 2>/dev/null || true)
  [ "$on" = on ] && [ "$run" = yes ]
}
docker_ok || fail "$(t 'Docker is not on or not running (hs docker enable).')"

app_dir=$(docker_new_app_dir "$name" web)

# the document of the route: compose, NUL, then the whole env text as one "*" record
doc() {
  printf '%s\0' "$compose"
  if [ "$have_env" = 1 ]; then printf '*%s\0' "$envtext"; fi
}

# the resolved config as JSON, made in the container from a throwaway folder (the env values never come back)
config_json() {
  doc | timeout 40 "${HS_INCUS:-incus}" exec "$CT" -- bash -c '
    set -uo pipefail
    d=$(mktemp -d) || exit 1
    trap "rm -rf \"$d\"" EXIT
    IFS= read -r -d "" c || true
    IFS= read -r -d "" e || true
    printf "%s" "$c" > "$d/c.yml"
    case "$e" in \**) printf "%s\n" "${e#\*}" > "$d/.env" ;; *) : > "$d/.env" ;; esac
    docker compose -p "$1" --project-directory "$2" -f "$d/c.yml" --env-file "$d/.env" config --format json
  ' sh "$name" "$app_dir"
}

errf=$(mktemp); trap 'rm -f "$errf"' EXIT
json=$(config_json 2>"$errf") || {
  # the message may quote a line of the env file (a secret): never print it, only line numbers
  warn "$(t 'The compose file or env file is not valid.')"
  lines=$(grep -oiE 'line [0-9]+' "$errf" | grep -oE '[0-9]+' | sort -un | head -n 5 | paste -sd, -) || lines=
  [ -z "$lines" ] || note "$(t 'Line numbers named in the error: %s' "$lines")"
  exit 1
}
analysis=$(printf '%s' "$json" | python3 -I "$here/lib/docker_import.py" --app-dir "$app_dir") || fail "$(t 'The compose file could not be read.')"

n_err=0 n_ref=0 n_risky=0 n_warn=0
show() {   # show <heading> <kind>: the lines of one kind
  local h=$1 kind=$2 k lv where text first=1
  while IFS=$'\t' read -r k lv where text; do
    [ "$k" = "$kind" ] || continue
    if [ "$first" = 1 ]; then step "$h"; first=0; fi
    case "$lv" in
      info) kv "$where" "$text" ;;
      warn) warn "$text ($where)" ;;
      *) danger "$(t '%s: %s (%s)' "$lv" "$text" "$where")" ;;
    esac
  done <<<"$analysis"
}
while IFS=$'\t' read -r k lv where text; do
  case "$lv" in error) n_err=$((n_err + 1)) ;; refuse) n_ref=$((n_ref + 1)) ;; risky) n_risky=$((n_risky + 1)) ;; warn) n_warn=$((n_warn + 1)) ;; esac
done <<<"$analysis"

step "$(t 'Import plan for %s' "$name")"
kv "$(t 'app folder')" "$app_dir"
show "$(t 'Services')" service
show "$(t 'Ports')" port
show "$(t 'Volumes')" volume
show "$(t 'Networks')" network
show "$(t 'Environment (names only)')" env
show "$(t 'Not imported or not tested')" unsupported
show "$(t 'Dangerous settings')" danger

# the route itself: it knows the folder, the ports in use, the vault; its findings are shown, nothing is written
route() { bash "${HS_DOCKER_APP_CHANGE:-$here/docker-app-change.sh}" "$@"; }
route_out=
route_rc=0
if [ "$n_err" -eq 0 ] && [ "$n_ref" -eq 0 ]; then
  route_out=$(doc | route plan "$name" app-save --rev new 2>/dev/null) || route_rc=$?
  if [ "$route_rc" -ne 0 ]; then
    step "$(t 'Checks of Docker')"
    while IFS=$'\t' read -r k a b c; do
      case "$k" in
        reason) danger "$(t 'refused: %s' "$a")" ;;
        finding) [ "$a" = error ] && danger "$(t 'error: %s (%s)' "$c" "$b")" || warn "$c ($b)" ;;
      esac
    done <<<"$route_out"
    n_err=$((n_err + 1))
  fi
fi

if [ "$n_ref" -gt 0 ]; then
  danger "$(t 'Refused: %s settings can never be imported. Nothing was changed.' "$n_ref")"
  exit 1
fi
if [ "$n_err" -gt 0 ]; then
  danger "$(t 'Refused: %s problems stop the import. Fix the compose file. Nothing was changed.' "$n_err")"
  exit 1
fi
if [ "$n_risky" -gt 0 ] && [ "$risky_ok" -ne 1 ]; then
  danger "$(t 'Refused: the file asks for %s dangerous settings. Nothing was changed.' "$n_risky")"
  note "$(t 'To import it anyway, look at every line above and add --allow-risky.')"
  exit 1
fi
if [ "$n_risky" -gt 0 ]; then warn "$(t '--allow-risky: you accept the dangerous settings above.')"; fi
if [ "$n_warn" -gt 0 ]; then note "$(t '%s keys are not imported or not tested; they stay in the file as they are.' "$n_warn")"; fi

if [ "$dry" = 1 ]; then ok "$(t 'Preview only (--dry-run): nothing was changed.')"; exit 0; fi

if [ "$yes" = 1 ]; then
  [ "$confirm_arg" = "$name" ] || fail "$(t '--yes needs --confirm %s.' "$name")"
else
  { [ -t 0 ] && [ -t 1 ]; } || fail "$(t 'This needs a terminal: nothing is imported without the typed name. Use --yes --confirm %s.' "$name")"
  confirm_name "$name" "$(t 'app')" || fail "$(t 'The name did not match. Nothing was changed.')"
  if [ "$job" = 0 ] && confirm "$(t 'Run in the background?')"; then job=1; fi
fi

step "$(t 'Importing %s' "$name")"
res=
rc=0
if [ "$job" = 1 ]; then res=$(doc | route start "$name" app-save --rev new 2>&1) || rc=$?
else res=$(doc | HS_DOCKER_NO_JOB=1 route start "$name" app-save --rev new 2>&1) || rc=$?; fi
unit=
while IFS=$'\t' read -r k a; do
  case "$k" in
    reason) [ "$rc" -eq 0 ] || danger "$(t 'refused: %s' "$a")" ;;
    unit) unit=$a ;;
  esac
done <<<"$res"
[ "$rc" -eq 0 ] || fail "$(t 'The import failed. Nothing was started.')"
if [ -n "$unit" ]; then ok "$(t 'Started in the background: %s' "$unit")"; else ok "$(t 'The app %s was created and started.' "$name")"; fi
next_step "hs docker list"
