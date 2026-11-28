#!/usr/bin/env bash
# Pairing of remote shares by code (docs/PLAN-remote-shares.md): the hobnix program (rust/hobnix-core/src/pair.rs) with remote.sh as glue,
# both servers played on one machine with fake manage-users, share-perm and curl. Checks: code made and listed, claim end to end, one use,
# wrong code, taken name (Q4), rate limit, the code and the password in no argv or file, the reverse direction (receive + send).
# The binary: HOBNIX_BIN, else rust/target/debug|release/hobnix. Without one, or off Linux, the test is skipped (77).
root=$(cd "$(dirname "$0")/.." && pwd)
# nix-shell exports `out`. This test keeps answers in a variable of that name, and an exported one would carry a pairing code into the
# environment of the fake programs, which the leak check then finds.
unset out
bin=${HOBNIX_BIN:-}
if [ -z "$bin" ]; then
  [ "$(uname -s)" = Linux ] || { echo "  skip  needs Linux (WSL) or HOBNIX_BIN"; exit 77; }
  for c in "$root/rust/target/debug/hobnix" "$root/rust/target/release/hobnix"; do [ -x "$c" ] && { bin=$c; break; }; done
fi
[ -n "$bin" ] && [ -x "$bin" ] || { echo "  skip  no hobnix binary (cargo build in rust/, or HOBNIX_BIN)"; exit 77; }
# shellcheck source=tests/lib.sh
. "$root/tests/lib.sh"
T=$'\t'
unset HOBNIX_LOG HS_GUIDED_TTY
export HOBNIX_BIN=$bin HS_SCRIPTS=$SCRIPTS HS_CALLER=test HS_PLAIN=1 HS_LANG=en HS_EVENT_NOROOT=1 HS_WEB_PORT=8480

# rec.sh <log> args...: what a fake saw (its argv, the command line of its caller, its whole environment) is appended to <log>; stdin is not touched
cat > "$WORK/rec.sh" <<'EOF'
#!/usr/bin/env bash
log=$1; shift
{ echo "ARGV $*"; echo "CALLER $(tr '\0' ' ' < "/proc/$PPID/cmdline" 2>/dev/null)"; echo "CALLERS-CALLER $(tr '\0' ' ' < "/proc/$(awk '{ print $4 }' "/proc/$PPID/stat")/cmdline" 2>/dev/null)"; env; } >> "$log"
EOF
chmod +x "$WORK/rec.sh"

# one fake server: its state dir, its fake manage-users (a list of logins), share-perm, host key
mkserver() {   # mkserver <dir> <name>
  local d=$1 n=$2
  mkdir -p "$d/state" "$d/bin"
  : > "$d/users"
  cat > "$d/bin/mu.sh" <<EOF
#!/usr/bin/env bash
"$WORK/rec.sh" "$d/rec.log" "\$@"
if [ -e "$d/mu-fail" ]; then case "\$1" in --add|--password) exit 1 ;; esac; fi
case "\$1" in
  --list) awk '{ print \$1 "\tx" }' "$d/users" ;;
  --add) echo "\$2" >> "$d/users"; cat > "$d/last-pw" ;;
  --password) cat > "$d/last-pw" ;;
  --delete) grep -vx "\$2" "$d/users" > "$d/users.new"; mv "$d/users.new" "$d/users" ;;
  *) ;;
esac
EOF
  printf '#!/usr/bin/env bash\n"%s/rec.sh" "%s/rec.log" "$@"\necho "$@" >> "%s/perm.log"\n' "$WORK" "$d" "$d" > "$d/bin/sp.sh"
  printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI%s comment\n' "$(printf '%-43s' "${n}key" | tr ' ' 'A')" > "$d/hostkey.pub"
}
srv() {   # srv <dir> <name> cmd...: run remote.sh as that server
  local d=$1 n=$2; shift 2
  HS_STATE_DIR=$d/state HS_MANAGE_USERS=$d/bin/mu.sh HS_SHARE_PERM=$d/bin/sp.sh HS_HOST_NAME=$n HS_DOMAIN_SHORT=HOME \
    HS_HOST_KEY_FILE=$d/hostkey.pub HS_REMOTE_CODES=$d/codes.json HS_REMOTE_ROOT=$d/mnt HS_MOUNT_CMD=true HS_MOUNTPOINT=false \
    HS_VAULT_DIR=$d/novault bash "$SCRIPTS/remote.sh" "$@"
}
A=$WORK/a; B=$WORK/b
mkserver "$A" alpha; mkserver "$B" beta
# fake curl: the "network" is a direct call of `hobnix remote-claim|remote-accept` on server A (or B for a push)
cat > "$WORK/curl.sh" <<EOF
#!/usr/bin/env bash
"$WORK/rec.sh" "$WORK/rec-curl.log" "\$@"
url=\${@: -1}
case "\$url" in */claim) w=remote-claim; d=$A; n=alpha ;; */push) w=remote-accept; d=$B; n=beta ;; *) exit 7 ;; esac
export HS_REMOTE=\${FAKE_REMOTE:-} HS_STATE_DIR=\$d/state HS_MANAGE_USERS=\$d/bin/mu.sh HS_SHARE_PERM=\$d/bin/sp.sh HS_HOST_NAME=\$n HS_DOMAIN_SHORT=HOME \\
  HS_HOST_KEY_FILE=\$d/hostkey.pub HS_REMOTE_CODES=\$d/codes.json HS_REMOTE_ROOT=\$d/mnt HS_MOUNT_CMD=true HS_MOUNTPOINT=false HS_VAULT_DIR=\$d/novault
