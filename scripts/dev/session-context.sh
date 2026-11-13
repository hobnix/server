#!/usr/bin/env bash
# SessionStart hook (.claude/settings.json): a few facts so a fresh session does not have to read files to get oriented.
# Prints the hook's JSON answer (hookSpecificOutput.additionalContext). Keep it under about 20 lines; it is paid for in every session.
# Flag (OpenCode, see AGENTS.md): --plain prints plain text instead of the hook JSON.
# The open issues come from the project board (scripts/dev/board.sh); the hook stays quiet when gh is missing or offline.
cd "$(dirname "$0")/../.." || exit 0
plain=0
while [ $# -gt 0 ]; do
  case "$1" in
    --plain) plain=1 ;;
  esac
  shift || break
done
# `bash` on Windows is WSL; its Linux git cannot follow the Windows-style gitdir pointer of a linked
# worktree (the .git file), so fall back to Windows git.exe there (WSL translates the cwd for it).
gitcmd=git
if ! git rev-parse --short HEAD >/dev/null 2>&1 && command -v git.exe >/dev/null 2>&1; then
  gitcmd=git.exe
fi
branch=$($gitcmd branch --show-current 2>/dev/null)
if [ -z "$branch" ]; then
  short=$($gitcmd rev-parse --short HEAD 2>/dev/null)
  branch=${short:+"detached $short"}
fi
dirty=$($gitcmd status --short 2>/dev/null | wc -l | tr -d ' ')
ahead=$($gitcmd rev-list --count main..HEAD 2>/dev/null)
text="Branch ${branch:-?}: ${ahead:-?} commits ahead of main, ${dirty:-?} changed files."
tasks=$(bash scripts/dev/board.sh open 4 2>/dev/null)
[ -z "$tasks" ] || text="$text
Open issues of the current milestone (board; /work <number> runs one):
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
