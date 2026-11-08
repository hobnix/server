#!/usr/bin/env bash
# scripts/lib/iommu.py: IOMMU group listing and findings from /sys fixtures. No root.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! have python3; then skip "python3 missing"; finish; exit 0; fi
echo "-- iommu groups"
if out=$(python3 -I "$ROOT/tests/iommu-test.py" 2>&1); then pass "iommu tests ($(grep -E '^Ran ' <<<"$out"))"; else fail "iommu tests: $(tail -n 25 <<<"$out")"; fi
finish
