#!/usr/bin/env bash
# tests/run-all.sh --shard I/N: the parts together are the whole list, no test is in two parts, a wrong value is refused.
# Only --list is used, so no test runs here. No root, no server.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
RUN="$(dirname "$0")/run-all.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

bash "$RUN" --list | awk '{print $1}' | sort >"$T/all"
for i in 1 2 3 4; do bash "$RUN" --list --shard "$i/4" | awk '{print $1}'; done | sort >"$T/parts"
check "the four parts together are the whole list" cmp -s "$T/all" "$T/parts"
check_eq "no test is in two parts" "" "$(uniq -d "$T/parts")"
check_eq "part 1/1 is the whole list" "$(wc -l <"$T/all")" "$(bash "$RUN" --list --shard 1/1 | wc -l)"
bash "$RUN" --list --only 'run-all-*' --shard 1/2 | awk '{print $1}' >"$T/only"
check_eq "--only is applied before the split" "run-all-shard" "$(cat "$T/only")"
for bad in 0/4 5/4 2 a/b 1/0 ""; do
  bash "$RUN" --list --shard "$bad" >/dev/null 2>&1
  check_eq "--shard '$bad' is refused" 2 $?
done

finish
