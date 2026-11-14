#!/usr/bin/env bash
# hs backup restore --to / on ZFS: the share datasets that are missing are created before restic writes (no root; a fake restic
# that lists share names, a fake zfs and chown that only record their calls).
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en HS_BACKUP_NO_MOUNT=1
unset HS_CALLER HS_BACKUP_YES
ST=$WORK/state BULKD=$WORK/bulk
export HS_STATE_DIR=$ST HS_BACKUP_REPO=$WORK/repo HS_BULK=$BULKD CALLS=$WORK/calls DS=$WORK/datasets
export HS_BULK_TYPE_FILE=$WORK/bulk-type
mkdir -p "$ST" "$WORK/repo" "$WORK/bin" "$BULKD/shares/restored" "$BULKD/shares/full"
: > "$WORK/repo/config"
echo pass > "$ST/restic-password"
echo "x" > "$BULKD/shares/full/file"
cat > "$WORK/bin/restic" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  *" ls "*)
    printf '%s\n' /bulk/shares /bulk/shares/docs /bulk/shares/docs/a.txt /bulk/shares/old /bulk/shares/old.deleted-2026-01-01 \
      /bulk/shares/lost+found /bulk/shares/global /bulk/shares/full /bulk/shares/fine ;;
  *restore*) echo "restore $*" >> "$CALLS" ;;
esac
exit 0
FAKE
cat > "$WORK/bin/zfs" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  list) grep -qxF "${@: -1}" "$DS" ;;
  create) [ -z "${ZFS_FAIL:-}" ] || exit 1; echo "create $*" >> "$CALLS"; echo "${@: -1}" >> "$DS" ;;
esac
FAKE
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/bin/chown"
chmod +x "$WORK/bin"/*
export PATH=$WORK/bin:$PATH
hsb() { bash "$SCRIPTS/backup.sh" "$@"; }
# the fake lists /bulk/..., so the test bulk must be /bulk for the path match: use the paths as given
BULKARG=$BULKD
sed -i "s|/bulk/|$BULKARG/|g" "$WORK/bin/restic"

echo "-- parent restore: only missing, valid names get a dataset"
echo "bulk/shares/fine" > "$DS"; : > "$CALLS"
out=$(hsb restore latest "$BULKD/shares" --to / 2>&1) || true
check_out "plan printed" "bulk/shares/docs" echo "$out"
check_eq "creates docs and old only" "create create -p bulk/shares/docs
create create -p bulk/shares/old" "$(grep '^create' "$CALLS")"
check_eq "full (plain folder with files) is left" "0" "$(grep -c 'shares/full' "$CALLS" || true)"
check_out "full is noted" "plain folder with files" echo "$out"
check_eq "restic restore ran after" "1" "$(grep -c '^restore' "$CALLS")"

echo "-- all there already: nothing created"
: > "$CALLS"
hsb restore latest "$BULKD/shares/docs" --to / >/dev/null 2>&1 || true
check_eq "existing dataset skipped" "0" "$(grep -c '^create' "$CALLS" || true)"

echo "-- one share folder"
: > "$CALLS"; : > "$DS"
hsb restore latest "$BULKD/shares/solo" --to / >/dev/null 2>&1 || true
check_eq "one dataset" "create create -p bulk/shares/solo" "$(grep '^create' "$CALLS")"

echo "-- snapraid: nothing"
echo snapraid > "$HS_BULK_TYPE_FILE"; : > "$CALLS"; : > "$DS"
hsb restore latest "$BULKD/shares" --to / >/dev/null 2>&1 || true
check_eq "no dataset" "0" "$(grep -c '^create' "$CALLS" || true)"
check_eq "restore still ran" "1" "$(grep -c '^restore' "$CALLS")"
rm -f "$HS_BULK_TYPE_FILE"

echo "-- other --to: nothing"
: > "$CALLS"; : > "$DS"
hsb restore latest "$BULKD/shares" --to "$BULKD/shares/restored" >/dev/null 2>&1 || true
check_eq "no dataset" "0" "$(grep -c '^create' "$CALLS" || true)"

echo "-- creation fails: no restore"
: > "$CALLS"; : > "$DS"
out=$(ZFS_FAIL=1 hsb restore latest "$BULKD/shares" --to / 2>&1) || true
check_out "clear message" "Could not create the dataset" echo "$out"
check_eq "restic did not run" "0" "$(grep -c '^restore' "$CALLS" || true)"
finish