out=\$("$bin" \$w --source \${FAKE_SRC:-10.0.0.9}); rc=\$?
printf '%s' "\$out" > "$WORK/last-answer"
printf '%s\n%s' "\$out" "\$( [ \$rc = 0 ] && echo 200 || { case "\$out" in *code.rate*) echo 429 ;; *code.unknown*) echo 404 ;; *) echo 503 ;; esac; } )"
EOF
chmod +x "$WORK/curl.sh"
export HS_CURL=$WORK/curl.sh
# a node list without nodes
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/node.sh"; export HS_NODE=$WORK/node.sh

echo "-- offer --code: a code is made and listed, never stored in the clear"
out=$(srv "$A" alpha offer media --code --plain --yes) || fail "offer --code failed: $out"
code=$(awk -F'\t' '$2 == "code" { print $3 }' <<<"$out"); addr=$(awk -F'\t' '$2 == "address" { print $3 }' <<<"$out")
[ ${#code} -eq 19 ] && pass "a code of four groups of four" || fail "code: $code"
check_eq "the address always shows the port" "alpha.local:8480" "$addr"
lst=$(HS_REMOTE_CODES=$A/codes.json "$bin" remote-codes)
case "$lst" in "media${T}-${T}"[0-9][0-9][0-9]) pass "remote-codes lists share, server, seconds left" ;; *) fail "remote-codes: $lst" ;; esac
raw=$(tr -d '-' <<<"$code")
if grep -q "$raw" "$A/codes.json" || grep -q "$code" "$A/codes.json"; then fail "the code is in the store"; else pass "the store holds derived values only"; fi
[ "$(stat -c %a "$A/codes.json")" = 600 ] && pass "the store is 0600" || fail "store mode"

echo "-- add --code: claim, open, mount row, the password reaches B"
out=$(printf '%s\n' "$code@$addr" | srv "$B" beta add --code --stdin 2>&1) && pass "add --code ran" || fail "add --code: $out"
grep -q "^alpha${T}alpha.local${T}media${T}remote-beta" "$B/state/remote-mounts" && pass "the mount row names alpha / media / remote-beta" || fail "mounts: $(cat "$B/state/remote-mounts" 2>&1)"
grep -q "^remote-beta$" "$A/users" && pass "A has the login remote-beta" || fail "A users"
grep -q "^beta${T}media${T}remote-beta" "$A/state/remote-offers" && pass "A kept the offer with the key fingerprint" || fail "offers"
check_eq "the fingerprint column is set" "SHA256" "$(awk -F'\t' '{ print substr($5, 1, 6) }' "$A/state/remote-offers")"
echo "$out" | grep -q "Connected to alpha, key SHA256:" && pass "the key fingerprint is shown" || fail "no fingerprint line: $out"
pw=$(cat "$A/last-pw")
if grep -rq "$pw" "$A/state" "$A/codes.json" "$B/codes.json" 2>/dev/null; then fail "the password is in a state file of A"; else pass "A keeps no password"; fi
grep -q "password=$pw" "$B/state/remote-alpha.cred" && pass "the password is in B's credentials file" || fail "cred file"

