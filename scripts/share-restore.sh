#!/usr/bin/env bash
# help: bring back files of a share from the backup (into the share "restored", the original is not touched)
# help.de: Dateien einer Freigabe aus dem Backup zurückholen (in die Freigabe "restored", das Original bleibt unberührt)
# args: <share> [<folder or file inside the share>] [--snapshot <id|latest>] [--yes]
# Guided front for `hs backup restore`: builds the full original path, asks which snapshot, makes sure the
# target share exists and confirms. HS_BACKUP, HS_CREATE_SHARE and HS_BULK point tests at stand-ins.
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
. "$here/lib/sharepath.sh"
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
case "/$sub/" in */../*) fail "$(t "The folder must lie inside the share (no \"..\").")" ;; esac

# where the share lives: the folder under shares or sensitive (it may be gone: that is why we restore)
if path=$(share_dir "$share"); then kind=$(share_kind "$share")
else
  # the folder may be gone (that is why we restore): the registry still knows where it was, a fast share must not fall back to /bulk
  path=$(net conf getparm "$share" path 2>/dev/null || true)
  kind=$(share_kind_of_path "$path")
  if [ "$kind" = other ]; then kind=shares; path="$bulk/$kind/$share"; fi
fi
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
