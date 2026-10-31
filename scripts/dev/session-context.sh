#!/usr/bin/env bash
# SessionStart hook (.claude/settings.json): a few facts so a fresh session does not have to read files to get oriented.
# Prints the hook's JSON answer (hookSpecificOutput.additionalContext). Keep it under about 20 lines; it is paid for in every session.
# Flags (OpenCode, see AGENTS.md and .opencode/commands/work.md): --plain prints plain text instead of the hook JSON;
# --task <id> prints the full TODO.md item for an id like A1 (heading, item line, continuation lines) before the summary.
cd "$(dirname "$0")/../.." || exit 0
plain=0
task=""
while [ $# -gt 0 ]; do
  case "$1" in
    --plain) plain=1 ;;
    --task) task="${2:-}" ; shift ;;
  esac
  shift || break
done
branch=$(git branch --show-current 2>/dev/null)
dirty=$(git status --short 2>/dev/null | wc -l | tr -d ' ')
ahead=$(git rev-list --count main..HEAD 2>/dev/null)
text="Branch ${branch:-?}: ${ahead:-?} commits ahead of main, ${dirty:-?} changed files."
if [ -n "$task" ]; then
  item=$(awk -v target="$task" '
    /^## [A-Z]\./ { sec = substr($2, 1, 1); heading = $0; initem = 0; next }
    /^[0-9]+\. \[/ {
      n = $1; sub(/\./, "", n)
      if (sec n == target) { if (!shown) { print heading; shown = 1 }; initem = 1; print; next }
      initem = 0; next
    }
    initem { if ($0 ~ /^[ \t]/) print; else initem = 0 }
  ' TODO.md 2>/dev/null)
  [ -z "$item" ] || text="$text
Task $task (TODO.md):
$item"
fi
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
if [ "$plain" = 1 ]; then
  printf '%s\n' "$text"
  exit 0
fi
esc=$(printf '%s' "$text" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | awk '{ printf "%s\\n", $0 }')
printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$esc"
