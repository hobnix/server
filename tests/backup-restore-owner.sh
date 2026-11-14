#!/usr/bin/env bash
# hs backup restore: the default re-owns the restored files to adminuser, --keep-owner and --to / (in place) leave the owners
# of the snapshot alone (no root, no disk, a fake restic and a fake chown that only record their calls).
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en HS_BACKUP_NO_MOUNT=1
unset HS_CALLER HS_BACKUP_YES
ST=$WORK/state BULKD=$WORK/bulk
export HS_STATE_DIR=$ST HS_BACKUP_REPO=$WORK/repo HS_BULK=$BULKD CALLS=$WORK/calls
mkdir -p "$ST" "$WORK/repo" "$WORK/bin" "$BULKD/shares/restored"
: > "$WORK/repo/config"
echo pass > "$ST/restic-password"
cat > "$WORK/bin/restic" <<'FAKE'
#!/usr/bin/env bash
# restore ... --target T --include P: create P below T (not for T = /, that is the real system)
args=("$@"); target="" inc=""
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in --target) target=${args[$((i + 1))]} ;; --include) inc=${args[$((i + 1))]} ;; esac
done
case "$*" in *restore*) [ "$target" = / ] || { mkdir -p "$target$(dirname "$inc")"; : > "$target$inc"; } ;; esac
exit 0
FAKE
printf '#!/usr/bin/env bash\necho "chown $*" >> "$CALLS"\n' > "$WORK/bin/chown"
chmod +x "$WORK/bin"/*
export PATH=$WORK/bin:$PATH
hsb() { bash "$SCRIPTS/backup.sh" "$@"; }

echo "-- default: the restored files go to adminuser"
: > "$CALLS"
out=$(hsb restore latest /data/a.txt --to "$BULKD/shares/restored" 2>&1) || true
check_out "restored" "Restored into" echo "$out"
check_eq "chown runs on the restored subtree" "chown -R adminuser:users $BULKD/shares/restored/data/a.txt" "$(head -n 1 "$CALLS")"

echo "-- --keep-owner: no chown"
: > "$CALLS"
out=$(hsb restore latest /data/a.txt --to "$BULKD/shares/restored" --keep-owner 2>&1) || true
check_out "the owners are kept" "Owners kept as in the snapshot" echo "$out"
check_eq "no chown" "0" "$(grep -c chown "$CALLS" || true)"

echo "-- --to / (in place): no chown, the target needs no folder"
: > "$CALLS"
out=$(hsb restore latest /etc --to / 2>&1) || true
check_out "restored in place" "Restored into /" echo "$out"
check_out "the owners are kept" "Owners kept as in the snapshot" echo "$out"
check_eq "no chown" "0" "$(grep -c chown "$CALLS" || true)"
finish
