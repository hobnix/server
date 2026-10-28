# shellcheck shell=bash
# The vault: a small encrypted partition on the system disk that holds the server's secrets.
# Sourced, not run:   . "$(dirname "$0")/lib/vault.sh"
#
#   /var/lib/hs/vault-uuid        LUKS uuid of the vault partition (not secret, stays on the plain disk) -> "this server has a vault"
#   /var/lib/hs/vault-binds       one line per bind item: <name> TAB <original directory> (names and paths only)
#   /var/lib/hs-vault             mount point while the vault is open [HS_VAULT_DIR], mode 0700
#   <mount>/secrets/<name>        a secret; /var/lib/hs/<name> is a symlink to it (scripts keep reading the old path)
#   <mount>/bind/<name>           a folder that is bind-mounted over its original directory while the vault is open
#   /dev/mapper/hs-vault          the opened device (fixed name, not the hs-<uuid> of data disks)
#
# Nothing here ever prints the content of a secret. Functions return 0 on success, 1 on failure; the messages go to stderr.

. "$(dirname "${BASH_SOURCE[0]}")/ui.sh"
. "$(dirname "${BASH_SOURCE[0]}")/crypt.sh"

vault_dir=${HS_VAULT_DIR:-/var/lib/hs-vault}
vault_uuid_file=$crypt_state/vault-uuid
vault_binds_file=$crypt_state/vault-binds
vault_mapper=hs-vault
vault_label=hs-vault
# the secrets of the contract (hs vault move without names moves those that exist)
vault_default_secrets="restic-password backup-offsite.env disk-key unifi grafana-admin vps-key zoraxy-admin"
# the optional bind item that comes last: the Samba member secrets
vault_samba_name=samba-private
vault_samba_dir=${HS_SAMBA_PRIVATE:-/var/lib/samba/private}
vault_header_file=$crypt_state/vault-header

vault_configured() { [ -s "$vault_uuid_file" ]; }

vault_is_open() {   # the mount point is a mount point of the mapper hs-vault (test knob: HS_VAULT_OPEN=1 = open)
  local src
  [ -z "${HS_VAULT_OPEN:-}" ] || return 0
  mountpoint -q "$vault_dir" 2>/dev/null || return 1
  [ -e "/dev/mapper/$vault_mapper" ] || return 1
  src=$(findmnt -n -o SOURCE -M "$vault_dir" 2>/dev/null | head -n1) || true
  [ -n "$src" ] && [ "$(readlink -f "$src")" = "$(readlink -f "/dev/mapper/$vault_mapper")" ]
}

vault_dev() {   # the device whose LUKS uuid is in vault-uuid; empty when missing
  local u
  u=$(crypt_vault_uuid)
  [ -n "$u" ] || return 0
  luks_dev_of "$u" || true
}

vault_locked_note() { printf '%s\n' "$(t 'The vault is closed: run hs unlock')"; }

vault_secret() {   # vault_secret <name>: prints /var/lib/hs/<name>; 1 = the link dangles because the vault is closed, 2 = no such secret
  local p=$crypt_state/$1
  printf '%s\n' "$p"
  [ -e "$p" ] && return 0
  if [ -L "$p" ] && ! vault_is_open; then vault_locked_note >&2; return 1; fi
  return 2
}

# ── bind items ──
vault_bind_mounts() {   # mount every bind item over its original directory (the vault is open)
  local n p
  [ -f "$vault_binds_file" ] || return 0
  while IFS=$'\t' read -r n p; do
    [ -n "$n" ] && [ -d "$vault_dir/bind/$n" ] && [ -d "$p" ] || continue
    mountpoint -q "$p" 2>/dev/null || mount --bind "$vault_dir/bind/$n" "$p" || return 1
  done < "$vault_binds_file"
}
vault_bind_unmounts() {   # unmount them again, last first
  local n p rc=0
  [ -f "$vault_binds_file" ] || return 0
  while IFS=$'\t' read -r n p; do
    [ -n "$n" ] || continue
    if mountpoint -q "$p" 2>/dev/null; then umount "$p" || rc=1; fi
  done < <(tac "$vault_binds_file")
  return $rc
}

