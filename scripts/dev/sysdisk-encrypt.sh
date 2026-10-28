#!/usr/bin/env bash
# Move the running NixOS system onto a NEW, empty disk: GPT = ESP + LUKS2 (ext4 inside).
# Rehearsed in a throwaway Incus VM; not part of CI, not an `hs` command.
#
#   sysdisk-encrypt.sh prepare <disk-by-id>   partition, LUKS, mkfs, rsync the running system to /mnt/new, print the UUIDs
#   sysdisk-encrypt.sh open    <disk-by-id>   open + mount again (/mnt/new, /mnt/new/boot) for later changes (nixos-enter)
#   sysdisk-encrypt.sh close                  unmount and close
#
# <disk-by-id> = /dev/disk/by-id/<name> of the WHOLE disk (never /dev/sdX: names change between boots).
# Needs: sgdisk (gptfdisk), cryptsetup, rsync, mkfs.vfat (dosfstools), mkfs.ext4, partprobe (parted), as root.
#   nix-shell -p gptfdisk cryptsetup rsync parted dosfstools --run 'bash sysdisk-encrypt.sh prepare /dev/disk/by-id/...'
# Passphrase: typed twice (prepare) or taken from $PASS (tests).
set -euo pipefail
MAP=sysdisk-new
NEW=/mnt/new

die() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root"

passphrase() {
  if [ -n "${PASS:-}" ]; then printf %s "$PASS"; return; fi
  local a b
  read -r -s -p "LUKS passphrase: " a </dev/tty; echo >&2
  if [ "${1:-}" = new ]; then
    read -r -s -p "again: " b </dev/tty; echo >&2
    [ "$a" = "$b" ] || die "passphrases differ"
  fi
  printf %s "$a"
}

cmd=${1:-}; D=${2:-}
case "$cmd" in
prepare)
  [ -n "$D" ] || die "usage: $0 prepare <disk-by-id>"
  [ -b "$D" ] || die "$D is not a block device"
  case "$D" in /dev/disk/by-id/*) ;; *) die "use the /dev/disk/by-id/ name";; esac
  real=$(readlink -f "$D")
  # Safety: the disk must be empty and unused.
  if lsblk -no MOUNTPOINTS "$real" | grep -q .; then die "$D has mounted partitions"; fi
  if [ -n "$(wipefs -n "$real" 2>/dev/null | tail -n +2)" ] && [ "${FORCE_WIPE:-}" != 1 ]; then
    wipefs -n "$real" >&2; die "$D already has signatures; if it is really the new disk: FORCE_WIPE=1"
  fi
  echo "About to ERASE $D ($(lsblk -dno SIZE,MODEL "$real"))."
  if [ -z "${PASS:-}" ]; then read -r -p "Type YES to continue: " ok </dev/tty; [ "$ok" = YES ] || die "aborted"; fi
  pw=$(passphrase new)
  sgdisk --zap-all "$D"
  sgdisk -n1:0:+512M -t1:ef00 -c1:ESP-new -n2:0:0 -t2:8309 -c2:cryptroot "$D"
  partprobe "$real"; udevadm settle; sleep 2
  printf %s "$pw" | cryptsetup luksFormat --type luks2 --batch-mode --key-file=- "${D}-part2"
  printf %s "$pw" | cryptsetup open --key-file=- "${D}-part2" "$MAP"
  mkfs.ext4 -L nixos-enc "/dev/mapper/$MAP"
  # -i: inside nix-shell SOURCE_DATE_EPOCH is set and every mkfs.vfat gives the SAME volume id (clashes with the old ESP)
  mkfs.vfat -F32 -n BOOTENC -i "$(printf %08X $((RANDOM * 65536 + RANDOM)))" "${D}-part1"
  mkdir -p "$NEW"; mount "/dev/mapper/$MAP" "$NEW"
  mkdir -p "$NEW/boot"; mount -o umask=0077 "${D}-part1" "$NEW/boot"
  # -x: stay on the root filesystem (no /boot, no /bulk, no ZFS datasets); runtime directories come back empty
  rsync -aAXHx --info=progress2 \
    --exclude='/dev/*' --exclude='/proc/*' --exclude='/sys/*' --exclude='/run/*' \
    --exclude='/tmp/*' --exclude='/mnt/*' --exclude='/lost+found' \
    / "$NEW/"
  mkdir -p "$NEW"/{dev,proc,sys,run,tmp,mnt}; chmod 1777 "$NEW/tmp"
  echo
  echo "Disk ready, mounted at $NEW. UUIDs for hardware-configuration.nix:"
  echo "  LUKS (boot.initrd.luks.devices.*.device): $(cryptsetup luksUUID "${D}-part2")"
  echo "  root (fileSystems.\"/\"):                  $(blkid -s UUID -o value "/dev/mapper/$MAP")"
  echo "  ESP  (fileSystems.\"/boot\"):              $(blkid -s UUID -o value "${D}-part1")"
  ;;
open)
  [ -b "$D" ] || die "usage: $0 open <disk-by-id>"
  passphrase | cryptsetup open --key-file=- "${D}-part2" "$MAP"
  mkdir -p "$NEW"; mount "/dev/mapper/$MAP" "$NEW"; mount -o umask=0077 "${D}-part1" "$NEW/boot"
  echo "mounted at $NEW"
  ;;
close)
  umount "$NEW/boot" "$NEW" 2>/dev/null || true
  cryptsetup close "$MAP"
  ;;
*) die "usage: $0 prepare|open|close <disk-by-id>";;
esac
