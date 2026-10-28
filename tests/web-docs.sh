#!/usr/bin/env bash
# The guides of the web interface: GET /api/docs/index|page|search (scripts/web-serve.py) against a fake docs folder: session, capability, names, search.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! have python3; then skip "python3 missing"; finish; exit 0; fi

echo "-- docs API"
if out=$(python3 -I "$ROOT/tests/web-docs-test.py" 2>&1); then pass "docs API tests ($(grep -E '^Ran ' <<<"$out"))"; else fail "docs API tests: $(tail -n 25 <<<"$out")"; fi

echo "-- the capability"
check "the manifest is there" test -s "$ROOT/capabilities/docs/capability.toml"
check "configuration.nix switches it on with the web interface" grep -q 'optional (webUi && machine.webDocs) "docs"' "$ROOT/configuration.nix"
check "the nav node of the page is gated by it" grep -q "path: '/docs', prefix: true, capability: 'docs'" "$ROOT/web/src/nav.js"
finish
