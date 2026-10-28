#!/usr/bin/env bash
# scripts/share-undelete.sh (bring a kept folder <share>.deleted-<date> back as the share <share>, `hs share restore-kept`).
# Real folders in a temp dir, fake net, zfs and sync-shares: no root, no disks. The real runs need flock (util-linux).
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en HS_MNT_BULK=$WORK/bulk HS_LOCK=$WORK/lock HS_STATE_DIR=$WORK/state
unset HS_CALLER HS_GUIDED_TTY
mkdir -p "$WORK/state" "$WORK/bulk/data-01/shares/docs.deleted-20261001" "$WORK/bulk/data-02/shares/docs.deleted-20261001" \
  "$WORK/bulk/data-01/shares/live" "$WORK/bulk/data-01/shares/taken.deleted-20261001" "$WORK/bulk/data-02/shares/taken" \
  "$WORK/bulk/data-01/shares/sh.deleted-20261001" "$WORK/bulk/data-01/shares/netname.deleted-20261001"
echo a > "$WORK/bulk/data-01/shares/docs.deleted-20261001/a"; echo b > "$WORK/bulk/data-02/shares/docs.deleted-20261001/b"
printf 'docs.deleted-20261001\nother\n' > "$WORK/state/backup-off"
echo snapraid > "$WORK/bulk-type"; export HS_BULK_TYPE_FILE=$WORK/bulk-type
cat > "$WORK/net" <<'FAKE'
#!/usr/bin/env bash
[ "$*" = "conf listshares" ] && printf 'live\nnetname\nPhotos\n'
exit 0
FAKE
cat > "$WORK/sync" <<'FAKE'
#!/usr/bin/env bash
echo sync >> "$SYNCLOG"
FAKE
chmod +x "$WORK/net" "$WORK/sync"; export HS_NET=$WORK/net HS_SYNC_SHARES=$WORK/sync SYNCLOG=$WORK/synclog; : > "$SYNCLOG"
P="bash $SCRIPTS/share-undelete.sh"
# no util-linux (Git Bash): a stub flock, the lock itself is not what is tested here
if ! have flock; then mkdir -p "$WORK/stub"; printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/stub/flock"; chmod +x "$WORK/stub/flock"; export PATH="$WORK/stub:$PATH"; fi

echo "-- only the folders a delete leaves behind"
for bad in docs ../x 'docs.deleted-2026' 'docs.deleted-20261001/../docs' shares; do
  rc=0; $P "$bad" >/dev/null 2>&1 || rc=$?
  check_eq "refuses '$bad'" 1 "$rc"
done
rc=0; $P shares.deleted-20261001 >/dev/null 2>&1 || rc=$?
check_eq "a reserved name is refused" 1 "$rc"

echo "-- refusals that change nothing"
check_out "a folder that is not there" "no kept folder" $P nothere.deleted-20261001
check_out "a share of the old name exists (Samba)" "exists already" $P live.deleted-20261001
check_out "the match ignores case" "exists already" $P photos.deleted-20261001
check_out "a folder of the old name on a disk" "has a 'taken' already" $P taken.deleted-20261001
check_eq "the kept folder is still there after the refusals" "yes yes" "$([ -d "$WORK/bulk/data-01/shares/taken.deleted-20261001" ] && echo yes) $([ -d "$WORK/bulk/data-02/shares/taken" ] && echo yes)"

echo "-- the dry run lists one rename per disk and changes nothing"
check_eq "dry run" "  mv $WORK/bulk/data-01/shares/docs.deleted-20261001 $WORK/bulk/data-01/shares/docs
  mv $WORK/bulk/data-02/shares/docs.deleted-20261001 $WORK/bulk/data-02/shares/docs
  hs share repair   (publish docs as a Samba share, Domain Admins only)" "$($P docs.deleted-20261001 --dry-run)"
check_eq "nothing moved" "yes yes no" "$([ -d "$WORK/bulk/data-01/shares/docs.deleted-20261001" ] && echo yes) $([ -d "$WORK/bulk/data-02/shares/docs.deleted-20261001" ] && echo yes) $([ -e "$WORK/bulk/data-01/shares/docs" ] && echo yes || echo no)"

