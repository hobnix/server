# Plan: one Rust core, a daemon, and thin front ends

Design record. Contributor document, not a guide. Written from design discussions with the maintainer on 2026-11-25. Nothing here is built or run on a
server. Measured so far: the build on a development PC (section 14.1) and the baseline of a real server (section 14.2). Nothing of the
design is tested on hardware yet.

It extends [PLAN-rust.md](PLAN-rust.md) and ADR 0032 (docs/adr/0032-rust-main-language.md: Rust is the main language). It changes some earlier decisions;
they stay in force until the records of section 16 replace them.

How to read it: **Decided** is agreed. **Planned** is the recommended design, to be confirmed in the decision records. **Proposal** needs a choice by the
maintainer. Every part gets an owner and a boundary here. Only the core and the job system are designed in detail.

## 1. Principle

**The core owns the rules, the system owns its state, and live state is a copy.**

| Question | Source of truth |
|---|---|
| How is an operation done? What is allowed, confirmed or locked? | the core |
| What state is the server in now? | the system: ZFS, Incus, systemd, the disks |
| How should the server be configured? | `machine.toml` and the Nix configuration built from it |
| What happened with jobs and events? | job records and the event log, reached through the core |
| What does the page show? | live state, a copy that can be rebuilt |

1. **Changes go through the core.** The CLI, the web API and the timers have no rules of their own. Packages use the protocol for what they ask `hobnix` to
   do. This is not full isolation: some package commands still run as root.
2. **System state comes from the system.** A row or an event never proves what is true now. Before a risky change the core reads the important facts again.
   Someone using `incus` or `zfs` directly is seen by the next read.

Limits: the bash paths that must run without the binary stay outside the core, so they are small and use the same locks. Until the move is finished, logic
is split between Rust, bash and Python. For each moved operation, every caller switches to the core and the old logic is removed after the side-by-side
release.

## 2. Shape

```
terminal -> CLI ---------------------------------------+
timer    -> CLI or core -------------------------------+-> hobnix-core -> system access layer -> systemd, Incus, ZFS, SnapRAID, Samba, disks
browser  -> hobnix-web -> local socket -> hobnixd -----+              -> database
extension processes <-> JSON lines <-> core (run by the CLI or by hobnixd)
```

| Process | User | Runs | Stops with a daemon restart |
|---|---|---|---|
| CLI | as today | one command | no |
| Job | root | its own systemd unit | **no** |
| `hobnixd` | root | live state, watchers, job monitor, extension supervision; for the web: sign-in checks, sessions, roles, operations | itself |
| `hobnix-web` | not root | HTTP, frontend files, cookies, SSE and other browser connections | no, but it cannot serve changes or live updates without the daemon |

`hobnix-web` arrives with P6. Until then `web-serve.py` is the web server.

## 3. Decided

1. `hobnix-core` is a library with every operation. A feature is a core operation first. A test names each operation that the CLI or the web API lacks, with
   a reason.
2. One daemon, `hobnixd`, on Tokio, with the actor pattern and no actor framework.
3. The CLI is written in Rust and links the core, so it works without the daemon. English only. `clap` for arguments; the terminal library (`cliclack`, or
   `dialoguer`, `indicatif`, `console`) is chosen at implementation, behind one `ui` module.
4. `sys` commands are retired area by area, when their last caller is gone.
5. Every user-requested change is a job, quick ones too. Reads, plans and refreshes are not jobs.
6. systemd runs the jobs. A job is never a task inside the daemon.
7. Events follow section 7.
8. Live state moves into the core (reads) and the daemon (scheduling, watchers, subscriptions) and refreshes single resources.
9. SQLite through `rusqlite` with migrations, no ORM.
10. Extensions stay separate processes that speak the JSON lines protocol, in any language. SDK and core share the message types. A package never opens the
    database.
11. Wasm stays deferred (ADR 0015). If it comes, a `wasmtime` process speaking the same protocol is tried first.
12. Measure before porting (section 14).
13. This work is its own milestone, **0.15**, after 0.14 (Marketplace) (section 15).
14. Job records move into SQLite, beside the events (section 6.2).
15. The web API is a separate service without root, `hobnix-web`, built with `axum`. It reaches the root daemon over a local socket (section 9).
16. History is kept for years, with permanent daily totals, in `history.db` (section 6.2).

Stays bash: installer and first run, unlock and recovery, `hs update` and rollback, thin wrappers (ADR 0032 decision 3).

## 4. Core

### 4.1 Operations

An operation is declared once: name, typed input, required role, **plan** (what happens, which name must be typed to confirm), **apply**, the resources it
affects, the locks it needs, when it can be cancelled, whether it notifies, and how an interrupted run is inspected and recovered. The CLI, the web API,
the role table and the API description come from this declaration. Today the roles hang on `sys` rows (`scripts/lib/sys-roles.tsv`, generated from
`docs/api/sys.toml`).

