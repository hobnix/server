#!/usr/bin/env bash
# What's new in the web interface: GET/POST /api/changes/seen (scripts/web-serve.py, one revision per web user, CSRF, mode 0600) and the frontend wiring.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! have python3; then skip "python3 missing"; finish; exit 0; fi

echo "-- changes API"
if out=$(python3 -I "$ROOT/tests/web-changes-test.py" 2>&1); then pass "changes API tests ($(grep -E '^Ran ' <<<"$out"))"; else fail "changes API tests: $(tail -n 25 <<<"$out")"; fi

echo "-- frontend wiring"
W="$ROOT/web/src"
check "the route is listed" grep -q "'/operations/whats-new': WhatsNew" "$W/routes.js"
check "the tree entry is under Operations" grep -q "path: '/operations/whats-new'" "$W/nav.js"
check "the tree shows the count" grep -q "m\['/operations/whats-new'\]" "$W/shell/Shell.svelte"
check "the Summary has the banner" grep -q "go('/operations/whats-new')" "$W/pages/Summary.svelte"
check "the page never renders HTML from an entry" bash -c "! grep -q '@html' '$W/pages/WhatsNew.svelte'"
finish
