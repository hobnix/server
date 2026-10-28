#!/usr/bin/env bash
# hs sys backup plan|start (scripts/backup-change.sh): switching entries, back up now, verify, drill and browsing as data and as a job.
# Fake backup.sh, incus and systemd-run: no root, no restic, no disk.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en
unset HS_CALLER GUIDED_TTY HS_GUIDED_TTY
BIN=$WORK/bin; mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/jobcalls"\n' "$WORK" > "$BIN/systemd-run"; chmod +x "$BIN/systemd-run"
export PATH="$BIN:$PATH"
cat > "$WORK/backup" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  --state)
    printf 'configured\t%s\n' "${FAKE_CONFIGURED:-yes}"
    [ -z "${FAKE_CLOSED:-}" ] || printf 'vault\tclosed\n'
    printf 'disk\t%s\nbrowse\t%s\nnext\t%s\noffsite\t%s\n' "${FAKE_DISK:-present}" "${FAKE_BROWSE:-off}" "${FAKE_NEXT:-}" "${FAKE_OFFSITE:-}" ;;
  init)
    [ -z "${FAKE_INIT_FAIL:-}" ] || { printf '  ✗ Refusing: %s is mounted, swap, or part of a pool.\n' "$2"; exit 1; }
    printf '  Backup disk\n  Disk   %s (3.6T ST4000)\n' "$2" ;;
  --overview)
    printf 'shares\tdocs\ton\t5000\nshares\tmedia\toff\t9000\nsensitive\timmich\ton\t-\nct\tweb\ton\t-\nalways\thost files\ton\t-\n' ;;
esac
FAKE
cat > "$WORK/incus" <<'FAKE'
#!/usr/bin/env bash
[ "$1 $2" = "info web" ] || [ "$1 $2" = "info jellyfin" ]
FAKE
chmod +x "$WORK/backup" "$WORK/incus"
export HS_BACKUP=$WORK/backup HS_INCUS=$WORK/incus
run() { rc=0; out=$(timeout 20 bash "$SCRIPTS/backup-change.sh" "$@" </dev/null 2>/dev/null) || rc=$?; }
has() { grep -q -- "$1" <<<"$out"; }
T=$'\t'

echo "-- switching an entry"
run plan toggle
check_eq "toggle without details asks for them" "2 status${T}needs
needs${T}name
needs${T}kind
needs${T}to" "$rc $out"
run plan toggle --name media --kind shares --to on
check_eq "put a share in: exit 0" 0 "$rc"
has "^heading${T}put media into the backup$" && has "^command${T}bash .*backup media on$" && has "^long${T}no$" && pass "share on: heading, command, short" || fail "share on: $out"
has "^danger\|^confirm_name" && fail "no switch is red" || pass "no switch is red"
run plan toggle --name docs --kind shares --to off
has "^heading${T}take docs out of the backup$" && has "existing backups stay" && pass "share off says what stays" || fail "share off: $out"
run plan toggle --name nothere --kind shares --to on
check_eq "an unknown share is refused" 1 "$rc"
run plan toggle --name web --kind ct --to off
has "^command${T}bash .*backup ct web off$" && pass "an instance goes through backup.sh ct" || fail "ct off: $out"
run plan toggle --name web --kind ct --to on
has "only backed up while it runs" && pass "an instance in says it must run" || fail "ct on: $out"
run plan toggle --name ghost --kind ct --to on
check_eq "an unknown instance is refused" 1 "$rc"
run plan toggle --name docs --kind folder --to on
check_eq "a bad kind is refused" 1 "$rc"
run plan toggle --name 'a;b' --kind shares --to on
check_eq "no shell characters in a name" 1 "$rc"
: > "$WORK/jobcalls"
run start toggle --name media --kind shares --to on
check_eq "start toggle: exit 0" 0 "$rc"
grep -q 'hs backup toggle' "$WORK/jobcalls" && grep -q 'backup media on' "$WORK/jobcalls" && pass "the job runs backup.sh and says what it is" || fail "job: $(cat "$WORK/jobcalls")"
has "^unit${T}" && pass "start prints the unit" || fail "unit: $out"

