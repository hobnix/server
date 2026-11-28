# Contributing

Hobnix is a NixOS home server: Incus containers on ZFS or SnapRAID, Samba shares, backups, a web interface and one command, `hs`. This
repository is the **core**. The apps (recipes) and the optional parts (extensions) are packages in their own repositories:

- https://github.com/hobnix/recipes (an app that runs in its own container or VM)
- https://github.com/hobnix/extensions (commands and a page on the host)

Each of them has its own `CONTRIBUTING.md` (how to write a package). A change to the helpers a package relies on (`scripts/recipes/_lib.sh`,
the loaders, `scripts/lib/api-level`) belongs here, and its pull request says which packages it touches.

## Before you start

- Open an issue first for anything that changes storage, the network, the firewall or how a command works. Small fixes and docs need none.
- A change that was not run on a real server says so in the pull request. Documentation steps that were not run say "Not tested on hardware yet."

## Working on the core

- Branches are named `feature/<topic>` and start from `develop`; open the pull request against `develop` (`main` holds releases only). CI runs
  on pull requests; a pull request is merged only when the check `ci-ok` is green.
- Code for a decision record (`docs/adr/`) is merged only when the record is Accepted, or when the code is behind a switch that is off by
  default (an option in `config/schema.toml`, or a feature a command refuses without). The pull request names the record and says which of
  the two applies. Code merged before its record was accepted stays behind its switch; nothing is built on it until the owner decides.
- Development and testing are two steps on the board. In Review: the pull request is open. Testing: the code is merged but was not run on a
  real server; the issue stays open. Done: the boxes under "Hardware test" in the issue are ticked, a comment says what was seen, the
  "Not tested on hardware yet." lines of that change are gone, and the issue is closed. A change with nothing to run on a server (a decision
  record, CI, a text) goes from In Review to Done. `python3 scripts/dev/untested.py` lists the untested steps per guide.
- Run the tests of the files you changed through the quiet runner, not raw: `scripts/dev/t quick [name...]` (`scripts/dev/t list` names
  them). Many tests need Linux (use WSL on Windows). Also `bash -n` on a script and `python3 scripts/pkg.py validate` for manifests.
- Text printed by the `hs` commands is English only; there is no catalog to update. Web texts go into `web/src/i18n.js`.
  Two pull requests with the same ADR number should conflict, so `docs/adr/README.md` has no merge driver.
- Rules that every change follows (the full list is in `CLAUDE.md`):
  - **Admin pages are never public.** Incus, Zoraxy, Arcane, Grafana, Tdarr and the like get no public route (`ADMIN_TARGETS` in `scripts/services.py`).
  - **Destructive commands** make the user type the name of the thing that changes, show a plan first and offer a background job for long work.
  - **Terminal output** goes through `scripts/lib/ui.sh` only: no raw `echo` or `printf`, no colours of its own. Lines the web interface reads
    (`hs sys ...`, `--list`, `--dry-run`, `--state`) keep their shape; an empty tab-separated field is written `-`.
  - **Generated files** (`config/defaults.nix`, `scripts/lib/config-keys.sh`, `scripts/lib/capabilities.tsv`, `machine.toml.example`) are never
    edited by hand: edit `config/schema.toml`, then run `python3 scripts/schema-gen.py write`.
  - **A new script** gets a row in `scripts/lib/registry.tsv`; a new `reads` command gets a probe in `scripts/smoke.sh`.
  - **Secrets** are read only through `scripts/lib/secret.sh` and never go through argv or the environment.
  - **Documentation** is English and follows `docs/GUIDE-TEMPLATE.md`.
- **Changelog entries.** A change that users see (a new option, a fixed bug, a changed behaviour) adds one file
  `docs/changelog/<YYYY-MM-DD>-<slug>.toml` with `date`, `type` (feature, fix, change, security), `title` (one line, plain English) and
  optionally `docs` (a guide and anchor) and `body`. One file per change. Check it with `python3 -I scripts/lib/changelog.py validate .`;
  the format is in `docs/changelog/README.md`. CI only warns when a pull request touches the core without an entry.
- Commit messages say what changed and why in a line or two, and end with a DCO sign-off (`git commit -s`, see below). Stage files by name.

## Sign your commits (DCO)

