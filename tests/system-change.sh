#!/usr/bin/env bash
# hs sys system plan|start (scripts/system-change.sh): updating the parity and a scrub as data and as a job.
# Fake zpool, bulk-sync and systemd-run: no root, no disks.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en
unset HS_CALLER HS_GUIDED_TTY
BIN=$WORK/bin; mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/jobcalls"\n' "$WORK" > "$BIN/systemd-run"; chmod +x "$BIN/systemd-run"
export PATH="$BIN:$PATH"
cat > "$WORK/zpool" <<'FAKE'
#!/usr/bin/env bash
case "$1 $2" in
  "list -H") [ "$5" = fast ] || [ "$5" = bulk ] || [ "$5" = busy ] ;;
  "status busy") echo "  scan: scrub in progress since Thu Oct  8" ;;
  "status "*) echo "  scan: scrub repaired 0B in 00:10:00" ;;
esac
FAKE
chmod +x "$WORK/zpool"
export HS_ZPOOL=$WORK/zpool HS_BULK_SYNC=$WORK/sync HS_BULK_TYPE_FILE=$WORK/bulk-type
run() { rc=0; out=$(timeout 20 bash "$SCRIPTS/system-change.sh" "$@" </dev/null 2>/dev/null) || rc=$?; }
has() { grep -q -- "$1" <<<"$out"; }

echo "-- SnapRAID: sync and scrub of the bulk pool"
echo snapraid > "$WORK/bulk-type"
run plan sync
check_eq "sync: exit 0" 0 "$rc"
has '^heading	update the parity of bulk$' && has '^command	bash .*sync$' && has '^long	yes$' && pass "sync: heading, command, long" || fail "sync: $out"
has '^danger\|^confirm_name' && fail "sync is not red" || pass "sync is not red"
run plan scrub
check_eq "scrub without a pool" "2 status	needs
needs	pool" "$rc $out"
run plan scrub --pool bulk
has '^heading	check part of the bulk data against the parity$' && has '^command	bash .*sync --scrub$' && pass "scrub of the SnapRAID bulk is bulk-sync --scrub" || fail "scrub bulk: $out"
run plan scrub --pool fast
has '^heading	scrub the pool fast$' && has "^command	.*zpool scrub fast$" && pass "scrub of the fast pool is a zpool scrub" || fail "scrub fast: $out"
run plan scrub --pool nothere
check_eq "a pool that does not exist" 1 "$rc"
run plan scrub --pool busy
check_eq "a scrub that is running already" 1 "$rc"
has "running already" && pass "says so" || fail "running: $out"
run plan scrub --pool 'Bad Name'
check_eq "a bad pool name" 1 "$rc"

echo "-- ZFS: nothing to sync, the bulk pool is a plain zpool scrub"
echo zfs > "$WORK/bulk-type"
run plan sync
check_eq "sync on ZFS is refused" 1 "$rc"
has "nothing to sync" && pass "with the reason" || fail "zfs sync: $out"
run plan scrub --pool bulk
has "^command	.*zpool scrub bulk$" && pass "scrub of a ZFS bulk" || fail "zfs scrub: $out"

echo "-- start"
echo snapraid > "$WORK/bulk-type"
: > "$WORK/jobcalls"
run start sync
check_eq "start: exit 0" 0 "$rc"
has '^status	started$' && has '^unit	hs-job-system-sync-all-' && pass "a job unit" || fail "start: $out"
grep -q 'sync$' "$WORK/jobcalls" && pass "the job runs bulk-sync" || fail "job: $(cat "$WORK/jobcalls")"
run plan frobnicate
check_eq "an unknown action" 1 "$rc"

echo "-- the update: the preview is the plan"
mkdir -p "$WORK/profiles"; touch "$WORK/profiles/system-41-link" "$WORK/profiles/system-42-link" "$WORK/profiles/system-43-link"
cat > "$WORK/preview" <<'FAKE'
#!/usr/bin/env bash
if [ "${PREVIEW_FAILS:-}" = 1 ]; then printf '  ✗ Is there a network connection to the Git server?\n'; exit 1; fi
cat <<'EOT'

