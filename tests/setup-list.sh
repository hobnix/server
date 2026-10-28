#!/usr/bin/env bash
# hs sys setup list (scripts/setup-list.sh): the first-run checklist as plain rows. No server: every place it looks at is a knob.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_STATE_DIR=$WORK/state HS_SETTINGS_DIR=$WORK/state/settings HS_ETC_DIR=$WORK/etc HS_MACHINE_FILE=$WORK/machine.toml HS_SETUP_BULK=$WORK/bulk HS_PYTHON=python3
mkdir -p "$HS_SETTINGS_DIR" "$HS_ETC_DIR" "$WORK/bulk"
: > "$HS_MACHINE_FILE"
run() { bash "$SCRIPTS/setup-list.sh" --list 2>&1; }
state_of() { run | awk -F'\t' -v id="$1" '$1 == id { print $2 }'; }

echo "-- a bare server"
out=$(run)
check_eq "every row has five fields" "" "$(awk -F'\t' 'NF != 5' <<<"$out")"
check_eq "language is open" open "$(state_of language)"
check_eq "storage is open (no mount point)" open "$(state_of storage)"
check_eq "no vault row while there is no vault" "" "$(state_of vault)"
check_eq "finished is the last row and open" "finished open" "$(tail -n1 <<<"$out" | cut -f1,2 | tr '\t' ' ')"
check_out "an open row names the command" "hs config set language" echo "$out"

echo "-- things get done"
printf 'de' > "$HS_SETTINGS_DIR/language"
check_eq "language is done" done "$(state_of language)"
check_eq "and its command is a dash" "-" "$(run | awk -F'\t' '$1 == "language" { print $4 }')"
printf 'timeZone = "Europe/Vienna"\n' > "$HS_MACHINE_FILE"
check_eq "time zone is done (machine.toml)" done "$(state_of timezone)"
printf 'https://ntfy.sh/x\n' > "$HS_STATE_DIR/notify-url"
check_eq "notifications are done" done "$(state_of notifications)"
rm -f "$HS_STATE_DIR/notify-url"
check_eq "without an address the entry is open" open "$(state_of notifications)"
check_out "and turns the part on with a setting, no rebuild" "hs config set notifications true" run
printf 'true' > "$HS_SETTINGS_DIR/notifications"
check_eq "the entry is done once the part is on" done "$(state_of notifications)"
rm -f "$HS_SETTINGS_DIR/notifications"
printf 'https://ntfy.sh/x\n' > "$HS_STATE_DIR/notify-url"
mkdir -p "$WORK/bulk/shares/media"
check_eq "a first share is done" done "$(state_of share)"
printf 'metrics\n' > "$HS_ETC_DIR/capabilities"
check_eq "optional parts are done once any is on" done "$(state_of parts)"
printf 'true' > "$HS_SETTINGS_DIR/setupDone"
check_eq "finished follows setupDone" done "$(state_of finished)"
echo "-- the wildcard row exists only while the gateway proxy is on"
printf 'cloud
' > "$HS_ETC_DIR/capabilities"
check_eq "no gateway-dns row while gateway is off" "" "$(state_of gateway-dns)"
printf 'gateway
' > "$HS_ETC_DIR/capabilities"
cat > "$WORK/resolve-ok" <<'EOF2'
#!/bin/sh
echo "192.168.1.10 STREAM x"
EOF2
cp "$WORK/resolve-ok" "$WORK/resolve-bad"; sed -i 's/192.168.1.10/192.168.1.99/' "$WORK/resolve-bad"
chmod +x "$WORK/resolve-ok" "$WORK/resolve-bad"
printf 'hostName = "homeserver"
adDomain = { realm = "AD.EXAMPLE.ORG", workgroup = "EX" }
' > "$HS_MACHINE_FILE"
echo homeserver > "$WORK/site-name"
export HS_SITE_NAME_FILE=$WORK/site-name HS_HOST_IP=192.168.1.10
export HS_GATEWAY_RESOLVE=$WORK/resolve-bad
check_eq "gateway-dns is open when the wildcard points elsewhere" open "$(state_of gateway-dns)"
check_out "and names hs gateway check" "hs gateway check" run
export HS_GATEWAY_RESOLVE=$WORK/resolve-ok
check_eq "gateway-dns is done when the wildcard works" done "$(state_of gateway-dns)"
finish
