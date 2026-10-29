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
- Finished plans without stdin are kept `HS_WEB_PLAN_TTL` seconds (default 5); every start and every read-cache clear empties the cache.
- Every plan and start writes `web timing: <verb> <shape> <ms> ms <how> rc= status=` (values as `*`).

Phase 0 is not done: the measurement is `journalctl -u hs-web | grep 'web timing'` on the server while using the pages; the table is still to fill. Unverified: that browsers close the connection on abort, that no plan starts a process outside its group, the frontend build.

Not built: the other pages (they keep their polls and have no topic), the homeserver-deck, retiring the old collector (`reads-collect.sh`, the `reads` table), the Health entries `live:down` and `live:stale:<topic>`.
