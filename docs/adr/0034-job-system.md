# 0034: The job system: every change is a systemd job with a record in SQLite

Status: Accepted (2026-11-26) by the owner. The **Decided** items are rules. The acceptance names no Planned item or open point: none of them is confirmed by it.
Issue: none filed yet (milestone 0.15 "Core and Jobs", steps P0 and P2 of docs/PLAN-core-daemon.md); related #1126 (extension actions as jobs), #1219
(recipe SDK and jobs), #1268 (remove `job-record.py`). Related: ADR 0004, 0005, 0018, 0033 (core and daemon), docs/PLAN-core-daemon-migration.md.

This record writes down section 5 of docs/PLAN-core-daemon.md (locks, passwords, cancel, notifications, failure and upgrade rules) and the parts of
section 6.2 (history) that change ADR 0004 and ADR 0005. Nothing here is built, measured or run on a server. Not tested on hardware yet.

How to read the Decision: **Decided** is what the plan marks as agreed by the maintainer (2026-11-25). **Planned** is the recommended design; it becomes a
decision only when the owner accepts this record and says so. **Open** is not decided by this record.

## Context

What is true today, checked in the code of the branch `0.14` on 2026-11-26:

- **Running a job.** `hs_job <slug> <desc> -- cmd` (`scripts/lib/job.sh`) starts a transient systemd unit `hs-job-<slug>-<HHMMSS>`. 36 scripts call
  `hs_job` (counted with `grep -rl 'hs_job '` over `scripts/`, `*.sh`). A change script that never calls it runs in the caller and leaves no record
  (for example `scripts/token-change.sh` has no `hs_job` call).
- **The record.** One JSON file per job in `/var/lib/hs/jobs/<id>.json` (ADR 0004), written through `hs_job_record` (job.sh), which runs
  `hobnix job-record` and falls back to `scripts/job-record.py`. States `queued`, `running`, `waiting`, `ok`, `failed`, `cancelled`, `interrupted`,
  `skipped`. Retention: records beyond the newest 200 that are also older than 30 days are removed (`job-record.py` `KEEP_COUNT`, `KEEP_DAYS`); an
  active (`waiting`) record is never pruned.
- **A record can be missing.** When `hs_job_record new` fails, the job still runs without a record (`job.sh` line 132: `... 2>/dev/null) || jid=`).
- **Events.** Every transition emits `job.<state>` (`job.sh` lines 85 to 107) through `event_emit`, best effort (`|| true`). The topic
  `reads:jobs-records` is counted up after a write (job.sh line 39, `state-db.py topic-bump`).
- **Reconcile.** `hs-job-reconcile.service` runs `scripts/job-reconcile.sh` at boot, before `hs-web.service` (`configuration.nix`); a `running` or
  `waiting` record whose unit is gone becomes `interrupted`. Nothing is re-run.
- **Cancel.** `scripts/jobs-change.sh stop` marks the record `cancelled` first (`hs_job_record cancel`), then stops the unit, and takes the mark back
  (`uncancel`) when `systemctl stop` fails (lines 71 to 78). Whether a stop is risky is guessed from the unit name (lines 54 to 58:
  `hs-job-pool-*`, `hs-job-system-sync-*`, `hs-bulk-sync.service` ...).
- **Locks.** `scripts/lib/bulklock.sh` holds a `flock` on `/run/hs-bulk.lock` (parity sync, scrub, cache mover); 12 scripts source it. It is not the
  only lock: `flock` appears in 21 runtime files under `scripts/` (dev tools left out), with further lock files such as `/run/hs-backup.lock` and
  `$STATE/.backup.lock` (`backup.sh`), `.remote.lock` (`remote.sh`), `disk-event.lock`, `event-notify.lock`, `apps-autoupdate.lock` and the record
  locks of `job-record.py` and `token_store.py` (counted with `grep -rlE '\bflock\b'` and a grep for `*.lock`). Some jobs refuse when the same work
  already runs (`hs_job_skip`, state `skipped`).
