# Plan: hot state for the web interface (draft, 2026-10-29)

Status: design only, nothing built. Open questions at the end are for the owner.

## Problem

1. The web backend (`scripts/web-serve.py`) answers every page read by starting an `hs sys ...` process, with a short in-memory cache. Cold
   pages, and every browser tab after the cache expires, wait for a subprocess.
2. A create or change dialog asks for a plan 300 ms after the last edit; the plan is a subprocess too, so the dialog sits on "fill in the form"
   until it finishes.
3. After a change finishes, the pages show old data until a reload. Only changes made through the web clear the read cache; a change made with
   `hs` in a terminal, or by a timer, does not.
4. Every page is its own reader. A reader that fails is a page that fails, and the same data is fetched in several shapes.

## Decision in one paragraph

One writer, one hot store, one reader. A collector service on the host runs the `reads` commands and publishes the result to Redis. A command
that changes something ends with a one-line refresh call. The web backend never runs a read itself: it reads Redis and forwards change
notifications to the browser (server-sent events). Redis holds only data that can be rebuilt, so it is never a second source of truth: persistent
facts (SMART baselines, config, job history) stay where they are today (files, the database), and the collector re-reads them after a restart.

## Design

**Store.** `services.redis.servers.hobnix` as a capability `state`: unix socket only (no TCP port, nothing to expose), socket group `hs-state`
(web and collector are members), no persistence (`save ""`), small `maxmemory` with `allkeys-lru`. Losing it costs one refresh round, nothing else.

**Keys.** `hs:v1:<topic>` holds `{"ts": <unix s>, "gen": <int>, "data": <the machine-readable document of the read command>}`.
Pub/sub channel `hs:v1:changed` carries the topic name. `data` is exactly what `hs sys ...` prints today (tab-separated shape unchanged, see
the contract in CLAUDE.md); the collector stores it as text plus the parsed form the web already builds, not a new format.

**Collector (`hs-state`).** A systemd service. Per topic: an interval (fast for status and jobs, slow for disks and shares), plus on-demand
refresh. `hs state refresh <topic>...` (a new `sys` row) is what change scripts call as their last line, what timers call after the daily SMART
check, and what the web calls when it finds a key missing. One refresh per topic at a time; a refresh that fails keeps the old value and
sets `err` and `ts_err` on the key so the web can show "stale since" without hiding data.

**Web backend.** `GET /api/<page>` = `GET hs:v1:<topic>`, no subprocess. `GET /api/events` = SSE fed by `SUBSCRIBE hs:v1:changed`; the browser
invalidates the page that uses that topic. Polling intervals in the Svelte pages go away. Sessions and permissions stay in the web layer:
the stored documents are admin-level and the backend filters per user, as it does today.

**Modes (capability option `stateMode`).** `redis` (default on a `homeserver`) and `off` (current behaviour: direct reads with the short cache),
for `edge` and `minimal` roles and for a machine where Redis is down on purpose. Two modes behind one `StateStore` interface in the web
backend (`get`, `subscribe`); there is no memory-cache mode, so there are not three paths to maintain. If Redis is unreachable at runtime the
backend does not silently fall back: it answers 503 "state service down" and the Health page says why.

**Plans.** Redis does not speed up plans (the answer depends on the form). Separate work, no Redis needed:
- open the dialog at once with a skeleton and the form enabled; the plan arrives into it;
- cancel the in-flight plan process when the form changes again, and cache the finished plan for a few seconds by (area, args);
- first measure where a plan spends its time (bash start, `incus`, `zfs list`, `smartctl`); a plan that does the same read as the collector
  can read the topic from Redis instead of repeating it.

**Deck and the status document.** On the same host the status API (`sys deck`, the one-read status document) can serve the `status` topic from
Redis instead of running the command, so the web Summary and the deck show one value. Between nodes nothing changes: Redis is never reachable
over Tailscale; a node pulls a peer through the narrow forced-command allowlist (`hs node`, TODO section D). Whether the web-side "status
page" can go depends on what it serves beyond the deck document (question 3).

## What this does not change

- Machine-readable lines of `hs sys ...` keep their shape; the collector is a consumer of them.
- Admin pages stay without a public route; the web reads no secret through this path (secrets only through `scripts/lib/secret.sh`).
- Writes (`CHANGES` in web-serve.py, plan/start) still go through the closed list of commands; Redis is never written by the browser.

