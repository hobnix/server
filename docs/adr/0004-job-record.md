# 0004: The job record

Status: Accepted (2026-11-10)
Issue: hobnix/server#131 (epic #128)

## Context

From the audit of #129 (docs/PLAN-jobs.md has the older one):

- `hs_job <slug> <desc> -- cmd` (`scripts/lib/job.sh`) starts a transient systemd unit `hs-job-<slug>-<HHMMSS>`. All state is read back from
  systemd and journald by `scripts/jobs.sh`. There is no record of the job itself.
- A reboot removes the unit; the journal may or may not keep its lines. Afterwards the state is `unknown`. Nothing notices a job that was
  running at power loss.
- The id has no date and is not unique across days. There is no queued, cancelled or interrupted state, no step or progress, no error text and no
  initiator. Times are `dd.mm. HH:MM` strings.
- The only real record is the file manager's `/var/lib/hs/fm/jobs/<id>.state` (files and bytes done and total, eta, phase, result).
- Execution (a transient unit) and the shapes `status started` / `unit`, `tail` (`state/exit/line/next`) and `show` are what the web interface,
  the tests and extensions use. The audit verdict: keep them, add a record.

## Decision

1. **One JSON file per job** in `/var/lib/hs/jobs/<id>.json` (owner root, mode 0644; written atomically: temporary file in the same directory,
   then rename). Chosen by the owner on 2026-11-04 over SQLite and Redis: plain for shell and Rust, survives a reboot, no new dependency.
2. **Id** is `YYYYMMDD-HHMMSS-<slug>-<4 random letters>`: unique across days and within a second. The unit name stays `hs-job-<slug>-<HHMMSS>`
   (the contract) and is stored in the record as `unit`.
3. **Fields** (all times ISO 8601 in UTC, an absent value is `null`):
   `id`, `slug`, `description`, `source` (`cli` | `web` | `timer` | `extension`), `initiator` (login name or null), `unit`, `queued`,
   `started`, `ended`, `state`, `exit`, `step` (`{n, of, text}`), `progress` (`{done, total, unit}`), `error` (`{category, message}`),
   `result` (object, per job kind), `cancel` (`{requested_by, at, safe}`), `version` (1).
4. **States:** `queued`, `running`, `ok`, `failed`, `cancelled`, `interrupted`. Only these; the old `never` and `unknown` stay in the old
   `jobs.sh` output and map to no record.
5. **One writer.** The `hs_job` wrapper writes the record: `running` before the command, the final state after. The job reports progress through
   helpers (`hs_job_step`, `hs_job_progress`) that go through the same writer. A cancel request is a separate file `<id>.cancel` that the
   writer folds into the record, so two processes never write the same file.
6. **Reconcile at boot** (`hs-job-reconcile.service`, before the web interface): a record that says `queued` or `running` whose unit is not
   active becomes `interrupted`, with `ended` taken from the last journal line or the boot time. Nothing is re-run by this step.
7. **No secrets in a record.** The command line is not stored, only the description the caller gave. Error text comes from the job's own
   messages, which the secret rules already keep clean.
8. **Retention:** the newest 200 records or 30 days, whichever keeps more; older ones are removed by the existing daily housekeeping.
9. **Contract:** nothing that `jobs.sh` prints today changes. The record is exposed by a new read row `sys jobs record <id>` and a list
   `sys jobs records` (new rows in `scripts/lib/registry.tsv`, `docs/api/sys.toml`), so the generated API grows and nothing breaks.
10. **Rust:** the record is a struct in `hobnix-core` (`job` module) with the same JSON; shell and Rust write the same format during the
    strangler phase (ADR 0001). Whether the runner itself moves is #137.

## Consequences

- Easier: recovery after a reboot (#133), safe cancellation with a recorded reason (#135), audit of who ran what (#167), one place for progress
  and step text, and the web interface can show a job after its unit is gone.
- Harder: the wrapper needs a JSON writer. Shell has no safe way to build JSON, so the helper calls `python3` (already required by the other
  scripts). Each job start costs one extra process.
- The file manager keeps its own state files until its jobs move to this record; a bridge reads them into `progress` meanwhile.
- The writer exists (`scripts/job-record.py`, used by `hs_job`, tests/job-record.sh). Follow-up work, not done by this record: cancel states (#135),
  the new read rows, the file manager bridge.
- The reconcile at boot exists (`job-record.py reconcile`, `scripts/job-reconcile.sh`, service `hs-job-reconcile`, tests/job-reconcile.sh): it marks and tells, it never re-runs a job.
- Cancellation exists (`job-record.py find-unit|cancel|cancelled`, `hs_job_cancelled`, `jobs-change.sh stop`): the record says `cancelled` before the unit is stopped, and a later `finish` keeps that state.
- The writer also exists in Rust (`hobnix job-record`, #137, ADR 0001 "Job store"); `hs_job_record` in scripts/lib/job.sh picks it, `scripts/job-record.py` stays as the fallback and the reference.

## Open points

- Whether a `queued` state is used at all before a real queue exists (nothing queues today); it is reserved so adding a queue changes no schema.
- Where `result` objects are documented: per job kind in `docs/api/sys.toml`, once the first kind uses it.
- Disk use: 200 small files; a job that reports progress many times a second must be rate-limited by the helper (proposal: at most once per second).
