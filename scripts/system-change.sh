#!/usr/bin/env bash
# help: do something to the whole server without asking anything: what would happen (plan), then do it as a background job (start)
# help.de: etwas mit dem ganzen Server tun, ohne etwas zu fragen: was passieren würde (plan), dann als Hintergrundjob ausführen (start)
# args: plan|start <sync|scrub|update|rollback|gc|reboot|shutdown> [--pool <pool>] [--days <N>] [--confirm <word>]
# System command (hs sys system plan|start): for the interface, timers and tests. It never asks and prints plain key<TAB>value lines like
# pool-change.sh and ct-change.sh.
#   sync                 SnapRAID layout: update the parity now (bulk-sync.sh); on ZFS there is nothing to sync
#   scrub --pool <pool>  SnapRAID bulk: check part of the data against the parity (bulk-sync.sh --scrub); a ZFS pool: zpool scrub <pool>
#   update               pull the configuration from Git and rebuild (update.sh); the plan is the preview (update-preview.sh --no-build): the new
#                        commits, the diffstat, new machine.toml options, a checkout that would stop the update; refused while the storage is locked
#   rollback             switch back to the previous generation (nixos-rebuild switch --rollback); RED: the word `rollback` is typed
#   gc [--days <N>]      delete the generations older than N days (default 30) and free the space (system.sh gc N --yes)
#   reboot | shutdown    power.sh reboot|shutdown --yes, started 5 seconds later by a systemd timer so the answer still reaches the caller; RED: the word
#                        `reboot` / `shutdown` is typed. Nothing is duplicated: power.sh refuses while a backup, sync, scrub or pool change runs (the plan
#                        says so, from `power.sh --dry-run`), and the "rebooting" / "shutting down" push message comes from hs-shutdown-notice.service
#                        as for the user command. The web interface and every instance go down; encrypted storage comes back locked (hs unlock).
#
# plan: exit 0 = allowed, 1 = refused, 2 = something is missing. Output: status ok|refused|needs, then needs<TAB><input>
#   | reason<TAB><text> | heading|section|step|note|warn|text|danger|command<TAB><line>, confirm_name<TAB>rollback|reboot|shutdown (only with a danger line), long<TAB>yes|no.
# start: the same checks, then the work runs as a background job (status started, unit).
# Test knobs: HS_POWER (stand-in for power.sh), HS_REBOOT_DELAY (seconds, default 5), HS_BULK_TYPE_FILE, HS_BULK_SYNC (stand-in for bulk-sync.sh), HS_ZPOOL, HS_UPDATE, HS_UPDATE_PREVIEW, HS_SYSTEM, HS_LOCKED_MARKER, HS_PROFILES.
set -euo pipefail
here=$(dirname "$0")
bulk_sync=${HS_BULK_SYNC:-$here/bulk-sync.sh}
update=${HS_UPDATE:-$here/update.sh}
preview=${HS_UPDATE_PREVIEW:-$here/update-preview.sh}
system=${HS_SYSTEM:-$here/system.sh}
power=${HS_POWER:-$here/power.sh}
profiles=${HS_PROFILES:-/nix/var/nix/profiles}
confirm=""
zpool=${HS_ZPOOL:-zpool}
bulk_type=$(cat "${HS_BULK_TYPE_FILE:-/etc/hs/bulk-type}" 2>/dev/null || echo zfs)

refuse() { printf 'status\trefused\nreason\t%s\n' "$1"; exit 1; }

verb=${1:-}; action=${2:-}
case "$verb" in plan|start) ;; *) echo "usage: system-change.sh plan|start <sync|scrub|update|rollback|gc|reboot|shutdown> [options]" >&2; exit 1 ;; esac
case "$action" in sync|scrub|update|rollback|gc|reboot|shutdown) ;; *) refuse "unknown action (sync, scrub, update, rollback, gc, reboot or shutdown)" ;; esac
shift 2
pool="" days=30
while [ $# -gt 0 ]; do
  case "$1" in
    --pool)    pool=${2:-}; shift 2 ;;
    --days)    days=${2:-}; shift 2 ;;
    --confirm) confirm=${2:-}; shift 2 ;;
    *) refuse "unknown option $1" ;;
  esac
