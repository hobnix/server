# Plan: update channels Stable, Beta, Edge (draft, 2026-11-03)

Status (2026-11-04): steps 1 to 3 are built for the core (setting `updateChannel`, scripts/lib/update-channel.sh, `hs update`, `hs update --preview`,
tests/update-channel.sh), the operations guide has the section "Update channels". Step 4 is built as the Settings page "Releases" (2026-11-04,
issue #286: `hs sys release show|plan|start`, scripts/release-channel.sh, scripts/release-change.sh; the plan checks the tag signature from
the tags already fetched and asks for the channel name when the channel is newer). Decision 2026-11-04: when the new channel is older than the
installed version, the server stays on the installed version until the channel catches up; a downgrade is out of scope for now, and the page
says so. Built 2026-11-05: `hs pkg` on a channel (scripts/pkg_repo.py, beta tags). Not built yet: the installer ISO, the `beta` mode of `release.sh`. The release key file `config/trusted-keys/server.allowed_signers` holds a key since commit 3d2c07a. Open questions 1 to 3 are still open; question 4 is built as proposed (a tag older than the installed version is refused).
Open questions at the end are for the owner. The branch model it rests on (`develop`, `main`, signed
tags) is in docs/dev-environment.md "Branches and releases".

## Problem

`hs update` runs `git pull --ff-only` on the branch the server is on (scripts/update.sh), so every server follows `main`. With `develop` as
the working branch there must be a way to choose how new a server wants to be, and the default must be the safe one.

## Channels

| Channel | Core follows | Package repositories (recipes, extensions) follow | For |
|---|---|---|---|
| `stable` (default) | the newest signed `vX.Y.Z` tag on `main` | the newest signed `vX.Y.Z` tag | every server that holds data |
| `beta` | the newest signed prerelease tag `vX.Y.Z-beta.N` (cut from `develop`), or the stable tag when it is newer | the same rule | a second server or a test VM |
| `edge` | the head of `develop` | not offered: packages stay on beta at most | the developer's own test server |

Why packages have no edge: docs/PLAN-packages.md checks out only a signed tag or commit, never a branch head. That trust rule stays. A
package author who needs to try an unreleased recipe uses a beta tag.

## Tags

- Stable `vX.Y.Z`, created on `main` after a release pull request (`git tag -s`, or `release.sh` in the package repositories).
- Beta `vX.Y.Z-beta.N`, created on `develop`, signed with the same release key, so `hs pkg` and the update path verify it the same way.
  `release.sh` gets a `beta` mode; it refuses a beta tag on `main` and a stable tag on `develop`.
- Version order is plain semver: `v1.4.0-beta.2` < `v1.4.0`. A beta server that sees `v1.4.0` moves to it.

## What changes in the code (steps)

1. Schema key `updateChannel` (`stable|beta|edge`, default `stable`) in config/schema.toml, then `python3 scripts/schema-gen.py write`.
2. A helper in scripts/lib that returns the target ref for the channel (newest matching signed tag, or `origin/develop`), used by
   scripts/update.sh, scripts/update-preview.sh and `hs pkg`. The `--state` and `--dry-run` lines keep their shape; the channel is one new
   labelled line, never a changed field.
3. `hs update` fetches tags, verifies the signature of the target tag, shows the diff as it does now, then checks the tag out (edge:
   fast-forwards `develop`). It refuses to move a stable server onto a prerelease, and asks the owner to type `edge` or `beta` when the
   channel is switched to a newer one. Going back to a lower channel is allowed only to a version that is not older than the installed one.
4. Web: Settings shows the channel with a warning text for beta and edge; the update page shows which ref it would install.
5. Docs: operations guide section "Update channels", changelog entry. CI: a test that stable never selects a prerelease tag and that an
   unsigned tag is refused on every channel.

## Rules to keep

- Stable is the default for a fresh install and for every server that has no `updateChannel` yet.
- A channel change never reboots or wipes anything; it only changes which ref `hs update` aims at.
- Edge is for a server whose data can be lost. The setting says so in plain words.
- Beta and edge never apply by themselves: no unattended update, always a plan the owner confirms.

## Open questions for the owner

1. Should the installer ISO exist for beta tags too, or for stable only? (Proposal: stable only; a beta server installs stable first.)
2. Does edge need a signed head? (Proposal: no for the core, since the owner controls the server; yes is possible with signed commits on
   `develop` later.)
3. How long do beta tags live before they are deleted? (Proposal: they stay; a stable tag supersedes them.)
4. Is a downgrade from beta to stable allowed when the stable tag is older than the installed beta? (Proposal: refused, the owner restores a
   backup or waits for the next stable.)

Not tested on hardware yet.
