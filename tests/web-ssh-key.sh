#!/usr/bin/env bash
# Web interface: `hs sys ssh-key list|plan|start` (ssh-key.sh --list, ssh-key-change.sh) against a copy of machine.toml. No root; needs ssh-keygen and python3.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test
export HS_MACHINE_FILE=$WORK/machine.toml HS_STATE_DIR=$WORK/state
L="bash $SCRIPTS/ssh-key.sh --list"
C="bash $SCRIPTS/ssh-key-change.sh"

have ssh-keygen || { skip "ssh-keygen is not installed"; finish; exit $?; }
have python3 || { skip "python3 is not installed"; finish; exit $?; }
for n in a b c; do ssh-keygen -q -t ed25519 -N '' -C "key-$n@pc" -f "$WORK/$n" >/dev/null; done
keyline() { cat "$WORK/$1.pub"; }
fp() { ssh-keygen -lf "$WORK/$1.pub" | awk '{ print $2 }'; }
cat > "$HS_MACHINE_FILE" <<EOF
hostName = "homeserver"
sshKeys = [
  "$(keyline a)",
]
nic = "enp3s0"
EOF

echo "-- list"
check_eq "one line: id, type, comment, session" "$(printf '%s\ted25519\tkey-a@pc\tno' "$(fp a)")" "$($L)"
check_eq "the key body is never printed" "0" "$(grep -c "$(awk '{ print $2 }' "$WORK/a.pub")" <<<"$($L)" || true)"
check_eq "the session key is marked" "yes" "$(HS_SSH_CURRENT_FP=$(fp a) $L | cut -f4)"

echo "-- add"
check_out "plan: ok with the fingerprint and the rebuild note" "^step.*$(fp b | sed "s/+/[+]/g")" $C plan add "$(keyline b)"
check_out "plan: says hs rebuild" "^note.*hs rebuild" $C plan add "$(keyline b)"
check_out "plan: not red" "^long	no" $C plan add "$(keyline b)"
check_eq "plan has no danger line" "0" "$($C plan add "$(keyline b)" | grep -c '^danger' || true)"
check_out "plan: a duplicate is refused" "in the list already" $C plan add "$(keyline a)"
check_out "plan: not a key" "not a public key line" $C plan add "hello world"
check_out "plan: a private key" "not a public key line" $C plan add "-----BEGIN OPENSSH PRIVATE KEY-----"
check_out "plan: options in front are refused" "not a public key line" $C plan add 'command="rm -rf /" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA x'
check_out "plan: a broken body" "not a valid public key" $C plan add "ssh-ed25519 AAAAAAAAAAAAAAAAAAAAAAAA me@pc"
check_out "plan: a quote in the comment" "not a public key line" $C plan add "$(keyline b | tr -d '\n') \"x"
check_out "plan: a dollar in the comment" "not a public key line" $C plan add "$(keyline b | tr -d '\n') \$(id)"
check_out "plan: two lines" "control characters" $C plan add "$(keyline b)
$(keyline c)"
check_out "plan: too long" "too long" $C plan add "ssh-ed25519 $(head -c 900 /dev/zero | tr '\0' A)"
check_out "plan: no key" "give the public key" $C plan add
check_out "plan: unknown option" "unknown option" $C plan add "$(keyline b)" --evil
check_out "start: adds" "^status.done" $C start add "$(keyline b)"
check_eq "two keys in the file" "2" "$(grep -c '"ssh-' "$HS_MACHINE_FILE")"
check_eq "the rest of the file is untouched" 'nic = "enp3s0"' "$(tail -n1 "$HS_MACHINE_FILE")"
check_out "start: again is refused" "in the list already" $C start add "$(keyline b)"
check_out "start: a bad key writes nothing" "not a public key line" $C start add "nonsense"
check_eq "still two keys" "2" "$(grep -c '"ssh-' "$HS_MACHINE_FILE")"
check_eq "the list shows both" "2" "$($L | wc -l | tr -d ' ')"

echo "-- remove"
check_out "plan: unknown id" "no key with this id" $C plan remove "SHA256:nope"
check_out "plan: red, the word remove" "^confirm_name	remove" $C plan remove "$(fp b)"
check_out "plan: danger line" "^danger" $C plan remove "$(fp b)"
check_out "plan: says hs rebuild" "^note.*hs rebuild" $C plan remove "$(fp b)"
check_out "plan: the session key is refused" "current SSH session" env HS_SSH_CURRENT_FP="$(fp b)" $C plan remove "$(fp b)"
check_out "start without the word is refused" "type the word to confirm: remove" $C start remove "$(fp b)"
check_out "start with a wrong word is refused" "type the word to confirm: remove" $C start remove "$(fp b)" --confirm yes
check_eq "nothing was removed" "2" "$(grep -c '"ssh-' "$HS_MACHINE_FILE")"
check_out "start with the word removes" "^status.done" $C start remove "$(fp b)" --confirm remove
check_eq "one key left" "1" "$(grep -c '"ssh-' "$HS_MACHINE_FILE")"
check_eq "it was the right one" "0" "$(grep -c 'key-b@pc' "$HS_MACHINE_FILE" || true)"
check_out "plan: the last key is refused" "last key" $C plan remove "$(fp a)"
check_out "start: the last key is refused" "last key" $C start remove "$(fp a)" --confirm remove
check_eq "the last key is still there" "1" "$(grep -c '"ssh-' "$HS_MACHINE_FILE")"
check_out "plan: an unknown action" "unknown action" $C plan wipe x

finish
