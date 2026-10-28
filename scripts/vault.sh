#!/usr/bin/env bash
# help: the vault: a small encrypted partition on the system disk that holds the server's secrets (status, init, open, close, move, bind, list)
# help.de: der Tresor: eine kleine verschlüsselte Partition auf der System-SSD mit den Geheimnissen des Servers (status, init, open, close, move, bind, list)
# args: status | list | usage | uses | init [<partition>] [--dry-run] [--yes] [--wipe] | open | close [--yes] | move [<name>...] | bind <name> <folder> [--yes] | header-backup
# The vault is opened with the passphrase of the encrypted disks (hs unlock opens it first, then the rest). init makes a new
# one on a free PARTITION (never a whole disk; a mounted partition or one with a signature is refused, --wipe allows the
# signature) and shows a plan first; it asks for the name of the disk the partition is on. move copies secrets into the
# vault (default: restic-password, backup-offsite.env, disk-key, unifi, grafana-admin, vps-key, zoraxy-admin, those that exist), checks the copy, overwrites
# the old file and leaves a link at the old path /var/lib/hs/<name>, so every script keeps working; it runs again without harm.
# bind puts a whole folder in the vault (its content moves, the vault is mounted over the folder while it is open), for
# example hs vault bind <name> <folder>. The Samba member secrets are such a folder: hs vault move samba-private (the last item
# of the default list, only when Samba is stopped) copies /var/lib/samba/private into the vault and mounts the vault over it
# while it is open; nothing of the original is removed before that mount has worked.
# header-backup writes the LUKS header to /var/lib/hs/vault-header (plain disk, mode 600, part of the host backup; init does it
# too): without the header a damaged partition could not be opened any more. Run it again after a passphrase change.
# While the vault is closed the links dangle: commands that need a secret say "The vault is closed: run hs unlock".
# usage and uses (hs sys vault usage|uses, for the web interface; plain, never a secret's content): usage = key TAB value lines (state none|open|closed,
# device, size and used in bytes of the partition's file system while it is open, else the partition size, free, header-backup-days; a key
# whose value is not known is left out); uses = name TAB who uses it, one row per vault item (name without the folder), text in English.
# HS_VAULT_DIR is the mount point (/var/lib/hs-vault), HS_STATE_DIR the state directory (vault-uuid, vault-binds, vault-header),
# HS_SAMBA_PRIVATE the Samba folder, HS_VAULT_OPEN=1 makes vault_is_open true (tests).
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
. "$here/lib/vault.sh"

usage() {
  say "usage: hs vault status            is the vault open, what is in it"
  say "       hs vault list              the same list for scripts (tab separated when piped)"
  say "       hs vault init <partition>  make the vault on a free partition of the system disk (erases it)"
  say "       hs vault open              open it (asks for the passphrase)"
  say "       hs vault close             close it (refused while something uses it)"
  say "       hs vault move [<name>...]  move secrets into the vault"
  say "       hs vault bind <name> <folder>   move a whole folder into the vault"
  say "       hs vault header-backup     save the LUKS header outside the vault"
  exit 1
}
interactive() { [ -t 0 ] && [ -t 1 ] && [ -z "${HS_CALLER:-}" ] || [ -n "${HS_GUIDED_TTY:-}" ]; }
need_vault() { vault_configured || fail_fix "No vault is set up." "hs vault init <partition>"; }
ask_yes() {   # ask_yes <yes flag> <question>
  [ "$1" = true ] && return 0
  interactive || fail "Nothing is changed without --yes when there is no terminal."
  confirm "$2" || fail "cancelled"
}

rows_for_people() {   # the items as table rows (translated words)
  local n k s
  while IFS=$'\t' read -r n k s; do
    printf '%s\t%s\t%s\n' "$n" "$(_tr "$k")" "$(_tr "$s")"
  done < <(vault_items)
}

