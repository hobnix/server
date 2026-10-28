#!/usr/bin/env bash
# scripts/share-purge.sh (remove a kept folder for good), `share-overview.sh deleted` (the list of kept folders) and
# `backup.sh --snapshots`. Real folders in a temp dir, fake net, zfs and restic: no root, no disks.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en HS_MNT_BULK=$WORK/bulk HS_LOCK=$WORK/lock
unset HS_CALLER HS_GUIDED_TTY
mkdir -p "$WORK/bulk/data-01/shares/docs.deleted-20261001" "$WORK/bulk/data-02/shares/docs.deleted-20261001" "$WORK/bulk/data-01/shares/docs" "$WORK/bulk/data-01/sensitive/old.deleted-20260901"
head -c 1000 /dev/zero > "$WORK/bulk/data-01/shares/docs.deleted-20261001/a"; head -c 500 /dev/zero > "$WORK/bulk/data-02/shares/docs.deleted-20261001/b"
echo snapraid > "$WORK/bulk-type"; export HS_BULK_TYPE_FILE=$WORK/bulk-type
cat > "$WORK/net" <<'FAKE'
#!/usr/bin/env bash
[ "$*" = "conf listshares" ] && printf 'docs\nlive.deleted-20261001\n'
exit 0
FAKE
chmod +x "$WORK/net"; export HS_NET=$WORK/net
P="bash $SCRIPTS/share-purge.sh"

echo "-- only the folders a delete leaves behind"
for bad in docs ../x 'docs.deleted-2026' 'docs.deleted-20261001/../docs' shares; do
  rc=0; $P "$bad" >/dev/null 2>&1 || rc=$?
  check_eq "refuses '$bad'" 1 "$rc"
done
check_out "a name that is still a Samba share" "still a Samba share" $P live.deleted-20261001
check_out "a folder that is not there" "no kept folder" $P nothere.deleted-20261001
check_eq "the live share folder is still there after all the refusals" "yes" "$([ -d "$WORK/bulk/data-01/shares/docs" ] && echo yes)"

echo "-- the dry run lists one command per disk and removes nothing"
check_eq "dry run" "  rm -rf $WORK/bulk/data-01/shares/docs.deleted-20261001
  rm -rf $WORK/bulk/data-02/shares/docs.deleted-20261001" "$($P docs.deleted-20261001 --dry-run)"
check_eq "nothing was removed" "yes yes" "$([ -d "$WORK/bulk/data-01/shares/docs.deleted-20261001" ] && echo yes) $([ -d "$WORK/bulk/data-02/shares/docs.deleted-20261001" ] && echo yes)"

echo "-- the list of kept folders"
O="bash $SCRIPTS/share-overview.sh deleted"
check_eq "one entry per name with its kind and disks (the size is the sum over the disks)" $'docs.deleted-20261001	shares	data-01,data-02
old.deleted-20260901	sensitive	data-01' "$($O | awk -F'	' '{ print $1 "	" $2 "	" $4 }')"
check_eq "the real size of the first" "1500" "$($O | awk -F'\t' '$1 == "docs.deleted-20261001" { print $3 }')"

echo "-- the real run removes the folder on every disk"
check_eq "exit 0" 0 "$($P docs.deleted-20261001 >/dev/null 2>&1; echo $?)"
check_eq "both folders are gone" "no no" "$([ -d "$WORK/bulk/data-01/shares/docs.deleted-20261001" ] && echo yes || echo no) $([ -d "$WORK/bulk/data-02/shares/docs.deleted-20261001" ] && echo yes || echo no)"
check_eq "the live share is untouched" "yes" "$([ -d "$WORK/bulk/data-01/shares/docs" ] && echo yes)"
check_eq "the other kept folder is untouched" "yes" "$([ -d "$WORK/bulk/data-01/sensitive/old.deleted-20260901" ] && echo yes)"

echo "-- ZFS: the dataset is destroyed"
echo zfs > "$WORK/bulk-type"
cat > "$WORK/zfs" <<'FAKE'
#!/usr/bin/env bash
echo "zfs $*" >> "$ZLOG"
case "$*" in
  "list -H -o name bulk/shares/z.deleted-20261001") echo bulk/shares/z.deleted-20261001 ;;
  "list -H -p -o name,used -d 1 bulk/shares") printf 'bulk/shares\t9\nbulk/shares/z\t5\nbulk/shares/z.deleted-20261001\t4096\n' ;;
  "list -H -p -o name,used -d 1 bulk/sensitive") ;;
  "destroy"*) ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$WORK/zfs"; export HS_ZFS=$WORK/zfs ZLOG=$WORK/zlog; : > "$ZLOG"
check_eq "dry run" "  zfs destroy -r bulk/shares/z.deleted-20261001" "$($P z.deleted-20261001 --dry-run)"
check_eq "the list" $'z.deleted-20261001\tshares\t4096\tbulk' "$($O)"
$P z.deleted-20261001 >/dev/null 2>&1
grep -q "destroy -r bulk/shares/z.deleted-20261001" "$ZLOG" && pass "zfs destroy -r on the dataset" || fail "zfs calls: $(cat "$ZLOG")"

echo "-- the snapshots of the backup"
if command -v jq >/dev/null 2>&1; then
  mkdir -p "$WORK/state" "$WORK/mnt"
  echo pw > "$WORK/state/restic-password"; mkdir -p "$WORK/mnt/restic"; echo x > "$WORK/mnt/restic/config"
  cat > "$WORK/restic" <<'FAKE'
#!/usr/bin/env bash
cat <<'JSON'
[{"short_id":"bbbb2222","time":"2026-10-08T03:00:01.123Z","tags":["shares"]},{"short_id":"aaaa1111","time":"2026-10-07T03:00:00.5Z","tags":["shares"]}]
JSON
FAKE
  chmod +x "$WORK/restic"
  out=$(PATH="$WORK:$PATH" HS_STATE_DIR=$WORK/state HS_BACKUP_MOUNT=$WORK/mnt HS_BACKUP_NO_MOUNT=1 bash "$SCRIPTS/backup.sh" --snapshots 2>&1) || true
  check_eq "oldest first: id, time, tags" $'aaaa1111\t2026-10-07 03:00\tshares\nbbbb2222\t2026-10-08 03:00\tshares' "$out"
else
  skip "jq is not installed: backup --snapshots not tested"
fi
finish
