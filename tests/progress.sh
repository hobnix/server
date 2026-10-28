#!/usr/bin/env bash
# scripts/lib/ui.sh `spin` with SPIN_STREAM: a long step in a job or a log prints its newest progress line now
# and then (SnapRAID and rsync redraw one line with \r), and a failing step shows the end of its output.
# No root, no terminal.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok:   $1"; else echo "FAIL: $1 (got: $3 | want: $2)"; fail=1; fi; }

run() { HS_PLAIN=1 bash -c ". '$here/scripts/lib/ui.sh'; $1" 2>&1; }

out=$(run 'slow() { for i in 1 2 3 4; do printf "%d%%, %d MB\r" $((i*25)) $((i*100)); sleep 1; done; echo finished; }
SPIN_STREAM=1 SPIN_EVERY=2 spin "Long step" slow')
check "a progress line shows up before the end" yes "$([ "$(grep -cE '^    [0-9]+%, [0-9]+ MB' <<<"$out")" -ge 1 ] && echo yes || echo no)"
check "the step is reported as done" "1" "$(grep -c '✓ Long step' <<<"$out")"

out=$(run 'failing() { echo first; echo boom; return 3; }
SPIN_STREAM=1 SPIN_EVERY=1 spin "Failing step" failing; echo "rc=$?"')
check "a failing step returns its code" "1" "$(grep -c 'rc=3' <<<"$out")"
check "and shows what it printed" yes "$([ "$(grep -c boom <<<"$out")" -ge 1 ] && echo yes || echo no)"

out=$(run 'quiet() { echo x; }; spin "No streaming" quiet')
check "without SPIN_STREAM nothing extra is printed" "0" "$(grep -cE '^    [0-9]+%' <<<"$out")"

exit $fail
