#!/usr/bin/env bash
# PreToolUse hook (.claude/settings.json): agents work in their own worktree, never in the primary checkout (the folder whose .git is a
# directory). Blocks Edit/Write/NotebookEdit on files there and git commands that change it (checkout, switch, commit, pull, reset ...).
# Worktrees under <primary>/.claude/worktrees are fine. Override for a deliberate change: HS_ALLOW_PRIMARY=1. Exit 2 = blocked.
[ "${HS_ALLOW_PRIMARY:-}" = 1 ] && exit 0
here=$(cd "$(dirname "$0")" && pwd)
common=$(git -C "$here" rev-parse --git-common-dir 2>/dev/null) || exit 0
primary=$(cd "$here" && cd "$common/.." 2>/dev/null && pwd) || exit 0

# Same spelling for C:\x, C:/x and /c/x, lower case.
norm() { printf '%s' "${1//\\//}" | tr 'A-Z' 'a-z' | sed -E -e 's#(^|[^a-z0-9])([a-z]):/#\1/\2/#g' -e 's#//+#/#g'; }
p=$(norm "$primary")
input=$(cat)
field() { printf '%s' "$input" | sed -nE "s/.*\"$1\" *: *\"(([^\"\\\\]|\\\\.)*)\".*/\1/p" | head -n1 | sed -E 's|\\\\|/|g'; }
in_primary() {   # path is inside the primary checkout but not inside one of its worktrees
  local x; x=$(norm "$1")
  case "$x/" in "$p"/.claude/worktrees/*) return 1 ;; "$p"/*) return 0 ;; esac
  return 1
}
block() {
  echo "Blocked: $1 is the primary checkout. Work in your own worktree (.claude/worktrees/...); the primary stays on main and untouched. Deliberate change: HS_ALLOW_PRIMARY=1." >&2
  exit 2
}

tool=$(field tool_name)
case "$tool" in
  Edit|Write|NotebookEdit)
    f=$(field file_path); [ -z "$f" ] && f=$(field notebook_path)
    [ -n "$f" ] && in_primary "$f" && block "$f" ;;
  Bash|PowerShell)
    cmd=$(field command)
    verbs='git[^|;&]*[[:space:]](checkout|switch|commit|merge|rebase|reset|pull|restore|clean|add|cherry-pick|revert|am|apply)([[:space:]]|$)'
    printf '%s' "$cmd" | grep -Eq "$verbs" || exit 0
    cwd=$(field cwd)
    if [ -n "$cwd" ] && in_primary "$cwd"; then block "$cwd"; fi
    if printf '%s' "$(norm "$cmd")" | grep -Fq "$p" && ! printf '%s' "$(norm "$cmd")" | grep -Fq "$p/.claude/worktrees"; then block "$primary"; fi ;;
esac
exit 0
