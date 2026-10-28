#!/usr/bin/env bash
# help: change the backup without asking anything: what would happen (plan), then do it as a background job (start)
# help.de: das Backup ändern, ohne etwas zu fragen: was passieren würde (plan), dann als Hintergrundjob ausführen (start)
# args: plan|start <toggle|now|verify|prune|drill|browse|offsite-set|offsite-now|offsite-off|init> [--name <share|instance>] [--kind shares|sensitive|ct] [--to on|off] [--count <N>] [--repo <restic repository>] [--disk <id>] [--confirm <disk name>]
# System command (hs sys backup plan|start): for the interface, timers and tests. It never asks and prints plain key<TAB>value lines like
# pool-change.sh and share-change.sh.
#   toggle --name <n> --kind shares|sensitive|ct --to on|off   put a share or an instance into the nightly backup or leave it out
#   now                                                        back up right now (the nightly run does the same)
#   verify                                                     read a part of the stored data and check it
#   prune                                                      give space back now: delete leftovers of a run that ran out of space, apply the retention, prune
#   drill [--count N]                                         restore N random files (default 5) and compare them with the originals
#   browse --to on|off                                         publish the whole backup read-only as the share backup-browse, or stop that
#   offsite-set --repo <restic repository>                     also copy every backup to a second repository (sftp:user@host:/path, b2:bucket:path, a folder ...); the
#                                                              credentials stay in /var/lib/hs/backup-offsite.env, written by hand, never passed through here
#   offsite-now                                                copy the new backups to the off-site repository now
#   offsite-off                                                stop copying (what is there stays there)
#   init --disk <id>                                           RED: make a free disk (its name under /dev/disk/by-id, see `hs sys pool disks`) the backup disk: it is ERASED,
#                                                              formatted ext4 with the label `backup`, the backup password is created (or reused) and the repository initialised;
#                                                              the plan's confirm_name is the kernel name of the disk (sdc), `start` needs it in --confirm
#
# plan: exit 0 = allowed, 1 = refused, 2 = something is missing. Output: status ok|refused|needs, then needs<TAB><input>
#   | reason<TAB><text> | heading|step|note|warn|danger|command<TAB><line>, confirm_name<TAB><disk> (only init), long<TAB>yes|no. Only init is red.
# start: the same checks, then the work runs as a background job (status started, unit).
# Test knobs: HS_BACKUP (stand-in for backup.sh), HS_BACKUP_NEXT (epoch of the next timer run), HS_INCUS, HS_STATE_DIR, HS_DISK_BYID (the directory of the by-id links).
set -euo pipefail
here=$(dirname "$0")
backup=${HS_BACKUP:-$here/backup.sh}

refuse() { printf 'status\trefused\nreason\t%s\n' "$1"; exit 1; }

verb=${1:-}; action=${2:-}
case "$verb" in plan|start) ;; *) echo "usage: backup-change.sh plan|start <toggle|now|verify|drill|browse> [options]" >&2; exit 1 ;; esac
case "$action" in toggle|now|verify|prune|drill|browse|offsite-set|offsite-now|offsite-off|init) ;; *) refuse "unknown action (toggle, now, verify, drill, browse, offsite-set|now|off or init)" ;; esac
shift 2
name="" kind="" to="" count=5 repo="" disk="" confirm=""
while [ $# -gt 0 ]; do
  case "$1" in
    --name)    name=${2:-}; shift 2 ;;
    --kind)    kind=${2:-}; shift 2 ;;
    --to)      to=${2:-}; shift 2 ;;
    --count)   count=${2:-}; shift 2 ;;
    --repo)    repo=${2:-}; shift 2 ;;
    --disk)    disk=${2:-}; shift 2 ;;
    --confirm) confirm=${2:-}; shift 2 ;;
    *) refuse "unknown option $1" ;;
  esac
done

needs=()
case "$action" in
  toggle) [ -n "$name" ] || needs+=(name); [ -n "$kind" ] || needs+=(kind); [ -n "$to" ] || needs+=(to) ;;
  browse) [ -n "$to" ] || needs+=(to) ;;
  offsite-set) [ -n "$repo" ] || needs+=(repo) ;;
  init) [ -n "$disk" ] || needs+=(disk) ;;
esac
if [ ${#needs[@]} -gt 0 ]; then
  printf 'status\tneeds\n'
  printf 'needs\t%s\n' "${needs[@]}"
  exit 2
fi
case "$action" in
  toggle)
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || refuse "invalid name"
    case "$kind" in shares|sensitive|ct) ;; *) refuse "--kind is shares, sensitive or ct" ;; esac
    [ "$to" = on ] || [ "$to" = off ] || refuse "--to is on or off" ;;
  browse) [ "$to" = on ] || [ "$to" = off ] || refuse "--to is on or off" ;;
  offsite-set) { [[ "$repo" =~ ^[A-Za-z0-9/@:._+=,~%-]+$ ]] && [[ "$repo" != -* ]] && [[ "$repo" != *..* ]]; } || refuse "that is not a restic repository address (for example sftp:user@host:/path, b2:bucket:path or a folder)" ;;
  init)   [[ "$disk" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]*$ ]] || refuse "that is not a disk id (see hs sys pool disks)" ;;
  drill)  [[ "$count" =~ ^[0-9]+$ ]] && [ "$count" -ge 1 ] && [ "$count" -le 100 ] || refuse "--count is a number from 1 to 100" ;;