cmd_status() {
  if ! vault_configured; then
    status_line "Vault" "not set up" warn
    line "Make it on a free partition of the system disk."
    next_step "hs vault init <partition>"
    return 0
  fi
  local dev; dev=$(vault_dev)
  if vault_is_open; then status_line "Vault" "open" ok
  elif [ -z "$dev" ]; then status_line "Vault" "partition not found" bad
  else status_line "Vault" "closed" warn; fi
  [ -z "$dev" ] || kv "Partition" "$dev"
  kv "Mounted at" "$vault_dir"
  local age; age=$(vault_header_age_days)
  if [ -n "$age" ]; then kv "Header backup" "$(t '%s days old (%s)' "$age" "$vault_header_file")"; else kv "Header backup" "$(_tr 'none: run hs vault header-backup')"; fi
  { thead 'Name' 'Kind' 'State'; rows_for_people; } | table
  vault_is_open || next_step "hs unlock"
}

cmd_list() {
  if [ -t 1 ] && [ -z "${HS_CALLER:-}" ] && [ -z "${HS_PLAIN:-}" ]; then
    { thead 'Name' 'Kind' 'State'; rows_for_people; } | table
  else vault_items; fi
}

# who uses what: a fixed table (the same facts as scripts/secrets.sh); a name the table does not know gets "-"
vault_used_by() {   # vault_used_by <item name>
  case "$1" in
    restic-password)     echo "the backup: every nightly and manual restic run (hs backup)" ;;
    backup-offsite.env)  echo "the off-site copy of the backup" ;;
    disk-key)            echo "hs unlock: opens the other encrypted disks without typing the passphrase" ;;
    unifi)               echo "the router commands: fixed addresses, reservations (hs unifi, hs ct ip)" ;;
    grafana-admin)       echo "the Grafana admin login (monitoring)" ;;
    vps-key)             echo "the web interface's key for vps update / vps watch on the proxyserver (hs vps key)" ;;
    zoraxy-admin)        echo "the Zoraxy admin login: hs services apply makes routes through its API (hs services proxy login)" ;;
    dc-ca-key)           echo "the CA that signs the domain controllers' certificates (hs dc cert)" ;;
    "$vault_samba_name") echo "Samba: the domain member secrets (folder $vault_samba_dir)" ;;
    *)                   echo "-" ;;
  esac
}
cmd_uses() {
  local n k s name
  while IFS=$'	' read -r n k s; do
    name=${n%% (*}
    printf '%s	%s
' "$name" "$(vault_used_by "$name")"
  done < <(vault_items)
}
cmd_usage() {
  local dev state hb sz used free
  if ! vault_configured; then printf 'state	none
'; return 0; fi
  if vault_is_open; then state=open; else state=closed; fi
  printf 'state	%s
' "$state"
  dev=$(vault_dev)
  [ -z "$dev" ] || printf 'device	%s
' "$dev"
  if [ "$state" = open ]; then
    # size, used, free of the file system inside (bytes)
    read -r sz used free < <(df -B1 --output=size,used,avail "$vault_dir" 2>/dev/null | awk 'NR == 2 { print $1, $2, $3 }') || true
    [ -z "${sz:-}" ] || printf 'size	%s
used	%s
free	%s
' "$sz" "$used" "$free"
  elif [ -n "$dev" ]; then
    sz=$(lsblk -bdn -o SIZE "$dev" 2>/dev/null | tr -d ' ') || true
    [ -z "$sz" ] || printf 'size	%s
' "$sz"
  fi
  hb=$(vault_header_age_days)
  [ -z "$hb" ] || printf 'header-backup-days	%s
' "$hb"
}

# ── init ──
candidates() {   # free partitions: no signature, not mounted, not in use
  local p t sz
  while read -r p t; do
    [ "$t" = part ] || continue
    [ -z "$(blkid -p -o value -s TYPE "$p" 2>/dev/null || true)" ] || continue
    [ -z "$(findmnt -rn -S "$p" 2>/dev/null || true)" ] || continue
    luks_in_use "$p" && continue
    sz=$(lsblk -dn -o SIZE "$p" 2>/dev/null | tr -d ' ')
    printf '%s  %s\n' "$p" "$sz"
  done < <(lsblk -nr -o PATH,TYPE)
}

cmd_init() {
  local dev="" dry=false yes=false wipe=false sig type pk partn disk size pick
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry=true ;; --yes) yes=true ;; --wipe) wipe=true ;;
      -*) usage ;;
      *) dev=$1 ;;
    esac
    shift
  done
  if [ -z "$dev" ]; then
    interactive || fail "$(t 'Missing: %s (give it as an option)' 'the partition')"
    mapfile -t cand < <(candidates)
    [ ${#cand[@]} -gt 0 ] || fail "No free partition found. Make one of about 1 GiB on the system disk first."
    pick=$(choose "Partition for the vault" "${cand[@]}") || fail "cancelled"
    dev=${pick%% *}
  fi
  [ -b "$dev" ] || fail "$(t 'Not a block device: %s' "$dev")"
  if vault_configured && [ "$wipe" != true ]; then
    fail "A vault is set up already. A new one would lose the secrets in it; run with --wipe if that is what you want."
  fi
  dev=$(readlink -f "$dev")
  type=$(lsblk -dn -o TYPE "$dev" 2>/dev/null | tr -d ' ')
  case "$type" in part|loop) ;; *) fail "$(t '%s is a whole disk or something else, not a partition. Give a partition, for example /dev/sda4.' "$dev")" ;; esac
  if [ -n "$(findmnt -rn -S "$dev" 2>/dev/null || true)" ] || [ -n "$(lsblk -n -o MOUNTPOINTS "$dev" 2>/dev/null | tr -d ' \n')" ]; then
    fail "$(t '%s is mounted. The vault needs an unused partition.' "$dev")"
  fi
  luks_in_use "$dev" && fail "$(t '%s is in use.' "$dev")"
  sig=$(blkid -p -o value -s TYPE "$dev" 2>/dev/null || true)
  if [ -n "$sig" ] && [ "$wipe" != true ]; then
    fail "$(t '%s already holds a %s signature. If it is really free, run again with --wipe.' "$dev" "$sig")"
  fi
  if [ -e "/dev/mapper/$vault_mapper" ]; then fail "The vault is open: close it first (hs vault close)."; fi
  pk=$(lsblk -dn -o PKNAME "$dev" 2>/dev/null | tr -d ' ')
  partn=$(lsblk -dn -o PARTN "$dev" 2>/dev/null | tr -d ' ')
  disk=${pk:-$(basename "$dev")}
  size=$(lsblk -dn -o SIZE "$dev" 2>/dev/null | tr -d ' ')

  step "Create the vault"
  kv "Partition" "$dev ($size)"
  kv "Disk" "$disk"
  kv "Encryption" "LUKS2, label $vault_label"
  kv "File system" "ext4, label $vault_label"
  kv "Mounted at" "$vault_dir"
  note "Only this partition is touched; the other partitions of the disk stay as they are."
  note "The passphrase is the one of the other encrypted disks (asked once if this is the first)."
  [ -z "$sig" ] || warn "$(t 'The signature %s on it is overwritten.' "$sig")"
  danger "$(t 'ALL DATA on %s will be erased' "$dev")"
  if [ "$dry" = true ]; then ok "Dry run: nothing was changed."; return 0; fi
  if [ "$yes" != true ]; then
    interactive || fail "Nothing is changed without --yes when there is no terminal."
    confirm_name "$disk" "the disk" || fail "cancelled"
  fi
  [ "$wipe" != true ] || wipefs -a "$dev" >/dev/null 2>&1 || true
  if [ -n "$pk" ] && [ -n "$partn" ] && command -v sfdisk >/dev/null 2>&1; then
    sfdisk --part-label "/dev/$pk" "$partn" "$vault_label" >/dev/null 2>&1 || note "The partition label could not be set (not important)."
  fi
  vault_create "$dev" || fail "The vault could not be made (the passphrase, or the disk)."
  ok "$(t 'Vault made on %s and open at %s' "$dev" "$vault_dir")"
  if vault_header_backup; then ok "$(t 'LUKS header saved in %s' "$vault_header_file")"; else warn "The LUKS header could not be saved: run hs vault header-backup"; fi
  next_step "hs vault move"
}

