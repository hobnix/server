#!/usr/bin/env bash
# hs remote: offer / revoke / add / remove / attach / detach / mount-all with stand-ins (no root, no Samba, no mount).
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test
export HS_STATE_DIR=$WORK/state HS_REMOTE_ROOT=$WORK/mnt HS_DOMAIN_SHORT=HOME HS_HOST_NAME=Alpha
mkdir -p "$HS_STATE_DIR" "$WORK/bin"
LOG=$WORK/calls.log; : > "$LOG"; export LOG
USERS=$WORK/users; : > "$USERS"; export USERS

# stand-in for manage-users.sh: --list, --add, --password, --delete, --flush (the password comes on stdin)
cat > "$WORK/bin/users" <<'X'
#!/usr/bin/env bash
case "$1" in
  --list) cat "$USERS" ;;
  --add) read -r pw; echo "$2" >> "$USERS"; echo "add $2 pwlen=${#pw}" >> "$LOG" ;;
  --password) read -r pw; echo "password $2 pwlen=${#pw}" >> "$LOG" ;;
  --delete) grep -vx "$2" "$USERS" > "$USERS.n" || true; mv "$USERS.n" "$USERS"; echo "delete $2 $3" >> "$LOG" ;;
  --flush) echo flush >> "$LOG" ;;
esac
X
cat > "$WORK/bin/perm" <<'X'
#!/usr/bin/env bash
echo "perm $*" >> "$LOG"
X
# mount: records the call and "mounts" by creating a marker; fails while $WORK/peer-off exists
cat > "$WORK/bin/mnt" <<'X'
#!/usr/bin/env bash
[ ! -e "$WORK/peer-off" ] || exit 32
echo "mount $*" >> "$LOG"; touch "$2/.mounted"
X
cat > "$WORK/bin/umnt" <<'X'
#!/usr/bin/env bash
echo "umount $*" >> "$LOG"; rm -f "$1/.mounted"
X
cat > "$WORK/bin/mpt" <<'X'
#!/usr/bin/env bash
[ -e "${2:-$1}/.mounted" ] || [ -e "${1:-}/.mounted" ]
X
cat > "$WORK/bin/inc" <<'X'
#!/usr/bin/env bash
echo "incus $*" >> "$LOG"
case "$1 $2" in
  "info web"|"info jf") exit 0 ;;
  "info "*) exit 1 ;;
  "config device") [ "$3" = get ] && { grep -q "device add $4 $5 " "$LOG"; exit $?; } ;;
