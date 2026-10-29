#!/usr/bin/env bash
# help: change a share without asking anything: what would happen (plan), then do it as a background job (start)
# help.de: eine Freigabe ändern, ohne etwas zu fragen: was passieren würde (plan), dann als Hintergrundjob ausführen (start)
# args: plan|start <share> <backup|cache|auto|rename|snapshot|rollback|repair|perm|visibility|add|delete|purge|undelete|restore> [--to on|off|<new name>] [--label <name>] [--snapshot <name>] [--set <sid>=<level> ...] [--path <folder or file inside the share>] [--kind shares|sensitive] [--ct <instance> --path <inside> [--as <uid>:<gid>]] [--confirm <word>]
# System command (hs sys shares plan|start): for the interface, timers and tests. It never asks and prints plain
# key<TAB>value lines like pool-change.sh and ct-change.sh. The console wizards
# (share-snap-guided.sh, hs backup, ...) stay the console front ends over the same scripts.
#   backup     --to on|off        put the share into the nightly backup or leave it out
#   cache      --to on|off        upload cache (the instances that mount the share restart)
#   auto       --to on|off        automatic ZFS snapshots of the share
#   rename     --to <new name>    the folder on every disk, the Samba share, the backup switch, and every instance mount
#   snapshot   [--label <name>]   a ZFS snapshot (default name manual-<date>-<time>)
#   rollback   --snapshot <name>  ZFS: go back to a snapshot; newer ones are deleted (red: the share's name is typed)
#   repair                        hand the files of every share to adminuser again (all shares, a long job on big pools)
#   perm       --set <sid>=<level> ...   who may use the share: level none|read|write|full (repeatable; the plan lists the access afterwards)
#   visibility --to visible|hidden   list the share when browsing the server, or hide it (it can still be opened by typing its path)
#   delete                        take the share away without erasing it: detach it from the instances, rename the folder to <share>.deleted-<date> (kept, never published again), remove the Samba share (red: the share's name is typed)
#   purge                         <share> is a kept folder <name>.deleted-<date>: remove it for good (red: its name is typed)
#   undelete                      <share> is a kept folder <name>.deleted-<date>: bring it back as the share <name> (a rename, nothing is overwritten or removed; the share starts closed: Domain Admins only)
#   restore    --snapshot <id|latest> [--path <inside>]   bring files back from the backup into the share `restored` (the original is not touched)
#   add        --kind shares|sensitive [--ct <instance> --path <inside> [--as <uid>:<gid>]]   create the share <share>, optionally mount it into an instance
#
# plan: exit 0 = allowed, 1 = refused, 2 = something is still missing. Output: status ok|refused|needs, then needs<TAB><input>
#   | reason<TAB><text> | heading|step|note|warn|danger|command<TAB><line>, confirm_name<TAB><share> (only with a danger line), long<TAB>yes|no.
# start: the same checks, then the work runs as a background job (status started, unit). A danger line needs --confirm <share>.
# Test knobs: HS_MANAGE_SHARES, HS_BACKUP, HS_SHARE_SNAP, HS_SNAPSHOTS_AUTO, HS_SYNC_SHARES, HS_SHARE_OVERVIEW, HS_CREATE_SHARE, HS_SHARE_DELETE, HS_SHARE_PURGE, HS_SHARE_UNDELETE, HS_SHARE_RESTORE, HS_INCUS.
set -euo pipefail
here=$(dirname "$0")
manage=${HS_MANAGE_SHARES:-$here/manage-shares.sh}
backup=${HS_BACKUP:-$here/backup.sh}
snap=${HS_SHARE_SNAP:-$here/share-snap.sh}
auto=${HS_SNAPSHOTS_AUTO:-$here/snapshots-auto.sh}
sync=${HS_SYNC_SHARES:-$here/sync-shares.sh}
overview=${HS_SHARE_OVERVIEW:-$here/share-overview.sh}
create=${HS_CREATE_SHARE:-$here/create-share.sh}
deleter=${HS_SHARE_DELETE:-$here/share-delete.sh}
purger=${HS_SHARE_PURGE:-$here/share-purge.sh}
undeleter=${HS_SHARE_UNDELETE:-$here/share-undelete.sh}
restorer=${HS_SHARE_RESTORE:-$here/share-restore.sh}

