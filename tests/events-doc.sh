#!/usr/bin/env bash
# The "Today" table of docs/events.md is generated from scripts/lib/event-kinds.tsv (scripts/events-doc-gen.py). No root, no server.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
GEN="python3 $SCRIPTS/events-doc-gen.py"

echo "-- the committed table is current"
check "docs/events.md is up to date (else: python3 scripts/events-doc-gen.py write)" $GEN check

echo "-- a new kind makes it stale"
tmp=$(mktemp)
cp "$SCRIPTS/lib/event-kinds.tsv" "$tmp"
printf 'x.new\tinfo\t-\ta test kind\n' >>"$tmp"
if $GEN check --tsv "$tmp" >/dev/null 2>&1; then fail "a tsv row missing in docs/events.md was not noticed"; else pass "a stale table is detected"; fi
rm -f "$tmp"

echo "-- a new package event makes it stale"
pd=$(mktemp -d)
cp "$SCRIPTS"/lib/pkg-events/*.tsv "$pd/"
printf 'pkg.sabnzbd.extra\tinfo\t-\tExtra\t-\ta test event\t-\t-\t-\t-\n' >>"$pd/sabnzbd.tsv"
if $GEN check --pkg-dir "$pd" >/dev/null 2>&1; then fail "a pkg-events row missing in docs/events.md was not noticed"; else pass "a stale package table is detected"; fi
rm -rf "$pd"

finish
