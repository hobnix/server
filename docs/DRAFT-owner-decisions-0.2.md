# DRAFT: proposals for four owner decisions (milestone 0.2)

**Draft for owner decision. Nothing here is decided.** Prepared 2026-11-10 from the roadmap review. The owner (Simon) accepts, changes or
rejects each part; this page is deleted when the four issues are closed. No ADR status was changed by this draft.

| Issue | Proposal in short | Text applied in this pull request |
| --- | --- | --- |
| [#458](https://github.com/hobnix/server/issues/458) positioning | Home user first; clustering, high availability and live migration out of scope before 1.0 | `README.md`, `docs/roadmap.md` ("Positioning", marked draft) |
| [#438](https://github.com/hobnix/server/issues/438) Rust | Pause new command groups until the two moved ones ran on a real server; then at most one group per release, with a rule for new commands | this page only |
| [#437](https://github.com/hobnix/server/issues/437) ADRs | Accept most; three need an edit first; one is already decided | `CONTRIBUTING.md` (sharper rule, marked draft) |
| [#464](https://github.com/hobnix/server/issues/464) rhythm | A release every six weeks on a Tuesday; what is verified ships | `docs/dev-environment.md` ("Release rhythm", marked draft) |

Things I found that the issues do not say:

- **ADR 0018 is already Accepted (2026-11-09)** and ADR 0002 (2026-11-08). The issue says 22 of 24 are Proposed; there are 25 records and 23 are Proposed.
- **ADR 0025 already has the owner's decision**: a comment on #437 says English-only `hs` commands and a translated web interface
  (option B, with C for what the web shows), tracked in #490. The record itself still says Proposed.
- **The CONTRIBUTING rule already exists** in a short form ("A change that needs a decision record is merged after the record is Accepted,
  or behind a switch that is off by default"), and so does rule 6 in `docs/dev-environment.md`. The draft only sharpens it (what counts as a
  switch, what to do with code that is already merged).
- **GitHub milestones have no due date** today (checked with the API on 2026-11-10); no `v0.1.0` tag exists.
- `gh issue view` fails in this repository (Projects classic is gone); I read the issues with `gh api`.

---

## #458 Positioning

**Proposal.** Hobnix is for the person who runs a home server today with Unraid (or a hand-built NAS) and wants apps, shares and backups
that they can read and rebuild. It is not a virtualization platform. The text is in `README.md` ("Who Hobnix is for") and
`docs/roadmap.md` ("Positioning"); both carry a "Draft" line to remove when the owner agrees.

The three things Hobnix does better, as I wrote them (each is checked against what is verified; two are not run on a real server yet, and the
text says so):

1. **Roll back the whole system**, not one app: every `hs update` is a NixOS generation (`hs update` with auto-rollback, TODO B8, #161).
2. **Rebuild the server from a backup disk and a passphrase** (#163, #169). Not run yet.
3. **The server is a readable git repository**: one `machine.toml`, every change shows a plan first, destructive ones need the typed name.
   (My choice for the third point; the issue names only the first two.)

Out of scope before 1.0: clusters with shared state, high availability, live migration, SDN-style network management. ADR 0013 (one owner
per object, read-only copies, no consensus) stays a record of why, and is the design behind the read-only node (#421) and the edge role (#422),
which stay.

Epics outside the positioning (the issue's third box). The board is the source, so I only list; I did not move anything:

| Issue | Milestone today | Proposal |
| --- | --- | --- |
| #203 Epic: Multi-node Management | 0.16 | loses its milestone |
| #201 Epic: Networking Management | 0.16 | owner checks: keep only what a home network needs (UniFi, VLANs, gateway), drop the rest |
| #205 Epic: Marketplace and Ecosystem (P2) | 0.13 | stays; ADR 0015 (Wasm) and ADR 0016 (third-party code) are already "not before an owner decision" |
| #421, #422 read-only node, edge role | 0.16 | stay (one person's own servers; no shared state) |
| #260, #261, #262 VM passthrough, console, nested harness | 0.15 | stay: Unraid users run VMs and GPUs |

**Questions for the owner**

1. Home user of Unraid first: yes, or also the Proxmox homelab user? (This decides whether #269, the vzdump import, stays in 0.6.)
2. Is the third "better" point (readable git repository and plan-before-change) the one you want?
3. #203 loses its milestone and #201 is cut down: agreed?
4. May the README say "rollback" and "rebuild" as promises, or only after #161 and #163 ran? (The draft says "Not tested on hardware yet.")

---

## #438 How far the Rust migration goes

**Where it stands (read from the repository).** About 3,900 lines of Rust in three crates (`hobnix-core`, `hobnix-cli`, `hobnix-ext-sdk`)
next to 189 scripts in `scripts/` (about 275 with `scripts/lib` and the tools). Two groups have moved: `hs sys secrets plan|start` (the
only two `rust:` rows in `scripts/lib/registry.tsv`) and the job record (`hobnix job-record`, behind `hs_job_record`). ADR 0001 itself says
"Not yet run on a real server" for both. ADR 0001 already has a checklist for when a command moves ("touch it, move it", characterization
test first); what is missing is the plan per release.

**Proposal: pause new groups, then one group per release, and only when the area is touched anyway.**

| Release | What | Why |
| --- | --- | --- |
| 0.1 (done) | `secrets` plan/start, job record, extension SDK | pilot and job store |
| 0.1 to 0.4 | **no new group.** Run the two moved groups on a real server and record it (add to #415/#416) | The first tags are about trust and install; a second language in more places before the first one was seen working adds risk |
| gate | Both moved groups ran on a real server in a tagged release, side by side with the fallback | After this the pause ends |
| 0.5 | `pkg` verify and hash of the vendored tree (signature, `capabilities.lock`) | new typed code for ADR 0017 rules 8 and 9; touched anyway |
| 0.7 | storage plans: `pool-state`, `pool-change`, `manage-pool` plan words | destructive plans gain from types (ADR 0001 "good reasons"); touched anyway |
| 0.10 | `hs event emit` and the events table writer, `live-collect` | hot path; the live interface milestone touches it |
| not before 1.0 | a Rust HTTP server in place of `scripts/web-serve.py` | needs its own ADR (ADR 0001 rule 4, ADR 0006 open points) |
| never (ADR 0001 "Stays") | installer and first run, unlock, `hs update` and rollback, recovery, `kind user` commands, package commands | must work when the binary is missing |

The list is an upper bound: a group moves only if its release also touches it. The alternative is "pause until 1.0": nothing moves, the Rust
code stays as is. I do not recommend it: ADR 0001's strangler is cheap to continue and the job store already depends on it.

**Rule: when must a new command be Rust?** (Proposed text for CONTRIBUTING and ADR 0001.)

1. A new subcommand of a group that is already Rust (`secrets`, `job-record`) is written in Rust, in `hobnix-core`, with the CLI adapter.
2. A new command or group is Rust only when the release table above names its area, it meets one "good reason" of ADR 0001 and none of its "Stays".
3. Everything else is shell or Python as today. No command is moved only to be moved.
4. A Rust command needs the same things as a script: a registry row, its test, the changelog entry. A moved row keeps `fallback:<script>` for one release.

**Questions for the owner**

1. Pause until the two moved groups ran on a real server (recommended), or until 1.0?
2. Are the releases and groups in the table right, or do you want to name them yourself?
3. Is rule 1 (a new subcommand of a Rust group must be Rust) acceptable? It forbids a quick shell addition to `secrets` or the job record.
4. Does the pause also cover Python (`pkg.py`, `forecast.py`, `live-collect.py` follow the same checklist in ADR 0001)?

---

## #437 The Proposed ADRs

Recommendations only; **no status was changed**. Order: dependencies first (0004, 0005, 0007, 0014, 0017, 0018, 0022, as in the issue; 0018 is
already Accepted), then the rest by number. "Edit first" means the record should be corrected before it is Accepted, because an accepted
record is never rewritten (`docs/adr/README.md`). What each record says about its own code is quoted from the record; I did not run anything.

| ADR | Recommendation |
| --- | --- |
| 0004 job record | **Accept.** The owner chose the JSON file per job on 2026-11-04; the writer, cancel, reconcile at boot and the Rust writer are merged. Open points are small: keep `queued` reserved, document `result` per job kind when the first kind uses it, check that the progress helper limits itself to about one write per second (I did not verify that it does). |
| 0005 events | **Accept.** The rules were chosen on 2026-11-04 and most are built (events table, #295 changed-means-different, #296 media helper, #155 Docker events, #313 package kinds, #390 to #392 in review). Open: incus monitor (#392 in review) and ZED, per-user visibility (not needed), the three push paths (`vps/hs-watch.sh` stays). The follow-up list under Consequences ("to create when accepted") should be checked against the board and missing ones filed. |
| 0007 branches and releases | **Accept, then write a short follow-up.** It records what CLAUDE.md and `docs/dev-environment.md` already enforce. Two gaps: ADR 0017 rule 27 adds `release/*` branches, and we now keep a long-lived `0.2` branch next to `develop`, which the record does not know. No `v0.1.0` tag exists yet, so the signed-tag step is untested. |
| 0014 extension permissions | **Accept the recommendation (declare and disclose now; step 1 and 1b are built).** Answer open point 1 "yes, enough for v1" provided the docs say packages are trusted root code; points 2 and 3 (what `net` may mean, non-root packages) stay open until third-party packages are a goal. #239 is titled "Enforce extension permissions", which the recommendation does not promise: retitle it. |
| 0017 capabilities repository | **Accept after one edit.** Nothing is built except the empty repository, so no merged code is at risk and milestone 0.5 is far; accepting now unblocks planning. Suggested answers to the ten questions: 1 pilot `network` (checked in phase 4); 2 `vendor/` ignored by git; 3 AGPL; 4 **no `release/*` branch** for now (edit rule 27 before accepting, otherwise it contradicts 0007); 5 status checks only, no review required while the team is one person; 6 the core release key; 7 same-named branch if it exists, else `develop`; 8 no silent patch updates until a real server ran the flow; 9 no; 10 include `vendor/` (or its lock) in `hs backup config`, so the rebuild promise does not depend on a network. |
| 0018 interactive recipe runs | **Already Accepted (2026-11-09).** Nothing to decide. Its translation open point is answered by the 0025 decision. |
| 0022 first-run console token | **Accept the server part.** The threat model is complete and the rules are testable. The boot unit and installer hook are not built (belongs to #183, 0.4); the setup page is plain HTTP, so the code and the new password cross the LAN once, like today's sign-in. The owner should say explicitly that this is acceptable until TLS (open point). |
| 0001 Rust strangler | **Accept.** Workspace, pilot and job store are merged. The open points are answered by the #438 proposal above (HTTP server replacement: own ADR, not before 1.0). Depends on the #438 decision for the "when" part. |
| 0003 binary cache | **Accept.** Chosen on 2026-11-04. It is off until `CACHIX_CACHE` is set and `config/binary-cache.nix` has a name, so it fits the "off switch" rule. Condition: turn it on only after the rebuild time was measured on a real server; protect the Cachix key with two-factor login. |
| 0006 API in front of the CLI | **Accept.** It writes down what CLAUDE.md and a test already enforce (allowlist, plan then start, shapes never change). Open points belong to 0001. |
| 0008 capabilities and packages | **Accept.** Signed tags, `hs pkg`, `api-level` and the five `core = true` recipes exist. Open point (patch release without a diff) is answered in 0017 question 8. |
| 0009 capability as package kind | **Accept together with 0017** (they depend on each other; 0017 answers the open points). |
| 0010 command extension protocol | **Accept.** Schema `docs/api/ext-protocol-v1.schema.json` and the Rust SDK exist. Open points (shape of `data`, a request channel from the extension) are for v2 and for 0014 step 3. |
| 0011 service extensions | **Accept as v1.** The limits (5 starts in 10 minutes, 30 s to `ready`, 10 s grace) are first guesses; change them after a hardware run, which needs no new record. Not tested on hardware yet. |
| 0012 roles and API tokens | **Accept after answers (edit first).** Nothing is built (#434 is in 0.8). Suggested answers: `viewer` may not read logs (they can hold secrets); the audit log is admin only; `app-manager` sees an app's logs through its page, not an instance console; global roles first, no per-object scope; a rate limit for token use is a follow-up issue. |
| 0013 cluster state | **Accept as a record of the limit.** Option A (one owner per object, read-only copies, a partition degrades to stale, no vote, no failover) is the design behind `hs node` and the forced-command `status`, and it is what the positioning (#458) says: no clustering before 1.0. Open points are numbers (60 s polling, 3 intervals stale, 15 minutes alarm). |
| 0015 Wasm for extensions | **Accept.** The decision is "defer" plus "keep the protocol transport-neutral"; it costs nothing and lists when to look again. |
| 0016 declarative package UI | **Accept.** Packages ship no code to the browser; third-party code, if ever, only in a sandboxed iframe. Matches the positioning. Collect needed block types first (open point 1). |
| 0019 VM GPU passthrough | **Accept the approach, mark it unverified.** The decision (detect read-only first, warn, never edit kernel parameters, bridge by default) was written without a machine that has IOMMU; only `scripts/lib/iommu.py` against fixtures is merged. Suggested answers: print the NixOS change, do not write it; allow a headless boot GPU after a typed confirmation. |
| 0020 web package builder | **Accept.** Step 1 (check a draft through a plan, never a change) is built and harmless; steps 2 and 3 are in 1.0 (#268). Open: credentials for the pull request step (archive is the fallback). |
| 0021 graphical VM console | **Accept with a condition.** Server side built against a fake Incus only, no picture in the browser yet. Condition: it stays behind the `webTerminal` setting (the record says the same switch) and is not announced until run against a real VM (#261). I did not check the default of `webTerminal`; `config/schema.toml` has it. |
| 0023 nested test harness | **Accept.** A dev tool that touches no server; only its logic is tested, never a real VM ("Not tested on hardware yet" in `docs/dev-environment.md`). |
| 0024 vzdump import | **Accept step 1 only.** The read-only plan is built; the restore (rule 2) is the riskiest part (tar extraction, network files) and should get its own record before it is built, when #269 is scheduled (0.6). |
| 0025 translation scope | **Accept, 2026-11-10.** The owner already decided (comment on #437): English `hs`, translated web interface, codes only where the web needs them. Open questions 4 to 7 (no-op `i18n.sh` for one `api-level`, `# help.de:`, translating job errors, message codes as contract) go to #491 and #490. |

**Rule for CONTRIBUTING** (applied as a draft in `CONTRIBUTING.md`; `docs/dev-environment.md` rule 6 says the same in one line):

> Code for a decision record (`docs/adr/`) merges only when the record is Accepted, or when the code is behind a switch that is off by default
> (a `machine.toml` option in `config/schema.toml`, or a feature a command refuses without). The pull request names the record and says
> which of the two applies. Code that was merged before its record was accepted stays behind its switch, or is the first thing the owner's
> decision covers; do not build further on it.

**Questions for the owner**

1. Do you accept my recommendations as listed, or want to go through them one by one? (23 records; 22 need a status line and a date.)
2. Edit first (0007 follow-up, 0012, 0017): should I prepare those edits in a separate pull request?
3. 0017 question 4, `release/*` branches: no (recommended) or yes?
4. 0022: is a setup page over plain HTTP acceptable until TLS?
5. 0024: accept only step 1 and require a new record for the restore?

---

## #464 Release rhythm

**Proposal.** A release every **six weeks, on a Tuesday**. The date is fixed, the scope is not: what is verified ships, what is not moves
to the next release. The text is in `docs/dev-environment.md` ("Release rhythm"), marked draft.

Due dates (not set on GitHub; the owner sets them, or tells me to):

| Milestone | Due | Why |
| --- | --- | --- |
| 0.1 Trustworthy Foundation | Tuesday 2026-12-15 | 5 weeks from today; the release checklist exists; most open P0 items need runs on a real server (#161, #163, #165, #169, #415 to #417) by the owner |
| 0.2 Safe Updates | Tuesday 2027-01-26 | six weeks after 0.1 (the Christmas weeks are inside the 0.1 period) |
| 0.3 Foundations | Tuesday 2027-03-09 | not asked for; shown only to make the rhythm visible |

If 0.1 should come sooner, the rhythm still holds: 0.1 ships on 2026-12-01 with only what is verified, and 0.2 follows on 2027-01-12.

**On release day, an unfinished issue**

| State of the issue | What happens |
| --- | --- |
| Every box under "Done when" ticked | closed, listed in the release notes |
| Merged but not run on a real server or VM | stays open in In Review and moves to the next milestone; the release notes list it under "Not verified yet", the guide says "Not tested on hardware yet.", and a feature with risk is behind a switch that is off |
| Not merged | moves to the next milestone; its branch stays; nothing half-built is merged to finish it |

The date moves only for one reason: a P0 issue of that milestone that can lose data or lock a server out is open. The owner decides, once, by
at most two weeks, and writes it in the milestone. A hotfix (rule 3 of "Branches and releases") is outside the rhythm.

**Questions for the owner**

1. Six weeks, or four? (Six matches one person verifying on real hardware; four needs the test lab, #430.)
2. 0.1 on 2026-12-15, or sooner with less?
3. A date moves for a P0 only: acceptable, or should it never move?
4. `docs/dev-environment.md` rule 8 says one milestone at a time, and 0.2 work already runs on a long-lived `0.2` branch next to `develop`. Which wins, and
   when is `0.2` merged into `develop` (when 0.1 is tagged)? The draft text does not decide this.
