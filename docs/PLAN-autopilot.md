# Plan: autopilot, a runner for board issues

Design record. Contributor document, not a guide. Written 2026-11-27, after 0.13.0. Planned for milestone **0.15** (moved from 0.14 on 2026-11-27), on the SDK crates of 0.14.
The runner is not built. A status-only trial of the package exists as a draft (hobnix/official#46) and ran in local checks only. Not tested
on hardware yet. `autopilot` is a working name.

**Changed on 2026-11-28 (ADR 0035):** the autopilot is in milestone **0.16** "Game servers and autopilot", not in 0.15. Ticking `[lab]` boxes from
test-lab runs is dropped (#1372): only a run that a person saw ticks a box. Where this plan says otherwise, this applies.

The runner takes an approved issue of the active milestone, lets Claude Code build it in a throwaway VM, and opens a pull request. A person
defines the milestones and issues, approves what runs, merges, tests on hardware and releases.

Builds on `/work` (.claude/commands/work.md), the agents in `.claude/agents/`, the quiet test runner (`scripts/dev/t`), the board
(`scripts/dev/board.sh`), the hardware-test trackers (`scripts/dev/hwtest.sh`), the test-lab (`capabilities/testlab/NOTES.md`), ADR 0031
(Rust extensions) and [PLAN-package-sdk.md](PLAN-package-sdk.md).

## 1. Scope

| In version 1 | Not in version 1 |
| --- | --- |
| One runner, one job at a time | More machines or a node page (multi-node is after 1.0) |
| One repository, set in the settings | Several repositories at once |
| Draft pull request into `develop` | Merging, releases, tags |
| The runner stops and asks when it cannot go on | Guessing at an unclear issue |
| One Claude account, the runner owner's | More than one account per runner |

## 2. Accounts and limits

- A runner uses **one account: its owner's own**. It never holds another person's login or token. Anthropic's
  [Consumer Terms](https://www.anthropic.com/legal/consumer-terms) forbid sharing credentials or making an account available to others.
- There is **no pooling, rotation or failover** across accounts.
- At the usage limit the job is saved, its state is `waiting-limit`, and it goes on after the reset. The page shows the reset time when the
  command line reports one (to check: what a `claude -p` run reports at the limit).
- Several runners on one account share one limit, so they add no capacity. Version 1 has one.
- Several contributors can each run their own runner: own machine or VM, own Claude login, own GitHub token. Each takes only issues assigned
  to its owner. Runners share no scheduler, usage view or queue, and one never takes over another's job.
- The [legal page](https://code.claude.com/docs/en/legal-and-compliance) says subscription limits assume "ordinary, individual usage". It
  gives no number for unattended use. The owner decides how much the runner does.
- Login: `claude setup-token`, which the [authentication docs](https://code.claude.com/docs/en/authentication) name for CI and scripts.
- The [headless docs](https://code.claude.com/docs/en/headless) say `--bare` will become the default of `-p`, and bare mode reads no
  subscription login. The VM image **pins the Claude Code version**; raising it is a change with a test run.

## 3. Stages of an issue

| Stage | Where it shows | Who moves it |
| --- | --- | --- |
| Dev | board: In Progress, then In Review with a draft pull request | the runner |
| Done | merged and closed (`Closes #N`); the milestone counts it as built | a person merges |
| Test | one box per step in "Hardware test: <milestone>" | the runner adds the boxes after the merge |
| Tested | the box is ticked | the test-lab (lab boxes) or a person (metal boxes) |

Testing never holds an issue or a milestone open, and no test is an issue of its own. A failed test opens a bug issue; the closed issue stays
closed.

### Lab and metal boxes

- Every box says who can run it: `[lab]` (a test-lab VM) or `[metal]` (real hardware: SMART, a failing disk, GPU passthrough, UPS, real DNS
  and certificates, a VPS). A box without a mark counts as `[metal]`.
- A `[lab]` box is ticked only when a test-lab stage **covers that step** and passed on a commit that contains the change. The box names the
  stage. A green smoke check ticks nothing else.
- A lab tick says "test-lab", with run id and commit, so it never reads like a run on a real server.
- This changes the rule "never tick a box for a run nobody saw" in CLAUDE.md. The new text: a logged test-lab run counts for `[lab]` boxes
  only.
- `hwtest.sh tick` ticks every step of an issue at once and writes "ran on a real server". It needs to tick one box and to word a lab tick.
- The test-lab has not run on hardware (#430). It ticks nothing until it has passed on a real server.

### Limit on untested work

The runner stops taking new issues when the open `[metal]` boxes **it added** reach a set number. Older boxes do not count: seven of the
trackers held 150 open and 6 ticked boxes on 2026-11-26.

## 4. Which issue runs

An issue runs when all of this is true:

1. It is in the active milestone. The settings hold an ordered list of milestones; "lowest open milestone" is not used, because old
   milestones keep open issues.
2. It is not an epic and not a tracker.
3. It has the label `agent:ok`, set by a person with write access.
4. It is assigned to the runner's owner.
5. Every issue it depends on is closed.

When every issue that is not an epic is closed, the runner goes to the next milestone in the list. A release stays a person's step.

**Approved text.** The repository is public, so issue text is untrusted input. The runner records a hash of title and body when it first sees
the label. If the text changes, the job stops and the label has to be set again. Comments are not given to Claude unless the owner wrote them.
To check: that the recorded text is the text the person approved (compare the time of the label with the time of the last edit).

## 5. A job

```
queued -> preparing -> planning -> coding -> checking -> reviewing -> pr-open -> done
                          (any step) -> waiting-limit -> (the same step)
                          (any step) -> needs-human | failed | cancelled
```

| Step | What happens |
| --- | --- |
| preparing | new VM from the image, clone of `develop` |
| planning | only for an issue marked "needs design": the `architect` agent writes `.work/<id>/spec.md`; otherwise the issue text is the spec |
| coding | the `coder` agent, in a fresh `claude -p` run |
| checking | `scripts/dev/t changed` and the configured checks, outside Claude; a failure goes back to coding with the runner's output |
| reviewing | the `reviewer` agent, in a fresh run, against the spec |
| pr-open | the runner pushes the branch and opens a draft pull request with the label `agent-pr` and the "Hardware test" steps; CI must pass |
| done | a person merged; the runner adds the tracker boxes |

- At most two fix rounds (checks, review and CI together), then `needs-human`.
- Each step is a fresh run. What passes between steps is a file, not a session.
- Turn and time limits are settings per step. Start with the agents' own `maxTurns`, then tune from measured runs.
- `.claude/` and CLAUDE.md come from `develop`, not from the job's branch, so a job cannot change its own reviewer. A change to them ends in
  `needs-human`.
- Storage, network and firewall changes need a question first (CLAUDE.md): the runner sets `needs-human` before it codes them.
- Commits follow the repository rules: no AI attribution lines and no sign-off.

## 6. Sandbox and secrets

- **One Incus VM per job**, deleted afterwards. A VM, not a container: Nix and the root tests need their own kernel and loop devices. No
  Docker inside for the runner itself.
- **No GitHub token in the VM.** The finished commits leave as a git bundle. The runner fetches the bundle into a bare repository and pushes.
  It never checks out, builds or runs repository content on the server, and runs no git hooks from it.
- **No repository scripts on the server.** The GitHub, board and tracker calls are part of the Rust program. Running `board.sh` from the
  target repository as root would let a merged change take over the server.
- The runner's own checks run in the VM as a user that cannot read the Claude token. That does not cover commands the agent starts itself
  (it runs tests while it codes): assume they can read the token. **Outbound traffic is limited** to what a job needs; this narrows where a
  token could be sent, and does not remove the risk (an allowed host can carry data out). This is a firewall decision: ask before building
  (open point 2).
- The GitHub token is fine-grained: one repository; contents, pull requests and issues; what the project board needs; **no workflow
  permission**. A change under `.github/` ends in `needs-human`.
- A pull request from a branch of the same repository runs CI with more rights than one from a fork. Before the first unattended run: check
  which secrets the workflows can read, and keep release secrets behind a protected environment.
- Both tokens are **package secrets** (#1125, below). The package does not read secret files by path.
- Everything that comes back from the VM (bundle, logs, status) is untrusted: size limits, no shell interpolation, no terminal control
  characters on the page or in the journal.

### Package secrets (#1125, core)

For every package, not only this one. Not built. The design is a proposal until the ADR of #1125 is accepted.

| Point | Proposal |
| --- | --- |
| Declare | the manifest names each secret (name, label); a package reaches only the names it declares, under its own package name |
| Store | `/var/lib/hs/pkg-secrets/<package>/<name>`, through `secret_prepare`: with a vault the file is in the vault and the path is a link. Without a vault it is a root-only file on the system disk. `secret_prepare` takes flat names today |
| Set | the core writes it, from stdin or a hidden prompt (`hs pkg secret set <package> <name>`), or from a `secret` field of a package form. `list` says `ok`, `missing` or `locked`; nothing prints a value |
| Use | the program asks the core over the protocol it already speaks: the SDK has `ctx.secret(name)`, the core checks the manifest and answers a `Secret`, or `missing`, `locked` or `denied`. The same call for commands, confined or not, and services. Never argv, never the environment. Integration keys stay as they are |
| Log | which package asked for which name and when; never the value |
| Vault closed | the state is `locked`, never `missing`; the package waits and says so. For autopilot no job starts after a reboot until `hs unlock` |
| Lifetime | kept on update, deleted when the package is removed |
| Limit | "only this package" holds only for confined code. An unconfined command runs as root and can read any file. The ADR and the install dialog say so |

ADR 0010 version 1 has no request channel: the core writes one line and closes stdin (`scripts/lib/ext_proto.py`, Python today). The channel
needs a decision record, stdin kept open for the answer, and a minimum `api-level`, so a core without it refuses the package. A service keeps
its stdin open already. The core knows which package asks, because it started the program. The SDK call stays the same when the core side
moves to Rust (`hobnixd`, 0.15).

Open for the ADR: whether a package may write a secret it made itself (a generated RCON password), or only a person sets one; what backup
and restore do with these files.

The vault protects the token **where it is stored**. It does not change how Claude receives it inside the job VM (open point 1).

## 7. The package

A capability in **hobnix/official**, `capabilities/autopilot/`, `kind = "capability"`, off by default, `requires = ["incus"]`. Other people
may install it, so repository, board, milestone list, labels, base branch, check commands and limits are settings.

| Part | Content |
| --- | --- |
| Rust library module | job states, issue selection, GitHub calls, VM calls; no SDK types; tested against fake GitHub and Incus |
| Rust commands | `hobnix-pkg` and `hobnix-pkg-command` with the feature `macros`; shipped as `[[binary]]` (ADR 0031) |
| `module.nix` | a timer and a oneshot unit that run `hs ext autopilot tick` |
| Page | `[web.page]`, data only |

**Why not an SDK service.** A service runs as an unprivileged user, never calls `hs`, and `Ctx` has no host-command call (ADR 0031,
decisions 4 and 7). It cannot manage Incus VMs. Command rows run as root unless confined.

**Tick.** Each tick takes a lock, reads the saved state, looks at the running job, takes at most one next step and exits. Claude and the
checks run inside the VM and outlive the tick, so a step never waits on them (a command ends after an hour at most). Every step can run twice
without harm. The state survives a reboot.

**Commands** (draft): `status`, `list`, `show <job>`, `tick`, `pause`, `resume`, `cancel <job>`, `login` (token on stdin), and the `plan` and
`start` rows the web changes need.

**Page.** The existing blocks are enough on paper: `stat` (state, waiting until), `table` (queue and past jobs, with row actions), `log` and
`progress` (running job), `form` (settings, and a secret field that goes on stdin). Approval stays on GitHub.

**Events.** `pkg.autopilot.needs-human`, `.pr-opened`, `.waiting-limit` and `.job-failed`, declared in `[[events]]`, so the notifications of
the server tell the owner. The page follows the live state; the timer does the work whether a page is open or not.

### The SDK

The package is written against the 0.14 crates from the first commit; `hobnix-ext-sdk` is not used.

- Commands come from code: `#[command]`, `#[derive(Args)]` and `commands!`. `commands.tsv` matches the table built into the program;
  `cargo test` and `hs pkg validate` fail on drift (`binary.drift`).
- `Ctx` has no host-command call. The program starts `incus` and `git` itself, which only a command row without `confine` may do. Tests use
  `hobnix_pkg::testing::FakeCtx` and fakes of its own for GitHub and Incus.
- **`hobnix_pkg::http` speaks plain `http://` only.** GitHub needs TLS, so the trial brings `ureq` with `rustls` (`ring`) in the static
  musl build, with its CA list built into the program. A changed CA list needs a new build, and a private CA of the server is not used. The
  build needs a musl C compiler (#1389).
- A token is a `hobnix_pkg::Secret` in the program, so logs print `***`.
- The crate split (#1321, #1262), the command macro (#1343, #1263) and the fixes #1317 and #1367 are part of 0.14.0, released on
  2026-11-27. The trial still pins commit `91fa6884`, the one tagged `v0.14.0-beta.1`. A release of the package pins a core tag,
  `v0.14.0-beta.1` or later (`binary.sdk-pin`). The beta lacks the web fix of #1373, so a run on a server needs 0.14.0 or later.
- The test harness, templates and CI template (#1264) are open. The package starts without them and takes them over when they exist.

### Gaps found by reading the code

Found by reading `develop` on 2026-11-27, before 0.14.0. #1373 (pull request #1386, part of 0.14.0) fixes the first three, after tests that
showed each of them. The fourth stays for the packaging trial.

| Gap | Where | Effect |
| --- | --- | --- |
| A package without `capability.toml` counts as a recipe | `scripts/hs_ext.py` `ext_declarations`, `_ext_page` | a capability package may not have a `capability.toml`, so its page becomes an app page; `group`, `after` and `state` are refused, and then the whole web declaration is ignored, reads included |
| Web blocks and roles are validated from `capability.toml` only | `scripts/pkg.py`, manifest checks | the web tables of a capability package are not checked by `hs pkg validate` |
| Web permissions are checked from `capability.toml` only | `scripts/lib/pkg_perms.py` `folder_problems` | `web.read` and `web.change` are not enforced for a capability package |
| No capability in hobnix/official yet | `capabilities/` holds only `.gitkeep` | install, vendoring, `[[binary]]` in a capability and the page have not been tried together |

### Seen in the packaging trial

Run on 2026-11-27 under WSL, with Rust 1.94.1 and the core at commit `91fa6884`:

- The static program is 1.7 MB, two builds were identical, and it holds no path of the build machine. One unauthenticated HTTPS request to
  GitHub got status 200.
- The core's protocol runner runs both commands, `hs pkg validate` finds no problem and reports a hand-edited `commands.tsv` as
  `binary.drift`, and the three command rows load.
- Without the fix of #1373, `0.14` drops the whole web declaration of the package. With it, the page and its read load.
- In hobnix/official, validate, repo-check and the tests `guides`, `rust-binaries` and `ext` pass; its other tests were not run.
- `repo-check --release` rejects the package (`binary.unbuilt`, `binary.sdk-pin`). **The draft (official#46) must not be merged** before it
  pins a core tag: it would block the next release of every package.
- Not done: install from a repository, evaluation of the Nix module, a rebuild, the page in a browser, anything on a server.

| Further gap | Effect |
| --- | --- |
| #1388 | hobnix/official did not build, check or release the Rust program of a capability. Fixed by official#47 (in its `develop`) |
| #1389 | the C compiler of the build is not pinned; whether two compilers give the same program is not tested |
| #1390 | the docs build lists the guide of a capability package under Apps (read in the code, not run) |

## 8. Steps

Epic #1370. Step 1 is #430, step 2 is #1371 and #1372, steps 3 and 4 are #1374 and #1373 (plus the gaps #1388 to #1390 that the trial
found), step 5 is #1375 and #1376, step 6 is #1377, steps 7 and 8 are #1378. Step 9 has no issue yet. The web fix (#1373) and the build
of capability programs (#1388) are done in 0.14; their runs on a server are still open.

| Step | Content | Needs |
| --- | --- | --- |
| 1 | The test-lab passes on a real server (#430) | - |
| 2 | Trackers: `[lab]` and `[metal]` marks, single-box ticks, lab wording, the CLAUDE.md rule; then ticks from test-lab runs | marks: -; lab ticks: 1 |
| 3 | Packaging trial on the 0.14 crates: a capability that only answers `status`, with a page, installed from a package repository on a server; one HTTPS call to GitHub from the static program | - |
| 4 | Fix the gaps the trial confirms | 3 |
| 5 | VM image and one job: an approved issue to a draft pull request, started by hand and watched; about 10 issues; record time, usage, fix rounds and failures | package secrets (#1125), outbound limit (open point 2) |
| 6 | Queue: milestone list, retries, `waiting-limit`, untested limit, events | 5 |
| 7 | The capability complete: timer, page, settings; released from hobnix/official | 4, 6, a 0.14 core tag |
| 8 | Unattended runs | 1, 7, CI secrets checked |
| 9 | Later: merge small changes into `develop` automatically. Never storage, network, firewall, `.claude/`, `.github/` or release changes | 8, required checks (#439) |

Steps 1, 2, 3 and 5 can start side by side. Steps 1 to 8 are one epic in **0.15**; step 9 comes later. As everywhere, a step is done when it
is merged, and its run on a server is a box in the tracker of its milestone. Steps 5 and 8 are the exception where the run is the step. Step 1 is #430,
which stays in its own milestone.

## Open points

1. **How the Claude token reaches Claude inside the VM.** The documented way is the variable `CLAUDE_CODE_OAUTH_TOKEN`. The project rule says
   secrets never go through argv or the environment. Either allow the variable as a written exception, or find a file-based login that works
   headless (not checked). With the exception: the token goes from the server to the VM on stdin, into a file in memory, and the variable is
   set for the Claude process only, not for the VM or the unit. Processes that Claude starts may still see it (section 6). **Not needed before
   the first job with Claude.** To check then: whether a proxy on the server can add the login to Claude's requests, so the token never enters
   the VM (not known whether this works with a subscription login or is allowed by the terms; code in the VM could still spend usage through
   it).
2. **Outbound limit of the job VM.** Which hosts a job needs (Anthropic, package and Nix caches, crates, npm), and whether an Incus network
   ACL or a proxy enforces it. Firewall work: decide before building.
3. **The untested limit.** The number of open `[metal]` boxes at which the runner stops.
4. **Size.** CPU, memory and disk of a job VM beside the services of the server, and beside a test-lab run.
5. **Name** of the package.
6. **HTTPS to GitHub:** the trial uses a TLS library in the program (section 7). It stays unless #1389 shows that the build cannot be made
   reproducible.
