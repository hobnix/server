#!/usr/bin/env bash
# scripts/lib/docker_app_doc.py: parse and check helpers. No root.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! have python3; then skip "python3 missing"; finish; exit 0; fi
echo "-- docker app doc"
if out=$(python3 -I "$ROOT/tests/docker-app-doc-test.py" 2>&1); then pass "docker app doc tests ($(grep -E '^Ran ' <<<"$out"))"; else fail "docker app doc tests: $(tail -n 25 <<<"$out")"; fi
finish