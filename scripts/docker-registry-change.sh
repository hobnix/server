#!/usr/bin/env bash
# help: -
# help.de: -
# args: list | add <host> --user <user> | remove <host> [--yes] | --list | plan|start add|remove <host> [--user <user>] [--confirm <host>]
# The logins for private registries (ghcr.io) of the apps in the container docker (docs/PLAN-docker-instances.md, Slice C).
# The list (host<TAB>user, not secret) is /var/lib/hs/docker-registries.tsv; the token is /var/lib/hs/docker-registry-<host> (0600, in the vault
# when there is one; scripts/lib/secret.sh). A pull or build gets the token for ONE command in a throwaway DOCKER_CONFIG (scripts/lib/docker-auth.sh).
# The token is ONE line on stdin (or asked for on a terminal), never an argument or an environment variable.
#   list, --list     the registries: host user state (ok|locked|missing) used_by (apps, comma; `-` when none)
#   add / remove     for people (hs docker registry add|remove); plan / start are the same for the web interface (hs sys docker-registry ...)
# Test knobs: HS_STATE_DIR, HS_VAULT_DIR, HS_INCUS, HS_DOCKER_SH (stands in for docker.sh), HS_DOCKER_SKIP_CHECK=1 (do not ask whether Docker runs).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/ui.sh"
. "$here/lib/setting.sh"
. "$here/lib/docker-auth.sh"

HOST_RE='^[a-z0-9][a-z0-9.-]{0,99}(:[0-9]{1,5})?$'   # starts with a letter or digit: it is an argument of docker login
USER_RE='^[A-Za-z0-9][A-Za-z0-9._@+-]{0,99}$'
TOKEN_RE='^[^[:cntrl:]]{1,256}$'
tab=$'\t'

refuse() { printf 'status\trefused\nreason\t%s\n' "$1"; [ -z "${2:-}" ] || printf 'fix\t%s\n' "$2"; exit 1; }
docker_sh() { bash "${HS_DOCKER_SH:-$here/docker.sh}" "$@"; }

docker_on_and_running() {
  [ -z "${HS_DOCKER_SKIP_CHECK:-}" ] || return 0
  local k v on=off run=no
  while IFS=$'\t' read -r k v; do
    case "$k" in state) on=$v ;; running) run=$v ;; esac
  done < <(docker_sh --status </dev/null 2>/dev/null || true)
  [ "$on" = on ] && [ "$run" = yes ]
}

vault_blocks() { vault_configured && ! vault_is_open; }

