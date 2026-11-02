#!/usr/bin/env bash
# Install the git hook that refuses commits in the primary checkout (git hooks are not versioned). Run once per clone:
#   bash scripts/dev/install-guards.sh
# Worktrees are not affected. Override for a deliberate commit: HS_ALLOW_PRIMARY=1 git commit ...
set -eu
common=$(git rev-parse --git-common-dir)
hook="$common/hooks/pre-commit"
if [ -e "$hook" ] && ! grep -q hobnix-primary-guard "$hook"; then
  echo "$hook already exists and is not ours; add the check by hand" >&2; exit 1
fi
cat > "$hook" <<'HOOK'
#!/bin/sh
# hobnix-primary-guard: no commits in the primary checkout (agents and people work in worktrees).
[ "${HS_ALLOW_PRIMARY:-}" = 1 ] && exit 0
if [ "$(cd "$(git rev-parse --absolute-git-dir)" && pwd)" = "$(cd "$(git rev-parse --git-common-dir)" && pwd)" ]; then
  echo "Commit refused: this is the primary checkout. Use a worktree (git worktree add ...). Override: HS_ALLOW_PRIMARY=1" >&2
  exit 1
fi
HOOK
chmod +x "$hook"
echo "installed $hook"
