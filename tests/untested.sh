#!/usr/bin/env bash
# scripts/dev/untested.py: the list of steps that were never run on real hardware, from the markers in the guides. No root, no network.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
GEN="python3 $SCRIPTS/dev/untested.py"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/docs/changelog" "$T/capabilities/one"
printf '# One\n\n## First\n\nRun it. Not tested on hardware yet.\n\n## Second\n\n```\n# not a heading\n```\nNot tested on hardware yet.\n' >"$T/docs/one.md"
printf '# Two\n\nA step that was not run says "Not tested on hardware yet."\n' >"$T/docs/two.md"
printf '# Plan\n\nNot tested on hardware yet.\n' >"$T/docs/PLAN-x.md"
printf '# Cap\n\n## Set up\n\nNot tested on hardware yet.\n' >"$T/capabilities/one/guide.md"
printf '# Notes\n\nNot tested on hardware yet.\n' >"$T/capabilities/one/NOTES.md"
printf '# name\tdate\none\t2026-10-01\n' >"$T/docs/verified.tsv"

out=$($GEN "$T")
check_out "a guide is counted with its date" 'docs/one.md +2 +2026-10-01' printf '%s\n' "$out"
check_out "a package guide is counted" 'capabilities/one/guide.md +1 +never' printf '%s\n' "$out"
check_out "the total" 'Total \(2 files\) +3' printf '%s\n' "$out"
check_eq "a quoted marker (a rule) is not a step" "" "$(printf '%s\n' "$out" | grep 'two.md' || true)"
check_eq "plans and notes are not guides" "" "$(printf '%s\n' "$out" | grep -E 'PLAN-x|NOTES' || true)"

steps=$($GEN --steps "$T")
check_out "a step names its heading" "docs/one.md:5	First" printf '%s\n' "$steps"
check_out "a comment in a code block is not a heading" "docs/one.md:12	Second" printf '%s\n' "$steps"

all=$($GEN --all "$T")
check_out "--all reads plans" 'docs/PLAN-x.md +1' printf '%s\n' "$all"
check_out "--all reads notes" 'capabilities/one/NOTES.md +1' printf '%s\n' "$all"

mkdir "$T/empty"
check_out "nothing found is said" "No untested steps." $GEN "$T/empty"
check "an unknown folder is refused" bash -c "! $GEN $T/nonexistent"
check "the real tree is read" $GEN

finish
