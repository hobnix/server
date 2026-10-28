#!/usr/bin/env bash
# hs sys users plan|start (scripts/user-change.sh): lock, unlock, new group, group memberships and the cache flush as data and as a job.
# Fake manage-users and systemd-run: no domain controller, no root.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en
unset HS_CALLER HS_GUIDED_TTY
BIN=$WORK/bin; mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/jobcalls"\n' "$WORK" > "$BIN/systemd-run"; chmod +x "$BIN/systemd-run"
export PATH="$BIN:$PATH"

cat > "$WORK/mu" <<'FAKE'
#!/usr/bin/env bash
echo "mu $*" >> "$WORK/mucalls"
dry=false; a=(); for x in "$@"; do if [ "$x" = --dry-run ]; then dry=true; else a+=("$x"); fi; done
case "${a[0]}" in
  --list)   printf 'anna\tAnna A\tenabled\tStaff\nbob\tBob B\tdisabled\t\nAdministrator\t\tenabled\tDomain Admins\n' ;;
  --groups) printf 'Staff\tanna\nDomain Admins\tAdministrator\nDomain Users\tanna,bob\n' ;;
  --disable)
    if [ "${a[1]}" = Administrator ]; then echo "  ✗ Not possible: locking Administrator would lock you out of the domain."; exit 1; fi
    [ "${a[1]}" = ghost ] && { echo "  ✗ No user called 'ghost'."; exit 1; }
    echo "Lock '${a[1]}': the account stays." ;;
  --enable) echo "Unlock '${a[1]}': it can log in again." ;;
  --group-add)
    [ "${a[1]}" = Staff ] && { echo "  ✗ A group called 'Staff' exists already."; exit 1; }
    echo "Create the group '${a[1]}'." ;;
  --flush)  echo "  net cache flush" ;;
  --member) ;;
esac
FAKE
chmod +x "$WORK/mu"; export WORK HS_MANAGE_USERS=$WORK/mu
run() { rc=0; out=$(timeout 20 bash "$SCRIPTS/user-change.sh" "$@" </dev/null 2>/dev/null) || rc=$?; }
has() { grep -q -- "$1" <<<"$out"; }

echo "-- lock and unlock"
run plan anna lock
check_eq "lock: exit 0" 0 "$rc"
has '^heading	lock anna$' && has '^note	Connections that are already open' && pass "lock: heading and note" || fail "lock: $out"
has '^danger\|^confirm_name' && fail "lock is not red" || pass "lock is not red"
run plan bob unlock
has '^heading	unlock bob$' && pass "unlock" || fail "unlock: $out"
run plan Administrator lock
check_eq "Administrator cannot be locked" 1 "$rc"
has "^reason	locking Administrator would lock you out" && pass "with the script's reason" || fail "refusal: $out"
run plan ghost lock
has "^reason	No user called 'ghost'" && pass "an unknown user" || fail "ghost: $out"

echo "-- a new group and the flush"
run plan Crew group-add
has '^heading	new group Crew$' && pass "new group" || fail "group-add: $out"
run plan Staff group-add
check_eq "a group that exists" 1 "$rc"
run plan - flush
has '^heading	forget cached users$' && pass "flush" || fail "flush: $out"

echo "-- memberships"
run plan anna membership
check_eq "no change" "2 status	needs
needs	change" "$rc $out"
run plan anna membership --change 'anna:Staff=remove' --change 'anna:Crew=add'
check_eq "a group that does not exist" 1 "$rc"
has "^reason	No group called 'Crew'" && pass "named" || fail "crew: $out"
run plan anna membership --change 'bob:Staff=add' --change 'anna:Staff=remove'
check_eq "memberships: exit 0" 0 "$rc"
has '^step	add bob to Staff$' && has '^step	take anna out of Staff$' && pass "a step per change, in order" || fail "membership: $out"
run plan anna membership --change 'bob:Domain Users=add'
check_eq "Domain Users cannot be changed" 1 "$rc"
run plan Administrator membership --change 'Administrator:Domain Admins=remove'
check_eq "Administrator stays in Domain Admins" 1 "$rc"
run plan anna membership --change 'nonsense'
check_eq "a malformed change" 1 "$rc"
: > "$WORK/mucalls"
run plan anna membership --change 'bob:Staff=add' --change 'anna:Staff=remove'
[ "$(grep -c -- '--list\|--groups' "$WORK/mucalls")" = 2 ] && ! grep -q -- '--member' "$WORK/mucalls" && pass "the plan reads the domain twice and runs no --member" || fail "calls: $(cat "$WORK/mucalls")"