# ── open and close ──
vault_open() {   # needs the passphrase (crypt_get_pass); nothing to do when it is open
  local dev
  vault_is_open && return 0
  vault_configured || { warn "No vault is set up (hs vault init)." >&2; return 1; }
  dev=$(vault_dev)
  [ -n "$dev" ] || { warn "The vault partition is not here." >&2; return 1; }
  crypt_get_pass || return 1
  if [ ! -e "/dev/mapper/$vault_mapper" ]; then
    printf %s "$crypt_pass" | cryptsetup open --key-file - "$dev" "$vault_mapper" 2>/dev/null || { warn "That passphrase does not open the vault." >&2; return 1; }
  fi
  mkdir -p "$vault_dir"; chmod 700 "$vault_dir"
  mountpoint -q "$vault_dir" 2>/dev/null || mount -o nodev,nosuid "/dev/mapper/$vault_mapper" "$vault_dir" || return 1
  vault_bind_mounts || { warn "A folder of the vault could not be mounted." >&2; return 1; }
  return 0
}

vault_services_running() {   # the Samba daemons that read the bind-mounted private folder
  local u
  command -v systemctl >/dev/null 2>&1 || return 1
  for u in samba-smbd samba-winbindd smbd winbindd; do
    systemctl is-active --quiet "$u.service" 2>/dev/null && return 0
  done
  return 1
}
vault_samba_bound() { grep -q "^$vault_samba_name	" "$vault_binds_file" 2>/dev/null; }

vault_busy() { command -v fuser >/dev/null 2>&1 && vault_is_open && fuser -m "$vault_dir" >/dev/null 2>&1; }
vault_busy_list() { fuser -vm "$vault_dir" 2>&1 || true; }

vault_close() {   # refuses (1) while something uses it
  if vault_is_open; then
    if vault_samba_bound && vault_services_running; then warn "Samba is running and uses the vault: stop it first." >&2; return 1; fi
    if vault_busy; then warn "The vault is in use." >&2; return 1; fi
    vault_bind_unmounts || { warn "A folder of the vault is still in use." >&2; return 1; }
    umount "$vault_dir" || { warn "The vault is still in use." >&2; return 1; }
  fi
  if [ -e "/dev/mapper/$vault_mapper" ]; then cryptsetup close "$vault_mapper" || return 1; fi
  return 0
}

# ── making the vault ──
vault_create() {   # vault_create <partition>: ERASES it, leaves the vault open. Passphrase: crypt_new_pass.
  local dev=$1 u
  crypt_new_pass || return 1
  printf %s "$crypt_pass" | cryptsetup luksFormat --batch-mode --type luks2 --label "$vault_label" --key-file - "$dev" >/dev/null 2>&1 || return 1
  u=$(cryptsetup luksUUID "$dev") || return 1
  printf %s "$crypt_pass" | cryptsetup open --key-file - "$dev" "$vault_mapper" >/dev/null 2>&1 || return 1
  if ! mkfs.ext4 -q -F -m 0 -L "$vault_label" "/dev/mapper/$vault_mapper" >/dev/null 2>&1; then cryptsetup close "$vault_mapper" 2>/dev/null; return 1; fi
  mkdir -p "$vault_dir"; chmod 700 "$vault_dir"
  mount -o nodev,nosuid "/dev/mapper/$vault_mapper" "$vault_dir" || return 1
  mkdir -p "$vault_dir/secrets" "$vault_dir/bind"
  chmod 700 "$vault_dir/secrets" "$vault_dir/bind"
  mkdir -p "$crypt_state"
  printf '%s\n' "$u" > "$vault_uuid_file"
  chmod 644 "$vault_uuid_file"
}