## Performance

The documents are small (tens of KiB for all topics together), so a Redis `GET` over a unix socket is well under a millisecond; it cannot be
the bottleneck on this hardware. The real costs are different: one more service to keep running and monitor, staleness when the collector
dies (hence `ts` on every key and a Health entry when a topic is older than three intervals), and the collector's own load (reads run on a
schedule even with no browser open; disks and ZFS reads are the expensive ones, so their intervals are long and event-driven).

## Phases

0. Measure: timings of the plan commands and of the ten slowest reads on the server. Output: a table in this file.
1. Plan dialog: skeleton first, cancel, short plan cache. Independent of everything below; ships alone.
2. `StateStore` interface, `off` mode (today's behaviour moved behind it), tests with a fake store.
3. Capability `state` (Redis on a socket), collector, `hs state refresh`, Summary page and the `status` topic moved over.
4. SSE to the browser; remove page polling.
5. Move the remaining pages, one area per change (storage, instances, shares, services); each change script ends with the refresh call.
6. Status API reads the `status` topic on the same host.

Tests: a fake store for the web backend; `tests/` for the collector with a stub `hs`; a root/VM test for the real socket and group
permissions. Not run on hardware until phase 3 is on the server.

## Open questions

1. Decided 2026-10-29: Redis is rebuildable only (no persistence); a reboot shows "refreshing" for a few seconds.
2. Per-user views: admin-level document plus web-side filtering (kept as designed unless the build finds a page that needs per-user keys).
3. Decided 2026-10-29: the "status page" (server resources) stays; the homeserver-deck on the owner's PC was a test and is reworked in its own
   repository after the Redis mode exists. Phase 6 is therefore later and not part of the first build (phases 2 to 5, the Summary page first).
4. Disks: the daily SMART result and its baseline are persistent data, so they live in the database or a state file, not in Redis. Redis
   only carries the latest summary. Agreed? (Details belong to the disk plan, written in its own session.)

## What was built (2026-10-29)

Phases 2 to 4 for the Summary page, none of it run on hardware yet:

- `StateStore` with the modes `off` (as before) and `redis`; the capability `live-state` (option `liveState`, default `off`).
- `/api/sys/status` reads the `status` topic from Redis in mode redis and starts no process; `503 state service down` when Redis is away.
- `/api/events` (server-sent events): `changed` per topic, `down` and `up` when the server's Redis subscription is lost or back.
- Browser: `web/src/live.svelte.js` opens the stream when `features.live` is on; `poll(path, ms, topic)` has no timer while the stream is open and reads again when the topic changes. While the stream is down (or `liveState` is off) it polls as before and the Summary shows a quiet "Live updates paused" line.

Phase 1, plan dialog, not run on hardware:

- A create dialog shows its form and a skeleton at once and asks for the plan without the 300 ms wait on open; Start works only for the plan of the current form.
- A newer question aborts the older request in the browser; the backend kills that plan's process group when the client goes away (plans only, never a start).
- Finished plans without stdin are kept `HS_WEB_PLAN_TTL` seconds (default 60); every start and every read-cache clear empties the cache.
- Every plan and start writes `web timing: <verb> <shape> <ms> ms <how> rc= status=` (values as `*`).

Phase 0 is not done: the measurement is `journalctl -u hs-web | grep 'web timing'` on the server while using the pages; the table is still to fill. Unverified: that browsers close the connection on abort, that no plan starts a process outside its group, the frontend build.

Built:
- Diagnostics is served by the `live` topic in Redis mode and keeps the old collected-reads view in off mode.
- `live:down`, `live:stale:<topic>` and `live:never:<topic>` are surfaced by Health automatically (`scripts/health-check.sh` calls `live.sh check`).

Storage slice (built, not run on hardware): 20 more topics (disks, pools, shares, encryption, vault, history, file locations, temp disks),
see capabilities/live-state/NOTES.md. A `READS` entry may carry a topic mapping `{bulk, fast}`; `Reads.resolve` picks the concrete topic from
the validated `pool` query per request (no match: no topic, so the read stays direct, also in Redis mode) and the warm-up skips only resolved
string topics. `poll` accepts a topic function; shell scripts call `live_refresh` after successful quick changes; unlock refreshes all topics.

Not built: the instances and services pages (they keep their polls and have no topic), the homeserver-deck, retiring the old collector (`reads-collect.sh`, the `reads` table).
Retirement stays future work until no served read uses `Reads.collected`.

## Reads table: reshape now, retire later (2026-11-08, #324)

**Decision: keep the table for now and bring it to the live entry shape; retire it when `liveState = "redis"` is the default for homeservers.**
Why: `liveState` is `off` by default (config/schema.toml) and the Redis default is neither decided nor proven on hardware, so every server that has
not turned it on still serves its 31 slow reads from state.db `reads` (ADR 0002: the table is runtime state, rebuildable, the collector fills it again).
Dropping it now would make those servers run every read per request again. Reshaping is small and gives the Data page one status for both modes.
The ADRs (0002 system state vs runtime state, 0005 events) say only that runtime state may be rebuilt and that "changed" must mean "different"; neither
asks for the table to go before Redis is the default. So: option A now, option B (migration that drops `reads`, removes `reads-collect.sh` and the
off-mode half of the Data page) in the change that flips the default.

Built: columns `gen` (counts up when the output changed), `err`, `ts_err` and `ttl` (nullable; a migration in `state-db.py migrate_reads`, run when the
database is opened for writing; old rows keep their values, an unmigrated database is still listed). `updated` is the good-data time (`ts`). A run with no
output keeps the old output and `updated` and records `err`/`ts_err`/`rc` (`state-db.py read-fail`, called by `reads-collect.sh`); a run with output (also
with a non-zero exit) still replaces the output, as before. `live_state.status_of` works on a row (`ts` = `updated`, interval = the line of
`collected-reads.tsv`): fresh, stale (failed, old data inside the ttl), error (failed or never read well) or expired (collector not running).
`state-db.py reads` and `hs sys reads status` get four more fields at the end (status, gen, err, error age; the first six are unchanged), the Data page
shows the status column in both modes. Not tested on hardware yet.

## Refresh base (2026-11-01)

Built, not run on hardware: topic columns `cap` and `groups`, group refresh (`@<group>`, `any`), bounded parallel reads (`HS_LIVE_PARALLEL`),
a refresh hook in the dispatcher for `changes` rows and at job start, the old collector skipping topic reads in Redis mode, and the topic map in the
session answer. Details: capabilities/live-state/NOTES.md. More topics follow in later slices.
Audit of every event source and consumer: docs/PLAN-events.md.

## System slice (2026-11-01)

Built, not run on hardware: 17 topics for the dashboard and system shell (deck, jobs, health, hardware, ups, updates, config, setup, parts, nodes, ssh keys,
expiry, notification channels and providers), explicit refreshes in health-check, ups, power-notice, jobs stop and the update fetch.
Details: capabilities/live-state/NOTES.md.

## Instances slice (2026-11-01)

8 topics (`ct-list`, `ct-profiles`, `services-list|app|routes|local-routes|tiles|stats`), see capabilities/live-state/NOTES.md. `ct list` is read
every 10 s (the pages polled 5 s) and refreshed by `@instances`/`@network` after a change. Not tested on hardware yet.

## Last good data (2026-11-04)

A failed read (non-zero exit without output, timeout, `hs sys` not startable) keeps the previous document: `out` and `ts` (the time of the last good
read) stay, `err`/`ts_err` are set and `state` is `stale` (there was a good read) or `error` (never). A good read sets `state` `ok` and clears the
error. The web answers with the old data and, additive, `X-HS-Stale` (time of the failure), `X-HS-State` and `X-HS-Last-Ok` (epoch seconds or `-`).
Events `live.collector-failed` (once per change into error) and `live.collector-recovered` (docs/adr/0005-events.md). `hs sys live status`/`check`
keep their shape. Not tested on hardware yet.

## Entry status, source and ttl (2026-11-07, #322)

A document gains `src` (the words of the read, e.g. `services list`) and `ttl` (seconds it counts as fresh): the topic's own override (`lib/live-topics.tsv`
column 8, `-` or empty = none) else 3 x interval. Documents from before still read: without `ttl` the status uses 3 x interval. One function,
`live_state.status_of(doc, interval, now)`, returns the status; `hs sys live status`/`check`/`inspect` and the web use it, the other thresholds are gone:

