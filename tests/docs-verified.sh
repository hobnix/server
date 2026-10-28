#!/usr/bin/env bash
# hs docs verified: the "last checked on the server" date per guide, shown under the title by docs-build.sh. No root, no network.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1
REPO=$WORK/repo; mkdir -p "$REPO/docs"
printf '# Eins\n\nText eins.\n' > "$REPO/docs/Eins.md"
printf '# Zwei Anleitung\n\nText zwei.\n' > "$REPO/docs/Zwei Anleitung.md"
printf '# Plan\n' > "$REPO/docs/PLAN-etwas.md"
printf '# Index\n' > "$REPO/docs/README.md"
export HS_REPO=$REPO
dv() { bash "$SCRIPTS/docs-verified.sh" "$@"; }

echo "-- summary and list"
check_out "no row means never" "verified=0" dv --summary
check_out "two guides, plans and README do not count" "total=2" dv --summary
check_out "the list says never" "Eins.*never" dv list

echo "-- marking"
check "a guide is marked for a day" dv Eins 2026-10-01
check_out "the row is in the file" "^Eins	2026-10-01" cat "$REPO/docs/verified.tsv"
check "a part of the name is enough" dv anleitung 2026-10-20
check_out "summary counts both and names the oldest" "verified=2" dv --summary
check_out "oldest" "oldest=2026-10-01" dv --summary
check "marking again replaces the row" dv Eins 2026-10-05
check_eq "still one row per guide" 2 "$(grep -vc '^#' "$REPO/docs/verified.tsv")"
check "a wrong date is refused" bash -c "! bash $SCRIPTS/docs-verified.sh Eins 2026-13-45"
check "a day to come is refused" bash -c "! bash $SCRIPTS/docs-verified.sh Eins 2999-01-01"
check "an unknown guide is refused" bash -c "! bash $SCRIPTS/docs-verified.sh nonexistent"

echo "-- the built pages"
OUT=$WORK/site
check_out "it builds" "Documentation built" bash "$SCRIPTS/docs-build.sh" --out "$OUT"
check_out "the date is under the title" "Last worked through on a real server: 2026-10-05" cat "$OUT/en/eins.md"
check_eq "the title stays the first line" "# Eins" "$(head -n1 "$OUT/en/eins.md")"
check_out "the text follows" "Text eins" cat "$OUT/en/eins.md"
rm -f "$REPO/docs/verified.tsv"
bash "$SCRIPTS/docs-build.sh" --out "$OUT" >/dev/null 2>&1 || true
check_out "a guide without a row says never" "never" cat "$OUT/en/eins.md"
check_eq "the stamp is no HTML" "" "$(grep -E '<[a-z]' "$OUT/en/eins.md" || true)"

finish
