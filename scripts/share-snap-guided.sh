#!/usr/bin/env bash
# help: guided ZFS snapshots of a share: hs share <share> snapshot|rollback|auto (asks what is missing)
# help.de: geführte ZFS-Schnappschüsse einer Freigabe: hs share <Freigabe> snapshot|rollback|auto (fragt, was fehlt)
# args: <share> snapshot [<name>] | rollback [<name>] [--yes] | auto [on|off] [--yes]
# Only on the ZFS layout (a share is a dataset; the snapraid layout has the backup instead). Guided front
# for share-snap.sh and snapshots-auto.sh. Every answer is also an option; --yes skips the
# confirmation; without a terminal and without --yes nothing is changed. HS_SHARE_SNAP, HS_SNAPSHOTS_AUTO
# point tests at stand-ins, HS_GUIDED_TTY=1 = "there is a terminal".
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
snap=${HS_SHARE_SNAP:-$here/share-snap.sh}
auto=${HS_SNAPSHOTS_AUTO:-$here/snapshots-auto.sh}

usage() {
  say "usage: hs share <share> snapshot [name] [--yes]"
  say "       hs share <share> rollback [name] [--yes]"
  say "       hs share <share> auto [on|off] [--yes]"
  exit 1
}
interactive() { [ -t 0 ] && [ -t 1 ] && [ -z "${HS_CALLER:-}" ] || [ -n "${HS_GUIDED_TTY:-}" ]; }

share=${1:-}; action=${2:-}; shift 2 2>/dev/null || true
[ -n "$share" ] && [ -n "$action" ] || usage
arg=""; yes=false
for a in "$@"; do
  case "$a" in
    --yes) yes=true ;;
    -*) usage ;;
    *) [ -z "$arg" ] || usage; arg=$a ;;
  esac
done
[[ "$share" =~ ^[A-Za-z0-9._-]+$ ]] || fail "$(t "'%s' is not a share name." "$share")"
need_tty() { $yes || interactive || fail "Nothing is changed without --yes when there is no terminal."; }

case "$action" in
  snapshot)
    [[ -z "$arg" || "$arg" =~ ^[A-Za-z0-9._-]+$ ]] || fail "$(t "'%s' is not a snapshot name (letters, digits, . _ -)." "$arg")"
    need_tty
    if [ -z "$arg" ] && ! $yes; then
      arg=$(ask "Name of the snapshot (enter = manual-<date>-<time>):" "")
    fi
    if [ -n "$arg" ]; then bash "$snap" "$share" snapshot "$arg"; else bash "$snap" "$share" snapshot; fi ;;
  rollback)
    need_tty
    if [ -z "$arg" ] && ! $yes; then
      mapfile -t names < <(bash "$snap" "$share" snapshots | cut -f1 | tac)
      [ ${#names[@]} -gt 0 ] || fail "There are no snapshots to go back to."
      arg=$(choose "Go back to which snapshot? (newest first)" "${names[@]}") || exit 1
    fi
    # share-snap.sh warns about what is lost and asks itself unless --yes is passed on
    args=("$share" rollback)
    [ -z "$arg" ] || args+=("$arg")
    ! $yes || args+=(--yes)
    bash "$snap" "${args[@]}" ;;
  auto)
    need_tty
    if [ -z "$arg" ]; then
      ! $yes || usage
      arg=$(choose "Automatic snapshots for this share?" on off) || exit 1
    fi
    [ "$arg" = on ] || [ "$arg" = off ] || usage
    bash "$auto" "$share" "$arg" ;;
  *) usage ;;
esac
