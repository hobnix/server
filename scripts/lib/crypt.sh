# shellcheck shell=bash
# Encrypted storage: one passphrase for every LUKS disk and every ZFS pool of
# this server. Sourced, not run (it lives in lib/ so `hs` does not offer it):
#   . "$(dirname "$0")/lib/crypt.sh"
#
# Where things are kept:
#   /var/lib/hs/luks-uuids   the LUKS disks that belong to this server (not other people's)
#   /var/lib/hs/disk-key     the passphrase, optional (with a vault: a link into the vault, so only readable while it is open)
#   /var/lib/hs/vault-uuid   LUKS uuid of the vault (lib/vault.sh); the vault is opened by vault_open as /dev/mapper/hs-vault,
#                            so the functions below leave it alone (it is not in luks-uuids)
#   /run/hs/storage-locked   exists while encrypted storage is waiting for `hs unlock`;
#                            the services that need the disks don't start then
#
# LUKS disks are opened as /dev/mapper/hs-<first 12 characters of the LUKS uuid>.

. "$(dirname "${BASH_SOURCE[0]}")/ui.sh"

crypt_state=${HS_STATE_DIR:-/var/lib/hs}
crypt_run=${HS_RUN_DIR:-/run/hs}
crypt_keyfile=$crypt_state/disk-key
crypt_uuids=$crypt_state/luks-uuids
crypt_locked=$crypt_run/storage-locked
crypt_pass=""
crypt_opened=0
crypt_skipped=0
crypt_unknown=""   # devices with a LUKS header that are not this server's (not opened in "known" mode)

crypt_vault_uuid() { cat "$crypt_state/vault-uuid" 2>/dev/null || true; }   # empty without a vault
crypt_is_vault() { local v; v=$(crypt_vault_uuid); [ -n "$v" ] && [ "$(cryptsetup luksUUID "$1" 2>/dev/null)" = "$v" ]; }   # crypt_is_vault <luks device>
crypt_known_uuid() { { [ -f "$crypt_uuids" ] && grep -qxF "$1" "$crypt_uuids"; } || { [ -n "$1" ] && [ "$1" = "$(crypt_vault_uuid)" ]; }; }
crypt_record() {   # crypt_record <luks device>: this disk belongs to the server from now on
  local u
  u=$(cryptsetup luksUUID "$1")
  mkdir -p "$crypt_state"
  crypt_known_uuid "$u" || echo "$u" >> "$crypt_uuids"
}
luks_name() {      # luks_name <luks device>
  local u
  u=$(cryptsetup luksUUID "$1")
  u=${u//-/}
  echo "hs-${u:0:12}"
}
luks_devices() {   # every disk, partition or image that holds a LUKS header
  local p t
  while read -r p t; do
    case "$t" in part|disk|loop) ;; *) continue ;; esac
    if [ "$(blkid -p -o value -s TYPE "$p" 2>/dev/null || true)" = crypto_LUKS ]; then echo "$p"; fi
  done < <(lsblk -nr -o PATH,TYPE)
}
luks_in_use() {    # luks_in_use <device>: something is mapped on it already, whatever its name (HS_SYS_BLOCK = test stand-in)
  local b
  b=$(basename "$(readlink -f "$1")")
  [ -n "$(ls "${HS_SYS_BLOCK:-/sys/class/block}/$b/holders" 2>/dev/null)" ]
}
# Whose is the LUKS volume on a disk? Decides whether a disk with a LUKS header may be offered as a free disk.
#   own        this server's (recorded UUID, and nothing else carries it, or it is the one that is open): never offered
#   ambiguous  the UUID of one of ours on a second device and nothing says which is the real one (both closed): never offered
#   copy       the UUID of one of ours, but the real one is open elsewhere (an old system disk): offered with a warning
#   foreign    not recorded: somebody else's data, offered with a warning (the new owner decides, after a typed confirmation)
crypt_partition_class() {   # crypt_partition_class <luks partition>
  local p=$1 u d others=0 other_open=no
  u=$(cryptsetup luksUUID "$p" 2>/dev/null || true)
  [ -n "$u" ] && crypt_known_uuid "$u" || { echo foreign; return; }
  luks_in_use "$p" && { echo own; return; }
  while read -r d; do
    [ "$d" = "$p" ] && continue
    [ "$(cryptsetup luksUUID "$d" 2>/dev/null || true)" = "$u" ] || continue
    others=1
    ! luks_in_use "$d" || other_open=yes
  done < <(luks_devices)
  if [ "$others" = 0 ]; then echo own; elif [ "$other_open" = yes ]; then echo copy; else echo ambiguous; fi
}
crypt_disk_class() {   # crypt_disk_class <disk>: own or ambiguous when any volume on it is, else copy or foreign
  local p cls res=foreign
  while read -r p; do
    [ "$(blkid -p -o value -s TYPE "$p" 2>/dev/null || true)" = crypto_LUKS ] || continue
    cls=$(crypt_partition_class "$p")
    case "$cls" in own|ambiguous) echo "$cls"; return ;; copy) res=copy ;; esac
  done < <(lsblk -nr -o PATH "$1")
  echo "$res"
}
luks_dev_of() {    # luks_dev_of <uuid>
  local d
  while read -r d; do
    [ "$(cryptsetup luksUUID "$d" 2>/dev/null)" = "$1" ] && { echo "$d"; return 0; }
  done < <(luks_devices)
  return 1
}

