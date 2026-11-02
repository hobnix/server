#!/usr/bin/env bash
# help: Docker as part of hobnix: turn it on (a locked container with Docker inside), turn it off, list the apps that run in it
# help.de: Docker als Teil von hobnix: einschalten (ein gesperrter Container mit Docker darin), ausschalten, die Apps darin auflisten
# args: status | list | enable [--manager webui|arcane|portainer|none] [--size s|m|l] [--yes] [--job] [--dry-run] | disable [--yes --confirm docker] [--no-backup] [--job] [--dry-run] | mount <share|remote:peer> <path> [--as uid:gid] [--yes] [--job] [--dry-run] | --status | --list | --apps | --containers | --app <app> | --logs <app> [lines]
# The capability docker (docs/PLAN-docker-instances.md, Decisions 12 to 14): the container `docker` is owned by it (user.hs.managed_by=docker),
# so only this script deletes it (HS_OWNER=docker on the manage-ct.sh call, scripts/lib/instance.sh).
#   hs docker status       key/value lines: on or off, the container, the manager, the size, the number of apps, the address
#   hs docker list         the apps (compose projects) that run in Docker: name, state, ports
#   hs docker enable       plan, then: create the container, install Docker, start the manager (arcane, portainer; webui and none start
#                          nothing: the page of hobnix itself is built later), lock it, add it to the backup, write dockerManager
#   hs docker disable      plan, a backup offer, the typed name docker, then delete the container and unset dockerManager
#   hs sys docker mount    the only route that gives the locked container a folder (the lock refuses create-share, hs remote attach): plan, then
#                          <share> <path> --as <uid:gid> (a local share; the idmap change restarts the container and so every app in it) or
#                          remote:<peer> <path> (/mnt/remote/<peer>, recursive, rslave, as hs remote attach does); needs --yes without a terminal
#   --status, --list       the same as data (hs sys docker status|list): key<TAB>value, and one row per app with exactly 5 fields
#                          name parent project state ports (`-` when empty); a stopped container or a failed read prints no row, exit 0
#   --apps                 the same data with more fields: name parent project state running/total ports address images managed update
#                          (`-` when empty); 10 fields, sorted by app name; state stopped (0/0) for an app whose folder /opt/apps/<app> has a docker-compose.yml but no container
#   --containers           every container of docker as name project state (`-` when empty; the web editor checks container_name against it)
#   --app <app>            JSON document for the web editor: rev, managed (web|recipe|other), env names, envText (the whole .env, base64 in the script output; envTooBig over 64 KiB), compose; for the admin editor, read nocache
#   --logs <app> [lines]   the Compose log of one app (default 200, max 2000); the app must be a child of docker, never the manager
#                          --job runs it as a background job (the web interface: hs sys docker start mount)
# Test knobs: HS_DOCKER_MANAGE_CT (a script that stands in for manage-ct.sh), HS_DOCKER_BACKUP (stands in for backup.sh), HS_DOCKER_NO_JOB=1
# (no systemd-run: the long work runs at once), HS_REMOTE_ROOT (default /mnt/remote), HS_SETTINGS_DIR, HS_STATE_DIR, HS_CAPABILITIES_FILE, HS_CAPABILITIES_TSV, HS_INCUS.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/ui.sh"
. "$here/lib/instance.sh"
. "$here/lib/capability.sh"
. "$here/lib/job.sh"
. "$here/lib/docker-apps.sh"
CT=docker
OWNER=docker
tab=$'\t'

usage() { fail "$(t 'usage: hs docker status | list | enable | disable | mount')" >&2; }
interactive() { [ -t 0 ] && [ -t 1 ] && [ -z "${HS_CALLER:-}" ]; }
inc() { "${HS_INCUS:-incus}" "$@"; }
ct_cmd() {   # ct_cmd <manage-ct args>: a call that changes the container, with the owner's pass
  if [ -n "${HS_DOCKER_MANAGE_CT:-}" ]; then HS_OWNER=$OWNER "$HS_DOCKER_MANAGE_CT" "$@"; else HS_OWNER=$OWNER bash "$here/manage-ct.sh" "$@"; fi
}
backup_cmd() { if [ -n "${HS_DOCKER_BACKUP:-}" ]; then "$HS_DOCKER_BACKUP" "$@"; else bash "$here/backup.sh" "$@"; fi; }

