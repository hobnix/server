#!/usr/bin/env bash
# hs update safety net: rollback after a failed switch or a failed check, the rebuild stamp, --yes / terminal / --no-rollback.
# rebuild.sh runs against stand-ins for nixos-rebuild, systemctl, incus and logger (the push messages end in the logger).
# No root, no network. The real switch and the real services are not exercised (see CLAUDE.md).
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test
G="git -c user.name=t -c user.email=t@t -c commit.gpgsign=false"
BIN=$WORK/bin; STATE=$WORK/state; REPO=$WORK/repo; mkdir -p "$BIN" "$STATE" "$WORK/gen-old" "$WORK/gen-new"
export HS_STATE_DIR=$STATE HS_REPO=$REPO HS_MACHINE_FILE=$WORK/none.toml HS_CURRENT_SYSTEM=$WORK/current HS_NOTIFY_URL=
export HS_POST_WAIT=0 HS_POST_TRIES=2 HS_LOCKED_MARKER=$WORK/no-lock FAKE_LOG=$WORK/calls.log PUSH_LOG=$WORK/push.log

git init -q "$REPO"
echo a > "$REPO/f"; ( cd "$REPO" && $G add f && $G commit -q -m one )
HEAD=$(git -C "$REPO" rev-parse HEAD)

cat > "$BIN/nixos-rebuild" <<'FAKE'
#!/usr/bin/env bash
echo "nixos-rebuild $*" >> "$FAKE_LOG"
if [ "$2" = --rollback ]; then
  [ "${FAKE_ROLLBACK_FAILS:-}" = 1 ] && exit 1
  echo gen-old > "$HS_CURRENT_SYSTEM"; exit 0
fi
case "$FAKE_MODE" in
  build-fail) echo "error: build failed" ; exit 1 ;;
  switch-fail) echo gen-new > "$HS_CURRENT_SYSTEM"; echo "activation failed"; exit 1 ;;
  *) echo gen-new > "$HS_CURRENT_SYSTEM"; [ -z "${FAKE_FAILED:-}" ] || echo "$FAKE_FAILED" > "$HS_CURRENT_SYSTEM.failed"; exit 0 ;;
esac
FAKE
cat > "$BIN/systemctl" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  cat) [ "$2" = sshd.service ] && exit 0; [ "$2" = incus.service ] && [ -n "${FAKE_INCUS:-}" ] && exit 0; exit 1 ;;
  is-active) [ "${FAKE_SSHD:-up}" = up ] ;;
  --failed) [ ! -s "$HS_CURRENT_SYSTEM.failed" ] || echo "$(cat "$HS_CURRENT_SYSTEM.failed") loaded failed failed x" ;;
