#!/usr/bin/env bash
# The buttons vps update / vps watch of the web interface: hs vps key (scripts/vps.sh) and hs sys vps plan|start (scripts/vps-change.sh).
# Stand-ins for ssh and systemd-run: no root, no VPS. Proves the exact ssh command line, that the private key is only a path in it, and the refusals.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en
unset HS_CALLER HS_GUIDED_TTY
T=$'\t'
has() { grep -q -- "$1" <<<"$out"; }
export HS_STATE_DIR=$WORK/state HS_RUN_DIR=$WORK/run HS_VAULT_DIR=$WORK/vault HS_MACHINE_FILE=$WORK/machine.toml
mkdir -p "$HS_STATE_DIR" "$HS_RUN_DIR"
BIN=$WORK/bin; mkdir -p "$BIN"
# systemd-run: one argument per line into jobcalls, so the exact command line can be compared
cat > "$BIN/systemd-run" <<FAKE
#!/usr/bin/env bash
for a in "\$@"; do printf '%s\n' "\$a"; done >> "$WORK/jobcalls"
printf -- '-----\n' >> "$WORK/jobcalls"
FAKE
chmod +x "$BIN/systemd-run"
export PATH="$BIN:$PATH"
printf 'hostName = "hs"\n' > "$HS_MACHINE_FILE"
run() { rc=0; out=$(timeout 30 bash "$SCRIPTS/vps-change.sh" "$@" </dev/null 2>/dev/null) || rc=$?; }

if have python3 || have python; then
  echo "-- allowlist"
  py=python3; have python3 || py=python
  if out=$($py -I "$ROOT/tests/web-vps-test.py" 2>&1); then pass "web CHANGES for vps ($(grep -E '^Ran ' <<<"$out"))"; else fail "allowlist: $(tail -n 25 <<<"$out")"; fi
else
  skip "python missing"
fi

echo "-- registry rows"
reg=$SCRIPTS/lib/registry.tsv
for r in "sys${T}sys vps plan <action>${T}vps-change.sh" "sys${T}sys vps start <action>${T}vps-change.sh" "user${T}vps key${T}vps.sh"; do
  check "row: ${r//$T/ | }" grep -q "^$r${T}" "$reg"
done

echo "-- no vpsHost: refused"
run plan update
check_eq "plan: exit 1" 1 "$rc"
has 'vpsHost is not set' && pass "says vpsHost" || fail "no host: $out"
run start update
check_eq "start: exit 1, nothing started" "1:" "$rc:$(cat "$WORK/jobcalls" 2>/dev/null)"

printf 'hostName = "hs"\nvpsHost = "proxyserver"\n' > "$HS_MACHINE_FILE"
echo "-- no key yet: refused"
run plan update
check_eq "plan: exit 1" 1 "$rc"
has 'hs vps key' && pass "points at hs vps key" || fail "no key: $out"
run start watch
check_eq "start: exit 1" 1 "$rc"

echo "-- hs vps key"
kout=$(timeout 30 bash "$SCRIPTS/vps.sh" key </dev/null 2>&1); krc=$?
check_eq "creates the key" 0 "$krc"
check "the private key exists, mode 600" test -s "$HS_STATE_DIR/vps-key"
touch "$WORK/modeprobe"; chmod 600 "$WORK/modeprobe"
if [ "$(stat -c %a "$WORK/modeprobe")" = 600 ]; then check_eq "mode 600" 600 "$(stat -c %a "$HS_STATE_DIR/vps-key")"; else skip "mode 600 (this file system ignores chmod)"; fi
check "no leftover copy in the run folder" test -z "$(ls -A "$HS_RUN_DIR")"
check "no .pub file beside the key" test ! -e "$HS_STATE_DIR/vps-key.pub"
publine=$(grep -E '^ssh-ed25519 ' <<<"$kout" || true)
check_eq "prints the public key line once" 1 "$(grep -c '^ssh-ed25519 ' <<<"$kout")"
check_eq "and the exact machine.nix line" "webKey = \"$publine\";" "$(grep '^webKey' <<<"$kout")"
check_eq "the public line is what the private key derives" "$(ssh-keygen -y -f "$HS_STATE_DIR/vps-key" | awk '{print $1" "$2}') hs-web" "$publine"
body=$(sed -n '2,/-----END/p' "$HS_STATE_DIR/vps-key" | sed '$d' | head -n 1)
check_eq "the output holds no private key text" 0 "$(grep -c -e 'PRIVATE' -e "$body" <<<"$kout" | tr -d ' ')"
k2=$(timeout 30 bash "$SCRIPTS/vps.sh" key </dev/null 2>&1)
check_eq "a second run shows the same line, changes nothing" "$publine" "$(grep '^ssh-ed25519 ' <<<"$k2")"
cksum < "$HS_STATE_DIR/vps-key" > "$WORK/ck1"
rc=0; timeout 30 bash "$SCRIPTS/vps.sh" key --new </dev/null >/dev/null 2>&1 || rc=$?
check_eq "--new without --yes and without a terminal is refused" 1 "$rc"
check_eq "...and the key is the same" "$(cat "$WORK/ck1")" "$(cksum < "$HS_STATE_DIR/vps-key")"
k3=$(timeout 30 bash "$SCRIPTS/vps.sh" key --new --yes </dev/null 2>&1)
check_eq "--new --yes makes another" 0 "$([ "$(grep '^ssh-ed25519 ' <<<"$k3")" = "$publine" ] && echo 1 || echo 0)"
rc=0; timeout 30 bash "$SCRIPTS/vps.sh" bogus </dev/null >/dev/null 2>&1 || rc=$?
check_eq "unknown word: usage" 1 "$rc"

