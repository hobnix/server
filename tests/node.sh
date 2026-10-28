#!/usr/bin/env bash
# Nodes: hs node list|show|add|remove|key|status (scripts/node.sh) and the forced command scripts/node-remote.sh.
# A stand-in for ssh (HS_SSH): no root, no other server. Proves the registry file, the implicit proxyserver node of the vps capability, that the
# only word ever sent is `status`, that the private key is only a PATH in the ssh command line, and the refusals.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en
unset HS_CALLER HS_GUIDED_TTY
T=$'\t'
export HS_STATE_DIR=$WORK/state HS_RUN_DIR=$WORK/run HS_VAULT_DIR=$WORK/vault HS_MACHINE_FILE=$WORK/machine.toml HS_SETTINGS_DIR=$WORK/state/settings HS_NOW=1000
mkdir -p "$HS_STATE_DIR" "$HS_RUN_DIR"
printf 'hostName = "hs"\n' > "$HS_MACHINE_FILE"
N() { rc=0; out=$(timeout 30 bash "$SCRIPTS/node.sh" "$@" </dev/null 2>"$WORK/err") || rc=$?; }
has() { grep -q -- "$1" <<<"$out"; }

echo "-- registry rows"
reg=$SCRIPTS/lib/registry.tsv
for r in "sys${T}sys node list${T}node.sh" "sys${T}sys node show <name>${T}node.sh" "sys${T}sys node status <name>${T}node.sh" "sys${T}sys node remote${T}node-remote.sh" \
         "user${T}node list${T}node.sh" "user${T}node show${T}node.sh" "user${T}node add${T}node.sh" "user${T}node remove${T}node.sh" "user${T}node key${T}node.sh" "user${T}node status${T}node.sh"; do
  check "row: ${r//$T/ | }" grep -q "^$r${T}" "$reg"
done
for k in '("node", "list")' '("node", "show")' '("node", "status")'; do
  check "READS has $k" grep -qF -- "$k" "$SCRIPTS/web-serve.py"
done
check "READS has (\"node\", \"keyline\")" grep -qF -- '("node", "keyline")' "$SCRIPTS/web-serve.py"
check "CHANGES has the entry node (scripts/node-change.sh; tests/web-node-change.sh)" grep -q '^    "node":' "$SCRIPTS/web-serve.py"

echo "-- empty registry"
N --list
check_eq "no node: no lines, exit 0" "0:" "$rc:$out"
N show nope
check_eq "unknown node: exit 1" 1 "$rc"

echo "-- add"
N add cousin cousin-server.tail.ts.net
check_eq "add a peer: exit 0" 0 "$rc"
N --list
check_eq "list: name kind host port source key" "cousin${T}peer${T}cousin-server.tail.ts.net${T}22${T}file${T}missing" "$out"
N add vps2 10.0.0.9 --kind vps
N --list
check_eq "vps kind defaults to port 2222" "vps2${T}vps${T}10.0.0.9${T}2222${T}file${T}missing" "$(grep '^vps2' <<<"$out")"
check_eq "the file has five fields and no empty one" "" "$(awk -F'\t' 'NF != 5 { print } { for (i = 1; i <= NF; i++) if ($i == "") print "empty" }' "$HS_STATE_DIR/nodes.tsv")"
N add cousin other.host
check_eq "a second node of the same name is refused" 1 "$rc"
for bad in "Cousin" "a b" "-x" "local" "main" "x/y" "1abc" ""; do
  N add "$bad" host.example
  check_eq "name '$bad' is refused" 1 "$rc"
done
for h in "-oProxyCommand=id" "a b" "a..b" "x;id" ""; do
  N add okname "$h"
  check_eq "host '$h' is refused" 1 "$rc"
