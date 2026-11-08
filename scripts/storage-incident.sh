#!/usr/bin/env bash
# help: a degraded pool, a missing pool disk or a failing disk, step by step: what happened, what is affected, the next safe step, the replace flow
# help.de: ein beeinträchtigter Pool, eine fehlende Pool-Platte oder eine sterbende Platte, Schritt für Schritt: was passiert ist, was betroffen ist, der nächste sichere Schritt, der Tausch
# args: [report] | --state [pool] | --alert-line | pause [--yes] [<instance>...] | resume | replace [--pool <pool>] [--member <name>] [--disk <by-id name>] [--dry-run] | plan|start pause|resume
# The guided storage incident workflow (hobnix/server#255, epic #189). It adds no disk logic of its own: it reads what the pool, SMART and
# share commands already say, joins it into one picture and leads to the commands that exist (hs pool <pool> replace asks the typed disk name).
#   (none) / report   a person's view: the incidents, the disk to pull, the affected shares and apps, the steps, the next safe step. Reads only.
#   --state [pool]    the same as tab separated lines for the web interface (hs sys incident state), reads only, never asks, "-" = empty field:
#       ok       -  <text>                                         no incident (the only line)
#       incident <id> <pool> <kind> <severity> <text>               kind pool-degraded|member-down|disk-failing; severity warn|error
#       member   <pool> <name> <state> <group> <disk> <why>         a pool member that is not ONLINE, or whose disk fails; disk = model and serial
#       target   <pool> <member> <dev> <disk>                        the one disk to replace first (dev = sdX, "-" when it is gone)
#       share    <pool> <name> <path> <impact>                      impact: unavailable (files on a missing disk) | at-risk (readable, no redundancy)
#       app      <pool> <name> <state> <via> <writes>               an instance that uses an affected share (via) or lives on the pool; writes yes|no
#       progress <pool> <resilver|rebuild> <percent|-> <text>       a replacement is running (ZFS resilver, SnapRAID job)
#       paused   <yes|no> <instances>                               what `pause` froze (comma separated)
#       free     <disk> <bytes> <text>                              a free disk that could replace the target (large enough)
#       phase    <pool> <detect|ready|running>                      where the replace flow stands
#       step     <n> <done|now|todo|optional> <title>
#       next     <command|-> <text>                                 the next safe step
#   --alert-line      one sentence for the push message of the health check (nothing when there is no incident)
#   pause             freeze the instances that WRITE to an affected share (incus pause), after a plan and a yes; the default is to only suggest it
#   resume            thaw what `pause` froze
#   replace           the guided replace: names the disk to pull, waits for the new one, then hands over to hs disk replace (plan, typed disk name, job)
#   plan|start pause|resume   the same for the web interface (key<TAB>value lines like jobs-change.sh; start needs no confirmation: nothing is lost by a pause)
# Test knobs: HS_MANAGE_POOL, HS_ZPOOL, HS_DISK_HEALTH, HS_MONITOR, HS_SHARE_OVERVIEW, HS_INCUS, HS_JOBS, HS_DISK_DETACH, HS_DISK_REPLACE, HS_BULK_TYPE_FILE,
#   HS_LOCK_ADMIN, HS_INCIDENT_PAUSED, HS_FREE_WAIT (seconds to wait for the new disk, default 600), HS_NOROOT.
set -uo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"

mp=${HS_MANAGE_POOL:-$here/manage-pool.sh}
zpool=${HS_ZPOOL:-zpool}
dh=${HS_DISK_HEALTH:-$here/disk-health.sh}
mon=${HS_MONITOR:-$here/monitor.sh}
sov=${HS_SHARE_OVERVIEW:-$here/share-overview.sh}
incus=${HS_INCUS:-incus}
jobs=${HS_JOBS:-$here/jobs.sh}
detach=${HS_DISK_DETACH:-$here/disk-detach.sh}
replace_sh=${HS_DISK_REPLACE:-$here/disk-replace.sh}
admin_lock=${HS_LOCK_ADMIN:-/run/hs-bulk.admin}
paused_file=${HS_INCIDENT_PAUSED:-${HS_STATE_DIR:-/var/lib/hs}/incident-paused}
bulk_type=$(cat "${HS_BULK_TYPE_FILE:-/etc/hs/bulk-type}" 2>/dev/null || echo zfs)

