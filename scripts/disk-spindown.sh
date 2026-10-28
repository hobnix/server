#!/usr/bin/env bash
# help: let the spinning bulk, parity and backup disks go to sleep after machine.toml diskSpindownMinutes (0 = never)
# help.de: lässt die drehenden Bulk-, Parity- und Backup-Platten nach diskSpindownMinutes (machine.toml) schlafen (0 = nie)
# args: apply | status
# apply: set the standby timer (hdparm -S) on every rotational disk that is a bulk/parity/backup member. SSDs, NVMe, the system disk and
# the `fast` pool are never touched. 0/unset = hdparm -S 0 (timer off). status: plain tab separated lines
# (dev, rotational, member, state, minutes); `hdparm -C` reads the power state without waking the disk.
# Test knobs: HS_SPINDOWN_SYSFS (default /sys/block), HS_SPINDOWN_MEMBERS (file with member disk names; replaces the lookup),
# HS_SPINDOWN_MINUTES (replaces machine.toml).
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
. "$here/lib/machine.sh"

usage() { say "usage: hs disk spindown [apply|status]"; exit 1; }
mode=${1:-status}
case "$mode" in apply|status|--value) ;; *) usage ;; esac

minutes=${HS_SPINDOWN_MINUTES:-$(machine_get diskSpindownMinutes 2>/dev/null || echo 0)}
case "$minutes" in ''|*[!0-9]*) minutes=0 ;; esac

# minutes -> hdparm -S value: 1..240 = n * 5 s (up to 20 min), 241..251 = (n - 240) * 30 min. Over 20 minutes the value rounds up to
# whole half hours; the longest is 251 (5.5 h).
spindown_value() {
  local m=$1
  if [ "$m" -le 0 ]; then echo 0
  elif [ "$m" -le 20 ]; then echo $(( (m * 60 + 4) / 5 ))
  else
    local v=$(( 240 + (m + 29) / 30 ))
    [ "$v" -le 251 ] || v=251
    echo "$v"
  fi
}
if [ "${1:-}" = "--value" ]; then spindown_value "${2:-0}"; exit 0; fi

sysfs=${HS_SPINDOWN_SYSFS:-/sys/block}

# the disks that carry bulk data, parity or the backup: by file system label, and the members of the ZFS pool `bulk`
members() {
  if [ -n "${HS_SPINDOWN_MEMBERS:-}" ]; then cat "$HS_SPINDOWN_MEMBERS" 2>/dev/null || true; return 0; fi
  local d p
  for d in "$sysfs"/*; do
    d=${d##*/}
    lsblk -rno LABEL "/dev/$d" 2>/dev/null | grep -Eq '^(bulk-data-[0-9]+|bulk-parity-[0-9]+|backup)$' && echo "$d"
  done
  if command -v zpool >/dev/null 2>&1; then
    zpool status -LP bulk 2>/dev/null | awk '$1 ~ /^\/dev\// {print $1}' | while read -r p; do
      lsblk -rno PKNAME "$p" 2>/dev/null | head -n 1 | grep . || basename "$p"
    done
  fi
  return 0
}

is_rot() { [ "$(cat "$sysfs/$1/queue/rotational" 2>/dev/null || echo 0)" = 1 ]; }
sysdisk() {   # is this disk the one under / or /boot?
  local src
  for src in / /boot; do
    findmnt -no SOURCE "$src" 2>/dev/null | head -n 1 | xargs -r -I{} lsblk -rno PKNAME {} 2>/dev/null
  done | grep -qx "$1"
}

mem=$(members | sort -u)
value=$(spindown_value "$minutes")

case "$mode" in
  status)
    printf 'disk\trotational\tmember\tstate\tminutes\n'
    for d in "$sysfs"/*; do
      d=${d##*/}
      case "$d" in loop*|ram*|zd*|dm-*|md*|sr*|nbd*) continue ;; esac
      rot=no; is_rot "$d" && rot=yes
      m=no; grep -qx "$d" <<<"$mem" && m=yes
      st=-
      if [ "$rot" = yes ] && command -v hdparm >/dev/null 2>&1; then
        st=$(hdparm -C "/dev/$d" 2>/dev/null | awk '/drive state is:/ {print $NF}')
        [ -n "$st" ] || st=-
      fi
      printf '%s\t%s\t%s\t%s\t%s\n' "$d" "$rot" "$m" "$st" "$([ "$rot$m" = yesyes ] && echo "$minutes" || echo -)"
    done ;;
  apply)
    command -v hdparm >/dev/null 2>&1 || fail "hdparm is not installed."
    n=0
    for d in $mem; do
      is_rot "$d" || { note "$d: not a spinning disk, left alone"; continue; }
      sysdisk "$d" && { note "$d: system disk, left alone"; continue; }
      if hdparm -S "$value" "/dev/$d" >/dev/null 2>&1; then
        n=$((n + 1))
        if [ "$minutes" -gt 0 ]; then ok "$d: standby after $minutes min (hdparm -S $value)"; else ok "$d: standby timer off"; fi
      else
        warn "$d: refuses hdparm -S (USB bridge or firmware), left as it is"
      fi
    done
    [ "$n" -gt 0 ] || note "no disk to set"
    ;;
esac