done
N add okname host.example --port 0;      check_eq "port 0 is refused" 1 "$rc"
N add okname host.example --port 70000;  check_eq "port 70000 is refused" 1 "$rc"
N add okname host.example --kind shell;  check_eq "kind shell is refused" 1 "$rc"
N add okname host.example --bogus;       check_eq "unknown option is refused" 1 "$rc"
check_eq "nothing of that was written" 2 "$(wc -l < "$HS_STATE_DIR/nodes.tsv" | tr -d ' ')"

echo "-- show"
N --show cousin
for kv in "name${T}cousin" "kind${T}peer" "user${T}adminuser" "port${T}22" "words${T}status" "key${T}missing"; do
  has "^$kv\$" && pass "show: ${kv//$T/=}" || fail "show lacks $kv: $out"
done
N --show vps2
has "^user${T}root\$" && pass "a vps node logs in as root" || fail "vps user: $out"
has "^command${T}.* -p 2222 .*root@10.0.0.9 status\$" && pass "the command ends with the one word" || fail "command: $out"

echo "-- the implicit proxyserver node of the vps capability"
mkdir -p "$HS_SETTINGS_DIR"
printf 'proxy.tail.ts.net\n' > "$HS_SETTINGS_DIR/vpsHost"
N --list
check_eq "proxyserver is listed from vpsHost" "proxyserver${T}vps${T}proxy.tail.ts.net${T}2222${T}setting${T}missing" "$(grep '^proxyserver' <<<"$out")"
echo x > "$HS_STATE_DIR/vps-key"
N --list
check_eq "and uses the old vps-key" "ok" "$(awk -F'\t' '$1 == "proxyserver" { print $6 }' <<<"$out")"
N remove proxyserver --yes
check_eq "the implicit node cannot be removed here" 1 "$rc"
N key proxyserver
check_eq "its key is made by hs vps key, not here" 1 "$rc"
N add proxyserver other.host --kind vps
N --list
check_eq "a real row of that name wins" "proxyserver${T}vps${T}other.host${T}2222${T}file" "$(awk -F'\t' '$1 == "proxyserver" { print $1 FS $2 FS $3 FS $4 FS $5 }' <<<"$out")"
N remove proxyserver --yes
rm -f "$HS_SETTINGS_DIR/vpsHost"

echo "-- status through a stand-in for ssh"
FAKE=$WORK/fakessh
cat > "$FAKE" <<'EOS'
#!/usr/bin/env bash
for a in "$@"; do printf '%s\n' "$a"; done > "$FAKE_LOG"
if [ -n "${FAKE_FAIL:-}" ]; then exit 255; fi
printf '%s\n' "${FAKE_OUT:-{\"schema\":1,\"kind\":\"homeserver\",\"host\":\"cousin\",\"problems\":0}}"
EOS
chmod +x "$FAKE"
export HS_SSH=$FAKE FAKE_LOG=$WORK/sshargs
N --status cousin
check_eq "no key yet: exit 1" 1 "$rc"
has 'hs node key cousin' || grep -q 'hs node key cousin' "$WORK/err" && pass "points at hs node key" || fail "no key hint"
check "ssh was not run without a key" test ! -e "$FAKE_LOG"
if command -v ssh-keygen >/dev/null 2>&1; then
  N key cousin
  check_eq "key: exit 0" 0 "$rc"
  check "the private key exists" test -s "$HS_STATE_DIR/node-key-cousin"
  pub=$(grep -c '^restrict,command="/etc/nixos/scripts/node-remote.sh" ssh-ed25519 ' <<<"$out")
  check_eq "prints the forced-command line for a peer" 1 "$pub"
  body=$(sed -n '2p' "$HS_STATE_DIR/node-key-cousin")
  check_eq "the output holds no private key text" 0 "$(grep -c -e PRIVATE -e "$body" <<<"$out" | tr -d ' ')"
  c1=$(cksum < "$HS_STATE_DIR/node-key-cousin")
  N key cousin
  check_eq "a second run changes nothing" "$c1" "$(cksum < "$HS_STATE_DIR/node-key-cousin")"
  N key vps2
  has '^webKey = "ssh-ed25519 ' && pass "a vps node gets a webKey line" || fail "vps key line: $out"
  N --keyline cousin
  has '^key'"${T}"'ok$' && has '^line'"${T}"'restrict,command="/etc/nixos/scripts/node-remote.sh" ssh-ed25519 ' && pass "keyline: the line for the other server" || fail "keyline: $out"
  check_eq "keyline: no private key text" 0 "$(grep -c PRIVATE <<<"$out" | tr -d ' ')"
  N --keyline nope
  check_eq "keyline: unknown node exit 1" 1 "$rc"
