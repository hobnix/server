#!/usr/bin/env bash
# help: -
# help.de: -
# args: plan|start <app> <action> [--rev new|<rev>] [--delete-data]
# Change the apps (compose projects) that run in the locked docker container.
# Actions: start, stop, restart run directly; pull runs as a background job and recreates the containers.
# app-save creates or updates a web-managed app; rebuild and delete are only for web-managed apps.
# Every check is repeated at start, and a plan refuses before anything changes.
# An image from a private registry (ghcr.io) needs its token from the vault (lib/docker-auth.sh): a closed vault refuses pull, rebuild and
# app-save at the plan (fix: hs vault open); start, stop, restart never need it.
# delete keeps /opt/apps/<app> unless --delete-data is given (the app stays editable and can be started again).
# Test knobs: HS_DOCKER_NO_JOB=1 (run pull/rebuild/save/delete inline), HS_INCUS, HS_DOCKER_SH and HS_CT_CHANGE (stand in for docker.sh and ct-change.sh).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/ui.sh"
. "$here/lib/job.sh"
. "$here/lib/setting.sh"
. "$here/lib/docker-apps.sh"
. "$here/lib/docker-auth.sh"

CT=docker
APP_RE='^[a-z0-9][a-z0-9_-]{0,40}$'
REV_RE='^[0-9a-f]{16}$'
ACTION_RE='^(start|stop|restart|pull|app-save|rebuild|delete)$'
WRITE_RE='^(app-save|rebuild|delete)$'
NAME_RE='^[A-Za-z_][A-Za-z0-9_]*$'

refuse() { printf 'status\trefused\nreason\t%s\n' "$1"; exit 1; }

# auth_check <app> [<compose file> <env file>]: refuse when an image of the app names a registry whose token is in the closed vault
auth_check() {
  local hosts h
  hosts=$(docker_auth_hosts "$@")
  # shellcheck disable=SC2086
  if h=$(docker_auth_locked $hosts); then
    printf 'status\trefused\nreason\tThe vault is closed: the token for %s is in it.\nfix\ths vault open\n' "$h"
    exit 1
  fi
}

docker_on_and_running() {
  local k v on=off run=no
  while IFS=$'\t' read -r k v; do
    case "$k" in state) on=$v ;; running) run=$v ;; esac
  done < <(bash "${HS_DOCKER_SH:-$here/docker.sh}" --status </dev/null 2>/dev/null || true)
  [ "$on" = on ] && [ "$run" = yes ]
}

app_is_child() {
  local app=$1
  bash "${HS_DOCKER_SH:-$here/docker.sh}" --list </dev/null 2>/dev/null | awk -F'\t' -v app="$app" '$1 == app {found=1} END{exit !found}'
}

is_manager() {
  local app=$1 mgr
  mgr=$(docker_manager_project "$(setting_get dockerManager 2>/dev/null || true)")
  [ -n "$mgr" ] && [ "$app" = "$mgr" ]
}

app_state() { bash "${HS_DOCKER_SH:-$here/docker.sh}" --list </dev/null 2>/dev/null | awk -F'\t' -v app="$1" '$1 == app { print $4; exit }'; }

app_read() { bash "${HS_DOCKER_SH:-$here/docker.sh}" --app "$1" 2>/dev/null; }
current_rev() { app_read "$1" | python3 -c 'import sys,json; print(json.load(sys.stdin)["rev"])'; }
current_managed() { app_read "$1" | python3 -c 'import sys,json; print(json.load(sys.stdin)["managed"])'; }

write_checks() {
  local app=$1
  [[ "$app" =~ $APP_RE ]] || refuse "The app name is not valid."
  docker_on_and_running || refuse "Docker is not on or not running."
  app_is_child "$app" || refuse "No app called '$app' was found."
  if is_manager "$app"; then refuse "The app '$app' is the Docker manager and cannot be changed here."; fi
  local managed
  managed=$(current_managed "$app") || refuse "The app '$app' cannot be read."
  [ "$managed" = web ] || refuse "Only web-managed apps can be saved, rebuilt or deleted."
}

base_checks() {
  local app=$1
  [[ "$app" =~ $APP_RE ]] || refuse "The app name is not valid."
  docker_on_and_running || refuse "Docker is not on or not running."
  app_is_child "$app" || refuse "No app called '$app' was found."
  if is_manager "$app"; then refuse "The app '$app' is the Docker manager and cannot be changed here."; fi
}

