#!/usr/bin/env bash
# help: unlock encrypted disks (LUKS) and encrypted ZFS pools after a boot, and start what waits for them
# help.de: entsperrt verschlüsselte Platten (LUKS) und ZFS-Pools nach einem Start und startet, was darauf wartet
# args: [--all | --status | --list | --setup-key | --remove-key | --passphrase-stdin | --alarm]
# With a vault (hs vault) the order is: the vault first, then every other encrypted disk and ZFS pool, then the
# services. The other disks take the key file kept inside the vault (hs unlock --setup-key) when there is one, else the passphrase typed.
# --list (hs sys encryption list): the encrypted volumes of THIS server as type TAB device TAB state TAB size, no header, plain, read only:
# type vault|luks|zfs; state open|locked|unmanaged (open under another name, e.g. the initrd's); size = bytes of the device (zfs: space used).
# LUKS disks that are not recorded in luks-uuids are other people's and are neither opened nor listed. Test knobs: HS_MAPPER_DIR, HS_SYS_BLOCK.
# At boot nothing is opened: a closed vault only writes the "storage is locked" marker and sends the push message.
set -euo pipefail
# --passphrase-stdin: the passphrase comes as the first line on standard input, plain output (no gum): for tools that unlock over SSH (homeserver-cli)
[ "${1:-}" != --passphrase-stdin ] || export HS_PLAIN=1
here=$(dirname "$0")
. "$here/lib/ui.sh"
. "$here/lib/crypt.sh"
. "$here/lib/dc.sh"
. "$here/lib/vault.sh"

usage() {
  say "usage: hs unlock                 ask for the passphrase, open every encrypted disk, start the services"
  say "       hs unlock --all           also open (and adopt) encrypted disks this server does not know yet"
  say "       hs unlock --status        what is encrypted and whether it is open"
  say "       hs unlock --list          the same for tools: type, device, state, size (tab separated)"
  say "       hs unlock --setup-key     keep the passphrase on this server's OS disk: unlocks at boot by itself"
  say "       hs unlock --remove-key    delete that file again: after a boot, hs unlock is needed"
  say "       hs unlock --passphrase-stdin   the passphrase is the first line on standard input (for tools)"
  exit 1
}

mode=unlock
open_all=false
case "${1:-}" in
  "") ;;
  --all) open_all=true ;;
  --boot|--status|--list|--setup-key|--remove-key|--alarm) mode=${1#--} ;;
  --passphrase-stdin) IFS= read -rs -p "Disk passphrase: " HS_DISK_PASSPHRASE || true; export HS_DISK_PASSPHRASE ;;
  *) usage ;;
esac

# What waits for the disks (written by configuration.nix)
start_units() {
  local u units
  units=$(cat "${HS_UNLOCK_UNITS:-/etc/hs/unlock-units}" 2>/dev/null || true)
  # the locked boot left these "failed" (Incus was held back): clear that, so nothing stays red
  systemctl reset-failed incus.socket incus-startup.service 2>/dev/null || true
  # Order matters: the domain controller is an instance (dc1) that starts with the others. winbind started before it answers made every user and
  # group lookup, `sudo` included, wait for an RPC timeout for the first minutes. So: everything except Samba, then the instances, then wait
  # for the domain controller, then Samba.
  for u in $units; do
    case "$u" in samba-*) continue ;; esac
    spin "$(t 'Start %s' "$u")" systemctl start "$u" || true
  done
  # containers set to start at boot: their start job ran while Incus was down
  case " $units " in *" incus.service "*) SPIN_SOFT=1 spin "Start the instances set to autostart" systemctl start incus-startup.service || true ;; esac
  case " $units " in *" samba-winbindd.service "*) SPIN_SOFT=1 spin "Wait for the domain controller" wait_dc || true ;; esac
  for u in $units; do
    case "$u" in samba-*) spin "$(t 'Start %s' "$u")" systemctl start "$u" || true ;; esac
  done
}