echo "-- the real run renames on every disk, never deletes, and publishes"
if have flock; then
  check_eq "exit 0" 0 "$($P docs.deleted-20261001 >/dev/null 2>&1; echo $?)"
  check_eq "back under the old name on both disks, with the files" "a b" "$(cat "$WORK/bulk/data-01/shares/docs/a") $(cat "$WORK/bulk/data-02/shares/docs/b")"
  check_eq "the kept names are gone (renamed, not copied)" "no no" "$([ -e "$WORK/bulk/data-01/shares/docs.deleted-20261001" ] && echo yes || echo no) $([ -e "$WORK/bulk/data-02/shares/docs.deleted-20261001" ] && echo yes || echo no)"
  check_eq "the other kept folders and live shares are untouched" "yes yes yes" "$([ -d "$WORK/bulk/data-01/shares/taken.deleted-20261001" ] && echo yes) $([ -d "$WORK/bulk/data-01/shares/live" ] && echo yes) $([ -d "$WORK/bulk/data-02/shares/taken" ] && echo yes)"
  check_eq "sync-shares ran once (publishes it)" "sync" "$(cat "$SYNCLOG")"
  check_eq "the backup switch moved back to the old name" $'docs\nother' "$(cat "$WORK/state/backup-off")"
  rc=0; $P docs.deleted-20261001 >/dev/null 2>&1 || rc=$?
  check_eq "a second run finds no kept folder" 1 "$rc"
else
  skip "flock is not installed: the real run is not tested"
fi

echo "-- ZFS: the dataset is renamed"
echo zfs > "$WORK/bulk-type"
cat > "$WORK/zfs" <<'FAKE'
#!/usr/bin/env bash
echo "zfs $*" >> "$ZLOG"
case "$*" in
  "list -H -o name bulk/shares/z.deleted-20261001") echo bulk/shares/z.deleted-20261001 ;;
  "list -H -o name bulk/sensitive/s.deleted-20261001") echo bulk/sensitive/s.deleted-20261001 ;;
  "list -H -o name bulk/shares/y.deleted-20261001") echo bulk/shares/y.deleted-20261001 ;;
  "list -H -o name bulk/shares/y") echo bulk/shares/y ;;
  "rename"*) ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$WORK/zfs"; export HS_ZFS=$WORK/zfs ZLOG=$WORK/zlog; : > "$ZLOG"
check_eq "dry run" $'  zfs rename bulk/shares/z.deleted-20261001 bulk/shares/z\n  hs share repair   (publish z as a Samba share, Domain Admins only)' "$($P z.deleted-20261001 --dry-run)"
check_eq "a sensitive dataset stays sensitive" $'  zfs rename bulk/sensitive/s.deleted-20261001 bulk/sensitive/s\n  hs share repair   (publish s as a Samba share, Domain Admins only)' "$($P s.deleted-20261001 --dry-run)"
check_out "a dataset of the old name exists" "exists already" $P y.deleted-20261001
check_out "no dataset of that kept name" "no kept folder" $P q.deleted-20261001
if have flock; then
  : > "$ZLOG"; $P z.deleted-20261001 >/dev/null 2>&1
  grep -q "rename bulk/shares/z.deleted-20261001 bulk/shares/z" "$ZLOG" && pass "zfs rename of the dataset" || fail "zfs calls: $(cat "$ZLOG")"
  grep -q "destroy" "$ZLOG" && fail "nothing may be destroyed" || pass "no zfs destroy"
fi

echo "-- the plan and the job (share-change.sh)"
cat > "$WORK/overview" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
chmod +x "$WORK/overview"
BIN=$WORK/bin; mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nprintf "%%s\n" "$*" >> "%s/jobcalls"\n' "$WORK" > "$BIN/systemd-run"; chmod +x "$BIN/systemd-run"
export PATH="$BIN:$PATH" HS_SHARE_OVERVIEW=$WORK/overview HS_SHARE_UNDELETE=$SCRIPTS/share-undelete.sh
run() { rc=0; out=$(timeout 20 bash "$SCRIPTS/share-change.sh" "$@" </dev/null 2>/dev/null) || rc=$?; }
has() { grep -q -- "$1" <<<"$out"; }
run plan docs undelete
check_eq "only a kept folder can be brought back" 1 "$rc"
run plan z.deleted-20261001 undelete
check_eq "plan exit 0" 0 "$rc"
has '^heading	bring the kept folder z.deleted-20261001 back as the share z$' && has '^step	zfs rename bulk/shares/z.deleted-20261001 bulk/shares/z$' && has '^step	publish it again as a Samba share$' && pass "plan: heading and steps" || fail "plan: $out"
has '^danger' && fail "restore is not red: $out" || pass "no danger line (nothing is lost)"
has '^note	Nothing is overwritten or removed' && pass "plan says nothing is overwritten" || fail "plan note: $out"
run plan y.deleted-20261001 undelete
check_eq "a taken name is refused in the plan" 1 "$rc"
has '^reason	.*exists already' && pass "with the script's reason" || fail "refusal: $out"
: > "$WORK/jobcalls"
run start z.deleted-20261001 undelete
check_eq "start needs no typed name" 0 "$rc"
grep -q 'share-undelete.sh z.deleted-20261001' "$WORK/jobcalls" && pass "the job runs share-undelete" || fail "job: $(cat "$WORK/jobcalls")"
finish