| status | meaning |
|---|---|
| `fresh` | good data inside its ttl, last try did not fail |
| `stale` | the last try failed, the last good data is still inside the ttl |
| `error` | the last try failed and there is no good data inside the ttl (never read, or older) |
| `expired` | no failed try, but the data is older than the ttl (the collector does not run) |

No Redis `EXPIRE`: an expired or failing entry is still served with its last good data, only marked. `hs sys live status` has the status as new last
field 9 (`-` = no document); `live inspect` gets `status`, `ttl`, `source`; the web answers `X-HS-Status` next to `X-HS-Age` (`X-HS-Stale`/`X-HS-State`
stay). `hs sys live check` reports `expired` and `error` as `live:stale:<topic>`. An identical read still moves only `ts` (an older document gets `src`
and `ttl` then). Not tested on hardware yet.

Web (#323): `web/src/api.js` keeps `X-HS-Status` per read (`stateOf(path)`, next to `ageOf`); for a failing read the server also sends `X-HS-Topic` and
`X-HS-Error` (one printable ASCII line). `shell/Fresh.svelte` shows the worst status of the page's reads (`web/src/freshstate.js`): `error` and `expired`
in words with the time of the last good read, `stale` in the warning colour; the tooltip names topic and error line. The page keeps its last data.
Web build and type check not run (no node on the dev machine). Not tested on hardware yet.

## Dependencies (2026-11-06, #153)

`lib/live-topics.tsv` column 7 `needs` lists the topics whose new `gen` re-reads this topic (`-` = none); today `services-list` and `services-app` need
`ct-list`, and `services-routes`, `services-local-routes` and `services-tiles` need `services-list`. One wave thread takes all queued changed topics at once
(a burst is one wave) and walks the topological order of the graph (`live_state.graph`) once: each dependent is read at most once, after everything it needs.
Only a new `gen` starts or spreads a wave: a failed read keeps the old document (see Last good data) and its dependents are not read; an identical read
spreads nothing. A wave never reads a topic sooner than `HS_LIVE_MIN_GAP` seconds (default 5) after its last read, it waits. That is also the cost bound for a
topic whose output changes on every read (for example `ct list` with usage columns): its dependents are then read about every gap, not faster; drop the edge
if that is too costly (`journalctl -u hs-live | grep wave`). Wave reads are sequential, so a slow dependent delays the rest of its wave. A cycle, a self
reference or an unknown target is cut and logged once; `tests/live-state-test.py` fails on any of them in the core table. An extension read may `needs` core
topics only; with an unknown name its live topic is off (the read stays direct) and the journal says so. `hs sys live status` has `needs` as new last
field 8 (comma list or `-`). Off mode has no propagation. Not tested on hardware yet.

Inspector page (Monitoring > Live state): `hs sys live inspect` (one JSON document, named keys), `hs sys live raw <topic>` (stored output, capped at 64 KiB) and `POST /api/live/refresh {topic}` (the same `hs:v1:refresh` message as `?fresh=1`). Not tested on hardware yet.

## Apps slice (2026-11-01)

3 topics (`pkg-market`, `pkg-repos`, `recipes-list`), see capabilities/live-state/NOTES.md. `pkg.sh` refreshes them (and `parts-list`) after a
successful fetch, install, update, remove or repository change. Not tested on hardware yet.

## Identity and backup slice (2026-11-01)

6 topics (`users-list`, `users-groups`, `dc-state`, `backup-state`, `backup-overview`, `backup-shares`), see capabilities/live-state/NOTES.md. Users
topics need capability `ad` (the script fails without a controller). `cache state` stays direct: the READS entry passes no share. Not tested on hardware yet.

## Network slice (2026-11-01)

8 topics (`gateway-*`, `dns-list`, `unifi-*`, `ports-list`, `remote-list`), see capabilities/live-state/NOTES.md. Not tested on hardware yet.

## Extension slice (2026-11-01)

A `[[web.reads]]` entry of an extension package without `args` may set `live = <seconds>` (and `locked = "run"|"skip"`) and gets the topic
`ext-<name>-<words>` in the group `ext-<name>`; the collector rescans the packages every 60 s. Format and rules: docs/PLAN-extensions.md, code
scripts/hs_ext.py. No existing read opts in. Not tested on hardware yet.