# ── open and close ──
cmd_open() {
  need_vault
  if vault_is_open; then ok "The vault is open already."; return 0; fi
  crypt_get_pass || fail "No passphrase."
  vault_open || fail "The vault did not open."
  ok "Vault open."
}

cmd_close() {
  local yes=false a
  for a in "$@"; do case "$a" in --yes) yes=true ;; *) usage ;; esac; done
  need_vault
  if ! vault_is_open && [ ! -e "/dev/mapper/$vault_mapper" ]; then note "The vault is closed already."; return 0; fi
  if vault_busy; then
    warn "The vault is in use:"
    vault_busy_list | trail
    fail "Stop what uses it first, then try again."
  fi
  ask_yes "$yes" "Close the vault? Everything that needs its secrets waits until hs unlock."
  vault_close || fail "The vault could not be closed."
  ok "Vault closed."
}

# ── move and bind ──
cmd_move() {
  local names=() n rc moved=0 explicit=false
  need_vault
  vault_is_open || fail "$(vault_locked_note)"
  if [ $# -gt 0 ]; then names=("$@"); explicit=true; else for n in $vault_default_secrets; do names+=("$n"); done; fi
  # the Samba folder is the optional last item of the default list
  if [ "$explicit" = false ] && { [ -d "$vault_samba_dir" ] || vault_samba_bound; }; then names+=("$vault_samba_name"); fi
  step "Move secrets into the vault"
  for n in "${names[@]}"; do
    rc=0
    if [ "$n" = "$vault_samba_name" ]; then
      if [ "$explicit" = false ] && ! vault_samba_bound && vault_services_running; then
        note "Samba is running: stop it and run hs vault move samba-private (left out for now)"; continue
      fi
      vault_bind_add "$n" "$vault_samba_dir" || rc=$?
    else
      vault_move_secret "$n" || rc=$?
    fi
    case $rc in
      0) ok "$(t 'Moved %s' "$n")"; moved=$((moved + 1)) ;;
      3) note "$(t '%s is in the vault already' "$n")" ;;
      2) if [ "$explicit" = true ]; then note "$(t '%s does not exist: nothing to move' "$n")"; fi ;;
      *) fail "$(t 'Could not move %s' "$n")" ;;
    esac
  done
  if [ "$moved" -eq 0 ]; then note "Nothing new to move."; fi
}

