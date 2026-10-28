#!/usr/bin/env bash
# hs net setup|check|ip (scripts/unifi.sh) and hs sys unifi used|reserved, against a fake curl that plays the UniFi
# controller. Needs jq (always there in CI), no root, nothing leaves the machine.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_STATE_DIR=$WORK/state
BIN=$WORK/bin; mkdir -p "$BIN" "$HS_STATE_DIR"
export CALLS=$WORK/calls; : > "$CALLS"

if ! command -v jq >/dev/null 2>&1; then skip "jq is not installed: UniFi tests not run"; finish; exit $?; fi

cat > "$BIN/curl" <<'FAKE'
#!/usr/bin/env bash
method=GET body=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method=$2; shift 2 ;;
    -d) body=$2; shift 2 ;;
    -H|-m|-w) shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
path=${url#*/proxy/network/api/s/default/}
echo "$method $path $body ($url)" >> "$CALLS"
code=${FAKE_CODE:-200}
if [ "$method" = GET ]; then
  case "$path" in
    rest/networkconf) echo '{"data":[{"name":"Default","ip_subnet":"10.10.10.1/24","dhcpd_enabled":true,"dhcpd_start":"10.10.10.100","dhcpd_stop":"10.10.10.254","_id":"n1"},{"name":"home","ip_subnet":"10.10.95.1/24","dhcpd_enabled":true,"dhcpd_start":"10.10.95.100","dhcpd_stop":"10.10.95.254","_id":"n95"},{"name":"nodhcp","ip_subnet":"10.20.0.1/24","dhcpd_enabled":false,"_id":"n20"}]}' ;;
    rest/user) echo '{"data":[{"mac":"aa:bb:cc:00:00:01","name":"web","use_fixedip":true,"fixed_ip":"10.10.95.21","_id":"u1"},{"mac":"aa:bb:cc:00:00:02","hostname":"phone","use_fixedip":false,"_id":"u2"}]}' ;;
    stat/sta) echo '{"data":[{"mac":"aa:bb:cc:00:00:09","ip":"10.10.95.45","name":"laptop"}]}' ;;
  esac
