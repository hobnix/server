#!/usr/bin/env bash
# One disk reached over two cables (dual-port SAS disk on two controllers) shows up as two block devices with the same WWID.
# second_path <name>: true when <name> is the spare path of such a disk, so listings show the disk once.
# The path that is open as LUKS wins; without one the lower name does. HS_SYSFS: test knob (default /sys/block).
second_path() {
  local w o sys=${HS_SYSFS:-/sys/block} first=""
  w=$(cat "$sys/$1/device/wwid" 2>/dev/null || true)
  [ -n "$w" ] || return 1
  for o in "$sys"/sd*; do
    o=${o##*/}
    [ "$o" != "$1" ] || continue
    [ "$(cat "$sys/$o/device/wwid" 2>/dev/null || true)" = "$w" ] || continue
    if lsblk -nr -o TYPE "/dev/$o" 2>/dev/null | grep -qx crypt; then return 0; fi
    [ -n "$first" ] || first=$o
  done
  [ -n "$first" ] || return 1
  # no sibling is open: the other path is a twin; hide this one only when the twin sorts first and this one is not open itself
  lsblk -nr -o TYPE "/dev/$1" 2>/dev/null | grep -qx crypt && return 1
  [[ "$1" > "$first" ]]
}

# stable_id <name>: the /dev/disk/by-id name of a disk (readable ata-/scsi-/nvme- name before wwn-). udev links the by-id names of a
# dual-port disk to ONE of its two devices, so the path that second_path leaves visible may have none: then the name of its twin
# is used (same disk, same data). HS_BYID: test knob (default /dev/disk/by-id).
stable_id() {
  local n o w sys=${HS_SYSFS:-/sys/block} byid=${HS_BYID:-/dev/disk/by-id} id
  w=$(cat "$sys/$1/device/wwid" 2>/dev/null || true)
  for n in "$1" $( [ -z "$w" ] || for o in "$sys"/sd*; do o=${o##*/}; [ "$o" != "$1" ] && [ "$(cat "$sys/$o/device/wwid" 2>/dev/null || true)" = "$w" ] && echo "$o"; done ); do
    id=$(find "$byid" -maxdepth 1 -type l ! -name '*-part*' ! -name 'wwn-*' ! -name 'nvme-eui.*' -lname "*/$n" -printf '%f\n' | sort | head -n1)
    [ -n "$id" ] || id=$(find "$byid" -maxdepth 1 -type l ! -name '*-part*' -lname "*/$n" -printf '%f\n' | sort | head -n1)
    if [ -n "$id" ]; then echo "$id"; return 0; fi
  done
  return 1
}
