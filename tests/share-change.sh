#!/usr/bin/env bash
# hs sys shares plan|start (scripts/share-change.sh): the plan of a share change as data, and the change as a background job.
# Fake manage-shares, backup, share-snap, snapshots-auto, share-overview and systemd-run: no root, no Samba, no ZFS.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en
unset HS_CALLER HS_GUIDED_TTY
BIN=$WORK/bin; mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nprintf "%%s\n" "$*" >> "%s/jobcalls"\n' "$WORK" > "$BIN/systemd-run"; chmod +x "$BIN/systemd-run"
export PATH="$BIN:$PATH"

cat > "$WORK/manage-shares" <<'FAKE'
#!/usr/bin/env bash
share=$1; shift
case "$1" in
  --rename)
    case "$2" in
      media) echo "  ✗ A share called 'media' exists already."; exit 1 ;;
    esac
    printf "Rename '%s' to '%s':\n  dataset  bulk/shares/%s -> bulk/shares/%s\n  Samba    share is replaced\n(dry run, nothing changed)\n" "$share" "$2" "$share" "$2" ;;
  --set)
    case "$*" in
      *S-1-5-21-1-512=read*) echo "! Not possible: nobody would have full access to '$share'"; exit 1 ;;
    esac
    printf "Access to '%s' afterwards:\n  read   Everyone\n  full   HOME\\Domain Admins\n" "$share" ;;
  --cache) printf "Upload cache of '%s' %s:\n  mount a cache folder\n(dry run, nothing changed)\n" "$share" "$2" ;;
esac
FAKE
cat > "$WORK/overview" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  mounts) [ "$2" = docs ] && printf 'jellyfin\tmedia\t/media\tro\t/x\nsonarr\ttv\t/data\trw\t/y\n' ;;
  history) [ "$2" = docs ] && printf 'manual-1\tx\tmanual\t1M\nauto-d-1\ty\tauto\t0B\nauto-d-2\tz\tauto\t0B\n' ;;
  *) printf 'docs\tshares\t/bulk/shares/docs\toff\t5\t\toff\tbulk\t-\nmedia\tshares\t/bulk/shares/media\toff\t5\t\toff\tdata-01\t-\n' ;;
esac
FAKE
chmod +x "$WORK/manage-shares" "$WORK/overview"
export HS_MANAGE_SHARES=$WORK/manage-shares HS_SHARE_OVERVIEW=$WORK/overview HS_BACKUP=$WORK/backup HS_SHARE_SNAP=$WORK/snap HS_SNAPSHOTS_AUTO=$WORK/auto HS_SYNC_SHARES=$WORK/sync

cat > "$WORK/incus" <<'FAKE'
#!/usr/bin/env bash
[ "$1 $2" = "info jellyfin" ]
FAKE
chmod +x "$WORK/incus"; export HS_INCUS=$WORK/incus HS_CREATE_SHARE=$WORK/create
cat > "$WORK/backup" <<'FAKE'
#!/usr/bin/env bash
[ "$1" = --state ] && printf 'configured\tyes\nstatus\tok\n'
exit 0
FAKE
cat > "$WORK/purge" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  gone.deleted-20261001) echo "There is no kept folder called 'gone.deleted-20261001'." >&2; exit 1 ;;
esac
printf '  rm -rf /mnt/bulk/data-01/shares/%s\n  rm -rf /mnt/bulk/data-02/shares/%s\n' "$1" "$1"
FAKE
chmod +x "$WORK/backup" "$WORK/purge"; export HS_SHARE_PURGE=$WORK/purge HS_SHARE_RESTORE=$WORK/restore
run() { rc=0; out=$(timeout 20 bash "$SCRIPTS/share-change.sh" "$@" </dev/null 2>/dev/null) || rc=$?; }
has() { grep -q -- "$1" <<<"$out"; }

echo "-- something is missing: exit 2"
run plan docs backup
check_eq "backup without --to" "2 status	needs
needs	to" "$rc $out"
run plan docs rollback
check_eq "rollback without a snapshot" "2 status	needs
needs	snapshot" "$rc $out"
run plan docs cache --to maybe
check_eq "a bad --to" 1 "$rc"

