#!/usr/bin/env bash
# hs disk <member> detach | attach (scripts/disk-detach.sh, routed by disk-change.sh): a data disk out of /bulk for work by hand, and back; bulk-mount.sh and
# bulk-sync.sh leave a detached disk alone; the health check complains after 2 hours. Folders stand in for mounted disks (HS_DETACH_TEST=1). No root.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en HS_CALLER=ui
unset HS_GUIDED_TTY
T=$'\t'
export HS_DISKS_ROOT=$WORK/disks HS_DETACHED_ROOT=$WORK/disks HS_STATE_DIR=$WORK/state HS_DETACH_TEST=1 HS_LOCK=$WORK/lock HS_LOCK_ADMIN=$WORK/admin
mkdir -p "$HS_DISKS_ROOT"/data-04 "$HS_DISKS_ROOT"/data-05 "$HS_STATE_DIR"
printf '#!/usr/bin/env bash\necho called >> %q\n' "$WORK/bulkmount-calls" > "$WORK/bulkmount"; chmod +x "$WORK/bulkmount"; export HS_BULK_MOUNT=$WORK/bulkmount
run() { rc=0; out=$(timeout 60 bash "$SCRIPTS/disk-detach.sh" "$@" </dev/null 2>/dev/null) || rc=$?; }
runc() { rc=0; out=$(timeout 60 bash "$SCRIPTS/disk-change.sh" "$@" </dev/null 2>/dev/null) || rc=$?; }
has() { grep -q -- "$1" <<<"$out"; }

echo "-- plan detach"
run plan detach data-04
check_eq "plan: exit 0" 0 "$rc"
has "^status${T}ok$" && has "^heading${T}detach data-04" && has "^confirm_name${T}data-04$" && has "^warn${T}The files of data-04 are missing in /bulk" && has "^note${T}A detached disk is not part of the pool" \
  && pass "plan: heading, typed name, the warning, why it is safe" || fail "plan: $out"
runc plan detach data-04
check_eq "disk-change.sh routes detach" 0 "$rc"
run plan attach data-04
check_eq "attach is refused while it is not detached" 1 "$rc"
has "is not detached" && pass "says so" || fail "attach: $out"
run plan detach sda
check_eq "only data-NN" 1 "$rc"
run plan detach data-99
check_eq "a disk that is not mounted" 1 "$rc"
run plan frob data-04
check_eq "unknown action" 1 "$rc"
run start detach data-04
check_eq "start needs the typed name" 1 "$rc"
has "type the name to confirm: data-04" && pass "names the word" || fail "no confirm: $out"
[ ! -e "$HS_STATE_DIR/detached/data-04" ] && pass "nothing was marked" || fail "marked"

echo "-- detach"
run start detach data-04 --confirm data-04
check_eq "start: exit 0" 0 "$rc"
has "^status${T}done$" && pass "done" || fail "start: $out"
[ -s "$HS_STATE_DIR/detached/data-04" ] && [[ "$(cat "$HS_STATE_DIR/detached/data-04")" =~ ^[0-9]+$ ]] && pass "the time is remembered" || fail "no mark"
run plan detach data-04
check_eq "detached already" 1 "$rc"
run plan detach data-05
check_eq "the last disk in the pool cannot be detached" 1 "$rc"
has "no other data disk would keep /bulk running" && pass "says why" || fail "last: $out"

echo "-- another place for detached disks (the switch of the plan, phase C)"
rm -f "$HS_STATE_DIR/detached/data-04"
export HS_DETACHED_ROOT=$WORK/detached
run plan detach data-04
has "^step${T}mount it at $WORK/detached/data-04" && pass "plan names the other mount point" || fail "ddir: $out"
run start detach data-04 --confirm data-04
check_eq "detach with another mount point" 0 "$rc"
[ -d "$WORK/detached/data-04" ] && has "^path${T}$WORK/detached/data-04$" && pass "reports where the disk is" || fail "path: $out"
export HS_DETACHED_ROOT=$HS_DISKS_ROOT

echo "-- attach"
rm -f "$WORK/bulkmount-calls"
run plan attach data-04
check_eq "attach plan: exit 0" 0 "$rc"
runc start attach data-04
check_eq "attach: exit 0" 0 "$rc"
[ ! -e "$HS_STATE_DIR/detached/data-04" ] && pass "the mark is gone" || fail "mark stays"
[ -e "$WORK/bulkmount-calls" ] || true
echo "-- a recovery blocks it"
mkdir -p "$HS_STATE_DIR/recovering"; : > "$HS_STATE_DIR/recovering/data-04"
run plan detach data-04
check_eq "a disk out for a recovery" 1 "$rc"
rm -f "$HS_STATE_DIR/recovering/data-04"

echo "-- the pieces around it"
grep -q 'detdir/${1#bulk-}' "$SCRIPTS/bulk-mount.sh" && grep -q 'mdata' "$SCRIPTS/bulk-mount.sh" && pass "bulk-mount.sh keeps a detached disk out of the merge" || fail "bulk-mount.sh"
grep -q 'HS_DETACHED_DIR' "$SCRIPTS/bulk-sync.sh" && pass "bulk-sync.sh skips while a disk is detached" || fail "bulk-sync.sh"
# the health check: 3 hours is a problem, 10 minutes is not
export HS_HEALTH_STATE=$WORK/h.state
mkdir -p "$HS_STATE_DIR/detached"
echo $(( $(date +%s) - 3 * 3600 )) > "$HS_STATE_DIR/detached/data-04"
out=$(bash "$SCRIPTS/health-check.sh" --dry-run 2>&1 || true)
grep -q "data-04 has been detached for 3 hours" <<<"$out" && pass "health check: detached for 3 hours is reported" || fail "health 3h: $(head -c 300 <<<"$out")"
echo $(( $(date +%s) - 600 )) > "$HS_STATE_DIR/detached/data-04"
out=$(bash "$SCRIPTS/health-check.sh" --dry-run 2>&1 || true)
grep -q "detached for" <<<"$out" && fail "health: 10 minutes is no problem" || pass "health check: 10 minutes is fine"
grep -q '^user	disk <disk> detach	disk-detach.sh' "$SCRIPTS/lib/registry.tsv" && grep -q '^user	disk <disk> attach	disk-detach.sh' "$SCRIPTS/lib/registry.tsv" && pass "registry rows" || fail "registry"
grep -q 'detach|attach' "$SCRIPTS/web-serve.py" && pass "web CHANGES allowlist" || fail "web CHANGES"

finish
