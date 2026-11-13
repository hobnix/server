#!/usr/bin/env bash
# scripts/manage-users.sh with the local back end (scripts/lib/users-local.sh): users are Unix accounts with a Samba password.
# Fake useradd, userdel, usermod, groupadd, groupdel, gpasswd, smbpasswd, pdbedit and getent on PATH: no root, no Samba.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en HS_USERS_BACKEND=local HS_ADMIN_USER_FILE=$WORK/admin-user HS_NOLOGIN=/test/nologin
unset HS_CALLER HS_GUIDED_TTY
echo adminuser > "$WORK/admin-user"
mkdir -p "$WORK/bin"
export CALLS=$WORK/calls PW=hunter2-secret-pw

# every fake records its argv (one line, fields end with |); smbpasswd also records its stdin and its environment
for tool in useradd userdel usermod groupadd groupdel gpasswd; do
  cat > "$WORK/bin/$tool" <<'FAKE'
#!/usr/bin/env bash
{ printf '%s ' "$(basename "$0")"; printf '%s|' "$@"; echo; } >> "$CALLS"
[ ! -e "$WORK/fail-$(basename "$0")" ] || exit 1
FAKE
done
cat > "$WORK/bin/smbpasswd" <<'FAKE'
#!/usr/bin/env bash
{ printf 'smbpasswd '; printf '%s|' "$@"; echo; } >> "$CALLS"
case " $* " in *" -s "*) cat > "$WORK/smb.stdin" ;; esac
env > "$WORK/smb.env"
[ ! -e "$WORK/fail-smbpasswd" ] || exit 1
FAKE
cat > "$WORK/bin/pdbedit" <<'FAKE'
#!/usr/bin/env bash
cat "$WORK/pdb"
FAKE
cat > "$WORK/bin/getent" <<'FAKE'
#!/usr/bin/env bash
f=$WORK/$1; [ -f "$f" ] || exit 2
if [ $# -eq 1 ]; then cat "$f"; exit 0; fi
grep -m1 "^$2:" "$f" || exit 2
FAKE
chmod +x "$WORK"/bin/*
export PATH=$WORK/bin:$PATH WORK

cat > "$WORK/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/sh
adminuser:x:1000:100:Admin:/home/adminuser:/bin/zsh
anna:x:2000:100:Anna A,,,:/var/empty:/test/nologin
bob:x:2001:100::/var/empty:/test/nologin
EOF
cat > "$WORK/group" <<'EOF'
users:x:100:
sys:x:3:anna
staff:x:2000:anna,bob
empty:x:2001:
EOF
cat > "$WORK/pdb" <<'EOF'
Unix username:        adminuser
NT username:          adminuser
Account Flags:        [U          ]
User SID:             S-1-5-21-1-2-3-1000
---------------
Unix username:        anna
NT username:          anna
Account Flags:        [U          ]
User SID:             S-1-5-21-1-2-3-1001
---------------
Unix username:        bob
NT username:          bob
Account Flags:        [DU         ]
User SID:             S-1-5-21-1-2-3-1002
EOF
MU="bash $SCRIPTS/manage-users.sh"
calls() { cat "$CALLS" 2>/dev/null || true; }
reset() { rm -f "$CALLS" "$WORK"/fail-* "$WORK/smb.stdin" "$WORK/smb.env"; }

echo "-- the back end"
check_eq "knob" local "$(HS_USERS_BACKEND=local bash -c ". $SCRIPTS/lib/users-backend.sh; users_backend")"
check_eq "knob ad" ad "$(HS_USERS_BACKEND=ad bash -c ". $SCRIPTS/lib/users-backend.sh; users_backend")"
printf 'ad\n' > "$WORK/caps"
check_eq "capability ad on" ad "$(HS_USERS_BACKEND= HS_CAPABILITIES_FILE=$WORK/caps bash -c ". $SCRIPTS/lib/users-backend.sh; users_backend")"
: > "$WORK/caps"
check_eq "capability ad off" local "$(HS_USERS_BACKEND= HS_STATE_DIR=$WORK/st HS_CAPABILITIES_FILE=$WORK/caps HS_CAPABILITIES_TSV=/dev/null HS_CAPABILITIES_TSV_OVERLAY=/dev/null bash -c ". $SCRIPTS/lib/users-backend.sh; users_backend")"

echo "-- the lists keep their shape"
check_eq "--list: 4 fields, an empty full name stays empty" $'adminuser\tAdmin\tenabled\t\nanna\tAnna A\tenabled\tstaff\nbob\t\tdisabled\tstaff' "$($MU --list)"
check_eq "--groups: name, members" $'empty\t\nstaff\tanna,bob' "$($MU --groups)"
check_eq "--details user" $'full\tAnna A\nmail\t-\ndescription\t-' "$($MU --details user anna)"
check_eq "--details user without a full name" $'full\t-\nmail\t-\ndescription\t-' "$($MU --details user bob)"
check_eq "--details group" $'description\t-' "$($MU --details group staff)"
check_out "--details unknown user" "No user called 'zed'" $MU --details user zed
check_out "--flush says there is nothing to flush" "Nothing to flush" $MU --flush
check_eq "--flush exits 0" 0 "$($MU --flush >/dev/null 2>&1; echo $?)"

echo "-- add a user: argv, and the password only on standard input"
reset
out=$(printf '%s\n' "$PW" | env -u PW $MU --add dora --full "Dora D" --stdin 2>&1); rc=$?
check_eq "add exits 0" 0 "$rc"
check_eq "useradd then smbpasswd -s -a" $'useradd -K|UID_MIN=2000|-K|UID_MAX=2999|-g|users|-M|-d|/var/empty|-s|/test/nologin|-c|Dora D|--|dora|\nsmbpasswd -s|-a|dora|' "$(calls)"
check_eq "the password reaches smbpasswd twice on stdin" "$(printf '%s\n%s' "$PW" "$PW")" "$(cat "$WORK/smb.stdin")"
check "the password is in no argument" bash -c "! grep -q '$PW' '$CALLS'"
check "the password is not in the environment of smbpasswd" bash -c "! grep -q '$PW' '$WORK/smb.env'"
check "the password is not printed" bash -c "! grep -q '$PW' <<<'$out'"
reset
check_out "no password on stdin" "No password on standard input" bash -c "printf '' | $MU --add dora --stdin"
check_eq "nothing was run without a password" "" "$(calls)"
echo "-- rollback when smbpasswd fails"
reset; : > "$WORK/fail-smbpasswd"
check_out "add fails" "Samba password of 'dora' was not set" bash -c "printf '%s\n' '$PW' | $MU --add dora --stdin"
check_eq "the account is removed again" $'useradd -K|UID_MIN=2000|-K|UID_MAX=2999|-g|users|-M|-d|/var/empty|-s|/test/nologin|-c||--|dora|\nsmbpasswd -s|-a|dora|\nuserdel --|dora|' "$(calls)"
reset
echo "-- names are checked before anything runs"
for bad in 'Anna' '-x' 'a b' '1abc' 'a;b' "$(printf 'a%.0s' $(seq 1 40))"; do
  check_out "refused user name '${bad:0:12}'" "Invalid login name" $MU --add "$bad" --dry-run
done
check_out "a user that exists" "A user called 'anna' exists already" $MU --add anna --dry-run
check_out "refused full name" "Invalid full name" $MU --add dora --full 'x;y' --dry-run
check_out "refused group name with a space" "Invalid group name" $MU --group-add 'my group' --dry-run
check_out "refused group name in capitals" "Invalid group name" $MU --group-add 'Staff' --dry-run
check_eq "no command ran" "" "$(calls)"
echo "-- --dry-run changes nothing"
check_out "add plan" "Create the user 'dora'" $MU --add dora --full "Dora D" --stdin --dry-run
check_out "add plan shows the command" "useradd -K UID_MIN=2000 -K UID_MAX=2999 -g users -M -d /var/empty -s /test/nologin -c Dora..D -- dora" $MU --add dora --full "Dora D" --dry-run
check_out "delete plan" "smbpasswd -x anna" $MU --delete anna --dry-run
check_out "lock plan" "smbpasswd -d anna" $MU --disable anna --dry-run
check_eq "no command ran" "" "$(calls)"

echo "-- password"
reset
out=$(printf '%s\n' "$PW" | env -u PW $MU --password anna --stdin 2>&1); rc=$?
check_eq "password exits 0" 0 "$rc"
check_eq "smbpasswd -s -a anna" "smbpasswd -s|-a|anna|" "$(calls)"
check_eq "stdin twice" "$(printf '%s\n%s' "$PW" "$PW")" "$(cat "$WORK/smb.stdin")"
check "no password in the environment" bash -c "! grep -q '$PW' '$WORK/smb.env'"
check "not printed" bash -c "! grep -q '$PW' <<<'$out'"
check_out "an unknown user" "No user called 'zed'" $MU --password zed --dry-run
reset; : > "$WORK/fail-smbpasswd"
check_out "a refused password" "was not changed" bash -c "printf '%s\n' '$PW' | $MU --password anna --stdin"
reset
echo "-- the admin gets its first Samba password"
sed -i '/^Unix username:        adminuser/,/^-----/d' "$WORK/pdb"
check_out "admin is not in the passdb list" "^anna" $MU --list
check_eq "admin password works without a passdb entry" 0 "$(printf '%s\n' "$PW" | $MU --password adminuser --stdin >/dev/null 2>&1; echo $?)"
check_eq "smbpasswd -s -a adminuser" "smbpasswd -s|-a|adminuser|" "$(calls)"
reset

echo "-- lock and unlock; the admin cannot be locked or deleted"
cat >> "$WORK/pdb" <<'EOF'
---------------
Unix username:        adminuser
Account Flags:        [U          ]
EOF
check_eq "lock" 0 "$($MU --disable anna >/dev/null 2>&1; echo $?)"
check_eq "unlock" 0 "$($MU --enable bob >/dev/null 2>&1; echo $?)"
check_eq "smbpasswd -d / -e" $'smbpasswd -d|anna|\nsmbpasswd -e|bob|' "$(calls)"
reset
check_out "the admin cannot be locked" "admin account" $MU --disable adminuser
check_out "the admin cannot be locked (plan)" "admin account" $MU --disable adminuser --dry-run
check_out "the admin cannot be deleted" "admin account" $MU --delete adminuser --yes
check_eq "nothing ran" "" "$(calls)"
check_out "an account outside uid 2000-2999 is not deleted" "not a share account" bash -c "echo 'carl:x:1500:100::/h:/s' >> '$WORK/passwd'; printf 'Unix username: carl\nAccount Flags: [U]\n' >> '$WORK/pdb'; $MU --delete carl --yes"
check_eq "nothing ran" "" "$(calls)"

echo "-- delete"
check_out "delete asks for the name" "cancelled" bash -c "echo wrong | $MU --delete anna"
check_eq "nothing ran" "" "$(calls)"
check_out "delete --yes" "User 'anna' deleted" $MU --delete anna --yes
check_eq "smbpasswd -x, then userdel" $'smbpasswd -x|anna|\nuserdel --|anna|' "$(calls)"
reset
check_out "unknown user" "No user called 'zed'" $MU --delete zed --yes

echo "-- groups"
check_out "group add" "Group 'team' created" $MU --group-add team
check_eq "groupadd argv" "groupadd -K|GID_MIN=2000|-K|GID_MAX=2999|--|team|" "$(calls)"
reset
check_out "a group that exists" "A group called 'staff' exists already" $MU --group-add staff
check_out "group delete --yes" "Group 'staff' deleted" $MU --group-delete staff --yes
check_eq "groupdel argv" "groupdel --|staff|" "$(calls)"
reset
check_out "a system group is not ours" "No group called 'users'" $MU --group-delete users --yes
check_out "member add" "'bob' is now in 'empty'" $MU --member empty bob add
check_out "member remove" "'bob' is no longer in 'staff'" $MU --member staff bob remove
check_eq "gpasswd argv" $'gpasswd -a|bob|--|empty|\ngpasswd -d|bob|--|staff|' "$(calls)"
reset
check_out "member of an unknown group" "No group called 'nope'" $MU --member nope bob add
check_out "an unknown user" "No user called 'zed'" $MU --member staff zed add
check_out "a bad mode" "usage" $MU --member staff bob sideways
check_eq "nothing ran" "" "$(calls)"

echo "-- edit"
check_out "edit --full" "details of 'bob' are changed" $MU --edit user bob --full "Bob B"
check_eq "usermod -c" "usermod -c|Bob B|--|bob|" "$(calls)"
reset
check_out "edit --full - clears" "details of 'bob' are changed" $MU --edit user bob --full -
check_eq "usermod -c empty" "usermod -c||--|bob|" "$(calls)"
reset
check_out "mail is refused" "Only with a domain." $MU --edit user bob --mail a@b.c
check_out "description is refused" "Only with a domain." $MU --edit user bob --description x
check_out "group description is refused" "Only with a domain." $MU --edit group staff --description x
check_out "nothing to change" "Nothing to change" $MU --edit user bob
check_out "a bad full name" "Invalid full name" $MU --edit user bob --full 'a;b'
check_eq "nothing ran" "" "$(calls)"

echo "-- the registry: hs user rows are visible without a domain, flush needs one"
check_eq "flush stays ad" "capability:ad" "$(awk -F'\t' '$2 == "user flush" { n = split($7, f, ","); print f[n] }' "$SCRIPTS/lib/registry.tsv")"
check_eq "add is samba" "capability:samba" "$(awk -F'\t' '$2 == "user add" { n = split($7, f, ","); print f[n] }' "$SCRIPTS/lib/registry.tsv")"
finish