echo "-- plain changes: no danger, no name"
run plan docs backup --to on
has '^heading	put docs into the backup$' && has "^command	bash .*backup .*docs on$" && pass "backup on" || fail "backup: $out"
has '^danger\|^confirm_name' && fail "backup is not red" || pass "backup is not red"
run plan docs backup --to off
has '^heading	take docs out of the backup$' && pass "backup off says what stays" || fail "backup off: $out"
run plan docs snapshot --label before
has '^command	bash .*snap .*docs snapshot before$' && pass "snapshot with a label" || fail "snapshot: $out"
run plan docs auto --to on
has '^heading	automatic snapshots of docs: on$' && pass "auto on" || fail "auto: $out"
run plan media snapshot
check_eq "snapshots need ZFS (this one is on data-01)" 1 "$rc"
has "SnapRAID" && pass "and says why" || fail "snapshot refusal: $out"
run plan docs repair
has '^long	yes$' && pass "repair is a long job" || fail "repair: $out"

echo "-- rename and cache use the script's own dry run and warn about the instances"
run plan docs rename --to films
check_eq "rename: exit 0" 0 "$rc"
has "^heading	Rename 'docs' to 'films'$" && has '^step	dataset  bulk/shares/docs -> bulk/shares/films$' && pass "rename: heading and steps from the dry run" || fail "rename: $out"
has '^warn	.*jellyfin, sonarr' && pass "rename warns: these instances switch and restart" || fail "rename warn: $out"
has 'dry run' && fail "the dry-run remark is not a step" || pass "the dry-run remark is dropped"
run plan docs rename --to media
check_eq "a taken name is refused with the script's reason" "1" "$rc"
has "^reason	A share called 'media' exists already" && pass "reason" || fail "refusal: $out"
run plan docs cache --to on
has '^warn	These instances restart so they see the cache: jellyfin, sonarr$' && pass "cache warns" || fail "cache: $out"

echo "-- roll back is red"
run plan docs rollback --snapshot manual-1
check_eq "rollback: exit 0" 0 "$rc"
has '^danger	Everything written to .docs. after the snapshot .manual-1. is lost' && has '^confirm_name	docs$' && has '^step	delete the 2 newer snapshot' && pass "danger, name and the newer snapshots" || fail "rollback: $out"
run plan docs rollback --snapshot nope
check_eq "an unknown snapshot" 1 "$rc"

echo "-- start"
run start docs rollback --snapshot manual-1
check_eq "start without the name is refused" 1 "$rc"
[ ! -s "$WORK/jobcalls" ] && pass "no job was started" || fail "a job was started"
run start docs rollback --snapshot manual-1 --confirm docs
check_eq "start with the name: exit 0" 0 "$rc"
has '^unit	hs-job-share-rollback-docs-' && pass "a job unit" || fail "start: $out"
grep -q -- 'rollback manual-1 --yes' "$WORK/jobcalls" && pass "the job passes --yes (it cannot ask)" || fail "job: $(cat "$WORK/jobcalls")"
run start docs backup --to off
check_eq "a plain change starts without a name" 0 "$rc"

echo "-- permissions"
run plan docs perm
check_eq "perm without a change" "2 status	needs
needs	permission" "$rc $out"
run plan docs perm --set S-1-1-0=bogus
check_eq "a bad level is refused" 1 "$rc"
run plan docs perm --set S-1-1-0=read --set S-1-5-21-1-1000=write
check_eq "perm: exit 0" 0 "$rc"
has "^heading	Access to 'docs' afterwards$" && has '^step	read   Everyone$' && has '^note	Permissions are checked when a connection is opened' && pass "perm: the access afterwards, from the script's dry run" || fail "perm: $out"
has '^command	.*docs --set S-1-1-0=read S-1-5-21-1-1000=write$' && pass "both changes in one command" || fail "perm command: $out"
run plan docs perm --set S-1-5-21-1-512=read
check_eq "the script's refusal (nobody would have full access)" 1 "$rc"
has '^reason	Not possible: nobody would have full access' && pass "with its reason" || fail "perm refusal: $out"
run start docs perm --set S-1-1-0=read
check_eq "perm starts without a typed name" 0 "$rc"
grep -q -- '--set S-1-1-0=read' "$WORK/jobcalls" && pass "the job sets it" || fail "job: $(cat "$WORK/jobcalls")"