── Preview of the update ──
    Fetching what is new (nothing is applied) ...
  ✓ 2 new change(s) from origin/main:
    abc1234 Overview phase 3
    def5678 Fix a thing

       scripts/x.sh | 4 ++--
  ! Local changes in files that change upstream too: hs update would stop.
── New options for machine.toml ──
  ✓ Nothing new: machine.toml has every option
EOT
FAKE
chmod +x "$WORK/preview"; export HS_UPDATE_PREVIEW=$WORK/preview HS_UPDATE=$WORK/update HS_SYSTEM=$WORK/system HS_PROFILES=$WORK/profiles HS_LOCKED_MARKER=$WORK/locked
run plan update
check_eq "update: exit 0" 0 "$rc"
has '^heading	update the server$' && has '^section	Preview of the update$' && has '^note	2 new change(s) from origin/main:$' && has '^text	abc1234 Overview phase 3$' && has '^text	scripts/x.sh | 4 ++--$' && pass "update: the preview becomes plan lines" || fail "update: $out"
has '^warn	Local changes in files that change upstream too' && pass "a checkout that would stop the update is a warning" || fail "update warn: $out"
has 'Fetching what is new' && fail "the spinner line is dropped" || pass "the spinner line is dropped"
has '^command	bash .*update$' && has '^long	yes$' && pass "the job is update.sh, a long one" || fail "update command: $out"
has '^danger\|^confirm_name' && fail "an update is not red" || pass "an update is not red"
PREVIEW_FAILS=1 run plan update
check_eq "no network: refused with the preview's words" 1 "$rc"
has "^reason	Is there a network connection" && pass "reason" || fail "preview fails: $out"
touch "$WORK/locked"
run plan update
check_eq "locked storage: refused" 1 "$rc"
has "storage is locked" && pass "says so" || fail "locked: $out"
rm -f "$WORK/locked"
: > "$WORK/jobcalls"
run start update
check_eq "start update: exit 0" 0 "$rc"
grep -q 'hs system update' "$WORK/jobcalls" && grep -q 'update$' "$WORK/jobcalls" && pass "the job runs update.sh and says what it is" || fail "job: $(cat "$WORK/jobcalls")"

echo "-- rollback is red and needs the word"
run plan rollback
check_eq "rollback: exit 0" 0 "$rc"
has '^danger	The running system goes back to the previous generation' && has '^confirm_name	rollback$' && has '^note	The newest generations: system-43-link, system-42-link, system-41-link$' && pass "red, the word to type, the generations" || fail "rollback: $out"
: > "$WORK/jobcalls"
run start rollback
check_eq "start without the word is refused" 1 "$rc"
[ ! -s "$WORK/jobcalls" ] && pass "no job was started" || fail "a job was started"
run start rollback --confirm rollback
check_eq "start with the word" 0 "$rc"
grep -q 'nixos-rebuild switch --rollback' "$WORK/jobcalls" && pass "the job switches back" || fail "job: $(cat "$WORK/jobcalls")"

echo "-- collecting garbage"
run plan gc
has '^step	delete every generation older than 30 days' && has '^warn	Rolling back further than that is not possible' && has '^long	no$' && pass "gc: the default is 30 days" || fail "gc: $out"
run plan gc --days 7
has 'older than 7 days' && pass "gc --days 7" || fail "gc 7: $out"
run plan gc --days soon
check_eq "a bad number of days" 1 "$rc"
: > "$WORK/jobcalls"
run start gc --days 14
grep -q 'gc 14 --yes' "$WORK/jobcalls" && pass "the job passes --yes (it cannot ask)" || fail "job: $(cat "$WORK/jobcalls")"

echo "-- the registry rows"
check_out "hs sys system plan runs it" "status	ok" env HS_CALLER=test bash "$SCRIPTS/lib/hs.sh" sys system plan sync
finish