find_working_dir() {
  local app=$1 raw dir
  raw=$(timeout 10 "${HS_INCUS:-incus}" exec "$CT" -- sh -c '
    ids=$(docker ps -aq -f label=com.docker.compose.project="$1")
    if [ -z "$ids" ]; then   # no container (a delete that kept the data): the app folder is the working directory
      [ -f "/opt/apps/$1/docker-compose.yml" ] && { printf "%s\n" "/opt/apps/$1"; exit 0; }
      exit 1
    fi
    first=""
    for id in $ids; do
      d=$(docker inspect --format "{{.Config.Labels.com.docker.compose.project.working_dir}}" "$id")
      [ -n "$d" ] || exit 1
      if [ -z "$first" ]; then first="$d"; fi
      printf "%s\n" "$d"
    done
  ' sh "$app" </dev/null 2>/dev/null) || return 1
  dir=$(printf '%s\n' "$raw" | sort -u | head -1)
  [ -n "$dir" ] || return 1
  [ "$(printf '%s\n' "$raw" | sort -u | wc -l | tr -d ' ')" -eq 1 ] || return 1
  timeout 5 "${HS_INCUS:-incus}" exec "$CT" -- sh -c '[ -d "$1" ]' sh "$dir" </dev/null 2>/dev/null || return 1
  printf '%s\n' "$dir"
}

apply_pull() {
  local app=$1 dir=$2
  step "$(t 'Pull images for %s' "$app")"
  if DOCKER_AUTH_DIR=$dir docker_with_auth "$app" pull && DOCKER_AUTH_DIR=$dir docker_with_auth "$app" up -d; then
    ok "$(t 'Pulled and restarted %s' "$app")"
  else
    fail "$(t 'Pull failed for %s' "$app")"
  fi
}

# ── document handling for app-save ──
# The document on stdin is: compose (UTF-8, no NUL), NUL, then +NAME=value\0 or -NAME\0 records.
# Values never leave the container; the host only extracts the names for the plan lines.

declare -a DOC_SET_NAMES DOC_SET_VALUES DOC_REM_NAMES
declare -A DOC_SET_MAP DOC_REM_MAP
DOC_COMPOSE=""
DOC_ENV_TEXT=""
DOC_ENV_SHAPE=0     # 1: the document carries the whole .env text (one "*" record) instead of set/remove records

read_document() {
  DOC_SET_NAMES=(); DOC_SET_VALUES=(); DOC_REM_NAMES=()
  DOC_SET_MAP=(); DOC_REM_MAP=()
  DOC_COMPOSE=""; DOC_ENV_TEXT=""; DOC_ENV_SHAPE=0
  local rec name value line n
  # read compose up to the first NUL
  if ! IFS= read -r -d '' DOC_COMPOSE; then
    [ -n "$DOC_COMPOSE" ] || refuse "The document is empty or malformed."
  fi
  while IFS= read -r -d '' rec || [ -n "$rec" ]; do
    case "$rec" in
      \**)
        if [ "$DOC_ENV_SHAPE" -ne 0 ] || [ "${#DOC_SET_NAMES[@]}" -ne 0 ] || [ "${#DOC_REM_NAMES[@]}" -ne 0 ]; then refuse "Malformed record in the document."; fi
        DOC_ENV_SHAPE=1; DOC_ENV_TEXT=${rec#\*}
        n=0
        while IFS= read -r line || [ -n "$line" ]; do
          n=$((n + 1))
          case "$line" in ""|"#"*) continue ;; esac
          [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || refuse "Line $n of the env file is not NAME=value."
        done <<<"$DOC_ENV_TEXT" ;;
      +*)
        [ "$DOC_ENV_SHAPE" -eq 0 ] || refuse "Malformed record in the document."
        name=${rec%%=*}; name=${name#+}; value=${rec#*=}
        [[ "$name" =~ $NAME_RE ]] || refuse "Malformed set record in the document."
        if [ -n "${DOC_SET_MAP[$name]:-}" ]; then refuse "Duplicate set name in the document."; fi
        DOC_SET_MAP[$name]=1; DOC_SET_NAMES+=("$name"); DOC_SET_VALUES+=("$value") ;;
      -*)
        [ "$DOC_ENV_SHAPE" -eq 0 ] || refuse "Malformed record in the document."
        name=${rec#-}
        [[ "$name" =~ $NAME_RE ]] || refuse "Malformed remove record in the document."
        if [ -n "${DOC_REM_MAP[$name]:-}" ]; then refuse "Duplicate remove name in the document."; fi
        DOC_REM_MAP[$name]=1; DOC_REM_NAMES+=("$name") ;;
      *) refuse "Malformed record in the document." ;;
    esac
  done
}

