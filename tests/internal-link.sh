#!/usr/bin/env bash
# internal_link (scripts/recipes/_lib.sh) and the helpers of scripts/lib/internal-link.sh: the second network card of a container on the internal link
# of Incus. A stub recipe sources the real _lib.sh with a fake incus that logs what it is asked and a fake ip; no root, no server.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test HS_STATE_DIR=$WORK/state HS_ETC_DIR=$WORK/etc HS_MACHINE_FILE=$WORK/machine.toml
mkdir -p "$WORK/bin" "$HS_STATE_DIR" "$HS_ETC_DIR"
cat > "$WORK/bin/incus" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_LOG"
case "$*" in
  "network show "*) exit 0 ;;
  "config device get "*) [ -z "${DEV_NET:-}" ] || echo "$DEV_NET" ;;
  *"systemctl is-enabled"*) exit 0 ;;
  *"-- tee "*) cat > "$WORK/tee" ;;
  *"-- cat "*) exit 1 ;;
  *"ip -4 -o addr show dev eth1"*) echo "5: eth1    inet 10.99.0.2/29 scope global eth1" ;;
  *) exit 0 ;;
esac
FAKE
cat > "$WORK/bin/fakeip" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  *route*) [ -z "${IP_ROUTE:-}" ] || echo "$IP_ROUTE" ;;
  *addr*) [ -z "${IP_ADDR:-}" ] || echo "$IP_ADDR" ;;
esac
exit 0
FAKE
chmod +x "$WORK/bin/incus" "$WORK/bin/fakeip"
export PATH="$WORK/bin:$PATH" HS_INCUS=$WORK/bin/incus HS_IP=$WORK/bin/fakeip FAKE_LOG=$WORK/log WORK
cat > "$WORK/stub.sh" <<STUB
#!/usr/bin/env bash
# recipe: Demo: a stub for the test
set -euo pipefail
scripts=$SCRIPTS
state=\$HS_STATE_DIR
ct=demo
. "\$scripts/recipes/_lib.sh"
internal_link || echo rc=1
echo "link_url=[\$link_url]"
STUB
run() { : > "$FAKE_LOG"; rm -f "$WORK/tee"; bash "$WORK/stub.sh" 2>&1 </dev/null || true; }
link_file() { printf 'name=hs-internal\nsubnet=10.99.0.0/29\nhost=10.99.0.1\npeer=10.99.0.2\n' > "$HS_ETC_DIR/internal-link"; }

# 1 no file: says so, returns 1, adds nothing
out=$(run)
check_out "no internal link file: says there is none yet" "no internal link yet" echo "$out"
check_out "and internal_link returns 1" "rc=1" echo "$out"
check "and no network card is added" bash -c '! grep -q "device add" "$1"' _ "$FAKE_LOG"

# 2 file present: the card is added, the address file has no gateway
link_file
out=$(run)
check "the card is added on the Incus network" grep -q 'config device add demo hs-link nic network=hs-internal name=eth1' "$FAKE_LOG"
check "the network file gives the peer address" grep -q '^Address=10.99.0.2/29$' "$WORK/tee"
check "and has no gateway" bash -c '! grep -qi gateway "$1"' _ "$WORK/tee"
check_out "and it reports the address" "has 10.99.0.2 on the internal link" echo "$out"

# 3 the device is there already
DEV_NET=hs-internal run >/dev/null
check "device already there: no second device add" bash -c '! grep -q "device add" "$1"' _ "$FAKE_LOG"

# 4 an overlapping network is refused and the setting is named
out=$(IP_ROUTE='10.99.0.0/24 dev br0 proto kernel scope link src 10.99.0.5' run)
check_out "an overlapping route is refused and incusInternalSubnet named" "incusInternalSubnet" echo "$out"
check "and no card is added" bash -c '! grep -q "device add" "$1"' _ "$FAKE_LOG"

# 5 a VPN aggregate is no overlap
out=$(IP_ROUTE='10.0.0.0/8 via 100.64.0.1 dev tailscale0' run)
check "a route shorter than /16 (VPN aggregate) is not an overlap" bash -c '! grep -q "overlaps" <<<"$1"' _ "$out"
check "and the card is added" grep -q 'device add demo hs-link' "$FAKE_LOG"

# 6 the tunnel port: the address for the origin, and the allow-list check
printf 'tunnel=8081\n' > "$HS_ETC_DIR/gateway-public"
printf '10.99.0.2/32\n' > "$HS_ETC_DIR/gateway-tunnel-from"
out=$(run)
check_out "tunnel port on, peer allowed: link_url names the host and port" "link_url=\[http://10.99.0.1:8081\]" echo "$out"
printf '10.10.95.10/32\n' > "$HS_ETC_DIR/gateway-tunnel-from"
out=$(run)
check_out "peer not allowed: the warning names gatewayTunnelFrom" "gatewayTunnelFrom" echo "$out"

# 7 the subnet of the next rebuild: the default from defaults.nix when machine.toml lacks the key
echo '# nothing' > "$HS_MACHINE_FILE"
want=$(sed -n 's/^  incusInternalSubnet = "\(.*\)";$/\1/p' "$ROOT/config/defaults.nix")
got=$(HS_REPO=$ROOT bash -c ". '$SCRIPTS/lib/machine.sh'; . '$SCRIPTS/lib/internal-link.sh'; link_subnet_wanted")
check_eq "link_subnet_wanted reads the default when machine.toml lacks the key" "$want" "$got"
finish