owned() { inc info "$CT" >/dev/null 2>&1 && [ "$(instance_owner "$CT")" = "$OWNER" ]; }
running() { inc list "$CT" -f csv -c s 2>/dev/null </dev/null | grep -qx RUNNING; }
size_of() {   # size_of [size]: "<MiB> <cpus>" from the size, each replaced by dockerMemory / dockerCpus when above 0
  local s=${1:-} m c v
  [ -n "$s" ] || s=$(setting_get dockerSize 2>/dev/null || true)
  case "$s" in s) m=2048 c=2 ;; l) m=8192 c=8 ;; *) m=4096 c=4 ;; esac
  v=$(setting_get dockerMemory 2>/dev/null || true)
  if [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -gt 0 ]; then m=$v; fi
  v=$(setting_get dockerCpus 2>/dev/null || true)
  if [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -gt 0 ]; then c=$v; fi
  printf '%s %s\n' "$m" "$c"
}
manager_project() { docker_manager_project "$@"; }   # see scripts/lib/docker-apps.sh
kept_apps() {   # the apps whose folder /opt/apps/<app> holds a docker-compose.yml (they may have no containers: a delete that kept the data), space separated
  timeout 8 "${HS_INCUS:-incus}" exec "$CT" -- sh -c 'ls -d /opt/apps/*/docker-compose.yml 2>/dev/null || true' </dev/null 2>/dev/null |
    awk -F/ 'NF == 5 && $2 == "opt" && $3 == "apps" && $4 ~ /^[a-z0-9][a-z0-9_-]*$/ { printf "%s ", $4 }' || true
}
children() {   # one row per app: name parent project state ports (state stopped: the folder is there, no container)
  local raw skip kept
  owned && running || return 0
  raw=$(timeout 8 "${HS_INCUS:-incus}" exec "$CT" -- docker ps -a --format '{{.Label "com.docker.compose.project"}}\t{{.State}}\t{{.Ports}}' </dev/null 2>/dev/null) || return 0
  skip=$(manager_project "$(setting_get dockerManager 2>/dev/null || true)")
  kept=$(kept_apps)
  printf '%s\n' "$raw" | awk -F'\t' -v skip="$skip" -v ct="$CT" -v kept="$kept" '
    $1 !~ /^[a-z0-9][a-z0-9_-]*$/ || $1 == skip { next }
    { p = $1
      if (!(p in seen)) { seen[p] = 1; st[p] = $2 }
      if ($2 == "running") st[p] = "running"
      s = $3
      while (match(s, /:[0-9]+->/)) {
        port = substr(s, RSTART + 1, RLENGTH - 3); s = substr(s, RSTART + RLENGTH)
        if (!((p, port) in has)) { has[p, port] = 1; cnt[p]++; pl[p, cnt[p]] = port + 0 }
      }
    }
    END {
      n = split(kept, kl, " ")
      for (a = 1; a <= n; a++) if (kl[a] != skip && !(kl[a] in seen)) { seen[kl[a]] = 1; st[kl[a]] = "stopped" }
      for (p in seen) { k = cnt[p]
        for (a = 2; a <= k; a++) { v = pl[p, a]; b = a - 1; while (b >= 1 && pl[p, b] > v) { pl[p, b + 1] = pl[p, b]; b-- } pl[p, b + 1] = v }
        out = ""; for (a = 1; a <= k; a++) out = out (a > 1 ? "," : "") pl[p, a]
        print p "\t" ct "\t" p "\t" st[p] "\t" (out == "" ? "-" : out) }
    }' | sort -t "$tab" -k1,1
}
apps() {   # one row per app: name parent project state running/total ports address images managed update
  local raw skip addr
  owned && running || return 0
  raw=$(timeout 8 "${HS_INCUS:-incus}" exec "$CT" -- sh -c '
    docker ps -a --format "{{.Label \"com.docker.compose.project\"}}\t{{.State}}\t{{.Ports}}\t{{.Image}}"
    echo "__HS_MARKER_WEBUI__"
    ls -a /opt/apps/*/.hs-webui 2>/dev/null || true
    echo "__HS_MARKER_DIR__"
    ls -d /opt/apps/*/ 2>/dev/null || true
    echo "__HS_MARKER_COMPOSE__"
    ls -d /opt/apps/*/docker-compose.yml 2>/dev/null || true
  ' </dev/null 2>/dev/null) || return 0
  skip=$(manager_project "$(setting_get dockerManager 2>/dev/null || true)")
  addr=$(ct_addr); [ -n "$addr" ] || addr=-
  printf '%s\n' "$raw" | awk -F'\t' -v skip="$skip" -v ct="$CT" -v addr="$addr" '
    BEGIN { phase = "ps" }
    $0 == "__HS_MARKER_WEBUI__" { phase = "webui"; next }
    $0 == "__HS_MARKER_DIR__" { phase = "dir"; next }
    $0 == "__HS_MARKER_COMPOSE__" { phase = "compose"; next }
    phase == "ps" {
      if (NF < 3) next
      p = $1
      if (p !~ /^[a-z0-9][a-z0-9_-]*$/ || p == skip) next
      if (!(p in seen)) { seen[p] = 1; cnt[p] = 0; run[p] = 0; created[p] = 0 }
      cnt[p]++
      st = $2
      if (st == "running") run[p]++
      if (st == "created") created[p] = 1
      s = $3
      while (match(s, /:[0-9]+->/)) {
        port = substr(s, RSTART + 1, RLENGTH - 3); s = substr(s, RSTART + RLENGTH)
        if (!((p, port) in has)) { has[p, port] = 1; pcnt[p]++; pl[p, pcnt[p]] = port + 0 }
      }
      if (NF >= 4 && $4 != "") {
        img = $4
        if (!((p, img) in ihas)) { ihas[p, img] = 1; icnt[p]++; il[p, icnt[p]] = img }
      }
      next
    }
    phase == "webui" {
      n = split($0, parts, "/")
      if (n >= 5 && parts[2] == "opt" && parts[3] == "apps" && parts[5] == ".hs-webui") webui[parts[4]] = 1
      next
    }
    phase == "dir" {
      n = split($0, parts, "/")
      if (n >= 4 && parts[2] == "opt" && parts[3] == "apps" && parts[4] != "") dir[parts[4]] = 1
      next
    }
    phase == "compose" {
      n = split($0, parts, "/")
      if (n == 5 && parts[2] == "opt" && parts[3] == "apps" && parts[5] == "docker-compose.yml") comp[parts[4]] = 1
      next
    }
    END {
      for (p in comp) if (p ~ /^[a-z0-9][a-z0-9_-]*$/ && p != skip && !(p in seen)) { seen[p] = 1; cnt[p] = 0; run[p] = 0; created[p] = 0 }
      for (p in seen) {
        total = cnt[p]; running = run[p]
        if (total == 0) st = "stopped"
        else if (running == total) st = "running"
        else if (running > 0) st = "partial"
        else if (created[p]) st = "created"
        else st = "exited"
        k = pcnt[p]
        for (a = 2; a <= k; a++) { v = pl[p, a]; b = a - 1; while (b >= 1 && pl[p, b] > v) { pl[p, b + 1] = pl[p, b]; b-- } pl[p, b + 1] = v }
        ports = ""; for (a = 1; a <= k; a++) ports = ports (a > 1 ? "," : "") pl[p, a]
        ik = icnt[p]
        for (a = 2; a <= ik; a++) { v = il[p, a]; b = a - 1; while (b >= 1 && il[p, b] > v) { il[p, b + 1] = il[p, b]; b-- } il[p, b + 1] = v }
        images = ""; for (a = 1; a <= ik; a++) images = images (a > 1 ? "," : "") il[p, a]
        managed = "other"
        if (webui[p]) managed = "web"
        else if (dir[p]) managed = "recipe"
        printf "%s\t%s\t%s\t%s\t%d/%d\t%s\t%s\t%s\t%s\t-\n", p, ct, p, st, running, total, (ports == "" ? "-" : ports), addr, (images == "" ? "-" : images), managed
      }
    }' | sort -t "$tab" -k1,1
}

containers() {   # every container of docker: name project state (`-` when empty); nothing when Docker is off or does not answer
  local raw
  owned && running || return 0
  raw=$(timeout 8 "${HS_INCUS:-incus}" exec "$CT" -- docker ps -a --format '{{.Names}}\t{{.Label "com.docker.compose.project"}}\t{{.State}}' </dev/null 2>/dev/null) || return 0
  printf '%s\n' "$raw" | awk -F'\t' 'NF >= 1 && $1 != "" { printf "%s\t%s\t%s\n", $1, ($2 == "" ? "-" : $2), ($3 == "" ? "-" : $3) }' | sort -t "$tab" -k1,1
}

logs() {   # logs <app> [lines]
  local app=${1:-} lines=${2:-200} raw
  [[ "$app" =~ ^[a-z0-9][a-z0-9_-]{0,40}$ ]] || return 1
  [[ "$lines" =~ ^[0-9]+$ ]] && [ "$lines" -ge 1 ] && [ "$lines" -le 2000 ] || return 1
  owned && running || return 1
  raw=$(children) || return 1
  if ! printf '%s\n' "$raw" | awk -F'\t' -v app="$app" '$1 == app {found=1} END{exit !found}'; then return 1; fi
  timeout 10 "${HS_INCUS:-incus}" exec "$CT" -- docker compose -p "$app" logs --no-color --tail "$lines" --timestamps </dev/null
}

app_is_child() {   # app_is_child <app>
  local app=$1
  owned && running || return 1
  bash "$0" --list </dev/null 2>/dev/null | awk -F'\t' -v app="$app" '$1 == app {found=1} END{exit !found}'
}

app() {   # --app <app>: JSON read for the web editor
  local app=${1:-} mgr
  [[ "$app" =~ ^[a-z0-9][a-z0-9_-]{0,40}$ ]] || return 1
  owned && running || return 1
  app_is_child "$app" || return 1
  mgr=$(docker_manager_project "$(setting_get dockerManager 2>/dev/null || true)")
  [ "$app" != "$mgr" ] || return 1
  timeout 8 "${HS_INCUS:-incus}" exec "$CT" -- sh -c '
    set -e
    app=$1; d=/opt/apps/$app
    [ -r "$d/docker-compose.yml" ] || exit 1
    compose=$(cat "$d/docker-compose.yml")
    if [ -r "$d/.env" ]; then env_stat=$(stat -c "%.9Y %s" "$d/.env"); else env_stat=""; fi
    rev=$(printf "%s%s" "$compose" "$env_stat" | sha256sum | cut -c1-16)
    if [ -f "$d/.hs-webui" ]; then managed=web
    elif [ -d "$d" ]; then managed=recipe
    else managed=other
    fi
    printf "rev\t%s\nmanaged\t%s\n" "$rev" "$managed"
    if [ -r "$d/.env" ]; then sed -n "s/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p" "$d/.env" | sort -u | sed "s/^/env\t/"; fi
    if [ -r "$d/.env" ]; then
      if [ "$(stat -c %s "$d/.env")" -gt 65536 ]; then printf "envbig\t1\n"; else printf "envb64\t%s\n" "$(base64 -w0 "$d/.env")"; fi
    fi
    printf "__HS_COMPOSE__\n%s" "$compose"
  ' sh "$app" </dev/null 2>/dev/null | python3 "$here/lib/docker_app_doc.py" parse
}

ct_addr() {   # the eth0 address of the container, one try; nothing when it has none (docker0 and the like are never the answer)
  inc list "$CT" -f csv -c 4 2>/dev/null </dev/null | grep -oE '[0-9]+(\.[0-9]+){3} \(eth0\)' | head -1 | cut -d' ' -f1 || true
}
ct_ip() {   # the address of the container, up to 10 tries; nothing when it has none
  local i ip
  for i in 1 2 3 4 5 6 7 8 9 10; do
    ip=$(ct_addr)
    if [ -n "$ip" ]; then printf '%s\n' "$ip"; return 0; fi
    sleep 1
  done
}
dash() { if [ -n "${1:-}" ]; then printf '%s' "$1"; else printf -- '-'; fi; }

status_rows() {   # key<TAB>value
  local on=off inst=- own=no run=no mgr size mem cpus n addr=- mapped
  if inc info "$CT" >/dev/null 2>&1; then inst=$CT; fi
  if owned; then own=yes; if running; then run=yes; fi; fi
  # on = the capability is listed AND hobnix owns the container; a listed capability without a container is not "on"
  if [ "$own" = yes ] && capability_on docker; then on=on; fi
  mgr=$(setting_get dockerManager 2>/dev/null || true)
  size=$(setting_get dockerSize 2>/dev/null || true); [ -n "$size" ] || size=m
  read -r mem cpus < <(size_of)
  n=$(children | wc -l | tr -d ' ')
  if [ "$run" = yes ]; then addr=$(ct_addr); fi
  mapped=-; if [ "$own" = yes ]; then mapped=$(dash "$(mapped_user)"); fi
  printf 'state\t%s\ninstance\t%s\nowned\t%s\nrunning\t%s\nmanager\t%s\nsize\t%s\nmemory\t%s\ncpus\t%s\nchildren\t%s\naddress\t%s\nmapped\t%s\n' \
    "$on" "$inst" "$own" "$run" "$(dash "$mgr")" "$size" "$mem" "$cpus" "$n" "$(dash "$addr")" "$mapped"
}

yesno() { if [ "$1" = yes ]; then t 'yes'; else t 'no'; fi; }
cmd_status() {
  local k v on=off own=no inst=-
  while IFS=$'\t' read -r k v; do
    case "$k" in
      state) on=$v; kv "$(t 'Docker')" "$(if [ "$v" = on ]; then t 'on'; else t 'off'; fi)" ;;
      instance) inst=$v; kv "$(t 'Container')" "$v" ;;
      owned) own=$v; kv "$(t 'Owned by hobnix')" "$(yesno "$v")" ;;
      running) kv "$(t 'Running')" "$(yesno "$v")" ;;
      manager) kv "$(t 'Manager')" "$v" ;;
      size) kv "$(t 'Size')" "$v" ;;
      memory) kv "$(t 'Memory (MiB)')" "$v" ;;
      cpus) kv "$(t 'CPUs')" "$v" ;;
      children) kv "$(t 'Apps')" "$v" ;;
      address) kv "$(t 'Address')" "$v" ;;
    esac
  done < <(status_rows)
  if [ "$on" != on ]; then
    if [ "$own" = yes ]; then note "$(t 'The container docker exists, but Docker is not listed as on. Turn it on: hs docker enable')"
    elif [ "$inst" != - ]; then note "$(t 'A container named docker exists but hobnix does not own it. Nothing was changed.')"
    else note "$(t 'No container docker is owned by hobnix yet. Create it: hs docker enable')"; fi
  fi
}

cmd_list() {
  local rows
  rows=$(children)
  if [ -z "$rows" ]; then note "$(t 'No apps run in Docker yet.')"; return 0; fi
  { thead 'Name' 'State' 'Ports'; printf '%s\n' "$rows" | cut -f1,4,5; } | table
}

# the long work of enable/disable as a background job (--job, or answered yes); prints the unit. Returns 1 when jobs are switched off.
as_job() {   # as_job <slug> <description> <args of this script...>
  local slug=$1 desc=$2 unit; shift 2
  if [ -n "${HS_DOCKER_NO_JOB:-}" ]; then return 1; fi
  unit=$(hs_job "$slug" "$desc" -- bash "$0" "$@") || fail "$(t 'The background job could not be started.')"
  ok "$(t 'Started in the background: %s' "$unit")"
}

# one step of the run: a title, then the function; a failure names the step and stops
run_step() {
  local title=$1; shift
  step "$title"
  "$@" || fail "$(t 'Step failed: %s. hs docker disable removes what was made.' "$title")"
}
st_create() { ct_cmd --create "$CT" --docker --ram "$MEM" --cpu "$CPUS"; }
st_lock() {   # a container that cannot be locked is removed again: never leave an unlocked docker behind
  inc config set "$CT" "user.hs.managed_by=$OWNER" && return 0
  ct_cmd "$CT" --delete --yes || true
  return 1
}
st_install() { inc exec "$CT" -- sh -c 'apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y -q docker.io docker-compose' </dev/null; }
st_dir() { inc exec "$CT" -- mkdir -p /opt/apps </dev/null; }
st_manager() {
  local ip port url
  . "$here/providers/docker/$MANAGER.sh"
  ip=$(ct_ip); [ -n "$ip" ] || ip=$CT
  port=$manager_default_port; url="http://$ip:$port"
  manager_prepare | inc exec "$CT" -- bash || return 1
  manager_compose "$port" "$url" | inc exec "$CT" -- tee "$manager_dir/docker-compose.yml" >/dev/null || return 1
  inc exec "$CT" -- sh -c "cd $manager_dir && docker compose up -d" </dev/null
}
st_backup() {
  if backup_new_instances_on; then backup_cmd ct "$CT" on
  else note "$(t "'%s' is not put into the backup (backupNewInstances is false). Later: hs backup ct %s on" "$CT" "$CT")"; fi
}

plan_enable() {
  local s=1
  step "$(t 'Turn Docker on')"
  line "$(t '%s. Create the container docker (%s MiB, %s CPUs, nesting).' "$s" "$MEM" "$CPUS")"; s=$((s + 1))
  line "$(t '%s. Install Docker in it.' "$s")"; s=$((s + 1))
  case "$MANAGER" in
    arcane|portainer) line "$(t '%s. Start the manager %s.' "$s" "$MANAGER")"; s=$((s + 1)) ;;
    webui) note "$(t 'The manager webui is the web interface of hobnix. It is built later: for now only the choice is recorded.')" ;;
    none) note "$(t 'No manager: Docker only.')" ;;
  esac
  if backup_new_instances_on; then line "$(t '%s. Lock the container (only hs docker disable deletes it) and add it to the backup.' "$s")"
  else line "$(t '%s. Lock the container (only hs docker disable deletes it). It is not added to the backup (backupNewInstances is false).' "$s")"; fi
}

cmd_enable() {
  local manager=webui size= yes=0 job=0 dry=0 mport
  while [ $# -gt 0 ]; do
    case "$1" in
      --manager) [ $# -ge 2 ] || usage; manager=$2; shift 2 ;;
      --size) [ $# -ge 2 ] || usage; size=$2; shift 2 ;;
      --yes) yes=1; shift ;;
      --job) job=1; shift ;;
      --dry-run) dry=1; shift ;;
      *) usage ;;
    esac
  done
  case "$manager" in webui|arcane|portainer|none) ;; *) fail "$(t "Unknown manager '%s'. Choose webui, arcane, portainer or none." "$manager")" ;; esac
  case "$size" in ""|s|m|l) ;; *) fail "$(t "Unknown size '%s'. Choose s, m or l." "$size")" ;; esac
  if inc info "$CT" >/dev/null 2>&1; then
    if ! owned; then
      fail_fix "$(t "An instance called 'docker' exists and is not managed by hs (the docker recipe?). Taking it over comes later (hs docker adopt).")" "hs ct list"
    fi
    if capability_on docker; then ok "$(t 'Docker is on already.')"; return 0; fi
    fail_fix "$(t 'A docker container from an earlier try exists.')" "hs docker disable"
  fi
  MANAGER=$manager
  read -r MEM CPUS < <(size_of "$size")
  plan_enable
  if [ "$dry" = 1 ]; then return 0; fi
  if [ "$yes" = 0 ]; then
    interactive || fail "$(t 'This needs a terminal or --yes.')"
    confirm "$(t 'Turn Docker on?')" || { note "$(t 'Nothing changed.')"; return 0; }
    if [ "$job" = 0 ] && confirm "$(t 'Run in the background?')"; then job=1; fi
  fi
  if [ "$job" = 1 ]; then
    set -- enable --yes --manager "$manager"
    if [ -n "$size" ]; then set -- "$@" --size "$size"; fi
    if as_job docker-enable "hs docker enable" "$@"; then return 0; fi
  fi
  case "$manager" in arcane|portainer) steps 6 ;; *) steps 5 ;; esac
  run_step "$(t 'Create the container')" st_create
  run_step "$(t 'Lock the container')" st_lock
  run_step "$(t 'Install Docker')" st_install
  run_step "$(t 'Make /opt/apps')" st_dir
  case "$manager" in arcane|portainer) run_step "$(t 'Start the manager %s' "$manager")" st_manager ;; esac
  run_step "$(if backup_new_instances_on; then t 'Add it to the backup'; else t 'Leave it out of the backup'; fi)" st_backup
  setting_set dockerManager "$manager"
  if [ -n "$size" ]; then setting_set dockerSize "$size"; fi
  ok "$(t 'Docker is on.')"
  next_step "$(t 'give it a fixed IP: hs ct docker ip')"
  case "$manager" in
    arcane|portainer)
      mport=$( . "$here/providers/docker/$manager.sh"; printf '%s' "$manager_default_port" )
      next_step "$(t 'the manager: http://%s:%s' "$(ct_ip)" "$mport")" ;;
  esac
  return 0
}

cmd_disable() {
  local yes=0 confirm_arg= nobackup=0 job=0 dry=0 snap n
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes) yes=1; shift ;;
      --confirm) [ $# -ge 2 ] || usage; confirm_arg=$2; shift 2 ;;
      --no-backup) nobackup=1; shift ;;
      --job) job=1; shift ;;
      --dry-run) dry=1; shift ;;
      *) usage ;;
    esac
  done
  if ! owned; then setting_unset dockerManager; ok "$(t 'Docker is off already.')"; return 0; fi
  n=$(children | wc -l | tr -d ' ')
  snap=$(ct_cmd "$CT" --snapshots 2>/dev/null </dev/null | tail -1 | cut -f2 || true)
  step "$(t 'Turn Docker off')"
  kv "$(t 'Container')" "$CT"
  kv "$(t 'Apps')" "$n"
  kv "$(t 'Newest snapshot')" "$(dash "$snap")"
  danger "$(t "The container 'docker', its apps and their data in /opt/apps are deleted. Snapshots are deleted with it; the backup stays.")"
  if [ "$dry" = 1 ]; then return 0; fi
  if [ "$yes" = 0 ]; then interactive || fail "$(t 'This needs a terminal or --yes.')"
  elif [ "$confirm_arg" != "$CT" ]; then fail "$(t 'This needs --confirm docker.')"; fi   # before the backup: a refusal costs nothing
  if [ "$nobackup" = 0 ]; then
    if [ "$yes" = 1 ] || confirm "$(t 'Back it up first (hs backup now)?')"; then
      backup_cmd now || fail "$(t 'The backup failed. Nothing was deleted.')"
    fi
  fi
  if [ "$yes" = 0 ]; then
    confirm_name "$CT" "$(t 'the instance')" || fail "$(t 'The name did not match. Nothing was deleted.')"
  fi
  if [ "$job" = 1 ]; then
    if as_job docker-disable "hs docker disable" disable --yes --confirm "$CT" --no-backup; then return 0; fi
  fi
  step "$(t 'Delete the container')"
  ct_cmd "$CT" --delete --yes || fail "$(t 'Deleting the container failed.')"
  setting_unset dockerManager
  ok "$(t 'Docker is off.')"
}

remote_mounted() {   # remote_mounted <peer>: the peer is set up (hs remote add) and one of its shares is mounted now, as hs remote attach needs
  local p h sh rest mp=${HS_MOUNTPOINT:-mountpoint}
  [ -f "${HS_STATE_DIR:-/var/lib/hs}/remote-mounts" ] || return 1
  while IFS=$'	' read -r p h sh rest; do
    [ "$p" = "$1" ] || continue
    if timeout 10 $mp -q "${HS_REMOTE_ROOT:-/mnt/remote}/$p/$sh" 2>/dev/null; then return 0; fi
  done < <(grep -v '^[[:space:]]*#' "${HS_STATE_DIR:-/var/lib/hs}/remote-mounts" || true)
  return 1
}

mapped_user() {   # the one user the container docker maps onto the share owner, as uid:gid (raw.idmap "uid 1000 <uid>" / "gid 100 <gid>"); nothing when none
  local m u g
  m=$(inc config get "$CT" raw.idmap 2>/dev/null </dev/null || true)
  u=$(sed -n 's/^uid 1000 \([0-9][0-9]*\)$/\1/p' <<<"$m" | head -n 1)
  g=$(sed -n 's/^gid 100 \([0-9][0-9]*\)$/\1/p' <<<"$m" | head -n 1)
  if [ -n "$u" ] && [ -n "$g" ]; then printf '%s:%s\n' "$u" "$g"; fi
}

# mount_checks <share|remote:peer> <path> <as>: prints nothing; returns 1 with MC_REASON (and MC_FIX, a command, maybe empty) set. Sets MC_PEER, MC_DEV.
mount_checks() {
  local src=$1 path=$2 as=$3 have want
  MC_REASON=; MC_FIX=; MC_PEER=; MC_DEV=
  owned || { MC_REASON=$(t 'Docker is not on.'); MC_FIX="hs docker enable"; return 1; }
  [[ "$path" == /* ]] || { MC_REASON=$(t "The path in the container must start with / (got '%s')." "$path"); return 1; }
  case "$src" in
    remote:*)
      MC_PEER=${src#remote:}; MC_DEV=remote-$MC_PEER
      [[ "$MC_PEER" =~ ^[a-z0-9][a-z0-9-]{0,19}$ ]] || { MC_REASON=$(t "Invalid peer name '%s'." "$MC_PEER"); return 1; }
      [ -z "$as" ] || { MC_REASON=$(t 'A remote share is read only and takes no --as.'); return 1; }
      remote_mounted "$MC_PEER" || { MC_REASON=$(t "Nothing is mounted from '%s'." "$MC_PEER"); MC_FIX="hs remote list"; return 1; }
      if inc config device get "$CT" "$MC_DEV" source >/dev/null 2>&1; then MC_REASON=$(t "'%s' has the device %s already." "$CT" "$MC_DEV"); return 1; fi ;;
    *)
      [[ "$src" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { MC_REASON=$(t "Invalid share name '%s'." "$src"); return 1; }
      [[ "$as" =~ ^[0-9]+:[0-9]+$ ]] || { MC_REASON=$(t 'A local share needs --as <uid>:<gid>.'); return 1; }
      MC_DEV=$src
      if inc config device get "$CT" "$src" type >/dev/null 2>&1; then
        MC_REASON=$(t "'%s' has a device %s already: the share is mounted, use it as it is." "$CT" "$src"); return 1
      fi
      have=$(inc config get "$CT" raw.idmap 2>/dev/null </dev/null || true)
      want=$(printf 'uid 1000 %s\ngid 100 %s' "${as%%:*}" "${as##*:}")
      if [ -n "$have" ] && [ "$have" != "$want" ]; then
        MC_REASON=$(t "The container docker maps another user already (%s). Only one user can write to shares: use that one." "$(mapped_user)"); return 1
      fi ;;
  esac
}

cmd_mount() {   # mount <share|remote:peer> <path> [--as uid:gid] [--yes] [--dry-run]
  local src=${1:-} path=${2:-} as= yes=0 dry=0 job=0 root=${HS_REMOTE_ROOT:-/mnt/remote} dev peer
  [ $# -ge 2 ] || usage
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --as) [ $# -ge 2 ] || usage; as=$2; shift 2 ;;
      --yes) yes=1; shift ;;
      --dry-run) dry=1; shift ;;
      --job) job=1; shift ;;
      *) usage ;;
    esac
  done
  if ! mount_checks "$src" "$path" "$as"; then
    if [ -n "$MC_FIX" ]; then fail_fix "$MC_REASON" "$MC_FIX"; fi
    fail "$MC_REASON"
  fi
  peer=$MC_PEER; dev=$MC_DEV
  step "$(t 'Give the container docker a folder')"
  if [ -n "$peer" ]; then line "$(t "1. Add the shares of %s (%s/%s) as %s, read only." "$peer" "$root" "$peer" "$path")"
  else line "$(t "1. Mount the share %s as %s, files seen as the user %s." "$src" "$path" "$as")"
    warn "$(t 'The user mapping changes: the container docker restarts, and with it every app in it.')"; fi
  if [ "$dry" = 1 ]; then return 0; fi
  if [ "$yes" = 0 ]; then
    interactive || fail "$(t 'This needs a terminal or --yes.')"
    confirm "$(t 'Do it?')" || { note "$(t 'Nothing changed.')"; return 0; }
  fi
  if [ "$job" = 1 ]; then   # a local share restarts every app: the web interface runs it in the background
    set -- mount "$src" "$path" --yes
    if [ -n "$as" ]; then set -- "$@" --as "$as"; fi
    if as_job docker-mount "hs docker mount $src" "$@"; then return 0; fi
  fi
  if [ -n "$peer" ]; then
    inc config device add "$CT" "$dev" disk source="$root/$peer" path="$path" recursive=true propagation=rslave >/dev/null       || fail "$(t 'Adding the folder failed.')"
  else
    ct_cmd "$CT" --add-storage shares "$src" "$path" --as "$as" || fail "$(t 'Adding the folder failed.')"
  fi
  ok "$(t 'The container docker has the folder %s.' "$path")"
}

verb=${1:-}; if [ $# -gt 0 ]; then shift; fi
case "$verb" in
  status) cmd_status ;;
  list) cmd_list ;;
  enable) cmd_enable "$@" ;;
  disable) cmd_disable "$@" ;;
  mount) cmd_mount "$@" ;;
  --status) status_rows ;;
  --list) children ;;
  --apps) apps ;;
  --containers) containers ;;
  --app) [ $# -ge 1 ] || usage; app "$1"; shift ;;
  --logs) logs "$@" ;;
  *) usage ;;
esac
