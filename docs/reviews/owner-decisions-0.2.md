# Owner decisions of 2026-11-10: positioning, Rust, ADRs, release rhythm

The owner (Simon) answered the proposals of the roadmap review on 2026-11-10. This page keeps the proposals with the answers, for #458, #438,
#437 and #464; delete it when the four issues are closed. The ADR status changes are in their own pull request (hobnix/server#514), after the
edits to the records (hobnix/server#513).

| Issue | Decision | Text in the tree |
| --- | --- | --- |
| [#458](https://github.com/hobnix/server/issues/458) positioning | Unraid users first; clustering, high availability and live migration out before 1.0; #203 and #201 moved to the milestone "Later — after 1.0" | `README.md`, `docs/roadmap.md` |
| [#438](https://github.com/hobnix/server/issues/438) Rust | Pause new shell-to-Rust moves through 0.4 until a real-server run; then the groups below; a new subcommand of a Rust group is Rust | this page |
| [#437](https://github.com/hobnix/server/issues/437) ADRs | All recommendations accepted; 0012 and 0017 edited first | `CONTRIBUTING.md`; the records in #513 and #514 |
| [#464](https://github.com/hobnix/server/issues/464) rhythm | **No fixed rhythm and no due dates** until after 1.0; what is verified ships; one milestone is *released* at a time | `docs/dev-environment.md` |

Things I found that the issues do not say:

- **ADR 0018 is already Accepted (2026-11-09)** and ADR 0002 (2026-11-08). The issue says 22 of 24 are Proposed; there are 25 records and 23 are Proposed.
- **ADR 0025 already has the owner's decision**: a comment on #437 says English-only `hs` commands and a translated web interface
  (option B, with C for what the web shows), tracked in #490. The record itself still says Proposed.
- **The CONTRIBUTING rule already exists** in a short form ("A change that needs a decision record is merged after the record is Accepted,
  or behind a switch that is off by default"), and so does rule 6 in `docs/dev-environment.md`. The new text only sharpens it (what counts as a
  switch, what to do with code that is already merged).
- GitHub milestones have no due date and no `v0.1.0` tag exists (2026-11-10); the owner wants no due dates for now.
- `gh issue view` fails in this repository (Projects classic is gone); I read the issues with `gh api`.

---

## #458 Positioning

**Proposal.** Hobnix is for the person who runs a home server today with Unraid (or a hand-built NAS) and wants apps, shares and backups
that they can read and rebuild. It is not a virtualization platform. The text is in `README.md` ("Who Hobnix is for") and
`docs/roadmap.md` ("Positioning").

The three things Hobnix does better, as I wrote them (each is checked against what is verified; two are not run on a real server yet, and the
text says so):

1. **Roll back the whole system**, not one app: every `hs update` is a NixOS generation (`hs update` with auto-rollback, TODO B8, #161).
2. **Rebuild the server from a backup disk and a passphrase** (#163, #169). Not run yet.
3. **The server is a readable git repository**: one `machine.toml`, every change shows a plan first, destructive ones need the typed name.
   (My choice for the third point; the issue names only the first two.)

Out of scope before 1.0: clusters with shared state, high availability, live migration, SDN-style network management. ADR 0013 (one owner
per object, read-only copies, no consensus) stays a record of why, and is the design behind the read-only node (#421) and the edge role (#422),
which stay.

Epics outside the positioning (the issue's third box). The board is the source; the owner's planning session moved #203 and #201:

| Issue | Milestone today | Proposal |
| --- | --- | --- |
| #203 Epic: Multi-node Management | 0.16 | **decided:** moved to the milestone "Later — after 1.0" (not cut down) |
| #201 Epic: Networking Management | 0.16 | **decided:** moved to "Later — after 1.0" (not cut down) |
| #205 Epic: Marketplace and Ecosystem (P2) | 0.13 | stays; ADR 0015 (Wasm) and ADR 0016 (third-party code) are already "not before an owner decision" |
| #421, #422 read-only node, edge role | 0.16 | stay (one person's own servers; no shared state) |
| #260, #261, #262 VM passthrough, console, nested harness | 0.15 | stay: Unraid users run VMs and GPUs |

**Answers (owner, 2026-11-10)**

1. Unraid users first.
2. The third "better" point (readable git repository, plan before change) is right.
3. #203 and #201 are **not** cut down; both moved to the milestone "Later — after 1.0".
4. The README may promise rollback and rebuild but keeps "not run on a real server yet" until #161 and #163 ran.


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

**Answers (owner, 2026-11-10)**: all four as recommended. Pause through 0.4 until the two moved groups ran on a real server; the groups per
release as in the table; a new subcommand of a group that is already Rust is Rust. The pause is about moving shell to Rust, not about
Python: read literally, a Python script may still move under the ADR 0001 checklist while shell stays (asked in the report).


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

**Answers (owner, 2026-11-10)**: go with the list. Accept all as recommended; 0012 and 0017 edited first, and 0007 made consistent with #233:
no `release/*` branch (the long-lived `0.2` branch plus tags), written into 0007, `docs/RELEASE-PROCESS.md` and `release-core.sh` (#513).
0022: plain HTTP on the setup page is acceptable until TLS, written into the record. 0024: step 1 only; the restore gets its own record.
The statuses are changed in #514, after #513.


---

## #464 Release rhythm

**Proposal was** a release every six weeks with due dates (0.1 on 2026-12-15, 0.2 on 2027-01-26).

**Decision (owner, 2026-11-10):** no fixed rhythm and no due dates for now, maybe after 1.0: the owner works when there is time. What
remains: **what is verified ships, what is not moves on** (`docs/dev-environment.md`), and the amendment to rule 8: one milestone is
*released* at a time; the next may be built on its own long-lived branch; the milestone branch is merged into `develop` right after the
release tag (rule 8 and `docs/RELEASE-PROCESS.md`, in #513). Release day for an unfinished issue: merged but not run stays open and moves on,
not merged moves on, as the text says.
