#!/usr/bin/env bash
# hs sys pool plan|start (scripts/pool-change.sh): the plan of a pool change as data, and the change as a background
# job. Runs against the fake zpool, lsblk ... of tests/lib-poolfakes.sh and a fake systemd-run: no root, no disks.
# The contract: never asks, plain key<TAB>value lines, no colour, exit 0 ok / 1 refused /
# 2 something missing, start needs the typed name and keeps the passphrase out of the arguments.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en HS_STATE_DIR=$WORK/state HS_RUN_DIR=$WORK/run
unset HS_CALLER HS_GUIDED_TTY
# shellcheck source=tests/lib-poolfakes.sh
. "$(dirname "$0")/lib-poolfakes.sh"
mkdir -p "$WORK/state"
printf '#!/usr/bin/env bash\nprintf "%%s\n" "$*" >> "%s/jobcalls"; env | grep "^HS_DISK_PASSPHRASE_FILE=" >> "%s/jobcalls" || true\n' "$WORK" "$WORK" > "$BIN/systemd-run"
chmod +x "$BIN/systemd-run"
P="bash $SCRIPTS/pool-change.sh"

plan() {   # plan <layout> <zpool scenario> <args...>: stdout and exit code in $out / $rc, stdin empty
  local layout=$1 sc=$2; shift 2
  echo "$layout" > "$BT"; echo "$sc" > "$SCEN"
  rc=0; out=$(timeout 20 bash "$SCRIPTS/pool-change.sh" "$@" </dev/null 2>/dev/null) || rc=$?
}
has() { grep -q -- "$1" <<<"$out"; }

echo "-- something is missing: exit 2, only status and needs"
plan zfs two plan bulk replace
check_eq "replace without member and disks: exit 2" 2 "$rc"
check_eq "it names both" "status	needs
needs	member
needs	disks" "$out"
plan snapraid one plan bulk add --disks ata-FAKE_sdy
check_eq "snapraid add without a role needs the role" "status	needs
needs	role" "$out"
plan zfs two plan bulk add
check_eq "zfs add needs the disks (no role)" "status	needs
needs	disks" "$out"

echo "-- a plan"
plan zfs two plan bulk replace --member ata-A --disks ata-FAKE_sdy
check_eq "zfs replace is allowed" 0 "$rc"
has '^status	ok$' && pass "status ok" || fail "status ok: $out"
has '^heading	replace ata-A' && pass "heading" || fail "heading: $out"
has '^command	zpool replace bulk ' && pass "the command" || fail "command: $out"
has '^danger	ALL DATA on ata-FAKE_sdy' && pass "danger line" || fail "danger: $out"
has '^confirm_name	ata-A$' && pass "the disk to type" || fail "confirm_name: $out"
has '^long	no$' && pass "zfs replace is not long" || fail "long: $out"
has 'Dry run' && fail "the dry-run line is not part of the plan" || pass "no dry-run line"
plan snapraid one plan bulk replace --member data-02 --disks ata-FAKE_sdy
check_eq "snapraid replace is allowed" 0 "$rc"
has '^step	take the old disk out of the array$' && pass "numbered steps become step lines" || fail "steps: $out"
has '^confirm_name	data-02$' && pass "snapraid confirm name" || fail "confirm: $out"
has '^long	yes$' && pass "snapraid replace is long" || fail "long: $out"
has '^option	filesystem	ext4|xfs|btrfs	ext4$' && pass "filesystem is an option with a default" || fail "option: $out"
plan snapraid one plan bulk add --role data --disks ata-FAKE_sdy
has '^section	Current array$' && pass "the current array is a section" || fail "section: $out"
has '^confirm_name	bulk$' && pass "add confirms the pool name" || fail "add confirm: $out"
plan zfs one plan bulk remove --member ata-A --mode detach
has '^warn	the other disk of mirror-0' && pass "warnings are warn lines" || fail "warn: $out"
has '^option	mode	detach|vdev	detach$' && pass "zfs remove offers the mode" || fail "mode: $out"
if grep -q "$(printf '\033')" <<<"$out"; then fail "no colour codes"; else pass "no colour codes"; fi