- **Passwords for a job.** The web server passes a password on stdin to the `hs sys` command (ADR 0006 rule 6). The command then hands it to its job as a
  root-only temporary file under `/run/hs` (`job-pass.XXXXXX` in `scripts/manage-pool.sh` line 677, `scripts/pool-change.sh` line 140,
  `scripts/migrate-unraid.sh` lines 179 and 217). `LoadCredential=` is used for the keys of extension services (`scripts/lib/ext_service.py` line 703) and
  for the ACME token of the gateway (`scripts/gateway.sh` line 252), not for jobs.
- **Questions.** ADR 0018: state `waiting`, files in `/run/hs/ask/<id>/`, `hs sys jobs answer` on stdin, a 24 hour timeout (setting
  `recipeQuestionHours`), answered by the initiator or an admin.
- **Alerts.** Timer units carry `onFailure = hs-notify-failure@%N.service` (`configuration.nix` line 115), which runs `notify.sh` without any database.
- **History.** Events in `state.db` table `events`: the newest 5000 rows and nothing older than 90 days (`state-db.py` `KEEP_EVENTS`, `EVENT_DAYS`).
  Package events of a declared class `ephemeral` go after 7 days, `metric` after 35 (`trim_events`); monthly counts in `rollups`, never pruned.
  `state.db` refuses a newer schema (`SchemaTooNew`, `state-db.py` line 143).
- **Backup.** `scripts/backup.sh` `host_files` copies `/var/lib/hs` (job records and `state.db` included) as files with restic.

### Where the code disagrees with the plan

1. **Event classes.** Plan 6.2 says events of class `ephemeral` go after 7 days. In the code only package events have a class; core kinds in
   `scripts/lib/event-kinds.tsv` have none, so every core event follows the 5000 rows / 90 days rule.
2. **Passwords.** Plan 5.3 says "until the privilege split exists, the web server hands it over on stdin as today". That is the step from the web to the
   command. The step from the command to the job, a temporary file in `/run/hs`, is not named in the plan; it is what `LoadCredential` would replace.
3. **The plan text contradicts itself on history.** Section 6.2 says "The rest is **planned**:" and on the next line "The rest is **decided** too; the
   numbers are starting values". This record follows the second sentence for the retention table and marks it; the owner confirms at acceptance.
4. **ADR 0004 says `skipped` is written by the Python writer only.** `rust/hobnix-core/src/jobs/transitions.rs` handles it in `finish` (line 43: a skipped record
   stays skipped); whether the Rust writer covers `skip` fully was not checked by running a test. Not a disagreement with the plan, but with ADR 0004's
   text.
5. **Backup.** Plan 6.2 asks for SQLite's backup support and a tested restore. Today the database is copied as a file while writers may be active.
6. **Locks.** Plan 5.2 names one shared lock file (`/run/hs-bulk.lock`). The code has several (Context, "Locks"); which of them the core takes over, and
   in which fixed order, is not in the plan.

## Decision

### Decided (plan sections 3 and 6.2)

1. **Every user-requested change is a job, quick ones too.** Reads, plans and refreshes are not jobs (plan 3.5).
2. **systemd runs the jobs.** A job is never a task inside the daemon; it survives a daemon restart (plan 3.6, section 2).
3. **Job records move into SQLite, beside the events** (plan 3.14). This reverses ADR 0004 rule 1 (JSON files). Still to design: how bash paths that run
   without the binary report a job, the write load of progress updates, the rules for a damaged database (Planned 12 below), and how the existing
   records are moved.
4. **History is kept for years** in one file, `history.db`, with jobs, events and their daily totals, so one transaction saves them together (plan
   3.16, 6.2). It cannot be rebuilt, so it is backed up with SQLite's backup support and the restore is tested. The move keeps the event ids (replay and
   extension cursors use them; an id is never reused).
