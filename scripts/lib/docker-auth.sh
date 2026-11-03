# shellcheck shell=bash
# Registry logins for the apps in the container docker (docs/PLAN-docker-instances.md, Slice C). Sourced after ui.sh:
#   . "$here/lib/docker-auth.sh"
# The token of a private registry (ghcr.io) lives in the vault (secret.sh), never in /root/.docker. A pull or build gets it for ONE command:
# the host feeds `host<TAB>user<TAB>token` lines on the stdin of one `incus exec docker -- sh -c`, which logs in with a throwaway
# DOCKER_CONFIG on tmpfs (0700, removed by a trap) and runs the compose command. The token is never in argv or the environment.
# Test knob: HS_INCUS, HS_STATE_DIR.
#
#   docker_registries_file               /var/lib/hs/docker-registries.tsv (host<TAB>user, not secret)
#   docker_registry_token_file <host>    /var/lib/hs/docker-registry-<host>
#   docker_registry_state <host>         ok | locked | missing   (secret_state of the token file)
#   docker_image_hosts                   image names on stdin -> the registry hosts they name (one per line, unique)
#   docker_app_images <app> [<compose file> <env file>]   the images of an app (compose config --images), run in the container
#   docker_auth_hosts <app> [<compose file> <env file>]   the registered hosts that an image of the app names
#   docker_auth_locked <host>...         prints the first host whose token is locked (exit 0), exit 1 when none is
#   docker_auth_lines <host>...          the stdin lines host<TAB>user<TAB>token of the hosts whose token is readable
#   DOCKER_AUTH_LOGIN                    shell code for the container: logs in from stdin into a throwaway DOCKER_CONFIG, sets a cleanup trap
#   docker_with_auth <app> <compose args...>   run `docker compose -p <app> <args>` in the folder of the app ($DOCKER_AUTH_DIR, else docker_app_dir) with the logins
. "${BASH_SOURCE[0]%/*}/secret.sh"
. "${BASH_SOURCE[0]%/*}/docker-apps.sh"

docker_registries_file() { printf '%s/docker-registries.tsv\n' "${HS_STATE_DIR:-/var/lib/hs}"; }
docker_registry_token_file() { printf '%s/docker-registry-%s\n' "${HS_STATE_DIR:-/var/lib/hs}" "$1"; }
docker_registry_state() { secret_state "$(docker_registry_token_file "$1")"; }
docker_registry_user() {   # docker_registry_user <host>: the user of an entry, nothing when none
  awk -F'\t' -v h="$1" '$1 == h { print $2; exit }' "$(docker_registries_file)" 2>/dev/null || true
}

docker_image_hosts() {
  awk '
    { sub(/[@].*$/, ""); n = split($0, p, "/"); if (n < 2) next
      h = p[1]; if (h ~ /[.:]/ || h == "localhost") if (!seen[h]++) print h }'
}

_auth_dir() { docker_app_dir "$1" 2>/dev/null || printf '%s/%s\n' "$DOCKER_APPS_LEGACY" "$1"; }   # the folder of the app (lib/docker-apps.sh)

docker_app_images() {   # docker_app_images <app> [<compose file> <env file>]
  local app=$1 file=${2:-} env=${3:-} dir=${DOCKER_AUTH_DIR:-$(_auth_dir "$1")}
  timeout 30 "${HS_INCUS:-incus}" exec docker -- sh -c '
    app=$1; file=$2; env=$3; dir=$4
    if [ -n "$file" ]; then
      docker compose -p "$app" --project-directory "$dir" -f "$file" ${env:+--env-file "$env"} config --images
    else
      cd "$dir" && docker compose -p "$app" config --images
    fi' sh "$app" "$file" "$env" "$dir" </dev/null 2>/dev/null || true
}

docker_auth_hosts() {
  local used h
  used=$(docker_app_images "$@" | docker_image_hosts)
  [ -n "$used" ] || return 0
  [ -s "$(docker_registries_file)" ] || return 0
  for h in $used; do
    [ -n "$(docker_registry_user "$h")" ] && printf '%s\n' "$h"
  done
  return 0
}

docker_auth_locked() {
  local h
  for h in "$@"; do
    if [ "$(docker_registry_state "$h")" = locked ]; then printf '%s\n' "$h"; return 0; fi
  done
  return 1
}

docker_auth_lines() {
  local h u tok f
  for h in "$@"; do
    f=$(docker_registry_token_file "$h"); u=$(docker_registry_user "$h")
    [ -n "$u" ] && [ -r "$f" ] || continue
    IFS= read -r tok <"$f" || [ -n "$tok" ] || continue
    printf '%s\t%s\t%s\n' "$h" "$u" "$tok"
  done
}

# Runs inside the container, sourced by its sh/bash. Reads the lines from stdin. A failed login ends the command (the caller sees status 1).
DOCKER_AUTH_LOGIN='
hs_auth_d=""
trap '"'"'[ -z "$hs_auth_d" ] || rm -rf -- "$hs_auth_d"'"'"' EXIT HUP INT TERM
hs_auth_login() {
  hs_auth_tab=$(printf "\t")
  while IFS=$hs_auth_tab read -r hs_h hs_u hs_t || [ -n "$hs_h" ]; do
    [ -n "$hs_h" ] || continue
    if [ -z "$hs_auth_d" ]; then
      hs_auth_d=$(mktemp -d /run/hs-auth.XXXX) || return 1
      chmod 700 "$hs_auth_d"
      export DOCKER_CONFIG=$hs_auth_d
    fi
    printf "%s" "$hs_t" | docker login -u "$hs_u" --password-stdin "$hs_h" >/dev/null 2>&1 || { echo "The login to $hs_h failed." >&2; return 1; }
  done
}
'

docker_with_auth() {
  local app=$1 hosts h lines dir=${DOCKER_AUTH_DIR:-$(_auth_dir "$1")}
  shift
  hosts=$(DOCKER_AUTH_DIR=$dir docker_auth_hosts "$app")
  # shellcheck disable=SC2086
  if h=$(docker_auth_locked $hosts); then
    warn "$(t 'The vault is closed: the token for %s is in it.' "$h")"
    return 1
  fi
  # shellcheck disable=SC2086
  lines=$(docker_auth_lines $hosts)
  printf '%s\n' "$lines" | timeout 600 "${HS_INCUS:-incus}" exec docker -- sh -c "$DOCKER_AUTH_LOGIN"'
    app=$1; dir=$2; shift 2
    hs_auth_login || exit 1
    cd "$dir" || exit 1
    docker compose -p "$app" "$@" </dev/null
    rc=$?
    exit $rc' sh "$app" "$dir" "$@"
}
