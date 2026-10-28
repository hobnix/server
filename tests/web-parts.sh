#!/usr/bin/env bash
# The part switches of the Settings page: hs sys parts list (scripts/parts.sh) and hs sys parts plan|start (scripts/part-change.sh), against a made-up
# packages folder and machine.toml. An extension without a module is switched at once (hs ext), any other part is a line in machine.toml and needs a rebuild.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en
unset HS_CALLER HS_GUIDED_TTY
T=$'\t'
has() { grep -q -- "$1" <<<"$out"; }
export HS_STATE_DIR=$WORK/state HS_MACHINE_FILE=$WORK/machine.toml HS_CAPABILITIES_FILE=$WORK/caps HS_CAPABILITIES_TSV=/dev/null HS_SETTINGS_DIR=$WORK/state/settings
export HS_PACKAGES_DIR=$WORK/packages
mkdir -p "$HS_STATE_DIR" "$HS_PACKAGES_DIR"/{metrics,games,edge-mail}
printf 'name = "metrics"\ntitle = "Metrics (Prometheus)"\nnix = "module.nix"\n' > "$HS_PACKAGES_DIR/metrics/capability.toml"; : > "$HS_PACKAGES_DIR/metrics/module.nix"
printf 'name = "games"\ntitle = "Game PCs"\nextension = true\n' > "$HS_PACKAGES_DIR/games/capability.toml"
printf 'user\text games list\tx.sh\tlist\tlist\t-\t-\n' > "$HS_PACKAGES_DIR/games/commands.tsv"
printf 'name = "edge-mail"\ntitle = "Edge mail"\n' > "$HS_PACKAGES_DIR/edge-mail/capability.toml"
printf 'hostName = "hs"\ncapabilities = ["metrics"]\n' > "$HS_MACHINE_FILE"
printf 'metrics\n' > "$HS_CAPABILITIES_FILE"
L() { bash "$SCRIPTS/parts.sh" --list; }
run() { rc=0; out=$(timeout 30 bash "$SCRIPTS/part-change.sh" "$@" </dev/null 2>/dev/null) || rc=$?; }

echo "-- registry and allowlist"
reg=$SCRIPTS/lib/registry.tsv
for r in "sys${T}sys parts list${T}parts.sh" "sys${T}sys parts plan <action>${T}part-change.sh" "sys${T}sys parts start <action>${T}part-change.sh"; do
  check "row: ${r//$T/ | }" grep -q "^$r${T}" "$reg"
done
check "READS has parts/list" grep -qF -- '("parts", "list")' "$SCRIPTS/web-serve.py"
check "CHANGES has parts" grep -q '^    "parts":' "$SCRIPTS/web-serve.py"

echo "-- list"
check_eq "metrics: on, a part with a module" "metrics${T}on${T}part${T}yes${T}yes${T}Metrics (Prometheus)" "$(L | grep '^metrics')"
check_eq "games: off, an extension without a module" "games${T}off${T}extension${T}no${T}yes${T}Game PCs" "$(L | grep '^games')"
check_eq "edge parts follow the role" "edge-mail${T}off${T}part${T}no${T}no${T}Edge mail" "$(L | grep '^edge-mail')"
check_eq "no empty field" "" "$(L | awk -F'\t' 'NF != 6 { print } { for (i = 1; i <= NF; i++) if ($i == "") print "empty" }')"

echo "-- plans"
run plan enable games
has '^status	ok$' && has 'No rebuild is needed' && has '^command	hs ext enable games$' && ! has '^confirm_name' && pass "an extension: no rebuild, nothing typed" || fail "enable games: $out"
run plan disable metrics
has "^confirm_name${T}metrics\$" && has '^danger' && has 'next hs rebuild' && pass "off with a module is red" || fail "disable metrics: $out"
run plan enable metrics;      check_eq "on already: refused" 1 "$rc"
run plan disable games;       check_eq "off already: refused" 1 "$rc"
run plan enable edge-mail;    check_eq "an edge part is refused" 1 "$rc"
run plan enable nope;         check_eq "unknown part is refused" 1 "$rc"
run plan enable "x y";        check_eq "bad name is refused" 1 "$rc"
run plan toggle games;        check_eq "unknown action is refused" 1 "$rc"
run plan enable games extra;  check_eq "extra argument is refused" 1 "$rc"

echo "-- start"
run start disable metrics
check_eq "start: done" "0:status${T}done" "$rc:$(head -n 1 <<<"$out")"
check "machine.toml lost metrics" grep -qxF 'capabilities = []' "$HS_MACHINE_FILE"
: > "$HS_CAPABILITIES_FILE"
run start enable metrics
check "and has it again" grep -qxF 'capabilities = ["metrics"]' "$HS_MACHINE_FILE"

finish