esac
FAKE
cat > "$BIN/incus" <<'FAKE'
#!/usr/bin/env bash
[ "${FAKE_INCUS:-}" = down ] && exit 1; exit 0
FAKE
# the "symlink" /run/current-system is a file holding the generation name (symlinks are copies in Git Bash on Windows)
cat > "$BIN/readlink" <<'FAKE'
#!/usr/bin/env bash
if [ "${*: -1}" = "$HS_CURRENT_SYSTEM" ]; then cat "$HS_CURRENT_SYSTEM"; exit 0; fi
PATH=${PATH#*:} exec readlink "$@"
FAKE
cat > "$BIN/logger" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$PUSH_LOG"
FAKE
# stand-in health check: --keys prints the keys in $WORK/hk.<running generation> (first call after a switch can differ: hk.gen-new.first)
cat > "$WORK/health" <<'FAKE'
#!/usr/bin/env bash
f=$WORK/hk.$(cat "$HS_CURRENT_SYSTEM")
if [ -f "$f.first" ]; then cat "$f.first"; rm -f "$f.first"; exit 0; fi
[ -f "$f" ] && cat "$f"; exit 0
FAKE
chmod +x "$BIN"/* "$WORK/health"
export WORK HS_HEALTH_CHECK=$WORK/health HS_HEALTH_WINDOW=0 HS_HEALTH_INTERVAL=0
export PATH="$BIN:$PATH"

R="bash $SCRIPTS/rebuild.sh"
reset() { echo gen-old > "$HS_CURRENT_SYSTEM"; rm -f "$HS_CURRENT_SYSTEM.failed"; : > "$FAKE_LOG"; : > "$PUSH_LOG"; rm -f "$STATE/last-rebuild-rev" "$WORK"/hk.*; unset FAKE_MODE FAKE_SSHD FAKE_INCUS FAKE_FAILED FAKE_ROLLBACK_FAILS HS_NO_ROLLBACK HS_UPDATE_YES HS_GUIDED_TTY; export FAKE_MODE=ok; }
rollbacks() { grep -c -- '--rollback' "$FAKE_LOG" || true; }
running() { cat "$HS_CURRENT_SYSTEM"; }

echo "-- a good update"
reset; export HS_UPDATE_NOTIFY=1
check "the rebuild succeeds" $R
check_eq "no rollback" 0 "$(rollbacks)"
check_eq "the new generation runs" gen-new "$(running)"
check_eq "the stamp holds the revision" "rev=$HEAD" "$(sed -n 1p "$STATE/last-rebuild-rev" 2>/dev/null)"

echo "-- hs rebuild alone writes the stamp but never rolls back"
reset; unset HS_UPDATE_NOTIFY; export FAKE_MODE=switch-fail
check "the rebuild fails" bash -c "! $R"
check_eq "no rollback without hs update" 0 "$(rollbacks)"
reset; export FAKE_MODE=ok
check "ok" $R
check_eq "stamp written" "rev=$HEAD" "$(sed -n 1p "$STATE/last-rebuild-rev")"
export HS_UPDATE_NOTIFY=1

echo "-- a build that fails changes nothing"
reset; export FAKE_MODE=build-fail
check "the update fails" bash -c "! $R"
check_eq "no rollback" 0 "$(rollbacks)"
check_out "it says nothing was switched" "Nothing was switched" $R
check "no stamp" test ! -e "$STATE/last-rebuild-rev"

echo "-- a switch that breaks half way is rolled back (no terminal)"
reset; export FAKE_MODE=switch-fail
out=$($R 2>&1 || true)
check_eq "one rollback" 1 "$(rollbacks)"
check_eq "the old generation runs again" gen-old "$(running)"
check "the update still fails" bash -c "! $R"
grep -q "update rolled back" "$PUSH_LOG" && pass "push message: rolled back" || fail "push message: rolled back"
check "no stamp after a rollback" test ! -e "$STATE/last-rebuild-rev"

echo "-- sshd down after the switch"
reset; export FAKE_SSHD=down
out=$($R 2>&1 || true)
grep -q "sshd is not running" <<<"$out" && pass "names the reason" || fail "names the reason: $out"
check_eq "rolled back" 1 "$(rollbacks)"
check_eq "old generation" gen-old "$(running)"

echo "-- Incus does not answer"
reset; export FAKE_INCUS=down
out=$($R 2>&1 || true)
grep -q "Incus does not answer" <<<"$out" && pass "names the reason" || fail "names the reason: $out"
check_eq "rolled back" 1 "$(rollbacks)"
reset; export FAKE_INCUS=up
check "Incus answering is fine" $R
check_eq "kept" gen-new "$(running)"

echo "-- a newly failed unit only warns"
reset; export FAKE_FAILED=hs-thing.service
check_out "warned" "failed since the switch: hs-thing.service" $R
check_eq "no rollback" 0 "$(rollbacks)"

echo "-- the health check: a problem that was there before is no reason"
reset; printf 'disk:old
' > "$WORK/hk.gen-old"; printf 'disk:old
config:unbuilt
' > "$WORK/hk.gen-new"
check "old problem and config:* are ignored" $R
check_eq "no rollback" 0 "$(rollbacks)"

echo "-- the health check: a new problem rolls back"
reset; printf 'disk:old
' > "$WORK/hk.gen-old"; printf 'disk:old
backup:failed
' > "$WORK/hk.gen-new"
out=$($R 2>&1 || true)
grep -q "health check reports new problems: backup:failed" <<<"$out" && pass "names the new problem" || fail "names the new problem: $out"
check_eq "rolled back" 1 "$(rollbacks)"
check_eq "old generation" gen-old "$(running)"
grep -q "update rolled back" "$PUSH_LOG" && pass "push message" || fail "push message"

echo "-- the health check: a problem that clears up in the window is fine"
reset; printf 'x:y
' > "$WORK/hk.gen-new.first"; export HS_HEALTH_WINDOW=60 HS_HEALTH_INTERVAL=0
check "gone at the second look" $R
check_eq "no rollback" 0 "$(rollbacks)"
export HS_HEALTH_WINDOW=0

echo "-- the health check: not while the storage is locked, not with --no-rollback, a terminal is asked"
reset; printf 'backup:failed
' > "$WORK/hk.gen-new"; : > "$WORK/locked"
HS_LOCKED_MARKER=$WORK/locked bash -c "$R" >/dev/null 2>&1 || true
check_eq "locked: refused before anything, no rollback" 0 "$(rollbacks)"
reset; printf 'backup:failed
' > "$WORK/hk.gen-new"; export HS_NO_ROLLBACK=1
check "--no-rollback: no check" $R
check_eq "no rollback" 0 "$(rollbacks)"
reset; printf 'backup:failed
' > "$WORK/hk.gen-new"; export HS_GUIDED_TTY=1
echo n | $R >/dev/null 2>&1 || true
check_eq "terminal, answer no: no rollback" 0 "$(rollbacks)"
unset HS_GUIDED_TTY

echo "-- the real health-check.sh --keys sends nothing"
out=$(HS_HEALTH_STATE=$WORK/k.state HS_BACKUP_STATE=$WORK/none HS_HEARTBEAT_URL= bash "$SCRIPTS/health-check.sh" --keys 2>&1 || true)
if grep -qiE "problem\(s\)|No problems found|nothing to send" <<<"$out"; then fail "--keys prints keys only: $out"; else pass "--keys prints keys only"; fi
check "--keys writes no state" test ! -e "$WORK/k.state"

echo "-- --no-rollback"
reset; export FAKE_SSHD=down HS_NO_ROLLBACK=1
check "the update goes on (no check, no rollback)" $R
check_eq "no rollback" 0 "$(rollbacks)"
unset HS_NO_ROLLBACK

echo "-- a terminal is asked"
reset; export FAKE_SSHD=down HS_GUIDED_TTY=1
echo n | $R >/dev/null 2>&1 || true
check_eq "answer no: no rollback" 0 "$(rollbacks)"
grep -q "update not rolled back" "$PUSH_LOG" && pass "push message: not rolled back" || fail "push message: not rolled back"
reset; export FAKE_SSHD=down HS_GUIDED_TTY=1
echo y | $R >/dev/null 2>&1 || true
check_eq "answer yes: rolled back" 1 "$(rollbacks)"
reset; export FAKE_SSHD=down HS_GUIDED_TTY=1 HS_UPDATE_YES=1
$R </dev/null >/dev/null 2>&1 || true
check_eq "--yes: no question, rolled back" 1 "$(rollbacks)"
unset HS_GUIDED_TTY HS_UPDATE_YES

echo "-- the rollback fails too"
reset; export FAKE_SSHD=down FAKE_ROLLBACK_FAILS=1
$R >/dev/null 2>&1 || true
grep -q "ROLLBACK FAILED" "$PUSH_LOG" && pass "loud push message" || fail "loud push message"

echo "-- configuration drift in the health check"
export HS_HEALTH_STATE=$WORK/h.state HS_BACKUP_STATE=$WORK/none HS_HEARTBEAT_URL=
UP=$WORK/up.git; CL=$WORK/clone; PUSHER=$WORK/pusher
git init -q --bare "$UP"; git clone -q "$UP" "$PUSHER" 2>/dev/null
( cd "$PUSHER" && echo a > f && $G add f && $G commit -q -m one && git push -q origin HEAD 2>/dev/null )
git clone -q "$UP" "$CL" 2>/dev/null
export HS_REPO=$CL
hc() { bash "$SCRIPTS/health-check.sh" --dry-run 2>&1 || true; }
rm -f "$STATE/last-rebuild-rev"
out=$(hc); if grep -qE "uncommitted|not pushed|upstream commit|built from" <<<"$out"; then fail "a clean checkout is no problem: $out"; else pass "a clean checkout is no problem"; fi
echo b >> "$CL/f"
check_out "uncommitted changes" "uncommitted changes" hc
git -C "$CL" checkout -q f
( cd "$CL" && echo c > g && $G add g && $G commit -q -m local )
check_out "a local commit that is not pushed" "1 commit\(s\) that are not pushed" hc
( cd "$PUSHER" && echo d > h && $G add h && $G commit -q -m upstream && git push -q origin HEAD 2>/dev/null )
git -C "$CL" fetch -q
check_out "diverged" "1 local and 1 new upstream commit" hc
git -C "$CL" reset -q --hard HEAD~1; git -C "$CL" merge -q --ff-only '@{u}'
out=$(hc); if grep -qE "uncommitted|not pushed|upstream commit" <<<"$out"; then fail "caught up is fine: $out"; else pass "caught up is fine"; fi
printf 'rev=%s\n' "$(git -C "$CL" rev-parse HEAD)" > "$STATE/last-rebuild-rev"
out=$(hc); if grep -q "built from" <<<"$out"; then fail "stamp = HEAD is fine"; else pass "stamp = HEAD is fine"; fi
printf 'rev=%s\n' "$HEAD" > "$STATE/last-rebuild-rev"
check_out "running system older than the checkout" "built from [0-9a-f]{8}, the checkout is at" hc

echo "-- help text"
check_out "update documents the safety net" "rollback" bash "$SCRIPTS/lib/hs.sh" help update

finish
