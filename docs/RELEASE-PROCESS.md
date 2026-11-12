# Release process

How code goes from `develop` to a signed release, how a hotfix flows back, what the milestone branch `0.2` does, and the rule proposals for
the owner. Issue #233; decision record ADR 0007 (`docs/adr/0007-branches-and-releases.md`); update channels [PLAN-channels](PLAN-channels.md). The
first release has its own list: [RELEASE-0.1-checklist](RELEASE-0.1-checklist.md). Nothing here was run against `main`, a real tag or a
real server yet: **Not tested on hardware yet.** The script is tested against a local repository (`tests/release-core.sh`).

## Branches

| Branch | Holds | Starts from | Goes into |
| --- | --- | --- | --- |
| `develop` | the next release, and its release candidate | | `main` (release pull request) |
| `0.N` (a milestone branch, now `0.2`) | the work of the milestone after the one being released | `develop` | `develop`, right after the tag of the release before it |
| `main` | released code only | | back into `develop` |
| `hotfix/<topic>` | a fix for a released version | `main` | `main` |
| `feature/<topic>`, `fix/<topic>` | one change | the branch it is for | that branch |

A tag is `vX.Y.Z`, signed, on `main`. Servers follow tags (stable) or `develop` (edge), never a milestone branch. There is no `release/*` branch (owner decision 2026-11-10): `develop` is the release candidate, and the next milestone is built on its own branch so that `develop` holds only what is being released.

## A release

`scripts/dev/release-core.sh` does the git steps; run it in any worktree (it never switches your branch). `release-core.sh status` shows
where everything stands.

1. **Freeze.** Nothing to cut. While a release is being tested only fixes go into `develop`; the work of the next milestone waits on its
   milestone branch (`0.2`). `bash scripts/dev/release-core.sh status` shows where everything stands.
2. **Release pull request.** `gh pr create --base main --head develop --title "Release 0.1.0" --body-file docs/RELEASE-NOTES-0.1.md`.
   CI runs; because the base is `main` the capability matrix runs too. Merge with `gh pr merge <n> --merge` (**merge commit**, never squash or
   rebase: the earlier releases must stay ancestors of `main`).
3. **Tag.** On the owner's machine `bash scripts/dev/release-core.sh tag v0.1.0`, or from GitHub with the workflow `release` (section "Release from GitHub"). It checks that `ci-ok` is green on the tip of `origin/main`, signs it, verifies the
   signature against `config/trusted-keys/server.allowed_signers` as `main` has it, asks you to type the tag, and pushes. The push builds the
   ISO and the GitHub release (the `iso` job of `ci.yml`). A beta tag (`release-core.sh tag v0.2.0-beta.1`) follows the same rules for its base version (above the newest stable tag, `N` above earlier betas) but builds no ISO: the `iso` job skips `-beta.` tags, and the script ends with `gh release create <tag> --verify-tag --prerelease --notes-file docs/RELEASE-NOTES-0.2.md`. A pushed tag is never moved: a bad release gets the next number.
4. **Check.** `gh run watch`, then `bash scripts/dev/release-core.sh verify v0.1.0`.
5. **Merge back.** `main` carries the release merge commit, which `develop` lacks. Open a pull
   request `main` into `develop` (`git switch -c chore/main-into-develop origin/develop && git merge --no-ff origin/main`, merge commit),
   then merge the milestone branch into `develop` (below).

Without step 5 `git describe` on `develop` does not see the tag and the next release pull request conflicts.

## A hotfix

For a bug in a released version:

1. `hotfix/<topic>` from `origin/main`, pull request into `main` (CI, `ci-ok`), merge commit.
2. `bash scripts/dev/release-core.sh tag v0.1.1`, `verify`.
3. Merge `main` back into `develop` and sync the milestone branch (`release-core.sh sync`), the same as step 5 above. A hotfix is not finished before that.

While a release is being tested and the bug is in the release candidate, fix it with a pull request into `develop`, not a hotfix.

## The milestone branch `0.2` after 0.1.0

`0.2` is a copy of `develop` that takes the 0.2 work so that fixes for 0.1 can go on landing in `develop` without mixing. The rule: **`0.2`
never lacks anything `develop` or `main` has.**

- **Sync often.** After a pull request lands in `develop`, or after the tag and the merge-back: `bash scripts/dev/release-core.sh sync` merges
  `origin/develop` into `origin/0.2` on a branch `chore/sync-develop-into-0.2-<rev>` and pushes it (`--pr` opens the pull request). Merge that
  pull request with a merge commit. `release-core.sh status` lists what `0.2` misses. A conflict stops the script and pushes nothing: resolve
  it by hand in a worktree, once, early, instead of at release time. Not automated yet: a scheduled `status` is a possible follow-up.