done

if [ "$action" = scrub ] && [ -z "$pool" ]; then
  printf 'status\tneeds\nneeds\tpool\n'
  exit 2
fi
[ -z "$pool" ] || [[ "$pool" =~ ^[a-z][a-z0-9_-]*$ ]] || refuse "invalid pool name"
[[ "$days" =~ ^[0-9]+$ ]] && [ "$days" -ge 1 ] || refuse "--days is a number of days (1 or more)"

snapraid=false
{ [ "$bulk_type" = snapraid ] && [ "$pool" = bulk ]; } && snapraid=true
case "$action" in
  sync)
    [ "$bulk_type" = snapraid ] || refuse "This server keeps /bulk on ZFS: the parity is always current, there is nothing to sync."
    cmd=(bash "$bulk_sync") ;;
  scrub)
    if $snapraid; then
      cmd=(bash "$bulk_sync" --scrub)
    else
      "$zpool" list -H -o name "$pool" >/dev/null 2>&1 || refuse "There is no pool called '$pool'."
      if "$zpool" status "$pool" 2>/dev/null | grep -q 'scrub in progress'; then refuse "A scrub of '$pool' is running already."; fi
      cmd=("$zpool" scrub "$pool")
    fi ;;
  update)
    [ ! -e "${HS_LOCKED_MARKER:-/run/hs/storage-locked}" ] || refuse "The storage is locked: unlock it first (hs unlock), an update would refuse."
    cmd=(bash "$update")
    # the preview is the plan; when it cannot even fetch, the update would fail too
    rc=0; pv=$(HS_PLAIN=1 HS_LANG=en bash "$preview" --no-build </dev/null 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "status	refused"
      printf '%s\n' "$pv" | sed -e 's/^[[:space:]]*//' -e 's/^✗ *//' -e 's/^! *//' | awk 'NF { print "reason\t" $0 }'
      exit 1
    fi ;;
  rollback) cmd=("nixos-rebuild" switch --rollback) ;;
  gc) cmd=(bash "$system" gc "$days" --yes) ;;
  reboot|shutdown)
    cmd=(bash "$power" "$action" --yes)
    # power.sh checks what must not be cut off; --dry-run only says it (it does not refuse), so the plan reads its list
    pw=$(HS_PLAIN=1 HS_LANG=en HS_CALLER=ui bash "$power" "$action" --dry-run </dev/null 2>&1) || refuse "$(printf '%s' "$pw" | tail -n 1)"
    if grep -q 'still running' <<<"$pw"; then
      echo "status	refused"
      printf 'reason\tNot now: something is still running that must not be cut off.\n'
      printf '%s\n' "$pw" | sed -n '/still running/,/Dry run/p' | sed '1d;$d' | sed -e 's/^[[:space:]]*//' | awk 'NF { print "reason\t" $0 }'
      exit 1
    fi ;;
esac

danger=""
case "$action" in
  reboot) danger="The server restarts now: the web interface and every instance go down for a few minutes. While the storage is encrypted it comes back LOCKED and stays unusable until someone runs hs unlock." ;;
  shutdown) danger="The server powers off: the web interface and every instance stay down until someone switches it on again, and it cannot be started from here. Encrypted storage is locked again after the next start (hs unlock)." ;;
esac
[ "$action" != rollback ] || danger="The running system goes back to the previous generation: services restart and everything the newer generation changed is switched off until you rebuild."


if [ "$verb" = start ]; then
  confirm_word=rollback; case "$action" in reboot|shutdown) confirm_word=$action ;; esac
  if [ -n "$danger" ] && [ "$confirm" != "$confirm_word" ]; then refuse "type the word to confirm: $confirm_word"; fi
  case "$action" in
    reboot|shutdown)
      # not a job that runs now: a timer starts power.sh a few seconds later, the caller still gets this answer
      unit=hs-job-system-$action-$(date +%H%M%S)
      systemd-run --quiet --unit="$unit" --on-active="${HS_REBOOT_DELAY:-5}" --description="hs $action (from the web interface)" \
        -E HS_CALLER=job -E "PATH=$PATH" "${cmd[@]}" || refuse "the $action could not be scheduled"
      printf 'status\tstarted\nunit\t%s\n' "$unit"
      exit 0 ;;
  esac
  . "$here/lib/job.sh"
  desc="hs pool ${pool:-bulk} $action"; case "$action" in update) desc="hs system update" ;; rollback) desc="hs system rollback" ;; gc) desc="hs system gc $days" ;; esac
  unit=$(hs_job "system-$action-${pool:-all}" "$desc" -- "${cmd[@]}") || refuse "the job could not be started"
  printf 'status\tstarted\nunit\t%s\n' "$unit"
  exit 0