compose_to_container() {
  # reconstruct the exact byte stream the container expects
  local i
  printf '%s\0' "$DOC_COMPOSE"
  if [ "$DOC_ENV_SHAPE" -eq 1 ]; then printf '*%s\0' "$DOC_ENV_TEXT"; return 0; fi
  for i in "${!DOC_SET_NAMES[@]}"; do
    printf '+%s=%s\0' "${DOC_SET_NAMES[$i]}" "${DOC_SET_VALUES[$i]}"
  done
  for name in "${DOC_REM_NAMES[@]}"; do
    printf '-%s\0' "$name"
  done
}

make_tmp_dir() {
  timeout 8 "${HS_INCUS:-incus}" exec "$CT" -- sh -c '
    mkdir -p /opt/apps/.hs-tmp
    chmod 700 /opt/apps/.hs-tmp
    mktemp -d /opt/apps/.hs-tmp/"$1".XXXX
  ' sh "$1" </dev/null
}

remove_tmp() {
  local tmp=${1:-}
  [ -n "$tmp" ] || return 0
  timeout 8 "${HS_INCUS:-incus}" exec "$CT" -- sh -c 'rm -rf -- "$1"' sh "$tmp" </dev/null >/dev/null 2>&1 || true
}

# Prepare the temp files inside the container. Prints nothing on success, filtered compose errors on failure.
prepare_in_container() {
  local app=$1 tmp=$2
  compose_to_container | timeout 30 "${HS_INCUS:-incus}" exec "$CT" -- bash -c '
    set -uo pipefail
    app=$1; tmp=$2
    mkdir -p /opt/apps/.hs-tmp
    chmod 700 /opt/apps/.hs-tmp
    chmod 700 "$tmp"
    declare -A SET REM
    compose="" rec="" name="" value="" line="" envtxt="" have_txt=0
    IFS= read -r -d "" compose || true
    printf "%s" "$compose" > "$tmp/docker-compose.yml"
    chmod 644 "$tmp/docker-compose.yml"
    while IFS= read -r -d "" rec || [ -n "$rec" ]; do
      case "$rec" in
        \**) have_txt=1; envtxt=${rec#\*} ;;
        +*)
          name=${rec%%=*}; value=${rec#*=}; name=${name#+}
          if [[ ! "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then echo "malformed name: $name" >&2; exit 1; fi
          SET[$name]=$value ;;
        -*)
          name=${rec#-}
          if [[ ! "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then echo "malformed name: $name" >&2; exit 1; fi
          REM[$name]=1 ;;
        *) echo "malformed record" >&2; exit 1 ;;
      esac
    done
    old=/opt/apps/$app/.env
    new=$tmp/.env
    : > "$new"
    if [ "$have_txt" -eq 1 ]; then
      printf "%s" "$envtxt" > "$new"
      if [ -s "$new" ] && [ -n "$(tail -c1 "$new")" ]; then printf "\n" >> "$new"; fi
    elif [ -f "$old" ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
          ""|"#"*) printf "%s\n" "$line" >> "$new"; continue ;;
        esac
        name=${line%%=*}
        [ -z "${REM[$name]:-}" ] || continue
        if [ -n "${SET[$name]+x}" ]; then
          printf "%s=%s\n" "$name" "${SET[$name]}" >> "$new"
          unset "SET[$name]"
          continue
        fi
        printf "%s\n" "$line" >> "$new"
      done < "$old"
    fi
    for name in "${!SET[@]}"; do printf "%s=%s\n" "$name" "${SET[$name]}" >> "$new"; done
    chmod 600 "$new"
    values=$(sed -n "s/^[A-Za-z_][A-Za-z0-9_]*=//p" "$new" | awk "length(\$0) >= 4")
    filter() {
      local l
      if [ -z "$values" ]; then cat; return; fi
      local pf=$tmp/.filter
      printf "%s\n" "$values" > "$pf"
      while IFS= read -r l || [ -n "$l" ]; do
        if grep -qF -f "$pf" <<<"$l"; then
          printf "%s\n" "(a line was hidden: it holds a value of the env file)"
        else
          printf "%s\n" "$l"
        fi
      done
    }
    out=$tmp/.out
    rc=0
    docker compose -p "$app" --project-directory "/opt/apps/$app" -f "$tmp/docker-compose.yml" --env-file "$tmp/.env" config -q >"$out" 2>&1 || rc=$?
    filter <"$out" >&2
    rm -f "$out"
    exit $rc
  ' sh "$app" "$tmp" </dev/null
}

# The names that differ between the old .env of the app and the new one in the temp dir: "added|removed|changed<TAB>NAME". Names only.
env_diff() {
  local app=$1 tmp=$2
  timeout 8 "${HS_INCUS:-incus}" exec "$CT" -- sh -c '
    old=/opt/apps/$1/.env; new=$2/.env
    [ -f "$old" ] || old=/dev/null
    awk '"'"'
      { f = (FILENAME == ARGV[1]) ? 1 : 2 }
      /^[A-Za-z_][A-Za-z0-9_]*=/ { n = index($0, "="); k = substr($0, 1, n - 1); val[f, k] = substr($0, n + 1); seen[f, k] = 1; names[k] = 1 }
      END {
        for (k in names) {
          if (seen[2, k] && !seen[1, k]) print "added\t" k
          else if (seen[1, k] && !seen[2, k]) print "removed\t" k
          else if (val[1, k] != val[2, k]) print "changed\t" k
        }
      }
    '"'"' "$old" "$new" | sort
  ' sh "$app" "$tmp" </dev/null 2>/dev/null
}

run_check() {
  local app=$1 tmp=$2 json
  json=$(timeout 30 "${HS_INCUS:-incus}" exec "$CT" -- sh -c '
    docker compose -p "$1" --project-directory "/opt/apps/$1" -f "$2/docker-compose.yml" --env-file "$2/.env" config --format json
  ' sh "$app" "$tmp" </dev/null 2>/dev/null) || return 1
  printf '%s\n' "$json" | python3 "$here/lib/docker_app_doc.py" check
}

# ── app-save plan / start ──

auth_check_tmp() {   # the images of the NEW compose file in the temp dir; the temp dir goes when the vault is closed
  local app=$1 tmp=$2 hosts h
  hosts=$(docker_auth_hosts "$app" "$tmp/docker-compose.yml" "$tmp/.env")
  # shellcheck disable=SC2086
  if h=$(docker_auth_locked $hosts); then
    remove_tmp "$tmp"
    printf 'status\trefused\nreason\tThe vault is closed: the token for %s is in it.\nfix\ths vault open\n' "$h"
    exit 1
  fi
}

cmd_plan_save() {
  local app=$1 rev=$2 tmp rc=0
  local current is_new=0
  if [ "$rev" = new ]; then
    is_new=1
    if timeout 8 "${HS_INCUS:-incus}" exec "$CT" -- sh -c '[ -e "/opt/apps/$1" ]' sh "$app" </dev/null 2>/dev/null; then
      refuse "The app '$app' exists already."
    fi
    if app_is_child "$app"; then refuse "An app called '$app' already runs in Docker."; fi
    if inc info "$app" >/dev/null 2>&1; then refuse "An instance called '$app' exists already."; fi
  else
    current=$(current_rev "$app") || refuse "The app '$app' cannot be read."
    [ "$current" = "$rev" ] || refuse "The app changed meanwhile. Reload it before saving."
  fi
  read_document
  tmp=$(make_tmp_dir "$app")
  if ! prepare_in_container "$app" "$tmp" >/tmp/docker-app-save-err-$$ 2>&1; then
    rc=1
  fi
  local policy=""
  if [ "$rc" -eq 0 ]; then
    policy=$(run_check "$app" "$tmp" 2>/dev/null) || { remove_tmp "$tmp"; refuse "The compose file is not valid."; }
    while IFS=$'\t' read -r k v; do
      case "$k" in
        port)
          local owner
          owner=$(docker_port_owner "$v" "$app" 2>/dev/null || true)
          if [ -n "$owner" ]; then
            remove_tmp "$tmp"
            refuse "Port $v is used by '$owner' in Docker already."
          fi ;;
        refuse)
          remove_tmp "$tmp"
          refuse "$v" ;;
      esac
    done <<<"$policy"
  fi
  if [ "$rc" -ne 0 ]; then
    local err
    err=$(cat /tmp/docker-app-save-err-$$ 2>/dev/null || true)
    remove_tmp "$tmp"
    if [ -n "$err" ]; then refuse "The compose file is not valid. $err"; else refuse "The compose file is not valid."; fi
  fi
  auth_check_tmp "$app" "$tmp"
  printf 'status\tok\nheading\tapp-save %s\n' "$app"
  local name how
  if [ "$DOC_ENV_SHAPE" -eq 1 ]; then
    while IFS=$'\t' read -r how name; do
      case "$how" in
        added) printf 'step\tSet %s\n' "$name" ;;
        removed) printf 'step\tRemove %s\n' "$name" ;;
        changed) printf 'step\tChange %s\n' "$name" ;;
      esac
    done < <(env_diff "$app" "$tmp")
  fi
  for name in "${DOC_SET_NAMES[@]}"; do printf 'step\tSet %s\n' "$name"; done
  for name in "${DOC_REM_NAMES[@]}"; do printf 'step\tRemove %s\n' "$name"; done
  if [ "$is_new" -eq 1 ]; then printf 'step\tCreate the app\n'; else printf 'step\tRecreate the app\n'; fi
  while IFS=$'\t' read -r k v; do
    [ "$k" = warn ] && printf 'warn\t%s\n' "$v"
  done <<<"$policy"
  printf 'long\tyes\n'
  remove_tmp "$tmp"
}

