#!/usr/bin/env bash
# SessionStart hook (.claude/settings.json): a few facts so a fresh session does not have to read files to get oriented.
# Prints the hook's JSON answer (hookSpecificOutput.additionalContext). Keep it under about 20 lines; it is paid for in every session.
cd "$(dirname "$0")/../.." || exit 0
branch=$(git branch --show-current 2>/dev/null)
dirty=$(git status --short 2>/dev/null | wc -l | tr -d ' ')
ahead=$(git rev-list --count main..HEAD 2>/dev/null)
text="Branch ${branch:-?}: ${ahead:-?} commits ahead of main, ${dirty:-?} changed files."
# open tasks: TODO.md items are "N. [ ]" / "N. [~]" under headings "## A. ..."; the id is the section letter plus the number (A1, B3)
tasks=$(awk '
  /^## [A-Z]\./ { sec = substr($2, 1, 1); next }
  /^[0-9]+\. \[[ ~]\]/ { n = $1; sub(/\./, "", n); st = substr($2, 2, 1); t = $0; sub(/^[0-9]+\. \[[ ~]\] /, "", t); printf "%s%s [%s] %s\n", sec, n, (st == "~" ? "~" : " "), substr(t, 1, 90); if (++c >= 4) exit }
' TODO.md 2>/dev/null)
[ -z "$tasks" ] || text="$text
Open tasks (TODO.md; /work <id> runs one):
$tasks"
last=$(ls -t .work/test-logs/*.log 2>/dev/null | head -n 1)
[ -z "$last" ] || text="$text
Last test log: ${last#./}"
[ ! -d .work ] || { open=$(find .work -maxdepth 2 -name spec.md 2>/dev/null | sed 's|^\./||; s|/spec.md$||' | paste -sd' '); [ -z "$open" ] || text="$text
Specs in progress: $open"; }
esc=$(printf '%s' "$text" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | awk '{ printf "%s\\n", $0 }')
printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$esc"