echo "-- start"
: > "$WORK/jobcalls"
run start anna lock
check_eq "start: exit 0" 0 "$rc"
has '^unit	hs-job-user-lock-anna-' && pass "a job unit" || fail "start: $out"
grep -q -- '--disable anna' "$WORK/jobcalls" && pass "the job locks the account" || fail "job: $(cat "$WORK/jobcalls")"
: > "$WORK/jobcalls"
run start anna membership --change 'bob:Staff=add'
grep -q -- 'user-change.sh apply bob:Staff=add' "$WORK/jobcalls" && pass "the memberships run through the apply verb" || fail "job: $(cat "$WORK/jobcalls")"

echo "-- apply: in order, then the flush; the first failure stops it"
: > "$WORK/mucalls"
bash "$SCRIPTS/user-change.sh" apply 'bob:Staff=add' 'anna:Staff=remove' >/dev/null
check_eq "member calls in order, then the flush" "mu --member Staff bob add
mu --member Staff anna remove
mu --flush" "$(cat "$WORK/mucalls")"
cat > "$WORK/mu" <<'FAKE'
#!/usr/bin/env bash
echo "mu $*" >> "$WORK/mucalls"
[ "$1 $3" = "--member bob" ] && exit 1
exit 0
FAKE
: > "$WORK/mucalls"
rc=0; bash "$SCRIPTS/user-change.sh" apply 'anna:Staff=add' 'bob:Staff=add' 'anna:Crew=add' >/dev/null 2>&1 || rc=$?
check_eq "a failure stops the job" "1 2" "$rc $(grep -c member "$WORK/mucalls")"
! grep -q -- '--flush' "$WORK/mucalls" && pass "and nothing is flushed" || fail "flushed after a failure"

echo "-- passwords, new users and the deletes (phase 3)"
cat > "$WORK/mu" <<'FAKE'
#!/usr/bin/env bash
echo "mu $*" >> "$WORK/mucalls"
dry=false; stdin=false; a=(); for x in "$@"; do case "$x" in --dry-run) dry=true ;; --stdin) stdin=true ;; *) a+=("$x") ;; esac; done
if $stdin; then cat > "$WORK/stdin-seen"; fi
case "${a[0]}" in
  --list)   printf 'anna\tAnna A\tenabled\tStaff\nAdministrator\t\tenabled\tDomain Admins\n' ;;
  --groups) printf 'Staff\tanna,bob\nDomain Admins\tAdministrator\n' ;;
  --password) [ "${a[1]}" = ghost ] && { echo "  ✗ No user called 'ghost'."; exit 1; }
              $dry && echo "  on dc1: samba-tool user setpassword ${a[1]}   (asks for the new password)" ;;
  --add)
    [ "${a[1]}" = anna ] && { echo "  ✗ A user called 'anna' exists already."; exit 1; }
    [ "${a[1]}" = Bad ] && { echo "  ✗ Invalid login name 'Bad': lowercase letters, digits, . _ -"; exit 1; }
    $dry && echo "Create the user '${a[1]}':" ;;
  --delete)
    [ "${a[1]}" = Administrator ] && { echo "  ✗ Not possible: 'Administrator' is an account the domain needs."; exit 1; }
    $dry && echo "Delete the user '${a[1]}' from the domain." ;;
  --group-delete)
    [ "${a[1]}" = "Domain Admins" ] && { echo "  ✗ Not possible: 'Domain Admins' is a group the domain needs."; exit 1; }
    $dry && echo "Delete the group '${a[1]}'." ;;
esac
exit 0
FAKE
cat > "$WORK/acc" <<'FAKE'
#!/usr/bin/env bash
printf 'media\twrite\tStaff\nprivate\tread\tStaff\n'
FAKE
chmod +x "$WORK/mu" "$WORK/acc"; export HS_USER_ACCESS=$WORK/acc HS_RUN_DIR=$WORK/run
runp() { local pw=$1; shift; rc=0; out=$(printf '%s\n' "$pw" | timeout 20 bash "$SCRIPTS/user-change.sh" "$@" 2>/dev/null) || rc=$?; }