echo "-- a refusal: exit 1, the reason, nothing else"
plan zfs two plan bulk convert --member ata-A
check_eq "convert on zfs is refused" 1 "$rc"
has '^status	refused$' && has '^reason	Not possible: convert is for' && pass "status refused and the reason" || fail "refusal: $out"
plan zfs two plan bulk close
check_eq "close without a member needs it" 2 "$rc"
plan zfs two plan bulk close --member ata-A
check_eq "close on zfs is refused" 1 "$rc"
has '^reason	Not possible: close/open is for' && pass "close refusal names the layout" || fail "close refusal: $out"
plan zfs two plan bulk frobnicate
check_eq "an unknown action is refused" 1 "$rc"
plan zfs two plan Bad_Pool add --disks x
check_eq "an invalid pool name is refused" 1 "$rc"

echo "-- start"
: > "$WORK/jobcalls"
plan zfs two start bulk replace --member ata-A --disks ata-FAKE_sdy
check_eq "start without the typed name is refused" 1 "$rc"
has 'type the name to confirm: ata-A' && pass "and says what to type" || fail "start refusal: $out"
[ ! -s "$WORK/jobcalls" ] && pass "no job was started" || fail "a job was started without confirmation"
plan zfs two start bulk replace --member ata-A --disks ata-FAKE_sdy --confirm ata-B
check_eq "the wrong name is refused" 1 "$rc"
plan zfs two start bulk replace --member ata-A --disks ata-FAKE_sdy --confirm ata-A
check_eq "start with the right name: exit 0" 0 "$rc"
has '^status	started$' && has '^unit	hs-job-pool-replace-ata-A-' && pass "a job unit is printed" || fail "start: $out"
grep -q -- "--yes" "$WORK/jobcalls" && grep -q "manage-pool.sh bulk --replace ata-A --disks ata-FAKE_sdy --yes" "$WORK/jobcalls" \
  && pass "the job repeats the command with --yes" || fail "job command: $(cat "$WORK/jobcalls")"
plan zfs two start bulk replace --member ata-A
check_eq "start with missing input: exit 2" 2 "$rc"
: > "$WORK/jobcalls"
echo "-- start with a passphrase"
echo snapraid > "$BT"; echo one > "$SCEN"
rc=0; out=$(printf 'secret pass\nsecond line\n' | bash "$SCRIPTS/pool-change.sh" start bulk add --role data --disks ata-FAKE_sdy --encrypt --confirm bulk 2>/dev/null) || rc=$?
check_eq "start with --encrypt: exit 0" 0 "$rc"
pf=$(grep '^HS_DISK_PASSPHRASE_FILE=' "$WORK/jobcalls" | head -n1 | cut -d= -f2-)
[ -n "$pf" ] && [ "$(cat "$pf" 2>/dev/null)" = "secret pass" ] && pass "the first line is in the file the job gets" || fail "pass file: '$pf'"
case "$(uname -s)" in
  MINGW*|MSYS*) skip "the pass file is 0600 (this filesystem has no modes)" ;;
  *) [ -n "$pf" ] && [ "$(stat -c %a "$pf" 2>/dev/null)" = 600 ] && pass "the file is 0600" || fail "pass file mode" ;;
esac
if grep -q "secret pass" <<<"$(grep -v '^HS_DISK_PASSPHRASE_FILE=' "$WORK/jobcalls")"; then fail "the passphrase is in an argument"; else pass "the passphrase is in no argument"; fi
rc=0; out=$(bash "$SCRIPTS/pool-change.sh" start bulk add --role data --disks ata-FAKE_sdy --encrypt --confirm bulk </dev/null 2>/dev/null) || rc=$?
check_eq "--encrypt without a passphrase is refused" 1 "$rc"