usage() {
  say "usage: hs storage incident                 what is wrong with the storage and what to do next (reads only)"
  say "       hs storage incident replace [--pool <pool>] [--member <name>] [--disk <by-id name>] [--dry-run]"
  say "       hs storage incident pause [--yes] [<instance>...]   freeze the apps that write to an affected share"
  say "       hs storage incident resume                          thaw them again"
  exit 1
}

# ───────────────────────────── collecting ─────────────────────────────
REC=""
rec() { local IFS=$'\t'; REC+="$*"$'\n'; }
f() { [ -n "$1" ] && printf '%s' "$1" || printf -- '-'; }       # an empty field is written "-"

declare -A mstate=() mgroup=() msize=() mdisk=() mdev=()        # key "<pool>/<member>"
declare -A pool_bad=() pool_health=() inc_member=()
members_of() { bash "$mp" "$1" --members 2>/dev/null || true; }

# model+serial and device of a disk: from the disk table of the overview (name bytes type role temp health hours realloc pending crc model free ...)
mon_rows=""
load_monitor() { mon_rows=$(bash "$mon" --disks 2>/dev/null || true); }
disk_of_member() {   # <pool> <member> -> "dev<TAB>model serial" ("-" when unknown)
  local pool=$1 m=$2 hit=""
  if [ "$pool" = bulk ] && [ "$bulk_type" = snapraid ]; then
    hit=$(awk -F'\t' -v r="bulk $m" '$4 == r { print $1 "\t" $11; exit }' <<<"$mon_rows")
  else
    hit=$(awk -F'\t' -v p="$pool" -v m="$m" '$4 ~ ("^" p) { n = split($11, a, " "); s = a[n]; if (length(s) > 3 && index(m, s)) { print $1 "\t" $11; exit } }' <<<"$mon_rows")
  fi
  [ -n "$hit" ] && printf '%s' "$hit" || printf -- '-\t-'
}

collect_pools() {
  local pool health line name size state group fs enc closed marks p
  marks=$(bash "$detach" marks 2>/dev/null | cut -f1 || true)       # data disks taken out by hand are not an incident
  for pool in bulk fast; do
    health=""
    if [ "$pool" = bulk ] && [ "$bulk_type" = snapraid ]; then health=SNAPRAID
    elif command -v "$zpool" >/dev/null 2>&1; then health=$("$zpool" list -H -o health "$pool" 2>/dev/null || true); fi
    [ -n "$health" ] || continue
    pool_health[$pool]=$health
    while IFS=$'\t' read -r name size state group fs enc closed; do
      [ -n "$name" ] || continue
      mstate["$pool/$name"]=$state; mgroup["$pool/$name"]=${group:--}; msize["$pool/$name"]=${size:-0}
      if [ "$state" != ONLINE ]; then
        grep -qx -- "$name" <<<"$marks" && continue
        inc_member["$pool/$name"]=down
      fi
    done < <(members_of "$pool")
  done
}

