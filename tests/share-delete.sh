#!/usr/bin/env bash
# scripts/share-delete.sh (the work behind `hs sys shares start <share> delete`) and the delete plan of share-change.sh.
# Fake net, manage-shares and incus: no root, no Samba, no Incus. Needs jq.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en HS_DELETE_STAMP=20261008
unset HS_CALLER HS_GUIDED_TTY
if ! command -v jq >/dev/null 2>&1; then skip "jq is not installed: share-delete tests not run"; finish; exit $?; fi
LOG=$WORK/calls

cat > "$WORK/net" <<'FAKE'
#!/usr/bin/env bash
echo "net $*" >> "$LOG"
case "$*" in
  "conf getparm docs path") echo /bulk/shares/docs ;;
  "conf getparm cached path") echo /bulk/shares/cached ;;
  "conf getparm other path") echo /srv/other ;;
  *"delshare"*) ;;
  *) exit 1 ;;
esac
FAKE
cat > "$WORK/manage" <<'FAKE'
#!/usr/bin/env bash
echo "manage $*" >> "$LOG"
if [ "$1" = cached ]; then echo "Not possible: the upload cache of 'cached' is on; switch it off first." >&2; exit 1; fi
[ "${FAIL_RENAME:-}" = 1 ] && [[ "$*" != *--dry-run* ]] && exit 1
echo "Rename '$1' to '$3':"
exit 0
FAKE
cat > "$WORK/incus" <<'FAKE'
#!/usr/bin/env bash
if [ "$1" = list ]; then
cat <<'JSON'
[
 {"name":"jellyfin","devices":{"media":{"type":"disk","source":"/bulk/shares/docs","path":"/media"}}},
 {"name":"sonarr","devices":{"tv":{"type":"disk","source":"/bulk/shares/docs/tv","path":"/data"},"other":{"type":"disk","source":"/bulk/shares/docs-more","path":"/x"}}},
 {"name":"immich","devices":{"photos":{"type":"disk","source":"/bulk/sensitive/immich","path":"/mnt/immich"}}}
]
JSON
else
  echo "incus $*" >> "$LOG"
fi
FAKE
chmod +x "$WORK/net" "$WORK/manage" "$WORK/incus"
export LOG HS_NET=$WORK/net HS_MANAGE_SHARES=$WORK/manage HS_INCUS=$WORK/incus
D="bash $SCRIPTS/share-delete.sh"

echo "-- the dry run lists the steps and changes nothing"
: > "$LOG"
check_eq "dry run" "  incus config device remove jellyfin media
  incus config device remove sonarr tv
  hs share docs rename docs.deleted-20261008
  net conf delshare docs.deleted-20261008" "$($D docs --dry-run)"
! grep -q '^incus' "$LOG" && pass "no device was touched" || fail "the dry run touched an instance"

echo "-- a refusal changes nothing"
: > "$LOG"
rc=0; out=$($D cached 2>&1) || rc=$?
check_eq "refused while the upload cache is on" 1 "$rc"
echo "$out" | grep -q "upload cache" && pass "with the script's reason" || fail "reason: $out"
! grep -q '^incus\|delshare' "$LOG" && pass "nothing was detached or removed" || fail "a refusal changed something: $(cat "$LOG")"
rc=0; $D other >/dev/null 2>&1 || rc=$?
check_eq "a folder outside /bulk/shares and /bulk/sensitive" 1 "$rc"

echo "-- the real run, in order"
: > "$LOG"
check_eq "exit 0" 0 "$($D docs >/dev/null 2>&1; echo $?)"
check_eq "detach, then rename, then remove the Samba share" "incus config device remove jellyfin media
incus config device remove sonarr tv
manage docs --rename docs.deleted-20261008
net conf delshare docs.deleted-20261008" "$(grep -v 'dry-run\|getparm' "$LOG")"

echo "-- the rename fails after the mounts went"
: > "$LOG"
rc=0; out=$(FAIL_RENAME=1 $D docs 2>&1) || rc=$?
check_eq "exit 1" 1 "$rc"
echo "$out" | grep -q "still published under its old name" && echo "$out" | grep -q "jellyfin:media" && pass "it says what was detached" || fail "message: $out"
! grep -q delshare "$LOG" && pass "and the Samba share is left alone" || fail "delshare ran after a failed rename"

echo "-- the plan in share-change.sh"
export HS_SHARE_DELETE=$WORK/delete HS_SHARE_OVERVIEW=$WORK/overview
cp "$SCRIPTS/share-delete.sh" "$WORK/delete"; sed -i "s|^here=.*|here=$SCRIPTS|" "$WORK/delete"
cat > "$WORK/overview" <<'FAKE'
#!/usr/bin/env bash
[ "$1" = mounts ] && printf 'jellyfin\tmedia\t/media\tro\t/x\nsonarr\ttv\t/data\trw\t/y\n'
exit 0
FAKE
chmod +x "$WORK/overview"
out=$(bash "$SCRIPTS/share-change.sh" plan docs delete 2>&1) || true
echo "$out" | grep -q '^status	ok$' && pass "plan: ok" || fail "plan: $out"
echo "$out" | grep -q '^step	detach media from the instance jellyfin$' && echo "$out" | grep -q '^step	rename the folder' && echo "$out" | grep -q '^step	remove the Samba share$' && pass "plan: the three kinds of step" || fail "steps: $out"
echo "$out" | grep -q "^danger	'docs' disappears from Samba and from the instances that mount it (jellyfin, sonarr)" && echo "$out" | grep -q '^confirm_name	docs$' && pass "plan: red, the name to type, who loses it" || fail "danger: $out"
echo "$out" | grep -q "^note	The folder stays" && pass "plan: says where the files stay" || fail "note: $out"
out=$(bash "$SCRIPTS/share-change.sh" plan cached delete 2>&1) || rc=$?
echo "$out" | grep -q '^status	refused$' && echo "$out" | grep -q 'upload cache' && pass "plan: the refusal of the rename comes through" || fail "refusal: $out"
echo "-- the folder was deleted by hand: only the dead share goes"
mkdir -p "$WORK/bulk/shares" "$WORK/bulk/sensitive"
export HS_BULK=$WORK/bulk HS_LOCK=$WORK/lock HS_LOCKED_FLAG=$WORK/no-such-flag
sed -i 's|/bulk/shares/docs$|'"$WORK"'/bulk/shares/docs|' "$WORK/net" 2>/dev/null || true
cat > "$WORK/net" <<'FAKE'
#!/usr/bin/env bash
echo "net $*" >> "$LOG"
case "$*" in
  "conf getparm gone path") echo "$HS_BULK/shares/gone" ;;
  *"delshare"*) ;;
  *) exit 1 ;;
esac
FAKE
: > "$LOG"
case "$($D gone --dry-run)" in *"net conf delshare gone"*) pass "dry run: just the Samba share" ;; *) fail "gone dry run" ;; esac
! grep -q rename <<<"$($D gone --dry-run)" && pass "no rename step" || fail "rename step for a gone folder"
check_eq "exit 0" 0 "$($D gone >/dev/null 2>&1; echo $?)"
check_eq "only delshare ran" "net conf delshare gone" "$(grep -v 'getparm' "$LOG")"
mkdir "$WORK/bulk/shares/gone"
: > "$LOG"
$D gone >/dev/null 2>&1 || true
grep -q "^manage gone --rename" "$LOG" && pass "folder present: the normal rename path" || fail "folder present, no rename"
unset HS_BULK
finish