vault_header_backup() {   # the LUKS header OUTSIDE the vault (plain disk, 600): without a header the vault is lost
  local dev
  dev=$(vault_dev)
  [ -n "$dev" ] || { warn "The vault partition is not here." >&2; return 1; }
  mkdir -p "$crypt_state"
  rm -f "$vault_header_file.new"
  ( umask 077; cryptsetup luksHeaderBackup "$dev" --header-backup-file "$vault_header_file.new" >/dev/null 2>&1 ) || { rm -f "$vault_header_file.new"; return 1; }
  chmod 600 "$vault_header_file.new"
  mv -f "$vault_header_file.new" "$vault_header_file"
}
vault_header_age_days() {   # days since the header backup was made; empty when there is none
  [ -s "$vault_header_file" ] || return 0
  echo $(( ( $(date +%s) - $(stat -c %Y "$vault_header_file") ) / 86400 ))
}

# ── moving things in ──
vault_move_secret() {   # vault_move_secret <name>: 0 moved, 3 was in the vault already, 2 nothing to move, 1 error (closed, directory, bad name)
  local name=$1 src dst tmp mode
  src=$crypt_state/$name; dst=$vault_dir/secrets/$name
  case "$name" in ""|.*|*/*) warn "$(t 'Not a secret name: %s' "$name")" >&2; return 1 ;; esac
  if ! vault_is_open; then vault_locked_note >&2; return 1; fi
  if [ -L "$src" ] && [ "$(readlink "$src")" = "$dst" ] && [ -e "$dst" ]; then return 3; fi
  if [ -d "$src" ] && [ ! -L "$src" ]; then warn "$(t '%s is a folder: use hs vault bind' "$name")" >&2; return 1; fi
  if [ ! -e "$src" ] && [ ! -L "$src" ]; then
    # only the file is in the vault (the link was lost): put the link back
    if [ -e "$dst" ]; then ln -sfn "$dst" "$src"; return 3; fi
    return 2
  fi
  [ ! -L "$src" ] || { warn "$(t '%s is a link to somewhere else' "$name")" >&2; return 1; }
  tmp=$dst.tmp.$$
  ( umask 077; cp -p -- "$src" "$tmp" ) || { rm -f "$tmp"; return 1; }
  if ! cmp -s -- "$src" "$tmp"; then rm -f "$tmp"; warn "$(t 'The copy of %s differs from the original: nothing was changed' "$name")" >&2; return 1; fi
  # keep the mode when nobody but the owner could touch it (400 stays 400), else 600
  mode=$(stat -c %a "$tmp")
  [ "${mode: -2}" = 00 ] || chmod 600 "$tmp"
  chown root:root "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$dst"
  # overwrite the old content on the plain disk, then replace the file by the link in one step
  shred -n 1 -- "$src" 2>/dev/null || true
  ln -sfn "$dst" "$src.link.$$" && mv -T -f -- "$src.link.$$" "$src"
}

# A signature of a folder to compare a copy with its original: path, type, mode, owner and link target of every folder, file and link,
# plus the checksum of every regular file. Sockets, pipes and devices are runtime state (Samba's msg.sock holds hundreds of stale
# sockets) and are left out on both sides: `diff -r` cannot compare them, which is why a plain diff refused a good copy.
vault_tree_sig() {
  ( cd "$1" && {
      find . \( -type f -o -type d -o -type l \) -printf '%p %y %m %U %G %l\n' | LC_ALL=C sort
      find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum
    } )
}

vault_bind_add() {   # vault_bind_add <name> <directory>: the folder's content moves into the vault, the vault is mounted over the folder
  local name=$1 dir=${2%/} dst
  case "$name" in ""|.*|*/*) warn "$(t 'Not a secret name: %s' "$name")" >&2; return 1 ;; esac
  case "$dir" in /?*/*|/?*) ;; *) warn "$(t 'Not a folder to move: %s' "$2")" >&2; return 1 ;; esac
  if ! vault_is_open; then vault_locked_note >&2; return 1; fi
  dst=$vault_dir/bind/$name
  if grep -q "^$name	" "$vault_binds_file" 2>/dev/null; then
    [ "$(awk -F'\t' -v n="$name" '$1 == n { print $2 }' "$vault_binds_file")" = "$dir" ] || { warn "$(t '%s is a bind item of another folder' "$name")" >&2; return 1; }
    mountpoint -q "$dir" 2>/dev/null || mount --bind "$dst" "$dir" || return 1
    return 3
  fi
  [ -d "$dir" ] || { warn "$(t 'No such folder: %s' "$dir")" >&2; return 1; }
  mountpoint -q "$dir" 2>/dev/null && { warn "$(t '%s is a mount point already' "$dir")" >&2; return 1; }
  if [ "$name" = "$vault_samba_name" ] && vault_services_running; then warn "Samba is running and uses the folder: stop it first." >&2; return 1; fi
  mkdir -p "$dst"; chmod 700 "$dst"
  ( cd "$dir" && tar --numeric-owner -cpf - . 2>/dev/null ) | tar --numeric-owner -C "$dst" -xpf - 2>/dev/null
  if [ -z "$(vault_tree_sig "$dir")" ] && [ -n "$(find "$dir" -mindepth 1 \( -type f -o -type d -o -type l \) -print -quit)" ]; then rm -rf "$dst"; warn "$(t 'The copy of %s could not be checked: nothing was changed' "$dir")" >&2; return 1; fi
  if [ "$(vault_tree_sig "$dir")" != "$(vault_tree_sig "$dst")" ]; then rm -rf "$dst"; warn "$(t 'The copy of %s differs from the original: nothing was changed' "$dir")" >&2; return 1; fi
  # the bind mount must work BEFORE anything of the original is removed
  if ! mount --bind "$dst" "$dir" 2>/dev/null; then rm -rf "$dst"; warn "$(t 'The vault could not be mounted over %s: nothing was changed' "$dir")" >&2; return 1; fi
  umount "$dir" || { rm -rf "$dst"; return 1; }
  mkdir -p "$crypt_state"
  printf '%s\t%s\n' "$name" "$dir" >> "$vault_binds_file"
  find "$dir" -mindepth 1 -delete
  if ! mount --bind "$dst" "$dir"; then
    # put the files back and forget the item
    cp -a -- "$dst/." "$dir/" || true
    grep -v "^$name	" "$vault_binds_file" > "$vault_binds_file.new" || true
    mv -f "$vault_binds_file.new" "$vault_binds_file"
    return 1
  fi
}

# ── what is in the vault ──
# i18n: secret|folder|in vault|not moved|not mounted
vault_items() {   # tab separated: name, kind (secret|folder), state (in vault|closed|not moved|not mounted|-)
  local n p t names seen=" "
  names="$vault_default_secrets"
  for p in "$crypt_state"/*; do
    [ -L "$p" ] || continue
    t=$(readlink "$p")
    case "$t" in "$vault_dir"/secrets/*) names+=" $(basename "$p")" ;; esac
  done
  for n in $names; do
    case "$seen" in *" $n "*) continue ;; esac
    seen+="$n "
    p=$crypt_state/$n
    if [ -L "$p" ]; then
      if [ -e "$p" ]; then printf '%s\t%s\t%s\n' "$n" secret "in vault"; else printf '%s\t%s\t%s\n' "$n" secret closed; fi
    elif [ -e "$p" ]; then printf '%s\t%s\t%s\n' "$n" secret "not moved"
    else printf '%s\t%s\t%s\n' "$n" secret "-"; fi
  done
  if [ -f "$vault_binds_file" ]; then
    while IFS=$'\t' read -r n p; do
      [ -n "$n" ] || continue
      if mountpoint -q "$p" 2>/dev/null; then printf '%s\t%s\t%s\n' "$n ($p)" folder "in vault"
      elif vault_is_open; then printf '%s\t%s\t%s\n' "$n ($p)" folder "not mounted"
      else printf '%s\t%s\t%s\n' "$n ($p)" folder closed; fi
    done < "$vault_binds_file"
  fi
}