Hobnix uses the [Developer Certificate of Origin](https://developercertificate.org/) (DCO), not a contributor license agreement. You keep
the copyright of your work; the sign-off says you have the right to submit it under the project's license (see `LICENSE`). By adding it you
certify, in short: you wrote the change or have the right to pass it on under this license, and you understand that the contribution and
your sign-off are public and kept with the history. The full text is at https://developercertificate.org/.

Sign off every commit with `-s`:

```bash
git commit -s -m "Short message"
```

This adds a trailer with the name and email from your git config (`user.name`, `user.email`):

```
Signed-off-by: Your Name <you@example.org>
```

- Forgot it on the last commit: `git commit --amend -s --no-edit`. On several commits: the steps below.
- Use your real name (a pseudonym you are known by is fine, an anonymous one is not) and an email that git can attribute to you.
- CI (`.github/workflows/dco.yml`, `scripts/dev/dco-check.sh`) fails a pull request when a commit has no `Signed-off-by` trailer. Merge
  commits are exempt, and so are the commits of three bots: `dependabot[bot]`, `renovate[bot]` and `github-actions[bot]`. The author's
  name and email must be exactly the ones GitHub gives that bot; any other name, with `[bot]` in it or not, needs a sign-off. Run the same
  check locally with `scripts/dev/dco-check.sh origin/develop` (name the base branch of your pull request).
- **AI tools.** The sign-off is the human contributor's: you certify the change, whoever or whatever helped write it. This repository
  also forbids `Co-Authored-By` and "generated with" lines about any AI tool in commits and pull requests (`CLAUDE.md`), so do not add one.
  An AI tool never adds a sign-off. A pull request opened by an AI session carries the label `agent-pr`. The label is only a marker: the
  DCO check runs for it like for every pull request. A person signs off the commits of an AI session before the merge, with the steps
  below.
- **Sign off several commits** of a branch, also those of an AI session. Run this yourself, in a checkout that is on the branch, with your
  own `user.name` and `user.email` configured. Set `base` to the base branch of the pull request first
  (`gh pr view --json baseRefName --jq .baseRefName`).

  <!-- tests/dco-check.sh runs the next block as it is written here. -->
  ```bash
  base=develop
  git config user.name >/dev/null && git config user.email >/dev/null &&
  git fetch origin &&
  git merge --ff-only '@{upstream}' &&
  SIGNOFF="Signed-off-by: $(git config user.name) <$(git config user.email)>" FILTER_BRANCH_SQUELCH_WARNING=1 \
  git filter-branch -f --msg-filter '
    if git rev-parse -q --verify "$GIT_COMMIT^2" >/dev/null; then cat
    else git interpret-trailers --no-divider --if-exists addIfDifferent --trailer "$SIGNOFF"
    fi' "origin/$base..HEAD" &&
  git push --force-with-lease
  ```

  It rewrites only the messages of the commits in `origin/<base>..HEAD`: your sign-off is added once to each commit that is not a merge.
  The files of every commit, the authors and the merge commits with their conflict fixes stay as they are, and the commits of the base
  branch are not touched. The commit ids change, and a cryptographic signature on a rewritten commit is lost. `git rebase --signoff` is
  not the way here: it drops merge commits. If `git merge --ff-only` stops, your copy and the pushed branch differ: sort that out first.

## Community

- Everyone who takes part follows the [code of conduct](CODE_OF_CONDUCT.md).
- **Discussions** (https://github.com/hobnix/core/discussions) are for questions, "how do I", show-and-tell and early ideas that are not yet
  a change. An issue is for something that can be built or fixed. A Discussion that turns into work becomes an issue, and the issue links back.
- **Good first issues** carry the label `good first issue`. We label an issue that way only when it names the files to touch, says what
  done looks like (a command and its output, or a test that passes) and needs no change to storage, the network or the firewall. Typical
  ones: a docs fix, a missing line in a guide, a test for an existing command, a translation, a small `hs` message. If you want one, say so
  in a comment before you start so two people do not do the same work; a maintainer answers with where to look. Ask there if the issue is
  unclear: an unclear good first issue is our mistake.

## Reporting a problem

Bugs, features, architecture proposals, spikes and documentation problems: an issue with the matching template (`.github/ISSUE_TEMPLATE`). A vulnerability: not an issue, see `SECURITY.md`.
