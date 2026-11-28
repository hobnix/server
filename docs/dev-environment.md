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
| `scripts/dev/t vm [name...]` | the throwaway Incus VM tests (`zfs-vm`, and `rebuild-vm`: restore from only the backup volume and the passphrase; need KVM and the internet); no name runs both; 900 s per test |
| `scripts/dev/t wsl quick\|changed\|root` | the same, run inside a Debian WSL (Windows only) |
| `scripts/dev/t list` | the names of the quick, root and vm tests |

Add `-v` for a line per test. `grep -n FAIL .work/test-logs/<name>.log` shows why one failed.

Rust: `cargo build` in rust/ (in WSL for a Linux binary), then `scripts/dev/t quick vault-change-rust` runs the shell test against it (skipped without a binary).

hobnix-core links the system SQLite and refuses one with the WAL-reset bug (below 3.51.3, except the fixed 3.50.7 and 3.44.6 lines), and the SQLite of a distribution may be such a one (Debian WSL has 3.46.1). So build and test rust/ with [Nix](https://nixos.org/download/), in the environment of the nixpkgs pin: `nix-shell scripts/dev/rust-shell.nix`, then `cargo ...` in rust/. It has cargo, rustc, clippy, rustfmt, python3 and that SQLite, and a `CARGO_HOME` of its own. `scripts/dev/t quick rust-cargo` and the CI job `rust` use it; the first start downloads about 900 MB from the binary cache.

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
checks it (issue #262, docs/adr/0023-nested-test-harness.md). Run on 2026-11-15 on a real Incus
server (KVM, nested virtualization) with the `v0.1.0-beta.1` release ISO, stage `all`: the ISO booted, the unattended `hs-install` finished,
the installed system booted and every check passed (exit 0). Not tested on hardware yet: a physical machine; the web wizard and the rebuild
rehearsal are not part of the run. Its logic is also tested without a VM (`scripts/dev/t quick nested`, a fake console and a fake `incus`).

| Command | What |
| --- | --- |
| `scripts/dev/nested.sh preflight` | can this machine do it? (`/dev/kvm`, nested virtualization, `incus`, `ssh-keygen`) |
| `scripts/dev/nested.sh plan [stage]` | the steps, without running anything |
| `scripts/dev/nested.sh check [stage]` | the dry check: every `hs` command line of the stages against the repository, no VM (below) |
| `scripts/dev/nested.sh run [--iso <file>] [--stage iso\|smoke\|all] [--keep]` | the run; the ISO defaults to `result-iso/iso/homeserver-installer.iso` (`scripts/dev/build-iso.sh`) |

**Dry check (`scripts/dev/nested.sh check`, `scripts/dev/nested_check.py`).** Takes every `hs ...` command line of every stage and checks it against the real repository in under a second, without a VM, so a wrong assumption fails before a 20 to 40 minute run, not in it. It checks that the words are a row of `scripts/lib/registry.tsv`; that every `--flag` is in the script's `# args:` line (or is a `case` pattern of the script; `rebuild --yes` fails, `rebuild --foreground` does not); that a `long` command carries `--foreground`; that a `hs sys ...` command typed by hand sets `HS_CALLER`; that a changing command that asks on a terminal carries `--yes` or `--confirm`; that `--disks` gets `/dev/disk/by-id` names; and that nothing uses `sudo -n`. A command whose output is piped, redirected or captured has no terminal, so the dispatcher does not ask there and the check lets it be. It reads text only: what a command does on a real system (a missing folder, no `zfs` on a minimal system, a detached HEAD) still shows only in a run. `scripts/dev/t quick nested` runs it (tests/nested-check-test.py, which also feeds it the mistakes of earlier runs); Not tested on hardware yet (it needs none).

Exit codes: 0 passed, 1 a check failed, 2 usage, 3 this machine cannot run it, 4 harness or Incus error. Logs: `.work/nested/<run-id>/`
(`run.log`, `console-<stage>.log`, `result-<stage>.json`; `.work/nested/latest`).

**File manager write checks (stages `pool` and `poolzfs`, #425).** Both run on an installed VM (`--name`) with two virtual disks
(`HS_NESTED_DISKS="pool1=<device> pool2=<device>"`) that are still empty, so each needs a fresh VM or fresh disks. `pool` makes a SnapRAID `bulk`
(two data disks, no parity), `poolzfs` a ZFS `bulk` (a mirror). Then `fileManagerWrite` is switched on and the file manager does, with a checksum
of the folder before and after: copy, move (source gone only after the target matches), rename, mkdir, an overwrite choice (refused without the typed
name, done with it), delete (refused with a wrong `delete N files`, done with the right one) and a cancelled move (`hs sys jobs stop`: afterwards the
data is whole in one place). On SnapRAID this runs disk to disk and share to share, and checks the guard: `sys fm pair disk:data-01 pool:bulk` says
`refused` and a `start` with that pair refuses. On ZFS it runs share to share and share to the pool view (a ZFS pool has no data disks).
`nested.sh plan pool` and `plan poolzfs` print the steps. Not tested on hardware yet: the stages have not run against a real VM.

**Unraid fixtures (`tests/lib-unraid.sh`, #460 a).** The helper builds loop disks the way Unraid makes them: one GPT partition from sector 64 (`loop -P`
needs partition devices on loop), xfs or btrfs in it (or LUKS with xfs/btrfs inside, opened with `$UNRAID_PASS`), a parity disk with the partition and
no file system, files owned 99:100, and the same top folder (`Shared`) on every data disk. For the refusals of the plan (D8) it also makes a ZFS array
disk, a two-device btrfs, a LUKS disk that only a key file opens, and an xfs with a dirty log. `tests/adopt.sh` uses it (adoptable cases and refusals,
dry run only); a case whose tool or kernel support is missing says `skip` with the reason (xfs and ZFS are often absent in a sandbox or WSL2; CI fails
a skip). The nested stage `unraid` (`HS_NESTED_DISKS="unraid1=<dev> unraid2=<dev> unraidp=<dev>"`, empty disks) builds the same disks inside the VM
and runs only the read-only side: `hs migrate check` and `hs pool <pool> add --role adopt --dry-run`, then compares the superblocks. Not tested on hardware yet.

Limits: nested virtualization must be enabled on the host. Where it is not (exit 3, a WSL2 without it, many CI runners) use `scripts/dev/t vm`
on a machine with Incus; that tests our scripts on Ubuntu VMs, not the ISO. The rebuild rehearsal is not part of it yet. CI: the manual
workflow `nested` (Actions, "Run workflow", give an ISO URL).

## Demo mode: the web interface without a server

`npm run demo` in `web/` starts the web interface with made-up data: no `hs`, no storage and no backend are needed (Node and `npm ci` are).
A Vite plugin (`web/demo/plugin.js`, only in `--mode demo`) answers `/api/*` itself from the fixtures in `web/demo/fixtures/`. Use it to look at
a page, to review the navigation or to take a screenshot.

```bash
cd web
npm ci
npm run demo
```

Pick the data with `?fixture=<name>` on any page (the choice is kept in a cookie), or set `HS_DEMO_FIXTURE` for the default.

| Fixture | Shows |
|---|---|
| `healthy` (default) | two pools (bulk, fast), eight instances (six running), nothing to fix |
| `degraded` | pool bulk lost a disk; two problems are listed |
| `locked` | encrypted storage is closed, instances are down |
| `one-pool` | a single pool |
| `three-pools` | three pools, so the pool selector has something to choose |

- **Reads:** every read of the `READS` allowlist in `scripts/web-serve.py` has an entry. `fixtures/base.json` and `fixtures/parts/*.json` (one
  file per area of the interface) are the healthy server; a fixture file lays its own rows over them. A key is the words joined by `/`
  (`pool/info`), optionally with the query (`pool/info?pool=bulk`) or an argument word (`ct/bindings/nextcloud`; the key without it is the
  fallback). A tab-separated read is a list of rows, every cell a string, an empty field is `-`; the shape is the one the page's parser reads.
  A read that is empty on a healthy server (no problems, no pending rebuild) is listed in `tests/web-demo-empty.txt`.
- **Changes:** a plan opens with a plausible list of steps and a note; a destructive one (remove, wipe, replace ...) asks for the name of the
  thing, as the real one does. A start is always refused with the note "Demo mode: ... Nothing was changed." No command runs, no file is
  written, the terminal and the VM console are refused.
- **Docs page:** a few made-up guides (`web/demo/docs.js`).
- **Not covered:** reads of extension packages (declared in their manifests), the proxyserver pages (capability `vps` is off), job logs, and
  `disk/power`, `unifi/used` and `unifi/reserved` (the pages ask for them, but they are not in the `READS` allowlist). Times in the fixtures are
  fixed to 2026-11-18, so "ago" texts drift as the real date moves on.
- A hosted demo is not part of this.
- Test: `scripts/dev/t quick web-demo` checks that every allowlisted read has a fixture, that no read is empty in `healthy` unless it is listed
  in `tests/web-demo-empty.txt`, that the number of reads with data per fixture does not fall below `tests/web-demo-min.tsv` (raise it when you
  fill more; never lower it), and that plans open and starts are refused.
  Not tested on hardware yet (it needs none; the browser check is in the issue).

## Branches and releases

The same model in hobnix/core, hobnix/recipes and hobnix/extensions.

| Branch | Holds | Who writes to it |
|---|---|---|
| `develop` | the next release, always green | pull requests from `feature/<topic>` and `fix/<topic>` |
| `main` | released code only | release pull requests from `develop`, hotfix pull requests |

1. Start a worktree from `origin/develop`, name the branch `feature/<topic>`, open the pull request against `develop`. CI runs on every
   pull request, whatever its target.
2. To release, open a pull request from `develop` into `main` (there is no `release/*` branch: `develop` is the release candidate) and merge it with a **merge commit** (no squash, so `develop` stays an
   ancestor of `main`). Then, on `main`, tag it: core `git tag -s vX.Y.Z`, package repositories `bash <core>/scripts/dev/release.sh`
   (it refuses unless you are on `main`, clean and equal to `origin/main`). The tag on the core builds the installer ISO. The core's tag:
   `scripts/dev/release-core.sh tag vX.Y.Z`. Steps, hotfixes, the milestone branch (`0.2`) and the ruleset proposals: docs/RELEASE-PROCESS.md.
3. A hotfix branches from `main`, goes into `main` through a pull request and is tagged. Merge `main` back into `develop` (and `develop` into an open milestone branch) right after, so
   the fix is not lost and the next release pull request has no conflict.
4. `main` is protected: no direct pushes, no force pushes, no deletion. The primary checkout stays on `main` (guard
   scripts/dev/guard-primary-checkout.sh).
5. A pull request is merged only when the check `ci-ok` is green (it is the one check the branch rule asks for). CI also runs on `develop`
   after each merge: two pull requests that pass alone can fail together. A red `develop` is fixed before anything else is merged.
6. Code for a decision record (`docs/adr/`) is merged after the record is Accepted, or behind a switch that is off by default.
7. Development and hardware testing are tracked apart, so the milestone bar shows what is built. A dev issue: In Review while the pull
   request is open, Done when it is merged (the issue closes with `Closes #N`). What has to run on a real server is a box in the
   **tracker issue of the milestone**, "Hardware test: <milestone title>" (label `hardware-test`, no milestone, board column Testing while a box
   is open, Done when all are ticked and it closes). One line per merged issue (`- [ ] #N title`), the steps as sub-boxes. At merge:
   `bash scripts/dev/hwtest.sh add <issue> "step" ...`. A step starts with a mark that says who can run it: `[metal]` (real hardware),
   `[lab]` (a test-lab VM) or `[lab:<stage>]` (the test-lab stage that covers the step, `a-z`, `0-9`, `-`); no mark counts as `[metal]`, and
   `add` refuses a mistyped mark. After a run somebody saw: `hwtest.sh tick <issue> "what was seen"` (the issue's line and all its steps), or
   `hwtest.sh tick <issue> --box <k> "what was seen"` for step `k` only (1 = the first; the issue's line is ticked with its last step).
   Only a run that a person saw ticks a box, whatever its mark; a test-lab run alone ticks nothing. Remove the
   "Not tested on hardware yet." lines of a change only after a run on a real server. A change with nothing to run on a server (a decision record, CI, a text) is not added.
   `hwtest.sh list [milestone] [--lab|--metal]` is the queue for the next session at the server (open boxes by kind, and ticked ones); `python3 scripts/dev/untested.py --steps` lists the same from the guides'
   side (every marker with its heading). A failed run becomes a bug issue linked from the box (it is in the milestone, so the bar drops for a
   real reason). A box that is not ticked is **postponed, not a blocker**: nothing in the release depends on it.
8. One milestone is *released* at a time, and at most three issues are In Progress. The next milestone may be built on its own long-lived
   branch (now `0.2`; `develop` is merged into it after every change). After the release tag, `main` is merged back into `develop` and the
   milestone branch is merged into `develop`, after its first beta if one is ready; the branch is kept for the later betas
   (docs/RELEASE-PROCESS.md).
9. A pull request opened by an AI session carries the label `agent-pr` from the start (`gh pr create --label agent-pr`). It is a marker
   only: the DCO check runs, and a person signs off the session's commits before the merge (CONTRIBUTING.md "Sign your commits (DCO)").

### Release rhythm

There is no fixed rhythm and there are no due dates (owner decision 2026-11-10; maybe after 1.0). **What is verified ships, what is not moves
on.** A release holds only what ran on a real server or VM, with the date recorded; anything else is behind a switch that is off, or says
"Not tested on hardware yet." On release day a merged issue is closed (Done); its hardware boxes that were not ticked stay in the tracker, which moves on with the next
release, and the release notes list them as not verified (`hwtest.sh list`). A tracker never blocks a release (owner decision 2026-11-20: maybe a
gate later). One that is not merged moves on with its branch.

### What CI runs (.github/workflows/ci.yml)

| Job | What | When |
| --- | --- | --- |
| `changes` | decides which jobs can be affected | always (not on a draft pull request) |
| `scripts` | `bash -n`, shellcheck (errors; only the changed files on a pull request), the changelog warning | always |
| `tests` | the tests that need no root, in one to four parts on separate runners (`tests/run-all.sh --shard I/N`). A pull request runs the tests that mention its files (`scripts/dev/tests-for.sh`, the local cousin is `t changed`); everything else runs all | always (a pull request always runs `profile-core-only` and `profile-vps`) |
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
- **By hand:** `bash scripts/dev/nixpkgs-pin.sh bump` (head of the channel) or `bump --rev <sha>`, then
  `bash scripts/dev/nixpkgs-pin.sh toolchain-sync` (needs nix) and commit both files.
- **The Rust toolchain follows the pin:** `rust/rust-toolchain.toml` names the rustc of the pinned nixpkgs, the one servers build `rust/`
  with. The job `nixos` fails when they differ (`nixpkgs-pin.sh toolchain-check`); the bump workflow moves the toolchain in the same pull
  request and says so in its text. `rust-version` in `rust/Cargo.toml` is the oldest rustc that must build the crates (hobnix/official's
  pinned toolchain builds the SDK, job `ext-crates`), so it can be lower than the toolchain.
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

`/work <issue number>` runs the loop for one issue of the project board: spec, code, test, review (`scripts/dev/board.sh open` lists them). Specs and reports are files in `.work/<id>/` (git-ignored); an agent's final message is at most 150 words.

A session starts with a short summary from `scripts/dev/session-context.sh`: the branch, the changed files and the next open issues of the milestone.

## Keep the context small

- The root `CLAUDE.md` holds only the rules that always apply. Area rules in `.claude/rules/` (storage, web, packages, commands, shell,
  config, monitoring, instances) load when a matching file is touched; a new fact goes into the rule of its area.
- Check what a session carries with `/context`. Turn off the MCP servers and skills a session does not need (`/mcp`, `skillOverrides`).
- Do not switch the model or the effort in the middle of a session: it empties the prompt cache.