- **Right after the 0.1.0 tag** (owner decision 2026-11-10). Merge `main` into `develop`, sync once more, then open a pull request `0.2` into
  `develop` (merge commit; it needs no conflict handling, because `develop` is already an ancestor). From then on 0.2 is built on `develop`
  and the branch `0.2` is deleted. One milestone is *released* at a time; the next one may be built on its own long-lived branch (`0.3`,
  cut from `develop` when its work starts while 0.2 is still being stabilised).

So there is one line of history: `develop` is always an ancestor of the milestone branch, the milestone branch of `develop` after its pull
request, and `main` of `develop` after the merge-back.

## Release from GitHub (no owner PC)

The workflow `.github/workflows/release.yml` signs and pushes the tag, so a release needs a browser, not the owner's key file. The git steps
before it stay the same: release branch, release pull request merged with a merge commit (or a hotfix pull request). Then: Actions, `release`,
Run workflow, branch `main`, version `v0.1.0` (a release or hotfix) or `v0.2.0-beta.1`.

What it does (`scripts/dev/release-gate.sh`, tested by `tests/release-gate.sh`):

1. **`gate`** (no secret, no approval): `check` refuses unless the run is on `main`, the commit is the tip of `origin/main` and a merge commit,
   `ci-ok` is green on it or on its second parent (CI does not run on a push to `main`, the pull request head carries the result),
   `docs/RELEASE-NOTES-X.Y.md` exists and names `X.Y`, the changelog entries validate, the tag does not exist (here or on the remote), the version is
   above the newest stable tag and `main` contains that tag. A beta must be for a version not released yet, with a higher `N` than the earlier betas.
2. **`release`** waits for the owner's approval (environment `release`), runs the checks again (main may have moved), then `sign`: the tag is
   made with the private key in the secret, then **the check `hs update` uses** (`uc_verify`: a good signature by a key in
   `config/trusted-keys/server.allowed_signers`, and the signed name equals the tag) runs on it. A tag that fails is deleted and nothing is
   pushed. A tag signed by GitHub itself (its web-flow key) or by any key that is not in the file never passes.
3. It pushes the tag, creates the GitHub release with the notes file (`--prerelease` for a beta) and, for a stable tag, starts `ci.yml` on the
   tag with `gh workflow run`: a push made with the workflow's token starts no workflow, so the test jobs and the ISO job would not run
   otherwise. The ISO job attaches the ISO to the release this workflow made. A beta gets no ISO (open question 1 of PLAN-channels).

Beta tags are cut from `main` by this workflow (after the release pull request, before the stable tag), which differs from the first PLAN-channels
draft (beta on `develop`); it is a proposal until the owner confirms. "The version matches the changelog" is checked as: the notes file for that `X.Y`
exists, names it, and the changelog entries validate; there is no version field in the entries.

### One-time setup (the owner; nothing in this repository can do it)

1. Make a dedicated key, with a passphrase-less OpenSSH format (the workflow cannot type one), on a machine you trust, and keep nothing of it
   there afterwards:
   ```bash
   ssh-keygen -t ed25519 -N '' -C hobnix-release-ci -f release-ci
   ```
2. Add the public key as **one more line** of `config/trusted-keys/server.allowed_signers` by a pull request (principal `release-ci`,
   `namespaces="git"`, the key: `release-ci namespaces="git" $(cut -d' ' -f1,2 release-ci.pub)`). Keep the existing `release` line. Let servers
   run `hs update` first (they learn a key only that way): the order is in `config/trusted-keys/README.md`.
3. Repository settings, Environments: create `release`, tick *Required reviewers* (you) and, if you like, *Deployment branches*: `main`.
   In that environment add the secret `RELEASE_SIGNING_KEY` with the whole content of the file `release-ci` (the private key). Then delete the file.
4. If you apply ruleset proposal 3 (only the owner creates `v*` tags), add the **GitHub Actions** app as a bypass actor of
   `protect-release-tags`, or the workflow cannot push. The ruleset also keeps forbidding update and deletion of a tag.
5. Settings, Actions: the workflow needs "Read and write permissions" for the token (the file asks for them per job).

**Rotation.** Add the new line, merge, let servers update, put the new key in the secret, cut the next release, remove the old line later
(the order of the trusted-keys README).
**Revocation (leaked or lost).** Remove the `release-ci` line by a pull request at once and delete the secret. Servers that update afterwards
refuse any tag signed with it, including tags already published with that key when they check them again: re-release (the next number,
signed by the other key or a new one). A pushed tag is never moved or deleted.

