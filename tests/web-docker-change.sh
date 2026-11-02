#!/usr/bin/env bash
# Web interface, turning Docker on (scripts/web-serve.py, CHANGES "docker"): allowed and refused shapes, plan never starts, a refusal keeps its reason.
# The script behind it is tested in tests/docker-cap.sh. No root; the run of `hs` is replaced.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! have python3; then skip "python3 missing"; finish; exit 0; fi

echo "-- docker setup route"
if out=$(python3 -I "$ROOT/tests/web-docker-change-test.py" 2>&1); then pass "docker setup route tests ($(grep -E '^Ran ' <<<"$out"))"; else fail "docker setup route tests: $(tail -n 25 <<<"$out")"; fi

finish
