# Release 0.1.0 checklist

The steps, in order, to release Hobnix 0.1.0 "Trustworthy Foundation": hobnix/recipes, hobnix/extensions, then the core with its installer ISO.
For the owner who signs the tags; nothing here has been done yet. Prepared 2026-11-09 from `develop` at `91aa7ec`.

Legend: **not run** = nobody has run this step; it is written from the scripts and workflows. Every "(verified by reading)" means the file
was read, not executed. Nothing in this list was run against `main`, a tag or a real server.

## Before you start
- A clone of hobnix/server, hobnix/recipes and hobnix/extensions, and the release key: `~/.ssh/hobnix_release.pub` with its private key (or in
  ssh-agent). The public key of the packages is in `config/trusted-keys/recipes.allowed_signers` and `extensions.allowed_signers`; the
  core has its own key in `config/trusted-keys/server.allowed_signers` (a different key, see "Release keys").
- Rights on GitHub: merge into `main` (it is protected), push tags, create releases. The `gh` CLI, logged in.
- Nothing may be released with open P0 work you did not decide on: see "Open work in milestone 0.1".
- The owner does steps 5 to 13. Not run.

## Release keys
The file `config/trusted-keys/README.md` still says `server.allowed_signers` "is not here yet". It is: it holds one key (principal `release`,
ed25519, added by commit 3d2c07a). Its public part differs from the key in `recipes.allowed_signers` and `extensions.allowed_signers`
(verified by reading). `scripts/dev/release.sh` only signs for the package repositories (it reads `<repo>.allowed_signers`), so the core tag is
made by hand with the key that matches `server.allowed_signers`.

Check that the private key you hold matches the file before you tag:

```bash
ssh-keygen -y -f ~/.ssh/<core-release-key> | cut -d' ' -f1-2
```

Compare the output with the key in `config/trusted-keys/server.allowed_signers`. Not run.

## 1. Check what develop holds
Work in a worktree, never in the primary checkout.

```bash
git -C /srv/repos/hobnix/server fetch origin
```

```bash
scripts/dev/t quick
```

All quick tests must pass. Not run for this checklist (the PR only adds docs; CI runs the tests on the pull request).

```bash
python3 -I scripts/lib/changelog.py validate .
```

Not run.

```bash
python3 scripts/pkg.py validate
```

Not run.

## 2. Roadmap board and open issues
```bash
python3 scripts/roadmap-gen.py write
```

Check the table "0.1 — Trustworthy Foundation" in `docs/roadmap.md` against the milestone on GitHub. On 2026-11-09 the board says 47 issues, 31
done; open: #128, #139, #147, #153, #155, #157, #159, #161, #163, #165, #169, #171, #252, #322, #323, #324 (the board can be stale: confirm on
GitHub). Decide for each: ship, or move to 0.2 with a sentence in the release notes. Not run.

## 3. Release the package repositories first
The core CI job `packages` checks `hobnix/recipes` and `hobnix/extensions` at their latest `main`, and the stable channel of a server
fetches the packages by tag (`hs pkg`, docs/PLAN-channels.md). Release them before the core so a fresh server finds tagged packages.

What each repository needs (verified by reading `scripts/dev/release.sh`):
- the branch `main` equal to `origin/main`, a clean tree, `python3 -I <core>/scripts/pkg.py repo-check .` passing;
- `index.toml` present; versions in `package.toml` and `index.toml` agree;
- the release key (`$HS_RELEASE_KEY` or `~/.ssh/hobnix_release.pub`) and the matching `<repo>.allowed_signers` in the core;
- a pull request `develop` into `main` first (merge commit, no squash), as for the core. Check that both repositories have a `develop`
  branch and that it is ahead of `main`; this was not checked. Not run.

In each of the two checkouts, on `main` after the release pull request is merged (the first tag found is `v0.0.0` plus one step, so pick the
step on purpose):

```bash
bash /srv/repos/hobnix/server/scripts/dev/release.sh minor
```

With no earlier tag the script computes `v0.1.0` from `v0.0.0` for `minor`, and `v0.0.1` for the default `patch`. It asks you to type the tag.
Not run. After it: `git tag -v v0.1.0` shows "Good signature". Not run.

## 4. Prepare the core on develop
These are changes through pull requests into `develop`, not on `main`.
1. Merge this checklist and `docs/RELEASE-NOTES-0.1.md`. Re-read the notes, fix the status of the hardware-unverified items.
2. Resolve or defer the blockers listed below.
3. Check that `docs/install.md` says where the ISO comes from (`homeserver-installer.iso` from the GitHub release).