else
  skip "ssh-keygen missing: key creation"
  echo x > "$HS_STATE_DIR/node-key-cousin"
fi
N --status cousin
check_eq "status: exit 0" 0 "$rc"
check_eq "status: the JSON document, one line" '{"schema":1,"kind":"homeserver","host":"cousin","problems":0}' "$out"
args=$(tr '\n' ' ' < "$FAKE_LOG")
case "$args" in *"-i $HS_STATE_DIR/node-key-cousin "*) pass "the key is a path" ;; *) fail "args: $args" ;; esac
case "$args" in *"-p 22 "*"adminuser@cousin-server.tail.ts.net status ") pass "peer: adminuser@host, the one word status last" ;; *) fail "args: $args" ;; esac
case "$args" in *"BatchMode=yes"*"IdentitiesOnly=yes"*"IdentityAgent=none"*) pass "no agent, no password prompt" ;; *) fail "options: $args" ;; esac
check_eq "exactly one word after the host" 1 "$(grep -c '^status$' "$FAKE_LOG")"
check_eq "no private key text in the arguments" 0 "$(grep -c 'PRIVATE' "$FAKE_LOG")"
FAKE_FAIL=1 N --status cousin
check_eq "no answer: exit 1" 1 "$rc"
FAKE_OUT='<html>nope' N --status cousin
check_eq "an answer that is not a JSON object: exit 1" 1 "$rc"
N status cousin
check_eq "people's status: exit 0" 0 "$rc"
N --status 'a;id'
check_eq "a bad name never reaches ssh" 1 "$rc"
N --status 'cousin extra'
check_eq "one argument only" 1 "$rc"

echo "-- remove"
N remove cousin
check_eq "without --yes and without a terminal nothing is removed" 1 "$rc"
N remove cousin --yes
check_eq "remove --yes: exit 0" 0 "$rc"
N --list
check_eq "gone from the list" 0 "$(grep -c '^cousin' <<<"$out")"
N remove cousin --yes
check_eq "removing it again fails" 1 "$rc"

echo "-- the forced command (node-remote.sh)"
R() { rc=0; out=$(SSH_ORIGINAL_COMMAND="$1" HS_DECK_FILE=$WORK/deck.json HS_DECK_STATUS=$WORK/fake-deck.sh timeout 20 bash "$SCRIPTS/node-remote.sh" </dev/null 2>"$WORK/err") || rc=$?; }
printf '{"kind":"homeserver","from":"file"}\n' > "$WORK/deck.json"
printf '#!/usr/bin/env bash\necho {\\"from\\":\\"script\\"}\n' > "$WORK/fake-deck.sh"
R status
check_eq "status: the deck file" '0:{"kind":"homeserver","from":"file"}' "$rc:$out"
rm -f "$WORK/deck.json"
R status
check_eq "status without a file: the script runs" '0:{"from":"script"}' "$rc:$out"
for w in "" "update" "watch" "bash" "status extra" "status;id" 'status && id' "status
id" '$(id)' "STATUS" " status" "status " "../status" "-o ProxyCommand=id" "sh -c id" "cat /etc/shadow"; do
  R "$w"
  check_eq "refused with exit 2: '$(printf '%s' "$w" | head -c 20 | tr '\n' ' ')'" "2:" "$rc:$out"
done

finish
