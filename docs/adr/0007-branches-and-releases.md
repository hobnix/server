# 0007: `develop` for work, `main` for releases, signed tags

Status: Proposed
Issue: hobnix/server#213 (epic #207). Records the branch model in CLAUDE.md and docs/dev-environment.md ("Branches and releases").

## Context

- Before this model every server followed `main` through `hs update` (`git pull --ff-only`, scripts/update.sh), and `main` also received
  every merged change (docs/PLAN-channels.md, "Problem").
- A server runs the repository as root and installs packages from other repositories, so what a server pulls must be a version somebody
  decided to release.
- The same model applies to hobnix/server, hobnix/recipes and hobnix/extensions.

## Decision

1. **`develop` is the default branch.** Feature and fix branches start from it and pull requests target it. It holds the next release.
2. **`main` holds released code only.** It takes nothing but a release pull request (develop into main, **merge commit, no squash**, so
   `develop` stays an ancestor of `main`) and hotfix pull requests. It is protected: no direct pushes, force pushes or deletion.
3. **A release is a signed tag `vX.Y.Z` on `main`.** Core: `git tag -s`. Package repositories: `scripts/dev/release.sh`, which refuses unless
   the checkout is on `main`, clean and equal to `origin/main`. The tag on the core builds the installer ISO.
4. **A hotfix** branches from `main`, goes into `main` and is tagged; `main` is then merged back into `develop`.
5. **The primary checkout stays on `main`.** Work happens in worktrees (guard: scripts/dev/guard-primary-checkout.sh).
6. **Update channels sit on top** (docs/PLAN-channels.md): `stable` follows the newest signed tag on `main`, `beta` a signed prerelease tag cut
   from `develop`, `edge` the head of `develop`. Stable is the default.

## Consequences

- `develop` can be ahead of what servers run; only a tag moves servers. Releasing is a deliberate step with a signature.
- Hotfixes need the extra merge back into `develop`; forgetting it makes the next release pull request conflict.
- Merge commits on `main` keep the history readable but need the release pull request to be merged without squash.

## Open points

- Channel behaviour that is not built yet (installer ISO, `beta` mode of `release.sh`, the release key file) is tracked in docs/PLAN-channels.md.
