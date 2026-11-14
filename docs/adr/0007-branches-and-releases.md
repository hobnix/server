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

## Amendment (issue #233): release branch and milestone branch

- **A release is cut through `release/X.Y`**, not straight from `develop`: `develop` -> `release/X.Y` (fixes only) -> pull request into `main`
  (merge commit) -> signed tag -> `main` merged back into `develop`. `develop` can take the next work while the release candidate is tested.
- **A milestone branch `0.N`** may exist while the milestone after the one being released is built. `develop` is merged into it after every
  change (merge commit); it never lacks anything `develop` or `main` has. When ready it is merged into `develop` and released as above;
  then it is deleted.
- **A hotfix is merged back** into `develop` and the open milestone branch.
- `main` takes merge commits only; the rulesets for `release/*` and milestone branches are proposals for the owner.
- Runbook and script: docs/RELEASE-PROCESS.md, `scripts/dev/release-core.sh`.

## Consequences

- `develop` can be ahead of what servers run; only a tag moves servers. Releasing is a deliberate step with a signature.
- Hotfixes need the extra merge back into `develop`; forgetting it makes the next release pull request conflict.
- Merge commits on `main` keep the history readable but need the release pull request to be merged without squash.

## Open points

- Channel behaviour that is not built yet (installer ISO, `beta` mode of `release.sh`, the release key file) is tracked in docs/PLAN-channels.md.
