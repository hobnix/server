#!/usr/bin/env bash
# Runtime settings (scripts/lib/setting.sh, docs/PLAN-modular-core.md step 2): the settings file wins, the old /etc/hs file
# is the fallback (on|off read as true|false), a push address keeps its old file, and the schema's `legacy` names are the
# ones setting.sh knows. No root, no server.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1
export HS_STATE_DIR=$WORK/state HS_ETC_DIR=$WORK/etc
mkdir -p "$HS_STATE_DIR" "$HS_ETC_DIR"
# shellcheck source=scripts/lib/setting.sh
. "$SCRIPTS/lib/setting.sh"
GEN="python3 $SCRIPTS/schema-gen.py"

echo "-- reading"
check "set nowhere: not set" bash -c '. "$1/lib/setting.sh"; ! setting_get language' _ "$SCRIPTS"
echo en > "$HS_ETC_DIR/language"
check_eq "the old /etc/hs file is the fallback" "en" "$(setting_get language)"
echo on > "$HS_ETC_DIR/login-message"; echo off > "$HS_ETC_DIR/backup-new-shares"
check_eq "on is true" "true" "$(setting_get loginMessage)"
check_eq "off is false" "false" "$(setting_get backupNewShares)"
check "a key without a legacy file is not set" bash -c '. "$1/lib/setting.sh"; ! setting_get webAccent' _ "$SCRIPTS"

echo "-- writing"
setting_set language de
check_eq "the settings file wins" "de" "$(setting_get language)"
check_eq "it is a plain file" "de" "$(cat "$HS_STATE_DIR/settings/language")"
check_eq "the push address keeps its old place" "$HS_STATE_DIR/notify-url" "$(setting_path notifyUrl)"
setting_set notifyUrl https://ntfy.sh/x
check_eq "and is written there" "https://ntfy.sh/x" "$(cat "$HS_STATE_DIR/notify-url")"
setting_set language ""
check_eq "an empty value removes the file; the fallback is back" "en" "$(setting_get language)"
setting_set webAccent '#112233'
setting_unset webAccent
check "unset removes it" bash -c '. "$1/lib/setting.sh"; ! setting_get webAccent' _ "$SCRIPTS"
check_eq "no temp file is left behind" "0" "$(ls "$HS_STATE_DIR/settings" | grep -c tmp || true)"

echo "-- the schema and setting.sh agree"
want=$($GEN settings | tr -d $'\r' | awk -F"$(printf '\t')" '$2 != "" {print $1 " " $2}' | sort)
have=$(sed -n '/^_setting_legacy()/,/^}/p' "$SCRIPTS/lib/setting.sh" | grep -E '^\s+[A-Za-z]+\) echo ' | sed -E 's/^\s+([A-Za-z]+)\) echo ([a-z-]+) ;;/\1 \2/' | sort)
check_eq "legacy file names" "$want" "$have"

echo "-- hs config migrate-settings"
M=$WORK/machine.toml; export HS_MACHINE_FILE=$M
rm -rf "$HS_STATE_DIR" "$HS_ETC_DIR"; mkdir -p "$HS_STATE_DIR" "$HS_ETC_DIR"
cp "$ROOT/machine.toml.example" "$M"
printf '
language = "de"
loginMessage = false
webTerminalMaxHours = 4
notifyUrl = "https://ntfy.sh/mine"
' >> "$M"
echo "https://ntfy.sh/recipe" > "$HS_STATE_DIR/notify-url"
CFG="bash $SCRIPTS/config.sh"
before=$(cat "$M")
$CFG migrate-settings --dry-run >/dev/null 2>&1
check_eq "--dry-run changes nothing" "$before" "$(cat "$M")"
$CFG migrate-settings >/dev/null 2>&1
check_eq "language moved" "de" "$(cat "$HS_STATE_DIR/settings/language")"
check_eq "a bool moved as true|false" "false" "$(cat "$HS_STATE_DIR/settings/loginMessage")"
check_eq "a number moved" "4" "$(cat "$HS_STATE_DIR/settings/webTerminalMaxHours")"
check_eq "a setting that was there already is kept" "https://ntfy.sh/recipe" "$(cat "$HS_STATE_DIR/notify-url")"
check_eq "machine.toml has none of them active any more" "0" "$(grep -cE '^(language|loginMessage|webTerminalMaxHours|notifyUrl) = ' "$M" || true)"
check_out "machine.toml still checks out" "machine.toml is fine|CHANGEME" bash "$SCRIPTS/config-read.sh" check
check_out "a second run has nothing to move" "Nothing to move" $CFG migrate-settings
check_eq "quiet mode (hs update, hs config sync) says nothing when there is nothing to move" "" "$(HS_QUIET_OK=1 $CFG migrate-settings 2>&1)"