esac

export HS_PLAIN=1 HS_LANG=en HS_CALLER=${HS_CALLER:-ui}
unset HS_GUIDED_TTY

state=$(bash "$backup" --state 2>/dev/null || true)
st() { awk -F'\t' -v k="$1" '$1 == k { print $2 }' <<<"$state"; }
overview=$(bash "$backup" --overview 2>/dev/null || true)
state_dir=${HS_STATE_DIR:-/var/lib/hs}

# the actions that read the backup disk need it set up, the vault open and the disk there
needs_disk() {
  [ "$(st configured)" = yes ] || refuse "The backup is not set up yet (hs backup init <device>)."
  [ "$(st vault)" != closed ] || refuse "The vault is closed: unlock it first (hs unlock)."
  [ "$(st disk)" = present ] || refuse "The backup disk is not plugged in."
}

case "$action" in
  toggle)
    if [ "$kind" = ct ]; then
      ${HS_INCUS:-incus} info "$name" >/dev/null 2>&1 || refuse "There is no instance called '$name'."
      cmd=(bash "$backup" ct "$name" "$to")
    else
      awk -F'\t' -v n="$name" '$1 != "ct" && $1 != "always" && $2 == n { f = 1 } END { exit !f }' <<<"$overview" || refuse "There is no share called '$name'."
      cmd=(bash "$backup" "$name" "$to")
    fi ;;
  now)    needs_disk; cmd=(bash "$backup" now) ;;
  verify) needs_disk; cmd=(bash "$backup" verify) ;;
  prune)  needs_disk; cmd=(bash "$backup" prune) ;;
  drill)  needs_disk; cmd=(bash "$backup" drill "$count") ;;
  init)
    [ "$(st vault)" != closed ] || refuse "The vault is closed: unlock it first (hs unlock)."
    # a disk labelled backup is plugged in: formatting another one would leave two, and init would not touch the first
    [ "$(st disk)" != present ] || refuse "A backup disk is plugged in already (label 'backup'). Unplug it first if you really want to replace it."
    dev=${HS_DISK_BYID:-/dev/disk/by-id}/$disk
    [ -e "$dev" ] || refuse "There is no disk '$disk' (see hs sys pool disks)."
    diskname=$(basename "$(readlink -f "$dev")")
    rc=0
    dry=$(bash "$backup" init "$dev" --dry-run </dev/null 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "status	refused"
      printf '%s\n' "$dry" | sed -e 's/^[[:space:]]*//' -e 's/^✗ *//' -e 's/^! *//' | awk 'NF { print "reason\t" $0 }'
      exit 1
    fi
    cmd=(bash "$backup" init "$dev" --yes) ;;
  offsite-set) needs_disk; cmd=(bash "$backup" offsite set "$repo") ;;
  offsite-now)
    [ -n "$(st offsite)" ] || refuse "There is no off-site repository yet: set one first."
    needs_disk; cmd=(bash "$backup" offsite now) ;;
  offsite-off)
    [ -n "$(st offsite)" ] || refuse "The off-site copy is off already."
    cmd=(bash "$backup" offsite off) ;;
  browse)
    if [ "$to" = on ]; then
      needs_disk
      [ "$(st browse)" != on ] || refuse "Browsing is on already."
      cmd=(bash "$backup" browse)
    else
      [ "$(st browse)" = on ] || refuse "Browsing is off already."
      cmd=(bash "$backup" browse --off)
    fi ;;
esac

if [ "$verb" = start ]; then
  if [ "$action" = init ] && [ "$confirm" != "$diskname" ]; then refuse "type the name of the disk to confirm: $diskname"; fi
  . "$here/lib/job.sh"
  unit=$(hs_job "backup-$action" "hs backup $action" -- "${cmd[@]}") || refuse "the job could not be started"
  printf 'status\tstarted\nunit\t%s\n' "$unit"
  exit 0
fi