# Wait (one try a second, HS_DC_WAIT tries, 90 by default) until the domain controller answers on the SMB port. Nothing to wait for when it is
# not an instance of this server. HS_DC (else lib/dc.sh), HS_INCUS and HS_DC_PROBE (a command that gets the address, tests) as elsewhere.
wait_dc() {
  local dc inc=${HS_INCUS:-incus} ip i
  dc=$(dc_name)
  "$inc" info "$dc" >/dev/null 2>&1 || return 0
  for i in $(seq 1 "${HS_DC_WAIT:-90}"); do
    ip=$("$inc" list "$dc" -c 4 --format csv 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+){3}' | head -n1 || true)
    if [ -n "$ip" ]; then
      if [ -n "${HS_DC_PROBE:-}" ]; then $HS_DC_PROBE "$ip" && return 0
      elif timeout 2 bash -c "exec 3<>/dev/tcp/$ip/445" 2>/dev/null; then return 0; fi
    fi
    sleep "${HS_DC_SLEEP:-1}"
  done
  warn "$(t 'The domain controller %s did not answer in time.' "$dc")" >&2
  return 1
}

# The push message: the server is not usable until someone unlocks (not translated: push messages never are)
unlock_message=$'**The server restarted.** Backups, containers, shares and Samba stay stopped until the vault is unlocked.

Log in and run `hs unlock` (or `homeserver unlock` from your PC).'

# hs-unlock-alarm.service (after the network is up): the boot message above may have been sent before the network
# existed. While the "storage is locked" marker is there, send it again every HS_ALARM_WAIT seconds (15) until the push
# arrives, at most HS_ALARM_TRIES times (40, ten minutes); stop as soon as someone unlocks. The health check goes on
# reminding once a day.
cmd_alarm() {
  local i
  for i in $(seq 1 "${HS_ALARM_TRIES:-40}"); do
    [ -e "$crypt_locked" ] || exit 0
    HS_NOTIFY_STRICT=1 bash "$here/notify.sh" --category lock "$(hostname): unlock needed" "$unlock_message" urgent && exit 0
    sleep "${HS_ALARM_WAIT:-15}"
  done
  exit 0
}

cmd_boot() {
  mkdir -p "$crypt_run"
  # A vault that is closed: everything that needs a secret waits for hs unlock; nothing else is opened (the key file is inside the vault)
  if vault_configured && ! vault_is_open; then
    touch "$crypt_locked"
    warn "Encrypted storage is locked: waiting for hs unlock."
    bash "$here/notify.sh" --category lock "$(hostname): unlock needed" "$unlock_message" urgent || true
    exit 0
  fi
  # Nothing of ours is encrypted: nothing to do, and nothing may wait
  if ! vault_configured && [ ! -s "$crypt_uuids" ] && [ -z "$(zfs_locked)" ]; then rm -f "$crypt_locked"; exit 0; fi
  if [ -f "$crypt_keyfile" ] && crypt_get_pass; then crypt_unlock_all known; fi
  if crypt_is_locked; then
    touch "$crypt_locked"
    warn "Encrypted storage is locked: waiting for hs unlock."
    bash "$here/notify.sh" --category lock "$(hostname): unlock needed" "$unlock_message" urgent || true
  else
    rm -f "$crypt_locked"
  fi
  exit 0
}