cmd_start_save() {
  local app=$1 rev=$2 tmp is_new=0 policy
  if [ "$rev" = new ]; then is_new=1; fi
  read_document
  tmp=$(make_tmp_dir "$app")
  if ! prepare_in_container "$app" "$tmp" >/tmp/docker-app-save-err-$$ 2>&1; then
    local err
    err=$(cat /tmp/docker-app-save-err-$$ 2>/dev/null || true)
    remove_tmp "$tmp"
    if [ -n "$err" ]; then refuse "The compose file is not valid. $err"; else refuse "The compose file is not valid."; fi
  fi
  policy=$(run_check "$app" "$tmp" 2>/dev/null) || { remove_tmp "$tmp"; refuse "The compose file is not valid."; }
  while IFS=$'\t' read -r k v; do
    case "$k" in
      port)
        local owner
        owner=$(docker_port_owner "$v" "$app" 2>/dev/null || true)
        [ -z "$owner" ] || { remove_tmp "$tmp"; refuse "Port $v is used by '$owner' in Docker already."; } ;;
      refuse)
        remove_tmp "$tmp"
        refuse "$v" ;;
    esac
  done <<<"$policy"
  auth_check_tmp "$app" "$tmp"
  if [ -n "${HS_DOCKER_NO_JOB:-}" ]; then
    apply_save "$app" "$rev" "$tmp" "$is_new"
    printf 'status\tdone\n'
  else
    local unit
    unit=$(hs_job "docker-app-save-$app" "Save $app" -- bash "$0" --apply-save "$app" "$rev" "$tmp" "$is_new") || refuse "The background job could not be started."
    printf 'status\tstarted\nunit\t%s\n' "$unit"
  fi
}

