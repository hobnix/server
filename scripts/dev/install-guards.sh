#!/usr/bin/env bash
# Install the git hooks (not versioned): pre-commit refuses commits in the primary checkout; commit-msg adds the DCO sign-off. Run once per clone:
#   bash scripts/dev/install-guards.sh
# The commit refusal does not apply to worktrees (the sign-off hook does). Override for a deliberate commit: HS_ALLOW_PRIMARY=1 git commit ...
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

# commit-msg (runs after the editor closes): every commit gets `Signed-off-by: <git user.name> <user.email>` (the DCO check has no exemption for agent pull requests).
hook="$common/hooks/commit-msg"
if [ -e "$hook" ] && ! grep -q hobnix-signoff "$hook"; then
  echo "$hook already exists and is not ours; add the sign-off by hand" >&2; exit 1
fi
cat > "$hook" <<'HOOK'
#!/bin/sh
# hobnix-signoff: add the Signed-off-by trailer of the configured git user unless the message has one.
name=$(git config user.name) && email=$(git config user.email) || exit 0
git interpret-trailers --in-place --if-exists doNothing --trailer "Signed-off-by: $name <$email>" "$1"
HOOK
chmod +x "$hook"
echo "installed $hook"