## 5. Release pull request develop into main
```bash
gh pr create --repo hobnix/server --base main --head develop --title "Release 0.1.0" --body-file docs/RELEASE-NOTES-0.1.md
```

CI runs on the pull request. Because the base is `main`, the job `nixos` also runs the capability matrix (about 20 minutes,
`scripts/dev/nix-matrix.sh`). Not run: `main` is about 340 commits behind `develop`, so this is the first run of that comparison. Merge
with a **merge commit** (never squash or rebase), so that `develop` stays an ancestor of `main`:

```bash
gh pr merge <number> --repo hobnix/server --merge
```

## 6. What the CI jobs need (.github/workflows/ci.yml, nested.yml, dco.yml)
Read, not run.

| Job | Runs when | Needs |
| --- | --- | --- |
| `changes` | every non-draft pull request, tag, manual run | full history; decides which jobs run; a tag or manual run runs all |
| `rust` | Rust, vault or job files changed; a tag | `cargo fmt`, `clippy -D warnings`, `cargo test --locked`, an up to date `Cargo.lock` |
| `scripts` | always | `bash -n`, shellcheck (errors), every non-root `tests/*.sh` with `HS_TEST_CI=1`, apt packages `jq`, `python3-pil` |
| `packages` | root changes; a tag | the repositories hobnix/recipes and hobnix/extensions are readable (public); their `main` passes `repo-check` and their tests against this core |
| `nixos` | non-docs changes; a tag | nixpkgs pinned to revision `774debe` (move it when servers' channel moves); evaluates the system, builds `pkgs/hobnix.nix` and `pkgs/hs-web.nix` (a stale `npmDepsHash` fails here), capability matrix on a PR into `main`, a tag or a manual run, and `build-iso.sh --eval`. Optional Cachix: variable `CACHIX_CACHE`, secret `CACHIX_AUTH_TOKEN` |
| `integration` | root changes; a tag | loop devices, `sudo`, restic, xfsprogs, btrfs-progs, cryptsetup, mergerfs, snapraid |
| `iso` | **only a tag `v*`**, after `changes`, `scripts`, `packages`, `nixos`, `integration` succeeded and `rust` succeeded or was skipped | the same pinned nixpkgs revision as `nixos` (`NIXPKGS_REV` in `ci.yml`), `permissions: contents: write`, enough runner disk for the image; builds `result-iso/iso/*.iso`, writes `.sha256` with the bare file name, runs `gh release create --notes-file docs/RELEASE-NOTES-<major>.<minor>.md` (or uploads to an existing release) |
| `nested` (nested.yml) | manual only | an ISO URL (a release asset), a runner with `/dev/kvm`; never run, UNVERIFIED |
| `dco` | pull requests | `Signed-off-by` on every commit, unless the PR has the label `agent-pr` |

On a tag, `ci.yml` runs every test job in parallel; the `iso` job waits for them (`needs:`) and is skipped, with no release, if one failed
or was skipped (blocker B2, issue #397). The ISO is built against the same pinned revision the `nixos` job evaluates (blocker B3, #398).
The release notes are `docs/RELEASE-NOTES-0.1.md` for any `v0.1.x` tag; a tag without such a file gets generated notes and a warning (B6, #399).
Changed by reading only: **never run on a real tag push.**

## 7. Tag the core
On `main`, clean and equal to `origin/main`. The primary checkout stays on `main`; tagging does not need a branch switch in a work tree:

```bash
git fetch origin main
```

```bash
git tag -s v0.1.0 origin/main -m "Hobnix 0.1.0"
```

This needs `gpg.format = ssh` and `user.signingkey` set to the core release key. Verify against the trusted file before you push:

```bash
git -c gpg.format=ssh -c gpg.ssh.allowedSignersFile=config/trusted-keys/server.allowed_signers tag -v v0.1.0
```

Not run. If it does not say "Good signature", delete the tag (`git tag -d v0.1.0`) and fix the key. Then:

```bash
git push origin v0.1.0
```

**The push starts the ISO build and creates the public release. A tag that is pushed cannot be taken back quietly: servers may have seen it.**

## 8. Watch the tag build
```bash
gh run watch --repo hobnix/server
```

Expect the jobs of section 6 and the `iso` job. Not run. If `iso` fails, fix on `develop`, release the next patch tag; do not move a pushed tag.

## 9. Verify the ISO
Download the release asset into a new, empty directory:

```bash
gh release download v0.1.0 --repo hobnix/server --dir iso-0.1.0
```

```bash
(cd iso-0.1.0 && sha256sum -c homeserver-installer.iso.sha256)
```

Not run. The workflow now runs `sha256sum` in the folder of the ISO, so the `.sha256` file carries the bare file name (blocker B7, issue #399) and the check should pass; the first tag build proves it. If it fails, compare by hand: `sha256sum homeserver-installer.iso` against the hash in the file.

Then boot it. The ISO has never been booted by anyone (issue #175, #254, #262):
1. Nested, on a machine with Incus and `/dev/kvm`: `bash scripts/dev/nested.sh preflight`, then
   `bash scripts/dev/nested.sh run --iso iso-0.1.0/homeserver-installer.iso --stage all`. UNVERIFIED harness (PR #374). Not run.
2. Or by hand in a VM or on a spare machine in UEFI mode: `sudo hs-install` (guide: docs/install.md). Not run.
3. Boot the installed system and run `hs system info`, `hs sys release show`, open the web interface. Not run.

The restore path (`hs-restore`, issue #254, PR #362) is UNVERIFIED too: only try it on a spare machine.

## 10. What the version string shows
There is no `VERSION` file and no `hs version` command (verified: `git ls-files`, `scripts/lib/registry.tsv`); since issue #400 the version comes from git (`scripts/lib/version.sh`) and is shown in more places. The facts:

| Where | Shows | Before any tag | After `v0.1.0` |
| --- | --- | --- | --- |
| `hs sys release show` (`scripts/release-channel.sh`), key `installed` | `git describe --tags --always` of `/etc/nixos` | the short commit hash, for example `91aa7ec` | `v0.1.0` on the tagged commit; `v0.1.0-<n>-g<hash>` on a commit after it that has the tag as ancestor |
| web Settings "Releases" (same command) | the same value | short hash | as above |
| `hs system info`, line `Hobnix` (issue #400) | the same value (`scripts/lib/version.sh`; the version the installer kept in `.hobnix-version` when there is no checkout; `-` if unknown) | the short hash | `v0.1.0` |
| web Overview, the "Version" fact (row `version` of `hs sys status`, last row) | the same value | short hash | `v0.1.0` |
| `hs system info`, line `Repo` | `git log -1` short hash and subject | same | same (no tag in it) |
| `hs system info`, line `NixOS` | `nixos-version` | NixOS release and nixpkgs revision, not the Hobnix version | same |
| `hs sys release show`, key `ref` and the `offer` lines | what each channel would install | `-` and state `none` | `v0.1.0` for stable and beta, `origin/develop` for edge |
| Rust workspace (`rust/Cargo.toml`) | `0.1.0` (set already) | `0.1.0` | `0.1.0` |
| the ISO file | `homeserver-installer-<describe>.iso` from `scripts/dev/build-iso.sh` (`homeserver-installer.iso` when built by hand without git); the volume label stays `HS_INSTALLER`; `/etc/hs-installer-version` on the stick holds `describe=` and `commit=` | no release | `homeserver-installer-v0.1.0.iso` when built from the tag. Release CI (issue #397 to #399) must use this name: not checked here. |

A server made by the installer had no `.git` (`install-wizard.sh` copies the tree with `tar --exclude=.git`), so `git describe` printed nothing
and `installed` was `-` (blocker B1). Since issue #396 the installer fetches the history and sets HEAD to the revision the ISO was built
from (`scripts/lib/checkout.sh`); without a network it leaves no `.git` and says so. Not tested on a VM or hardware yet. A server cloned as in docs/install.md ("Keep the configuration updatable") follows `develop` (the default
branch). Tag `v0.1.0` sits on the merge commit on `main`, which is not an ancestor of `develop`, so a `develop` checkout keeps showing a bare hash
until `main` is merged back into `develop` (step 11).

## 11. Merge main back into develop
So that `git describe` on `develop` sees the tag and the next release PR has no conflict (the same rule as a hotfix):

```bash
git switch -c chore/main-into-develop origin/develop
```

```bash
git merge --no-ff origin/main
```

Open a pull request into `develop` for it. Not run.

## 12. What the update channels do on the first tag (docs/PLAN-channels.md)
Read from `scripts/lib/update-channel.sh`, `scripts/update.sh`; not run on a server.
- Before the tag: every channel resolves to "no tag" (`none`); `hs update` follows the current branch as before.
- Stable (default): the newest signed `vX.Y.Z` tag; `v0.1.0` qualifies. Beta: the newest `vX.Y.Z` or `vX.Y.Z-beta.N` tag, so also `v0.1.0`. Edge:
  `origin/develop`, no tag involved.
- The tag must verify against `config/trusted-keys/server.allowed_signers` **in the checkout on the server**. A server that updates from a commit
  before 3d2c07a has no key file and refuses every tag ("No release key is trusted"). Servers pull the key with the update before the tag, so the first
  tag works only for servers that already updated to a `develop` or `main` with that file.
- A server already on a commit that contains the tag target (for example it follows `develop` ahead of the tag) gets state `kept`: it stays
  where it is, no downgrade. A server on an older commit gets state `update` and `hs update` checks out the tag (detached HEAD) after showing the diff.
- Beta and edge never apply by themselves and ask for the channel name on a switch. The `beta` mode of `release.sh` is not built: only
  stable tags can be cut now. Open questions 1 to 3 of the plan are unanswered; the stable-only ISO matches the proposal.
- `hs pkg` on a channel: a stable server takes stable package tags, so step 3 must be done first.

## 13. Announce
The workflow already creates the release with `docs/RELEASE-NOTES-0.1.md` as its text (`--notes-file`, not run on a tag yet). Check the text on the release page; if the
release was made earlier or the text is wrong, replace it with the release notes:

```bash
gh release edit v0.1.0 --repo hobnix/server --notes-file docs/RELEASE-NOTES-0.1.md
```

Not run. Tell people that the ISO and every hardware item in the notes are UNVERIFIED.

## Open work in milestone 0.1
From `docs/roadmap.md` (2026-11-09): #161 auto-rollback on the real server, #163 rebuild rehearsal in a VM, #165 first monthly restore drill, #171
disk and pool failure review, #128 job system epic, #139 event architecture epic, #147 live-state epic, #153, #155, #157, #159, #169, #252, #322,
#323, #324. Several have merged work since the board was generated (PRs #340, #341, #384). Update the board before you decide. Not run.

## Blockers found
Each was verified by reading the file named; none was run.

| # | Blocker | Evidence | Proposed issue |
| --- | --- | --- | --- |
| B1 | A server made by the ISO has no git checkout, so `hs update`, update channels and the version shown do not work on it | `scripts/install-wizard.sh:212` excludes `.git`; `docs/install.md` tells the user to clone by hand; `scripts/update.sh` needs git | Installer: leave a git checkout (remote `origin`, the release tag) in /etc/nixos (issue #396). Done in code and tests with a local origin; Not tested on hardware yet. |
| B2 | The `iso` job publishes a release without waiting for any other job | `.github/workflows/ci.yml`, job `iso` has no `needs:` | CI: the ISO and release job needs the test jobs (issue #397; fixed in the workflow, untested on a real tag) |
| B3 | The ISO is built from `nixos-unstable` of the day, everything else from the pinned nixpkgs; the tag build is the first time that combination evaluates | `ci.yml` `iso` vs `nixos` nix_path | CI: build the ISO from the pinned nixpkgs revision (issue #398; fixed in the workflow, untested on a real tag) |
| B4 | No version file, no `hs version`, the ISO name has no version | section 10 | Show the Hobnix version in `hs system info` and the ISO file name (issue #400). Done in code and tests; the ISO build was not run (no nix here), Not tested on hardware yet. |
| B5 | `config/trusted-keys/README.md` and the header of `docs/PLAN-channels.md` say the core key file is missing | the file exists (3d2c07a) | Docs fix, done in this pull request (README) |
| B7 | The `.sha256` asset names the ISO with the build path, so `sha256sum -c` fails for a downloader | `ci.yml` step "Attach it to the release" | CI: write the checksum with the bare file name (issue #399 (with B6); fixed in the workflow, untested on a real tag) |
| B6 | The GitHub release text is generic, no notes | `ci.yml` `gh release create --notes "Installer ISO ..."` | CI: use a notes file for the release (issue #399; fixed in the workflow, untested on a real tag) |

Not a blocker, noted: `release.sh beta` and the beta ISO are not built (docs/PLAN-channels.md); the core tag has no helper script.
