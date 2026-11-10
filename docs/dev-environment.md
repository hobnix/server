# Development environment and agent workflow

How to run the tests, where each kind of test can run, and how the agents in `.claude/agents/` split the work. For people who change the code;
the guides for running a server are the other pages.

## Run tests

One quiet command runs them. It prints failures and one summary line, and keeps every full log in `.work/test-logs/`.

```bash
scripts/dev/t quick pkg docs
```

| Command | What it runs |
| --- | --- |
| `scripts/dev/t quick [name...]` | the tests that need no root (all of them without names) |
| `scripts/dev/t changed` | the tests that mention a file you changed (at most 25; name the rest yourself) |
| `scripts/dev/t root [name...]` | the root tests: loop devices, dm-crypt, mounts (Linux and root, or passwordless sudo) |
| `scripts/dev/t vm` | the throwaway Incus VM tests (`zfs-vm`, and `rebuild-vm`: restore from only the backup volume and the passphrase; need KVM and the internet) |
| `scripts/dev/t wsl quick\|changed\|root` | the same, run inside a Debian WSL (Windows only) |
| `scripts/dev/t list` | the names of the quick, root and vm tests |

Add `-v` for a line per test. `grep -n FAIL .work/test-logs/<name>.log` shows why one failed.

Rust: `cargo build` in rust/ (in WSL for a Linux binary), then `scripts/dev/t quick vault-change-rust` runs the shell test against it (skipped without a binary).

## Where each test can run

| Tier | Where | Covers |
| --- | --- | --- |
| 0 | Linux, macOS, or Windows Git Bash | all quick tests (slow on Windows: use tier 1) |
| 1 | Debian WSL or any Linux, with root | root tests on loop devices: ext4, mergerfs, SnapRAID, LUKS, restic |
| 2 | CI, or a throwaway Incus VM | ZFS and Incus tests, boot and rebuild |

The WSL2 kernel has no ZFS and no `/dev/kvm` (unless nested virtualization is on), so ZFS tests run in tier 2. CI runs the quick tests, the root
tests on a hosted runner, and the NixOS evaluation.

### Set up a Debian WSL (tier 1)

Run once, inside the WSL, as your normal user. It installs the test tools and, only if you say yes, allows passwordless sudo for this
development WSL (remove `/etc/sudoers.d/hobnix-dev` to undo):

```bash
wsl -d Debian -- bash /mnt/c/path/to/the/repository/scripts/dev/wsl-setup.sh
```

Then, from the repository on Windows:

```bash
scripts/dev/t wsl root
```

The runner copies the working tree into `~/hobnix-test` in the WSL (ext4, much faster than `/mnt/c`) and runs the tests there.

## Hobnix-in-Hobnix (nested VM from the ISO)

