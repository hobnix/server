#!/usr/bin/env bash
# hs sys peers plan|start (scripts/peer-change.sh): shares between two homeservers. add takes the password on stdin; remove and revoke are red
# (the peer is typed). A fake remote.sh stands in: no mounts, no vault.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en
unset HS_CALLER HS_GUIDED_TTY
T=$'\t'
CALLS=$WORK/calls; : > "$CALLS"
cat > "$WORK/remote.sh" <<FAKE
#!/usr/bin/env bash
case "\$1" in
  list) printf 'offer${T}bob${T}films${T}remote-bob${T}given\nmount${T}kim${T}music${T}kim.lan${T}mounted\n' ;;
  offer) echo "\$*" >> "$CALLS"
     printf 'step\tnoise that is not a result\noffer-result\tlogin\tremote-x\noffer-result\thost\tme.local\n'
     case " \$* " in *" --new-password "*|*" series "*) printf 'offer-result\tpassword\tPw123-Aa1\n' ;; esac ;;
  *) pw=""; case " \$* " in *" --stdin "*) IFS= read -r pw || true ;; esac
     echo "\$* [stdin=\$pw]" >> "$CALLS" ;;
esac
FAKE
export HS_REMOTE=$WORK/remote.sh
run() { rc=0; out=$(timeout 20 bash "$SCRIPTS/peer-change.sh" "$@" </dev/null 2>/dev/null) || rc=$?; }
runin() { local in=$1; shift; rc=0; out=$(printf '%s\n' "$in" | timeout 20 bash "$SCRIPTS/peer-change.sh" "$@" 2>/dev/null) || rc=$?; }
has() { grep -q -- "$1" <<<"$out"; }

echo "-- add"
run plan add dan dan.lan films --user alice; check_eq "plan: exit 0" 0 "$rc"
has "mount //dan.lan/films" && pass "names the mount" || fail "$out"
has "^confirm_name" && fail "add is not red" || pass "add needs no typed word"
run plan add kim kim.lan music --user a; check_eq "already set up: refused" 1 "$rc"
run plan add dan dan.lan films; check_eq "no --user: refused" 1 "$rc"
run plan add dan 'bad host' films --user a; check_eq "bad host: refused" 1 "$rc"
: > "$CALLS"; runin 's3cret' start add dan dan.lan films --user alice --domain HOME; check_eq "start: exit 0" 0 "$rc"
grep -q "add dan dan.lan films --user alice --domain HOME --stdin --yes \[stdin=s3cret\]" "$CALLS" && pass "password reached remote.sh on stdin" || fail "calls: $(cat "$CALLS")"
grep -q "s3cret" <<<"$out" && fail "the password must not be in the output" || pass "password not echoed"

echo "-- remove and revoke are red"
run plan remove kim; check_eq "plan: exit 0" 0 "$rc"
has "^confirm_name${T}kim" && pass "asks for the peer name" || fail "$out"
run plan remove nobody; check_eq "unknown peer: refused" 1 "$rc"
run start remove kim; check_eq "no word: refused" 1 "$rc"
run start remove kim --confirm bob; check_eq "wrong word: refused" 1 "$rc"
: > "$CALLS"; run start remove kim --confirm kim; check_eq "right word: exit 0" 0 "$rc"
grep -q "^remove kim --yes" "$CALLS" && pass "remote.sh remove kim --yes" || fail "$(cat "$CALLS")"
run plan revoke bob films; check_eq "revoke: plan ok" 0 "$rc"
has "^confirm_name${T}bob" && pass "revoke is red" || fail "$out"
run plan revoke bob music; check_eq "revoke of a share that was not given: refused" 1 "$rc"
: > "$CALLS"; run start revoke bob films --confirm bob; check_eq "revoke start: exit 0" 0 "$rc"
grep -q "^revoke bob films --yes" "$CALLS" && pass "remote.sh revoke bob films --yes" || fail "$(cat "$CALLS")"

echo "-- attach and detach"
run plan attach kim jellyfin; check_eq "attach plan: exit 0" 0 "$rc"
run plan attach bob jellyfin; check_eq "a peer that is not mounted: refused" 1 "$rc"
: > "$CALLS"; run start attach kim jellyfin --path /media/kim; check_eq "attach start: exit 0" 0 "$rc"
grep -q "^attach kim jellyfin --path /media/kim" "$CALLS" && pass "remote.sh attach" || fail "$(cat "$CALLS")"
: > "$CALLS"; run start detach kim jellyfin; check_eq "detach start: exit 0" 0 "$rc"
grep -q "^detach kim jellyfin" "$CALLS" && pass "remote.sh detach" || fail "$(cat "$CALLS")"

echo "-- offer"
run plan offer dan series; check_eq "plan: exit 0" 0 "$rc"
has "^step${T}make the login remote-dan" && pass "names the login" || fail "$out"
has "^confirm_name" && fail "offer is not red" || pass "offer needs no typed word"
has "Pw123" && fail "the plan must not hold a password" || pass "no password in the plan"
run plan offer bob films; check_eq "offered already: refused" 1 "$rc"
run plan offer bob films --new-password; check_eq "offered already, new password: exit 0" 0 "$rc"
has "^warn${T}A new password is made" && pass "warns about the old password" || fail "$out"
: > "$CALLS"; run start offer dan series; check_eq "start: exit 0" 0 "$rc"
has "^status${T}done" && pass "done" || fail "$out"
has "^secret${T}password${T}Pw123-Aa1" && pass "the password is in the answer" || fail "$out"
has "^secret${T}host${T}me.local" && pass "and the host" || fail "$out"
has "noise" && fail "only tagged lines are passed on" || pass "only the tagged lines are passed on"
grep -qx "offer series --peer dan --plain --yes" "$CALLS" && pass "remote.sh offer --plain --yes" || fail "$(cat "$CALLS")"
run start offer dan films; has "^secret${T}password" && fail "no password when none was made" || pass "no password line without a new one"
run plan offer 'a b' films; check_eq "bad peer: refused" 1 "$rc"

echo "-- bad calls"
run plan remove 'A b'; check_eq "bad peer name: refused" 1 "$rc"
run plan attach kim jellyfin --bogus; check_eq "unknown option: refused" 1 "$rc"
finish
