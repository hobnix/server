#!/usr/bin/env bash
# help: restore a server from its backup disk and the backup password onto a new system disk (run on the installer stick as root)
# help.de: einen Server von der Backup-Platte und dem Backup-Passwort auf eine neue Systemplatte zurückholen (auf dem Stick als root)
# args: [--backup-device <name>] [--password-file <file>] [--snapshot <id|latest>] [--disk <name>] [--confirm-disk <name>] [--answers <file>] [--dry-run]
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/ui.sh"
. "$here/lib/machine.sh"
. "$here/lib/restore.sh"

# Disaster-recovery bootstrap of the installer (issue #254, docs/backup-and-recovery.md Case A, docs/install.md "Restore from a backup").
#
# UNVERIFIED: NOT TESTED ON HARDWARE. Nothing in here has run against a real disk, a real backup disk or the ISO. tests/install-restore.sh
# covers the reading of the backup, the plan, the refusals and the files that end up in the target folder, with a fake restic and no disk.
#
# What it does: finds the backup disk (label "backup"), mounts it READ-ONLY, opens the restic repository with the backup password, reads
# the settings of a host snapshot (machine.toml, /var/lib/hs, SSH host keys) into a temporary folder, shows a plan, and after you type the
# NAME of the system disk it runs scripts/install-wizard.sh with those settings (--restore-from): the same disk layout, the same nixos-install.
# It never touches the backup disk (read-only mount) and never a data disk. Pools, the vault, containers and the shares are NOT restored
# here: that is Case A step 8 on, and Case B (hs backup restore) once the new server runs.
#
# Secrets: the backup password comes from a file (--password-file, or the answers file) or is asked without echo; it is written to a 0600
# file in a private temporary folder, never put on a command line or in the environment.
# Test knobs: HS_RESTORE_REPO (an existing restic repository folder: no disk is searched or mounted), HS_INSTALL_SKIP_DISK=1,
# HS_INSTALL_TARGET, HS_INSTALL_PASSWORD (passed on to the wizard), HS_PYTHON.

backup_dev=""; pwfile=""; snap=""; disk=""; confirm_disk=""; answers=""; dry=false; wrepo=""
target=${HS_INSTALL_TARGET:-/mnt}
while [ $# -gt 0 ]; do
  case "$1" in
    --backup-device) backup_dev=${2:?}; shift 2 ;;
    --password-file) pwfile=${2:?}; shift 2 ;;
    --snapshot) snap=${2:?}; shift 2 ;;
    --disk) disk=${2:?}; shift 2 ;;
    --confirm-disk) confirm_disk=${2:?}; shift 2 ;;
    --answers) answers=${2:?}; shift 2 ;;
    --target) target=${2:?}; shift 2 ;;
    --repo) wrepo=${2:?}; shift 2 ;;   # the repository the wizard copies (a test knob; the stick has the right default)
    --dry-run) dry=true; shift ;;
    *) note "usage: hs-restore [--backup-device <name>] [--password-file <file>] [--snapshot <id|latest>] [--disk <name>] [--confirm-disk <name>] [--answers <file>] [--dry-run]"; exit 1 ;;
  esac
done
skip=${HS_INSTALL_SKIP_DISK:-}
py=${HS_PYTHON:-python3}
tty=false; if [ -t 0 ] && [ -t 1 ]; then tty=true; fi

work=$(mktemp -d "${TMPDIR:-/tmp}/hs-restore.XXXXXX"); chmod 700 "$work"
mnt=""
cleanup() {
  # never remove the temporary folder while the backup disk may still be mounted below it
  if [ -n "$mnt" ] && ! umount "$mnt" 2>/dev/null; then
    warn "$(t 'Could not unmount %s; it was left as it is. Unmount it by hand.' "$mnt")"; return 0
  fi
  rm -rf "$work"
}
trap cleanup EXIT

# ---- the answers file (format: docs/install.md; checked with the same code as hs installer check-answers)
if [ -n "$answers" ]; then
  step "The answers file"
  rc=0; res=$("$py" -I "$here/lib/answers.py" check "$answers") || rc=$?
  if [ "$rc" -ne 0 ]; then
    while IFS=$'\t' read -r lvl where text; do [ "$lvl" != error ] || warn "$where: $text"; done <<<"$res"
    fail "The answers file has errors. Nothing was changed."
  fi
  ans() { "$py" -I "$here/lib/answers.py" get "$answers" "$1"; }
  [ -n "$backup_dev" ] || backup_dev=$(ans restore.backup_device)
  [ -n "$snap" ] || snap=$(ans restore.snapshot)
  [ -n "$disk" ] || disk=$(ans install.disk)
  [ -n "$confirm_disk" ] || confirm_disk=$(ans install.confirm_disk)
  [ -n "$pwfile" ] || pwfile=$(ans secrets.backup_passphrase_file)
  ok "The answers file is valid"