# ── The passphrase ──
crypt_verify() {   # does crypt_pass open one of our disks (or the vault)? (nothing known yet: yes)
  local u d
  [ -s "$crypt_uuids" ] || [ -s "$crypt_state/vault-uuid" ] || return 0
  while read -r u; do
    [ -n "$u" ] || continue
    d=$(luks_dev_of "$u") || continue
    if printf %s "$crypt_pass" | cryptsetup open --test-passphrase --key-file - "$d" 2>/dev/null; then return 0; fi
    echo "That passphrase does not open $d." >&2
    return 1
  done < <({ cat "$crypt_uuids" 2>/dev/null; crypt_vault_uuid; } | awk 'NF')
  return 0
}
crypt_get_pass() {   # sets crypt_pass: environment (tests), key file, or a prompt
  [ -z "$crypt_pass" ] || return 0
  if [ -n "${HS_DISK_PASSPHRASE:-}" ]; then crypt_pass=$HS_DISK_PASSPHRASE
  elif [ -n "${HS_DISK_PASSPHRASE_FILE:-}" ] && [ -f "$HS_DISK_PASSPHRASE_FILE" ]; then   # a job started by a wizard: read once, delete
    crypt_pass=$(cat "$HS_DISK_PASSPHRASE_FILE"); rm -f "$HS_DISK_PASSPHRASE_FILE"
  elif [ -f "$crypt_keyfile" ]; then crypt_pass=$(cat "$crypt_keyfile")
  else crypt_pass=$(ask_secret "Disk passphrase:"); fi
  [ -n "$crypt_pass" ]
}
crypt_new_pass() {   # for making encrypted disks: the passphrase the server already uses, or a new one
  [ -z "$crypt_pass" ] || return 0
  if [ -n "${HS_DISK_PASSPHRASE:-}" ] || [ -n "${HS_DISK_PASSPHRASE_FILE:-}" ] || [ -f "$crypt_keyfile" ] || [ -s "$crypt_uuids" ] || [ -s "$crypt_state/vault-uuid" ]; then
    crypt_get_pass && crypt_verify
    return
  fi
  local a b
  a=$(ask_secret "New passphrase for encrypted disks (the same for all of them):")
  b=$(ask_secret "Again:")
  if [ -z "$a" ] || [ "$a" != "$b" ]; then echo "Empty, or the two entries differ." >&2; return 1; fi
  crypt_pass=$a
}

# ── LUKS ──
luks_format() {    # luks_format <device>: ERASES it. Needs crypt_pass.
  printf %s "$crypt_pass" | cryptsetup luksFormat --batch-mode --type luks2 --key-file - "$1"
}
luks_open() {      # luks_open <device>: 0 when it is open afterwards. Needs crypt_pass.
  local name
  name=$(luks_name "$1")
  [ -e "/dev/mapper/$name" ] && return 0
  printf %s "$crypt_pass" | cryptsetup open --key-file - "$1" "$name" 2>/dev/null
}
crypt_locked_devices() {   # our LUKS disks that are plugged in but not open
  local d u
  [ -s "$crypt_uuids" ] || return 0
  while read -r d; do
    u=$(cryptsetup luksUUID "$d" 2>/dev/null) || continue
    [ "$u" != "$(crypt_vault_uuid)" ] || continue   # the vault has its own name and its own check (vault_is_open)
    if crypt_known_uuid "$u" && [ ! -e "/dev/mapper/$(luks_name "$d")" ]; then echo "$d"; fi
  done < <(luks_devices)
}

# ── ZFS native encryption ──
zfs_locked() {     # encryption roots whose key is not loaded
  command -v zfs >/dev/null 2>&1 || return 0
  zfs list -H -o name,encryptionroot,keystatus 2>/dev/null | awk -F'\t' '$3 == "unavailable" && $1 == $2 { print $1 }' || true
}
zfs_unlock() {
  local r rc=0
  for r in $(zfs_locked); do
    printf '%s\n' "$crypt_pass" | zfs load-key "$r" 2>/dev/null || rc=1
  done
  return $rc
}

crypt_is_locked() { [ -n "$(crypt_locked_devices)$(zfs_locked)" ]; }

crypt_unlock_all() {   # crypt_unlock_all all|known: open the LUKS disks the passphrase fits, load the ZFS keys
  local mode=$1 d u
  crypt_opened=0; crypt_skipped=0; crypt_unknown=""
  while read -r d; do
    u=$(cryptsetup luksUUID "$d" 2>/dev/null) || continue
    [ "$u" != "$(crypt_vault_uuid)" ] || continue   # the vault is opened by vault_open, under its own name
    [ -e "/dev/mapper/$(luks_name "$d")" ] && continue
    luks_in_use "$d" && continue   # open under another name already (the system disk, opened by the initrd as cryptroot)
    if [ "$mode" = known ] && ! crypt_known_uuid "$u"; then crypt_unknown+="$d "; continue; fi
    if luks_open "$d"; then
      crypt_record "$d"; crypt_opened=$((crypt_opened + 1))
    else
      crypt_skipped=$((crypt_skipped + 1))
    fi
  done < <(luks_devices)
  zfs_unlock || true
}