echo "-- back up now"
run plan now
check_eq "now: exit 0" 0 "$rc"
has "^step${T}back up 2 share(s) and 1 instance(s)$" && has "^command${T}bash .*backup now$" && has "^long${T}yes$" && pass "now: counts what is in, a long job" || fail "now: $out"
has '^warn' && fail "no warning far from the timer" || pass "no warning far from the timer"
FAKE_NEXT=$(( $(date +%s) + 600 )) run plan now
has "^warn${T}The nightly backup starts in" && pass "a timer run within 30 minutes is a warning" || fail "timer warn: $out"
FAKE_CONFIGURED=no run plan now
check_eq "not set up: refused" 1 "$rc"
has "hs backup init" && pass "says how to set it up" || fail "not set up: $out"
FAKE_CLOSED=1 run plan now
has "vault is closed" && pass "a closed vault is named" || fail "closed: $out"
FAKE_DISK=absent run plan now
check_eq "no disk: refused" 1 "$rc"
FAKE_DISK=absent run plan toggle --name media --kind shares --to on
check_eq "switching an entry needs no disk" 0 "$rc"

echo "-- verify and drill"
run plan verify
has "^command${T}bash .*backup verify$" && has "^long${T}yes$" && pass "verify" || fail "verify: $out"
run plan prune
has "^command${T}bash .*backup prune$" && has "^long${T}yes$" && has "keep 7 daily" && pass "prune" || fail "prune: $out"
run plan drill
has "restore 5 random file" && has "^command${T}bash .*backup drill 5$" && pass "drill: five files by default" || fail "drill: $out"
run plan drill --count 12
has "^command${T}bash .*backup drill 12$" && pass "drill --count 12" || fail "drill 12: $out"
run plan drill --count many
check_eq "a bad count is refused" 1 "$rc"
: > "$WORK/jobcalls"
run start drill --count 3
grep -q 'backup drill 3' "$WORK/jobcalls" && pass "the drill job" || fail "drill job: $(cat "$WORK/jobcalls")"

echo "-- browsing"
run plan browse
check_eq "browse without on/off asks" "2 status${T}needs
needs${T}to" "$rc $out"
run plan browse --to on
has "^command${T}bash .*backup browse$" && has "^warn${T}The backup disk stays mounted" && has "^long${T}no$" && pass "browse on" || fail "browse on: $out"
FAKE_BROWSE=on run plan browse --to on
check_eq "browsing on already" 1 "$rc"
FAKE_BROWSE=on run plan browse --to off
has "^command${T}bash .*backup browse --off$" && pass "browse off" || fail "browse off: $out"
run plan browse --to off
check_eq "browsing off already" 1 "$rc"

echo "-- the off-site copy"
export HS_STATE_DIR=$WORK/state; mkdir -p "$HS_STATE_DIR"
run plan offsite-set
check_eq "set without an address asks for it" "2 status${T}needs
needs${T}repo" "$rc $out"
run plan offsite-set --repo 'sftp:me@nas:/backup'
check_eq "offsite-set: exit 0" 0 "$rc"
has "^command${T}bash .*backup offsite set sftp:me@nas:/backup$" && has "^step${T}use sftp:me@nas:/backup as the off-site" && has "^note${T}The first copy" && has "^long${T}yes$" && pass "set: command, steps, a first copy takes long" || fail "offsite-set: $out"
has '^warn' && fail "an sftp address needs no credentials file" || pass "an sftp address needs no credentials file"
run plan offsite-set --repo 'b2:bucket:path'
has "^warn${T}This repository needs credentials" && pass "b2 without the credentials file is a warning" || fail "b2: $out"
printf 'B2_ACCOUNT_ID=x\n' > "$HS_STATE_DIR/backup-offsite.env"
run plan offsite-set --repo 'b2:bucket:path'
has '^warn' && fail "no warning once the file exists" || pass "no warning once the file exists"
FAKE_OFFSITE=/mnt/old run plan offsite-set --repo 'sftp:me@nas:/backup'
has "^warn${T}The current off-site repository (/mnt/old) is replaced" && pass "replacing one is said" || fail "replace: $out"
run plan offsite-set --repo 'bad repo;rm'
check_eq "no spaces or shell characters in an address" 1 "$rc"
run plan offsite-set --repo -oextra
check_eq "an address never starts with a dash (no option)" 1 "$rc"
run plan offsite-set --repo /mnt/../etc
check_eq "no .. in an address" 1 "$rc"
FAKE_DISK=absent run plan offsite-set --repo /mnt/other/restic
check_eq "no disk: refused" 1 "$rc"
run plan offsite-now
check_eq "copy now without a repository" 1 "$rc"
FAKE_OFFSITE=/mnt/old run plan offsite-now
has "^command${T}bash .*backup offsite now$" && has "^long${T}yes$" && pass "copy now" || fail "offsite-now: $out"
run plan offsite-off
check_eq "off when it is off" 1 "$rc"
FAKE_OFFSITE=/mnt/old run plan offsite-off
has "^command${T}bash .*backup offsite off$" && has "^long${T}no$" && has "stays there" && pass "off: stays there, short" || fail "offsite-off: $out"
: > "$WORK/jobcalls"
FAKE_OFFSITE=/mnt/old run start offsite-now
grep -q 'backup offsite now' "$WORK/jobcalls" && pass "the copy job" || fail "offsite job: $(cat "$WORK/jobcalls")"

