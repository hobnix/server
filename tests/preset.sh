#!/usr/bin/env bash
# hs preset (scripts/preset.sh, scripts/preset.py, presets/*.toml): list, show, apply fills gaps only and never overwrites. No server.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test HS_PYTHON=python3 PYTHONUTF8=1
export HS_STATE_DIR=$WORK/state HS_SETTINGS_DIR=$WORK/state/settings HS_MACHINE_FILE=$WORK/machine.toml
mkdir -p "$HS_SETTINGS_DIR"
P="bash $SCRIPTS/preset.sh"

echo "-- the shipped presets"
for f in "$ROOT"/presets/*.toml; do
  n=$(basename "$f" .toml)
  check "$n: every key is an option of the schema, in the right table" python3 "$SCRIPTS/preset.py" rows "$n"
  check "$n: it has a title and a description" bash -c 'python3 "$1/preset.py" meta "$2" | awk -F"\t" "\$1==\"title\" && \$2!=\"\" {t=1} \$1==\"description\" && \$2!=\"\" {d=1} END {exit !(t&&d)}"' _ "$SCRIPTS" "$n"
done
check_out "list names both" "minimal.*\n*.*example-server|example-server" $P list

echo "-- apply fills gaps only"
cat > "$WORK/machine.toml" <<'T'
timeZone = "UTC"
T
printf 'caddy' > "$HS_SETTINGS_DIR/reverseProxy"
out=$($P apply example-server --dry-run 2>&1)
check_out "the plan says what is kept" "timeZone.*already set, kept" echo "$out"
check_out "and what will be set" "gpu.*will be set" echo "$out"
check_out "a dry run says nothing changed" "Dry run" echo "$out"
check_eq "and changes nothing" 'timeZone = "UTC"' "$(cat "$WORK/machine.toml")"
out=$($P apply example-server 2>&1 </dev/null || true)
check_out "without a terminal and without --yes it refuses" "asks first" echo "$out"
$P apply example-server --yes >/dev/null 2>&1
check_eq "an existing machine.toml value is kept" '"UTC"' "$(python3 "$SCRIPTS/machine-toml.py" get "$WORK/machine.toml" timeZone --json)"
check_eq "a missing one is set (gpu)" '"nvidia"' "$(python3 "$SCRIPTS/machine-toml.py" get "$WORK/machine.toml" gpu --json)"
check_eq "a list is written as a list" '["metrics","tailscale","games","posters"]' "$(python3 "$SCRIPTS/machine-toml.py" get "$WORK/machine.toml" capabilities --json | tr -d ' ')"
check_eq "an existing runtime setting is kept" caddy "$(cat "$HS_SETTINGS_DIR/reverseProxy")"
check_eq "a missing one is set (dashboard)" web "$(cat "$HS_SETTINGS_DIR/dashboard")"
out=$($P apply example-server --yes 2>&1)
check_out "a second apply has nothing to do" "Nothing to set" echo "$out"
out=$($P apply nonsense --yes 2>&1 || true)
check_out "an unknown preset is refused" "no preset called" echo "$out"
echo "-- scripts run from a copy (the Nix store has no presets/ or config/ folder)"
COPY=$WORK/store/scripts; CHECKOUT=$WORK/checkout
mkdir -p "$COPY" "$CHECKOUT/config"
cp -r "$SCRIPTS/." "$COPY/"; cp -r "$ROOT/presets" "$CHECKOUT/presets"; cp "$ROOT/config/schema.toml" "$CHECKOUT/config/"
: > "$CHECKOUT/machine.toml"
out=$(HS_MACHINE_FILE=$CHECKOUT/machine.toml HS_SETTINGS_DIR=$WORK/copy-settings bash "$COPY/preset.sh" show example-server 2>&1)
check_out "the presets are found beside machine.toml" "will be set" echo "$out"

finish