used_by() {   # used_by <host>: the apps whose images name the host, comma separated; - when none
  local out
  out=$(docker_sh --apps </dev/null 2>/dev/null | awk -F'\t' -v h="$1" '
    { n = split($8, im, ","); for (i = 1; i <= n; i++) { m = split(im[i], p, "/"); if (m > 1 && p[1] == h) { r = r (r == "" ? "" : ",") $1; break } } }
    END { print r }' || true)
  printf '%s\n' "${out:--}"
}

rows() {   # host user state used_by, sorted by host
  local f h u
  f=$(docker_registries_file)
  [ -s "$f" ] || return 0
  sort "$f" | while IFS=$'\t' read -r h u; do
    [ -n "$h" ] || continue
    printf '%s\t%s\t%s\t%s\n' "$h" "${u:--}" "$(docker_registry_state "$h")" "$(used_by "$h")"
  done
}

read_token() {   # the token: one line on stdin, or asked for on a terminal
  local tok=""
  if [ -t 0 ]; then tok=$(ask_secret "$(t 'Token for the registry:')")
  else IFS= read -r tok || true; fi
  [[ "$tok" =~ $TOKEN_RE ]] || return 1
  printf '%s' "$tok"
}

# A login in a throwaway DOCKER_CONFIG on tmpfs; the token goes on stdin, builtin printf keeps it out of argv.
LOGIN_TEST='
d=$(mktemp -d /run/hs-auth.XXXX) || exit 1
trap "rm -rf -- \"\$d\"" EXIT HUP INT TERM
chmod 700 "$d"; export DOCKER_CONFIG=$d
IFS= read -r tok
printf "%s" "$tok" | docker login -u "$1" --password-stdin -- "$2" >/dev/null 2>&1'

login_test() {   # login_test <host> <user> <token>
  printf '%s\n' "$3" | timeout 60 "${HS_INCUS:-incus}" exec docker -- sh -c "$LOGIN_TEST" sh "$2" "$1"
}

store() {   # store <host> <user> <token>; 0 stored, 1 vault closed or the write failed
  local host=$1 user=$2 tok=$3 f tmp
  f=$(docker_registry_token_file "$host")
  secret_prepare "docker-registry-$host" >&2 || return 1
  ( umask 077; printf '%s\n' "$tok" >"$f" ) || return 1
  chmod 600 "$f" 2>/dev/null || true
  tmp=$(docker_registries_file).new
  { awk -F'	' -v h="$host" '$1 != h' "$(docker_registries_file)" 2>/dev/null || true; printf '%s\t%s\n' "$host" "$user"; } >"$tmp"
  chmod 644 "$tmp"; mv -f "$tmp" "$(docker_registries_file)"
}

forget() {   # forget <host>; 1 (nothing changed) when the vault is closed
  local host=$1 f tgt tmp
  f=$(docker_registry_token_file "$host")
  if vault_blocks && [ -L "$f" ]; then return 1; fi
  if secret_in_vault "$f"; then tgt=$(readlink "$f"); rm -f -- "$tgt" 2>/dev/null || true; fi
  rm -f -- "$f"
  tmp=$(docker_registries_file).new
  { awk -F'	' -v h="$host" '$1 != h' "$(docker_registries_file)" 2>/dev/null || true; } >"$tmp"
  chmod 644 "$tmp"; mv -f "$tmp" "$(docker_registries_file)"
}

known() { [ -n "$(docker_registry_user "$1")" ]; }

# ── plan / start (hs sys docker-registry) ──

parse_opts() {   # sets user, confirm from the arguments
  user=""; confirm=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --user) [ $# -ge 2 ] || refuse "--user needs a name."; user=$2; shift 2 ;;
      --confirm) [ $# -ge 2 ] || refuse "--confirm needs the host."; confirm=$2; shift 2 ;;
      *) refuse "Unexpected argument." ;;
    esac
  done
}

common_checks() {   # common_checks <action> <host>
  # a token in the closed vault cannot be deleted: the link would go and the token stay behind
  if [ "$1" = remove ] && vault_blocks && [[ "$2" =~ $HOST_RE ]]; then refuse "The vault is closed: the token for $2 is in it." "hs vault open"; fi
  [[ "$2" =~ $HOST_RE ]] || refuse "The registry address is not valid."
  docker_on_and_running || refuse "Docker is not on or not running."
  if [ "$1" = add ]; then
    [[ "$user" =~ $USER_RE ]] || refuse "The user name is not valid."
    if vault_blocks; then refuse "The vault is closed: the token cannot be stored." "hs vault open"; fi
  else
    known "$2" || refuse "No registry called '$2' is set up."
  fi
}

cmd_plan() {
  local action=$1 host=$2; shift 2
  parse_opts "$@"
  common_checks "$action" "$host"
  case "$action" in
    add)
      printf 'status\tok\nheading\tadd registry %s\n' "$host"
      printf 'step\tTest the login to %s\n' "$host"
      if known "$host"; then printf 'step\tReplace the stored token of %s\n' "$host"
      elif vault_configured; then printf 'step\tStore the token in the vault\n'
      else printf 'step\tStore the token\n'; fi
      printf 'note\tFor GitHub use a classic token with read:packages only.\n'
      printf 'long\tno\n' ;;
    remove)
      local apps
      apps=$(used_by "$host")
      printf 'status\tok\nheading\tremove registry %s\n' "$host"
      printf 'confirm_name\t%s\n' "$host"
      printf 'step\tForget the user and delete the token of %s\n' "$host"
      [ "$apps" = - ] || printf 'warn\tThese apps use it and cannot pull new images afterwards: %s.\n' "$apps"
      printf 'long\tno\n' ;;
  esac
}