The confirmation check is in the core. Apply reads the safety facts again (disk identity, free space, running state) and refuses when they differ from the
plan (#1219, part 3).

### 4.2 System access layer

**Planned.** One layer for systemd, Incus, ZFS, SnapRAID, Samba, SMART and udev, each behind a trait so tests use fakes. Jobs and live state both use it;
no other module starts a command.

| System | Access |
|---|---|
| systemd | D-Bus: start units, receive state changes |
| journal | its JSON output |
| Incus | its API and lifecycle events |
| Docker | runs inside the `docker` instance; today `incus exec docker -- docker events`. Keep that at first; do not assume a socket on the host |
| disks added or removed | udev events |
| ZFS, SMART, SnapRAID, Samba | their tools, with JSON output where the pinned version has it (to check) |

### 4.3 Actors

An actor is a task that owns state and handles messages: a size-limited channel, reply channels. Tokio gives no supervision, so restart and shutdown are our
code. Blocking work and slow reads run in separate tasks.

| Component | Starting design |
|---|---|
| Live state | one actor holding the current values |
| Job monitor | one actor watching all jobs |
| Extension services | possibly one supervisor per service |
| One read | a short task |
| One operation check | a plain function |

**Actors coordinate; they are never the only place where important data is kept.** After a restart the daemon rebuilds from the system, the records and the
database. Split an actor when it is a bottleneck, needs its own failure handling or has its own lifecycle; not one per object.

## 5. Jobs

### 5.1 Path of one change

An app start from the browser:

1. `hobnix-web` takes the request and passes it, with the session, to the daemon. The daemon checks session, role and input. (Until P6, `web-serve.py`
   does this and calls a `sys` row.)
2. The core writes a job record and asks systemd for the unit.
3. The browser gets the job id at once.
4. The job uses the core to start the app.
5. The job saves its state and events, then pokes the daemon over a local socket. The daemon reads what is new; it reaches the browsers as SSE through
   `hobnix-web`.
6. Independently, the Incus watcher reports that the instance changed.
7. Live state reads that app again and sends the new value only when it differs.

A job started by the CLI or a timer takes the same path from step 2. The CLI follows its job without the daemon.

- Job state and app state are separate. "Job ok" never sets an app to running; "instance running" does not say the app is healthy.
- Nothing depends on the order of the job's report and the watcher's report.
- Save first, poke second. A periodic look at the database catches a lost poke.
- The job monitor also follows the unit state in systemd, so a job that dies without a word is noticed and its record corrected. After a daemon restart it
  reloads the records, compares them with systemd and watches again.

The job code does for every operation: record and `job.*` events, refresh signals after success, failure **and** cancel (ADR 0005 rule 8), and reconcile
after a crash or reboot.

Scheduled work that changes something (backup, sync, scrub) is a job. Routine health reads are not.

### 5.2 Locks

**Planned.**

- Each operation declares what it reads and what it needs to itself. A lock on a pool covers its disks.
- The **job process** holds kernel file locks (`flock`), so a crash frees them. While both exist, Rust and bash use the same lock files
  (`scripts/lib/bulklock.sh`, `/run/hs-bulk.lock`).
- All locks are taken at once or in one fixed order.
- A conflict is refused and names the job in the way. A scheduled job may wait or end as `skipped`, as today. No general queue yet.
- An update or a reboot does not run beside a job that cannot safely be interrupted.

### 5.3 Passwords

**Planned:** systemd credentials (`LoadCredential`, already used for extension services, ADR 0031). The core writes a root-only temporary file in memory,
systemd gives the unit its copy, the core removes the original. Never in a record, a log, argv or the environment. Answers to questions use the same care
(ADR 0018 rules 7 and 10).

To check: that the unit keeps its copy after the original is removed, cleanup when the start fails, and whether swap can put the file on disk. A password
lost in a reboot makes the job interrupted, and it is asked again. Until the privilege split exists, the web server hands it over on stdin as today.

### 5.4 Cancel

**Planned.** Each operation, or phase of one, is cancellable **now**, **at the next safe point**, or **not at all**.

- A cancel is a request. The record says `cancelled` only after the job stopped. Today `scripts/jobs-change.sh` marks first and takes it back when the stop
  fails.
- The risk is declared by the operation, not guessed from the unit name as today.
- **No promise of automatic rollback.** #1219 proposes that cancel always reverts. Revert only where it is built and tested: a snapshot rollback loses data
  written after the snapshot, and some storage steps cannot be reverted.

### 5.5 Notifications and questions

| Situation | Planned default |
|---|---|
| Quick job that a person started | result in the page or the CLI, no push |
| Long job succeeds | push when the operation turns it on |
| Scheduled or destructive job fails | push |
| Job needs input | shown and pushed |

Open: the default for a failed quick job that nobody is watching.

Questions keep ADR 0018: state `waiting`, answered by the person who started the job or an admin, 24 hour timeout. Ask as much as possible in the plan.
**A job does not wait for input while it holds a storage lock.**

### 5.6 Failure and upgrade rules

**Planned.**

- **Update and rollback.** `scripts/state-db.py` refuses a database with a newer schema (`SchemaTooNew`) unless the database names an oldest writer that
  its own schema version reaches (`meta` key `oldest_writer`, #1352; when a step keeps or raises it: `schema_steps` in that file). A release from before
  #1352 does not read the number, so the first schema change that relies on it ships at least one release later. Not tested on hardware yet. Once jobs
  depend on the database, a rollback could stop every job. Rule: at least the previous release works with the new format. Test an update and a rollback
  while a job of the old version runs. The same holds for the socket messages between old jobs, the CLI and a new daemon.
- **Database failure** (disk full, damaged, locked). Today a job runs without a record when the record cannot be written. New: normal changes are refused;
  a short, named list of repair operations runs anyway and logs to the journal.
- **Alerts do not need the daemon.** systemd's failure alert (`hs-notify-failure@`) stays independent. The daemon itself is watched. Check this again when
  event notifications move into the daemon.
- **Duplicate requests.** A double click or a network retry carries a request id and gets the same job.
- **Interrupted work** says how to inspect and recover. A destructive step is never repeated automatically.
- **Stuck jobs.** Each operation has a time limit or a progress rule. A long quiet time alone never kills storage work.

Also: to verify that a job unit survives `nixos-rebuild switch` with the new start method; to measure the cost of one unit per quick action.

## 6. Data and retention

### 6.1 Database

The core is the only code that reads or writes the database. While Python still writes, one side owns the schema, and both wait for locks (WAL,
busy timeout). Say for each stored file whether it is backed up or can be rebuilt (ADR 0002).

### 6.2 History

What exists (`docs/events.md`, ADR 0004, `scripts/state-db.py`):

| Data | Store | Today |
|---|---|---|
| Events | SQLite, `events` | deleted past the newest 5000 rows or 90 days; class `ephemeral` after 7 days |
| `metric` events (packages) | SQLite | raw rows deleted after 35 days |
| Monthly counts | SQLite, `rollups` | one row per month, user and kind, added by the sender (#927, closed); never pruned |
| Job records | **one JSON file each**, `/var/lib/hs/jobs/` | removed when outside the newest 200 **and** older than 30 days |
| Job output | journal | the journal's own retention |

A search of the issues in `hobnix/core` and `hobnix/official` on 2026-11-25 found none for archiving or merging job records or events. #927 covers monthly
counts for package metrics only. This milestone needs an issue for it.

With every change a job there are many more records and events.

1. **Decided:** job records move into SQLite, beside the events. This reverses ADR 0004 rule 1 (JSON files, chosen on 2026-11-04 as plain for shell and
   Rust). With one Rust writer that reason gets weaker, and filtering, grouping and counting get easier. To design: how bash paths that run without the
   binary report a job, the write load of progress updates, the rules of section 5.6 for a damaged database, and how the existing records are moved.

The rest is **planned**:

The rest is **decided** too; the numbers are starting values, adjusted after measuring real use. History is kept for years, not for 30 days. For
orientation, an assumption and not a measurement: 1,000 records a day at 1 KB each is about 365 MB a year before indexes.

#### What is kept

| Data | Default |
|---|---|
| Job summary: operation, target, who, when, result, duration, error code | no age limit |
| Job details: plan, steps, saved output | 1 year; no age limit for failed (including interrupted) and destructive jobs |
| Important events: security, destructive actions, failures, disk problems | no age limit |
| Normal events, for example an instance started | 1 year |
| Short-lived events | 7 days |
| Raw statistics events (`metric`) | 35 days, as now |
| Daily totals | permanent |

- **The limit of 5000 events goes.** With more actions creating events it would remove useful history after a short time.
- **A storage limit** (start with 2 GB) with an early warning. It removes short-lived and raw data first, then older job details and older normal events. It
  never removes daily totals or unfinished jobs. When only protected data is left, it warns and a person decides what to delete.
- Housekeeping runs once a day.
- **Two settings only:** how long detailed history is kept, and the storage limit.

#### Which events are important

**Decided.** Each core kind names its class in `scripts/lib/event-kinds.tsv` (or what replaces it).

| Class | Events |
|---|---|
| `important` (no age limit) | **security:** lockouts and failed sign-ins, changes to users, roles, tokens and SSH keys, vault and secret changes; **destructive:** delete, wipe, restore over data, rollback; **failures:** failed and interrupted jobs, events of level error; **disk and data health:** a disk missing, removed or getting worse, pool and parity problems; **system changes:** update, rebuild, rollback |
| `normal` (1 year) | other changes, instance start and stop, job progress through its states, notifications sent |
| `ephemeral` (7 days) | a status that is only interesting now |
| `metric` (35 days) | a tick that is counted into totals, not read |

A success needs no important event: its job summary has no age limit. **Planned:** repeats of the same important event (failed sign-ins, a job failing in a
loop) are combined into one row with a count and the first and last time, so a loop or an attacker cannot fill the permanent history.

#### Retention of package events

**Decided:** a package names the retention of **each event** in `package.toml`. `[[events]]` has `retention` today (`ephemeral`, `audit`, `metric`;
`docs/events.md`); the values become `ephemeral`, `normal`, `important`, `metric`.

- The default is `normal`. The old value `audit` means `normal`, so no package gets "no age limit" without asking for it. This changes the package
  contract: it needs the usual deprecation.

**Planned:**

- Install and update show which events a package keeps with no age limit. An admin can lower the class of a package's event.
- Each package has a limit of `important` rows (start with 10,000). Above it the oldest of that package follow the `normal` rules, with a warning. A service
  may send 50 events a minute (ADR 0011), up to 72,000 a day.
- The class is **stored on the row** when it is written. Today the rules come from the installed declaration, which `hs pkg` deletes with the package. A
  removed or updated package must not change what happens to old rows; a new class applies to new events. An admin's lowering may apply to old rows too.

#### Statistics

Designed before data is collected.

- Separate typed fields for operation, target, person, source, parent job, the times, result and error code; not hidden in text or JSON.
- Stable ids for targets, for example the serial number of a disk, not `/dev/sdb`.
- Daily totals by operation and target (count, failures, duration), updated in the same transaction that saves the result of a job, so removing details
  loses no total.
- Statistics are versioned: when collection began and when a meaning changed is recorded.

Kept summaries allow some new reports later. What was never saved, or is already deleted, cannot be recovered, also not from the old records.

#### Measurements are not events

CPU use, temperatures, disk usage and SMART readings are measurements with their own tables. Today SMART readings are kept 400 days and thinned to one a day
after 30 (`scripts/state-db.py`); fill levels are kept 400 days. Kept permanently: useful daily disk health and capacity trends, and for temperatures the
daily low, average and high. Detailed, frequent measurements belong in the metrics system (capability `metrics`, Prometheus). Their design is part of
health and notifications (section 11, #1380).

**Decided** (2026-11-27): the measurement tables stay in `state.db` in step P2. They cannot be rebuilt, so `state.db` is backed up with SQLite's backup
support too, not only `history.db`. The health and notifications design says where they live later.

#### Storage, backup, privacy

- Jobs, events and their totals are in **one file, `history.db`**, apart from temporary runtime data, so one transaction saves them together.
- It cannot be rebuilt, so it is **backed up** with SQLite's backup support, and the restore is tested.
- Indexes, loading in pages, and freed space is given back.
- **No yearly archive databases yet:** they make searches and upgrades harder. An export (JSON Lines or CSV) is added when needed. An export does not
  replace the backup.
- **The move keeps the event ids.** Replay after a reconnect and the cursors of extension services (ADR 0005, ADR 0011) use them, and an id is never reused.
- A failed or interrupted job saves the end of its output in its details, because the journal may drop it earlier: **the last 200 lines, at most 64 KiB**,
  whichever is reached first, without colour codes and progress-bar redraws, with a mark when lines were cut. The numbers are starting values. The output
  follows the retention of the job's details. Longer retention makes the secret rules more important. For an interrupted job the lines are taken at
  reconcile, as far as the journal still has them.
- History records what people do. An admin can delete it or remove personal details, also from the totals.

**Decided, removing a person:** replace the person with the same neutral "removed user" mark instead of deleting rows, so what happened and the totals
stay. It covers the person fields of jobs and events and the per-user package totals (`rollups`, merged under the mark). Free text and payloads are harder:
packages mark the payload keys that hold personal data; text, unmarked package payloads and saved job output of that person's rows are cleared. It is its own
action with a typed confirmation, not a side effect of removing an account. Backups keep the old data until they expire, and the action says so. It removes
the identity; it does not promise that the remaining history is anonymous.

**Decided for now:** the audit events (`audit.ok`, `audit.failed`: who did what) stay. **Review later**, when every change is a job (after P7): whether the
job record and its `job.*` events say everything the audit events say, and whether they can then be removed. Check first what they cover that a job does
not, for example changes made by a command that has not moved yet. Until then they count as security events.

## 7. Events

| Type | Meaning | Example | In the event log |
|---|---|---|---|
| Command | please do this | start jellyfin | no, the job records it |
| Event | this happened | `job.failed`, `ct.started` | yes, as long as section 6.2 says |
| Refresh signal | this may have changed | read jellyfin again | no |
| State | how it is now | running, 60 % done | current value or job record |

1. An event is added when someone may want to see it later or react to it. Reads, refreshes and progress are not events.
2. Events are not commands. An automation may react to an event by asking the core to start a job.
3. State comes from its owner. It is never rebuilt from the log.
4. Each kind has one producer. What can be observed is reported by the watcher, which also sees changes made outside `hobnix`; what only the operation knows
   is reported by the operation.
5. Refreshes and automations are separate. A refresh may run twice. An automation needs protection against duplicates and rules for retry and failure.
6. SSE carries data from the daemon to the browser. It is not the event system.

A watcher that was disconnected refreshes what it watches. That restores state, not the missed events, so the log is not a complete history. ADR 0005 (log,
kinds, one writer, replay, resync) stays.

## 8. Live state

Today `hs-live` runs `hs sys` reads on intervals and stores changed documents in SQLite. It already has Docker and Incus watchers, named events mapped to
topics (`scripts/lib/event-topics.tsv`), topic dependencies where only a changed value spreads, and slower reads for some topics while no page wants them.

| Part | New home |
|---|---|
| Reading and parsing system state | core |
| Scheduling, watchers, subscriptions | daemon |
| Current values | memory of the daemon, a map owned by the live-state actor |
| Events and history | database |

**When values move to memory:** only after the Rust web API serves the page (P6). Until then `web-serve.py` reads the SQLite table, so the daemon keeps writing
it. After a restart the map is empty and fills from new reads.

- **Resources, not only topics.** A signal names what may have changed (`instance:jellyfin`). It is read, and its dependents only if the value differs.
- A signal says "read again"; it never sets a value.
- Typed events and dependencies; tests for missing links and loops.
- Signals close together cause one read. A signal during a read causes one more read afterwards.
- After a watcher reconnects, what it watches is read again. Slow periodic reads stay as the safety net.
- Page demand comes from the open subscriptions.
- The CLI and jobs poke the daemon after a change; the periodic look covers a lost poke.

## 9. Front ends

**CLI.** Rust, links the core, English. One `ui` module: messages, progress, prompts, tables, confirmation by typed name, refusal to prompt without a
terminal, plain output for scripts, `--json` where useful. It may start early: ported commands call the core, all others go to the existing scripts.

**Web API (decided).** `hobnix-web`: `axum` on Tokio, a service without root. One binary with the daemon, two units; both share the Rust types of the
requests and replies. Requests are ordinary async tasks, not one API actor. Each SSE connection subscribes to updates. It must work while storage is locked.

| `hobnix-web` | `hobnixd` |
|---|---|
| HTTP and the frontend files | runs the operations of the core |
| cookies and request protections | checks sign-ins and keeps sessions |
| SSE and other browser connections | checks roles and permissions |
| forwards requests | live state, job monitor, watchers |

The split helps only when the daemon does not trust the web service:

- The daemon checks session and role on every request. A statement such as "this user is an admin" from `hobnix-web` is not enough.
- It accepts defined operations only, never a command line.
- It checks plans and typed confirmations itself.
- It filters live updates by what the user may see.

Limits: a taken-over `hobnix-web` can still capture the passwords and sessions that pass through it, then act as that user. Terminals and consoles stay
powerful: the root side decides who may open one and what it runs as. The split does not protect traffic on the network; HTTPS is a separate need.

Cost: the socket protocol carries requests, errors, live updates, terminals and file transfers, with version differences during an update and either
service being away. The split is part of the **first** Rust API, not added later. The socket protocol of Core and Jobs leaves room for it.

## 10. Packages

- Extensions: SDK split and rename (#1262), command macro and drift check (#1263), test harness and templates (#1264), as in
  [PLAN-package-sdk.md](PLAN-package-sdk.md). The host side of the protocol (Python today) moves into the core and uses the same message types.
- Recipes and capabilities use no SDK today. A recipe SDK (#1219) builds on the job model of section 5.
- Extension actions as jobs (#1126) use the same job model, not a second one.
- Packages that add `sys` rows need a new way to declare operations before `sys` can go. This changes the package contract and needs a deprecation release.
- **Open:** PLAN-rust step 8 removes Python from the server image, but Python extensions are supported today. Keep Python as an option, let packages bring
  their own, or end the support.

## 11. Other parts

Each has an owner and a boundary here and gets its detailed design before its migration starts. Core and Jobs designs only what it needs from them.

| Part | Owner | Its design must settle |
|---|---|---|
| Configuration | core | who reads, checks and writes `machine.toml`; what applies at once and what needs `nixos-rebuild`; how pending rebuild changes are shown; the generators and `config/schema.toml` |
| System access | core | section 4.2 |
| Security | core for the rules, `hobnixd` for sign-in and sessions | sign-in, sessions, roles, API tokens (ADR 0012), two-factor and single sign-on (0.8), audit history, secrets and vault, the socket of the privilege split |
| Health and notifications | core for checks and delivery, daemon for scheduling | checks, problems, acknowledgements, channels, rules, quiet hours; moving `event-notify` is only a part |
| Package manager | core, daemon for extension services | repositories, signed index, install and update, permissions, extension host, package pages and page blocks; the SDK is only the author's side |
| Live connections | `hobnix-web` for the browser side, `hobnixd` for who may open one and what it runs | browser terminal, VM console, package terminals and consoles (#1123, #1124), job logs, file transfers: streams, not plain requests |
| Boot and recovery | bash and core | first setup, locked storage, daemon stopped, failed update |
| Remote, edge, displays | core for the reads and the pairing, `hobnixd` for the deck feed (**decided** 2026-11-27, ADR 0033 item 22); moved in P7 | peers, nodes, VPS, the deck API: the move must not break them. `deck-serve.py` stays a server of its own until `hobnix-web` can serve the deck API; the edge-node units stay unchanged until they move |

**Decided** (2026-11-27): systemd timers and the udev, ZED and UPS hooks stay. Each starts the core operation of its area, from the step in which that area
moves, and works while `hobnixd` is stopped; the daemon only watches for refreshes. The polling programs that move into the daemon (event notifications at
P3, the deck feed) lose their timers.

## 12. Rules for all parts

- **Internal messages:** how CLI, jobs, web service and daemon talk over local sockets: shape, permissions, version differences during an update.
- **API contract:** types, versions, OpenAPI and TypeScript generation; what an open browser tab does after an update.
- **Errors:** the stable error codes (ADR 0028) stay, with a next step in the CLI and the web.
- **Diagnostics:** logs that connect a request, its job and its events; daemon health; a support report without secrets.
- **Stored data:** section 6.1 and 5.6.
- **Testing:** fakes for the system access layer, VM tests for failures, checks on real hardware.
- **Resource limits:** targets for idle CPU, memory, database writes and parallel reads, set after the first measurements.
- **Build and release:** build time, download size and the binary cache (ADR 0003) on the pinned Nix version.

## 13. Not in this plan

- managing several servers as a cluster. Only avoid blocking it, for example do not assume a resource id is unique across machines (ADR 0013).
- Wasm
- a general automation or workflow builder
- a full terminal dashboard
- new product features added while old ones move

## 14. Measure first

On a real server, before any port, and again after P3, P4 and P6. Results go into this file. How to take and compare them:
[operations](operations.md#take-a-performance-baseline) (`hs perf baseline`; build time and closure size are not part of it). It counts started
processes only for the whole host, not for one service. Not tested on hardware yet.

- `hs-live`: CPU time, processes started per minute, memory, with and without an open page.
- Per read: wall and CPU time, split into dispatcher and script overhead against time in external tools.
- Time from a change to the open page (`hs live measure`, #486).
- Build time and closure size of `hobnix` on the pinned nixpkgs, also with the new dependencies. Measured on a development PC only (section 14.1); the run
  on a server is open.

For orientation, not a measurement: from the intervals in `scripts/lib/live-topics.tsv` (84 topics, every capability on, storage unlocked, no page open) the
schedule asks for about 155 reads a minute. One older server timing exists (2026-10-08, docs/Entwicklungsnotizen.md): the page-load reads took under 0.5 s
except two at 2.2 s and 1.8 s, which then ran their sources side by side.

Expected, to be checked: the largest gain is in the reads, which stop starting bash and Python. Time in external tools, parity syncs and backups change
little. Moving only the scheduler gains little while it still runs `hs sys`.

### 14.1 Build of `hobnix`, measured on a development PC

**Measured on a development PC** on 2026-11-26, not on a server (#1334). Not tested on hardware yet.

**Setup.** AMD Ryzen 9 7950X3D (16 cores, 32 threads), WSL2 on Windows 11 (Debian 13, 32 CPUs and 31 GiB visible), Nix 2.35.2 single-user, sandbox on,
`max-jobs = 1`. nixpkgs at the pin of that day, `774debe7a0d1b496e35677ad955a1011c6ff74f3` (rustc and cargo 1.95.0, SQLite 3.51.2). Source: `rust/` and
`pkgs/hobnix.nix` of the branch `feature/rust-quality` at `23bed8fd` (not merged into 0.14 at that time). Each time is one build of the whole derivation
(release build, then `cargo test` in the check phase, install, strip) with every input already in the store: no timed build fetched or built anything else.

**Variants.** Each had only the features the plan would use, `default-features = false`:

| Variant | Added |
|---|---|
| base | nothing |
| Tokio | `tokio` 1.54.1 (`rt-multi-thread`, `macros`, `net`, `io-util`, `process`, `signal`, `sync`, `time`), `tokio-util` 0.7.20 (cancellation token) |
| SQLite, system | `rusqlite` 0.43.0 (`cache`, `backup`), `libsqlite3-sys` 0.40.0; in Nix `pkg-config` and `sqlite` |
| SQLite, bundled | the same with `bundled` (compiles SQLite 3.54.1 from the crate) |
| axum | `axum` 0.8.9 (`http1`, `json`, `query`, `tokio`, `ws`), `tower-http` 0.7.1 (`fs`, for the frontend files), `futures-util` 0.3.34 (the SSE stream), and the Tokio it needs (`rt-multi-thread`, `macros`, `net`, `signal`, `sync`, `time`) |
| all | Tokio, SQLite (system or bundled) and axum |

axum cannot run without Tokio, so the rows do not add up.

**The libraries were really used.** The linker drops code that nothing calls, so each variant got a small throwaway skeleton in the `hobnix` binary, reached
from `main` through a hidden subcommand with input from the command line: a daemon (Unix socket, bounded line reads, an actor with channels, timers, signals,
a started program, shutdown), a database (WAL, busy timeout, migrations in `BEGIN IMMEDIATE`, cached statements, a backup) and a web server (JSON routes,
SSE, WebSocket upgrade, static files, graceful stop). The built binaries were run: socket request and reply, SQLite rows and backup, and over HTTP a read, a
change (and its refusal without a cookie), two SSE events, a static file and the `101` answer of the WebSocket (no message was sent over it). `nm -C` on
unstripped builds found symbols of each added library and none in the base build. The skeletons and the new dependencies are not in the repository.

**Time with 32 cargo jobs** (all CPUs). Three runs each, in seconds, `run 1 / run 2 / run 3`:

| Variant | Wall time | CPU time of the build |
|---|---|---|
| base | 13.6 / 15.6 / 13.2 | 66 / 79 / 67 |
| Tokio | 15.4 / 16.1 / 15.7 | 89 / 91 / 91 |
| SQLite, system | 12.9 / 13.0 / 13.2 | 71 / 70 / 72 |
| SQLite, bundled | 49.5 / 49.2 / 50.3 | 113 / 113 / 114 |
| axum | 20.4 / 21.1 / 20.3 | 137 / 142 / 137 |
| all, system SQLite | 21.6 / 21.3 / 21.0 | 153 / 148 / 147 |
| all, bundled SQLite | 55.5 / 52.3 / 52.8 | 204 / 191 / 193 |

**Time with 4 cargo jobs** (`--option cores 4`; the same CPU, not a slower one). Two runs each, in seconds:

| Variant | Wall time | CPU time of the build |
|---|---|---|
| base | 18.0 / 20.5 | 56 / 65 |
| Tokio | 23.6 / 26.3 | 77 / 87 |
| SQLite, system | 18.9 / 21.5 | 62 / 71 |
| SQLite, bundled | 55.2 / 57.6 | 103 / 109 |
| axum | 33.2 / 33.1 | 115 / 115 |
| all, system SQLite | 36.0 / 36.4 | 125 / 126 |
| all, bundled SQLite | 75.4 / 81.2 | 176 / 192 |

**How much the numbers vary.** Other work ran on this PC. With 32 jobs most variants stayed within about 1 s; the largest differences were base (2.4 s, 18 %) and
all with bundled SQLite (3.2 s, 6 %). With 4 jobs the two runs differ by up to 14 % (base) and 5.8 s (all, bundled). So a difference of 2 to 3 s between two
rows means nothing: system SQLite looks as fast as base in wall time, though it needed about 4 s more CPU time (median, 32 jobs). Before each build there
was no other `cargo`, `rustc` or Nix build process in WSL (not watched during the build), and the Windows CPU load was 0 to 32 %. The CPU time of the whole
WSL machine during a build was 3 to 50 % higher than that of the build.

**Size and crates.** The sizes are the stripped binary and `nix path-info -S` of the output. "Locked" counts new packages in `Cargo.lock`, including crates
for other platforms, which Nix still fetches. "Compiled" counts new crates in the `Compiling` lines of the build log (x86_64 Linux). Base has 40 packages
in `Cargo.lock`, 3 of them our own.

| Variant | Binary, MiB | Closure, MiB (store paths) | Crates locked | Crates compiled |
|---|---|---|---|---|
| base | 1.40 | 47.40 (7) | | |
| Tokio | 2.20 | 48.20 (7) | +14 | +12 |
| SQLite, system | 1.52 | 53.24 (9) | +9 | +9 |
| SQLite, bundled | 3.62 | 49.62 (7) | +12 | +12 |
| axum | 3.48 | 49.47 (7) | +63 | +56 |
| all, system SQLite | 3.92 | 55.64 (9) | +70 | +63 |
| all, bundled SQLite | 6.01 | 52.01 (7) | +73 | +66 |

- With the system library the closure gains the store paths `sqlite-3.51.2` (5.6 MiB) and `zlib-1.3.2` (0.13 MiB). A server may have both already; not
  checked. If it has, the download hardly grows.
- Bundled SQLite adds about 31 to 36 s of wall time with 32 jobs (medians), almost all in the build phase; the check phase stayed at 3 to 4 s. It is probably
  the C file of SQLite, compiled by one process (not timed alone), so it would depend on the speed of one core.
- `cargo deny check` (0.22.1, the version CI uses, with `rust/deny.toml` of that commit) said `advisories ok, bans ok, licenses ok, sources ok` for every
  variant, with no warning. It used the advisory database of that day.

**SQLite.** The owner chose the system library. The measurement used the pin, and the binary reported SQLite 3.51.2. According to
[sqlite.org](https://sqlite.org/wal.html#walresetbug), the WAL-reset corruption bug is likely present in 3.7.0 to 3.51.2 and fixed in 3.51.3, with backports
in 3.50.7 and 3.44.6. The package file of SQLite in the pinned nixpkgs applies no patch. So **the pin has to move before the database lands** (the new Rust
rules on `feature/rust-quality` require a fixed SQLite). The `nixos-26.05` revision `0dc498bf` names SQLite 3.53.3 in its package file; it was not built or
measured.

**Binary cache.** What was fetched and what is built was read from a dry run against an empty store, with only `cache.nixos.org` as the cache:

| Variant | Fetched from the cache | Derivations to build |
|---|---|---|
| base | 113 paths, 783.1 MiB download, 2.6 GiB unpacked | 18 |
| all, system SQLite | 199 paths, 800.1 MiB download, 2.6 GiB unpacked | 60 |
| all, bundled SQLite | 196 paths, 796.7 MiB download, 2.6 GiB unpacked | 62 |

- The toolchain (rustc, cargo, the C compiler, and `pkg-config` and `sqlite` for the system library) comes from the cache. A server already has some of
  these paths, so its download is likely smaller.
- Some crate archives and unpacked crates are in that cache too. For base all crate archives were; each "all" variant also downloads 8 from
  crates.io. The rest of the local derivations unpack crates, collect them (the vendor directory) and build `hobnix`.
- **No compiled crate comes from a cache.** `buildRustPackage` compiles all crates inside the one `hobnix` derivation, so every change under `rust/` that
  makes a server build `hobnix` compiles all dependencies again.
- The Hobnix cache of ADR 0003 (`config/binary-cache.nix`) was not asked. When it has the same store path, a server downloads `hobnix` and does not build
  it; that was not measured. The times above are the case without that hit.

**What limits these numbers.**

- A server is slower: slower cores, usually fewer of them, often slower disks. Neither table is a server time, and 4 jobs on this CPU do not imitate a small
  server.
- Not measured: a real server; peak memory of the build (it may matter on a small server); fetching with an empty store (only the sizes above); a whole
  `hs rebuild`; the web frontend (`pkgs/hs-web.nix`); aarch64; the newer nixpkgs revision.
- Not included: a D-Bus library (section 4.2), the CLI libraries (section 3), logging or tracing libraries, TLS (none was assumed: `web-serve.py` sets up
  none itself), multipart uploads. Each adds time and size.
- The skeletons are small. The real daemon and web server add their own code and call more of each library, so the binary and the build will be larger than
  here.

**How to repeat it.** Work in a directory outside the repository, with one copy of `rust/` and `pkgs/hobnix.nix` per variant.

1. Add the dependencies of the table to `[workspace.dependencies]` and to `hobnix-cli`, and write code that uses them as described above. For the system
   library add `nativeBuildInputs = [ pkg-config ]` and `buildInputs = [ sqlite ]` to that copy of `hobnix.nix`. Resolve the "all" variant first with
   `cargo metadata`, copy its `Cargo.lock` to the others and run `cargo metadata` there, so all variants use the same versions. The versions above were the
   ones resolved on that day.
2. Put this `default.nix` beside the copies, and give `nixpkgs` the store path of the pinned tarball
   (`builtins.fetchTarball` of `scripts/dev/nixpkgs-pin.sh get url`):

   ```nix
   { nixpkgs, variant, run ? "warm" }:
   let pkgs = import nixpkgs { config = { }; overlays = [ ]; }; in
   (pkgs.callPackage (./. + "/${variant}/pkgs/hobnix.nix") { }).overrideAttrs { measureRun = run; }
   ```

3. Build each variant once so that all inputs are in the store. A new `run` value gives a new store path, so the next build is a full build and nothing has to
   be deleted.
4. Time one build at a time: `nix-instantiate` with the new `run` value, then in Bash `time nix-store --realise "$drv" --option substitute false --option
   cores 0` (or `4`). `user` plus `sys` is the CPU time **only with single-user Nix**; with the Nix daemon the builder is not a child of the shell, so read
   the CPU time from the control group of the build.
5. Sizes: `nix path-info -s` and `-S` on the output. Crates: `Cargo.lock` and the `Compiling` lines. Licences and advisories: `cargo deny check` in each
   `rust/`. Cache: `nix-build --dry-run --store <empty directory>` with `nixpkgs` as `builtins.fetchTarball`. Use: run the code, and `nm -C` on a build with
   `dontStrip = true`.

On a server, the first number to get is today's build: in the repository (`/etc/nixos`), run `nix-build -E 'with import <nixpkgs> {}; callPackage
./pkgs/hobnix.nix {}' --no-out-link` under `time`. If the result is already in the store, add `--check` to build it again. With the Nix daemon `time` gives
only the wall time. Not tested on hardware yet.

### 14.2 Baseline of a real server, before any port

**Run on the maintainer's server** on 2026-11-27, installed release `v0.13.0-beta.2`, 8 cores. That release has no `hs perf baseline`, so the script ran
from a separate copy of `develop`, with `HS_BIN` set to the installed `hs.sh` so that the installed reads were timed. The server was not updated.
Both runs of the baseline were taken, 30 minutes each, and `hs live measure` between them. Which page was open is not recorded. Ctrl-C was not tried.

| What | No page open | One page open |
|---|---|---|
| Samples that saw an open page | 0 of 7 | 7 of 7 |
| Load at the start | 1.62 | 2.58 |
| Whole host, containers and VMs included: CPU, cores | 1.476 | 2.257 |
| Whole host: processes and threads started a minute | 19209 | 28342 |
| `hs-live`: CPU, cores (with everything the service starts) | 0.763 | 0.988 |
| `hs-live`: CPU, cores (the service's own process) | 0.008 | 0.006 |
| `hs-live`: memory of the service, MiB, average / largest | 192.2 / 233.5 | 200.6 / 238.6 |
| `hs-live`: memory of its own process, MiB, average | 44.3 | 44.6 |
| `hs-web`: CPU, cores (with everything the service starts) | 0.005 | 0.276 |
| `hs-web`: CPU, cores (the service's own process) | 0.005 | 0.034 |
| `hs-web`: memory of the service, MiB, average / largest | 269.3 / 270.3 | 241.4 / 310.8 |
| `hs-web`: memory of its own process, MiB, average | 101.3 | 99.4 |
| Collector: reads a minute | 35.0 | 48.9 |
| Collector: seconds of read time per second / largest stretch | 0.686 / 2.16 | 0.923 / 2.85 |
| CPU of the measuring itself, cores | 0.007 | 0.006 |

Neither service restarted. The two services together used 0.768 cores with no page open and 1.264 with one, about half of the host's CPU time in both
runs (52 % and 56 %). The host used 0.781 cores more with a page open; 0.496 of that is in the two services. Where the other 0.285 come from was not
measured. How many of the started processes are Hobnix's is not counted.

**Page reads:** 21 reads, 34.2 s of wall time and 35.9 s of CPU time in one run each. The split comes from a second run of each read, so its parts do not
add up to those sums exactly (33.7 s wall, 37.0 s CPU):

| Part | Wall, s | CPU, s | Share of CPU |
|---|---|---|---|
| command dispatcher | 5.1 | 6.9 | 19 % |
| external tools (777 calls) | 7.7 | 4.6 | 12 % |
| rest (the script, its shells, Python, `jq`, tools called by full path) | 20.9 | 25.6 | 69 % |

The slowest reads (wall / CPU, seconds): shares overview 10.5 / 11.1 (9.9 / 10.6 of it in the rest, 8 tool calls), system doctor 8.0 / 7.7 (276 tool
calls), status 1.9 / 4.0, container list 1.7 / 0.4, pool disks 1.4 / 1.5, job list 1.2 / 1.0. The one read with a non-zero exit is the doctor report,
which ends with 1 when one of its checks reports a problem. A call spends about 0.2 to 0.45 s of wall time and 0.29 to 0.43 s of CPU in the dispatcher.
Time outside the external tools is most of the CPU time; how much of it a port removes was not measured.

**Change to page**, `hs live measure`, 10 minutes: 60 probes, none lost, 59 with a stream open, the collector did not restart. The latency is 0 ms at
the median and 95th percentile and 9 ms at most. **0 does not mean no time:** the script counts from the end of the program that writes the probe and
turns a negative difference into 0, so here the web server mostly had the change before that program had exited. The write took 75 ms at the median
(126 ms at most) from start to exit. This number cannot show a gain below that. Database writes: 17.9 stored reads, 12.0 heartbeats and 29.7 change
counter steps a minute, 44.4 KiB of payload a minute, 1.2 ms for a commit on average, none over 100 ms; `state.db` did not grow (2620 KiB, write-ahead log
4079.8 KiB).

**Delays that count since the collector first recorded a topic**, not only during the run (median of the last values / worst): change to stored value
14.6 s / 879 s at the end of the first run and 10.0 s / 879 s at the end of the second, over 59 topics; stored value to page 9.3 s / 58 s over 19 topics,
the same in both. Only the Live state page records the second one.

One run of each: how much two equal runs differ is not known, so a small later difference says nothing. The release is a beta; a later release on the same
server also differs in other ways than a port.

## 15. Steps and milestone

Each step keeps the ADR 0001 method: characterization test first, old and new side by side for one release, a short way back. For 0.15 a beta that
has run on the owner's server is that release (ADR 0035). Reads move before destructive operations. **Check the behaviour on a real server before porting it:** a test that records today's output also records today's bugs.

| Step | Content | Done when | Milestone |
|---|---|---|---|
| P0 | Decision records; migration map; baseline of section 14 | records accepted, map complete, numbers in this file | Core and Jobs |
| P1 | Core foundations: allowed dependencies, operation model, system access layer, database with one schema owner, event writer, shared protocol types | a read and an event go through the core; Python and Rust write the database without lock errors in a test | Core and Jobs |
| P2 | Job system: section 5, and the history of section 6.2 with its typed fields, daily totals, moved event ids and backup | job tests pass on old and new; crash, reboot, update and rollback leave correct records | Core and Jobs |
| P3 | `hobnixd` skeleton and job monitor; move background programs one at a time: unit watcher, event notifications, live collector (still writing the table), extension host | each old unit is gone after its side-by-side release | Core and Jobs |
| P4 | End to end: app start and stop as a core operation with job, watcher and per-resource refresh, still served through `web-serve.py` and a `sys` row backed by Rust | seen on a real server, with a killed job, a stopped daemon, a disconnected watcher, and an update and rollback while a job runs | Core and Jobs |
| P5 | Rust CLI. May start after P2 | the same behaviour for unported commands; works with the daemon stopped | 0.15 (ADR 0035) |
| P6 | `hobnix-web` and its socket to the daemon (privilege split), sign-in, roles, SSE, live connections; route group by route group | no route left in `web-serve.py`; then the current values move to memory | 0.15 (ADR 0035) |
| P7 | Per area, together with P6: move reads and changes into the core, switch every caller, delete the `sys` rows; storage last | no caller of that area's rows is left | 0.15 (ADR 0035) |
| P8 | Remove the rest of `sys`, `web-serve.py`, the shell dispatcher if unused, and Python as far as section 10 allows | announced one release earlier | 0.15 (ADR 0035) |

### 15.1 Migration map (P0)

For every command, background service, timer, API route, stored file and package hook:

| Current behaviour | New owner | Step | Test | Old part removed when |
|---|---|---|---|---|

An entry without a new owner is missing from this plan, or is meant to be removed and says so. The inventory in PLAN-rust.md is a start; it covers Python
files and large shell scripts, not the rest of this list.

### 15.2 Milestone "Core and Jobs"

**Decided:** a milestone of its own, **0.15**, after 0.14 (Marketplace). Translations, Virtualization and Networking move up by one. Done on GitHub
on 2026-11-26.

**Changed on 2026-11-28 (ADR 0035):** 0.15 is the Rust release and holds P0 to P8, with the improvements of the Rust SDK. This replaces "P0 to P4,
the rest later". No new product features are built in it (section 13); how large it gets is accepted by the owner. The feature work has the new
milestone 0.16 "Game servers and autopilot"; Translations, Virtualization and Networking are now 0.17, 0.18 and 0.19.

**Marketplace comes first**, so its job work is built before this design. **Proposal** to avoid building twice:

| Issue | In 0.14 | Core and Jobs |
|---|---|---|
| #1126 extension actions as jobs | keep if Marketplace needs it: use today's `hs_job` and job record, add no new job features | moves to the new job system |
| #1219 recipe SDK and jobs | parts that need no new job system | jobify everything, cancel with safepoint, jobified changes, plans bound to apply |
| #1266 web server record (and build measurement) | | moves here; also covers the daemon and the privilege split |
| #1267 port `event-notify`, `live-collect`, `forecast` | | moves here, rewritten: they become parts of the core and the daemon, not standalone programs |
| #1268 remove `job-record.py` | stays if its condition holds (one release on servers with the Rust writer) | |
| #1262 to #1264 SDK | stay | the host side reuses the message types |
| #1123, #1124, #1125 package terminals, consoles, secrets | stay | listed in the migration map |

Before the milestone is filled: look through the open issues of 0.10 (Live Interface) and 0.1 (the job, event, live state and recovery epics). For each
related one: finish, move here, or replace. New issues needed at least for history and retention, the migration map and the baseline.

## 16. Decision records

| Record | Change |
|---|---|
| New: core and daemon | sections 1 to 4, 8; with #1266 or beside it |
| New: job system | section 5 |
| ADR 0001, 0006 | the end state replaces "the `hs sys` contract is the API"; the move method stays |
| ADR 0032 decision 6 | the Rust CLI starts early and calls the scripts, not the other way round |
| ADR 0004 | locks, cancel, storage and retention |
| ADR 0005 | log, kinds, replay and resync stay; add the rules of section 7; retention, limits and the database file change (section 6.2) |
| ADR 0018 | stays; add the lock rule |
| ADR 0026 | current values in daemon memory after P6 |
| ADR 0012 | roles on operations, not on `sys` rows |
| ADR 0025 | the Rust CLI is English only; bash scripts, packages and the web are separate questions |
| ADR 0011, 0031 | the host moves into the core; the protocol does not change |
| `docs/events.md`, package manifest `retention` | the event classes and the default for package events (section 6.2) |
| PLAN-rust.md | `hobnix-core` may use more than `std` and `serde`: Tokio, a SQLite library, a D-Bus library, each with a reason; step 5 follows section 15 |
| CLAUDE.md, `.claude/rules/` | the `ui.sh` and `sys` contract rules change as the steps land |

## 17. Open points

None of these is answered yet. Each names the issue that has to answer it (#1337, 2026-11-27). The gaps of the migration map are answered in
[PLAN-core-daemon-migration.md](PLAN-core-daemon-migration.md#missing-from-the-plan).

1. The details of history listed at the end of section 6.2: #1340.
2. The local sockets: the poke and the web protocol, their shape and permissions. A socket exists for the live push (`/run/hs/live.sock`). The poke and
   the daemon: #1341. The web protocol, with the privilege split: #1266.
3. The list of repair operations that run without a database (section 5.6): #1339.
4. Push for a failed quick job that nobody watches (section 5.5): #1339.
5. `hn` rename: does the Rust CLI start as `hn`, with `hs` as alias? Decide before P5: #1381.
6. German in the remaining bash scripts (`scripts/lib/i18n.sh`, part of the package contract). The web translations are not affected by the English-only
   CLI; #494 touches package texts. #1382.
7. Python for extensions (section 10): #1383.
8. How the daemon reaches Docker (section 4.2): #1341.