5. **Retention** (plan 6.2, starting values, adjusted after measuring; see disagreement 3):

   | Data | Default |
   |---|---|
   | Job summary (operation, target, who, when, result, duration, error code) | no age limit |
   | Job details (plan, steps, saved output) | 1 year; no age limit for failed, interrupted and destructive jobs |
   | Events of class `important` | no age limit |
   | Events of class `normal` | 1 year |
   | Events of class `ephemeral` | 7 days |
   | Events of class `metric` | 35 days |
   | Daily totals | permanent |

   The limit of 5000 events goes. A storage limit (start 2 GB) with an early warning removes short-lived and raw data first, then older job details
   and older normal events; it never removes daily totals or unfinished jobs. Housekeeping runs once a day. Two settings only: how long detailed
   history is kept, and the storage limit. A failed or interrupted job saves the end of its output: the last 200 lines, at most 64 KiB, without colour
   codes and progress redraws, with a mark when cut.
6. **Event classes.** Each core kind names its class (`important`, `normal`, `ephemeral`, `metric`) in `scripts/lib/event-kinds.tsv` or what replaces
   it; the classes are those of plan 6.2. A package names the retention of each event in `package.toml`; the default is `normal`, the old value
   `audit` means `normal`. This changes the package contract and needs the usual deprecation.
7. **Removing a person** replaces the person with one neutral "removed user" mark in jobs, events and the per-user totals; marked payload keys, free
   text and saved output of that person's rows are cleared. It is its own action with a typed confirmation; backups keep the old data until they
   expire, and the action says so.
8. **Audit events stay for now** (`audit.ok`, `audit.failed`) and count as security events; reviewed after P7.

### Planned (plan section 5; to be confirmed at acceptance)

9. **Path of a change (5.1).** The front end passes the request to the core (to the daemon from P6 on; until then `web-serve.py` calls a `sys` row).
   The core writes the record and asks systemd for the unit; the caller gets the job id at once. The job saves its state and events first, then
   pokes the daemon over a local socket; a periodic look at the database catches a lost poke. Job state and app state are separate; nothing depends on
   the order of the job's report and a watcher's report. The job monitor follows the unit state in systemd, corrects the record of a job that died
   without a word, and after a daemon restart reloads the records, compares them with systemd and watches again. The job code does for every operation:
   record and `job.*` events, refresh signals after success, failure and cancel (ADR 0005 rule 8), reconcile after a crash or reboot. Scheduled work
   that changes something (backup, sync, scrub) is a job; routine health reads are not.
10. **Locks (5.2).** Each operation declares what it reads and what it needs to itself; a lock on a pool covers its disks. The job process holds kernel
    file locks (`flock`), so a crash frees them. While both exist, Rust and bash use the same lock files (`/run/hs-bulk.lock`). All locks are taken at
    once or in one fixed order. A conflict is refused and names the job in the way; a scheduled job may wait or end as `skipped`. No general queue yet.
    An update or a reboot does not run beside a job that cannot safely be interrupted.
11. **Passwords (5.3).** systemd credentials: the core writes a root-only temporary file in memory, systemd gives the unit its copy (`LoadCredential`),
    the core removes the original. Never in a record, a log, argv or the environment; answers to questions take the same care (ADR 0018 rules 7, 10).
    A password lost in a reboot makes the job interrupted and it is asked again.
12. **Cancel (5.4).** Each operation, or phase of one, is cancellable now, at the next safe point, or not at all, as the operation declares (not guessed
    from the unit name). A cancel is a request: the record says `cancelled` only after the job stopped. No promise of automatic rollback: revert only
    where it is built and tested.
13. **Notifications and questions (5.5).** A quick job a person started: result in the page or the CLI, no push. A long job that succeeds: push when the
    operation turns it on. A scheduled or destructive job that fails: push. A job that needs input: shown and pushed. Questions keep ADR 0018. **A job
    does not wait for input while it holds a storage lock;** ask as much as possible in the plan.
14. **Failure and upgrade (5.6).**
    - At least the previous release works with the new database format and the new socket messages; an update and a rollback are tested while a job of
      the old version runs.
    - Database failure (full, damaged, locked): normal changes are refused; a short, named list of repair operations runs anyway and logs to the
      journal.
    - Alerts do not need the daemon: `hs-notify-failure@` stays independent, and the daemon itself is watched.
    - A request carries a request id; a double click or a retry gets the same job.
    - An interrupted job says how to inspect and recover; a destructive step is never repeated automatically.
    - Each operation has a time limit or a progress rule; a long quiet time alone never kills storage work.