cmd_start() {
  local action=$1 host=$2 tok; shift 2
  parse_opts "$@"
  common_checks "$action" "$host"
  case "$action" in
    add)
      tok=$(read_token) || refuse "The token is missing or not valid."
      login_test "$host" "$user" "$tok" || refuse "The login to $host failed. Check the user and the token."
      store "$host" "$user" "$tok" || refuse "The token could not be stored." ;;
    remove)
      [ "$confirm" = "$host" ] || refuse "The name did not match. Nothing was removed."
      forget "$host" || refuse "The login could not be removed." ;;
  esac
  printf 'status\tdone\n'
}

# ── for people ──

cmd_list() {
  local data
  data=$(rows)
  if [ -z "$data" ]; then note "$(t 'No registry is set up. Add one with: hs docker registry add <host> --user <user>')"; return 0; fi
  { printf 'Registry\tUser\tState\tUsed by\n'; printf '%s\n' "$data"; } | table
}

cmd_add() {
  local host=${1:-} user="" tok
  [ -n "$host" ] || fail "$(t 'usage: hs docker registry add <host> --user <user>')"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in --user) [ $# -ge 2 ] || fail "$(t '--user needs a name.')"; user=$2; shift 2 ;; *) fail "$(t 'Unexpected argument: %s' "$1")" ;; esac
  done
  [[ "$host" =~ $HOST_RE ]] || fail "$(t 'The registry address is not valid.')"
  [[ "$user" =~ $USER_RE ]] || fail "$(t 'Give the user with --user <user>.')"
  docker_on_and_running || fail "$(t 'Docker is not on or not running.')"
  if vault_blocks; then fail_fix "$(t 'The vault is closed: the token cannot be stored.')" "hs vault open"; fi
  note "$(t 'For GitHub use a classic token with read:packages only.')"
  tok=$(read_token) || fail "$(t 'The token is missing or not valid.')"
  step "$(t 'Test the login to %s' "$host")"
  login_test "$host" "$user" "$tok" || fail "$(t 'The login to %s failed. Check the user and the token.' "$host")"
  store "$host" "$user" "$tok" || fail "$(t 'The token could not be stored.')"
  ok "$(t 'Registry %s is set up for %s' "$host" "$user")"
}

cmd_remove() {
  local host=${1:-} yes=0 apps
  [ -n "$host" ] || fail "$(t 'usage: hs docker registry remove <host>')"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in --yes) yes=1; shift ;; *) fail "$(t 'Unexpected argument: %s' "$1")" ;; esac
  done
  [[ "$host" =~ $HOST_RE ]] || fail "$(t 'The registry address is not valid.')"
  known "$host" || fail "$(t 'No registry called %s is set up.' "$host")"
  if vault_blocks; then fail_fix "$(t 'The vault is closed: the token for %s is in it.' "$host")" "hs vault open"; fi
  apps=$(used_by "$host")
  [ "$apps" = - ] || warn "$(t 'These apps use it and cannot pull new images afterwards: %s' "$apps")"
  if [ "$yes" -ne 1 ]; then
    if [ -t 0 ] && [ -t 1 ]; then
      confirm_name "$host" "$(t 'the registry')" || fail "$(t 'The name did not match. Nothing was removed.')"
    else
      fail "$(t 'Removing needs --yes without a terminal.')"
    fi
  fi
  forget "$host"
  ok "$(t 'Removed registry %s' "$host")"
}

case "${1:-list}" in
  list) cmd_list ;;
  --list) rows ;;
  add) shift; cmd_add "$@" ;;
  remove) shift; cmd_remove "$@" ;;
  plan|start)
    [ $# -ge 3 ] || refuse "Usage: plan|start add|remove <host>"
    verb=$1; action=$2; host=$3; shift 3
    case "$action" in add|remove) ;; *) refuse "Action must be add or remove." ;; esac
    if [ "$verb" = plan ]; then cmd_plan "$action" "$host" "$@"; else cmd_start "$action" "$host" "$@"; fi ;;
  *) fail "$(t 'usage: hs docker registry list | add <host> --user <user> | remove <host>')" ;;
esac
