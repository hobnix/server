#!/usr/bin/env bash
# help: bring back files of a share from the backup (into the share "restored", the original is not touched)
# help.de: Dateien einer Freigabe aus dem Backup zurückholen (in die Freigabe "restored", das Original bleibt unberührt)
# args: <share> [<folder or file inside the share>] [--snapshot <id|latest>] [--yes]
# Guided front for `hs backup restore`: builds the full original path, asks which snapshot, makes sure the
# target share exists and confirms. HS_BACKUP, HS_CREATE_SHARE and HS_BULK point tests at stand-ins.
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
backup=${HS_BACKUP:-$here/backup.sh}
create=${HS_CREATE_SHARE:-$here/create-share.sh}
bulk=${HS_BULK:-/bulk}

usage() {
  say "usage: hs share <share> restore [<folder or file inside the share>] [--snapshot <id|latest>] [--yes]"
  say "  The files land in the share 'restored' (created if needed), below their full original path."
  exit 1
}
interactive() { [ -t 0 ] && [ -t 1 ] && [ -z "${HS_CALLER:-}" ] || [ -n "${HS_GUIDED_TTY:-}" ]; }

share=""; sub=""; snap=""; yes=false
while [ $# -gt 0 ]; do
  case "$1" in
    --snapshot) [ $# -ge 2 ] || usage; snap=$2; shift 2 ;;
    --yes) yes=true; shift ;;
    -*) usage ;;
    *) if [ -z "$share" ]; then share=$1; elif [ -z "$sub" ]; then sub=$1; else usage; fi; shift ;;
  esac
done
[ -n "$share" ] || usage

# where the share lives: the folder under shares or sensitive (it may be gone: that is why we restore)
kind=shares
[ -d "$bulk/sensitive/$share" ] && [ ! -d "$bulk/shares/$share" ] && kind=sensitive
path="$bulk/$kind/$share"
if [ -z "$sub" ] && interactive && ! $yes; then
  sub=$(ask "Folder or file inside the share (empty = the whole share):" "")
fi
[ -z "$sub" ] || path="$path/${sub#/}"
if [ -z "$snap" ]; then
  if interactive && ! $yes; then snap=$(ask "Which snapshot? (latest, or an id from: hs backup list)" "latest"); else snap=latest; fi
fi
[[ "$snap" =~ ^[A-Za-z0-9]+$ ]] || fail "$(t "'%s' is not a snapshot id." "$snap")"

to="$bulk/shares/restored"
if [ ! -d "$to" ]; then
  note "The share 'restored' does not exist yet: the files are restored into it."
  if ! $yes; then interactive || fail "Nothing is changed without --yes when there is no terminal."; confirm "Create the share 'restored' now?" || fail "cancelled"; fi
  bash "$create" restored
fi

note "$ hs backup restore $snap $path"
if ! $yes; then interactive || fail "Nothing is changed without --yes when there is no terminal."; confirm "Restore it?" || fail "cancelled"; fi
bash "$backup" restore "$snap" "$path" --to "$to"
ok "$(t 'Restored. Look in the share restored, below %s' "$path")"
note "Copy what you need back; the original was not touched."
