#!/usr/bin/env bash
# help: remove the Samba shares whose folder is gone (what `hs share repair` reports as "folder is gone")
# help.de: Samba-Freigaben entfernen, deren Ordner nicht mehr existiert (das, was `hs share repair` als "folder is gone" meldet)
# args: [--dry-run] [--yes]
# Only registry shares whose path is under /bulk/shares or /bulk/sensitive are looked at; other shares are never touched. Nothing is removed
# while the storage is locked or /bulk is not mounted (a missing folder then means "not mounted", not "gone"), and the bulk lock is taken so
# a rename in progress (old folder already moved, old Samba share not yet dropped) is not mistaken for a gone folder. The share's settings
# and permissions are lost with it; a folder that comes back is published again by `hs share repair`, closed to Domain Admins.
# Test knobs: HS_NET, HS_BULK, HS_LOCK, HS_LOCKED_FLAG.
set -euo pipefail
. "$(dirname "$0")/lib/ui.sh"

net=${HS_NET:-net}
BULK=${HS_BULK:-/bulk}
dry=false; yes=false
for a in "$@"; do
  case "$a" in
    --dry-run) dry=true ;;
    --yes)     yes=true ;;
    *) say "usage: hs share cleanup [--dry-run] [--yes]"
       say "  --dry-run  only list the shares whose folder is gone, change nothing"
       say "  --yes      do not ask before removing them"
       exit 1 ;;
  esac
done

[ ! -e "${HS_LOCKED_FLAG:-/run/hs/storage-locked}" ] || fail "The storage is locked, so no folder can be checked. Unlock it first:  hs unlock"
for parent in shares sensitive; do
  [ -d "$BULK/$parent" ] || fail "$(t "%s is missing: is the pool mounted? Nothing was changed." "$BULK/$parent")"
  # a folder on the system disk instead of the pool: the pool is not mounted
  if [ -z "${HS_BULK:-}" ] && [ "$(findmnt -n -T "$BULK/$parent" -o TARGET 2>/dev/null || true)" = / ]; then
    fail "$(t "%s is not on the pool (not mounted?). Nothing was changed." "$BULK/$parent")"
  fi
done

exec 9>"${HS_LOCK:-/run/hs-bulk.lock}"
flock -w 600 9 || fail "Parity sync, cache mover or a rename is running, try again later."

gone=(); paths=()
while IFS= read -r name; do
  [ -n "$name" ] || continue
  path=$("$net" conf getparm "$name" path 2>/dev/null || true)
  case "$path" in
    "$BULK"/shares/*|"$BULK"/sensitive/*) ;;
    *) continue ;;
  esac
  if [ ! -e "$path" ]; then gone+=("$name"); paths+=("$path"); fi
done < <("$net" conf listshares 2>/dev/null)

if [ ${#gone[@]} -eq 0 ]; then
  ok "No Samba share points at a folder that is gone."
  exit 0
fi

{
  thead SHARE FOLDER
  for i in "${!gone[@]}"; do printf '%s\t%s\n' "${gone[i]}" "${paths[i]}"; done
} | table

if $dry; then
  note "(dry run, nothing changed)"
  exit 0
fi

if ! $yes; then
  [ -t 0 ] || fail "No terminal to ask on: add --yes to remove them anyway."
  confirm "Remove ${#gone[@]} Samba share(s) whose folder is gone?" || { note "Nothing was removed."; exit 0; }
fi

removed=0
for name in "${gone[@]}"; do
  if "$net" conf delshare "$name"; then removed=$((removed + 1)); else warn "$(t "Could not remove the share '%s'." "$name")"; fi
done
ok "$(t "%s Samba share(s) removed." "$removed")"
[ "$removed" -eq ${#gone[@]} ] || exit 1