### What this changes about trust
`config/trusted-keys/README.md` promises that a stolen GitHub account alone cannot put code on a server, because the key lives off GitHub. With
this workflow a signing key lives in a GitHub secret, so an attacker who can run this workflow **and** pass the environment approval can
sign. The approval (a required reviewer who is not the person who ran it, once there are two maintainers), the dedicated principal (removable
without touching the owner's key) and the checks (only a merge commit that is the tip of `main`, green CI) are the guard. If that trade is not
acceptable, keep using `release-core.sh tag` on the owner's machine: both ways verify against the same file.

### Proven only on GitHub
Nothing of the workflow ran. Not proven: that the `gate` job reads `ci-ok` of the pull request head with the workflow token, that the
environment approval and the secret reach the job, that `git push` of the tag is allowed by the rulesets, that `gh workflow run ci.yml --ref <tag>`
starts the tag build and its `iso` job (which then finds the release this workflow created), and that `gh release create --verify-tag`
accepts the pushed tag. The scripts and the verification logic are tested locally with fakes.

## Rule proposals for the owner

The rulesets today (read 2026-11-10): `protect-branches` on `main` and `develop` (no deletion, no force push, pull request required with 0
approvals and resolved threads, check `ci-ok`, all three merge methods allowed, repository role 5 may bypass through a pull request) and
`protect-release-tags` on `v*` (no deletion, no update, no force push). Nobody but the owner changes them; each proposal says why.

1. **`main` takes merge commits only.** A new ruleset `protect-main` for `refs/heads/main` with `allowed_merge_methods: ["merge"]`. Why:
   a squash or rebase on the release pull request breaks the ancestor rule and the merge-back. `develop` keeps all methods (feature pull
   requests are squashed or merged as you like).
2. **Protect the milestone branches.** Add `refs/heads/0.*` to the include list of `protect-branches` (deletion and force pushes
   blocked, `ci-ok` required). Why: they are shared and the sync steps rest on their history; `0.2` is unprotected today. Deleting a
   merged milestone branch then needs the bypass, which is intended.
3. **Who creates `v*` tags.** Add the rule `creation` to `protect-release-tags` with the owner as the only bypass actor. Today any
   writer can push a tag `v9.9.9`; the signature protects servers, but a stray tag starts the ISO job and can publish a release. Needs a
   bypass actor for the owner, otherwise the owner cannot tag either.
4. **Required reviews.** Keep 0 approvals while there is one maintainer. When there are two: 1 approval on `main`.
5. **Required check on `main`.** `ci-ok` stays the only required check; the stricter checks (the capability matrix) already run on every
   pull request with base `main`. Setting `strict_required_status_checks_policy` to true would force a branch update before every merge and
   is not recommended for the release pull request (a merge commit from `develop` would need re-running CI for nothing).
6. **Signed commits on `main`**: not proposed. Merge commits made by GitHub are signed by GitHub, the tag carries the signature that servers
   check.

## First release 0.1.0 and the first stable server (#231)

What the owner does, in order. The detailed list with the package repositories, the ISO and the CI jobs is
[RELEASE-0.1-checklist](RELEASE-0.1-checklist.md) (sections 3 to 13); this is the short path for the core. Nobody ran it.

1. Release hobnix/recipes and hobnix/extensions first (`release.sh minor` in each, checklist section 3), so the stable channel finds package
   tags.
2. Check that the private key matches `config/trusted-keys/server.allowed_signers` (checklist, "Release keys").
3. In a worktree: `bash scripts/dev/release-core.sh status` (there is no branch to cut).
4. Test the release candidate on `develop`; fixes go into `develop`. Release pull request, merge commit (step 2 above).
5. `bash scripts/dev/release-core.sh tag v0.1.0`, then `gh run watch` and `release-core.sh verify v0.1.0`.
6. Merge `main` into `develop`, then merge `0.2` into `develop` (section above).
7. **Follow stable on a real server.** On a server whose `/etc/nixos` is a clone that has the key file (it needs a commit from 3d2c07a or later):
   ```bash
   hs config set updateChannel stable
   ```
   ```bash
   hs update --preview
   ```
   `--preview` fetches the tags and shows `channel: stable (v0.1.0)` and the diff. Then check the server without changing it:
   ```bash
   bash /etc/nixos/scripts/dev/release-core.sh follow-check v0.1.0
   ```
   It must say the channel is stable, that stable points at `v0.1.0`, and that the tag is signed. Then apply:
   ```bash
   hs update
   ```
   and prove it:
   ```bash
   bash /etc/nixos/scripts/dev/release-core.sh follow-check v0.1.0 --after
   ```
   It exits 0 only when `installed` is `v0.1.0` (`git describe`) and the state is `current`. Also look at `hs system info` (the line
   `Hobnix`) and the web page Settings, Releases. A server that already contains the tag commit shows state `kept` and does not move: use one
   that is behind, or accept `kept` as the answer for that server. Tick the open box of #231 with the output of both `follow-check` runs.
8. Run `hs update` once more the day after a hotfix tag, the same way, to see a second tag followed. Not run.
