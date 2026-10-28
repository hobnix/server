#!/usr/bin/env bash
# help: the disks that were plugged in or taken out lately (the service behind it logs them and sends a push message)
# help.de: die zuletzt ein- oder ausgesteckten Platten (der Dienst dahinter protokolliert sie und schickt eine Push-Nachricht)
# args: [log] | add|remove <kernel name> | seed
# Called by udev through hs-disk-event@<action>-<name>.service when a disk appears or goes away (hs sys disk event ...). It
# NEVER touches a disk: it describes it (size, model, serial, what is on it), writes a line to /var/lib/hs/disk-events and sends
# a push message. Adding a disk to a pool stays a deliberate step: hs pool <pool> add (or the Disks tab).
# Every disk it has seen is remembered in <state>/disks-seen/<name> (serial|description|member): an add event for a disk that is
# known already (udev replays all of them at every boot and at every `hs rebuild`) is silent. The first run records the disks that
# are there and says nothing. No push message in the first minutes after a boot (HS_BOOT_WINDOW). Push messages are never translated.
# Test knobs: HS_STATE_DIR, HS_PROC_UPTIME, HS_BOOT_WINDOW, HS_UDEVADM, HS_LSBLK, HS_BLKID.
set -euo pipefail
here=$(dirname "$0")
state=${HS_STATE_DIR:-/var/lib/hs}
seen=$state/disks-seen
log=$state/disk-events
lsblk_=${HS_LSBLK:-lsblk}
blkid_=${HS_BLKID:-blkid}

human() { numfmt --to=si --round=nearest --suffix=B --format='%.1f' "$1" 2>/dev/null || echo "${1}B"; }

is_disk_name() { [[ "$1" =~ ^[a-z][a-z0-9]*$ ]] && [[ ! "$1" =~ ^(loop|ram|zram|sr|fd|nbd|zd[0-9]|dm|md) ]]; }

# serial|description|member for a disk that is there now
describe() {
  local name=$1 size model serial parts label fstypes state="" member=no t
  read -r size < <("$lsblk_" -dnb -o SIZE "/dev/$name" 2>/dev/null || echo 0)
  model=$("$lsblk_" -dn -o MODEL "/dev/$name" 2>/dev/null | sed 's/[[:space:]]*$//' | head -n1 || true)
  serial=$("$lsblk_" -dn -o SERIAL "/dev/$name" 2>/dev/null | sed 's/[[:space:]]*$//' | head -n1 || true)
  parts=$("$lsblk_" -nr -o LABEL,FSTYPE "/dev/$name" 2>/dev/null || true)
  label=$(awk 'NF >= 1 && $1 ~ /^(bulk-|backup$)/ { print $1; exit }' <<<"$parts")
  fstypes=$(awk 'NF >= 2 { print $2 } NF == 1 && $1 ~ /^(ext4|xfs|btrfs|ntfs|exfat|vfat|zfs_member|crypto_LUKS|swap)$/ { print $1 }' <<<"$parts" | sort -u | paste -sd, || true)
  case "$label" in
    bulk-*) state="a member of the bulk array (${label#bulk-})"; member=yes ;;
    backup) state="the backup disk"; member=yes ;;
    *)
      case ",$fstypes," in
        *,zfs_member,*) state="has ZFS labels (a pool member or a leftover)"; member=yes ;;
        *,crypto_LUKS,*) state="encrypted (LUKS): not touched" ;;
        ,,) state="empty: it can be added to a pool" ;;
        *) state="holds data ($fstypes): nothing is erased unless you add it to a pool" ;;
      esac ;;
  esac
  t="$name, ${model:-unknown model}, $(human "${size:-0}")${serial:+, S/N $serial}: $state"
  printf '%s|%s|%s\n' "${serial:-?}" "$t" "$member"
}

record() { mkdir -p "$seen"; printf '%s\n' "$2" > "$seen/$1"; }

seed() {   # remember the disks that are there, silently
  local n
  mkdir -p "$seen"
  while read -r n; do
    is_disk_name "$n" || continue
    [ -e "$seen/$n" ] || record "$n" "$(describe "$n")"
  done < <("$lsblk_" -dn -o NAME,TYPE 2>/dev/null | awk '$2 == "disk" { print $1 }')
  touch "$seen/.seeded"
}

event_log() {   # event_log <what> <text>
  mkdir -p "$state"
  printf '%s\t%s\t%s\n' "$(date '+%Y-%m-%d %H:%M')" "$1" "$2" >> "$log"
  tail -n 200 "$log" > "$log.tmp" && mv "$log.tmp" "$log"
}

# the state database learns about the change at once; never fails the service
collect_state() { bash "$here/state.sh" collect --event >/dev/null 2>&1 || true; }

push() {   # push <title> <text> <priority> <category>: never fails the service
  local up
  up=$(cut -d. -f1 "${HS_PROC_UPTIME:-/proc/uptime}" 2>/dev/null || echo 99999)
  [ "${up:-99999}" -ge "${HS_BOOT_WINDOW:-300}" ] || return 0
  bash "$here/notify.sh" --category "$4" "$1" "$2" "$3" >/dev/null 2>&1 || true
}

case "${1:-log}" in
  log)
    . "$here/lib/ui.sh"
    if [ -s "$log" ]; then
      { thead 'When' 'Event' 'Disk'; tail -n 30 "$log"; } | table
    else
      note "No disk was plugged in or taken out since this was set up."
    fi ;;
  seed) seed ;;
  add|remove)
    action=$1; name=${2:-}
    is_disk_name "$name" || exit 0
    mkdir -p "$state"
    exec 9>"$state/disk-event.lock"
    ! command -v flock >/dev/null || flock 9   # one event at a time: the first one seeds, the others see its records
    host=$(hostname)
    # the first run only learns what is there (nothing to announce about disks that were always in the machine)
    if [ ! -e "$seen/.seeded" ]; then seed; exit 0; fi
    case "$action" in
      add)
        "${HS_UDEVADM:-udevadm}" settle --timeout=15 2>/dev/null || true
        info=$(describe "$name")
        serial=${info%%|*}
        if [ -e "$seen/$name" ] && [ "$(cut -d'|' -f1 "$seen/$name")" = "$serial" ]; then exit 0; fi   # known: a replay
        text=$(cut -d'|' -f2 <<<"$info")
        record "$name" "$info"
        echo "plugged in: $text"
        event_log "plugged in" "$text"
        collect_state
        push "$host: disk plugged in" "$text" default info ;;
      remove)
        [ -e "$seen/$name" ] || exit 0
        old=$(cat "$seen/$name")
        text=$(cut -d'|' -f2 <<<"$old")
        member=$(cut -d'|' -f3 <<<"$old")
        rm -f "$seen/$name"
        echo "taken out: $text"
        event_log "taken out" "$text"
        collect_state
        if [ "$member" = yes ]; then
          push "$host: disk taken out" "$text. It belonged to a pool: see \`hs health\`." high alarm
        else
          push "$host: disk taken out" "$text" low info
        fi ;;
    esac ;;
  *) echo "usage: disk-event.sh [log] | add|remove <kernel name> | seed" >&2; exit 1 ;;
esac