fi
[ -n "$snap" ] || snap=latest
[[ "$snap" =~ ^(latest|[0-9a-f]{8,64})$ ]] || fail "$(t "'%s' is not a snapshot id." "$snap")"

step "Restore from backup"
warn "UNVERIFIED: this restore has not been tested on hardware. Read the plan carefully."
if [ -z "$skip" ] && [ -z "${HS_RESTORE_REPO:-}" ] && ! $dry; then
  [ "$(id -u)" = 0 ] || fail "Run this as root (sudo -i)."
  findmnt -rn /iso >/dev/null 2>&1 || fail "This is not the installer stick (nothing is mounted at /iso), so nothing is restored. It runs from the stick."
fi

# ---- the backup disk, read-only
repo=${HS_RESTORE_REPO:-}
if [ -z "$repo" ]; then
  step "The backup disk"
  cands=$(lsblk -rn -o NAME,SIZE,LABEL,FSTYPE 2>/dev/null | awk '$3 == "backup" { print $1 "\t" $2 "\t" $4 }' || true)
  if [ -z "$backup_dev" ]; then
    [ -n "$cands" ] || fail "No disk with the label \"backup\" was found. Connect it, or name it with --backup-device."
    if [ "$(wc -l <<<"$cands")" -eq 1 ]; then backup_dev=${cands%%$'\t'*}
    else
      $tty || fail "More than one backup disk and no terminal: name one with --backup-device."
      { thead 'Name' 'Size' 'Type'; printf '%s\n' "$cands"; } | table
      backup_dev=$(ask "Name of the backup disk partition (e.g. sdb1)" "")
    fi
  fi
  backup_dev=${backup_dev#/dev/}
  [[ "$backup_dev" =~ ^[a-zA-Z0-9]+$ ]] || fail "$(t "'%s' is not a disk name." "$backup_dev")"
  [ -b "/dev/$backup_dev" ] || fail "$(t "There is no disk /dev/%s." "$backup_dev")"
  mnt=$work/backup; mkdir -p "$mnt"
  mount -o ro "/dev/$backup_dev" "$mnt" || { mnt=""; fail "$(t "/dev/%s could not be mounted read-only." "$backup_dev")"; }
  repo=$mnt/restic
  ok "$(t "/dev/%s is mounted read-only; nothing is written to it." "$backup_dev")"
fi
[ -f "$repo/config" ] || fail "$(t 'No backup repository in %s. Is this the disk made by hs backup init?' "$repo")"

# ---- the password: a file, or asked; written to a 0600 file, never to argv or the environment
if [ -z "$pwfile" ]; then
  $tty || fail "No terminal and no --password-file: the backup password cannot be asked."
  note "The backup password is in your password manager (hs secrets reminded you of it)."
  pw=$(ask_secret "Backup password:")
  [ -n "$pw" ] || fail "The password is empty. Nothing was changed."
  pwfile=$work/pass; ( umask 077; printf '%s' "$pw" > "$pwfile" ); pw=""
else
  [ -f "$pwfile" ] || fail "$(t 'The password file %s does not exist.' "$pwfile")"
fi

# ---- the snapshot
step "The snapshots"
snaps=$(restore_snapshots "$repo" "$pwfile") || true
[ -n "$snaps" ] || fail "The repository could not be opened, or holds no host snapshot. Wrong password, or the wrong disk? Nothing was changed."
{ thead 'Snapshot' 'When'; printf '%s\n' "$snaps"; } | table
if [ "$snap" != latest ] && ! grep -q "^${snap:0:8}" <<<"$snaps"; then fail "$(t 'No host snapshot %s.' "$snap")"; fi
fetched=$work/fetched; mkdir -p "$fetched"
restore_fetch "$repo" "$pwfile" "$snap" "$fetched" || fail "The settings could not be read from the snapshot. Nothing was changed."
[ -f "$fetched/etc/nixos/machine.toml" ] || fail "That snapshot holds no machine.toml. Choose another snapshot."
ok "The settings of the snapshot were read into a temporary folder"

# ---- what the new system gets from machine.toml
tget() { HS_MACHINE_FILE=$fetched/etc/nixos/machine.toml "$py" "$here/machine-toml.py" get "$fetched/etc/nixos/machine.toml" "$1" --json 2>/dev/null || true; }
unq() { "$py" -I -c 'import json,sys; v=json.loads(sys.argv[1] or "null"); print((v[0] if isinstance(v, list) and v else v) or "")' "$1" 2>/dev/null || true; }
hostname_=$(unq "$(tget hostName)"); role=$(unq "$(tget role)"); tz=$(unq "$(tget timeZone)")
key=$(unq "$(tget sshKeys)"); nic=$(unq "$(tget nic)"); smb=$(unq "$(tget smbAllow)")
[ -n "$role" ] || role=homeserver
[ -n "$hostname_" ] || fail "The restored machine.toml has no hostName."
[ -n "$key" ] || fail "The restored machine.toml has no SSH key (sshKeys): nobody could log in to the new server."

# ---- the system disk
disks() {   # the disks that are neither loop devices, optical drives nor the stick or the backup disk
  local ex=""
  ex=$(lsblk -no PKNAME "/dev/${backup_dev:-none}" 2>/dev/null | head -n1 || true)
  lsblk -dn -e 7,11 -o NAME,SIZE,TRAN,MODEL 2>/dev/null | awk -v ex="$ex" '$1 != ex { n = $1; s = $2; t = ($3 == "" || NF < 3) ? "-" : $3; $1 = $2 = ""; sub(/^ +/, ""); print n "\t" s "\t" t "\t" $0 }' || true
}
if [ -z "$disk" ]; then
  $tty || fail "No terminal and no --disk: nothing is chosen on a guess."
  step "Which disk is the NEW system disk?"
  note "Only this disk is erased. The data disks and the backup disk stay as they are, but check the name twice."
  { thead 'Name' 'Size' 'Bus' 'Model'; disks; } | table
  disk=$(ask "Name of the new system disk (e.g. sda or nvme0n1)" "")
fi
disk=${disk#/dev/}
[[ "$disk" =~ ^[a-zA-Z0-9]+$ ]] || fail "$(t "'%s' is not a disk name." "$disk")"
[ "$disk" != "${backup_dev:-}" ] || fail "That is the backup disk. It is never erased."
if [ -z "$skip" ] && [ -z "${HS_RESTORE_REPO:-}" ]; then
  [ -b "/dev/$disk" ] || fail "$(t "There is no disk /dev/%s." "$disk")"
  if lsblk -no MOUNTPOINTS "/dev/$disk" 2>/dev/null | grep -q .; then fail "$(t "/dev/%s has mounted parts (it may be the stick or the backup disk). Choose another." "$disk")"; fi
fi

# ---- the plan
step "The plan"
kv "Backup" "${backup_dev:+/dev/$backup_dev (read-only) }$repo"
kv "Snapshot" "$snap"
kv "New system disk" "/dev/$disk (erased)"
kv "Server name" "$hostname_"
kv "Role" "$role"
kv "Time zone" "${tz:-UTC (not set)}"
kv "SSH key" "${key%% *} ... ${key##* }"
note "Settings that come back from the backup:"
restore_files "$fetched" | trail
note "Not restored here: the backup password (it goes into the new vault by hand), the pools, shares and containers, the vault itself."
note "Data disks are not touched. Afterwards: first boot, hs rebuild, hs vault init, import the pools, hs unlock, hs backup restore (docs/backup-and-recovery.md)."
if $dry; then note "Dry run: nothing was changed."; exit 0; fi

[ -z "$confirm_disk" ] || [ "$confirm_disk" = "$disk" ] || fail "$(t "--confirm-disk '%s' is not the disk '%s'." "$confirm_disk" "$disk")"
if [ -z "$skip" ]; then
  if [ -z "$confirm_disk" ]; then
    $tty || fail "Erasing a disk asks for its name: run this in a terminal, or add --confirm-disk $disk."
    warn "$(t "Everything on /dev/%s will be erased." "$disk")"
    confirm_name "$disk" "the disk" || { note "Not the same name. Nothing was changed."; exit 1; }
    confirm_disk=$disk
  fi
fi

# ---- hand over to the installer: same layout, same nixos-install; it asks for the admin account's password itself (the name comes from the backup's machine.toml) (the answers file's admin_password_file is not read yet)
args=(--role "$role" --disk "$disk" --hostname "$hostname_" --key "$key" --restore-from "$fetched" --target "$target")
if [ "$role" = homeserver ]; then args+=(--preset minimal); else args+=(--preset "$role"); fi
[ -z "$wrepo" ] || args+=(--repo "$wrepo")
[ -z "$tz" ] || args+=(--timezone "$tz")
[ -z "$nic" ] || args+=(--nic "$nic")
[ -z "$smb" ] || args+=(--smb-allow "$smb")
[ -z "$confirm_disk" ] || args+=(--confirm-disk "$confirm_disk")
bash "$here/install-wizard.sh" "${args[@]}"