run plan anna password
check_eq "password: exit 0" 0 "$rc"
has '^heading	new password for anna$' && has '^note	The password is typed once' && pass "password plan" || fail "password: $out"
has 'S3cret' && fail "no password appears in a plan" || pass "no password in the plan"
run plan ghost password
check_eq "password for an unknown user" 1 "$rc"
: > "$WORK/jobcalls"
runp 'My S3cret pw!' start anna password
check_eq "start password: exit 0" 0 "$rc"
has '^unit	hs-job-user-password-anna-' && pass "a job unit" || fail "start password: $out"
f=$(grep -o "$WORK/run/user-pass\.[A-Za-z0-9]*" "$WORK/jobcalls" | head -1)
[ -n "$f" ] && pass "the job gets a file, not the password" || fail "file: $(cat "$WORK/jobcalls")"
case "$(uname -s)" in MINGW*|MSYS*) skip "the password file is 0600 (this filesystem has no modes)" ;; *) [ "$(stat -c %a "$f")" = 600 ] && pass "the password file is 0600" || fail "mode: $(stat -c %a "$f")" ;; esac
! grep -q 'S3cret' "$WORK/jobcalls" && pass "the password is not in the job's arguments" || fail "the password is in the job: $(cat "$WORK/jobcalls")"
[ "$(cat "$f")" = 'My S3cret pw!' ] && pass "the file holds it (spaces and all)" || fail "file content"
rc=0; bash "$SCRIPTS/user-change.sh" start anna password </dev/null >/dev/null 2>&1 || rc=$?
check_eq "start without a password on stdin is refused" 1 "$rc"

echo "-- the job reads the file once, deletes it and feeds samba-tool's stdin"
: > "$WORK/mucalls"
bash "$SCRIPTS/user-change.sh" apply-secret password anna "$f"
check_eq "manage-users got --password anna --stdin" "mu --password anna --stdin" "$(cat "$WORK/mucalls")"
check_eq "and the password on its standard input" "My S3cret pw!" "$(cat "$WORK/stdin-seen")"
[ ! -e "$f" ] && pass "the file is gone" || fail "the password file is still there"

echo "-- a new user"
run plan newbie user-add --full 'New Bee'
check_eq "user-add: exit 0" 0 "$rc"
has '^heading	create the user newbie$' && has '^step	create the account (New Bee)$' && has '^step	set its password$' && pass "user-add plan" || fail "user-add: $out"
run plan anna user-add
check_eq "a login that exists" 1 "$rc"
run plan Bad user-add
check_eq "a bad login name" 1 "$rc"
: > "$WORK/jobcalls"
runp 'Pw12345!x' start newbie user-add --full 'New Bee'
check_eq "start user-add: exit 0" 0 "$rc"
grep -q 'apply-secret user-add newbie' "$WORK/jobcalls" && grep -q 'New Bee' "$WORK/jobcalls" && pass "the job knows the login and the full name" || fail "job: $(cat "$WORK/jobcalls")"
f=$(grep -o "$WORK/run/user-pass\.[A-Za-z0-9]*" "$WORK/jobcalls" | head -1)
: > "$WORK/mucalls"
bash "$SCRIPTS/user-change.sh" apply-secret user-add newbie "$f" 'New Bee'
check_eq "manage-users --add with the full name and --stdin" "mu --add newbie --full New Bee --stdin" "$(cat "$WORK/mucalls")"

echo "-- the deletes are red"
run plan anna user-delete
check_eq "user-delete: exit 0" 0 "$rc"
has "^danger	The user 'anna' is deleted from the domain" && has '^confirm_name	anna$' && pass "red, the name to type" || fail "user-delete: $out"
has '^warn	He is in these groups: Staff$' && has '^warn	He reaches these shares: media, private$' && pass "it lists his groups and shares" || fail "user-delete warn: $out"
run plan Administrator user-delete
check_eq "Administrator cannot be deleted" 1 "$rc"
run plan 'Domain Admins' group-delete
check_eq "a group the domain needs" 1 "$rc"
run plan Staff group-delete
has "^danger	The group 'Staff' is deleted" && has '^warn	Members who lose what the group gave them: anna, bob$' && has '^warn	Shares with an entry for the group' && pass "group-delete: red, members and shares listed" || fail "group-delete: $out"
: > "$WORK/jobcalls"
run start anna user-delete
check_eq "start without the name is refused" 1 "$rc"
[ ! -s "$WORK/jobcalls" ] && pass "no job was started" || fail "a job was started"
run start anna user-delete --confirm anna
check_eq "start with the name" 0 "$rc"
grep -q -- '--delete anna --yes' "$WORK/jobcalls" && pass "the job passes --yes (it cannot ask)" || fail "job: $(cat "$WORK/jobcalls")"
run start Staff group-delete --confirm Staff
grep -q -- '--group-delete Staff --yes' "$WORK/jobcalls" && pass "group delete too" || fail "job: $(cat "$WORK/jobcalls")"