echo "-- through the dispatcher: hs sys pool plan ..."
echo zfs > "$BT"; echo two > "$SCEN"
rc=0; out=$(HS_CALLER=test timeout 30 bash "$SCRIPTS/lib/hs.sh" sys pool plan bulk replace --member ata-A --disks ata-FAKE_sdy </dev/null 2>/dev/null) || rc=$?
check_eq "hs sys pool plan runs pool-change.sh with the words and options" 0 "$rc"
has '^confirm_name	ata-A$' && pass "and prints the plan" || fail "dispatcher: $out"
rc=0; out=$(HS_CALLER=test timeout 30 bash "$SCRIPTS/lib/hs.sh" sys pool plan bulk replace </dev/null 2>/dev/null) || rc=$?
check_eq "missing input is exit 2 through the dispatcher too" 2 "$rc"

echo "-- a disk that holds data: the plan names it and the danger line says so"
cat > "$WORK/standin.sh" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  *--list-disks*) printf 'ata-OLD\t1000204886016\tSSD\tSamsung SSD 860 S1 [encrypted: not this server'"'"'s] [has ext4 files]\nata-BLANK\t1000204886016\tSSD\tWD Blue W1\n' ;;
  *--dry-run*) printf 'Plan:\n  format ata-OLD (1.0TB) as data-04 (ext4)\n\nDry run: nothing changed.\n' ;;
esac
FAKE
echo snapraid > "$BT"
rc=0; out=$(HS_MANAGE_POOL=$WORK/standin.sh bash "$SCRIPTS/pool-change.sh" plan bulk add --role data --disks ata-OLD </dev/null 2>/dev/null) || rc=$?
check_eq "adding the old disk is allowed (it is a plan, nothing is erased yet)" 0 "$rc"
has "^warn	ata-OLD is not empty: encrypted: not this server's, has ext4 files$" && pass "a warn line says what is on it" || fail "warn: $out"
has "^danger	ALL DATA on ata-OLD will be erased.$" && pass "and the danger line makes the review red" || fail "danger: $out"
rc=0; out=$(HS_MANAGE_POOL=$WORK/standin.sh bash "$SCRIPTS/pool-change.sh" plan bulk add --role data --disks ata-BLANK </dev/null 2>/dev/null) || rc=$?
has "^danger	ALL DATA on ata-BLANK will be erased\.$" && pass "a blank disk gets the plain danger line (adding formats it)" || fail "blank: $out"
if grep -q "^warn" <<<"$out"; then fail "a blank disk has no data warning"; else pass "a blank disk has no data warning"; fi
rc=0; out=$(HS_MANAGE_POOL=$WORK/standin.sh bash "$SCRIPTS/pool-change.sh" plan bulk adopt --disks ata-OLD </dev/null 2>/dev/null) || rc=$?
if grep -q "^danger" <<<"$out"; then fail "adopting erases nothing: no danger line"; else pass "adopting erases nothing: no danger line"; fi

echo "-- every typed confirmation honours --yes (a background job has no one to type)"
# the one confirm_name call without assume_yes on its line is the one inside confirm_plan, which sits in `if ! $assume_yes`
n=$(grep -n 'confirm_name ' "$SCRIPTS/manage-pool.sh" | grep -v '^[0-9]*:[[:space:]]*#' | grep -v 'assume_yes' | wc -l | tr -d ' ')
check_eq "only confirm_plan's call has no assume_yes on its line" 1 "$n"
check_out "and that call is inside the --yes guard" "if ! .assume_yes; then" bash -c "grep -B2 'confirm_name \"\$word\"' '$SCRIPTS/manage-pool.sh'"

echo "-- the registry rows"
HS="bash $SCRIPTS/lib/hs.sh"
check_out "sys pool plan is a registry row" "pool-change.sh" grep -h "sys pool plan" "$SCRIPTS/lib/registry.tsv"
check_out "sys pool start is a registry row" "pool-change.sh" grep -h "sys pool start" "$SCRIPTS/lib/registry.tsv"

finish