collect_smart() {
  local name verdict why model pool m hit key
  while IFS=$'\t' read -r name _ _ model verdict _ why _; do
    [ "$verdict" = BAD ] || continue
    pool=""; m=""
    hit=$(awk -F'\t' -v n="$name" '$1 == n { print $4 }' <<<"$mon_rows")
    case "$hit" in
      bulk\ *) pool=bulk; m=${hit#bulk } ;;
      bulk|fast) pool=$hit ;;
    esac
    if [ -n "$pool" ] && [ -z "$m" ]; then   # ZFS: the member whose name carries the serial
      for key in "${!mstate[@]}"; do
        [ "${key%%/*}" = "$pool" ] || continue
        local s=${model##* }
        [ "${#s}" -gt 3 ] && [[ "${key#*/}" == *"$s"* ]] && m=${key#*/}
      done
    fi
    if [ -n "$pool" ] && [ -n "$m" ] && [ -n "${mstate["$pool/$m"]:-}" ] && [ "${inc_member["$pool/$m"]:-}" != down ]; then
      inc_member["$pool/$m"]="failing:$name:$why"
    elif [ -z "$pool" ]; then continue                   # a disk that is in no pool: the health check tells about it, not an incident of the pool
    fi
  done < <(bash "$dh" --list 2>/dev/null || true)
}

# shares and instances that an incident touches
shares_rows=""; incus_rows=""
load_shares() { shares_rows=$(bash "$sov" 2>/dev/null || true); incus_rows=$("$incus" list -f csv -c ns 2>/dev/null </dev/null || true); }
state_of_app() { awk -F, -v n="$1" '$1 == n { print $2; exit }' <<<"$incus_rows"; }

# $pool_inc[<pool>]: space separated "member:kind"
collect_impact() {
  local pool=$1 members data_down=false parity_down=false key m
  for key in "${!inc_member[@]}"; do
    [ "${key%%/*}" = "$pool" ] || continue
    m=${key#*/}
    if [ "${inc_member[$key]}" = down ]; then
      if [ "$pool" = bulk ] && [ "$bulk_type" = snapraid ]; then
        [ "${mgroup[$key]}" = parity ] && parity_down=true || data_down=true
      fi
    fi
  done
  local name kind path cache size meas bk disks mounted impact want hit d
  while IFS=$'\t' read -r name kind path cache size meas bk disks mounted; do
    [ -n "$name" ] && [ "$kind" != other ] || continue
    impact=""
    if [ "$pool" = fast ]; then [ "$disks" = fast ] && impact=at-risk
    elif [ "$bulk_type" = snapraid ]; then
      [ "$disks" != fast ] || continue
      if $data_down; then
        for key in "${!inc_member[@]}"; do
          [ "${key%%/*}" = bulk ] && [ "${mgroup[$key]}" != parity ] && [ "${inc_member[$key]}" = down ] || continue
          case ",$disks," in *",${key#*/},"*) impact=unavailable ;; esac
        done
        [ -n "$impact" ] || impact=at-risk
      else impact=at-risk; fi
    else [ "$disks" = bulk ] && impact=at-risk; fi
    [ -n "$impact" ] || continue
    rec share "$pool" "$name" "$path" "$impact"
    if [ -n "$mounted" ] && [ "$mounted" != - ]; then
      for hit in ${mounted//,/ }; do
        d=${hit%%(*}; w=no; [[ "$hit" == *"(rw)"* ]] && w=yes
        printf '%s\t%s\t%s\n' "$d" "$name" "$w" >> "$appfile"
      done
    fi
  done <<<"$shares_rows"
  if [ "$pool" = fast ]; then   # every instance has its root disk on the fast pool (Incus pool "default")
    while IFS=, read -r d _; do [ -z "$d" ] || printf '%s\t%s\t%s\n' "$d" pool no >> "$appfile"; done <<<"$incus_rows"
  fi
}

zfs_progress() {   # <pool>: resilver percent and text, from the scan lines of zpool status
  local st scan pct txt
  st=$("$zpool" status "$1" 2>/dev/null || true)
  grep -q 'resilver in progress' <<<"$st" || return 1
  txt=$(grep -E '% done' <<<"$st" | head -n1 | sed 's/^[[:space:]]*//')
  pct=$(sed -nE 's/.*[^0-9.]([0-9]+(\.[0-9]+)?)% done.*/\1/p' <<<"$txt" | head -n1)
  [ -n "$pct" ] || pct=-
  printf '%s\t%s' "$pct" "${txt:-resilver in progress}"
}

collect() {
  local pool key m kind sev text n ids line v
  appfile=$(mktemp "${TMPDIR:-/tmp}/hs-incident.XXXXXX"); : > "$appfile"
  load_monitor; collect_pools; collect_smart
  declare -gA targets=()
  local pools_hit=""
  for pool in bulk fast; do
    [ -n "${pool_health[$pool]:-}" ] || continue
    local down="" failing="" worst=warn
    for key in "${!inc_member[@]}"; do
      [ "${key%%/*}" = "$pool" ] || continue
      m=${key#*/}
      if [ "${inc_member[$key]}" = down ]; then down+="$m "; case "${mstate[$key]}" in FAULTED|UNAVAIL|MISSING|REMOVED) worst=error ;; esac
      else failing+="$m "; fi
    done
    local ph=${pool_health[$pool]}
    case "$ph" in ONLINE|SNAPRAID) ph="" ;; DEGRADED) ;; *) worst=error ;; esac
    [ -n "$down$failing$ph" ] || continue
    pools_hit+="$pool "
    if [ -n "$ph" ] || { [ -n "$down" ] && [ "${pool_health[$pool]}" != SNAPRAID ]; }; then
      rec incident "$pool:degraded" "$pool" pool-degraded "$worst" "pool $pool is ${ph:-degraded}: ${down:-no member named}$( [ -n "$down" ] || true)"
    fi
    for m in $down; do
      key=$pool/$m
      rec incident "$pool:down:$m" "$pool" member-down "$([ "${mstate[$key]}" = UNMOUNTED ] && echo warn || echo error)" "member $m of $pool is ${mstate[$key]}"
    done
    for m in $failing; do
      key=$pool/$m; v=${inc_member[$key]}
      rec incident "$pool:failing:$m" "$pool" disk-failing warn "disk of $m in $pool is rated BAD by SMART (${v#failing:*:})"
    done
    # members, target
    local first=""
    for m in $down $failing; do
      key=$pool/$m
      IFS=$'\t' read -r dev model < <(disk_of_member "$pool" "$m")
      why=-; [ "${inc_member[$key]}" = down ] || why=${inc_member[$key]#failing:*:}
      rec member "$pool" "$m" "$(f "${mstate[$key]}")" "$(f "${mgroup[$key]}")" "$model" "$why"
      [ -n "$first" ] || { first=$m; targets[$pool]="$m"$'\t'"$dev"$'\t'"$model"; }
    done
    [ -n "${targets[$pool]:-}" ] && rec target "$pool" "${targets[$pool]}"
  done
  if [ -z "$pools_hit" ]; then rm -f "$appfile"; rec ok - "no storage incident: every pool and every disk looks fine"; return; fi
  load_shares
  for pool in $pools_hit; do collect_impact "$pool"; done
  # apps, once per name: writes = yes when it mounts an affected share read-write
  declare -A seen=()
  while IFS=$'\t' read -r name via w; do
    [ -n "$name" ] || continue
    pool=bulk; grep -q "^share	fast	$via	" <<<"$REC" && pool=fast; [ "$via" = pool ] && pool=fast
    [ -z "${seen[$name]:-}" ] || { [ "$w" = yes ] && [ "${seen[$name]}" != yes ] && REC=$(awk -F'\t' -v n="$name" 'BEGIN{OFS="\t"} $1=="app" && $3==n { $7="yes" } { print }' <<<"$REC")$'\n'; continue; }
    seen[$name]=$w
    rec app "$pool" "$name" "$(f "$(state_of_app "$name")")" "$via" "$w"
  done < "$appfile"
  rm -f "$appfile"
  # a replacement that is running
  local running=""
  for pool in $pools_hit; do
    local pg
    if [ "$pool" = bulk ] && [ "$bulk_type" = snapraid ]; then
      local jl; jl=$(bash "$jobs" --records --state running 2>/dev/null | awk -F'\t' '$2 ~ /^pool-replace-/ { print; exit }' || true)
      if [ -n "$jl" ] || [ -e "$admin_lock" ]; then
        local pct=- unit=
        if [ -n "$jl" ]; then
          IFS=$'\t' read -r unit _ _ _ _ _ _ _ _ _ _ pd pt _ <<<"$jl"
          [[ "${pd:-}" =~ ^[0-9]+$ && "${pt:-}" =~ ^[1-9][0-9]*$ ]] && pct=$(( pd * 100 / pt ))
        fi
        rec progress "$pool" rebuild "$pct" "the replacement runs as a job ($(f "$unit")): follow it with hs job follow"
        running+="$pool "
      fi
    elif pg=$(zfs_progress "$pool"); then
      IFS=$'\t' read -r pct txt <<<"$pg"; rec progress "$pool" resilver "$pct" "$txt"; running+="$pool "
    fi
  done
  # free disks that would do
  local fl; fl=$(bash "$mp" --list-disks 2>/dev/null || true)
  for pool in $pools_hit; do
    [ -n "${targets[$pool]:-}" ] || continue
    local need; need=${msize["$pool/${targets[$pool]%%$'\t'*}"]:-0}
    local ready=false
    while IFS=$'\t' read -r id size role _; do
      [ -n "$id" ] && [[ "${size:-}" =~ ^[0-9]+$ ]] && [ "$size" -ge "$need" ] || continue
      if [ "$pool" = "${freed:-}" ]; then continue; fi
      rec free "$id" "$size" "$(f "$role")"; ready=true
    done <<<"$fl"
    local ph=detect; $ready && ph=ready; case " $running " in *" $pool "*) ph=running ;; esac
    rec phase "$pool" "$ph"
  done
  # paused instances
  if [ -s "$paused_file" ]; then rec paused yes "$(paste -sd, "$paused_file")"; else rec paused no -; fi
  # steps and the next safe step: of the first affected pool
  local p1=${pools_hit%% *} ph1 kind1
  ph1=$(awk -F'\t' -v p="$p1" '$1 == "phase" && $2 == p { print $3 }' <<<"$REC")
  local anyw; anyw=$(awk -F'\t' '$1 == "app" && $6 == "yes" && $4 == "RUNNING" { n++ } END { print n + 0 }' <<<"$REC")
  local s2=optional; [ "$anyw" -eq 0 ] && s2=done
  [ -s "$paused_file" ] && s2=done
  local s3=now s4=todo s5=todo
  case "$ph1" in ready) s3=done; s4=now ;; running) s3=done; s4=done; s5=now ;; esac
  rec step 1 done "Understand what failed"
  rec step 2 "$s2" "Pause the apps that write to the pool"
  rec step 3 "$s3" "Pull the failed disk and plug in the new one"
  rec step 4 "$s4" "Replace the disk (you type its name)"
  rec step 5 "$s5" "Wait for the rebuild, then check the result"
  local tg=${targets[$p1]:-}
  case "$ph1" in
    running) rec next - "A replacement is running. Wait for it; do not pull or unplug any disk. Follow it: hs storage incident" ;;
    ready)   rec next "hs storage incident replace" "A new disk is plugged in: replace the failed one (you see the plan first and type the disk name)" ;;
    *)
      if [ -n "$tg" ] && [ "${tg#*$'\t'}" != "-" ] && [ "${mstate["$p1/${tg%%$'\t'*}"]:-}" != ONLINE ] || [ -n "$tg" ]; then
        rec next "hs storage incident replace" "Plug in a new disk (not smaller than the old one), then replace the failed one. Do not reboot or pull other disks before that"
      else rec next "hs health" "See hs health for the details"; fi ;;
  esac
}