`scripts/dev/nested.sh run` boots the installer ISO in a nested Incus VM, runs an unattended `hs-install`, boots the installed system and
checks it (issue #262, docs/adr/0023-nested-test-harness.md). **Not tested on hardware yet: the harness has never been run against a real
VM.** Only its logic is tested (`scripts/dev/t quick nested`, a fake console and a fake `incus`).

| Command | What |
| --- | --- |
| `scripts/dev/nested.sh preflight` | can this machine do it? (`/dev/kvm`, nested virtualization, `incus`, `ssh-keygen`) |
| `scripts/dev/nested.sh plan [stage]` | the steps, without running anything |
| `scripts/dev/nested.sh run [--iso <file>] [--stage iso\|smoke\|all] [--keep]` | the run; the ISO defaults to `result-iso/iso/homeserver-installer.iso` (`scripts/dev/build-iso.sh`) |

Exit codes: 0 passed, 1 a check failed, 2 usage, 3 this machine cannot run it, 4 harness or Incus error. Logs: `.work/nested/<run-id>/`
(`run.log`, `console-<stage>.log`, `result-<stage>.json`; `.work/nested/latest`).

Limits: nested virtualization must be enabled on the host. Where it is not (exit 3, a WSL2 without it, many CI runners) use `scripts/dev/t vm`
on a machine with Incus; that tests our scripts on Ubuntu VMs, not the ISO. The rebuild rehearsal is not part of it yet. CI: the manual
workflow `nested` (Actions, "Run workflow", give an ISO URL).

## Branches and releases

The same model in hobnix/server, hobnix/recipes and hobnix/extensions.

| Branch | Holds | Who writes to it |
|---|---|---|
| `develop` | the next release, always green | pull requests from `feature/<topic>` and `fix/<topic>` |
| `main` | released code only | release pull requests from `develop`, hotfix pull requests |

1. Start a worktree from `origin/develop`, name the branch `feature/<topic>`, open the pull request against `develop`. CI runs on every
   pull request, whatever its target.
2. To release, open a pull request from `develop` into `main` and merge it with a **merge commit** (no squash, so `develop` stays an
   ancestor of `main`). Then, on `main`, tag it: core `git tag -s vX.Y.Z`, package repositories `bash <core>/scripts/dev/release.sh`
   (it refuses unless you are on `main`, clean and equal to `origin/main`). The tag on the core builds the installer ISO.
3. A hotfix branches from `main`, goes into `main` through a pull request and is tagged. Merge `main` back into `develop` right after, so
   the fix is not lost and the next release pull request has no conflict.
4. `main` is protected: no direct pushes, no force pushes, no deletion. The primary checkout stays on `main` (guard
   scripts/dev/guard-primary-checkout.sh).
5. A pull request is merged only when the check `ci-ok` is green (it is the one check the branch rule asks for). CI also runs on `develop`
   after each merge: two pull requests that pass alone can fail together. A red `develop` is fixed before anything else is merged.
6. Code for a decision record (`docs/adr/`) is merged after the record is Accepted, or behind a switch that is off by default.
7. An issue is closed when every box under "Done when" is ticked. Merged but not run: it stays open, in the board column In Review.
8. One milestone at a time, and at most three issues In Progress. Work for a later milestone waits until the current one is released.
9. A pull request opened by an AI session carries the label `agent-pr` from the start (`gh pr create --label agent-pr`); the DCO job is
   skipped for it and the maintainer who merges it takes the responsibility (CONTRIBUTING.md).

### What CI runs (.github/workflows/ci.yml)

| Job | What | When |
| --- | --- | --- |
| `changes` | decides which jobs can be affected | always (not on a draft pull request) |
| `scripts` | `bash -n`, shellcheck (errors; only the changed files on a pull request), the changelog warning | always |
| `tests` | the tests that need no root, in one to four parts on separate runners (`tests/run-all.sh --shard I/N`). A pull request runs the tests that mention its files (`scripts/dev/tests-for.sh`, the local cousin is `t changed`); everything else runs all | always (skipped when no test matches) |
| `rust` | format, clippy, tests of the Cargo workspace | Rust files or the scripts they stand in for changed |
| `packages` | hobnix/recipes and hobnix/extensions against this core | the package helpers, `scripts/lib/`, `packages/`, `capabilities/` or their tests changed |
| `integration` | the root tests on loop devices | not for web-only or docs-only changes |
| `nixos` | evaluates the system, builds the Rust program and the web frontend, evaluates the ISO | not for docs-only or tests-only changes |
| `ci-ok` | fails when one of the jobs above failed or was cancelled | always |
| `iso` | builds the ISO and the release | a tag `v*`, after every job above |

A push to `develop` or `0.2`, the merge queue, the nightly run on `develop` (02:17 UTC), a tag and a manual run always run every job and every
test: a pull request gets the quick answer (the tests are picked by the file names a change touches, not by a call graph), the full set runs
before and after the merge. A change to `scripts/lib/`, `tests/lib*.sh`, `config/` or a workflow runs every test even in a pull request.
A new test needs no entry in the workflow. A test never hard-codes a TCP port: `free_port` in tests/lib.sh asks the kernel for one.

### The nixpkgs pin

`config/nixpkgs-pin.toml` is the one place that names nixpkgs: the `channel` the servers follow and the `rev` CI evaluates and builds
(job `nixos`) and the ISO is built from (job `iso`). Nothing else may hard-code a revision (`scripts/dev/nixpkgs-pin.sh check` runs in the
`scripts` job). Servers follow their channel, not the revision: the revision only decides which store paths CI puts in the binary cache.

- **Who moves it:** the workflow `nixpkgs-bump` (Mondays, or by hand) opens a pull request that moves `rev` to the head of the channel;
  the normal CI runs on it and a maintainer merges it when green. Without a bump the pin stays; a stale pin costs cache hits, not correctness.
- **By hand:** `bash scripts/dev/nixpkgs-pin.sh bump` (head of the channel) or `bump --rev <sha>`, then commit the file.
- **A NixOS release change** changes `channel` too and is a project decision, not a bump: [Move to a new NixOS release](operations.md#move-to-a-new-nixos-release).
- The bump workflow needs repository settings that only the owner can change (see the comment at the top of `.github/workflows/nixpkgs-bump.yml`).

Update channels (Stable, Beta, Edge) are designed in docs/PLAN-channels.md; they build on these branches and tags.
Not tested on hardware yet.

## Agents

The main session orchestrates and keeps its context small. It delegates to the agents in `.claude/agents/`, each with its own model and effort:

| Agent | Model, effort | Job |
| --- | --- | --- |
| `architect` | Opus, high | writes `.work/<id>/spec.md` for a task that needs design; never edits code |
| `coder` | Sonnet, medium | implements one spec and writes `.work/<id>/report.md` |
| `implementer` | Haiku, low | mechanical edits from an exact spec |
| `tester` | Haiku, low | runs `scripts/dev/t`, reports failures only |
| `reviewer` | Opus, high | reviews the diff against the spec; read-only |
| `docs-writer` | Sonnet, low | writes guides to `GUIDE-TEMPLATE.md` |

`/work <id>` runs the loop for one task of `TODO.md`: spec, code, test, review. A task id is the section letter and the item number
(`## A.` item 1 is `A1`). Specs and reports are files in `.work/<id>/` (git-ignored); an agent's final message is at most 150 words.

A session starts with a short summary from `scripts/dev/session-context.sh`: the branch, the changed files and the next open tasks.

## Keep the context small

- The root `CLAUDE.md` holds only the rules that always apply. Area rules in `.claude/rules/` (storage, web, packages, commands, shell,
  config, monitoring, instances) load when a matching file is touched; a new fact goes into the rule of its area.
- Check what a session carries with `/context`. Turn off the MCP servers and skills a session does not need (`/mcp`, `skillOverrides`).
- Do not switch the model or the effort in the middle of a session: it empties the prompt cache.