apply_save() {
  local app=$1 rev=$2 tmp=$3 is_new=$4 current managed rc
  [[ "$app" =~ $APP_RE ]] || { remove_tmp "$tmp"; fail "The app name is not valid."; }
  docker_on_and_running || { remove_tmp "$tmp"; fail "Docker is not on or not running."; }
  app_is_child "$app" || [ "$is_new" -eq 1 ] || { remove_tmp "$tmp"; fail "No app called '$app' was found."; }
  is_manager "$app" && { remove_tmp "$tmp"; fail "The app '$app' is the Docker manager."; }
  managed=$(current_managed "$app" 2>/dev/null || echo other)
  [ "$managed" = web ] || [ "$is_new" -eq 1 ] || { remove_tmp "$tmp"; fail "Only web-managed apps can be saved."; }
  if [ "$is_new" -eq 0 ]; then
    current=$(current_rev "$app") || { remove_tmp "$tmp"; fail "The app '$app' cannot be read."; }
    [ "$current" = "$rev" ] || { remove_tmp "$tmp"; fail "The app changed meanwhile. Reload it before saving."; }
  fi
  local hosts h lines
  hosts=$(docker_auth_hosts "$app" "$tmp/docker-compose.yml" "$tmp/.env")
  # shellcheck disable=SC2086
  if h=$(docker_auth_locked $hosts); then
    remove_tmp "$tmp"
    fail "$(t 'The vault is closed: the token for %s is in it.' "$h")"
  fi
  # shellcheck disable=SC2086
  lines=$(docker_auth_lines $hosts)
  printf '%s\n' "$lines" | timeout 600 "${HS_INCUS:-incus}" exec "$CT" -- bash -c "$DOCKER_AUTH_LOGIN"'
    set -uo pipefail
    app=$1; rev=$2; tmp=$3; is_new=$4
    dir=/opt/apps/$app
    hs_auth_login || { echo "The registry login failed." >&2; rm -rf -- "$tmp"; exit 1; }
    if [ "$is_new" -eq 1 ]; then
      mkdir -p "$dir"
    fi
    # make .prev copies when present
    for f in docker-compose.yml .env; do
      if [ -f "$dir/$f" ]; then
        cp -p "$dir/$f" "$dir/$f.prev"
        chmod 600 "$dir/$f.prev"
      fi
    done
    mv -f "$tmp/docker-compose.yml" "$dir/docker-compose.yml"
    chmod 644 "$dir/docker-compose.yml"
    if [ -f "$tmp/.env" ]; then
      mv -f "$tmp/.env" "$dir/.env"
      chmod 600 "$dir/.env"
    fi
    if [ "$is_new" -eq 1 ]; then
      : > "$dir/.hs-webui"
      chmod 644 "$dir/.hs-webui"
    fi
    values=""
    [ -f "$dir/.env" ] && values=$(sed -n "s/^[A-Za-z_][A-Za-z0-9_]*=//p" "$dir/.env" | awk "length(\$0) >= 4")
    filter() {
      local l
      if [ -z "$values" ]; then cat; return; fi
      local pf=$tmp/.filter-run
      printf "%s\n" "$values" > "$pf"
      while IFS= read -r l || [ -n "$l" ]; do
        if grep -qF -f "$pf" <<<"$l"; then
          printf "%s\n" "(a line was hidden: it holds a value of the env file)"
        else
          printf "%s\n" "$l"
        fi
      done
    }
    out=$tmp/.out-run
    rc=0
    env_arg=()
    [ -f "$dir/.env" ] && env_arg=(--env-file "$dir/.env")
    docker compose -p "$app" --project-directory "$dir" -f "$dir/docker-compose.yml" "${env_arg[@]}" up -d --remove-orphans >"$out" 2>&1 || rc=$?
    filter <"$out"
    rm -f "$out"
    if [ "$rc" -ne 0 ]; then
      # restore previous version
      for f in docker-compose.yml .env; do
        if [ -f "$dir/$f.prev" ]; then
          mv -f "$dir/$f.prev" "$dir/$f"
        elif [ "$is_new" -eq 0 ] && [ -f "$dir/$f" ]; then
          # there was no previous file: remove the new one
          rm -f "$dir/$f"
        fi
      done
      if [ "$is_new" -eq 0 ]; then
        env_arg=()
        [ -f "$dir/.env" ] && env_arg=(--env-file "$dir/.env")
        docker compose -p "$app" --project-directory "$dir" -f "$dir/docker-compose.yml" "${env_arg[@]}" up -d --remove-orphans >/dev/null 2>&1 || true
        echo "The new version did not start; the previous one runs again." >&2
      else
        echo "The app did not start; the files are kept for correction." >&2
      fi
      rm -rf -- "$tmp"
      exit 1
    fi
    rm -f "$dir"/*.prev
    rm -rf -- "$tmp"
  ' sh "$app" "$rev" "$tmp" "$is_new"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    remove_tmp "$tmp"
    fail "$(t 'The save of %s failed.' "$app")"
  fi
  [ "$is_new" -eq 1 ] && ok "$(t 'Created %s' "$app")" || ok "$(t 'Updated %s' "$app")"
}

# ── rebuild ──

cmd_plan_rebuild() {
  local app=$1
  write_checks "$app"
  auth_check "$app"
  printf 'status\tok\nheading\trebuild %s\n' "$app"
  printf 'step\tPull the newest images\n'
  printf 'step\tBuild images that have a Dockerfile\n'
  printf 'step\tRecreate and start the containers\n'
  printf 'long\tyes\n'
}

cmd_start_rebuild() {
  local app=$1
  write_checks "$app"
  auth_check "$app"
  if [ -n "${HS_DOCKER_NO_JOB:-}" ]; then
    step "$(t 'Rebuild %s' "$app")"
    if docker_with_auth "$app" up -d --build --pull always; then
      ok "$(t 'Rebuilt %s' "$app")"
      printf 'status\tdone\n'
    else
      fail "$(t 'Rebuild of %s failed.' "$app")"
    fi
  else
    local unit
    unit=$(hs_job "docker-app-rebuild-$app" "Rebuild $app" -- bash "$0" --apply-rebuild "$app") || refuse "The background job could not be started."
    printf 'status\tstarted\nunit\t%s\n' "$unit"
  fi
}

apply_rebuild() {
  local app=$1 managed
  [[ "$app" =~ $APP_RE ]] || fail "The app name is not valid."
  docker_on_and_running || fail "Docker is not on or not running."
  app_is_child "$app" || fail "No app called '$app' was found."
  is_manager "$app" && fail "The app '$app' is the Docker manager."
  managed=$(current_managed "$app") || fail "The app '$app' cannot be read."
  [ "$managed" = web ] || fail "Only web-managed apps can be rebuilt."
  step "$(t 'Rebuild %s' "$app")"
  if docker_with_auth "$app" up -d --build --pull always; then
    ok "$(t 'Rebuilt %s' "$app")"
  else
    fail "$(t 'Rebuild of %s failed.' "$app")"
  fi
}

# ── delete ──

cmd_plan_delete() {
  local app=$1 data=$2
  write_checks "$app"
  printf 'status\tok\nheading\tdelete %s\n' "$app"
  printf 'confirm_name\t%s\n' "$app"
  printf 'step\tStop and remove the containers\n'
  if [ "$data" = 1 ]; then
    printf 'danger\tDelete the app, its containers and /opt/apps/%s.\n' "$app"
    printf 'step\tRemove the app directory and its data\n'
  else
    printf 'note\t/opt/apps/%s is kept: the app stays editable and can be started again.\n' "$app"
  fi
  printf 'note\tA snapshot of docker is taken first.\n'
  printf 'long\tyes\n'
}

cmd_start_delete() {
  local app=$1 confirm=${2:-} data=${3:-0}
  write_checks "$app"
  [ "$confirm" = "$app" ] || refuse "The name did not match. Nothing was deleted."
  if [ -n "${HS_DOCKER_NO_JOB:-}" ]; then
    apply_delete "$app" "$data"
    printf 'status\tdone\n'
  else
    local unit
    unit=$(hs_job "docker-app-delete-$app" "Delete $app" -- bash "$0" --apply-delete "$app" "$data") || refuse "The background job could not be started."
    printf 'status\tstarted\nunit\t%s\n' "$unit"
  fi
}

apply_delete() {
  local app=$1 data=${2:-0} managed
  [[ "$app" =~ $APP_RE ]] || fail "The app name is not valid."
  docker_on_and_running || fail "Docker is not on or not running."
  app_is_child "$app" || fail "No app called '$app' was found."
  is_manager "$app" && fail "The app '$app' is the Docker manager."
  managed=$(current_managed "$app") || fail "The app '$app' cannot be read."
  [ "$managed" = web ] || fail "Only web-managed apps can be deleted."
  step "$(t 'Snapshot docker before deleting %s' "$app")"
  if ! bash "${HS_CT_CHANGE:-$here/ct-change.sh}" start docker snapshot --label "pre-delete-$app" >/dev/null 2>&1; then
    fail "$(t 'The snapshot of docker failed. Nothing was deleted.')"
  fi
  step "$(t 'Stop and remove the containers of %s' "$app")"
  if ! timeout 120 "${HS_INCUS:-incus}" exec "$CT" -- sh -c 'cd "/opt/apps/$1" && docker compose -p "$1" down --remove-orphans' sh "$app" </dev/null; then
    fail "$(t 'Stopping the containers of %s failed. The app directory was not removed.' "$app")"
  fi
  if [ "$data" != 1 ]; then
    ok "$(t 'Deleted the containers of %s; /opt/apps/%s is kept.' "$app" "$app")"
    return 0
  fi
  step "$(t 'Remove /opt/apps/%s' "$app")"
  timeout 30 "${HS_INCUS:-incus}" exec "$CT" -- sh -c 'rm -rf -- "/opt/apps/$1"' sh "$app" </dev/null || fail "$(t 'Removing /opt/apps/%s failed.' "$app")"
  ok "$(t 'Deleted %s' "$app")"
}

# ── old actions ──

cmd_plan_old() {
  local app=$1 action=$2 dir
  base_checks "$app"
  if [ "$action" = pull ]; then
    dir=$(find_working_dir "$app") || refuse "The working directory of $app could not be found."
    DOCKER_AUTH_DIR=$dir auth_check "$app"
  elif [ "$action" != stop ] && [ "$(app_state "$app")" = stopped ]; then
    auth_check "$app"
  fi
  printf 'status\tok\nheading\t%s %s\n' "$action" "$app"
  case "$action" in
    start) printf 'step\tStart the containers of %s\n' "$app" ;;
    stop) printf 'step\tStop the containers of %s\n' "$app" ;;
    restart) printf 'step\tRestart the containers of %s\n' "$app" ;;
    pull)
      printf 'step\tPull new images for %s\n' "$app"
      printf 'step\tRecreate and start the containers\n' ;;
  esac
  if [ "$action" = pull ]; then printf 'long\tyes\n'; else printf 'long\tno\n'; fi
}

cmd_start_old() {
  local app=$1 action=$2 dir unit
  base_checks "$app"
  case "$action" in
    start|stop|restart)
      if [ "$action" != stop ] && [ "$(app_state "$app")" = stopped ]; then
        # no container (the data were kept): bring the app up from its folder
        if docker_with_auth "$app" up -d; then printf 'status\tdone\n'; else refuse "The $action of $app failed."; fi
        return 0
      fi
      if timeout 30 "${HS_INCUS:-incus}" exec "$CT" -- sh -c 'docker compose -p "$1" "$2"' sh "$app" "$action" </dev/null; then
        printf 'status\tdone\n'
      else
        refuse "The $action of $app failed."
      fi
      ;;
    pull)
      dir=$(find_working_dir "$app") || refuse "The working directory of $app could not be found."
      DOCKER_AUTH_DIR=$dir auth_check "$app"
      if [ -n "${HS_DOCKER_NO_JOB:-}" ]; then
        apply_pull "$app" "$dir"
        printf 'status\tdone\n'
      else
        unit=$(hs_job "docker-app-pull-$app" "Pull $app" -- bash "$0" --apply-pull "$app" "$dir")
        printf 'status\tstarted\nunit\t%s\n' "$unit"
      fi
      ;;
  esac
}

# ── main dispatch ──

if [ "${1:-}" = "--apply-pull" ]; then
  [ $# -eq 3 ] || exit 1
  apply_pull "$2" "$3"
  exit 0
fi

if [ "${1:-}" = "--apply-save" ]; then
  [ $# -eq 5 ] || exit 1
  apply_save "$2" "$3" "$4" "$5"
  exit 0
fi

if [ "${1:-}" = "--apply-rebuild" ]; then
  [ $# -eq 2 ] || exit 1
  apply_rebuild "$2"
  exit 0
fi

if [ "${1:-}" = "--apply-delete" ]; then
  [ $# -eq 3 ] || exit 1
  apply_delete "$2" "$3"
  exit 0
fi

[ $# -ge 3 ] || refuse "Usage: plan|start <app> <action> [--rev new|<rev>]"
verb=$1; app=$2; action=$3; shift 3
[[ "$app" =~ $APP_RE ]] || refuse "The app name is not valid."
[[ "$action" =~ $ACTION_RE ]] || refuse "Action must be start, stop, restart, pull, app-save, rebuild or delete."
case "$action" in
  start|stop|restart|pull) [ $# -eq 0 ] || refuse "Unexpected arguments." ;;
esac
delete_data=0

case "$verb" in
  plan)
    case "$action" in
      start|stop|restart|pull) cmd_plan_old "$app" "$action" ;;
      app-save)
        [ $# -eq 2 ] && [ "$1" = --rev ] || refuse "app-save needs --rev new|<rev>."
        cmd_plan_save "$app" "$2" ;;
      rebuild) cmd_plan_rebuild "$app" ;;
      delete)
        [ $# -eq 0 ] || { [ $# -eq 1 ] && [ "$1" = --delete-data ] && delete_data=1; } || refuse "delete takes only --delete-data."
        cmd_plan_delete "$app" "$delete_data" ;;
    esac
    ;;
  start)
    case "$action" in
      start|stop|restart|pull) cmd_start_old "$app" "$action" ;;
      app-save)
        [ $# -eq 2 ] && [ "$1" = --rev ] || refuse "app-save needs --rev new|<rev>."
        cmd_start_save "$app" "$2" ;;
      rebuild) cmd_start_rebuild "$app" ;;
      delete)
        confirm=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --confirm) [ $# -ge 2 ] || refuse "--confirm needs the app name."; confirm=$2; shift 2 ;;
            --delete-data) delete_data=1; shift ;;
            *) refuse "delete takes only --confirm <app> and --delete-data." ;;
          esac
        done
        cmd_start_delete "$app" "$confirm" "$delete_data" ;;
    esac
    ;;
  *) refuse "Usage: plan|start <app> <action> [--rev new|<rev>]" ;;
esac