echo "-- web forms: a new user with groups, a new group with share access"
cat > "$WORK/ms" <<'FAKE'
#!/usr/bin/env bash
echo "ms $*" >> "$WORK/mscalls"
[ "$1" = --list ] && printf 'media\tshares\t/bulk/shares/media\nprivate\tsensitive\t/x\n'
exit 0
FAKE
cat > "$WORK/wb" <<'FAKE'
#!/usr/bin/env bash
case "$1" in --own-domain) echo HOME ;; -n) echo "wb $*" >> "$WORK/wbcalls"; echo "S-1-5-21-1-2-3-1234 2" ;; esac
FAKE
chmod +x "$WORK/ms" "$WORK/wb"; export HS_MANAGE_SHARES=$WORK/ms HS_WBINFO=$WORK/wb
run plan newbie user-add --group Staff
check_eq "user-add with a group: exit 0" 0 "$rc"
has '^step	add newbie to Staff$' && pass "a step per group" || fail "groups: $out"
run plan newbie user-add --group Nope
check_eq "an unknown group is refused" 1 "$rc"
run plan newbie user-add --group 'Domain Users'
check_eq "Domain Users is refused" 1 "$rc"
run plan anna lock --group Staff
check_eq "--group only for user-add" 1 "$rc"
: > "$WORK/jobcalls"
runp 'Pw12345!x' start newbie user-add --group Staff --group 'Domain Admins'
grep -q 'apply-secret user-add newbie' "$WORK/jobcalls" && grep -q 'Staff Domain Admins' "$WORK/jobcalls" && pass "the job gets the groups after the full name" || fail "job: $(cat "$WORK/jobcalls")"
f=$(grep -o "$WORK/run/user-pass\.[A-Za-z0-9]*" "$WORK/jobcalls" | head -1)
: > "$WORK/mucalls"
bash "$SCRIPTS/user-change.sh" apply-secret user-add newbie "$f" '' Staff 'Domain Admins'
check_eq "add, then each membership, then the flush" "mu --add newbie --stdin
mu --member Staff newbie add
mu --member Domain Admins newbie add
mu --flush" "$(cat "$WORK/mucalls")"

run plan Crew group-add --access media=read --access private=full
check_eq "group-add with access: exit 0" 0 "$rc"
has '^step	give the group read access to media$' && has '^step	give the group full access to private$' && pass "a step per share" || fail "access: $out"
run plan Crew group-add --access nothere=read
check_eq "an unknown share is refused" 1 "$rc"
run plan Crew group-add --access media=none
check_eq "level none is refused" 1 "$rc"
run plan Crew group-add --access 'media=read;ls'
check_eq "a malformed access is refused" 1 "$rc"
run plan anna lock --access media=read
check_eq "--access only for group-add" 1 "$rc"
: > "$WORK/jobcalls"
run start Crew group-add --access media=write
grep -q 'user-change.sh apply-group Crew media=write' "$WORK/jobcalls" && pass "the job is apply-group" || fail "job: $(cat "$WORK/jobcalls")"
: > "$WORK/mucalls"; : > "$WORK/mscalls"
bash "$SCRIPTS/user-change.sh" apply-group Crew media=write private=read >/dev/null
check_eq "create, then set by SID" "ms media --set S-1-5-21-1-2-3-1234=write
ms private --set S-1-5-21-1-2-3-1234=read" "$(cat "$WORK/mscalls")"
grep -q -- '--group-add Crew' "$WORK/mucalls" && pass "the group is created first" || fail "mu: $(cat "$WORK/mucalls")"
grep -qF -- 'HOME\Crew' "$WORK/wbcalls" && pass "the SID is looked up with the domain name" || fail "wb: $(cat "$WORK/wbcalls")"

echo "-- edit the details of a user and a group"
run plan anna user-edit
check_eq "nothing to change is refused" 1 "$rc"
run plan anna user-edit --full 'Anna Muster' --mail - --description 'Front desk'
check_eq "user-edit: exit 0" 0 "$rc"
has '^heading	change the details of anna$' && has '^step	set the full name to Anna Muster$' && has '^step	clear the email$' && has '^step	set the description to Front desk$' && pass "a step per field" || fail "user-edit: $out"
has '^command	.*--edit user anna --full Anna Muster --mail - --description Front desk' && pass "the command carries the fields" || fail "user-edit command: $out"
run plan Staff group-edit --description 'The staff'
has '^step	set the description to The staff$' && pass "group-edit" || fail "group-edit: $out"
run plan Staff group-edit --mail a@b.c
check_eq "a group has no email" 1 "$rc"
run plan anna lock --description x
check_eq "--description only for the edits" 1 "$rc"

echo "-- the registry rows"
check_out "hs sys users plan runs it" "status	ok" env HS_CALLER=test HS_MANAGE_USERS="$WORK/mu" bash "$SCRIPTS/lib/hs.sh" sys users plan anna unlock
finish
