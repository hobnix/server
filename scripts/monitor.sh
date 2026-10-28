#!/usr/bin/env bash
# help: live overview of CPU, memory, pools and disks (temperature, health, role)
# help.de: Live-Übersicht über CPU, Speicher, Pools und Platten (Temperatur, Zustand, Aufgabe)
# args: [--plain]  (--disks [--fresh]: the machine-readable disk table, see below)
set -euo pipefail
. "$(dirname "$0")/lib/ui.sh"
. "$(dirname "$0")/lib/diskpath.sh"
. "$(dirname "$0")/lib/diskused.sh"
. "$(dirname "$0")/lib/bulkpath.sh"

mode=""
plain=false
fresh=false
while [ $# -gt 0 ]; do
  case "$1" in
    --plain) plain=true; shift ;;
    --disks) mode=disks; shift ;;   # machine-readable, for the web interface (Disks)
    --fresh) fresh=true; shift ;;   # with --disks: ask every disk itself (smartctl) instead of reading the exporter's last scrape
    *) say "usage: hs monitor [--plain]"; exit 1 ;;
  esac
done

here=$(dirname "$0")

# ── One line per disk, tab separated ──
# Free bytes of a mounted filesystem, or "-"
avail_of() {
  local v
  v=$(df -B1 --output=avail "$1" 2>/dev/null | tail -n1 | tr -d ' ' || true)
  [[ "$v" =~ ^[0-9]+$ ]] && echo "$v" || echo "-"
}
# Free bytes of the ZFS vdev (mirror) a disk belongs to: `zpool list -v` shows size, allocated and free per vdev
zfs_vdev_free() {   # zfs_vdev_free <pool> <kernel name>
  local v
  # a mirror's own line carries the numbers, its disks show "-": remember the last numeric line; a lone disk has its own. Indentation is not relied on.
  v=$(zpool list -vHpL "$1" 2>/dev/null | awk -F'	' -v d="$2" -v pool="$1" '
    { line = $0; sub(/^[ 	]+/, "", line); n = split(line, f, "	"); name = f[1]
      if (name ~ /^sd[a-z]+[0-9]+$/) sub(/[0-9]+$/, "", name); else if (name ~ /^nvme[0-9]+n[0-9]+p[0-9]+$/) sub(/p[0-9]+$/, "", name)
      num = (f[4] ~ /^[0-9]+$/)
      if (name == d) { print (num ? f[4] : vfree); exit }
      if (name != pool && num) vfree = f[4] }' || true)
  # not found: the pool's own free space (right for one mirror)
  [[ "$v" =~ ^[0-9]+$ ]] || v=$(zpool list -Hp -o free "$1" 2>/dev/null || true)
  [[ "$v" =~ ^[0-9]+$ ]] && echo "$v" || echo "-"
}

# SMART values of every disk the smartctl exporter on this host knows (machine.toml: metrics = true; it scrapes every 5 minutes, so the
# values are at most that old): device<TAB>temp<TAB>health<TAB>hours<TAB>realloc<TAB>pending<TAB>crc. A disk without a current
# temperature in it (asleep, new, not rescanned yet) is left out: the caller asks smartctl for that one. `--fresh` skips all of this.
exporter_smart() {
  curl -s -m 2 "${HS_SMARTCTL_URL:-http://127.0.0.1:9633/metrics}" 2>/dev/null | awk '
    function dev(s) { if (match(s, /device="[^"]*"/)) return substr(s, RSTART + 8, RLENGTH - 9); return "" }
    /^smartctl_device_temperature\{/ && /temperature_type="current"/ { d = dev($0); temp[d] = $NF }
    /^smartctl_device_smart_status\{/ { d = dev($0); st[d] = ($NF + 0 == 1) ? "OK" : "FAIL" }
    /^smartctl_device_power_on_seconds\{/ { d = dev($0); hrs[d] = int($NF / 3600) }
    /^smartctl_device_attribute\{/ && /attribute_value_type="raw"/ {
      d = dev($0)
      if (match($0, /attribute_id="[0-9]+"/)) {
        id = substr($0, RSTART + 14, RLENGTH - 15)
        if (id == 5) a5[d] = $NF + 0; else if (id == 197) a197[d] = $NF + 0; else if (id == 199) a199[d] = $NF + 0
      }
    }
    END { for (d in temp) if (d != "") printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", d, temp[d], (d in st ? st[d] : "-"), (d in hrs ? hrs[d] : "-"), (d in a5 ? a5[d] : "-"), (d in a197 ? a197[d] : "-"), (d in a199 ? a199[d] : "-") }' || true
}

# Power state of a rotating disk without waking it (hdparm -C only asks the drive's power mode): spinning | asleep | "-" (SSD, NVMe, no hdparm, no answer)
power_of() {   # power_of <name> <rota>
  local st
  [ "$2" = 1 ] && command -v hdparm >/dev/null 2>&1 || { echo -; return 0; }
  st=$(hdparm -C "/dev/$1" 2>/dev/null | awk -F: '/drive state is/ { gsub(/[ 	]/, "", $2); print $2 }' || true)
  case "$st" in
    active*|idle*) echo spinning ;;
    standby|sleeping) echo asleep ;;
    *) echo - ;;
  esac
}

# name  bytes  SSD/HDD  role  temp  health  hours  reallocated  pending  crc  model+serial  free (bytes of free space on it, or "-": a free disk, a disk that is not mounted)  power (spinning|asleep|-)
disks() {
  # which pool a disk belongs to (ZFS)
  declare -A member=()
  local p dev
  for p in $(zpool list -H -o name 2>/dev/null); do
    while read -r dev; do
      member[$dev]=$p
    done < <(zpool status -L "$p" 2>/dev/null |
      awk '/^[ \t]*NAME/ { on = 1; next } on && NF == 0 { on = 0 } on { print $1 }' |
      sed -E 's/^(sd[a-z]+)[0-9]+$/\1/; s/^(nvme[0-9]+n[0-9]+)p[0-9]+$/\1/')
  done

  local name size type rota rest role label smart free mp d vals used
  declare -A exported=()
  if ! $fresh; then
    while IFS=$'\t' read -r d vals; do
      [ -z "$d" ] || exported[$d]=$vals
    done < <(exporter_smart)
  fi
  while read -r name size type rota rest; do
    [ "$type" = disk ] || continue
    [ "$size" -gt 0 ] || continue
    [[ "$name" == zd* ]] && continue
    [ -n "${member[$name]:-}" ] || ! second_path "$name" || continue   # the spare cable of a dual-port disk

    label=$(lsblk -nr -o LABEL "/dev/$name" | grep -m1 '^bulk-' || true)
    if [ -n "${member[$name]:-}" ]; then
      role=${member[$name]}
    elif [ -n "$label" ]; then
      role="bulk ${label#bulk-}"
    elif lsblk -nr -o LABEL "/dev/$name" | grep -qx 'backup'; then
      role="backup disk"
    elif lsblk -nr -o MOUNTPOINT "/dev/$name" | grep -qx '/'; then
      role=system
    elif [ -n "$(lsblk -nr -o MOUNTPOINT "/dev/$name" | tr -d '\n')" ]; then
      role=mounted
    else
      role=free
    fi

    # SMART: the exporter's last scrape when it has the disk, else the disk itself.
    # -n standby: don't wake a sleeping disk just to read its temperature
    smart=${exported[$name]:-}
    if [ -z "$smart" ]; then
      smart=$(smartctl -n standby -j -i -H -A "/dev/$name" 2>/dev/null |
        jq -r 'def attr(n): ((.ata_smart_attributes.table // []) | map(select(.id == n)) | .[0].raw.value) // "-";
          [ (.temperature.current // "-"),
            (if .smart_status.passed == true then "OK" elif .smart_status.passed == false then "FAIL"
             elif ((.smartctl.messages // []) | map(.string) | join(" ") | test("STANDBY|SLEEP")) then "asleep" else "-" end),
            (.power_on_time.hours // "-"), attr(5), attr(197), attr(199) ] | @tsv' 2>/dev/null || true)
    fi
    [ -n "$smart" ] || smart=$'-\t-\t-\t-\t-\t-'

    # free space: the filesystem of a snapraid disk, the system disk, a mounted disk; the vdev of a ZFS member
    case "$role" in
      system) free=$(avail_of /) ;;
      "bulk "*) free=$(avail_of "$(disk_dir "$label")") ;;
      "backup disk") mp=$(lsblk -nr -o MOUNTPOINT "/dev/$name" | grep -m1 . || true); free=$([ -n "$mp" ] && avail_of "$mp" || echo -) ;;
      mounted) mp=$(lsblk -nr -o MOUNTPOINT "/dev/$name" | grep -m1 . || true); free=$(avail_of "$mp") ;;
      # not mounted: size minus what the superblock says is used (cached, see lib/diskused.sh); "-" when that is not known
      free) used=$(disk_used_bytes "$name"); [[ "$used" =~ ^[0-9]+$ ]] && free=$((size - used)) || free="-" ;;
      *) free=$(zfs_vdev_free "$role" "$name") ;;
    esac

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$size" "$([ "$rota" = 1 ] && echo HDD || echo SSD)" "$role" "$smart" "$rest" "$free" "$(power_of "$name" "$rota")"
  done < <(lsblk -dnb -o NAME,SIZE,TYPE,ROTA,MODEL,SERIAL)
}

if [ "$mode" = disks ]; then
  disks
  exit 0
fi

# ── Plain output ──
up=$(awk '{ s = int($1); d = int(s / 86400); h = int(s % 86400 / 3600); m = int(s % 3600 / 60); o = ""
  if (d) o = d " d "
  if (d || h) o = o h " h "
  print o m " min" }' /proc/uptime 2>/dev/null || echo '?')
step "$(t '%s: load %s, up %s' "$(hostname)" "$(cut -d' ' -f1-3 /proc/loadavg)" "$up")"
free -h | sed -n '1,3p' | trail
for p in fast bulk; do
  step "$p"
  bash "$here/manage-pool.sh" "$p" --info | trail
done
step "Disks"
{
  thead 'Name' 'Size' 'Type' 'Role' 'Temp' 'Health' 'Hours' 'Realloc' 'Pending' 'CRC' 'Model' 'Free' 'Power'
  disks | awk -F'\t' -v OFS='\t' '{ $2 = sprintf("%.1fTB", $2 / 1e12); print }'
} | table