echo "-- setting up the backup disk (red)"
mkdir -p "$WORK/byid"; : > "$WORK/sdz"; ln -sf "$WORK/sdz" "$WORK/byid/ata-ST4000_X"
export HS_DISK_BYID=$WORK/byid
run plan init
check_eq "init without a disk asks for it" "2 status${T}needs
needs${T}disk" "$rc $out"
FAKE_DISK=absent run plan init --disk ata-ST4000_X
check_eq "init: exit 0" 0 "$rc"
has "^heading${T}make sdz the backup disk$" && has "^step${T}erase sdz and format it ext4" && has "^step${T}create the backup repository" && has "^command${T}bash .*backup init .*ata-ST4000_X --yes$" && pass "init: heading, steps, the command with --yes" || fail "init: $out"
has "^danger${T}This ERASES everything on sdz" && has "^confirm_name${T}sdz$" && has "^long${T}no$" && pass "init is red and asks for the kernel name of the disk" || fail "init danger: $out"
has "^note${T}Disk " && has "SAVE IT elsewhere" && pass "the disk line of the dry run and the password hint" || fail "init notes: $out"
FAKE_DISK=absent run plan init --disk nothere
check_eq "an unknown disk is refused" 1 "$rc"
FAKE_DISK=absent run plan init --disk 'a;b'
check_eq "no shell characters in a disk id" 1 "$rc"
run plan init --disk ata-ST4000_X
check_eq "a backup disk is plugged in already: refused" 1 "$rc"
has "plugged in already" && pass "says why" || fail "present: $out"
FAKE_DISK=absent FAKE_INIT_FAIL=1 run plan init --disk ata-ST4000_X
check_eq "a disk that is in use is refused with the script's words" 1 "$rc"
has "^reason${T}Refusing: .* is mounted, swap, or part of a pool" && pass "the reason" || fail "init refusal: $out"
FAKE_CLOSED=1 FAKE_DISK=absent run plan init --disk ata-ST4000_X
has "vault is closed" && pass "a closed vault is named" || fail "init closed: $out"
: > "$WORK/jobcalls"
FAKE_DISK=absent run start init --disk ata-ST4000_X
check_eq "start without the name is refused" 1 "$rc"
[ ! -s "$WORK/jobcalls" ] && pass "no job was started" || fail "a job was started"
FAKE_DISK=absent run start init --disk ata-ST4000_X --confirm sdc
check_eq "the wrong name is refused" 1 "$rc"
FAKE_DISK=absent run start init --disk ata-ST4000_X --confirm sdz
check_eq "start with the disk name" 0 "$rc"
grep -q 'backup init .*ata-ST4000_X --yes' "$WORK/jobcalls" && pass "the job formats with --yes" || fail "init job: $(cat "$WORK/jobcalls")"

echo "-- the usual refusals"
run plan fly
check_eq "an unknown action" 1 "$rc"
run plan now --bogus
check_eq "an unknown option" 1 "$rc"

finish