refuse() { printf 'status\trefused\nreason\t%s\n' "$1"; exit 1; }

verb=${1:-}; share=${2:-}; action=${3:-}
case "$verb" in plan|start) ;; *) echo "usage: share-change.sh plan|start <share> <action> [options]" >&2; exit 1 ;; esac
[[ "$share" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || refuse "invalid share name"
case "$action" in backup|cache|auto|rename|snapshot|rollback|repair|perm|visibility|add|delete|purge|undelete|restore) ;; *) refuse "unknown action" ;; esac
shift 3

to="" label="" snapname="" confirm="" kind="" ct="" ctpath="" as="" sets=() inside=""
while [ $# -gt 0 ]; do
  case "$1" in
    --to)       to=${2:-}; shift 2 ;;
    --label)    label=${2:-}; shift 2 ;;
    --snapshot) snapname=${2:-}; shift 2 ;;
    --confirm)  confirm=${2:-}; shift 2 ;;
    --set)      sets+=("${2:-}"); shift 2 ;;
    --kind)     kind=${2:-}; shift 2 ;;
    --ct)       ct=${2:-}; shift 2 ;;
    --path)     ctpath=${2:-}; inside=${2:-}; shift 2 ;;
    --as)       as=${2:-}; shift 2 ;;
    *) refuse "unknown option $1" ;;
  esac
done
word='^[A-Za-z0-9][A-Za-z0-9._-]*$'
for v in "$label" "$snapname"; do [ -z "$v" ] || [[ "$v" =~ $word ]] || refuse "invalid name '$v'"; done