esac
exit 0
X
chmod +x "$WORK"/bin/*
export WORK
export HS_MANAGE_USERS=$WORK/bin/users HS_SHARE_PERM=$WORK/bin/perm HS_MOUNT_CMD=$WORK/bin/mnt HS_UMOUNT=$WORK/bin/umnt HS_MOUNTPOINT=$WORK/bin/mpt HS_INCUS=$WORK/bin/inc
R="bash $SCRIPTS/remote.sh"

echo "-- offer"
check_out "needs --peer" "^usage|usage: hs remote" $R offer media
check_out "a bad peer name" "Invalid peer name" $R offer media --peer 'Bad Name' --yes
check_out "without --yes and no terminal" "without --yes" $R offer media --peer bob
out=$($R offer media --peer bob --yes 2>&1)
grep -q "remote-bob" <<<"$out" && pass "names the login" || fail "names the login ($out)"
grep -q "hs remote add alpha alpha.local media --user remote-bob --domain HOME" <<<"$out" && pass "prints the line for the other side" || fail "prints the line ($out)"
grep -q "Password (shown once" <<<"$out" && pass "shows the password once" || fail "shows the password"
check_eq "the login was made with a password" "1" "$(grep -c '^add remote-bob pwlen=[0-9][0-9]' "$LOG")"
check_eq "read access, nothing more" "1" "$(grep -c '^perm media remote-bob=read' "$LOG")"
check_eq "the offer is recorded" "bob	media	remote-bob" "$(cut -f1-3 "$HS_STATE_DIR/remote-offers")"
out=$($R offer media --peer bob --yes 2>&1)
grep -q "Password (shown once" <<<"$out" && fail "a second offer prints no password" || pass "a second offer prints no password"
check_eq "and makes no second login" "1" "$(grep -c '^add ' "$LOG")"
check_eq "the offer is not duplicated" "1" "$(wc -l < "$HS_STATE_DIR/remote-offers" | tr -d ' ')"
check_out "--new-password sets one" "Password \(shown once" $R offer media --peer bob --new-password --yes
check_eq "via --password" "1" "$(grep -c '^password remote-bob' "$LOG")"
out=$($R offer series --peer bob --yes --plain 2>&1)
check_eq "--plain: tagged lines, no box" "" "$(grep -c 'Tell the other person' <<<"$out" | grep -v '^0$' || true)"
grep -q "^offer-result	login	remote-bob" <<<"$out" && pass "--plain: the login" || fail "--plain: the login ($out)"
grep -q "^offer-result	host	alpha.local" <<<"$out" && pass "--plain: the host" || fail "--plain: the host ($out)"
grep -q "^offer-result	password	" <<<"$out" && fail "--plain: no password for an existing login" || pass "--plain: no password for an existing login"
check_eq "two shares for one peer" "2" "$(wc -l < "$HS_STATE_DIR/remote-offers" | tr -d ' ')"

echo "-- revoke"
check_out "an unknown peer" "Nothing is shared with 'zed'" $R revoke zed --yes
$R revoke bob series --yes >/dev/null 2>&1
check_eq "the permission is removed" "1" "$(grep -c '^perm series remote-bob=none' "$LOG")"
check_eq "the login stays while a share is left" "0" "$(grep -c '^delete' "$LOG")"
$R revoke bob --yes >/dev/null 2>&1
check_eq "the last share deletes the login" "1" "$(grep -c '^delete remote-bob --yes' "$LOG")"
check_eq "no offers left" "0" "$(wc -l < "$HS_STATE_DIR/remote-offers" | tr -d ' ')"

echo "-- add"
check_out "needs --user" "usage: hs remote" $R add alpha alpha.local media
check_out "a bad host" "Invalid host" $R add alpha 'a b' media --user remote-bob --yes
out=$(printf 'secretpw\n' | $R add alpha alpha.local media --user remote-bob --domain HOME --stdin --yes 2>&1)
grep -q "Mounted alpha/media" <<<"$out" && pass "mounts" || fail "mounts ($out)"
grep -q "^mount //alpha.local/media $WORK/mnt/alpha/media -o credentials=$HS_STATE_DIR/remote-alpha.cred,vers=3,ro,nosuid,nodev,noexec" "$LOG" && pass "read-only SMB3 with a credentials file" || fail "mount line ($(grep '^mount' "$LOG"))"
check_eq "credentials file" "username=remote-bob|password=secretpw|domain=HOME" "$(paste -sd'|' "$HS_STATE_DIR/remote-alpha.cred")"
touch "$WORK/modeprobe"; chmod 600 "$WORK/modeprobe"   # a Windows workstation's filesystem ignores modes
if [ "$(stat -c %a "$WORK/modeprobe")" = 600 ]; then check_eq "mode 600" "600" "$(stat -c %a "$HS_STATE_DIR/remote-alpha.cred")"; else skip "mode 600 (this filesystem has no modes)"; fi
check_eq "the password is not in the mount call" "0" "$(grep -c secretpw "$LOG")"
check_out "twice is refused" "set up already" bash -c "printf 'x\n' | $R add alpha alpha.local media --user remote-bob --stdin --yes"
check_out "list (machine readable)" "^mount	alpha	media	alpha.local	mounted" $R list

echo "-- mount-all"
rm -f "$WORK/mnt/alpha/media/.mounted"
check_out "mounts again what is missing" "Mounted alpha/media" $R mount-all
touch "$WORK/peer-off"; rm -f "$WORK/mnt/alpha/media/.mounted"
check_eq "a peer that is off does not fail the unit" "0" "$($R mount-all >/dev/null 2>&1; echo $?)"
check_out "and is reported as down" "^mount	alpha	media	alpha.local	down" $R list
rm -f "$WORK/peer-off"
$R mount-all >/dev/null 2>&1
echo "-- a peer that is off at add"
touch "$WORK/peer-off"
out=$(printf 'pw2\n' | $R add beta beta.local films --user remote-x --stdin --yes 2>&1); rc=$?
check_eq "add still succeeds" "0" "$rc"
grep -q "tried every 2 minutes" <<<"$out" && pass "says it keeps trying" || fail "says it keeps trying ($out)"
rm -f "$WORK/peer-off"

echo "-- attach / detach"
check_out "unknown peer" "Nothing is mounted from 'zed'" $R attach zed web
check_out "unknown instance" "No instance called 'nope'" $R attach alpha nope
check_out "attach" "web sees the shares of alpha under /media-alpha" $R attach alpha web
grep -q "device add web remote-alpha disk source=$WORK/mnt/alpha path=/media-alpha recursive=true propagation=rslave" "$LOG" && pass "recursive device with rslave (read-only is the mount)" || fail "device line ($(grep 'device add' "$LOG"))"
check_out "twice is refused" "has the device remote-alpha already" $R attach alpha web
check_out "detach" "Removed from web" $R detach alpha web

echo "-- remove"
check_out "without --yes and no terminal" "without --yes" $R remove alpha
$R remove alpha media --yes >/dev/null 2>&1
check_eq "unmounted" "1" "$(grep -c "^umount $WORK/mnt/alpha/media" "$LOG")"
check_eq "credentials are gone with the last share" "no" "$([ -e "$HS_STATE_DIR/remote-alpha.cred" ] && echo yes || echo no)"
check_out "beta is still there" "beta" $R list

echo "-- through hs"
export HS_COMPLETE_DIR=$WORK/complete
check_out "hs remote list" "^mount	beta" bash "$SCRIPTS/lib/hs.sh" remote list
check_out "hs help remote" "^hs remote offer" bash "$SCRIPTS/lib/hs.sh" help remote

finish