# ───────────────────────────── the views ─────────────────────────────
render_human() {
  local k id pool kind sev text name state group disk why cmd st title n m dev path impact pct w via l
  if grep -q '^ok	' <<<"$REC"; then ok "$(t 'No storage incident: every pool and every disk looks fine.')"; return; fi
  step "$(t 'What happened')"
  while IFS=$'\t' read -r k id pool kind sev text; do
    [ "$k" = incident ] || continue
    if [ "$sev" = error ]; then warn "$text"; else note "$text"; fi
  done <<<"$REC"
  while IFS=$'\t' read -r k pool name state group disk why; do
    [ "$k" = member ] || continue
    kv "$name ($pool)" "$state; $group; $disk$([ "$why" = - ] || echo "; SMART: $why")"
  done <<<"$REC"
  if grep -q '^progress	' <<<"$REC"; then
    step "$(t 'Replacement running')"
    while IFS=$'\t' read -r k pool kind pct text; do
      [ "$k" = progress ] || continue
      kv "$pool" "$kind $([ "$pct" = - ] || echo "$pct %") $text"
    done <<<"$REC"
  fi
  if grep -q '^target	' <<<"$REC"; then
    step "$(t 'The disk to pull')"
    while IFS=$'\t' read -r k pool m dev disk; do
      [ "$k" = target ] || continue
      if [ "$dev" = - ]; then note "$(t '%s of %s is gone: there is nothing to pull. Plug in its replacement.' "$m" "$pool")"
      else note "$(t 'Pull %s (%s) only after the replacement is planned. Check the serial number on the label, never go by /dev/sdX alone.' "$disk" "$dev")"; fi
    done <<<"$REC"
  fi
  if grep -q '^share	' <<<"$REC"; then
    step "$(t 'Affected shares')"
    while IFS=$'\t' read -r k pool name path impact; do
      [ "$k" = share ] || continue
      if [ "$impact" = unavailable ]; then warn "$(t '%s (%s): files on the missing disk are not reachable' "$name" "$path")"; else note "$(t '%s (%s): readable, but without redundancy right now' "$name" "$path")"; fi
    done <<<"$REC"
  fi
  if grep -q '^app	' <<<"$REC"; then
    step "$(t 'Affected apps')"
    while IFS=$'\t' read -r k pool name state via w; do
      [ "$k" = app ] || continue
      if [ "$via" = pool ]; then l=$(t '%s (%s): lives on this pool' "$name" "$state"); else l=$(t '%s (%s): uses share %s' "$name" "$state" "$via"); fi
      [ "$w" = yes ] && l+=$(t ', writes to it')
      note "$l"
    done <<<"$REC"
    if [ "$(awk -F'\t' '$1 == "paused" { print $2 }' <<<"$REC")" = yes ]; then
      note "$(t 'Paused by you: %s. Lift it with: hs storage incident resume' "$(awk -F'\t' '$1 == "paused" { print $3 }' <<<"$REC")")"
    elif [ "$(awk -F'\t' '$1 == "app" && $6 == "yes" && $4 == "RUNNING"' <<<"$REC" | wc -l)" -gt 0 ]; then
      note "$(t 'Suggestion: pause the apps that write to the pool until the rebuild is done: hs storage incident pause')"
    fi
  fi
  step "$(t 'Steps')"
  while IFS=$'\t' read -r k n st title; do
    [ "$k" = step ] || continue
    case "$title" in
      "Understand what failed") title=$(t 'Understand what failed') ;;
      "Pause the apps that write to the pool") title=$(t 'Pause the apps that write to the pool') ;;
      "Pull the failed disk and plug in the new one") title=$(t 'Pull the failed disk and plug in the new one') ;;
      "Replace the disk (you type its name)") title=$(t 'Replace the disk (you type its name)') ;;
      "Wait for the rebuild, then check the result") title=$(t 'Wait for the rebuild, then check the result') ;;
    esac
    case "$st" in done) ok "$title" ;; now) warn "$title   <- $(t 'now')" ;; optional) note "$title ($(t 'optional'))" ;; *) note "$title" ;; esac
  done <<<"$REC"
  while IFS=$'\t' read -r k cmd text; do
    [ "$k" = next ] || continue
    line "$text"
    [ "$cmd" = - ] || next_step "$cmd"
  done <<<"$REC"
}

