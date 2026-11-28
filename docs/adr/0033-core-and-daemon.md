# 0033: One Rust core, one daemon, thin front ends

Status: Accepted (2026-11-26) by the owner. The **Decided** items are rules. The acceptance names no Planned item, Proposal or open point: none of them is confirmed by it. Confirmed separately by the owner on 2026-11-26: **P-h** (item 21, one writer of the database); on 2026-11-27: **item 22** (owner of remote, edge and displays, #1337). ADR 0035 (accepted 2026-11-28) replaces **D13**: 0.15 holds P0 to P8.
Issue: none filed yet (milestone 0.15 "Core and Jobs", step P0 of docs/PLAN-core-daemon.md); the web server record #1266 moves into the same milestone
and is written with this record or beside it. Related: ADR 0001, 0006, 0012, 0026, 0032, ADR 0034 (job system), docs/PLAN-rust.md,
docs/PLAN-core-daemon-migration.md (the migration map).

This record writes down sections 1 to 4, 8 and 9 of docs/PLAN-core-daemon.md (design discussions with the maintainer on 2026-11-25). Nothing here is built,
measured or run on a server. Not tested on hardware yet.

How to read the Decision: **Decided** is what the plan marks as agreed by the maintainer. **Planned** is the recommended design; it becomes a decision only
when the owner accepts this record and may change before. **Proposal** needs a choice by the owner. Acceptance by the owner turns Decided items into rules;
it does not turn Planned items into decisions unless the acceptance says so per item.

## Context

What is true today, checked in the code of the branch `0.14` on 2026-11-26 (paths relative to the repository):

- **Three languages, many entry points.** The command is the bash dispatcher `hs` (`scripts/lib/hs.sh`, `scripts/lib/registry-load.sh`) over
  `scripts/lib/registry.tsv`: 628 rows, 299 of kind `sys` in 70 groups (second word) and 329 of kind `user` in 73 groups (first word), counted with `awk`
  on the file. Five rows run the Rust binary (`rust:secrets` twice, `rust:remote-codes`, `rust:remote-claim`, `rust:remote-accept`); everything else is
  a bash or Python script.
- **Rust exists as a library and an adapter.** `rust/` has `hobnix-core` (modules `error`, `jobs`, `log`, `pair`, `pair_host`, `secret`, `secrets`),
  `hobnix-cli` (the `hobnix` binary: `jobs`, `pair`, `secrets`) and `hobnix-ext-sdk`. `hobnix-core` depends on `serde`, `serde_json`,
  `chacha20poly1305`, `hkdf` and `sha2` (`rust/hobnix-core/Cargo.toml`).
- **The web server is one Python process as root.** `hs-web.service` runs `scripts/web-serve.py` (4141 lines) with no `User=` (`configuration.nix`,
  `install.nix`). It runs allowlisted `hs sys` words as subprocesses (ADR 0006), checks sign-in, sessions (`/run/hs-web/sessions.json`), roles (ADR 0012,
  `scripts/lib/sys-roles.tsv`, generated from `docs/api/sys.toml`), tokens (`/var/lib/hs/api-tokens.json`), serves SSE (`/api/events`), the browser
  terminal (`scripts/web_terminal.py`) and the VM console (`scripts/web_vmconsole.py`).
- **Live state is a separate collector.** `hs-live` (`capabilities/live-state/module.nix`) runs `scripts/live-collect.py`: `hs sys` reads on the
  intervals of `scripts/lib/live-topics.tsv` (84 topics), changed documents into SQLite (`/var/lib/hs/state.db`, tables `live`, `topics`, `heartbeat`,
  `demand`, `live_delay`), a Docker watcher (`docker events` of the instance `docker`) and an Incus watcher (`incus monitor --type=lifecycle`), named
  events mapped to topics (`scripts/lib/event-topics.tsv`). The web server is woken over the datagram socket `/run/hs/live.sock` (`state-db.py`
  `live_sock_path`, `web-serve.py` line 2616) and reads the counters once a second as the fallback (ADR 0026, D11 of PLAN-live-interface).
- **Other long-running or timed programs:** `hs-unit-watch` (`scripts/unit-watch.py`), `hs-event-notify` every 30 s (`scripts/event-notify.sh`,
  `event-notify.py`), the extension services `hs-ext-svc@` and the transient `hs-ext-run-<name>` (`scripts/ext.sh`, `scripts/lib/ext_service.py`),
  in all 46 units of our own (`hs-*` and `bulk-mount`) in `configuration.nix`, `install.nix` and `capabilities/*/module.nix` (listed in the migration map).
- **The rules live in many places.** The confirmation by typed name is checked in each `*-change.sh` script (ADR 0001 decision 6, ADR 0006 rule 3); the
  role check in `web-serve.py` only; the audit line in `scripts/lib/audit.sh`; the refresh groups in registry flags and `live-topics.tsv`.

### Where the code disagrees with the plan

1. **"`hobnix-core` uses only `std` and `serde`"** (PLAN-rust.md "Risks", ADR 0001 "Job store") is no longer true: the pairing code added
   `chacha20poly1305`, `hkdf` and `sha2`. Section 16 of the plan ("may use more than `std` and `serde`") therefore describes the present, not only the
   future; the rule to name a reason per dependency is what is new.
2. **Event classes exist for package events only.** Section 6.2 says events of class `ephemeral` go after 7 days. In `scripts/state-db.py`
   `trim_events` that holds only for rows with `source = 'pkg'` whose kind a package declared `ephemeral` (or `metric`, 35 days); core kinds in
   `scripts/lib/event-kinds.tsv` have no class column (ADR 0034 takes this up).
3. **The plan names `history.db` as a new file.** Today events, rollups, SMART readings, live documents and counters share one file,
   `/var/lib/hs/state.db` (tables `meta`, `disks`, `events`, `smart`, `baseline`, `samples`, `topics`, `reads`, `usage`, `rollups`, `hours`, `demand`,
   `live`, `heartbeat`, `live_delay`). Moving events out of it is a change the plan implies (6.2 "apart from temporary runtime data") but does not list
   as a step.
4. **Backup of the database.** Section 6.2 asks for SQLite's backup support. Today `scripts/backup.sh` `host_files` copies `/var/lib/hs` as files with
   restic, `state.db` included, while writers may be active.
5. **A Rust CLI already exists in part.** Section 3 decision 3 says "the CLI is written in Rust". Today `hobnix` is an adapter behind six registry rows;
   the human CLI is the bash dispatcher. ADR 0032 decision 6 keeps that dispatcher until everything behind it is Rust; this record proposes to change the order
   (Decision, item P-f).

## Decision

### Decided (plan section 3, agreed 2026-11-25)

1. **D1. The core.** `hobnix-core` is a library that holds every operation. A feature is a core operation first. A test names each operation that
   the CLI or the web API lacks, with a reason.
2. **D2. One daemon.** `hobnixd`, on Tokio, uses the actor pattern without an actor framework. It runs as root and holds live state, the watchers, the job
   monitor and the supervision of extension services; for the web it checks sign-ins, sessions and roles and runs operations.
3. **D3. Principle (section 1).** Changes go through the core: the CLI, the web API and the timers have no rules of their own. System state comes from
   the system (ZFS, Incus, systemd, disks); a row or an event never proves what is true now, and before a risky change the core reads the safety facts
   again. Live state is a copy that can be rebuilt.
4. **D4. Front ends.** The CLI is Rust and links the core, so it works without the daemon; English only; `clap` for arguments; the terminal library
   (`cliclack`, or `dialoguer`, `indicatif`, `console`) is chosen at implementation, behind one `ui` module.
5. **D5. The web API is a separate service without root,** `hobnix-web`, built with `axum`, one binary with the daemon and two units. It reaches the
   daemon over a local socket. Until P6 `web-serve.py` stays the web server. The privilege split is part of the first Rust API, not added later.
6. **D6. Every user-requested change is a job; systemd runs the jobs** (plan 3.5, 3.6). The rules of the job system are ADR 0034.
7. **D7. `sys` commands are retired area by area,** when their last caller is gone (step P7, P8).
8. **D8. Live state** moves into the core (reads) and the daemon (scheduling, watchers, subscriptions) and refreshes single resources.
9. **D9. Storage.** SQLite through `rusqlite` with migrations, no ORM. A package never opens the database.
10. **D10. Extensions** stay separate processes speaking the JSON lines protocol (ADR 0010, 0011), in any language; the SDK and the core share the
    message types; the host side (Python today) moves into the core. Wasm stays deferred (ADR 0015); if it comes, a `wasmtime` process speaking the
    same protocol is tried first.
11. **D11. Measure before porting** (section 14), on a real server, again after P3, P4 and P6.
12. **D12. Stays bash:** installer and first run, unlock and recovery, `hs update` and rollback, thin wrappers (ADR 0032 decision 3). These paths stay
    small and use the same locks as the core.
13. **D13. Milestone.** This work is milestone 0.15 "Core and Jobs" (P0 to P4); P5 to P8 get later milestones by area.

### Planned (plan sections 4, 8, 9; to be confirmed at acceptance)

14. **P-a. Operation declaration (4.1).** An operation is declared once: name, typed input, required role, plan (what happens, which name is typed to
    confirm), apply, affected resources, locks, cancel points, whether it notifies, and how an interrupted run is inspected and recovered. The CLI, the web
    API, the role table and the API description are generated from it. Apply reads the safety facts again and refuses when they differ from the plan
    (#1219 part 3). The confirmation check is in the core.
15. **P-b. System access layer (4.2).** One layer for systemd (D-Bus), the journal (JSON output), Incus (API and lifecycle events), Docker (at first
    `incus exec docker -- docker events`, as `live-collect.py` does), udev, ZFS, SMART, SnapRAID and Samba (their tools, JSON where the pinned version has
    it, to check). Each behind a trait so tests use fakes. No other module starts a command.
16. **P-c. Actors (4.3).** Live state is one actor holding the current values; the job monitor is one actor; extension services possibly one supervisor
    each; a read is a short task; an operation check is a plain function. Actors coordinate and are never the only place important data is kept: after
    a restart the daemon rebuilds from the system, the records and the database.
17. **P-d. Live state by resource (8).** A refresh signal names a resource (`instance:jellyfin`) and says "read again"; it never sets a value. Signals
    close together cause one read; a signal during a read causes one more read. After a watcher reconnects, what it watches is read again; slow periodic
    reads stay the safety net. Page demand comes from the open subscriptions. Typed dependencies, with tests for missing links and loops.
18. **P-e. Trust across the split (9).** The daemon checks session and role on every request (a claim from `hobnix-web` is not enough), accepts defined
    operations only (never a command line), checks plans and typed confirmations itself and filters live updates by what the user may see.
19. **P-f. The Rust CLI starts early (9, step P5 after P2).** Ported commands call the core, all others go to the existing scripts. This reverses the
    order of ADR 0032 decision 6 (bash launcher in front of Rust) for the commands it covers. The plan text has no "Decided" mark on this paragraph,
    although section 16 lists the change to ADR 0032; the owner confirms it.
20. **P-g. When live values move to memory (8).** Only after `hobnix-web` serves the page (P6); until then the daemon keeps writing the SQLite table that
    `web-serve.py` reads. After a restart the map is empty and fills from new reads.
21. **P-h. One writer of the database (6.1).** The core is the only code that reads or writes the database. While Python still writes, one side owns the
    schema, and both wait for locks (WAL, busy timeout).

### Proposal (needs a choice by the owner)

22. **Owner of remote, edge and displays** (plan section 11 says "to be assigned in P0"): the migration map proposes the core for the reads and the
    pairing (it is already in `hobnix-core` `pair`), the daemon for the deck feed (`hs-deck-status`, today every 20 s), and `deck-serve.py` staying a
    separate small server until `hobnix-web` can serve the deck API. **Confirmed by the owner on 2026-11-27** (#1337): these areas move in step P7, and the
    edge-node units stay unchanged until then.

## What changes in older records on acceptance

The text of these records is not edited. Each has a Status note that points here. A change that rests on a Planned item waits until that item is confirmed.

| Record | Change on acceptance |
|---|---|
| 0001 Rust behind the `hs sys` contract | The end state is no longer "the `hs sys` contract is the API" (decision 1, 4): the core operation is. The method (characterization test, one release side by side, a short way back) stays and applies per step. Decision 3 (service layer `hobnix-core`, adapter `hobnix-cli`) stays and is widened by D1. Decision 5 was already amended by ADR 0032. "Std only" is replaced by "each dependency with a reason". |
| 0006 The `hs sys` contract is the API | Rule 1 (no second data layer, the web runs `hs sys`) and rule 2 (allowlist of words) end per route group with P6; the web then calls operations over the socket. Rule 3 (plan, then start; the confirmation check in the command) stays, moved into the core. Rule 4 (shapes do not change) holds while a `sys` row exists. Rule 5 becomes "a feature is a core operation first" (D1). |
| 0012 Roles and API tokens | Decision 2 (a role per `sys` row, `sys-roles.tsv`) becomes a role per operation (P-a). Decision 3 (the check in `web-serve.py`) moves into `hobnixd` (P-e). Tokens, the three roles and the AD rules stay. |
| 0026 Live state, one mode, one store | Decision 3 (one document store in the state database) holds until P6; after P6 the current values live in daemon memory (P-g) and the table goes. Decision 8 (events are signals, not data) stays and is sharpened by P-d. Decision 9 (push socket) stays as the daemon's poke. |
| 0032 Rust is the main language | Decision 6 changes: the Rust CLI starts early and calls the scripts for unported commands (P-f; planned, not decided), not the bash launcher in front of Rust. Decision 5 (own record for the web server) is answered by D5 together with #1266. The rest stays. |
| 0004, 0005, 0018 | See ADR 0034 (job system). |

## Consequences

- Easier: one place for each rule (role, confirmation, lock, refresh); typed system access with fakes for tests; fewer processes per read once reads
  stop starting bash and Python (expected, not measured: section 14).
- Harder: a long period with logic in Rust, bash and Python; a socket protocol between `hobnix-web`, the CLI, jobs and the daemon, with version
  differences during an update; a root daemon that must survive restarts without losing jobs (ADR 0034); a larger Nix build (not measured).
- Follow-up issues to file before the milestone is filled (plan 15.2): the baseline measurement (section 14), history and retention (ADR 0034), the
  socket protocol, the system access layer, the operation model, `hobnixd` skeleton, and one per background program of P3.

## Open points

1. The local sockets: the poke and the web protocol, their shape and permissions (plan 17.2).
2. `hn` rename: does the Rust CLI start as `hn`, with `hs` as alias (plan 17.5)?
3. German in the remaining bash scripts (`scripts/lib/i18n.sh`, part of the package contract; plan 17.6, ADR 0025).
4. Python for extensions once PLAN-rust step 8 removes Python from the server image: keep, let packages bring their own, or end it (plan 17.7).
5. How the daemon reaches Docker (plan 17.8).
6. Whether events, totals and jobs leave `state.db` for `history.db`, and what stays in `state.db` (Context, disagreement 3). Answered: they leave in step
   P2 (#1340); the measurement tables stay (owner, 2026-11-27, #1337).
7. The owner of remote, edge and displays (Proposal 22): answered, item 22 is confirmed (2026-11-27).
8. Not tested on hardware yet.
