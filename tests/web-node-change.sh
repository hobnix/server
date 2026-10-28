#!/usr/bin/env bash
# The Nodes page of the web interface: hs sys node plan|start (scripts/node-change.sh) adds, removes and makes the key of a node, against the real node.sh
# in a temporary state folder. Nothing reaches another server. Proves the plans (remove and key --new are red), the refusals and the web allowlist.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en
unset HS_CALLER HS_GUIDED_TTY
T=$'\t'
has() { grep -q -- "$1" <<<"$out"; }
export HS_STATE_DIR=$WORK/state HS_RUN_DIR=$WORK/run HS_VAULT_DIR=$WORK/vault HS_MACHINE_FILE=$WORK/machine.toml HS_SETTINGS_DIR=$WORK/state/settings HS_NOW=1000
mkdir -p "$HS_STATE_DIR" "$HS_RUN_DIR"
printf 'hostName = "hs"\n' > "$HS_MACHINE_FILE"
run() { rc=0; out=$(timeout 30 bash "$SCRIPTS/node-change.sh" "$@" </dev/null 2>/dev/null) || rc=$?; }
list() { bash "$SCRIPTS/node.sh" --list | cut -f1,2,3,4 | tr '\t' '|' | paste -sd, -; }

if have python3 || have python; then
  echo "-- allowlist"
  py=python3; have python3 || py=python
  if out=$($py -I "$ROOT/tests/web-node-test.py" 2>&1); then pass "web CHANGES for node ($(grep -E '^Ran ' <<<"$out"))"; else fail "allowlist: $(tail -n 25 <<<"$out")"; fi
else
  skip "python missing"
fi

echo "-- add"
run plan add cousin cousin.tail.ts.net
has '^status	ok$' && has '^heading	add the node cousin$' && has 'Nothing changes on the other server' && has '^long	no$' && pass "plan: names the node, changes nothing there" || fail "add plan: $out"
check_eq "a plan writes nothing" "" "$(list)"
run plan add cousin
check_eq "the host is missing: exit 2, needs host" "2:needs" "$rc:$(grep -c '^needs	host$' <<<"$out" | sed 's/1/needs/')"
run start add cousin cousin.tail.ts.net
check_eq "start: done" "0:status${T}done" "$rc:$(head -n 1 <<<"$out")"
check_eq "the node is on the list (peer, port 22)" "cousin|peer|cousin.tail.ts.net|22" "$(list)"
run plan add cousin other.host
check_eq "a second node of the same name is refused" 1 "$rc"
run start add edge1 edge1.example.org --kind edge --port 2222
check_eq "start with kind and port" "cousin|peer|cousin.tail.ts.net|22,edge1|edge|edge1.example.org|2222" "$(list)"
for bad in "Cousin host.example" "a-b-c- -oProxyCommand=id" "okname a..b" "okname host --kind shell" "okname host --port 0" "okname host --port 99999" "okname host --bogus" "local host.example" "main host.example"; do
  # shellcheck disable=SC2086
  run plan add $bad
  check_eq "refused: $bad" 1 "$rc"
done
check_eq "nothing of that was written" "cousin|peer|cousin.tail.ts.net|22,edge1|edge|edge1.example.org|2222" "$(list)"

echo "-- key"
run plan key cousin
has '^status	ok$' && ! has '^confirm_name' && ! has '^danger' && pass "plan key: plain, nothing typed" || fail "key plan: $out"
run plan key nope
check_eq "key of an unknown node is refused" 1 "$rc"
if command -v ssh-keygen >/dev/null 2>&1; then
  run start key cousin
  check_eq "start key: done" "0:status${T}done" "$rc:$(head -n 1 <<<"$out")"
  check "the key file exists on this server" test -s "$HS_STATE_DIR/node-key-cousin"
  bash "$SCRIPTS/node.sh" --keyline cousin > "$WORK/keyline" 2>/dev/null || true
  check "keyline holds the public line" grep -q "^line${T}restrict,command=\"/etc/nixos/scripts/node-remote.sh\" ssh-ed25519 " "$WORK/keyline"
  check_eq "and no private key text" 0 "$(grep -c PRIVATE "$WORK/keyline" | tr -d ' ')"
  run plan key cousin --new
  has "^confirm_name${T}cousin\$" && has '^danger' && pass "plan key --new is red: the node's name is typed" || fail "key --new plan: $out"
  c1=$(cksum < "$HS_STATE_DIR/node-key-cousin")
  run start key cousin --new
  check_eq "start key --new: done" 0 "$rc"
  [ "$c1" != "$(cksum < "$HS_STATE_DIR/node-key-cousin")" ] && pass "the key was replaced" || fail "the key is the same"
else
  skip "ssh-keygen missing: key creation"
fi

echo "-- remove"
run plan remove cousin
has "^confirm_name${T}cousin\$" && has '^danger' && has "^command${T}.*node.sh remove cousin --yes\$" && pass "plan remove is red: the node's name is typed" || fail "remove plan: $out"
run plan remove nope
check_eq "unknown node: refused" 1 "$rc"
run start remove cousin
check_eq "start remove: done" 0 "$rc"
check_eq "the node is gone from the list" "edge1|edge|edge1.example.org|2222" "$(list)"
printf 'vpsHost = "vps.example"\n' >> "$HS_MACHINE_FILE"
run plan remove proxyserver
check_eq "the implicit proxyserver (a setting) cannot be removed here" 1 "$rc"

echo "-- verbs and shape"
run plan bogus x;                 check_eq "unknown action refused" 1 "$rc"
run plan remove edge1 extra;      check_eq "extra arguments refused" 1 "$rc"
rc=0; timeout 10 bash "$SCRIPTS/node-change.sh" nope add x y </dev/null >/dev/null 2>&1 || rc=$?; check_eq "unknown verb exits 1" 1 "$rc"

finish