case "${1:-}" in
  ""|report) mode=report ;;
  --state) mode=state; want=${2:-} ;;
  --alert-line) mode=alert ;;
  pause|resume|replace) mode=$1; shift ;;
  plan|start) mode=web; verb=$1; shift ;;
  -h|--help) usage ;;
  *) usage ;;
esac

case "$mode" in
  state) collect; if [ -n "${want:-}" ]; then awk -F'\t' -v p="$want" '$1=="ok"||$1=="step"||$1=="next"||$1=="paused"||$1=="free"||$2==p||$3==p||$1=="app"&&$2==p' <<<"$REC" | grep . ; else printf '%s' "$REC"; fi; exit 0 ;;
  report) collect; render_human; exit 0 ;;
  alert)
    collect; grep -q '^ok	' <<<"$REC" && exit 0
    url=""
    . "$here/lib/machine.sh" 2>/dev/null || true
    if [ "$(machine_get webUi 2>/dev/null || echo false)" = true ]; then url=" (web: http://$(hostname):$(machine_get webPort 2>/dev/null || echo 8480)/storage/incident)"; fi
    printf 'Guided steps: hs storage incident%s\n' "$url"; exit 0 ;;
esac

# ───────────────────────────── actions ─────────────────────────────
. "$here/lib/event.sh" 2>/dev/null || event_emit() { :; }

