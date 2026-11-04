# 0005: Events: domain events in one log, invalidations as counters

Status: Proposed
Issue: hobnix/server#143 (epic #139)

## Context

The audit (docs/PLAN-events.md, #141) found 24 event sources. Two kinds are mixed in them:

- **Domain events** are facts that stay true: "disk sdb removed", "job X failed", "backup finished". They are worth storing and listing.
- **Invalidation events** say "topic T may have changed, read it again". They carry no facts; losing one only delays a page.

What is true today:

- Facts are written to four stores in four formats: state.db `events` (disks, SMART; newest 2000), `/var/lib/hs/disk-events` (a second log
  of the udev part), the journal (`hs-notify`, job units) and the job records (ADR 0004). No shared id or time format (gap 17).
- Invalidations travel on Redis pub/sub only, and only when `liveState = "redis"`. The default is `off`: the browser has no event stream,
  `/api/events` answers 404 and pages catch up on their TTL (gap 1).
- `/api/events` has no `id:`; a reconnect cannot ask what it missed. The per-stream queue (256) drops silently (gaps 3, 12).
- Refreshes are sent only after success (`&&`, exit 0), so a failed backup or sync leaves pages stale (gap 6).
- Two refresh vocabularies (`AREA_GROUP` in web-serve.py, `topic:` flags in registry.tsv) are kept in step by hand (gap 13).

## Decision

Chosen by the owner on 2026-11-04 (questions 2, 4 and 1 of the plan, section 5).

1. **Two kinds, two mechanisms.** A domain event is a row in the event log (rule 2). An invalidation is a counter bump (rule 5) and is
   never kept as history. A source that is both writes both.
2. **One event log: the state.db `events` table**, widened. Columns: `id` (integer, autoincrement, never reused), `time` (epoch seconds UTC; readers format it),
   `source` (area, for example `storage`), `kind` (rule 3; stored as two columns, `source` and the rest of `<source>.<kind>`, so `storage.new` is source `storage`, kind `new`), `subject`, `level` (`info` | `warn` | `error`), `text` (one line, English
   key words only; the interface translates by `kind`), `payload` (JSON object or null), `v` (1). The old columns stay; old rows get
   `source` from their kind and a null payload. Retention: newest 5000 rows and nothing older than 90 days, whichever removes more,
   applied on write.
3. **Kinds are `<area>.<what>`**, lower case, registered in `scripts/lib/event-kinds.tsv` (core) with level, the payload keys and a one-line
   meaning. Extensions use the prefix `ext.<name>.`. A test fails when a script emits a kind that is not registered. The catalogue itself
   is #145.
4. **One writer.** `hs event emit <kind> <subject> [text] [--payload JSON]` (library function `event_emit` in `scripts/lib/event.sh` for
   scripts). Nothing else inserts rows. `state-db.py event()` calls it. `/var/lib/hs/disk-events` stops being written; its lines are
   imported once and the Disk events panel reads the log. Emitting never fails the caller (best effort, rc 0, one warning line).
5. **Invalidations are counters.** A small table `topics(topic, gen, time)` in the same database. `live_refresh` and the collector bump
   `gen` for a topic or a group. The web backend watches the database (one cheap read per second, no subprocess) and serves
   `/api/events` **in every `liveState` mode**. Redis pub/sub stays the fast path for the live topics when it is on; the counter is the
   fallback and the source of truth for "did it change".
6. **The stream replays domain events.** `/api/events` sends domain events as `event: domain` with `id: <log id>` and a JSON `data`.
   A reconnect with `Last-Event-ID` gets the rows after that id, up to 500; if the id is older than the oldest kept row or more than 500
   behind, the stream sends `event: resync` instead. `event: changed {topic, gen}` stays as it is (no id, no replay).
7. **Overflow is visible.** When a stream queue is full, the backend drops the queue and sends `event: resync`; the browser then re-reads
   every topic it follows. No silent drop.
8. **Failures refresh too.** The dispatcher (`hs.sh`), the `hs_job` wrapper and the timer units refresh their groups on any exit code, not
   only 0. A failed job also emits `job.failed`.
9. **Job transitions are events, the record stays state.** The job record (ADR 0004) is the model for current state with one writer and
   atomic files, not for events. Each transition writes the record and emits `job.<state>` with the job id as `subject`. The record is
   not copied into the log.
10. **Notifications are logged.** `notify.sh` emits `notify.sent`, `notify.held` or `notify.failed` with the channel as `subject`. The
    journal line stays. Push delivery stays best effort; there is no outbox in 0.1 (a failed send is a `notify.failed` row, so it can be
    listed). The quiet-hours queue (E20) is unchanged.
11. **One vocabulary for groups.** The refresh groups are defined once (`scripts/lib/live-topics.tsv` and the registry flags); the web
    reads them instead of `AREA_GROUP`. Until that lands, a test compares the two.

## Consequences

- Easier: the default install gets change events and a "what happened" list; the Bottom panel and the Health page can read one source;
  a reconnect no longer loses facts; one place to add retention, filters and later per-user visibility.
- Harder: state.db becomes a write path for many scripts (SQLite locking; emitting must be short and must not hold the lock across
  anything else); a migration of `events` and of `disk-events`; the web backend gets a watcher thread.
- Not solved: invalidations still cause a re-read of the whole topic, also when the content is identical (gap 4); see open points.
- Follow-up issues (to create when this record is accepted): the event catalogue and `event-kinds.tsv` (#145, existing); `hs event emit`,
  the table migration and retention; the counters table and the `/api/events` watcher in every mode; `Last-Event-ID` replay and
  `resync`; refresh on failure; job transition events; notification events; one group vocabulary with a test. Job lifecycle events
  depend on the job epic (#128).

## Open points

- **"Changed" should mean "different"** (question 6): comparing `out` before bumping `gen` in the collector. Not decided here; a separate
  small change with its own measurement.
- **Three push paths** (question 7): `vps/hs-watch.sh` -> ntfy and `hs-media-notify.py` -> Matrix bypass notify.sh, channels and quiet
  hours. Moving them onto `notify.sh` is wanted but changes the edge VPS and a container recipe; its own issue.
- **Daemon watchers** (question 9): `incus monitor`, Docker events, ZED. Each would be an event source after this record; out of scope for
  0.1 unless the reliability epic (#159) asks for one.
- **Per-user visibility** of events: the stream is admin only today; filtering by user needs a `visibility` column. Not needed yet.
- **Deck export**: `hs-deck-status` re-publishes events from state.db every 10 s; it keeps working on the widened table and should read
  `source` and `level` later.
- Not tested on hardware yet.