15. **History details (6.2).** Repeats of the same important event are combined into one row with a count and the first and last time. Each package has
    a limit of `important` rows (start 10,000), above which its oldest follow the `normal` rules, with a warning. The class is stored on the row when it
    is written, so removing or updating a package does not change old rows. Install and update show which events a package keeps with no age limit; an
    admin can lower a class. Statistics have typed fields (operation, target, person, source, parent job, times, result, error code), stable target ids
    (a disk's serial, not `/dev/sdb`), and daily totals updated in the same transaction as the job result.

## What changes in older records on acceptance

The text of these records is not edited. Each has a Status note that points here. A change that rests on a Planned item waits until that item is confirmed.

| Record | Change on acceptance |
|---|---|
| 0004 The job record | Rule 1 (one JSON file per job) is replaced by rows in `history.db` (Decided 3). Rule 3 (fields) grows typed statistics fields (Planned 15); the JSON shape of `sys jobs record` stays while the row exists. Rule 5 (one writer, cancel as a separate file) becomes the core as the writer and cancel as a request (Planned 12). Rule 6 (reconcile at boot) stays and is joined by the job monitor (Planned 9). Rule 8 (200 records or 30 days) is replaced by Decided 5. Rule 10 (Rust and shell write the same format) ends when the bash fallback is gone. The Consequences line "the record says cancelled before the unit is stopped" is reversed by Planned 12. |
| 0005 Events | Rules 1, 3, 5, 6, 7 and 11 stay (two kinds, kinds registered, counters, replay, resync, one vocabulary). Rule 2 changes: the log moves to `history.db`, ids kept, and the retention "newest 5000 and 90 days" is replaced by the classes of Decided 5 and 6. Rule 4 (one writer, `hs event emit`) becomes the core as the writer. Rule 8 (failures refresh too) and rule 9 (job transitions are events, the record is state) stay and apply to every operation. The rules of plan section 7 (command, event, refresh signal, state) are added; ADR 0033 holds them. |
| 0018 Interactive recipe runs | Stays. Added: a job does not wait for input while it holds a storage lock (Planned 13). The answer is a core operation with the same role rule (initiator or admin). Rule 12e (retention counts orchestrations) is replaced by the retention of Decided 5. |
| 0001 Rust behind the `hs sys` contract | Section "Job store (#137)": the side-by-side of `job-record.py` and `hobnix job-record` ends with #1268; the writer then becomes the core's job module over SQLite. |
| 0012 Roles and API tokens | The role of `sys jobs stop` and `sys jobs answer` moves to the cancel and answer operations (ADR 0033 P-a). |
| 0026, 0032 | No change from this record (see ADR 0033). |

## Consequences

- Easier: one model for every change (record, events, cancel, recovery); filtering and counting jobs in SQL; history that survives years; a lock and a
  cancel rule declared once per operation instead of guessed.
- Harder: one systemd unit per quick change (cost to measure, plan 5.6); jobs depend on a database, so the failure and rollback rules must hold before
  the move; the bash paths that run without the binary need a way to report a job; the event and package contracts change (classes, `retention`).
- Follow-up issues: history and retention (plan 6.2 says none exists in `hobnix/core` or `hobnix/official` as of 2026-11-25), the move of job records,
  core event classes in `event-kinds.tsv`, the package `retention` deprecation, the SQLite backup and restore test, credentials for jobs.

## Open points

1. The default push for a failed quick job that nobody watches (plan 5.5, 17.4).
2. The list of repair operations that run without a database (plan 5.6, 17.3).
3. How bash paths that run without the binary report a job; the write load of progress updates; how existing records are moved (plan 6.2).
4. Credentials, to check: that the unit keeps its copy after the original is removed, cleanup when the start fails, whether swap can put the file on
   disk (plan 5.3).
5. That a job unit survives `nixos-rebuild switch` with the new start method; the cost of one unit per quick action (plan 5.6).
6. The plan's contradiction on whether the history rules are decided or planned (disagreement 3).
7. The list of lock files the core owns and their fixed order (disagreement 6).
8. Not tested on hardware yet.
