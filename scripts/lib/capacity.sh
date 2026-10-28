# shellcheck shell=bash
# Capacity and trend problems for health-check.sh: pools filling up (forecast from the readings in the state database),
# SSD wear, an upload cache that is not drained, a backup disk that grows towards full.
# Sourced, not run. The maths is scripts/forecast.py (tests/capacity.sh); the readings live in state.db and are
# reached only through scripts/state.sh (usage-record / usage), never directly.
#
#   capacity_record      write one reading per volume (state.sh keeps at most one per hour and key)
#   capacity_problems    print "key TAB text" per problem. The keys carry no numbers (so the set of problems only
#                        changes when a problem starts or ends): forecast:<volume>, ssd:<dev>:wear, ssd:<dev>:wear-high,
#                        space:cache-backlog. A forecast below HS_CAP_URGENT_DAYS (7) days uses the key
#                        forecast:<volume>:urgent INSTEAD of forecast:<volume>: the escalation changes the set of problems,
#                        so it is sent exactly once, and health-check.sh sends it with priority urgent.
# Volumes: zfs:<pool> (ZFS layout), bulk (/bulk on the SnapRAID layout), root (/), backup (the backup disk: bytes from
# used_bytes/size_bytes in backup.state, history key backup-bytes; an old state file with only used_pct gives percent
# and 100 under the history key backup, so the two units never mix in one fit).
# Knobs (tests): HS_CAP_WARN_DAYS (30), HS_CAP_MIN_FILL (60 %), HS_CAP_WEAR (80 %), HS_CAP_WEAR_HIGH (95 %),
# HS_CAP_CACHE_HOURS (48), HS_CAP_CACHE (/mnt/bulk/cache), HS_CAP_DISKS (command: SSD names, one per line),
# HS_CAP_URGENT_DAYS (7), HS_SMARTCTL, HS_CAP_MIN_DAYS (3), HS_CAP_MIN_SAMPLES (6), HS_BACKUP_STATE, HS_STATE_DIR, HS_NOW.

_cap_here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
_cap_py=${HS_PYTHON:-python3}
_cap_state() { bash "$_cap_here/state.sh" "$@"; }
_cap_fc() { "$_cap_py" "$_cap_here/forecast.py" "$@"; }
_cap_now() { echo "${HS_NOW:-$(date +%s)}"; }

# "volume<TAB>used<TAB>size" per volume that exists (bytes; the backup disk in percent and 100)
_cap_volumes() {
  local p alloc size used
  if command -v zpool >/dev/null 2>&1; then
    while read -r p alloc size; do
      if [ -n "$p" ] && [[ "$alloc" =~ ^[0-9]+$ ]]; then printf 'zfs:%s\t%s\t%s\n' "$p" "$alloc" "$size"; fi
    done < <(zpool list -Hp -o name,alloc,size 2>/dev/null || true)
  fi
  if [ "$(cat /etc/hs/bulk-type 2>/dev/null || echo zfs)" = snapraid ] && mountpoint -q /bulk 2>/dev/null; then
    read -r used size < <(df -B1 --output=used,size /bulk 2>/dev/null | tail -n1) || true
    if [[ "${used:-}" =~ ^[0-9]+$ ]]; then printf 'bulk\t%s\t%s\n' "$used" "$size"; fi
  fi
  read -r used size < <(df -B1 --output=used,size / 2>/dev/null | tail -n1) || true
  if [[ "${used:-}" =~ ^[0-9]+$ ]]; then printf 'root\t%s\t%s\n' "$used" "$size"; fi
  used=$(sed -n 's/^used_pct=//p' "${HS_BACKUP_STATE:-/var/lib/hs/backup.state}" 2>/dev/null | head -n1 || true)
  if [[ "${used:-}" =~ ^[0-9]+$ ]]; then printf 'backup\t%s\t100\n' "$used"; fi
  return 0
}

capacity_record() {
  local v used size
  while IFS=$'\t' read -r v used size; do
    [ -n "$v" ] || continue
    _cap_state usage-record "$v" "$used" "$size" >/dev/null 2>&1 || true
  done < <(_cap_volumes)
}

_cap_human_days() { if [ "$1" -ge 90 ]; then echo "$(( $1 / 30 )) months"; else echo "$1 days"; fi; }

