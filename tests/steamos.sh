#!/usr/bin/env bash
# The steamos recipe (syntax, dry run, header). No root, no incus.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test
export HS_STATE_DIR=$WORK/state
mkdir -p "$HS_STATE_DIR"
R=$ROOT/packages/steamos/run.sh

check "steamos.sh parses" bash -n "$R"
check "recipe has a German one-liner" grep -q '^# recipe.de: ' "$R"
check_out "dry run names the container" "container 'steamos'" bash "$R" --dry-run
check "no Docker in the recipe" bash -c '! grep -qE "^ *(install_docker|nvidia_docker)" "$1"' _ "$R"
check "no raw.lxc device rule (it stops the container from booting)" bash -c '! grep -q "^ *incus config set .*raw.lxc" "$1"' _ "$R"
check "VNC is flagged as an admin port" grep -q "steamos.*5900" "$SCRIPTS/ports.sh"
finish