cmd_status() {
  local d u state n=0 locked=0 rows="" r e k
  while read -r d; do
    u=$(cryptsetup luksUUID "$d" 2>/dev/null) || continue
    if crypt_is_vault "$d"; then
      # the vault has its own name (hs-vault) and is open when it is mounted
      if vault_is_open; then state=open; else state=LOCKED; locked=1; fi
      rows+="VAULT"$'\t'"$d"$'\t'"$state"$'\n'
      n=$((n + 1))
      continue
    fi
    if [ -e "/dev/mapper/$(luks_name "$d")" ]; then state=open; else state=LOCKED; fi
    # open under another name (the system disk, opened by the initrd as cryptroot): not ours to unlock, not locked
    if [ "$state" = LOCKED ] && luks_in_use "$d"; then state="open (in use, not managed by hs unlock)"
    else crypt_known_uuid "$u" || state="$state (not yet of this server)"; fi
    [ "$state" != LOCKED ] || locked=1
    rows+="LUKS"$'\t'"$d"$'\t'"$state"$'\n'
    n=$((n + 1))
  done < <(luks_devices)
  # encrypted ZFS pools: every encryption root with its key state (open = key loaded)
  if command -v zfs >/dev/null 2>&1; then
    while IFS=$'\t' read -r r e k; do
      [ -n "$r" ] && [ "$r" = "$e" ] || continue
      if [ "$k" = unavailable ]; then state=LOCKED; locked=1; else state=open; fi
      rows+="ZFS"$'\t'"$r"$'\t'"$state"$'\n'
      n=$((n + 1))
    done < <(zfs list -H -o name,encryptionroot,keystatus 2>/dev/null || true)
  fi
  if [ "$n" -eq 0 ]; then
    line "Nothing encrypted found."
  else
    if [ "$locked" = 1 ]; then status_line "Encrypted storage" "locked" bad; else status_line "Encrypted storage" "open" ok; fi
    { thead 'Type' 'Device' 'State'; printf '%s' "$rows"; } | table
  fi
  if vault_configured; then
    if [ -f "$crypt_keyfile" ]; then line "Key file: yes (in the vault, for the other disks)"
    elif [ -L "$crypt_keyfile" ]; then line "Key file: in the vault, which is closed (hs unlock)"
    else line "Key file: no (the other disks take the passphrase)"; fi
  elif [ -f "$crypt_keyfile" ]; then line "Key file: yes (unlocks at boot by itself)"; else line "Key file: no (after a boot: hs unlock)"; fi
  if [ -e "$crypt_locked" ]; then line "Services waiting: yes"; else line "Services waiting: no"; fi
  if [ "$locked" = 1 ] || [ -e "$crypt_locked" ]; then next_step "hs unlock"; fi
}

cmd_list() {
  local d u state sz type mp=${HS_MAPPER_DIR:-/dev/mapper} r e k used
  while read -r d; do
    u=$(cryptsetup luksUUID "$d" 2>/dev/null) || continue
    if crypt_is_vault "$d"; then
      type=vault
      if vault_is_open; then state=open; else state=locked; fi
    elif crypt_known_uuid "$u"; then
      type=luks
      if [ -e "$mp/$(luks_name "$d")" ]; then state=open; else state=locked; fi
      [ "$state" != locked ] || ! luks_in_use "$d" || state=unmanaged
    else
      continue
    fi
    sz=$(lsblk -bdn -o SIZE "$d" 2>/dev/null | tr -d ' ') || sz=""
    printf '%s	%s	%s	%s
' "$type" "$d" "$state" "${sz:--}"
  done < <(luks_devices)
  if command -v zfs >/dev/null 2>&1; then
    while IFS=$'	' read -r r e k used; do
      [ -n "$r" ] && [ "$r" = "$e" ] || continue
      if [ "$k" = unavailable ]; then state=locked; else state=open; fi
      printf 'zfs	%s	%s	%s
' "$r" "$state" "${used:--}"
    done < <(zfs list -H -p -o name,encryptionroot,keystatus,used 2>/dev/null || true)
  fi
}