cmd_header_backup() {
  need_vault
  vault_header_backup || fail "The LUKS header could not be saved."
  ok "$(t 'LUKS header saved in %s' "$vault_header_file")"
  note "It is part of the host backup. Keep a copy elsewhere too: with the header and the passphrase the vault opens even when the partition is damaged."
}

cmd_bind() {
  local yes=false pos=() a rc=0
  for a in "$@"; do case "$a" in --yes) yes=true ;; -*) usage ;; *) pos+=("$a") ;; esac; done
  [ ${#pos[@]} -eq 2 ] || usage
  need_vault
  vault_is_open || fail "$(vault_locked_note)"
  warn "$(t 'Stop what uses %s first. Its content moves into the vault.' "${pos[1]}")"
  ask_yes "$yes" "Move the folder into the vault?"
  vault_bind_add "${pos[0]}" "${pos[1]}" || rc=$?
  case $rc in
    0) ok "$(t 'Folder %s is in the vault now' "${pos[1]}")" ;;
    3) note "$(t '%s is in the vault already' "${pos[0]}")" ;;
    *) fail "$(t 'Could not move %s' "${pos[1]}")" ;;
  esac
}

cmd=${1:-status}
[ $# -eq 0 ] || shift
case "$cmd" in
  status) cmd_status ;;
  list)   cmd_list ;;
  usage)  cmd_usage ;;
  uses)   cmd_uses ;;
  init)   cmd_init "$@" ;;
  open)   cmd_open ;;
  close)  cmd_close "$@" ;;
  move)   cmd_move "$@" ;;
  bind)   cmd_bind "$@" ;;
  header-backup) cmd_header_backup ;;
  *)      usage ;;
esac
