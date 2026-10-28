#!/usr/bin/env bash
# hs cheatsheet: the German one-page cheat sheet made from the `cheat:<group>` flags of the registry. No root.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1
REG=$SCRIPTS/lib/registry.tsv
CS="bash $SCRIPTS/cheatsheet.sh"
GROUPS_OK="server disks shares users backup update trouble"

echo "-- the flags"
n=$(grep -a -v '^#' "$REG" | grep -a -c 'cheat:')
if [ "$n" -ge 20 ] && [ "$n" -le 25 ]; then pass "20 to 25 commands are on the sheet ($n)"; else fail "20 to 25 commands are on the sheet (got $n)"; fi
bad=""
while IFS=$'\t' read -r kind path _ _ _ _ flags; do
  case ",${flags:-}," in *,cheat:*) ;; *) continue ;; esac
  [ "$kind" = user ] || bad="$bad notuser:$path"
  case ",${flags:-}," in *,legacy:*) bad="$bad legacy:$path" ;; esac
  g=$(tr ',' '\n' <<<"$flags" | sed -n 's/^cheat://p')
  case " $GROUPS_OK " in *" $g "*) ;; *) bad="$bad group:$path($g)" ;; esac
  [ "$(tr ',' '\n' <<<"$flags" | grep -c '^cheat:')" = 1 ] || bad="$bad twice:$path"
done < <(grep -av '^#' "$REG")
check_eq "cheat rows are user rows, listed, with one known group" "" "$bad"
dead=""
while IFS=$'\t' read -r kind path script _ _ _ flags; do
  case ",${flags:-}," in *,cheat:*) ;; *) continue ;; esac
  [ -f "$SCRIPTS/$script" ] || dead="$dead $path"
done < <(grep -av '^#' "$REG")
check_eq "their scripts exist" "" "$dead"
check_out "the sheet has its own row (reads, docs)" "topic:docs,reads" grep -a "^user	cheatsheet	" "$REG"

echo "-- the page"
out=$($CS)
check_out "a German title" "^# Spickzettel" echo "$out"
for t in "Den Server ansehen" "Platten und Speicher" "Freigaben" "Benutzer" "Sicherung" "Aktualisieren" "Wenn etwas klemmt"; do
  check_out "section $t" "^## $t" echo "$out"
done
missing=""
while IFS=$'\t' read -r kind path _ _ _ _ flags; do
  case ",${flags:-}," in *,cheat:*) ;; *) continue ;; esac
  grep -qF -- "| \`hs $path\` |" <<<"$out" || missing="$missing $path"
done < <(grep -av '^#' "$REG")
check_eq "every flagged command is on the page" "" "$missing"
check_eq "and only those (one table row each)" "$n" "$(grep -c '^| `hs ' <<<"$out")"
check_eq "no row without a text" "0" "$(grep -c '^| `hs [^|]*` |  *|$' <<<"$out")"
lines=$(wc -l <<<"$out")
if [ "$lines" -le 75 ]; then pass "fits one page ($lines lines)"; else fail "fits one page ($lines lines)"; fi
check_out "a value is written in angle brackets" 'hs disk <disk> health' echo "$out"
check_eq "--out writes the same text to a file" "$out" "$($CS --out "$WORK/s.md" && cat "$WORK/s.md")"
check_eq "a wrong option fails" "1" "$($CS --nope >/dev/null 2>&1; echo $?)"

echo "-- the docs site"
# The guides are English only (docs-build.sh builds en/): the German sheet stays a command (`hs cheatsheet --out`), not a page.
SITE=$WORK/site
HS_DOCS_NO_FETCH=1 bash "$SCRIPTS/docs-build.sh" --out "$SITE" --quiet >/dev/null 2>&1 || true
check "docs build still runs" test -s "$SITE/en/start.md"
check "it writes no German page" test ! -e "$SITE/de/spickzettel.md"

finish
