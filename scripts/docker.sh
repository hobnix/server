#!/usr/bin/env bash
# help: Docker as part of hobnix: turn it on (a locked container with Docker inside), turn it off, list the apps that run in it
# help.de: Docker als Teil von hobnix: einschalten (ein gesperrter Container mit Docker darin), ausschalten, die Apps darin auflisten
# args: status | list | enable [--manager webui|arcane|portainer|none] [--size s|m|l] [--yes] [--job] [--dry-run] | disable [--yes --confirm docker] [--no-backup] [--job] [--dry-run] | mount <share|remote:peer> <path> [--as uid:gid] [--yes] [--dry-run] | --status | --list
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
# Test knobs: HS_DOCKER_MANAGE_CT (a script that stands in for manage-ct.sh), HS_DOCKER_BACKUP (stands in for backup.sh), HS_DOCKER_NO_JOB=1
# (no systemd-run: the long work runs at once), HS_REMOTE_ROOT (default /mnt/remote), HS_SETTINGS_DIR, HS_STATE_DIR, HS_CAPABILITIES_FILE, HS_CAPABILITIES_TSV, HS_INCUS.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/ui.sh"
. "$here/lib/instance.sh"
. "$here/lib/capability.sh"
. "$here/lib/job.sh"
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
manager_project() {   # the compose project of the manager (not an app of the person): basename of manager_dir; nothing for webui and none
  local m=${1:-}
  [ -n "$m" ] && [ -f "$here/providers/docker/$m.sh" ] || return 0
  ( . "$here/providers/docker/$m.sh"; basename "$manager_dir" )
}
children() {   # one row per app: name parent project state ports
  local raw skip
  owned && running || return 0
  raw=$(timeout 8 "${HS_INCUS:-incus}" exec "$CT" -- docker ps -a --format '{{.Label "com.docker.compose.project"}}\t{{.State}}\t{{.Ports}}' </dev/null 2>/dev/null) || return 0
  skip=$(manager_project "$(setting_get dockerManager 2>/dev/null || true)")
  printf '%s\n' "$raw" | awk -F'\t' -v skip="$skip" -v ct="$CT" '
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
      for (p in seen) { k = cnt[p]
        for (a = 2; a <= k; a++) { v = pl[p, a]; b = a - 1; while (b >= 1 && pl[p, b] > v) { pl[p, b + 1] = pl[p, b]; b-- } pl[p, b + 1] = v }
        out = ""; for (a = 1; a <= k; a++) out = out (a > 1 ? "," : "") pl[p, a]
        print p "\t" ct "\t" p "\t" st[p] "\t" (out == "" ? "-" : out) }
    }' | sort -t "$tab" -k1,1
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
  local on=off inst=- own=no run=no mgr size mem cpus n addr=-
  if inc info "$CT" >/dev/null 2>&1; then inst=$CT; fi
  if owned; then own=yes; if running; then run=yes; fi; fi
  # on = the capability is listed AND hobnix owns the container; a listed capability without a container is not "on"
  if [ "$own" = yes ] && capability_on docker; then on=on; fi
  mgr=$(setting_get dockerManager 2>/dev/null || true)
  size=$(setting_get dockerSize 2>/dev/null || true); [ -n "$size" ] || size=m
  read -r mem cpus < <(size_of)
  n=$(children | wc -l | tr -d ' ')
  if [ "$run" = yes ]; then addr=$(ct_addr); fi
  printf 'state\t%s\ninstance\t%s\nowned\t%s\nrunning\t%s\nmanager\t%s\nsize\t%s\nmemory\t%s\ncpus\t%s\nchildren\t%s\naddress\t%s\n' \
    "$on" "$inst" "$own" "$run" "$(dash "$mgr")" "$size" "$mem" "$cpus" "$n" "$(dash "$addr")"
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

cmd_mount() {   # mount <share|remote:peer> <path> [--as uid:gid] [--yes] [--dry-run]
  local src=${1:-} path=${2:-} as= yes=0 dry=0 peer= root=${HS_REMOTE_ROOT:-/mnt/remote} dev
  [ $# -ge 2 ] || usage
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --as) [ $# -ge 2 ] || usage; as=$2; shift 2 ;;
      --yes) yes=1; shift ;;
      --dry-run) dry=1; shift ;;
      *) usage ;;
    esac
  done
  owned || fail_fix "$(t 'Docker is not on.')" "hs docker enable"
  [[ "$path" == /* ]] || fail "$(t "The path in the container must start with / (got '%s')." "$path")"
  case "$src" in
    remote:*)
      peer=${src#remote:}; dev=remote-$peer
      [[ "$peer" =~ ^[a-z0-9][a-z0-9-]{0,19}$ ]] || fail "$(t "Invalid peer name '%s'." "$peer")"
      [ -z "$as" ] || fail "$(t 'A remote share is read only and takes no --as.')"
      remote_mounted "$peer" || fail_fix "$(t "Nothing is mounted from '%s'." "$peer")" "hs remote list"
      if inc config device get "$CT" "$dev" source >/dev/null 2>&1; then fail "$(t "'%s' has the device %s already." "$CT" "$dev")"; fi ;;
    *)
      [[ "$src" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "$(t "Invalid share name '%s'." "$src")"
      [[ "$as" =~ ^[0-9]+:[0-9]+$ ]] || fail "$(t 'A local share needs --as <uid>:<gid>.')"
      dev=$src ;;
  esac
  step "$(t 'Give the container docker a folder')"
  if [ -n "$peer" ]; then line "$(t "1. Add the shares of %s (%s/%s) as %s, read only." "$peer" "$root" "$peer" "$path")"
  else line "$(t "1. Mount the share %s as %s, files seen as the user %s." "$src" "$path" "$as")"
    warn "$(t 'The user mapping changes: the container docker restarts, and with it every app in it.')"; fi
  if [ "$dry" = 1 ]; then return 0; fi
  if [ "$yes" = 0 ]; then
    interactive || fail "$(t 'This needs a terminal or --yes.')"
    confirm "$(t 'Do it?')" || { note "$(t 'Nothing changed.')"; return 0; }
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
  *) usage ;;
esac
