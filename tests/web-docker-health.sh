#!/usr/bin/env bash
# The Docker health rows as tree notes and a banner (web/src/pages/docker/health.js), run with node.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! command -v node >/dev/null 2>&1; then skip "node is not installed"; finish; exit 0; fi
node "$SCRIPTS/../tests/web-docker-health.mjs"
rc=$?
check_eq "the docker health tests pass" 0 "$rc"
finish