else echo '{"data":[]}'; fi
printf '\n%s' "$code"
FAKE
cat > "$BIN/ip" <<'FAKE'
#!/usr/bin/env bash
echo "default via 10.10.10.1 dev br0"
FAKE
chmod +x "$BIN"/*
export PATH=$BIN:$PATH
U="bash $SCRIPTS/unifi.sh"

echo "-- not set up"
check_out "without the file it says what to do" "UniFi is not set up.*hs net setup" $U check
check_eq "and exits with 2" "2" "$($U check >/dev/null 2>&1; echo $?)"
check_out "no argument prints the usage" "usage: hs net" $U

echo "-- hs net setup (address and key typed, then the check runs)"
out=$(printf 'https://router.test/\nSECRETKEY\n' | $U setup 2>&1)
check_eq "address (no trailing slash) and key are stored" "https://router.test
SECRETKEY" "$(cat "$HS_STATE_DIR/unifi")"
check_eq "root only" "600" "$(stat -c %a "$HS_STATE_DIR/unifi")"
check_out "the check follows and works" "The connection to https://router.test works" echo "$out"
if grep -q SECRETKEY <<<"$out"; then fail "the key is never printed"; else pass "the key is never printed"; fi
check_out "the request goes to the API of the router" "GET rest/networkconf  \(https://router.test/proxy/network/api/s/default/rest/networkconf\)" cat "$CALLS"
rm -f "$HS_STATE_DIR/unifi"
check_out "no key at all is refused" "No key entered" bash -c "printf 'https://x\n\n' | $U setup"
check "and nothing was saved" test ! -e "$HS_STATE_DIR/unifi"
echo "-- hs net setup --address --stdin (the web interface: nothing is asked)"
out=$(printf 'APIKEY2
' | $U setup --address https://r2.test/ --stdin 2>&1)
check_eq "the address and the key from stdin are stored" "https://r2.test
APIKEY2" "$(cat "$HS_STATE_DIR/unifi")"
check_out "the check follows" "The connection to https://r2.test works" echo "$out"
rm -f "$HS_STATE_DIR/unifi"
check_out "a bad address is refused" "is not an address of the router" bash -c "printf 'K
' | $U setup --address 'https://x;rm' --stdin"
check "and nothing was saved" test ! -e "$HS_STATE_DIR/unifi"
check_out "an unknown option is refused" "usage" bash -c "$U setup --bogus </dev/null"
printf 'https://router.test\nSECRETKEY\n' > "$HS_STATE_DIR/unifi"

echo "-- hs net check"
out=$($U check 2>&1)
check_out "networks with their DHCP ranges" "home +10\.10\.95\.1/24 +true +10\.10\.95\.100 +10\.10\.95\.254" echo "$out"
check_out "the client counts" "Known clients: 2, with a fixed IP: 1" echo "$out"
check_eq "the ranges are saved for hs ct list (only networks with DHCP)" "10.10.10.100 10.10.10.254
10.10.95.100 10.10.95.254" "$(cat "$HS_STATE_DIR/dhcp-ranges")"
check_out "a wrong key says what to do" "API key is wrong" env FAKE_CODE=401 $U check
check_out "another error shows the code" "UniFi answered 500" env FAKE_CODE=500 $U check

echo "-- hs sys unifi used / reserved"
check_eq "a reserved address" $'aa:bb:cc:00:00:01\tweb\treserved' "$($U used 10.10.95.21)"
check_eq "an address in use right now" $'aa:bb:cc:00:00:09\tlaptop\tonline' "$($U used 10.10.95.45)"
check_eq "a free address prints nothing" "" "$($U used 10.10.95.99)"
check_out "not an address: usage" "usage" $U used banana
check_eq "reserved for a MAC (case does not matter)" "10.10.95.21" "$($U reserved AA:BB:CC:00:00:01)"
check_eq "no reservation prints nothing" "" "$($U reserved aa:bb:cc:00:00:02)"

echo "-- reserving addresses (hs net set-ip, clear-ip; hs net ip calls them)"
check_out "a known client: PUT" "reserve 10\.10\.95\.25 in 'home' for aa:bb:cc:00:00:02 \(known client, PUT rest/user/u2\)" $U set-ip aa:bb:cc:00:00:02 10.10.95.25 phone --dry-run
check_out "an unknown MAC: POST" "new client, POST rest/user" $U set-ip aa:bb:cc:00:00:77 10.10.95.26 --dry-run
check_out "inside the DHCP range is refused" "lies in the DHCP range of 'home'" $U set-ip aa:bb:cc:00:00:02 10.10.95.150
check_out "an address of someone else is refused" "10\.10\.95\.21 is already taken" $U set-ip aa:bb:cc:00:00:02 10.10.95.21
check_out "the same MAC may keep its address" "reserve 10\.10\.95\.21" $U set-ip aa:bb:cc:00:00:01 10.10.95.21 --dry-run
check_out "no network for the address" "No UniFi network contains 192.168.1.5" $U set-ip aa:bb:cc:00:00:02 192.168.1.5
check_out "outside the writable networks is refused" "Refused: 10\.20\.0\.5 is outside the networks" $U set-ip aa:bb:cc:00:00:02 10.20.0.5 --dry-run
check_out "the default network is refused too" "Refused: 10\.10\.10\.50 is outside" $U set-ip aa:bb:cc:00:00:02 10.10.10.50 --dry-run
printf '10.20.0.0/24
' > "$HS_STATE_DIR/unifi-write-networks"
check_out "a network without DHCP takes any address once allowed" "reserve 10\.20\.0\.5 in 'nodhcp'" $U set-ip aa:bb:cc:00:00:02 10.20.0.5 --dry-run
check_out "and VLAN 95 is now refused" "Refused: 10\.10\.95\.30 is outside" $U set-ip aa:bb:cc:00:00:02 10.10.95.30 --dry-run
check_out "clear: a reservation outside is refused" "Refused: 10\.10\.95\.21 is outside" $U clear-ip aa:bb:cc:00:00:01
rm -f "$HS_STATE_DIR/unifi-write-networks"
: > "$CALLS"
check_out "the real call says what happens" "UniFi: 10\.10\.95\.25 is reserved for aa:bb:cc:00:00:02 \(phone\) in 'home'" $U set-ip aa:bb:cc:00:00:02 10.10.95.25 phone
check_out "the request is a PUT with the fixed address" 'PUT rest/user/u2 \{"use_fixedip":true,"fixed_ip":"10.10.95.25","network_id":"n95","name":"phone"\}' cat "$CALLS"
: > "$CALLS"
$U set-ip aa:bb:cc:00:00:77 10.10.95.26 >/dev/null
check_out "a new client is created with its MAC" 'POST rest/user .*"mac":"aa:bb:cc:00:00:77"' cat "$CALLS"
check_out "clear: dry run" "remove the reservation of aa:bb:cc:00:00:01 \(PUT rest/user/u1\)" $U clear-ip aa:bb:cc:00:00:01 --dry-run
check_out "clear: an unknown MAC is no error" "does not know aa:bb:cc:00:00:55, nothing to remove" $U clear-ip aa:bb:cc:00:00:55
: > "$CALLS"
check_out "clear: removed" "reservation of aa:bb:cc:00:00:01 removed" $U clear-ip aa:bb:cc:00:00:01
check_out "clear sends use_fixedip=false" 'PUT rest/user/u1 \{"use_fixedip":false\}' cat "$CALLS"

echo "-- the script calls only what it needs"
: > "$CALLS"
check_out "a foreign endpoint is refused" "Refused: this script may not call DELETE rest/networkconf" bash -c ". $SCRIPTS/lib/ui.sh; sed -n '/^api() {/,/^}/p' $SCRIPTS/unifi.sh > $WORK/api.sh; url=u key=k site=default; . $WORK/api.sh; api DELETE rest/networkconf"
check_eq "and nothing was sent" "" "$(cat "$CALLS")"

echo "-- through the registry"
fake=$WORK/reg; mkdir -p "$fake/lib"
cp "$SCRIPTS"/lib/hs.sh "$SCRIPTS"/lib/capability.sh "$SCRIPTS"/lib/registry-load.sh "$SCRIPTS"/lib/ui.sh "$SCRIPTS"/lib/secret.sh "$SCRIPTS"/lib/vault.sh "$SCRIPTS"/lib/crypt.sh "$SCRIPTS"/lib/i18n.sh "$SCRIPTS"/lib/setting.sh "$SCRIPTS"/lib/job.sh "$SCRIPTS/lib/registry.tsv" "$fake/lib/"; cp -r "$SCRIPTS"/lib/i18n "$fake/lib/"
cp "$SCRIPTS/unifi.sh" "$fake/"
F="env HS_CALLER=t HS_COMPLETE_DIR=$WORK/complete bash $fake/lib/hs.sh"
check_out "hs net check" "The connection to https://router.test works" $F net check
check_eq "hs sys unifi used" $'aa:bb:cc:00:00:01\tweb\treserved' "$($F sys unifi used 10.10.95.21)"
check_eq "hs sys unifi reserved" "10.10.95.21" "$($F sys unifi reserved aa:bb:cc:00:00:01)"
finish