fi

echo "status	ok"
case "$action" in
  sync)
    printf 'heading\tupdate the parity of bulk\n'
    printf 'step\tfind what changed on the data disks since the last sync\n'
    printf 'step\tupdate the parity disk\n'
    printf 'note\tShares stay usable. A sync makes deletions permanent; it refuses when unusually many files vanished since the last one.\n'
    printf 'note\tThe nightly timer skips its run while this one holds the bulk lock.\n' ;;
  scrub)
    if $snapraid; then
      printf 'heading\tcheck part of the bulk data against the parity\n'
      printf 'step\tread a part of every data disk and compare it with the parity\n'
      printf 'note\tIt reads a lot: the disks are busy for a while, shares stay usable. It takes the bulk lock.\n'
    else
      printf 'heading\tscrub the pool %s\n' "$pool"
      printf 'step\tread every block of %s and check its checksum; repair from the mirror where it can\n' "$pool"
      printf 'note\tThe job only starts the scrub: ZFS runs it in the background and %s stays usable (see the pool card for the result).\n' "$pool"
    fi ;;
esac
case "$action" in
  update)
    printf 'heading\tupdate the server\n'
    printf '%s\n' "$pv" | awk '
      /^[ \t]*$/ { next }
      /\.\.\.$/ { next }
      /^── / { t = $0; sub(/^── */, "", t); sub(/ *──.*$/, "", t); print "section\t" t; next }
      /^  [!✗] / { t = $0; sub(/^  [!✗] /, "", t); print "warn\t" t; next }
      /^  ✓ / { t = $0; sub(/^  ✓ /, "", t); print "note\t" t; next }
      { t = $0; sub(/^[ \t]+/, "", t); print "text\t" t }'
    printf 'note\tThe rebuild builds the new system first; a build that fails changes nothing. Services whose files changed restart.\n' ;;
  rollback)
    gens=$(ls -1 "$profiles" 2>/dev/null | grep -E '^system-[0-9]+-link$' | sort -t- -k2 -n -r | head -n 3 | paste -sd, - | sed 's/,/, /g' || true)
    printf 'heading\troll the system back\nstep\tswitch the running system to the previous generation\n'
    [ -z "$gens" ] || printf 'note\tThe newest generations: %s\n' "$gens"
    printf 'note\tThe newer generation is not deleted: hs rebuild brings it back.\n' ;;
  gc)
    printf 'heading\tdelete old generations\nstep\tdelete every generation older than %s days and the store paths only they use\n' "$days"
    printf 'warn\tRolling back further than that is not possible afterwards.\n' ;;
  reboot|shutdown)
    if [ "$action" = reboot ]; then printf 'heading\treboot the server\nstep\tsend the "rebooting" message, stop every service and instance, restart the machine\n'
    else printf 'heading\tshut the server down\nstep\tsend the "shutting down" message, stop every service and instance, power the machine off\n'; fi
    printf 'step\tstart in 5 seconds, so this page still gets its answer\n'
    printf 'warn\tThis web interface and every instance go down. Nothing runs while the server is off.\n'
    printf 'warn\tIf the storage is encrypted it comes back LOCKED: shares, instances and this page stay unavailable until hs unlock is run over SSH.\n' ;;
esac
printf 'command\t%s\n' "${cmd[*]}"
if [ -n "$danger" ]; then printf 'danger\t%s\nconfirm_name\t%s\n' "$danger" "${confirm_word:-$action}"; fi
case "$action" in gc|reboot|shutdown) printf 'long\tno\n' ;; *) printf 'long\tyes\n' ;; esac
exit 0