echo "status	ok"
case "$action" in
  toggle)
    if [ "$kind" = ct ]; then
      if [ "$to" = on ]; then
        printf 'heading\tput the instance %s into the backup\nstep\tinclude the files of %s in the nightly backup\nnote\tIts files are read from the mounted disk, so they are only backed up while it runs.\n' "$name" "$name"
      else
        printf 'heading\ttake the instance %s out of the backup\nstep\tleave %s out of the nightly backup (existing backups stay until they age out)\n' "$name" "$name"
      fi
    elif [ "$to" = on ]; then
      printf 'heading\tput %s into the backup\nstep\tinclude %s in the nightly backup\n' "$name" "$name"
    else
      printf 'heading\ttake %s out of the backup\nstep\tleave %s out of the nightly backup (existing backups stay until they age out)\n' "$name" "$name"
    fi ;;
  now)
    shares=$(awk -F'\t' '$1 != "ct" && $1 != "always" && $3 == "on" { n++ } END { print n + 0 }' <<<"$overview")
    cts=$(awk -F'\t' '$1 == "ct" && $3 == "on" { n++ } END { print n + 0 }' <<<"$overview")
    printf 'heading\tback up now\nstep\tback up %s share(s) and %s instance(s)\nstep\tback up the domain controller and the host files\nstep\tcopy to the off-site repository if one is set, and prune old snapshots\n' "$shares" "$cts"
    printf 'note\tShares stay usable. The nightly run does the same at 04:00.\n'
    next=${HS_BACKUP_NEXT:-$(st next)}
    if [[ "$next" =~ ^[0-9]+$ ]]; then
      left=$(( next - $(date +%s) ))
      if [ "$left" -ge 0 ] && [ "$left" -le 1800 ]; then
        printf 'warn\tThe nightly backup starts in %s min: it skips while this one holds the repository lock, or runs right after it.\n' "$(( left / 60 ))"
      fi
    fi ;;
  verify)
    printf 'heading\tcheck the stored data\nstep\tread a tenth of the stored data and compare it with its checksums\nnote\tThe backup disk is busy for a while; nothing is changed.\n' ;;
  prune)
    printf 'heading\tgive space back on the backup disk\nstep\tdelete leftovers of a run that ran out of space\nstep\tkeep 7 daily, 4 weekly and 6 monthly snapshots per kind, forget the rest\nstep\tprune the data no snapshot uses any more\nnote\tThe backup disk is busy for a while (the nightly run does this on Sundays). Nothing a kept snapshot needs is deleted.\n' ;;
  drill)
    printf 'heading\trestore drill\nstep\trestore %s random file(s) of the newest shares backup into a temporary folder\nstep\tcompare each with the original and delete the temporary folder\nnote\tThe result counts for the health check (a drill is expected every 45 days).\n' "$count" ;;
  init)
    printf 'heading\tmake %s the backup disk\n' "$diskname"
    printf 'step\terase %s and format it ext4 with the label backup\n' "$diskname"
    if [ -e "$state_dir/restic-password" ]; then printf 'step\tkeep the existing backup password\n'; else printf 'step\tcreate the backup password (root only, inside the vault when there is one)\n'; fi
    printf 'step\tcreate the backup repository on it\n'
    printf '%s\n' "$dry" | awk '/^[ \t]*Disk[ \t]/ { sub(/^[ \t]+/, ""); print "note\t" $0; exit }'
    printf 'note\tAfterwards read the password once with: sudo cat %s/restic-password, and SAVE IT elsewhere: without it a backup cannot be opened, also not after the system disk dies.\n' "$state_dir"
    [ "$(st configured)" != yes ] || printf 'warn\tA backup was set up before: the password is reused, but the old backups are not on this disk.\n' ;;
  offsite-set)
    printf 'heading\tcopy every backup to a second repository\nstep\tuse %s as the off-site repository (created when it does not exist yet, with the same password)\nstep\tcopy every new backup there after each nightly run\n' "$repo"
    case "$repo" in
      s3:*|b2:*|azure:*|gs:*|rest:*|swift:*|rclone:*)
        [ -s "$state_dir/backup-offsite.env" ] || printf 'warn\tThis repository needs credentials: write them into %s/backup-offsite.env first (root only), or creating it fails.\n' "$state_dir" ;;
    esac
    if [ -n "$(st offsite)" ] && [ "$(st offsite)" != "$repo" ]; then printf 'warn\tThe current off-site repository (%s) is replaced; what is there stays there.\n' "$(st offsite)"; fi
    printf 'note\tThe first copy sends the whole backup: that can take a long time and a lot of traffic.\n' ;;
  offsite-now)
    printf 'heading\tcopy to the off-site repository now\nstep\tcopy the backups the off-site repository does not have yet to %s\nnote\tA failed copy only warns: the backup itself is fine.\n' "$(st offsite)" ;;
  offsite-off)
    printf 'heading\tswitch the off-site copy off\nstep\tstop copying to %s\nnote\tWhat is already there stays there.\n' "$(st offsite)" ;;
  browse)
    if [ "$to" = on ]; then
      printf 'heading\tbrowse the backup\nstep\tmount the whole backup read-only\nstep\tpublish it as the share backup-browse (Domain Admins only)\nwarn\tThe backup disk stays mounted until you switch browsing off again.\n'
    else
      printf 'heading\tstop browsing the backup\nstep\tremove the share backup-browse and unmount the backup\n'
    fi ;;
esac
printf 'command\t%s\n' "${cmd[*]}"
if [ "$action" = init ]; then
  printf 'danger\tThis ERASES everything on %s and makes it the backup disk.\nconfirm_name\t%s\n' "$diskname" "$diskname"
fi
case "$action" in toggle|browse|offsite-off|init) printf 'long\tno\n' ;; *) printf 'long\tyes\n' ;; esac
exit 0