needs=()
case "$action" in
  backup|cache|auto) [ -n "$to" ] || needs+=(to) ;;
  rename|visibility) [ -n "$to" ] || needs+=(to) ;;
  rollback|restore) [ -n "$snapname" ] || needs+=(snapshot) ;;
  perm) [ ${#sets[@]} -gt 0 ] || needs+=(permission) ;;
  add) [ -n "$kind" ] || needs+=(kind); [ -z "$ct" ] || [ -n "$ctpath" ] || needs+=(path) ;;
esac
if [ ${#needs[@]} -gt 0 ]; then
  echo "status	needs"
  printf 'needs\t%s\n' "${needs[@]}"
  exit 2
fi
case "$action" in
  backup|cache|auto) [ "$to" = on ] || [ "$to" = off ] || refuse "--to is on or off" ;;
  visibility) [ "$to" = visible ] || [ "$to" = hidden ] || refuse "--to is visible or hidden" ;;
  rename) [[ "$to" =~ $word ]] || refuse "'$to' is not a usable name (letters, digits, . _ -)" ;;
  restore) [[ "$snapname" =~ ^[A-Za-z0-9]+$ ]] || refuse "'$snapname' is not a snapshot id (latest, or an id from the list)"
           case "$inside" in *..*) refuse "the folder must lie inside the share" ;; esac ;;
  purge) [[ "$share" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.deleted-[0-9]{8}$ ]] || refuse "only a kept folder (<name>.deleted-<date>) can be removed for good" ;;
  undelete) [[ "$share" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.deleted-[0-9]{8}$ ]] || refuse "only a kept folder (<name>.deleted-<date>) can be brought back" ;;
  perm) for x in "${sets[@]}"; do [[ "$x" =~ ^S-[0-9-]+=(none|read|write|full)$ ]] || refuse "expected <sid>=<level> (none, read, write or full), got '$x'"; done ;;
  add) [ "$kind" = shares ] || [ "$kind" = sensitive ] || refuse "--kind is shares or sensitive"
       [ -z "$as" ] || [[ "$as" =~ ^[0-9]+:[0-9]+$ ]] || refuse "--as expects <uid>:<gid>, got '$as'"
       [ -z "$ct" ] || [[ "$ct" =~ ^[a-z][a-z0-9-]*$ ]] || refuse "invalid instance name"
       [ -z "$ctpath" ] || [[ "$ctpath" == /* ]] || refuse "the path inside must start with /" ;;
esac

export HS_PLAIN=1 HS_LANG=en HS_CALLER=${HS_CALLER:-ui}
unset HS_GUIDED_TTY

# the command the job runs
case "$action" in
  backup)   cmd=(bash "$backup" "$share" "$to") ;;
  cache)    cmd=(bash "$manage" "$share" --cache "$to") ;;
  auto)     cmd=(bash "$auto" "$share" "$to") ;;
  rename)   cmd=(bash "$manage" "$share" --rename "$to") ;;
  visibility) cmd=(bash "$manage" "$share" --visibility "$to") ;;
  snapshot) cmd=(bash "$snap" "$share" snapshot); [ -z "$label" ] || cmd+=("$label") ;;
  rollback) cmd=(bash "$snap" "$share" rollback "$snapname" --yes) ;;
  repair)   cmd=(bash "$sync" --fix-owner) ;;
  delete)   cmd=(bash "$deleter" "$share") ;;
  purge)    cmd=(bash "$purger" "$share") ;;
  undelete) cmd=(bash "$undeleter" "$share") ;;
  restore)  cmd=(bash "$restorer" "$share"); [ -z "$inside" ] || cmd+=("${inside#/}"); cmd+=(--snapshot "$snapname" --yes) ;;
  perm)     cmd=(bash "$manage" "$share" --set "${sets[@]}") ;;
  add)      cmd=(bash "$create" "$share"); [ "$kind" != sensitive ] || cmd+=(--sensitive)
            [ -z "$ct" ] || cmd+=(--ct "$ct" "$ctpath"); [ -z "$as" ] || cmd+=(--as "$as") ;;
esac

# ZFS layout: the disks column of the overview is the pool name, on SnapRAID it is data-NN,...
is_zfs() {
  local d
  d=$(bash "$overview" 2>/dev/null | awk -F'	' -v s="$share" '$1 == s { print $8 }' || true)
  [ -n "$d" ] && [ "$d" != "-" ] && [[ "$d" != data-* ]]
}

# the plan of the actions that have a dry run: the script's own text; the others are described here
dry=""
case "$action" in
  purge)
    rc=0
    dry=$(bash "$purger" "$share" --dry-run </dev/null 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "status	refused"
      printf '%s\n' "$dry" | sed -e 's/^[[:space:]]*//' | awk 'NF { print "reason\t" $0 }'
      exit 1
    fi ;;
  undelete)
    rc=0
    dry=$(bash "$undeleter" "$share" --dry-run </dev/null 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "status	refused"
      printf '%s\n' "$dry" | sed -e 's/^[[:space:]]*//' | awk 'NF { print "reason\t" $0 }'
      exit 1
    fi ;;
  restore)
    st=$(bash "$backup" --state 2>/dev/null | awk -F'\t' '$1 == "configured" { print $2 }' || true)
    [ "$st" = yes ] || refuse "the backup is not set up (hs backup init <device>)" ;;
  delete)
    rc=0
    dry=$(bash "$deleter" "$share" --dry-run </dev/null 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "status	refused"
      printf '%s\n' "$dry" | sed -e 's/^[[:space:]]*//' -e 's/^✗ *//' -e 's/^! *//' | awk 'NF { print "reason\t" $0 }'
      exit 1
    fi ;;
  rename|cache|perm|visibility)
    rc=0
    if [ "$action" = perm ]; then dry=$(bash "$manage" "$share" --set "${sets[@]}" --dry-run </dev/null 2>&1) || rc=$?
    else dry=$(bash "$manage" "$share" "--$action" "$to" --dry-run </dev/null 2>&1) || rc=$?; fi
    if [ "$rc" -ne 0 ]; then
      echo "status	refused"
      printf '%s\n' "$dry" | sed -e 's/^[[:space:]]*//' -e 's/^✗ *//' -e 's/^! *//' | awk 'NF { print "reason\t" $0 }'
      exit 1
    fi ;;
  rollback)
    is_zfs || refuse "snapshots need the ZFS layout (the backup is the history on SnapRAID: hs share $share restore)"
    list=$(bash "$overview" history "$share" 2>/dev/null | cut -f1 || true)
    [ -n "$list" ] || refuse "this share has no snapshots (ZFS layout only)"
    grep -qxF -- "$snapname" <<<"$list" || refuse "No snapshot '$snapname' on this share."
    newer=$(awk -v t="$snapname" 'f { n++ } $0 == t { f = 1 } END { print n + 0 }' <<<"$list") ;;
  add)
    if "${HS_NET:-net}" conf listshares 2>/dev/null | grep -qxF -- "$share"; then refuse "A share called '$share' exists already."; fi
    case "${share,,}" in shares|sensitive|global|homes|printers) refuse "'$share' is a reserved name." ;; esac
    [ -z "$ct" ] || ${HS_INCUS:-incus} info "$ct" >/dev/null 2>&1 || refuse "'$ct' does not exist." ;;
  snapshot|auto)
    is_zfs || refuse "snapshots need the ZFS layout (the backup is the history on SnapRAID: hs share $share restore)" ;;
