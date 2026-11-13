#!/usr/bin/env bash
# --plain on the command line of a script that sources lib/ui.sh switches gum off (ui=plain), like HS_PLAIN. A fake gum on PATH and a
# pseudo terminal would otherwise pick gum. Only the choice in ui.sh is tested.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
unset HS_PLAIN
mkdir -p "$WORK/bin"; printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/gum"; chmod +x "$WORK/bin/gum"
probe="$WORK/probe.sh"
printf '#!/usr/bin/env bash\n. %s/lib/ui.sh\necho "ui=$ui plain=${HS_PLAIN:-}"\n' "$SCRIPTS" > "$probe"
export PATH=$WORK/bin:$PATH
if have script; then
  with=$(script -qec "bash $probe" /dev/null </dev/null | tr -d '\r')
  without=$(script -qec "bash $probe --plain" /dev/null </dev/null | tr -d '\r')
  grep -q '^ui=gum' <<<"$with" && pass "terminal with gum: gum" || skip "no pseudo terminal here ($with)"
  grep -q '^ui=plain plain=1' <<<"$without" && pass "--plain: no gum" || fail "--plain: $without"
else
  skip "script is not installed"
fi
check_eq "HS_PLAIN set: plain" "ui=plain plain=1" "$(HS_PLAIN=1 bash "$probe")"
check_eq "a pipe without --plain: plain" "ui=plain plain=" "$(bash "$probe")"
check_eq "a pipe with --plain: plain, exported" "ui=plain plain=1" "$(bash "$probe" --plain)"
finish
