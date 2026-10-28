#!/usr/bin/env bash
# hs ssh-key: list, add, remove in a copy of machine.toml. No root needed (needs ssh-keygen for the real keys).
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test
export HS_MACHINE_FILE=$WORK/machine.toml HS_STATE_DIR=$WORK/state
K="bash $SCRIPTS/ssh-key.sh"

command -v ssh-keygen >/dev/null 2>&1 || { skip "ssh-keygen is not installed"; finish; exit $?; }
for n in a b c; do ssh-keygen -q -t ed25519 -N '' -C "key-$n@pc" -f "$WORK/$n" >/dev/null; done
ssh-keygen -q -t rsa -b 2048 -N '' -C "old rsa key" -f "$WORK/r" >/dev/null
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
check_out "comment, type and fingerprint" "key-a@pc +ed25519 +SHA256:" $K list
check_out "with a header" "^Comment +Type +Fingerprint" $K list

echo "-- add"
check_out "a key that is not a key" "not a public key line" $K add "hello world" --yes
check_out "a private key is refused" "not a public key line" $K add "BEGIN OPENSSH PRIVATE KEY" --yes
check_out "a broken key" "not a public key line" $K add "ssh-ed25519 AAAAnotreallyakey me@pc" --yes
check_out "a quote inside is refused" "not a public key line" $K add 'ssh-ed25519 AAAAC3Nza me"@pc' --yes
check_out "without --yes and no terminal" "without --yes" $K add "$(keyline b)"
check_out "adds a key" "takes effect with: hs rebuild" $K add "$(keyline b)" --yes
check_out "it is listed" "key-b@pc" $K list
check_out "a copy of the old file" "machine.toml.before-ssh-key" $K add --file "$WORK/c.pub" --yes
check_eq "the copy has the old content" "2" "$(grep -c 'ssh-' "$HS_STATE_DIR/machine.toml.before-ssh-key")"
check_out "a key twice" "in the list already" $K add "$(keyline b)" --yes
check_out "an rsa key with a comment of several words" "old rsa key" $K add "$(keyline r)" --yes
check_out "listed with its type" "old rsa key +rsa" $K list
check_eq "the rest of the file is untouched" "2" "$(grep -c -E '^(hostName|nic) ' "$HS_MACHINE_FILE")"
check_eq "four keys" "4" "$(grep -c '"ssh-' "$HS_MACHINE_FILE")"
check_eq "the list is closed and the file ends as before" 'nic = "enp3s0"' "$(tail -n1 "$HS_MACHINE_FILE")"

echo "-- remove"
check_out "unknown key" "No key with the comment" $K remove nobody@pc --yes
check_out "by comment" "removed from machine.toml" $K remove key-c@pc --yes
check_eq "it is gone" "0" "$(grep -c "key-c@pc" "$HS_MACHINE_FILE" || true)"
check_out "by fingerprint" "removed from machine.toml" $K remove "$(fp r)" --yes
check_out "by fingerprint without the prefix" "removed from machine.toml" $K remove "$(fp b | sed 's/^SHA256://')" --yes
check_out "the last key stays" "last key" $K remove key-a@pc --yes
check_eq "still one key" "1" "$(grep -c '"ssh-' "$HS_MACHINE_FILE")"
$K add "$(keyline b)" --yes >/dev/null
check_out "the session key is refused" "your current SSH session" env HS_SSH_CURRENT_FP="$(fp b)" $K remove key-b@pc --yes
check_eq "and is still there" "2" "$(grep -c '"ssh-' "$HS_MACHINE_FILE")"
check_out "another key can go while the session key stays" "removed from machine.toml" env HS_SSH_CURRENT_FP="$(fp b)" $K remove key-a@pc --yes
$K add "$(keyline c)" --yes >/dev/null
check_out "a note when the session key is unknown" "Could not tell which key" env -u SSH_CONNECTION HS_PROC_ROOT=$WORK/noproc $K remove key-c@pc --yes

echo "-- file shapes"
printf 'sshKeys = [ "%s", "%s" ]\nx = 1\n' "$(keyline a)" "$(keyline b)" > "$HS_MACHINE_FILE"
check_out "a list on one line" "key-b@pc" $K list
check_out "removing from it" "removed from machine.toml" $K remove key-a@pc --yes
check_eq "x stays" "1" "$(grep -c '^x = 1' "$HS_MACHINE_FILE")"
printf 'nic = "x"\n' > "$HS_MACHINE_FILE"
check_out "no sshKeys list" "no sshKeys list" $K list

echo "-- guided"
cat > "$HS_MACHINE_FILE" <<EOF
sshKeys = [
  "$(keyline a)",
]
EOF
export HS_GUIDED_TTY=1
check_out "no terminal: asks for the key" "Missing: the public key" env -u HS_GUIDED_TTY $K add
out=$(printf '%s\ny\n' "$(keyline b)" | $K add 2>&1 || true)
if grep -q "takes effect" <<<"$out"; then pass "add asks for the key and confirms"; else fail "add asks ($out)"; fi
out=$(printf '2\ny\n' | $K remove 2>&1 || true)
if grep -q "removed from machine.toml" <<<"$out"; then pass "remove offers the keys to choose from"; else fail "remove asks ($out)"; fi
check_eq "one key left" "1" "$(grep -c '"ssh-' "$HS_MACHINE_FILE")"
out=$(printf 'n\n' | $K add "$(keyline c)" 2>&1 || true)
if grep -q cancelled <<<"$out"; then pass "no cancels"; else fail "no cancels ($out)"; fi
check_eq "and changes nothing" "1" "$(grep -c '"ssh-' "$HS_MACHINE_FILE")"

echo "-- through hs"
export HS_COMPLETE_DIR=$WORK/complete
check_out "hs ssh-key list" "key-a@pc" bash "$SCRIPTS/lib/hs.sh" ssh-key list
check_out "hs help ssh-key" "^hs ssh-key remove" bash "$SCRIPTS/lib/hs.sh" help ssh-key

finish
