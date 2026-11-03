#!/usr/bin/env bash
# help: -
# help.de: -
# args: plan|start <app> <action> [--rev new|<rev>] [--delete-data]
# Change the apps (compose projects) that run in the locked docker container.
# Actions: start, stop, restart run directly; pull runs as a background job and recreates the containers.
# app-save creates or updates a web-managed app and recreates it (up -d); app-write only writes the two files (the running app is not touched).
# The plan of app-save/app-write is also the Test of the web editor: it collects every problem as `finding<TAB>error|warn<TAB>where<TAB>text`
# (where = compose:<line> | compose:<dotted.path> | env:<line> | -) and refuses with "The test found N problems." when one is an error.
# app-save/app-write rebuild and delete are only for web-managed apps. recreate = `docker compose up -d` from the folder (the Apply of the app
# list for files changed on disk): no pull, no build, no volume removal; any app that is a child of the Docker container.
# Every check is repeated at start, and a plan refuses before anything changes.
# An image from a private registry (ghcr.io) needs its token from the vault (lib/docker-auth.sh): a closed vault refuses pull, rebuild and
# app-save at the plan (fix: hs vault open); start, stop, restart never need it.
# The files of an app live in the share apps (seen in docker at /shares/apps): stacks/<app> for web-managed apps, recipes/<app> for recipes,
# or the legacy /opt/apps/<app> (lib/docker-apps.sh docker_app_dir). delete keeps the folder unless --delete-data is given (the app stays editable and can be started again).
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
ACTION_RE='^(start|stop|restart|pull|app-save|app-write|rebuild|recreate|delete)$'
WRITE_RE='^(app-save|app-write|rebuild|delete)$'
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
      for d in "/shares/apps/stacks/$1" "/opt/apps/$1" "/shares/apps/recipes/$1"; do
        [ -f "$d/docker-compose.yml" ] && { printf "%s\n" "$d"; exit 0; }
      done
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

