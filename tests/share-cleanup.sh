#!/usr/bin/env bash
# scripts/share-cleanup.sh (`hs share cleanup`): removes the Samba shares whose folder is gone. Fake net, no root, no Samba.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en
unset HS_CALLER HS_GUIDED_TTY
LOG=$WORK/calls
B=$WORK/bulk
mkdir -p "$B/shares/docs" "$B/sensitive/keep"

cat > "$WORK/net" <<FAKE
#!/usr/bin/env bash
echo "net \$*" >> "$LOG"
case "\$*" in
  "conf listshares") printf 'docs\nghost\nkeep\nghost2\nother\n' ;;
  "conf getparm docs path") echo $B/shares/docs ;;
  "conf getparm ghost path") echo $B/shares/ghost ;;
  "conf getparm keep path") echo $B/sensitive/keep ;;
  "conf getparm ghost2 path") echo $B/sensitive/ghost2 ;;
  "conf getparm other path") echo /srv/other-gone ;;
  *delshare*) [ "\${FAIL_DEL:-}" = "\$3" ] && exit 1 || exit 0 ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$WORK/net"
export HS_NET=$WORK/net HS_BULK=$B HS_LOCK=$WORK/lock HS_LOCKED_FLAG=$WORK/locked
C="bash $SCRIPTS/share-cleanup.sh"

echo "-- dry run lists only gone folders under /bulk/shares and /bulk/sensitive"
: > "$LOG"
out=$($C --dry-run 2>&1) || true
echo "$out" | grep -q '^ghost ' && echo "$out" | grep -q '^ghost2 ' && pass "both gone shares listed" || fail "list: $out"
echo "$out" | grep -q '^docs \|^keep \|^other ' && fail "listed a share it must not: $out" || pass "existing folders and foreign paths are left out"
! grep -q delshare "$LOG" && pass "dry run removed nothing" || fail "dry run called delshare"

echo "-- a real run with --yes"
: > "$LOG"
check_eq "exit 0" 0 "$($C --yes >/dev/null 2>&1; echo $?)"
check_eq "only the two gone shares are removed" "net conf delshare ghost
net conf delshare ghost2" "$(grep delshare "$LOG")"

echo "-- one removal fails"
rc=0; FAIL_DEL=ghost $C --yes >/dev/null 2>&1 || rc=$?
check_eq "exit 1, the rest still went" 1 "$rc"

echo "-- without a terminal and without --yes it refuses"
: > "$LOG"
rc=0; $C </dev/null >/dev/null 2>&1 || rc=$?
check_eq "refused" 1 "$rc"
! grep -q delshare "$LOG" && pass "nothing removed" || fail "removed without asking"

echo "-- nothing to do"
rm -rf "$B/shares/docs"; mkdir -p "$B/shares/ghost" "$B/sensitive/ghost2" "$B/shares/docs" "$WORK/x"
out=$($C --yes 2>&1); check_eq "exit 0" 0 "$?"
echo "$out" | grep -q "No Samba share points at a folder that is gone" && pass "says so" || fail "msg: $out"

echo "-- locked storage and an unmounted pool change nothing"
: > "$LOG"; touch "$WORK/locked"
rc=0; $C --yes >/dev/null 2>&1 || rc=$?
check_eq "locked: refused" 1 "$rc"
rm -f "$WORK/locked"; rmdir "$B/shares/docs" "$B/shares/ghost"; rmdir "$B/shares"
rc=0; $C --yes >/dev/null 2>&1 || rc=$?
check_eq "no /bulk/shares: refused" 1 "$rc"
! grep -q delshare "$LOG" && pass "nothing removed in both cases" || fail "removed while storage was away"
finish