cmd_setup_key() {
  local a
  step "Key file for the boot"
  if vault_configured && ! vault_is_open; then fail "$(vault_locked_note)"; fi
  if [ -f "$crypt_keyfile" ]; then confirm "A key file exists. Replace it?" || exit 0; fi
  crypt_pass=""
  a=$(ask_secret "Disk passphrase:")
  [ -n "$a" ] || fail "Empty passphrase."
  crypt_pass=$a
  crypt_verify || fail "That is not the passphrase of the encrypted disks."
  mkdir -p "$crypt_state"
  if vault_configured; then
    # the key file lives inside the vault: the plain system disk alone does not help anybody
    rm -f "$crypt_keyfile"
    ( umask 077; printf %s "$crypt_pass" > "$vault_dir/secrets/disk-key" )
    chmod 0400 "$vault_dir/secrets/disk-key"
    ln -sfn "$vault_dir/secrets/disk-key" "$crypt_keyfile"
    ok "$(t 'Saved in %s (inside the vault).' "$vault_dir/secrets/disk-key")"
    note "hs unlock opens the vault with the passphrase and the other disks with this file."
    return 0
  fi
  ( umask 077; printf %s "$crypt_pass" > "$crypt_keyfile" )
  chmod 0400 "$crypt_keyfile"
  ok "$(t 'Saved in %s (root only).' "$crypt_keyfile")"
  warn "Anyone who has this server's OS disk can now unlock the data disks. The data disks alone stay locked."
}

cmd_unlock() {
  step "Unlocking encrypted storage"
  local found
  found=$( { luks_devices; zfs_locked; } | wc -l)
  [ "$found" -gt 0 ] || { note "No encrypted disk or pool found."; exit 0; }
  crypt_get_pass || fail "No passphrase."
  if vault_configured; then
    # 1. the vault, with the passphrase typed
    if ! vault_is_open; then vault_open || fail "The vault did not open."; ok "Vault open."; fi
    # 2. the others: the key file inside the vault when there is one, else the same passphrase
    if [ -f "$vault_dir/secrets/disk-key" ]; then crypt_pass=$(cat "$vault_dir/secrets/disk-key"); fi
  fi
  # Only disks this server knows (luks-uuids, the vault) are opened and recorded. A server that knows none yet (first setup, a rebuilt
  # server without its state) or --all opens every disk the passphrase fits; a foreign or old system disk is never taken in by accident.
  local scope=known
  if $open_all || { [ ! -s "$crypt_uuids" ] && ! vault_configured; }; then scope=all; fi
  crypt_unlock_all "$scope"
  if [ -n "$crypt_unknown" ]; then note "$(t 'Not opened (this server does not know them; hs unlock --all opens them too): %s' "${crypt_unknown% }")"; fi
  if [ "$crypt_opened" -gt 0 ]; then ok "$(t '%s disk(s) opened' "$crypt_opened")"; fi
  if [ "$crypt_skipped" -gt 0 ]; then warn "$(t '%s encrypted disk(s) did not accept the passphrase (other keys are left alone)' "$crypt_skipped")"; fi
  if [ "$crypt_opened" -eq 0 ] && { [ "$crypt_skipped" -gt 0 ] || crypt_is_locked; }; then fail "The passphrase opens nothing."; fi
  udevadm settle 2>/dev/null || true
  crypt_is_locked && fail "$(t 'Still locked: %s' "$(crypt_locked_devices | tr '\n' ' ') $(zfs_locked | tr '\n' ' ')")"
  mkdir -p "$crypt_run"
  rm -f "$crypt_locked"
  start_units
  ok "Unlocked."
  # tell the owner (low priority: it also shows when somebody else unlocked); never makes the unlock fail
  bash "$here/notify.sh" --category ok "$(hostname): unlocked" "The vault and the encrypted disks are open, services are starting." low || true
}

cmd_remove_key() {
  step "Key file for the boot"
  if [ -L "$crypt_keyfile" ]; then
    # the file itself is inside the vault
    vault_is_open || fail "$(vault_locked_note)"
    rm -f "$(readlink "$crypt_keyfile")"
  fi
  rm -f "$crypt_keyfile"
  ok "Key file removed. After a boot, run hs unlock."
}

# test hook: only start the units (the order of start_units is what tests/unlock-order.sh checks)
[ -z "${HS_TEST_START_UNITS:-}" ] || { start_units; exit 0; }

case "$mode" in
  boot)       cmd_boot ;;
  alarm)      cmd_alarm ;;
  status)     cmd_status ;;
  list)       cmd_list ;;
  setup-key)  cmd_setup_key ;;
  remove-key) cmd_remove_key ;;
  unlock)     cmd_unlock ;;
esac
