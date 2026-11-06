#!/usr/bin/env bash
# Every button of the web interface is ui/Button.svelte: no bare `<button class="btn ...">` outside it (allow-list and reasons in
# tests/web-buttons-test.py). Plain static check, no node needed.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
out=$(python3 "$ROOT/tests/web-buttons-test.py" 2>&1)
rc=$?
[ -z "$out" ] || echo "$out"
check_eq "no bare <button class=\"btn\"> outside ui/Button.svelte" 0 "$rc"
finish
