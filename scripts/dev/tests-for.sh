#!/usr/bin/env bash
# Which tests does a change need? (CI, job `changes`; `scripts/dev/t changed` is the local cousin.)
#
#   scripts/dev/tests-for.sh <base-commit>     prints "all", or the test names (tests/<name>.sh) that mention a changed file, one line, space separated
#                                              (the line is empty when no test mentions any changed file)
#   scripts/dev/tests-for.sh <base> [<head>]   head defaults to HEAD
#   scripts/dev/tests-for.sh                   no base: "all"
#
# Rule: a changed tests/<name>.sh selects <name>; any other changed file selects the tests whose text mentions its name without extension
# (scripts/foo-bar.sh -> every test that says `foo-bar`), and for capabilities/<x>/ and packages/<x>/ the name <x>. Files the whole suite
# rests on select "all": scripts/lib/, tests/lib*.sh, tests/run-all.sh, config/, the workflows, this script. It is a guess made from names,
# not from a call graph: a script that another script calls is not followed. That is why the full set runs in the merge queue and every
# night on `develop`; a pull request gets the quick answer. Read-only: runs no test.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
base=${1:-}; head=${2:-HEAD}
if [ -z "$base" ] || ! git cat-file -e "$base" 2>/dev/null; then echo all; exit 0; fi
files=$(git diff --name-only "$base" "$head")
# the whole suite rests on these
if grep -qE '^(scripts/lib/|tests/lib[^/]*\.sh$|tests/run-all\.sh$|config/|\.github/workflows/|scripts/dev/tests-for\.sh$|scripts/dev/t$)' <<<"$files"; then echo all; exit 0; fi
HELPERS=" lib lib-poolfakes lib-standins run run-all "
# names too generic to tell tests apart
GENERIC=" module default index main README lib test tests "
stems=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in
    tests/*.sh) n=$(basename "$f" .sh); [ -f "$f" ] && stems="$stems"$'\n'"=$n"; continue ;;
    docs/*|*.md|.claude/*|.github/ISSUE_TEMPLATE/*) continue ;;
  esac
  s=$(basename "$f"); s=${s%.*}
  case "$GENERIC" in *" $s "*) ;; *) [ ${#s} -ge 3 ] && stems="$stems"$'\n'"$s" ;; esac
  case "$f" in capabilities/*/*|packages/*/*) d=${f#*/}; d=${d%%/*}; stems="$stems"$'\n'"$d" ;; esac
done <<<"$files"
names=$(
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    case "$s" in
      =*) echo "${s#=}" ;;
      *) grep -lF -- "$s" tests/*.sh 2>/dev/null | while read -r t; do basename "$t" .sh; done ;;
    esac
  done <<<"$stems" | sort -u | while read -r n; do
    case "$HELPERS" in *" $n "*) continue ;; esac
    [ -f "tests/$n.sh" ] && echo "$n"
  done
)
echo "$names" | tr "\n" " " | sed "s/ *$//"
