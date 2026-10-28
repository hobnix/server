#!/usr/bin/env bash
# help: which secrets does this server keep (passwords, keys), are they readable by root only, which ones to store elsewhere
# help.de: welche Geheimnisse der Server aufbewahrt (Passwörter, Schlüssel), ob nur root sie lesen darf, welche man woanders sichern sollte
# args: [fix]
# Only looks at names, modes and owners; the contents are never printed. `fix` sets root-only modes.
# HS_STATE_DIR points tests at another state directory, HS_SSH_DIR and HS_SAMBA_PRIVATE at other places.
# With a vault a secret is a link into it: "in the vault" (open) or "in the vault (closed)"; `fix` never touches the vault content;
# a secret that belongs in the vault but is still a plain file is flagged "move it: hs vault move <name>". HS_VAULT_DIR, HS_VAULT_OPEN: tests.
set -uo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
. "$here/lib/secret.sh"
state=${HS_STATE_DIR:-/var/lib/hs}
ssh_dir=${HS_SSH_DIR:-/etc/ssh}
samba=${HS_SAMBA_PRIVATE:-/var/lib/samba/private}
fix=false
case "${1:-}" in "") ;; fix) fix=true ;; *) say "usage: hs secrets [fix]"; exit 1 ;; esac

# path|what it is|keep a copy elsewhere?|where it belongs: file = a file in the vault, bind = a folder bound from the vault, empty = stays on the system disk
items="$state/restic-password|password of the backup repository|YES: without it the backup cannot be opened|file
$state/backup-offsite.env|credentials of the off-site backup|yes (or be able to create new ones)|file
$state/disk-key|key file that unlocks the encrypted disks at boot|no: the passphrase is what matters (store THAT elsewhere)|file
$state/unifi|router address and API key|no: create a new API key|file
$state/notify-url|address of the push messages (stays outside the vault: the alarm 'storage is locked' needs it)|no|
$state/grafana-admin|admin password of Grafana|no: it can be reset|file
$state/vps-key|SSH key of the web interface for the proxyserver (vps update / watch)|no: hs vps key --new makes a new one|file
$state/zoraxy-admin|admin login of Zoraxy for hs services apply (name, then password)|no: hs services proxy login sets it again|file
$state/dc-ca-key|key of the CA that signs the domain controllers' certificates (hs dc cert)|no: hs dc cert ca makes a new CA, every controller then needs a new certificate|file
$samba|Samba domain database (private)|covered by the backup (hs backup)|bind"
for k in "$ssh_dir"/ssh_host_*_key; do [ -e "$k" ] && items+=$'\n'"$k|SSH host key|covered by the backup, otherwise clients see a new host key|"; done

# The vault: its secrets are links at the old paths. Mode and owner of what is inside the
# vault are never changed here (not even by `fix`); a secret still on the plain disk that belongs there is flagged.
vault_conf=false; vault_open=false
if vault_configured; then vault_conf=true; if vault_is_open; then vault_open=true; fi; fi
vault_dir=${HS_VAULT_DIR:-/var/lib/hs-vault}
bad=0
moves=0   # secrets that belong in the vault and are still on the plain disk
closed=0  # secrets that are in the closed vault
rows=""
while IFS='|' read -r path what keep where; do
  [ -n "$path" ] || continue
  name=$(basename "$path")
  if $vault_conf && [ "$where" = file ] && [ -L "$path" ]; then
    # a link into the vault: open = the file is there, closed = the link dangles (NOT "not set up")
    if [ -e "$path" ]; then
      rows+="$name"$'\t'"$(stat -L -c %a "$path")"$'\t'"$(stat -L -c %U "$path")"$'\t'"$(_tr 'in the vault')"$'\t'"$what; $keep"$'\n'
    else
      closed=$((closed + 1))
      rows+="$name"$'\t'"-"$'\t'"-"$'\t'"$(_tr 'in the vault (closed)')"$'\t'"$what; $keep"$'\n'
    fi
    continue
  fi
  if $vault_conf && [ "$where" = bind ]; then
    if $vault_open && mountpoint -q "$path" 2>/dev/null; then
      rows+="$name"$'\t'"-"$'\t'"-"$'\t'"$(_tr 'in the vault')"$'\t'"$what; $keep"$'\n'; continue
    fi
    if ! $vault_open && [ -d "$path" ] && [ -z "$(ls -A "$path" 2>/dev/null)" ]; then
      closed=$((closed + 1))
      rows+="$name"$'\t'"-"$'\t'"-"$'\t'"$(_tr 'in the vault (closed)')"$'\t'"$what; $keep"$'\n'; continue
    fi
  fi
  if [ ! -e "$path" ]; then rows+="$name"$'\t'"-"$'\t'"-"$'\t'"$(_tr 'not set up')"$'\t'"$what"$'\n'; continue; fi
  mode=$(stat -c %a "$path"); owner=$(stat -c %U "$path")
  # nobody but the owner may touch it: no group or world bits
  wrong=false
  [ "${mode: -2}" = 00 ] || wrong=true
  if [ "$owner" != root ] && [ -z "${HS_SECRETS_ANY_OWNER:-}" ]; then wrong=true; fi
  if $wrong; then
    state_=$(_tr 'WRONG'); bad=$((bad + 1))
    if $fix; then
      chown root:root "$path" 2>/dev/null
      if [ -d "$path" ]; then chmod 700 "$path"; else chmod 600 "$path"; fi
      state_=$(_tr 'fixed')
    fi
  else state_=ok; fi
  if $vault_conf && [ -n "$where" ] && [ "$state_" = ok ]; then
    mv_name=$name; [ "$where" != bind ] || mv_name=samba-private
    state_="$(t 'move it: hs vault move %s' "$mv_name")"; moves=$((moves + 1))
  fi
  rows+="$(basename "$path")"$'\t'"$mode"$'\t'"$owner"$'\t'"$state_"$'\t'"$what; $keep"$'\n'
done <<<"$items"
if [ "$bad" -eq 0 ]; then status_line "Secrets" "Readable by root only" ok
elif $fix; then status_line "Secrets" "$(t '%s fixed' "$bad")" ok
else status_line "Secrets" "$(t '%s readable by more than root' "$bad")" bad; fi
if $vault_conf; then
  if [ "$moves" -gt 0 ]; then status_line "Vault" "$(t '%s secret(s) still outside the vault' "$moves")" warn
  elif $vault_open; then status_line "Vault" "open" ok
  else status_line "Vault" "closed" warn; fi
fi
{ thead 'Secret' 'Mode' 'Owner' 'State' 'What it is / keep a copy?'; printf '%s' "$rows"; } | table
if [ "$bad" -gt 0 ] && ! $fix; then fail_fix "Some secrets can be read by more than root." "hs secrets fix"; fi
note "Store elsewhere (not on this server): the restic password and the disk passphrase."
