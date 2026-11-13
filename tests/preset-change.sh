#!/usr/bin/env bash
# hs sys preset list|plan|start (scripts/preset-change.sh, preset.sh --list): the data the first-run wizard reads and changes. No server.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test HS_PYTHON=python3 PYTHONUTF8=1
export HS_STATE_DIR=$WORK/state HS_SETTINGS_DIR=$WORK/state/settings HS_MACHINE_FILE=$WORK/machine.toml
export HS_PRESETS_DIR=$WORK/presets
mkdir -p "$HS_SETTINGS_DIR" "$HS_PRESETS_DIR"
cat > "$HS_PRESETS_DIR/alpha.toml" <<'T'
title = "Alpha"
description = "The first one"
[machine]
capabilities = ["metrics", "games"]
timeZone = "Europe/Vienna"
T
cat > "$HS_PRESETS_DIR/beta.toml" <<'T'
title = "Beta"
T
printf 'timeZone = "UTC"\n' > "$WORK/machine.toml"
P="bash $SCRIPTS/preset-change.sh"

echo "-- hs sys preset list"
out=$(bash "$SCRIPTS/preset.sh" --list)
check_eq "one line per preset with four fields, - for an empty one" "$(printf 'alpha\tAlpha\tThe first one\tmetrics games\nbeta\tBeta\t-\t-')" "$out"

echo "-- plan"
out=$($P plan apply alpha 2>&1); rc=$?
check "plan exits 0" test "$rc" = 0
check_out "heading names the title" "heading.apply the preset Alpha" echo "$out"
check_out "a missing value is a step" "step.set capabilities" echo "$out"
check_out "a value that is set is kept" "note.timeZone is set already and is kept" echo "$out"
check_out "machine.toml changes are said" "note.machine.toml changes" echo "$out"
out=$($P plan apply nope 2>&1 || true)
check_out "an unknown preset is refused" "status.refused" echo "$out"
out=$($P plan apply 'Bad Name' 2>&1 || true)
check_out "a bad name is refused" "status.refused" echo "$out"

echo "-- start"
out=$($P start apply alpha 2>&1)
check_out "start answers done" "status.done" echo "$out"
check_eq "and wrote the missing value" '["metrics","games"]' "$(python3 "$SCRIPTS/machine-toml.py" get "$WORK/machine.toml" capabilities --json | tr -d ' ')"
out=$($P plan apply alpha 2>&1)
check_out "now there is nothing to set" "note.everything in this preset is set already" echo "$out"
finish
