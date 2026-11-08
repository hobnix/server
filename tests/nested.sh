#!/usr/bin/env bash
# scripts/dev/nested.sh and scripts/dev/nested_lib.py (issue #262): the logic of the nested harness with a fake console and a fake incus.
# No root, no KVM, no Incus, no ISO. The harness itself (a real nested VM) is UNVERIFIED: see docs/adr/0019-nested-test-harness.md.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! have python3; then skip "python3 missing"; finish; exit 0; fi
echo "-- nested harness"
if out=$(python3 -I "$ROOT/tests/nested-test.py" 2>&1); then pass "nested harness tests ($(grep -E '^Ran ' <<<"$out"))"; else fail "nested harness tests: $(tail -n 30 <<<"$out")"; fi
finish