writers() {   # running instances that write to an affected share (or the ones named)
  awk -F'\t' '$1 == "app" && $6 == "yes" && $4 == "RUNNING" { print $3 }' <<<"$REC"
}
pause_list() {   # the instances to freeze: the named ones (must be affected apps) or every writer
  local n
  if [ $# -gt 0 ]; then
    for n in "$@"; do
      awk -F'\t' -v n="$n" '$1 == "app" && $3 == n && $4 == "RUNNING" && $6 == "yes" { f = 1 } END { exit !f }' <<<"$REC" || return 1
      printf '%s\n' "$n"
    done
  else writers; fi
}
do_pause() {
  local n
  for n in "$@"; do
    "$incus" pause "$n" >/dev/null 2>&1 || { warn "$(t 'Could not pause %s.' "$n")"; continue; }
    mkdir -p "$(dirname "$paused_file")" 2>/dev/null; printf '%s\n' "$n" >> "$paused_file"
    event_emit storage.incident-pause "$n" "paused $n because of a storage incident" --level info >/dev/null 2>&1 || true
  done
}
do_resume() {
  local n
  [ -s "$paused_file" ] || return 0
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    "$incus" resume "$n" >/dev/null 2>&1 || warn "$(t 'Could not resume %s.' "$n")"
    event_emit storage.incident-resume "$n" "resumed $n after a storage incident" --level info >/dev/null 2>&1 || true
  done < "$paused_file"
  rm -f "$paused_file"
}

wrefuse() { printf 'status\trefused\nreason\t%s\n' "$1"; exit 1; }

case "$mode" in
  pause)
    yes=false; names=()
    for a in "$@"; do case "$a" in --yes) yes=true ;; -*) usage ;; *) names+=("$a") ;; esac; done
    collect
    grep -q '^ok	' <<<"$REC" && fail "$(t 'There is no storage incident: nothing to pause.')"
    mapfile -t list < <(pause_list "${names[@]}") || true
    [ "${#names[@]}" -eq 0 ] || [ "${#list[@]}" -eq "${#names[@]}" ] || fail "$(t 'Only running apps that write to an affected share can be paused here.')"
    [ "${#list[@]}" -gt 0 ] && [ -n "${list[0]}" ] || { note "$(t 'No running app writes to an affected share: nothing to pause.')"; exit 0; }
    step "$(t 'Plan')"
    for n in "${list[@]}"; do note "$(t 'Freeze %s (incus pause). It keeps its memory and carries on after: hs storage incident resume' "$n")"; done
    note "$(t 'Nothing is deleted or changed on any disk.')"
    $yes || confirm "$(t 'Pause these apps now?')" || { note "$(t 'Nothing was paused.')"; exit 0; }
    do_pause "${list[@]}"; ok "$(t 'Paused: %s' "${list[*]}")"; exit 0 ;;
  resume)
    [ -s "$paused_file" ] || { note "$(t 'Nothing was paused by hs storage incident.')"; exit 0; }
    do_resume; ok "$(t 'The paused apps run again.')"; exit 0 ;;
  web)
    action=${1:-}; shift || true
    case "$action" in pause|resume) ;; *) wrefuse "unknown action (pause or resume)" ;; esac
    export HS_PLAIN=1
    collect
    if [ "$action" = resume ]; then
      [ -s "$paused_file" ] || wrefuse "nothing was paused by the storage incident workflow"
      printf 'status\tok\nheading\tlet the paused apps run again\nstep\t%s\nlong\tno\n' "$(paste -sd, "$paused_file")"
      [ "$verb" = plan ] || { do_resume; printf 'status\tdone\n'; }
      exit 0
    fi
    grep -q '^ok	' <<<"$REC" && wrefuse "there is no storage incident"
    mapfile -t list < <(writers)
    [ "${#list[@]}" -gt 0 ] && [ -n "${list[0]}" ] || wrefuse "no running app writes to an affected share"
    if [ "$verb" = plan ]; then
      printf 'status\tok\nheading\tpause the apps that write to the affected shares\n'
      for n in "${list[@]}"; do printf 'step\tfreeze %s (incus pause)\n' "$n"; done
      printf 'note\tNothing is deleted or changed on any disk. Undo it with Resume.\nlong\tno\n'
    else do_pause "${list[@]}"; printf 'status\tdone\n'; fi
    exit 0 ;;
  replace)
    pool=""; member=""; disk=""; dry=false
    while [ $# -gt 0 ]; do
      case "$1" in
        --pool) pool=${2:-}; shift 2 ;; --member) member=${2:-}; shift 2 ;; --disk) disk=${2:-}; shift 2 ;;
        --dry-run) dry=true; shift ;; *) usage ;;
      esac
    done
    collect
    grep -q '^ok	' <<<"$REC" && fail "$(t 'There is no storage incident: nothing to replace.')"
    [ -n "$pool" ] || pool=$(awk -F'\t' '$1 == "target" { print $2; exit }' <<<"$REC")
    [ -n "$pool" ] || fail "$(t 'No disk to replace was found. Say which: --pool <pool> --member <name>')"
    [ -n "$member" ] || member=$(awk -F'\t' -v p="$pool" '$1 == "target" && $2 == p { print $3; exit }' <<<"$REC")
    [ -n "$member" ] || fail "$(t 'No disk to replace was found in %s. Say which: --member <name>' "$pool")"
    key=$pool/$member
    [ -n "${mstate[$key]:-}" ] || fail "$(t "'%s' is not a member of %s." "$member" "$pool")"
    # never take a healthy disk out of a mirror whose partner is already down: it would hold the only copy
    if [ "${mstate[$key]}" = ONLINE ] && [ "${mgroup[$key]}" != - ] && [ "$pool" != bulk -o "$bulk_type" != snapraid ]; then
      for k in "${!mstate[@]}"; do
        [ "${k%%/*}" = "$pool" ] && [ "$k" != "$key" ] && [ "${mgroup[$k]}" = "${mgroup[$key]}" ] && [ "${mstate[$k]}" != ONLINE ] \
          && fail "$(t '%s is the only good copy of its mirror right now. Replace the failed disk %s first, not this one.' "$member" "${k#*/}")"
      done
    fi
    if grep -q "^progress	$pool	" <<<"$REC"; then fail "$(t 'A replacement is already running in %s. Wait for it to finish.' "$pool")"; fi
    render_human
    step "$(t 'Replace')"
    if [ -z "$disk" ]; then
      need=${msize[$key]:-0}
      waited=0; max=${HS_FREE_WAIT:-600}
      while :; do
        mapfile -t cand < <(bash "$mp" --list-disks 2>/dev/null | awk -F'\t' -v n="$need" '$2 + 0 >= n + 0 { print $1 }')
        [ "${#cand[@]}" -gt 0 ] && [ -n "${cand[0]}" ] && break
        [ -t 0 ] || fail "$(t 'No free disk that is large enough was found. Plug the new disk in, then run this again.')"
        [ "$waited" -lt "$max" ] || fail "$(t 'No new disk showed up. Plug it in, then run this again.')"
        warn "$(t 'Waiting for the new disk (at least as large as the old one). Plug it in now. Ctrl-C stops.')"
        sleep 10; waited=$((waited + 10))
      done
      if [ "${#cand[@]}" -eq 1 ]; then disk=${cand[0]}; note "$(t 'The new disk: %s' "$disk")"
      else disk=$(choose "$(t 'Which disk is the new one? (it will be erased)')" "${cand[@]}") || exit 1; fi
    fi
    event_emit storage.incident-replace "$pool" "replace of $member in $pool started from the incident workflow" --level info >/dev/null 2>&1 || true
    args=(--pool "$pool" --member "$member" --disk "$disk"); $dry && args+=(--dry-run)
    note "$(t 'Next you see the plan and type the name of the disk. The copy runs in the background; this page follows it.')"
    exec bash "$replace_sh" "${args[@]}" ;;
esac