echo "-- a new share"
run plan newshare add
check_eq "add without a kind" "2 status	needs
needs	kind" "$rc $out"
run plan docs add --kind shares
check_eq "a name that exists" 1 "$rc"
run plan newshare add --kind sensitive --ct nope --path /data
check_eq "an instance that does not exist" 1 "$rc"
run plan newshare add --kind shares --ct jellyfin --path /data --as 1000:100
check_eq "add with a mount: exit 0" 0 "$rc"
has '^heading	create the share newshare$' && has '^step	mount it into jellyfin at /data (user 1000:100 can write)$' && has '^note	A changed user mapping restarts jellyfin' && pass "add: heading, mount, note" || fail "add: $out"
has "^command	.*create newshare --ct jellyfin /data --as 1000:100$" && pass "the command" || fail "add command: $out"
run plan shares add --kind shares
check_eq "a reserved name" 1 "$rc"

echo "-- remove a kept folder for good"
run plan docs purge
check_eq "only a kept folder (name.deleted-date) can be purged" 1 "$rc"
run plan docs.deleted-20261001 purge
check_eq "purge: exit 0" 0 "$rc"
has '^heading	remove the kept folder docs.deleted-20261001 for good$' && has '^step	rm -rf /mnt/bulk/data-01/shares/docs.deleted-20261001$' && has '^step	rm -rf /mnt/bulk/data-02/shares/docs.deleted-20261001$' && pass "purge: a step per disk" || fail "purge: $out"
has '^danger	.docs.deleted-20261001. is removed for good' && has '^confirm_name	docs.deleted-20261001$' && has '^long	yes$' && pass "purge is red, asks the name, is a long job" || fail "purge danger: $out"
run plan gone.deleted-20261001 purge
check_eq "a folder that is not there" 1 "$rc"
has "^reason	There is no kept folder" && pass "with the script's reason" || fail "purge refusal: $out"
run start docs.deleted-20261001 purge
check_eq "start without the name is refused" 1 "$rc"
: > "$WORK/jobcalls"
run start docs.deleted-20261001 purge --confirm docs.deleted-20261001
check_eq "start with the name" 0 "$rc"
grep -q 'purge docs.deleted-20261001' "$WORK/jobcalls" && pass "the job runs share-purge" || fail "job: $(cat "$WORK/jobcalls")"

echo "-- restore from the backup"
run plan docs restore
check_eq "restore without a snapshot" "2 status	needs
needs	snapshot" "$rc $out"
run plan docs restore --snapshot 'a b'
check_eq "a bad snapshot id" 1 "$rc"
run plan docs restore --snapshot latest --path ../etc
check_eq "a path that leaves the share" 1 "$rc"
run plan docs restore --snapshot latest
check_eq "restore: exit 0" 0 "$rc"
has '^heading	restore docs from the backup$' && has '^step	restore the whole share of snapshot latest into the share restored$' && has '^warn	The whole share is restored' && pass "restore: the whole share warns" || fail "restore: $out"
has '^danger' && fail "restore is not red" || pass "restore into restored is not red"
run plan docs restore --snapshot 1a2b3c4d --path photos/2024
has '^step	restore photos/2024 of snapshot 1a2b3c4d into the share restored$' && ! has '^warn' && pass "restore of a folder" || fail "restore folder: $out"
has "^command	.*restore docs photos/2024 --snapshot 1a2b3c4d --yes$" && pass "the job passes --yes" || fail "restore command: $out"
printf '#!/usr/bin/env bash\n[ "$1" = --state ] && printf "configured\tno\n"\nexit 0\n' > "$WORK/backup"
run plan docs restore --snapshot latest
check_eq "refused when the backup is not set up" 1 "$rc"

echo "-- the registry rows"
check_out "hs sys shares plan runs it" "status	ok" env HS_CALLER=test bash "$SCRIPTS/lib/hs.sh" sys shares plan docs backup --to on
finish
