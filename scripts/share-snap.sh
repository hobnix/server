#!/usr/bin/env bash
# help: ZFS snapshots of a share: hs share <share> snapshot [name] | snapshots | rollback [name]
# help.de: ZFS-Schnappschüsse einer Freigabe: hs share <Freigabe> snapshot [Name] | snapshots | rollback [Name]
# args: <share> snapshot|snapshots|rollback [<name>] [--yes]
# Only on the ZFS layout (a share is a dataset). On the snapraid layout the backup is the history:
# hs share <share> restore. HS_ZFS and HS_BULK_TYPE point tests at stand-ins.
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
zfs=${HS_ZFS:-zfs}
pool=${HS_BULK_POOL:-bulk}

usage() {
  say "usage: hs share <share> snapshot [name]   take a snapshot (default name: manual-<date>-<time>)"
  say "       hs share <share> snapshots         list the snapshots"
  say "       hs share <share> rollback [name]   go back to a snapshot (default: the newest)"
  exit 1
}
interactive() { [ -t 0 ] && [ -t 1 ] && [ -z "${HS_CALLER:-}" ] || [ -n "${HS_GUIDED_TTY:-}" ]; }

share=${1:-}; action=${2:-}; shift 2 2>/dev/null || true
[ -n "$share" ] && [ -n "$action" ] || usage
name=""; yes=false
for a in "$@"; do
  case "$a" in
    --yes) yes=true ;;
    -*) usage ;;
    *) [ -z "$name" ] || usage; name=$a ;;
  esac
done
[[ "$share" =~ ^[A-Za-z0-9._-]+$ ]] || fail "$(t "'%s' is not a share name." "$share")"
[ -z "$name" ] || [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || fail "$(t "'%s' is not a snapshot name (letters, digits, . _ -)." "$name")"

bulk_type=${HS_BULK_TYPE:-$(cat /etc/hs/bulk-type 2>/dev/null || echo zfs)}
if [ "$bulk_type" != zfs ]; then
  fail "$(t 'This server keeps /bulk on SnapRAID: there are no snapshots. Use the backup: hs share %s restore' "$share")"
fi

ds=""
for kind in shares sensitive; do
  if "$zfs" list -H -o name "$pool/$kind/$share" >/dev/null 2>&1; then ds="$pool/$kind/$share"; break; fi
done
[ -n "$ds" ] || fail "$(t "No share called '%s'." "$share")"

snaps() { "$zfs" list -H -t snapshot -o name,creation,used -s creation -d 1 "$ds" 2>/dev/null || true; }

case "$action" in
  snapshot)
    [ -n "$name" ] || name="manual-$(date +%Y%m%d-%H%M%S)"
    "$zfs" snapshot "$ds@$name"
    ok "$(t 'Snapshot %s taken.' "$ds@$name")"
    note "$(t 'List them: hs share %s snapshots. Go back to one: hs share %s rollback %s' "$share" "$share" "$name")" ;;
  snapshots)
    list=$(snaps)
    if [ -z "$list" ]; then note "$(t 'No snapshots yet. Take one: hs share %s snapshot' "$share")"; exit 0; fi
    rows=$(printf '%s\n' "$list" | while IFS=$'\t' read -r full created used; do
      printf '%s\t%s\t%s\n' "${full#*@}" "$created" "$used"
    done)
    # a person at a terminal gets a table; a pipe (the guided dialogue, tests) gets the tab separated lines
    if [ -t 1 ] && [ -z "${HS_CALLER:-}" ]; then { thead 'Snapshot' 'Created' 'Used'; printf '%s\n' "$rows"; } | table
    else printf '%s\n' "$rows"; fi ;;
  rollback)
    list=$(snaps)
    [ -n "$list" ] || fail "$(t 'There are no snapshots to go back to. Take one first: hs share %s snapshot' "$share")"
    newest=$(printf '%s\n' "$list" | tail -n 1 | cut -f1 | sed 's/^[^@]*@//')
    [ -n "$name" ] || name=$newest
    printf '%s\n' "$list" | cut -f1 | grep -qx "$ds@$name" || fail "$(t "No snapshot '%s' on this share." "$name")"
    extra=""
    if [ "$name" != "$newest" ]; then
      extra="-r"
      warn "$(t 'Newer snapshots exist; going back to %s deletes every snapshot after it.' "$name")"
    fi
    danger "$(t 'Everything written to the share after the snapshot %s is lost.' "$name")"
    if ! $yes; then
      interactive || fail "Nothing is changed without --yes when there is no terminal."
      confirm_name "$share" "$(t 'the share')" || fail "cancelled"
    fi
    # shellcheck disable=SC2086
    "$zfs" rollback $extra "$ds@$name"
    ok "$(t 'The share is back at %s.' "$name")" ;;
  *) usage ;;
esac
