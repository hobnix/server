#!/usr/bin/env bash
# Runs every tests/*.sh (the one place that knows the list: CI calls this, nobody lists tests by hand).
#
#   bash tests/run-all.sh [--list] [--only <glob>]... [--jobs N] [--verbose] [--root-only]
#
#   --list       show each test and whether it would run or be skipped (and why), run nothing
#   --only GLOB  only tests whose name (without .sh) matches the glob; repeatable (e.g. --only 'pool-*')
#   --jobs N     run N tests at the same time (default 1; a few tests use fixed ports/dirs, so 1 is the safe default)
#   --verbose    print the output of passing tests too (failed ones always print their last 40 lines)
#   --root-only  run only the tests that need root (what the CI "integration" job does)
#
# What is skipped, and the switch that turns it on:
#   needs root (loop devices, mounts, dm-crypt): tests that call `need_root` (found in the file itself).
#       HS_TEST_ROOT=1 runs them (you must already be root, e.g. `sudo env HS_TEST_ROOT=1 bash tests/run-all.sh`).
#   needs KVM + internet (see EXTERNAL below): HS_TEST_VM=1.
#   HS_TEST_CI=1 = we are in CI: sets REQUIRE_ALL=1, so a test that skips a part for a missing tool fails instead.
# A test that exits 77 counts as skipped, not failed. tests/lib*.sh, run.sh and the *.py files are helpers, not tests
# (the .py files are called by tests/matrix-hook.sh).
# HS_TEST_BASH = the bash that runs each test (default `bash`; on Windows set it to Git's bash, the bare `bash` is WSL's).
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
bash_bin=${HS_TEST_BASH:-bash}

# name -> why it is not run by default | the env switch that enables it.
declare -A EXTERNAL=(
  [zfs-vm]="needs Incus with KVM and the internet (a throwaway VM)|HS_TEST_VM"
)
HELPERS=" lib lib-poolfakes lib-standins run run-all "

list=false verbose=false root_only=false jobs=1
only=()
while [ $# -gt 0 ]; do
  case $1 in
    --list) list=true ;;
    --verbose|-v) verbose=true ;;
    --root-only) root_only=true ;;
    --only) shift; [ $# -gt 0 ] || { echo "--only needs a glob" >&2; exit 2; }; only+=("$1") ;;
    --jobs|-j) shift; jobs=${1:-}; case $jobs in ''|*[!0-9]*|0) echo "--jobs needs a number >= 1" >&2; exit 2 ;; esac ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
[ "${HS_TEST_CI:-}" = 1 ] && export REQUIRE_ALL=${REQUIRE_ALL:-1}

# decide <name>: prints "run" or "skip<TAB>reason"
decide() {
  local n=$1 f=$here/$1.sh why sw
  if [ -n "${EXTERNAL[$n]:-}" ]; then
    why=${EXTERNAL[$n]%%|*}
    sw=${EXTERNAL[$n]##*|}
    [ "${!sw:-}" = 1 ] || { printf 'skip\t%s (set %s=1)\n' "$why" "$sw"; return; }
  fi
  if grep -q '^need_root' "$f"; then
    if [ "${HS_TEST_ROOT:-}" != 1 ]; then printf 'skip\tneeds root, loop devices (set HS_TEST_ROOT=1 as root)\n'; return; fi
    if [ "$(id -u)" -ne 0 ]; then printf 'skip\tHS_TEST_ROOT=1 but not root\n'; return; fi
  elif $root_only; then
    printf 'skip\tnot a root test (--root-only)\n'; return
  fi
  echo run
}

names=()
for f in "$here"/*.sh; do
  n=$(basename "$f" .sh)
  case "$HELPERS" in *" $n "*) continue ;; esac
  if [ ${#only[@]} -gt 0 ]; then
    m=false
    for g in "${only[@]}"; do
      # shellcheck disable=SC2254
      case $n in $g) m=true ;; esac
    done
    $m || continue
  fi
  names+=("$n")
done
[ ${#names[@]} -gt 0 ] || { echo "no test matches" >&2; exit 2; }

if $list; then
  for n in "${names[@]}"; do
    d=$(decide "$n")
    if [ "$d" = run ]; then printf '%-22s run\n' "$n"; else printf '%-22s skip: %s\n' "$n" "${d#skip	}"; fi
  done
  exit 0
fi

out=$(mktemp -d "${TMPDIR:-/tmp}/hs-run-all.XXXXXX")
trap 'rm -rf "$out"' EXIT
now() { date +%s.%N 2>/dev/null || date +%s; }

run_one() {   # name: runs the test, prints one line, leaves <name>.res = ok|FAIL|skip
  local n=$1 t0 t1 rc secs extra=""
  t0=$(now)
  "$bash_bin" "$here/$n.sh" >"$out/$n.log" 2>&1 </dev/null
  rc=$?
  t1=$(now)
  secs=$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.1f", b - a }')
  if [ $rc -eq 0 ]; then echo ok >"$out/$n.res"
  elif [ $rc -eq 77 ]; then echo skip >"$out/$n.res"
  else echo FAIL >"$out/$n.res"; extra="  (exit $rc)"; fi
  printf '%-4s %-22s %6ss%s\n' "$(cat "$out/$n.res")" "$n" "$secs" "$extra"
}

started=$(now)
todo=()
nskip=0
for n in "${names[@]}"; do
  d=$(decide "$n")
  if [ "$d" = run ]; then
    todo+=("$n")
  else
    nskip=$((nskip + 1))
    printf '%-4s %-22s         %s\n' skip "$n" "${d#skip	}"
  fi
done

running=0
for n in "${todo[@]}"; do
  if [ "$jobs" -eq 1 ]; then run_one "$n"; continue; fi
  run_one "$n" &
  running=$((running + 1))
  if [ $running -ge "$jobs" ]; then wait -n; running=$((running - 1)); fi
done
wait

pass=0 fail=0 failed=()
for n in "${todo[@]}"; do
  case $(cat "$out/$n.res" 2>/dev/null) in
    ok) pass=$((pass + 1)) ;;
    skip) nskip=$((nskip + 1)) ;;
    *) fail=$((fail + 1)); failed+=("$n") ;;
  esac
  if $verbose && [ -f "$out/$n.log" ]; then echo "---- $n"; cat "$out/$n.log"; fi
done
for n in "${failed[@]}"; do
  echo "---- $n (last 40 lines)"
  tail -n 40 "$out/$n.log"
done
total=$(awk -v a="$started" -v b="$(now)" 'BEGIN { printf "%.1f", b - a }')
echo "== $pass passed, $fail failed, $nskip skipped, in ${total}s"
if [ $fail -gt 0 ]; then echo "failed: ${failed[*]}"; exit 1; fi
exit 0