esac

danger=""
[ "$action" != rollback ] || danger="Everything written to '$share' after the snapshot '$snapname' is lost."
[ "$action" != purge ] || danger="'$share' is removed for good: its files cannot be brought back from the disks. Copies in older backups stay until they age out."
if [ "$action" = delete ]; then
  who=$(bash "$overview" mounts "$share" 2>/dev/null | cut -f1 | sort -u | paste -sd, - | sed 's/,/, /g' || true)
  if grep -q 'rename' <<<"$dry"; then
    danger="'$share' disappears from Samba${who:+ and from the instances that mount it ($who)}. The files are kept in a renamed folder, not erased."
  else
    danger="'$share' disappears from Samba${who:+ and from the instances that mount it ($who)}. Its folder is already gone, so no files are touched."
  fi
fi
long=no
case "$action" in repair|restore|purge|undelete) long=yes ;; esac

if [ "$verb" = start ]; then
  if [ -n "$danger" ] && [ "$confirm" != "$share" ]; then refuse "type the name to confirm: $share"; fi
  . "$here/lib/job.sh"
  unit=$(hs_job "share-$action-$share" "hs share $share $action" -- "${cmd[@]}") || refuse "the job could not be started"
  printf 'status\tstarted\nunit\t%s\n' "$unit"
  exit 0
fi

