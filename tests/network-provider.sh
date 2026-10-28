#!/usr/bin/env bash
# The network provider (capabilities/network/NOTES.md, scripts/lib/network.sh, scripts/providers/network/unifi.sh): which variant is set, the
# legacy fallback for a server with the UniFi file, migrate-settings, the verbs, and fixed_address without a connection. No server.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test HS_PYTHON=python3
export HS_STATE_DIR=$WORK/state HS_SETTINGS_DIR=$WORK/state/settings HS_ETC_DIR=$WORK/etc HS_CAPABILITIES_FILE=$WORK/etc/capabilities
mkdir -p "$HS_SETTINGS_DIR" "$HS_ETC_DIR"
. "$SCRIPTS/lib/network.sh"
. "$SCRIPTS/lib/capability.sh"

echo "-- which provider"
check_eq "nothing set, no UniFi file: no provider" "" "$(network_provider)"
check "and the capability is off" bash -c '. "$1/lib/capability.sh"; ! capability_on network' _ "$SCRIPTS"
printf 'https://r\nkey\n' > "$HS_STATE_DIR/unifi"
check_eq "an old server with the UniFi file counts as unifi" "unifi" "$(network_provider)"
check_eq "the provider says it is ready" "0" "$(bash "$SCRIPTS/providers/network/unifi.sh" ready; echo $?)"
check_eq "info names the variant" "unifi" "$(bash "$SCRIPTS/providers/network/unifi.sh" info | cut -f1)"
rm "$HS_STATE_DIR/unifi"
check_eq "without the file it is not ready" "1" "$(bash "$SCRIPTS/providers/network/unifi.sh" ready; echo $?)"

echo "-- migrate-settings sets the setting for a connected server"
printf 'https://r\nkey\n' > "$HS_STATE_DIR/unifi"
export HS_MACHINE_FILE=$WORK/machine.toml; : > "$HS_MACHINE_FILE"
bash "$SCRIPTS/config.sh" migrate-settings >/dev/null 2>&1
check_eq "networkProvider is unifi" "unifi" "$(cat "$HS_SETTINGS_DIR/networkProvider" 2>/dev/null)"
check "and the capability is on" bash -c '. "$1/lib/capability.sh"; capability_on network' _ "$SCRIPTS"
rm -f "$HS_STATE_DIR/unifi" "$HS_SETTINGS_DIR/networkProvider"

echo "-- fixed_address without a connection"
mkdir -p "$WORK/bin"
printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/bin/incus"; chmod +x "$WORK/bin/incus"
export PATH="$WORK/bin:$PATH" HS_INCUS=$WORK/bin/incus
cat > "$WORK/stub.sh" <<STUB
#!/usr/bin/env bash
# recipe: Demo: a stub for the test
set -euo pipefail
scripts=$SCRIPTS
state=\$HS_STATE_DIR
ct=demo
. "\$scripts/recipes/_lib.sh"
ip=10.0.0.5
fixed_address demo
echo done
STUB
out=$(bash "$WORK/stub.sh" 2>&1 </dev/null || true)
check_out "it says the address is not fixed and goes on" "is not fixed" echo "$out"
check_out "and the recipe continues" "done" echo "$out"
finish