echo "-- plan"
run plan update
check_eq "update plan: exit 0" 0 "$rc"
has '^status	ok$' && has '^heading	update the proxyserver (proxyserver)$' && has '^long	yes$' && pass "heading and long" || fail "update plan: $out"
has '^warn' && pass "a warning about the rebuild" || fail "no warn: $out"
cmdline=$(grep '^command' <<<"$out" | cut -f2)
case "$cmdline" in
  "ssh -i $HS_STATE_DIR/vps-key -T -p 2222 -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$HS_STATE_DIR/vps-known-hosts -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=8 root@proxyserver update") pass "the command names the key by path and the verb" ;;
  *) fail "command: $cmdline" ;;
esac
run plan watch
has '^heading	look at the home server' && has '^long	no$' && has 'root@proxyserver watch$' && pass "watch plan" || fail "watch plan: $out"
check_eq "plan starts nothing" "" "$(cat "$WORK/jobcalls" 2>/dev/null)"
for bad in "status" "shell" "update;id" "update --force" "" "UPDATE"; do
  rc=0; out=$(timeout 30 bash "$SCRIPTS/vps-change.sh" plan "$bad" </dev/null 2>/dev/null) || rc=$?
  check_eq "plan refuses [$bad]" 1 "$rc"
done
run plan update extra
check_eq "plan refuses extra arguments" 1 "$rc"

echo "-- start"
run start update
check_eq "start: exit 0" 0 "$rc"
has '^status	started$' && has '^unit	hs-job-vps-update-' && pass "status started with the unit" || fail "start: $out"
check "the job is a transient unit that notifies on failure" grep -q 'OnFailure=hs-notify-failure@' "$WORK/jobcalls"
# the command inside the unit: after the shell wrapper's description, ssh and its arguments, one per line
jc=$(awk '/^ssh$/ { on = 1 } on { print } /^-----$/ { on = 0 }' "$WORK/jobcalls" | sed '/^-----$/d' | tr '\n' ' ' | sed 's/ $//')
check_eq "the job runs exactly this ssh command" "ssh -i $HS_STATE_DIR/vps-key -T -p 2222 -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$HS_STATE_DIR/vps-known-hosts -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=8 root@proxyserver update" "$jc"
run start watch
has '^status	started$' && pass "watch starts too" || fail "watch: $out"
check_eq "the last job ends in 'root@proxyserver watch'" 1 "$(tail -n 2 "$WORK/jobcalls" | head -n 1 | grep -c '^watch$' | tr -d ' ')"
privbody=$(sed -n '2p' "$HS_STATE_DIR/vps-key")
check_eq "the private key text is nowhere in the job arguments or the answers" 0 "$(grep -c -e "$privbody" -e PRIVATE "$WORK/jobcalls" | tr -d ' ')"
check_eq "...nor in the plan and start answers" 0 "$(printf '%s\n%s\n' "$out" "$cmdline" | grep -c -e "$privbody" -e PRIVATE | tr -d ' ')"

echo "-- a closed vault"
rm -f "$HS_STATE_DIR/vps-key"
mkdir -p "$HS_VAULT_DIR/secrets"
if ln -s "$HS_VAULT_DIR/secrets/vps-key" "$HS_STATE_DIR/vps-key" 2>/dev/null && [ -L "$HS_STATE_DIR/vps-key" ]; then   # a link into the vault that is not there: the vault is closed
echo 1111-2222 > "$HS_STATE_DIR/vault-uuid"
: > "$WORK/jobcalls"
run plan update
check_eq "plan: exit 1" 1 "$rc"
has 'hs unlock' && pass "says unlock, not 'no key'" || fail "locked: $out"
run start update
check_eq "start: exit 1, no job" "1:" "$rc:$(cat "$WORK/jobcalls")"
rc=0; kout=$(timeout 30 bash "$SCRIPTS/vps.sh" key </dev/null 2>&1) || rc=$?
check_eq "hs vps key refuses and writes nothing" "1:0" "$rc:$([ -e "$HS_VAULT_DIR/secrets/vps-key" ] && echo 1 || echo 0)"
check_eq "...and says hs unlock" 1 "$(grep -c 'hs unlock' <<<"$kout" | tr -d ' ')"
else
  skip "closed vault (this system makes no symbolic links)"
fi

echo "-- a bad vpsHost"
rm -f "$HS_STATE_DIR/vps-key" "$HS_STATE_DIR/vault-uuid"; echo x > "$HS_STATE_DIR/vps-key"
printf 'hostName = "hs"\nvpsHost = "-oProxyCommand=id"\n' > "$HS_MACHINE_FILE"
run plan update
check_eq "an option-like host is refused" 1 "$rc"
printf 'hostName = "hs"\nvpsHost = "a b"\n' > "$HS_MACHINE_FILE"
run start update
check_eq "a host with a space is refused" 1 "$rc"

finish