echo "-- one use, wrong code, rate limit"
out=$(printf '%s\n' "$code@$addr" | srv "$B" beta add --code --stdin 2>&1) && fail "a used code worked again" || pass "a used code is refused"
echo "$out" | grep -q "does not know that code" && pass "one answer: unknown" || fail "text: $out"
out=$(srv "$A" alpha offer media --code --peer beta --plain --yes) && code2=$(awk -F'\t' '$2 == "code" { print $3 }' <<<"$out")
for i in 1 2 3 4 5; do printf 'AAAA-BBBB-CCCC-DDDD@%s\n' "$addr" | srv "$B" beta add --code --stdin >/dev/null 2>&1; done
out=$(printf '%s\n' "$code2@$addr" | srv "$B" beta add --code --stdin 2>&1) && fail "rate limit did not hold" || pass "6th try from one source is refused"
echo "$out" | grep -q "Too many" && pass "the refusal is code.rate" || fail "rate text: $out"
out=$(printf '%s\n' "$code2@$addr" | FAKE_SRC=10.0.0.77 srv "$B" beta add --code --stdin --reconnect alpha 2>&1) && pass "another source still works" || fail "other source: $out"

echo "-- a name taken by another server is refused (Q4)"
out=$(srv "$A" alpha offer media --code --plain --yes) && code3=$(awk -F'\t' '$2 == "code" { print $3 }' <<<"$out")
mkserver "$WORK/c" beta   # another server that also calls itself beta: another host key
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ x\n' > "$WORK/c/hostkey.pub"
out=$(printf '%s\n' "$code3@$addr" | srv "$WORK/c" beta add --code --stdin 2>&1) && fail "a taken name was given away" || pass "the second beta is refused"

echo "-- list keeps its shape"
l=$(srv "$B" beta list); echo "$l" | grep -q "^mount${T}alpha${T}media${T}alpha.local${T}" && pass "hs remote list: mount line unchanged" || fail "list: $l"
l=$(srv "$A" alpha list); echo "$l" | grep -q "^offer${T}beta${T}media${T}remote-beta${T}given$" && pass "hs remote list: offer line unchanged" || fail "list: $l"

echo "-- reverse: receive on B, send on A"
srv "$B" beta remove alpha --yes >/dev/null 2>&1   # a pushed share never reuses a name: start with a free one
out=$(srv "$B" beta receive --plain --yes) && rcode=$(awk -F'\t' '$2 == "code" { print $3 }' <<<"$out") || fail "receive: $out"
mkdir -p "$WORK/d"; mkserver "$WORK/d" gamma
srv "$WORK/d" gamma remove alpha --yes >/dev/null 2>&1
out=$(printf '%s\n' "$rcode@beta.local:8480" | srv "$A" alpha send docs --peer gamma --code --stdin --yes 2>&1) && pass "send ran" || fail "send: $out"
grep -q "^alpha${T}alpha.local${T}docs${T}remote-gamma" "$B/state/remote-mounts" && pass "B mounts docs of alpha" || fail "B mounts: $(cat "$B/state/remote-mounts")"
out=$(printf '%s\n' "$rcode@beta.local:8480" | srv "$A" alpha send docs --peer gamma --code --stdin --yes 2>&1) && fail "a used receive code worked" || pass "a used receive code is refused"