echo "status	ok"
# what restarts: the instances that mount the share (rename and cache switch their mounts or need a restart)
mounted() { bash "$overview" mounts "$share" 2>/dev/null | cut -f1 | sort -u | paste -sd, - | sed 's/,/, /g' || true; }
case "$action" in
  backup) if [ "$to" = on ]; then printf 'heading\tput %s into the backup\nstep\tinclude %s in the nightly backup\n' "$share" "$share"
          else printf 'heading\ttake %s out of the backup\nstep\tleave %s out of the nightly backup (existing backups stay until they age out)\n' "$share" "$share"; fi ;;
  auto)   printf 'heading\tautomatic snapshots of %s: %s\nstep\t%s\n' "$share" "$to" "$([ "$to" = on ] && echo "include '$share' in the hourly, daily and weekly snapshots" || echo "leave '$share' out of the automatic snapshots (existing ones stay)")" ;;
  snapshot) printf 'heading\tsnapshot of %s\nstep\ttake a snapshot of the share as it is now\nnote\tSnapshots hold deleted files, so they use pool space.\n' "$share" ;;
  rollback) printf 'heading\tgo back to %s on %s\n' "$snapname" "$share"
            [ "${newer:-0}" -eq 0 ] || printf 'step\tdelete the %s newer snapshot(s)\n' "$newer"
            printf 'step\troll the share back to the snapshot\n' ;;
  repair) printf 'heading\thand every share over to adminuser\nstep\tchange the owner of the files of every share that is not adminuser'"'"'s\nnote\tThis can take a long time on big shares.\n' ;;
  perm)
    printf '%s\n' "$dry" | awk '
      /^[ \t]*$/ { next }
      !h { sub(/:[ \t]*$/, ""); print "heading\t" $0; h = 1; next }
      { sub(/^[ \t]+/, ""); print "step\t" $0 }'
    printf 'note\tPermissions are checked when a connection is opened: reconnect to see the change.\n' ;;
  add)
    printf 'heading\tcreate the share %s\nstep\tcreate the %s folder (a dataset on ZFS)\nstep\tpublish it over Samba; only Domain Admins may use it until you set permissions\n' "$share" "$kind"
    [ -z "$ct" ] || printf 'step\tmount it into %s at %s%s\n' "$ct" "$ctpath" "$([ -n "$as" ] && echo " (user $as can write)" || true)"
    [ "$kind" != sensitive ] || printf 'note\tA sensitive folder is read-only for the Samba users.\n'
    [ -z "$ct" ] || printf 'note\tA changed user mapping restarts %s.\n' "$ct" ;;
  purge)
    printf 'heading\tremove the kept folder %s for good\n' "$share"
    printf '%s\n' "$dry" | awk '{ sub(/^[ \t]+/, ""); print "step\t" $0 }'
    printf 'note\tThis frees the space it uses. Old backup snapshots still hold a copy until they age out.\n' ;;
  undelete)
    printf 'heading\tbring the kept folder %s back as the share %s\n' "$share" "${share%.deleted-*}"
    printf '%s\n' "$dry" | awk '/hs share repair/ { print "step\tpublish it again as a Samba share"; next } { sub(/^[ \t]+/, ""); print "step\t" $0 }'
    printf 'note\tNothing is overwritten or removed. The share starts closed (Domain Admins only): set who may use it again. Instance mounts are not put back.\n' ;;
  restore)
    printf 'heading\trestore %s from the backup\n' "$share"
    printf 'step\trestore %s of snapshot %s into the share restored\n' "${inside:-the whole share}" "$snapname"
    printf 'step\tcreate the share restored if it does not exist yet\n'
    printf 'note\tThe original is not touched: look in the share restored, below the full original path, and copy back what you need.\n'
    [ -n "$inside" ] || printf 'warn\tThe whole share is restored: this can be a lot of data.\n'
    ;;
  delete)
    printf 'heading\tdelete the share %s\n' "$share"
    printf '%s\n' "$dry" | awk '
      /incus config device remove/ { printf "step\tdetach %s from the instance %s\n", $6, $5; next }
      / rename / { print "step\trename the folder to <share>.deleted-<date> on every disk (nothing is erased)"; next }
      /delshare/ { print "step\tremove the Samba share"; next }'
    grep -q ' rename ' <<<"$dry" || printf 'note\tThe folder was already removed outside the interface: only the dead share is cleaned up.\n'
    grep -q ' rename ' <<<"$dry" && printf 'note\tThe folder stays on the disks and in the backup if it was in it. `hs share repair` lists it as kept and never publishes it. Remove it by hand when you are sure.\n' ;;
  rename|cache|visibility)
    printf '%s\n' "$dry" | awk '
      /^\(dry run/ || /^[ \t]*$/ { next }
      NR == 1 || !h { sub(/:[ \t]*$/, ""); print "heading\t" $0; h = 1; next }
      { sub(/^[ \t]+/, ""); print "step\t" $0 }'
    who=$(mounted)
    if [ -n "$who" ]; then
      if [ "$action" = rename ]; then printf 'warn\tThese instances mount the share; their mount is switched to the new path and they restart: %s\n' "$who"
      else printf 'warn\tThese instances restart so they see the cache: %s\n' "$who"; fi
    fi ;;
esac
printf 'command\t%s\n' "${cmd[*]}"
if [ -n "$danger" ]; then
  printf 'danger\t%s\nconfirm_name\t%s\n' "$danger" "$share"
fi
printf 'long\t%s\n' "$long"
exit 0