echo "-- migrate-settings: dashboard homepage becomes web, nothing is removed"
mkdir -p "$HS_STATE_DIR/settings"; echo homepage > "$HS_STATE_DIR/settings/dashboard"
export HS_INCUS=$WORK/no-incus HS_SERVICES_DIR=$WORK/svc.d
check_out "--dry-run only says it" "dashboard = web would be set" $CFG migrate-settings --dry-run
check_eq "--dry-run changes nothing" "homepage" "$(cat "$HS_STATE_DIR/settings/dashboard")"
out=$($CFG migrate-settings 2>&1)
check_eq "homepage is now web" "web" "$(cat "$HS_STATE_DIR/settings/dashboard")"
check "it says where the dashboard is and how to remove the container" bash -c 'grep -Eq "/dashboard.*hs ct homepage remove" <<<"$1"' _ "$out"
check "webUi off: it warns" bash -c 'grep -q "needs the web interface" <<<"$1"' _ "$out"
check_eq "a second run says nothing about it" "0" "$($CFG migrate-settings 2>&1 | grep -c 'dashboard' || true)"
unset HS_INCUS HS_SERVICES_DIR

echo "-- the state after an update with the OLD update.sh (moved options in the closing section of machine.toml)"
export HS_MACHINE_EXAMPLE=$ROOT/machine.toml.example
SYNC="bash $SCRIPTS/machine-sync.sh"
rm -rf "$HS_STATE_DIR" "$HS_ETC_DIR"; mkdir -p "$HS_STATE_DIR" "$HS_ETC_DIR"
cp "$ROOT/machine.toml.example" "$M"; sed -i 's/CHANGEME/deadbeef/' "$M"
printf '\nlanguage = "de"\nicons = "nerd"\nvpsHost = "proxy.example.net"\nexpiryDomains = ["example.org"]\n' >> "$M"
check_out "check names a moved option as a runtime setting, not as unknown" "language: a runtime setting now" $SYNC check
check_out "and still calls a really unknown one unknown" "expiryDomains: unknown option" $SYNC check
HS_QUIET_OK=1 $SYNC sync >/dev/null 2>&1
check_eq "sync moved them to the settings" "de nerd proxy.example.net" "$(cat "$HS_STATE_DIR/settings/language") $(cat "$HS_STATE_DIR/settings/icons") $(cat "$HS_STATE_DIR/settings/vpsHost")"
check_eq "and none is an active line of machine.toml any more" "0" "$(grep -cE '^(language|icons|vpsHost) = ' "$M" || true)"
check_eq "a key that is really unknown stays" "1" "$(grep -c '^expiryDomains' "$M" || true)"
check_out "check is quiet about the moved ones now" "expiryDomains" $SYNC check
check_eq "no moved option is reported any more" "0" "$($SYNC check 2>&1 | grep -c 'runtime setting now' || true)"

echo "-- hs config set for a runtime setting the table does not list"
$CFG set vpsHost proxy.example.net >/dev/null 2>&1
check_eq "vpsHost goes to its file" "proxy.example.net" "$(cat "$HS_STATE_DIR/settings/vpsHost")"
check_out "a bad host is refused" "must be a host name" $CFG set vpsHost "a b;c"
check_out "a bad URL is refused" "must be an http" $CFG set proxyStatusUrl ftp://x
check_out "a number below the minimum is refused" "or more" $CFG set webTerminalMaxHours 0
check_out "--dry-run changes nothing" "Dry run" $CFG set webTerminalIdleMinutes 5 --dry-run
check_eq "and wrote nothing" "no" "$(test -e "$HS_STATE_DIR/settings/webTerminalIdleMinutes" && echo yes || echo no)"
$CFG set vpsHost none >/dev/null 2>&1
check_eq "none removes it" "no" "$(test -e "$HS_STATE_DIR/settings/vpsHost" && echo yes || echo no)"

finish