echo "-- an existing server's login cannot be taken over with a free code and its public host key"
export FAKE_SRC=10.0.0.55
cp "$B/hostkey.pub" "$WORK/c/hostkey.pub"   # the host key is public (ssh-keyscan): a server that shows beta's key and calls itself beta
pwbefore=$(cat "$A/last-pw")
out=$(srv "$A" alpha offer secret --code --plain --yes) && code4=$(awk -F'\t' '$2 == "code" { print $3 }' <<<"$out")
out=$(printf '%s\n' "$code4@$addr" | srv "$WORK/c" beta add --code --stdin 2>&1) && fail "a free code took over remote-beta" || pass "a free code refuses a taken name, even with the right host key"
check_eq "the password of remote-beta was not reset" "$pwbefore" "$(cat "$A/last-pw")"
if grep -q "^beta${T}secret${T}" "$A/state/remote-offers"; then fail "beta got read access to the other share"; else pass "no access to the other share"; fi
echo "-- Reconnect: a code bound to the name works for the same host key only"
out=$(srv "$A" alpha offer media --code --peer beta --plain --yes) && code5=$(awk -F'\t' '$2 == "code" { print $3 }' <<<"$out")
out=$(printf '%s\n' "$code5@$addr" | srv "$WORK/c" beta add --code --stdin 2>&1) && pass "a bound code is claimed by the stored key" || fail "reconnect: $out"
out=$(srv "$A" alpha offer media --code --peer beta --plain --yes) && code6=$(awk -F'\t' '$2 == "code" { print $3 }' <<<"$out")
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQ x\n' > "$WORK/c/hostkey.pub"
out=$(printf '%s\n' "$code6@$addr" | srv "$WORK/c" beta add --code --stdin 2>&1) && fail "a bound code was given to another key" || pass "a bound code refuses another host key"
echo "-- send never resets an existing login (mistyped name)"
out=$(srv "$B" beta receive --plain --yes) && rcode2=$(awk -F'\t' '$2 == "code" { print $3 }' <<<"$out")
pwbefore=$(cat "$A/last-pw")
out=$(printf '%s\n' "$rcode2@beta.local:8480" | srv "$A" alpha send docs --peer beta --code --stdin --yes 2>&1) && fail "send reset the login of beta" || pass "send refuses a name that exists"
check_eq "the password of beta was not reset by send" "$pwbefore" "$(cat "$A/last-pw")"
echo "-- B: the credentials file of a name is not overwritten by another server"
credbefore=$(cat "$B/state/remote-alpha.cred")
out=$(printf 'evilpw\n' | srv "$B" beta accept-mount alpha evil.local docs2 remote-x HOME - 2>&1); rc=$?
check_eq "accept-mount without the stored key is refused (exit 1)" 1 "$rc"
out=$(printf 'evilpw\n' | srv "$B" beta accept-mount alpha evil.local docs2 remote-x HOME SHA256:otherkey 2>&1); rc=$?
check_eq "accept-mount with another key is refused (exit 1)" 1 "$rc"
check_eq "the credentials file is unchanged" "$credbefore" "$(cat "$B/state/remote-alpha.cred")"
echo "-- the MATCHING public host key proves nothing: a pushed or claimed box cannot take a name that is mounted"
fpmatch=$(awk -F'\t' '$1 == "alpha" && $6 ~ /^SHA256/ { print $6; exit }' "$B/state/remote-mounts")
[ -n "$fpmatch" ] && pass "B has the stored key of alpha" || fail "no stored key: $(cat "$B/state/remote-mounts")"
rowsbefore=$(wc -l < "$B/state/remote-mounts")
out=$(printf 'evilpw\n' | srv "$B" beta accept-mount alpha evil.local docs2 remote-x HOME "$fpmatch" 2>&1); rc=$?
check_eq "a push with the matching key for a taken name is refused (exit 1)" 1 "$rc"
check_eq "the credentials file is unchanged by it" "$credbefore" "$(cat "$B/state/remote-alpha.cred")"
check_eq "no new row" "$rowsbefore" "$(wc -l < "$B/state/remote-mounts")"
if grep -q "evil.local" "$B/state/remote-mounts"; then fail "a row for the attacker host"; else pass "no row for the attacker host"; fi
out=$(srv "$A" alpha offer media --code --peer beta --plain --yes) && code7=$(awk -F'\t' '$2 == "code" { print $3 }' <<<"$out")
out=$(printf '%s\n' "$code7@$addr" | srv "$B" beta add --code --stdin 2>&1) && fail "add --code took a name that is mounted" || pass "add --code refuses a taken name without --reconnect"
check_eq "the credentials file is unchanged by add --code" "$credbefore" "$(cat "$B/state/remote-alpha.cred")"
out=$(srv "$A" alpha offer media --code --peer beta --plain --yes) && code8=$(awk -F'\t' '$2 == "code" { print $3 }' <<<"$out")
out=$(printf '%s\n' "$code8@$addr" | srv "$B" beta add --code --stdin --reconnect gamma 2>&1) && fail "reconnect for another name worked" || pass "--reconnect names the server and the answer must match"
out=$(srv "$A" alpha offer media --code --peer beta --plain --yes) && code9=$(awk -F'\t' '$2 == "code" { print $3 }' <<<"$out")
out=$(printf '%s\n' "$code9@$addr" | srv "$B" beta add --code --stdin --reconnect alpha 2>&1) && pass "--reconnect alpha with the stored key works" || fail "reconnect: $out"
echo "-- --reconnect is anchored to the stored host: a code maker who shows alpha's public key and name but another host is refused"
cat > "$WORK/evil-remote.sh" <<EOT
#!/usr/bin/env bash
# an attacker's server: patched remote.sh that answers server=alpha, the PUBLIC host key of alpha, but its own host
[ "\$1" = grant ] || exit 3
printf 'server\talpha\nhost\tevil.local\nlogin\tremote-beta\ndomain\tHOME\npassword\tevilpw\nhostkey\t%s\n' "\$(awk '{ print \$1 " " \$2; exit }' "$A/hostkey.pub")"
EOT
chmod +x "$WORK/evil-remote.sh"
credbefore=$(cat "$B/state/remote-alpha.cred"); rowsbefore=$(cat "$B/state/remote-mounts")
out=$(srv "$A" alpha offer media --code --peer beta --plain --yes) && code10=$(awk -F'\t' '$2 == "code" { print $3 }' <<<"$out")
out=$(printf '%s\n' "$code10@$addr" | FAKE_REMOTE=$WORK/evil-remote.sh srv "$B" beta add --code --stdin --reconnect alpha 2>&1) && fail "a reconnect moved alpha to another host" || pass "the answer's host must be the stored host"
check_eq "the credentials file is unchanged (host in the answer)" "$credbefore" "$(cat "$B/state/remote-alpha.cred")"
check_eq "the rows are unchanged (host in the answer)" "$rowsbefore" "$(cat "$B/state/remote-mounts")"
out=$(srv "$A" alpha offer media --code --peer beta --plain --yes) && code11=$(awk -F'\t' '$2 == "code" { print $3 }' <<<"$out")
out=$(printf '%s\n' "$code11@evil.local:8480" | srv "$B" beta add --code --stdin --reconnect alpha 2>&1) && fail "a reconnect followed a code that points to another host" || pass "the address the code points to must be the stored host"
check_eq "the credentials file is unchanged (address of the code)" "$credbefore" "$(cat "$B/state/remote-alpha.cred")"
check_eq "the rows are unchanged (address of the code)" "$rowsbefore" "$(cat "$B/state/remote-mounts")"
echo "-- a node link proves only that node X answered: node carol (not alpha, not at alpha's host) cannot renew alpha"
cat > "$WORK/node2.sh" <<EOT
#!/usr/bin/env bash
case "\$1" in
  --list) printf 'carol\tpeer\tcarol.host\t22\tfile\tok\nalpha\tpeer\talpha.local\t22\tfile\tok\n' ;;
  --pair) resp=\$($WORK/curl.sh http://x/api/remote/claim); body=\${resp%\$'\n'*}; printf '%s\n' "\$body"; [ "\${resp##*\$'\n'}" = 200 ] ;;
esac
EOT
chmod +x "$WORK/node2.sh"
credbefore=$(cat "$B/state/remote-alpha.cred"); rowsbefore=$(cat "$B/state/remote-mounts")
out=$(srv "$A" alpha offer media --code --peer beta --plain --yes) && code12=$(awk -F'\t' '$2 == "code" { print $3 }' <<<"$out")
out=$(printf '%s\n' "$code12" | HS_NODE=$WORK/node2.sh srv "$B" beta add --code --stdin --server carol --reconnect alpha 2>&1) && fail "an unrelated node renewed alpha" || pass "a node that is not alpha and not at alpha's host is refused"
check_eq "the credentials file is unchanged (node)" "$credbefore" "$(cat "$B/state/remote-alpha.cred")"
check_eq "the rows are unchanged (node)" "$rowsbefore" "$(cat "$B/state/remote-mounts")"
cat > "$WORK/node3.sh" <<EOT
#!/usr/bin/env bash
# a node that is only LABELLED alpha (it lives at vps.example) and answers like alpha with the public key
case "\$1" in
  --list) printf 'alpha\tpeer\tvps.example\t22\tfile\tok\n' ;;
  --pair) resp=\$($WORK/curl.sh http://x/api/remote/claim); body=\${resp%\$'\n'*}; printf '%s\n' "\$body"; [ "\${resp##*\$'\n'}" = 200 ] ;;
esac
EOT
chmod +x "$WORK/node3.sh"
out=$(srv "$A" alpha offer media --code --peer beta --plain --yes) && code14=$(awk -F'\t' '$2 == "code" { print $3 }' <<<"$out")
out=$(printf '%s\n' "$code14" | HS_NODE=$WORK/node3.sh srv "$B" beta add --code --stdin --server alpha --reconnect alpha 2>&1) && fail "a node labelled alpha at another host renewed alpha" || pass "a node label proves nothing: its host must be the stored host"
check_eq "the credentials file is unchanged (label)" "$credbefore" "$(cat "$B/state/remote-alpha.cred")"
check_eq "the rows are unchanged (label)" "$rowsbefore" "$(cat "$B/state/remote-mounts")"
out=$(srv "$A" alpha offer media --code --peer beta --plain --yes) && code13=$(awk -F'\t' '$2 == "code" { print $3 }' <<<"$out")
out=$(printf '%s\n' "$code13" | HS_NODE=$WORK/node2.sh srv "$B" beta add --code --stdin --server alpha --reconnect alpha 2>&1) && pass "the node named alpha renews alpha" || fail "node alpha: $out"
echo "-- the manual add keeps its plain failure (exit 1) for an empty password"
out=$(printf '\n' | srv "$B" beta add manual manual.local share --user u --stdin --yes 2>&1); rc=$?
check_eq "manual add without a password fails with exit 1" 1 "$rc"
echo "-- send: a second share for a server that has access gets an accurate error"
out=$(srv "$B" beta receive --plain --yes) && rcode3=$(awk -F'\t' '$2 == "code" { print $3 }' <<<"$out")
out=$(printf '%s\n' "$rcode3@beta.local:8480" | srv "$A" alpha send docs --peer beta --code --stdin --yes 2>&1) && fail "send to an existing name worked" || pass "send refuses it"
echo "$out" | grep -q "has an access from this server already" && pass "the error says why" || fail "error text: $out"
echo "-- no secret in argv of the programs (the code goes on stdin)"
grep -n 'pair request\|pair open\|pair push\|pair check' "$SCRIPTS/remote.sh" | grep -v '|' | grep -q . && fail "a pair call without stdin pipe" || pass "every pair call reads the code from a pipe"

# ---- what follows: the regressions of the review of the backend, the burn, the error names, and the leak check (issue 1155)
export HS_STATE_DB=$WORK/state.db   # the events of the rest of this file land here
unset FAKE_SRC FAKE_REMOTE
newcode() {   # newcode <dir> <name> [args...]: a code of that server, on stdout
  local out
  out=$(srv "$1" "$2" offer "${@:3}" --code --plain --yes) || { echo "offer failed: $out" >&2; return 1; }
  awk -F'\t' '$2 == "code" { print $3 }' <<<"$out"
}
answer_error() { python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("error",""))' < "$WORK/last-answer" 2>/dev/null; }
srv "$A" alpha codes --cancel >/dev/null 2>&1; srv "$B" beta codes --cancel >/dev/null 2>&1

echo "-- takeover regression: a free code and a taken name (the other side chose the name), the public host key matching"
export FAKE_SRC=10.0.0.60
cp "$B/hostkey.pub" "$WORK/c/hostkey.pub"
code=$(newcode "$A" alpha docs)
snap() { { cat "$A/users"; cat "$A/state/remote-offers"; cat "$A/perm.log"; cat "$A/last-pw"; } | cksum; }
before=$(snap)
out=$(printf '%s\n' "$code@$addr" | srv "$WORK/c" beta add --code --stdin 2>&1) && fail "a free code took the taken name beta" || pass "free code + taken name: refused"
check_eq "nothing changed on the giving side (logins, offers, permissions, password)" "$before" "$(snap)"
[ "$(srv "$A" alpha codes | wc -l)" -eq 0 ] && pass "the code is spent by the refusal" || fail "the code survived"

echo "-- takeover regression: --reconnect for a name that is not the one the answer comes from"
code=$(newcode "$A" alpha media --peer beta)
credbefore=$(cat "$B/state/remote-alpha.cred"); rowsbefore=$(cat "$B/state/remote-mounts")
out=$(printf '%s\n' "$code@$addr" | srv "$B" beta add --code --stdin --reconnect delta 2>&1) && fail "--reconnect delta accepted an answer from alpha" || pass "--reconnect with another name than the answering server: refused"
check_eq "credentials unchanged (reconnect other name)" "$credbefore" "$(cat "$B/state/remote-alpha.cred")"
check_eq "rows unchanged (reconnect other name)" "$rowsbefore" "$(cat "$B/state/remote-mounts")"

echo "-- the error names: unknown (wrong, used, expired), rate, unavailable"
export FAKE_SRC=10.0.0.61
srv "$A" alpha codes --cancel >/dev/null 2>&1
code=$(newcode "$A" alpha docs --peer beta)
out=$(printf '%s\n' "$code@$addr" | srv "$B" beta add --code --stdin --reconnect alpha 2>&1) && pass "a fresh code works once" || fail "fresh code: $out"
out=$(printf '%s\n' "$code@$addr" | srv "$B" beta add --code --stdin --reconnect alpha 2>&1) && fail "a used code worked" || check_eq "a used code answers code.unknown" code.unknown "$(answer_error)"
out=$(printf '%s\n' "ZZZZ-ZZZZ-ZZZZ-ZZZZ@$addr" | srv "$B" beta add --code --stdin --reconnect alpha 2>&1) && fail "a wrong code worked" || check_eq "a wrong code answers code.unknown too (the same words)" code.unknown "$(answer_error)"
code=$(newcode "$A" alpha docs --peer beta)
# the clock is a parameter in the Rust tests (pair::Clock); here the stored expiry is moved into the past
python3 - "$A/codes.json" <<'EOF'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
for c in d["codes"]:
    c["expires"] = 1
json.dump(d, open(p, "w"))
EOF
[ "$(srv "$A" alpha codes | wc -l)" -eq 0 ] && pass "an expired code is no longer listed" || fail "expired code listed"
out=$(printf '%s\n' "$code@$addr" | srv "$B" beta add --code --stdin --reconnect alpha 2>&1) && fail "an expired code worked" || check_eq "an expired code answers code.unknown" code.unknown "$(answer_error)"
echo "$out" | grep -q "does not know that code" && pass "the text says: wrong, used or expired" || fail "text: $out"
code=$(newcode "$A" alpha docs --peer beta)
touch "$A/mu-fail"
out=$(printf '%s\n' "$code@$addr" | srv "$B" beta add --code --stdin --reconnect alpha 2>&1) && fail "a claim worked without an account" || check_eq "no account possible answers code.unavailable" code.unavailable "$(answer_error)"
rm -f "$A/mu-fail"
out=$(printf '%s\n' "$code@$addr" | srv "$B" beta add --code --stdin --reconnect alpha 2>&1) && fail "the code of a failed claim worked again" || check_eq "the code of a failed claim is spent (one use)" code.unknown "$(answer_error)"
export FAKE_SRC=10.0.0.62
for i in 1 2 3 4 5; do printf 'AAAA-BBBB-CCCC-DDDD@%s\n' "$addr" | srv "$B" beta add --code --stdin >/dev/null 2>&1; done
printf 'AAAA-BBBB-CCCC-DDDD@%s\n' "$addr" | srv "$B" beta add --code --stdin >/dev/null 2>&1
check_eq "the 6th try from one source answers code.rate" code.rate "$(answer_error)"

echo "-- 20 wrong tries from several sources end every open code"
srv "$A" alpha codes --cancel >/dev/null 2>&1
code=$(newcode "$A" alpha docs --peer beta)
for n in 71 72 73 74; do
  export FAKE_SRC=10.0.0.$n
  for i in 1 2 3 4 5; do printf 'AAAA-BBBB-CCCC-DDDD@%s\n' "$addr" | srv "$B" beta add --code --stdin >/dev/null 2>&1; done
done
[ "$(srv "$A" alpha codes | wc -l)" -eq 0 ] && pass "the open code ended with the 20th failure" || fail "the code is still open"
export FAKE_SRC=10.0.0.75
out=$(printf '%s\n' "$code@$addr" | srv "$B" beta add --code --stdin --reconnect alpha 2>&1) && fail "a burned code worked" || check_eq "the right code of a burned set answers code.unknown" code.unknown "$(answer_error)"

echo "-- the probe: hs sys remote codes is a read the smoke test runs, three tab-separated fields, never the code"
grep -qF 'hs remote codes\tremote codes' "$SCRIPTS/smoke.sh" && pass "scripts/smoke.sh probes hs remote codes" || fail "no smoke probe for remote codes"
grep -q "^sys	sys remote codes	rust:remote-codes	" "$SCRIPTS/lib/registry.tsv" && pass "the sys row is in the registry" || fail "no sys row"
export FAKE_SRC=10.0.0.80
code=$(newcode "$A" alpha docs --peer beta)
lst=$(HS_REMOTE_CODES=$A/codes.json "$bin" remote-codes); rc=$?
check_eq "remote-codes exits 0" 0 "$rc"
check_eq "one row of three fields" 3 "$(awk -F'\t' '{ print NF }' <<<"$lst" | sort -u | tr -d '\n')"
case "$lst" in *"$code"*|*"$(tr -d - <<<"$code")"*) fail "the code is in the list" ;; *) pass "the list never carries the code" ;; esac
srv "$A" alpha codes --cancel >/dev/null 2>&1
check_eq "an empty list is empty and exits 0" "0:" "$(HS_REMOTE_CODES=$A/codes.json "$bin" remote-codes; echo "$?:")"