ENV_BAD=0
add_finding() {   # add_finding <error|warn> <where> <text>: a tab or newline in the text becomes a space
  local text=${3//$'\t'/ }
  text=${text//$'\n'/ }
  FINDINGS+=("$1"$'\t'"$2"$'\t'"$text")
}

declare -a DOC_SET_NAMES DOC_SET_VALUES DOC_REM_NAMES
declare -A DOC_SET_MAP DOC_REM_MAP
DOC_COMPOSE=""
DOC_ENV_TEXT=""
DOC_COLLECT=0       # 1 (the plan of app-save/app-write): an env line problem becomes a finding instead of a refusal
FINDINGS=()         # "level<TAB>where<TAB>text"
DOC_ENV_SHAPE=0     # 1: the document carries the whole .env text (one "*" record) instead of set/remove records

read_document() {
  DOC_SET_NAMES=(); DOC_SET_VALUES=(); DOC_REM_NAMES=()
  DOC_SET_MAP=(); DOC_REM_MAP=()
  DOC_COMPOSE=""; DOC_ENV_TEXT=""; DOC_ENV_SHAPE=0; ENV_BAD=0
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
          if ! [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            if [ "$DOC_COLLECT" -eq 1 ]; then add_finding error "env:$n" "Line $n of the env file is not NAME=value."; ENV_BAD=1
            else refuse "Line $n of the env file is not NAME=value."; fi
          fi
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

# the temp files are on the same filesystem as the app folders (so mv is atomic), in a folder only root of docker may enter
tmp_root_for() {   # tmp_root_for <app folder>: the .hs-tmp next to the folder's parent, so mv into the folder stays on one filesystem
  case "$1" in "$DOCKER_APPS_ROOT"/*) printf '%s/.hs-tmp\n' "$DOCKER_APPS_ROOT" ;; *) printf '%s/.hs-tmp\n' "$DOCKER_APPS_LEGACY" ;; esac
}

# a NEW app goes under the share apps: refuse when docker does not have it mounted (the files would land on the container disk)
need_apps_mounted() {
  docker_apps_mounted && return 0
  printf 'status\trefused\nreason\tThe share apps is not mounted in Docker.\nfix\ths docker enable\n'
  exit 1
}

app_dir_for() {   # app_dir_for <app> [new]: the folder of the app; a NEW app goes to stacks/
  if [ "${2:-}" = new ]; then docker_new_app_dir "$1" web; else docker_app_dir "$1"; fi
}

mapped_owner() {   # the one user of docker that writes the share apps, uid:gid (docker.sh --status mapped), else 1000:1000
  local k v m=
  while IFS=$'\t' read -r k v; do
    [ "$k" = mapped ] && m=$v
  done < <(bash "${HS_DOCKER_SH:-$here/docker.sh}" --status </dev/null 2>/dev/null || true)
  [[ "$m" =~ ^[0-9]+:[0-9]+$ ]] || m=1000:1000
  printf '%s\n' "$m"
}

make_tmp_dir() {   # make_tmp_dir <app> <app folder>
  local root; root=$(tmp_root_for "$2")
  timeout 8 "${HS_INCUS:-incus}" exec "$CT" -- sh -c '
    mkdir -p "$2"
    chmod 700 "$2"
    mktemp -d "$2"/"$1".XXXX
  ' sh "$1" "$root" </dev/null
}

remove_tmp() {
  local tmp=${1:-}
  [ -n "$tmp" ] || return 0
  timeout 8 "${HS_INCUS:-incus}" exec "$CT" -- sh -c 'rm -rf -- "$1"' sh "$tmp" </dev/null >/dev/null 2>&1 || true
}

# Prepare the temp files inside the container. Prints nothing on success, filtered compose errors on failure.
prepare_in_container() {
  local app=$1 tmp=$2 dir=$3
  compose_to_container | timeout 30 "${HS_INCUS:-incus}" exec "$CT" -- bash -c '
    set -uo pipefail
    app=$1; tmp=$2; dir=$3
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
    old=$dir/.env
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
    docker compose -p "$app" --project-directory "$dir" -f "$tmp/docker-compose.yml" --env-file "$tmp/.env" config -q >"$out" 2>&1 || rc=$?
    filter <"$out" >&2
    rm -f "$out"
    exit $rc
  ' sh "$app" "$tmp" "$dir"   # no </dev/null: stdin is the document from compose_to_container
}

# The names that differ between the old .env of the app and the new one in the temp dir: "added|removed|changed<TAB>NAME". Names only.
env_diff() {
  local app=$1 tmp=$2 dir=$3
  timeout 8 "${HS_INCUS:-incus}" exec "$CT" -- sh -c '
    old=$3/.env; new=$2/.env
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
  ' sh "$app" "$tmp" "$dir" </dev/null 2>/dev/null
}

run_check() {
  local app=$1 tmp=$2 dir=$3 json
  json=$(timeout 30 "${HS_INCUS:-incus}" exec "$CT" -- sh -c '
    docker compose -p "$1" --project-directory "$3" -f "$2/docker-compose.yml" --env-file "$2/.env" config --format json || exit 1
    # the same file before ${VAR} is filled in: a value that comes from the env file is not a literal secret (the check reads it after the 0x1e line)
    printf "\n\036\n"
    docker compose -p "$1" --project-directory "$3" -f "$2/docker-compose.yml" --env-file "$2/.env" config --no-interpolate --format json 2>/dev/null || true
  ' sh "$app" "$tmp" "$dir" </dev/null 2>/dev/null) || return 1
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

# the "where" of a finding for a line of a compose error text: env:<line> (the error names the .env file), compose:<line>, compose:<dotted.path> or -
finding_where() {
  local t=$1 w
  if [[ "$t" == *".env"* ]] && [[ "$t" =~ line\ ([0-9]+) ]]; then printf 'env:%s' "${BASH_REMATCH[1]}"
  elif [[ "$t" =~ line\ ([0-9]+) ]]; then printf 'compose:%s' "${BASH_REMATCH[1]}"
  elif [[ "$t" =~ (services\.[A-Za-z0-9_.-]+) ]]; then
    w=${BASH_REMATCH[1]}
    while [[ "$w" == *[.:-] ]]; do w=${w%?}; done
    printf 'compose:%s' "$w"
  else printf -- '-'
  fi
}

where_of() { if [ "$1" = - ] || [ -z "$1" ]; then printf -- '-'; else printf 'compose:%s' "$1"; fi; }

# every line of the error output of `compose config` becomes a finding (at most 20)
collect_compose_errors() {
  local errf=$1 tmp=$2 l n=0
  while IFS= read -r l || [ -n "$l" ]; do
    l=${l//"$tmp/"/}
    [ -n "${l//[[:space:]]/}" ] || continue
    # the env lines were found already by the line check: do not name them twice
    if [ "$ENV_BAD" -eq 1 ] && [[ "$l" == *".env"* ]]; then continue; fi
    n=$((n + 1)); [ "$n" -le 20 ] || break
    add_finding error "$(finding_where "$l")" "$l"
  done <"$errf"
  [ "$n" -gt 0 ] || [ "$ENV_BAD" -eq 1 ] || add_finding error - "The compose file is not valid."
}

PLAN_WARNS=()      # warn lines of the plan (the dialog shows them)
VAULT_FIX=0

# cname_owner <container name> <app>: the project of ANOTHER container with this name (another container when it has none), nothing when free
cname_owner() {
  bash "${HS_DOCKER_SH:-$here/docker.sh}" --containers </dev/null 2>/dev/null \
    | awk -F'\t' -v n="$1" -v app="$2" '$1 == n && $2 != app { print ($2 == "-" ? "another container" : $2); exit }'
}

# the Test also shows a closed vault (an image of a private registry) as a finding, next to the others
vault_finding() {
  local app=$1 tmp=$2 hosts h
  hosts=$(docker_auth_hosts "$app" "$tmp/docker-compose.yml" "$tmp/.env")
  # shellcheck disable=SC2086
  if h=$(docker_auth_locked $hosts); then
    add_finding error - "$(t 'The vault is closed: the token for %s is in it.' "$h")"
    VAULT_FIX=1
  fi
}

# the policy lines of docker_app_doc.py check (refuse|port|warn|cname|bind, each with a path) and the host's own checks -> findings
collect_policy() {
  local app=$1 policy=$2 dir=$3 k a b c owner src hit
  local -a binds=()
  local -A bpath=()
  while IFS=$'\t' read -r k a b c; do
    case "$k" in
      refuse) add_finding error "$(where_of "$b")" "$a" ;;
      port)
        owner=$(docker_port_owner "$a" "$app" 2>/dev/null || true)
        [ -z "$owner" ] || add_finding error "$(where_of "$b")" "Port $a is used by '$owner' in Docker already." ;;
      warn)
        add_finding warn "$(where_of "$b")" "$a"
        PLAN_WARNS+=("$a") ;;
      cname)
        hit=$(cname_owner "$a" "$app")
        [ -z "$hit" ] || add_finding error "$(where_of "$b")" "The container name $a is used by $hit." ;;
      bind)
        case "$a" in "$dir/"*|"$dir") continue ;; esac   # the folder of the app itself is made for it
        binds+=("$a"); bpath[$a]=$c ;;
    esac
  done <<<"$policy"
  if [ "${#binds[@]}" -gt 0 ]; then   # one exec for all the sources
    while IFS= read -r src; do
      [ -n "$src" ] || continue
      add_finding warn "$(where_of "${bpath[$src]:--}")" "$src does not exist: Docker would make an empty folder on the container disk."
      PLAN_WARNS+=("$src does not exist: Docker would make an empty folder on the container disk.")
    done < <(timeout 8 "${HS_INCUS:-incus}" exec "$CT" -- sh -c 'for p in "$@"; do [ -e "$p" ] || printf "%s\n" "$p"; done' sh "${binds[@]}" </dev/null 2>/dev/null || true)
  fi
}

# cmd_plan_save <app> <rev> [save|write]: the plan, and the Test of the web editor (the same call, no dialog): every problem is a finding line
cmd_plan_save() {
  local app=$1 rev=$2 mode=${3:-save} tmp rc=0 f nerr=0
  local current is_new=0 errf=/tmp/docker-app-save-err-$$ dir
  if [ "$rev" = new ]; then
    is_new=1
    need_apps_mounted
    dir=$(app_dir_for "$app" new)
    # the three places an app can live: stacks/ and recipes/ of the share apps, the legacy /opt/apps
    if timeout 8 "${HS_INCUS:-incus}" exec "$CT" -- sh -c '[ -e "$2/stacks/$1" ] || [ -e "$2/recipes/$1" ] || [ -e "$3/$1" ]' sh "$app" "$DOCKER_APPS_ROOT" "$DOCKER_APPS_LEGACY" </dev/null 2>/dev/null; then
      refuse "The app '$app' exists already."
    fi
    if app_is_child "$app"; then refuse "An app called '$app' already runs in Docker."; fi
    if inc info "$app" >/dev/null 2>&1; then refuse "An instance called '$app' exists already."; fi
  else
    current=$(current_rev "$app") || refuse "The app '$app' cannot be read."
    [ "$current" = "$rev" ] || refuse "The app changed meanwhile. Reload it before saving."
    dir=$(app_dir_for "$app") || refuse "The folder of the app '$app' cannot be found."
  fi
  DOC_COLLECT=1
  read_document
  tmp=$(make_tmp_dir "$app" "$dir")
  if ! prepare_in_container "$app" "$tmp" "$dir" >"$errf" 2>&1; then
    rc=1
  fi
  if [ "$rc" -ne 0 ]; then
    collect_compose_errors "$errf" "$tmp"
  else
    local policy
    if policy=$(run_check "$app" "$tmp" "$dir" 2>/dev/null); then collect_policy "$app" "$policy" "$dir"
    else add_finding error - "The compose file is not valid."; fi
    [ "$mode" = write ] || vault_finding "$app" "$tmp"
  fi
  rm -f "$errf"
  for f in ${FINDINGS[@]+"${FINDINGS[@]}"}; do [ "${f%%$'\t'*}" = error ] && nerr=$((nerr + 1)); done
  if [ "$nerr" -gt 0 ]; then
    remove_tmp "$tmp"
    printf 'status\trefused\nreason\tThe test found %s %s.\n' "$nerr" "$([ "$nerr" -eq 1 ] && printf problem || printf problems)"
    for f in "${FINDINGS[@]}"; do printf 'finding\t%s\n' "$f"; done
    [ "$VAULT_FIX" -eq 0 ] || printf 'fix\ths vault open\n'
    exit 1
  fi
  printf 'status\tok\nheading\tapp-%s %s\n' "$mode" "$app"
  for f in ${FINDINGS[@]+"${FINDINGS[@]}"}; do printf 'finding\t%s\n' "$f"; done
  local name how
  if [ "$DOC_ENV_SHAPE" -eq 1 ]; then
    while IFS=$'\t' read -r how name; do
      case "$how" in
        added) printf 'step\tSet %s\n' "$name" ;;
        removed) printf 'step\tRemove %s\n' "$name" ;;
        changed) printf 'step\tChange %s\n' "$name" ;;
      esac
    done < <(env_diff "$app" "$tmp" "$dir")
  fi
  for name in ${DOC_SET_NAMES[@]+"${DOC_SET_NAMES[@]}"}; do printf 'step\tSet %s\n' "$name"; done
  for name in ${DOC_REM_NAMES[@]+"${DOC_REM_NAMES[@]}"}; do printf 'step\tRemove %s\n' "$name"; done
  if [ "$mode" = write ]; then printf 'step\tSave the files (the app is not restarted)\n'
  elif [ "$is_new" -eq 1 ]; then printf 'step\tCreate the app\n'
  else printf 'step\tRecreate the app\n'; fi
  for f in ${PLAN_WARNS[@]+"${PLAN_WARNS[@]}"}; do printf 'warn\t%s\n' "$f"; done
  printf 'long\tyes\n'
  remove_tmp "$tmp"
}

cmd_start_save() {
  local app=$1 rev=$2 mode=${3:-save} tmp is_new=0 policy up=1 dir
  if [ "$rev" = new ]; then is_new=1; need_apps_mounted; dir=$(app_dir_for "$app" new); else dir=$(app_dir_for "$app") || refuse "The folder of the app '$app' cannot be found."; fi
  if [ "$mode" = write ]; then up=0; fi
  read_document
  tmp=$(make_tmp_dir "$app" "$dir")
  if ! prepare_in_container "$app" "$tmp" "$dir" >/tmp/docker-app-save-err-$$ 2>&1; then
    local err
    err=$(cat /tmp/docker-app-save-err-$$ 2>/dev/null || true)
    remove_tmp "$tmp"
    if [ -n "$err" ]; then refuse "The compose file is not valid. $err"; else refuse "The compose file is not valid."; fi
  fi
  policy=$(run_check "$app" "$tmp" "$dir" 2>/dev/null) || { remove_tmp "$tmp"; refuse "The compose file is not valid."; }
  while IFS=$'\t' read -r k v p; do
    case "$k" in
      port)
        local owner
        owner=$(docker_port_owner "$v" "$app" 2>/dev/null || true)
        [ -z "$owner" ] || { remove_tmp "$tmp"; refuse "Port $v is used by '$owner' in Docker already."; } ;;
      cname)
        owner=$(cname_owner "$v" "$app")
        [ -z "$owner" ] || { remove_tmp "$tmp"; refuse "The container name $v is used by $owner."; } ;;
      refuse)
        remove_tmp "$tmp"
        refuse "$v" ;;
    esac
  done <<<"$policy"
  [ "$up" -eq 0 ] || auth_check_tmp "$app" "$tmp"
  if [ -n "${HS_DOCKER_NO_JOB:-}" ]; then
    apply_save "$app" "$rev" "$tmp" "$is_new" "$up"
    printf 'status\tdone\n'
  else
    local unit
    unit=$(hs_job "docker-app-save-$app" "Save $app" -- bash "$0" --apply-save "$app" "$rev" "$tmp" "$is_new" "$up") || refuse "The background job could not be started."
    printf 'status\tstarted\nunit\t%s\n' "$unit"
  fi
}

apply_save() {
  local app=$1 rev=$2 tmp=$3 is_new=$4 up=${5:-1} current managed rc dir owner
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
  local hosts="" h lines=""
  if [ "$up" -eq 1 ]; then     # app-write never pulls an image: no registry login
    hosts=$(docker_auth_hosts "$app" "$tmp/docker-compose.yml" "$tmp/.env")
    # shellcheck disable=SC2086
    if h=$(docker_auth_locked $hosts); then
      remove_tmp "$tmp"
      fail "$(t 'The vault is closed: the token for %s is in it.' "$h")"
    fi
    # shellcheck disable=SC2086
    lines=$(docker_auth_lines $hosts)
  fi
  if [ "$is_new" -eq 1 ]; then
    docker_apps_mounted || { remove_tmp "$tmp"; fail "$(t 'The share apps is not mounted in Docker.')"; }
    dir=$(app_dir_for "$app" new)
  else dir=$(app_dir_for "$app") || { remove_tmp "$tmp"; fail "The folder of the app '$app' cannot be found."; }; fi
  owner=$(mapped_owner)
  printf '%s\n' "$lines" | timeout 600 "${HS_INCUS:-incus}" exec "$CT" -- bash -c "$DOCKER_AUTH_LOGIN"'
    set -uo pipefail
    app=$1; rev=$2; tmp=$3; is_new=$4; up=$5; dir=$6; owner=$7
    if [ "$up" -eq 1 ]; then hs_auth_login || { echo "The registry login failed." >&2; rm -rf -- "$tmp"; exit 1; }; fi
    if [ "$is_new" -eq 1 ]; then
      mkdir -p "$dir/data"
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
    case "$dir" in   # the files belong to the one user of docker that Samba and the Docker page share (not the legacy folder)
      /shares/apps/*)
        chown "$owner" "$dir/docker-compose.yml"
        [ ! -f "$dir/.env" ] || chown "$owner" "$dir/.env"
        if [ "$is_new" -eq 1 ]; then chown "$owner" "$dir" "$dir/data"; elif [ -d "$dir/data" ]; then chown "$owner" "$dir/data"; fi ;;
    esac
    if [ "$up" -eq 0 ]; then rm -f "$dir"/*.prev; rm -rf -- "$tmp"; exit 0; fi
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
  ' sh "$app" "$rev" "$tmp" "$is_new" "$up" "$dir" "$owner"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    remove_tmp "$tmp"
    fail "$(t 'The save of %s failed.' "$app")"
  fi
  if [ "$up" -eq 0 ]; then ok "$(t 'Saved the files of %s' "$app")"
  elif [ "$is_new" -eq 1 ]; then ok "$(t 'Created %s' "$app")"
  else ok "$(t 'Updated %s' "$app")"; fi
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

# ── recreate ──

cmd_plan_recreate() {
  local app=$1
  base_checks "$app"
  auth_check "$app"
  printf 'status	ok
heading	recreate %s
' "$app"
  printf 'step	Recreate the containers whose settings changed and start the missing ones (docker compose up -d)
'
  printf 'note	No image is pulled or built and no volume is removed.
'
  printf 'long	no
'
}

cmd_start_recreate() {
  local app=$1
  base_checks "$app"
  auth_check "$app"
  if docker_with_auth "$app" up -d; then printf 'status	done
'; else refuse "The recreate of $app failed."; fi
}

# ── delete ──

cmd_plan_delete() {
  local app=$1 data=$2 dir
  write_checks "$app"
  dir=$(app_dir_for "$app") || refuse "The folder of the app '$app' cannot be found."
  printf 'status\tok\nheading\tdelete %s\n' "$app"
  printf 'confirm_name\t%s\n' "$app"
  printf 'step\tStop and remove the containers\n'
  if [ "$data" = 1 ]; then
    printf 'danger\tDelete the app, its containers and %s.\n' "$dir"
    printf 'step\tRemove the app directory and its data\n'
  else
    printf 'note\t%s is kept: the app stays editable and can be started again.\n' "$dir"
  fi
  if [ "$data" = 1 ] && [[ "$dir" == "$DOCKER_APPS_ROOT"/* ]]; then
    printf 'note\tA snapshot of docker and of the share apps is taken first.\n'
  else
    printf 'note\tA snapshot of docker is taken first.\n'
  fi
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
  local app=$1 data=${2:-0} managed dir
  [[ "$app" =~ $APP_RE ]] || fail "The app name is not valid."
  docker_on_and_running || fail "Docker is not on or not running."
  app_is_child "$app" || fail "No app called '$app' was found."
  is_manager "$app" && fail "The app '$app' is the Docker manager."
  managed=$(current_managed "$app") || fail "The app '$app' cannot be read."
  [ "$managed" = web ] || fail "Only web-managed apps can be deleted."
  dir=$(app_dir_for "$app") || fail "$(t 'The folder of the app %s cannot be found.' "$app")"
  step "$(t 'Snapshot docker before deleting %s' "$app")"
  if ! bash "${HS_CT_CHANGE:-$here/ct-change.sh}" start docker snapshot --label "pre-delete-$app" >/dev/null 2>&1; then
    fail "$(t 'The snapshot of docker failed. Nothing was deleted.')"
  fi
  if [ "$data" = 1 ] && [[ "$dir" == "$DOCKER_APPS_ROOT"/* ]]; then   # the files are in the share apps, which the snapshot of the container does not cover
    step "$(t 'Snapshot the share apps before deleting %s' "$app")"
    if ! bash "${HS_SHARE_SNAP:-$here/share-snap.sh}" apps snapshot "pre-delete-$app" >/dev/null 2>&1; then
      fail "$(t 'The snapshot of the share apps failed. Nothing was deleted.')"
    fi
  fi
  step "$(t 'Stop and remove the containers of %s' "$app")"
  if ! timeout 120 "${HS_INCUS:-incus}" exec "$CT" -- sh -c 'cd "$2" && docker compose -p "$1" down --remove-orphans' sh "$app" "$dir" </dev/null; then
    fail "$(t 'Stopping the containers of %s failed. The app directory was not removed.' "$app")"
  fi
  if [ "$data" != 1 ]; then
    ok "$(t 'Deleted the containers of %s; %s is kept.' "$app" "$dir")"
    return 0
  fi
  step "$(t 'Remove %s' "$dir")"
  case "$dir" in "$DOCKER_APPS_ROOT/stacks/$app"|"$DOCKER_APPS_LEGACY/$app") ;; *) fail "$(t 'Removing %s failed.' "$dir")" ;; esac
  timeout 30 "${HS_INCUS:-incus}" exec "$CT" -- sh -c 'rm -rf -- "$1"' sh "$dir" </dev/null || fail "$(t 'Removing %s failed.' "$dir")"
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
  [ $# -eq 6 ] || exit 1
  apply_save "$2" "$3" "$4" "$5" "$6"
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
[[ "$action" =~ $ACTION_RE ]] || refuse "Action must be start, stop, restart, pull, app-save, app-write, rebuild, recreate or delete."
case "$action" in
  start|stop|restart|pull|recreate) [ $# -eq 0 ] || refuse "Unexpected arguments." ;;
esac
delete_data=0

case "$verb" in
  plan)
    case "$action" in
      start|stop|restart|pull) cmd_plan_old "$app" "$action" ;;
      app-save|app-write)
        [ $# -eq 2 ] && [ "$1" = --rev ] || refuse "$action needs --rev new|<rev>."
        cmd_plan_save "$app" "$2" "${action#app-}" ;;
      rebuild) cmd_plan_rebuild "$app" ;;
      recreate) cmd_plan_recreate "$app" ;;
      delete)
        [ $# -eq 0 ] || { [ $# -eq 1 ] && [ "$1" = --delete-data ] && delete_data=1; } || refuse "delete takes only --delete-data."
        cmd_plan_delete "$app" "$delete_data" ;;
    esac
    ;;
  start)
    case "$action" in
      start|stop|restart|pull) cmd_start_old "$app" "$action" ;;
      app-save|app-write)
        [ $# -eq 2 ] && [ "$1" = --rev ] || refuse "$action needs --rev new|<rev>."
        cmd_start_save "$app" "$2" "${action#app-}" ;;
      rebuild) cmd_start_rebuild "$app" ;;
      recreate) cmd_start_recreate "$app" ;;
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