capacity_problems() {
  local warn=${HS_CAP_WARN_DAYS:-30} minfill=${HS_CAP_MIN_FILL:-60}
  local v used size days growth pct label hist fix key urgent=${HS_CAP_URGENT_DAYS:-7}
  while IFS=$'\t' read -r v used size; do
    [ -n "$v" ] || continue
    pct=$(( used * 100 / size ))
    [ "$pct" -ge "$minfill" ] || continue
    hist=$(_cap_state usage "$v" 30 2>/dev/null || true)
    days=$(_cap_fc days-to-full --min-days "${HS_CAP_MIN_DAYS:-3}" --min-samples "${HS_CAP_MIN_SAMPLES:-6}" <<<"$hist" || echo -)
    [[ "$days" =~ ^[0-9]+$ ]] || continue
    [ "$days" -le "$warn" ] || continue
    growth=$(_cap_fc growth-pct-per-day --min-days "${HS_CAP_MIN_DAYS:-3}" --min-samples "${HS_CAP_MIN_SAMPLES:-6}" <<<"$hist" || echo -)
    fix="Look at: hs pool"
    key=$v
    [ "$v" != backup-bytes ] || key=backup
    case "$key" in
      zfs:*)  label="ZFS pool ${key#zfs:}" ;;
      bulk)   label="/bulk" ;;
      root)   label="the system disk" ;;
      backup) label="the backup disk"; fix="Free space: hs backup prune" ;;
      *)      label="$v" ;;
    esac
    [ "$days" -ge "$urgent" ] || key="$key:urgent"
    printf 'forecast:%s\t%s will be full in about %s at the growth of the last weeks (%s %% of its size per day, now %s %% full). %s\n' \
      "$key" "$label" "$(_cap_human_days "$days")" "$growth" "$pct" "$fix"
  done < <(_cap_volumes)

  # SSD wear (root only: smartctl reads nothing otherwise)
  if [ "$(id -u)" -eq 0 ] || [ -n "${HS_SMARTCTL:-}" ]; then
    local smart=${HS_SMARTCTL:-smartctl} d w
    local -a ssds=()
    if [ -n "${HS_CAP_DISKS:-}" ]; then
      mapfile -t ssds < <(eval "$HS_CAP_DISKS" 2>/dev/null || true)
    else
      mapfile -t ssds < <(lsblk -dno NAME,ROTA,TYPE 2>/dev/null | awk '$2 == 0 && $3 == "disk" { print $1 }' || true)
    fi
    for d in "${ssds[@]}"; do
      [ -n "$d" ] || continue
      w=$("$smart" -A "/dev/$d" 2>/dev/null | _cap_fc wear || echo -)
      [[ "$w" =~ ^[0-9]+$ ]] || continue
      if [ "$w" -ge "${HS_CAP_WEAR_HIGH:-95}" ]; then
        printf 'ssd:%s:wear-high\tSSD %s has used %s %% of its rated life: replace it soon. Details: hs disk %s health\n' "$d" "$d" "$w" "$d"
      elif [ "$w" -ge "${HS_CAP_WEAR:-80}" ]; then
        printf 'ssd:%s:wear\tSSD %s has used %s %% of its rated life: plan a replacement. Details: hs disk %s health\n' "$d" "$d" "$w" "$d"
      fi
    done
  fi

  # Upload cache that is not drained: the mover runs when the cache is full or after a sync; a file that has waited
  # two days means it did not.
  local cache=${HS_CAP_CACHE:-/mnt/bulk/cache} oldest hours
  if [ -d "$cache" ] && { mountpoint -q "$cache" 2>/dev/null || [ -n "${HS_CAP_CACHE:-}" ]; }; then
    oldest=$(find "$cache" -type f -printf '%T@\n' 2>/dev/null | sort -n | head -n1 | cut -d. -f1 || true)
    if [[ "$oldest" =~ ^[0-9]+$ ]]; then
      hours=$(_cap_fc cache-age-hours "$(_cap_now)" "$oldest")
      if [[ "$hours" =~ ^[0-9]+ ]] && [ "${hours%.*}" -ge "${HS_CAP_CACHE_HOURS:-48}" ]; then
        printf 'space:cache-backlog\tuploads have been waiting in the SSD cache for %s hours: the mover is not draining it. Details: hs cache-mover\n' "${hours%.*}"
      fi
    fi
  fi
  return 0
}