echo "-- the code and the password are in no argv, environment, journal line, state file or event"
mkserver "$WORK/e" echo
srv "$WORK/e" echo remove alpha --yes >/dev/null 2>&1
: > "$A/rec.log"; : > "$WORK/rec-curl.log"; : > "$WORK/e/rec.log"
export FAKE_SRC=10.0.0.81
out=$(srv "$A" alpha offer secret-docs --code --plain --yes 2>"$WORK/err-offer") || fail "offer: $out"
code=$(awk -F'\t' '$2 == "code" { print $3 }' <<<"$out"); raw=$(tr -d - <<<"$code")
HS_EVENT_VERBOSE=1 srv "$WORK/e" echo add --code --stdin >"$WORK/out-add" 2>"$WORK/err-add" <<<"$code@$addr"
grep -q "^remote-echo$" "$A/users" && pass "the pairing ran (login remote-echo on A)" || fail "the pairing did not run: $(cat "$WORK/out-add" "$WORK/err-add" "$WORK/last-answer" | head -c 600)"
pw=$(cat "$A/last-pw")
[ ${#pw} -ge 12 ] && pass "there is a password to look for" || fail "no password: '$pw'"
python3 - "$HS_STATE_DB" > "$WORK/events.txt" 2>&1 <<'EOF'
import sqlite3, sys
for r in sqlite3.connect(sys.argv[1]).execute("SELECT kind, subject, text, payload FROM events ORDER BY id"):
    print("|".join(str(x) for x in r))
EOF
grep -q "claimed" "$WORK/events.txt" && grep -q "code.made" "$WORK/events.txt" && pass "the events were written (the check below is not empty)" || fail "no events: $(head -c 200 "$WORK/events.txt")"
leaks=
for f in "$A/rec.log" "$WORK/e/rec.log" "$WORK/rec-curl.log" "$WORK/err-offer" "$WORK/out-add" "$WORK/err-add" "$WORK/events.txt"; do
  for s in "$code" "$raw" "$pw"; do grep -qF -- "$s" "$f" && leaks="$leaks ${f##*/}:${s:0:4}"; done
done
[ -z "$leaks" ] && pass "no argv, environment, journal line or event holds the code or the password" || fail "leaks:$leaks"
grep -q "ARGV" "$A/rec.log" && grep -q "ARGV" "$WORK/rec-curl.log" && pass "the fakes recorded their calls (the check is not empty)" || fail "nothing recorded"
leaks=
for d in "$A/state" "$WORK/e/state"; do
  while IFS= read -r f; do
    case "$f" in *.cred) continue ;; esac   # the one place the password belongs: the credentials file of the using side
    for s in "$code" "$raw" "$pw"; do grep -qF -- "$s" "$f" && leaks="$leaks ${f##*/}"; done
  done < <(find "$d" -type f)
done
for s in "$code" "$raw"; do grep -qF -- "$s" "$A/codes.json" && leaks="$leaks codes.json"; done
[ -z "$leaks" ] && pass "no state file or job record holds them (the credentials file apart)" || fail "files with a secret:$leaks"
[ "$(stat -c %a "$WORK/e/state/remote-alpha.cred")" = 600 ] && pass "the credentials file of the using side is 0600" || fail "cred mode"

echo "-- HOBNIX_LOG=debug: the log lines on stderr stay out of the request and the answer (issue 1174)"
mkserver "$WORK/g" golf
export FAKE_SRC=10.0.0.82
code=$(newcode "$A" alpha secret-docs) || fail "no code for the debug run"
out=$(HOBNIX_LOG=debug srv "$WORK/g" golf add --code --stdin 2>"$WORK/err-debug" <<<"$code@$addr") && pass "add --code works with HOBNIX_LOG=debug" || fail "add at debug level: $out $(head -c 300 "$WORK/err-debug")"
grep -q "^remote-golf$" "$A/users" && pass "the login was made through the debug run" || fail "no pairing at debug level"
pw=$(cat "$A/last-pw")
grep -qF -- "$pw" "$WORK/err-debug" 2>/dev/null && fail "the password reached the debug log" || pass "no password in the debug run's stderr"

echo "-- the stderr file of the pair calls: 0600, made by mktemp in the state directory, removed on exit"
cat > "$WORK/spy.sh" <<EOT
#!/usr/bin/env bash
t=\$(readlink /proc/\$\$/fd/2); printf '%s %s
' "\$(stat -c %a "\$t")" "\$t" >> "$WORK/spy.log"
exec "$bin" "\$@"
EOT
chmod +x "$WORK/spy.sh"; : > "$WORK/spy.log"
export FAKE_SRC=10.0.0.83
code=$(newcode "$A" alpha secret-docs) || fail "no code for the stderr file run"
mkserver "$WORK/h" hotel
HOBNIX_BIN=$WORK/spy.sh srv "$WORK/h" hotel add --code --stdin >/dev/null 2>&1 <<<"$code@$addr"
mode=$(awk '{ print $1; exit }' "$WORK/spy.log"); path=$(awk '{ print $2; exit }' "$WORK/spy.log")
check_eq "the stderr file is 0600" 600 "$mode"
case "$path" in "$WORK/h/state/.pair-err."*) pass "it lives in the state directory" ;; *) fail "stderr file path: '$path'" ;; esac
[ -n "$path" ] && [ ! -e "$path" ] && pass "it is removed on exit" || fail "the stderr file is still there"

finish
