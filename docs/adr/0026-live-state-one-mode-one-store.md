# 0026: Live state is always on, one mode, one store (the state database, not Redis)

Status: Accepted (2026-11-13), option A. The measurement in migration step 1 is still to do; all code for #481 stays behind a switch that is off until it is measured.
Issue: hobnix/server#481 (part of #480)

The owner decided: live state is on by default, with one mode and one store, and accepted the state database as that store (2026-11-13).
Nothing is built and nothing here was run on a server; the numbers below were counted in the code on `origin/0.3` (2026-11-13). The code for
#481 merges behind a switch that stays off until the measurement in migration step 1 is done.

## Context

**Two modes.** The option `liveState` (`config/schema.toml`, capability `live-state`) is `"off"` or `"redis"`, default `"off"`. The capability is
on only when `webUi`, a homeserver and `liveState = "redis"` (`configuration.nix`, `liveOn`); the web server sees it as `HS_WEB_LIVE`
(`scripts/web-serve.py`). Redis mode and off mode are two read paths behind one `StateStore` interface.

**Two stores.**

| Store | Holds | Written by | Read by |
| --- | --- | --- | --- |
| Redis `hobnix` (`capabilities/live-state/module.nix`): unix socket, `port = 0`, no persistence, 32 MB `allkeys-lru` | `hs:v1:<topic>` documents (the raw output of one `hs sys` read) for the 67 topics of `scripts/lib/live-topics.tsv`, plus the channel `hs:v1:changed` | the collector service `hs-live` (`scripts/live-collect.py`, 591 lines) and a small RESP2 client (`scripts/live_state.py`, no redis-py) | `web-serve.py` (a topic read is a GET, no process) and its pub/sub subscription (the `Events` hub) |
| state database `/var/lib/hs/state.db` (SQLite, WAL): table `reads` (`key, payload, updated, ms, rc, gen, err, ts_err, ttl`) | the 27 slow reads of `scripts/lib/collected-reads.tsv` | `scripts/reads-collect.sh` (timer `hs-reads-collect`, every 15 s, only with `webUi`) | `Reads.collected` in `web-serve.py`, while the row is at most 3 minutes old |

The same database already has the table `topics(topic, gen, time)` (ADR 0005 rule 5, change counters). `live_refresh` and `state-db.py read-put`
count a topic up, and `Events._watch` reads the table once a second (no subprocess) and feeds `changed` to every open `/api/events` stream.
That endpoint is served in every mode: with Redis up the pub/sub subscription delivers the live topics and the counters are the fallback.

**What a fresh install does today.** `liveState` is `off`: no Redis, no `hs-live`. The 27 slow reads come from `reads`, every other read runs
as a process per request behind the stale-while-revalidate cache and the warm-up thread. The browser follows the stream only when
`features.live` is true; otherwise `poll(path, ms, topic)` (`web/src/data.svelte.js`) sets a timer. So the default polls, and a change made in
a terminal reaches an open page after the next poll or never (the cache may serve it first).

**What is already decided in writing.** `docs/PLAN-web-cache.md` ("Reads table: reshape now, retire later", #324): the table goes "when
`liveState = "redis"` is the default", together with `reads-collect.sh` and the off-mode half of the Data page. ADR 0002 (the table is runtime
state, rebuildable) and ADR 0005 (a counter means "different") do not ask for the table to stay.

**What the code says about a single server.** The documents are the output of `hs sys` reads: tens of KiB for all topics together
(PLAN-web-cache). Redis is used for exactly four things: `GET`/`SET` of a document, a per-topic generation, a `refresh` list the hooks write, and
pub/sub for `changed`. All of that except push is already built for SQLite: documents (`reads`), generations (`reads.gen`, `topics.gen`), and a
one-second watcher. Redis is a second service with its own unit, socket, group (`redis-hobnix`, `hs-live`), memory cap, a 503 "state service
down" mode and a collector that retries every 5 s while it is away (`live-collect.py`). `capabilities/live-state/module.nix` itself marks the
Redis `group` option as unverified in the pinned nixpkgs. Redis is never reachable across nodes (ADR 0013), so it gives nothing to a cluster.

## Options

**A. The state database (recommended).** Documents move into the state database (the `reads` table reshaped, or a `live` table of the same shape),
written by the collector, read by the web server. `changed` comes from the generation counters; the existing watcher already does this.

- For: no second service, no socket and group, nothing to be "down" other than the collector; one store, one status for the Data page; works on
  `edge` and `minimal` roles that cannot run Redis today; `state.db` is already opened with WAL by several processes; the counters path is
  already tested without Redis (`tests/change-counters.sh`); Redis memory eviction (`allkeys-lru`) goes away; removes about one third of the
  live-state code (the RESP client, the pub/sub thread, the 503 path).
- Against: no push; the browser learns of a change up to one watcher period later (today 1 s, so a terminal change shows within about 1 to 2 s,
  not instantly). A write per changed document touches the disk; Redis never does.
- Mitigations: write a document only when its output changed (`read-put` already does this) and prove freshness with one heartbeat row
  (Decision 4), so 67 topics are not a constant disk write; or keep the documents in a second SQLite file on `/run` (tmpfs, rebuildable, no disk
  wear) and leave `state.db` for history. See Open points. Instant push, if 1 s proves too slow: Decision 8.

**B. Redis for everything.** Make `liveState = "redis"` the only mode, drop the `reads` table and `reads-collect.sh`, as PLAN-web-cache
anticipated.

- For: push is instant; no disk writes; the code and the tests exist (`tests/live-state.sh`, `tests/web-live.sh` with a fake Redis).
- Against: a mandatory service on every web-enabled install (also `edge` and `minimal`, or a role exception that is a second mode again); a
  hard dependency whose failure is a visible 503; one more service to rebuild, start and watch on a small box; permissions rest on an unverified
  option; none of this was run on hardware ("Not tested on hardware yet"). It buys sub-second push on a single server, where the user is
  one or a few people on the LAN.

**C. Keep both modes.** Rejected by the owner (one mode, one store).

## Decision (proposed)

1. Live state has no setting and no mode. The collector runs and the web follows the stream on every install with `webUi = true`, on every role.
2. The store is the state database (option A). Redis is not a dependency of Hobnix: `services.redis.servers.hobnix`, the group `hs-live` and
   `redis-hobnix` and the 503 "state service down" path are removed.
3. One document store: the `reads` table (or its successor `live`) holds all topics, with `gen`, `updated`, `err`, `ts_err`, `ttl`, `ms` and `rc`
   as `reads` has them today. `topics(topic, gen, time)` stays the change counter. A document is written, and its `gen` counted up, only when
   its output differs (ADR 0005 rule 5); an unchanged run writes nothing per document.
4. Freshness is one heartbeat row: the collector writes a single "alive" row (time of its last completed round) at its own rhythm. `/api/events`
   is fed by the counters; `changed`, `down`, `up`, `resync` keep their shape (ADR 0005). `down` is read from the heartbeat (older than a
   limit: the collector is not running), not from per-document ages and not from a service being away. A document's own `updated` changes
   only with its output; the page shows "unchanged since" from it, and "checked at" from the heartbeat.
5. `reads-collect.sh` and the timer `hs-reads-collect` go; the collector (`hs-live`, renamed only if needed) takes over the 27 slow reads as topics
   with their intervals.
6. Machine-readable lines (`hs sys live status`, `hs sys state reads`, topic documents) keep their shape (CLAUDE.md contract). An empty field is
   still `-`.
7. A server upgraded from a version with `liveState = "redis"` keeps working: the key is ignored with a note for one release, then removed from
   the schema.
8. Events stay signals, not data. An event says "this topic changed, refetch"; it never carries the new row. Reasons: a lost or reordered
   event would leave the page wrong until a reload (a refetch on reconnect resyncs); producers (scripts, recipes, extensions) would have to
   know the row shape of the page, which today only the `hs sys` read knows; a change made outside `hs` (`incus stop`, a crashed container)
   fires no event, so the read has to run again anyway. The collector intervals therefore stay as the safety net: better hooks allow longer
   intervals, they do not remove them.
9. Instant push is optional and later: if 1 s feels slow on real hardware, the collector pokes the web server over a unix socket after a
   write. The one-second watcher stays as the fallback, so the socket is an accelerator, never a requirement. It is not built unless the
   check on a real server asks for it.

## Consequences

- Easier: one path to test and document; `edge` and `minimal` get live state; no Redis socket permissions; a fresh install has a page that
  follows a terminal change without a setting.
- Harder: the push latency is the watcher period (about 1 s), not instant. The collector's write load goes to SQLite (WAL, several processes):
  needs a `busy_timeout`, and a check that 67 topics at their intervals do not make a writer wait (measure before accepting).
- Gone: option `liveState`, capability `live-state` (or kept as a name for the collector, see Open points), `module.nix` Redis part, `live_state.py`
  RESP client, `reads-collect.sh`, its timer, the off-mode half of the Data page, `HS_WEB_LIVE`, `StateStore` modes, tests that need a fake Redis.
- Docs: `docs/PLAN-web-cache.md` (the Redis parts are superseded by this record), `capabilities/live-state/NOTES.md` and `guide.md`,
  `.claude/rules/web.md`, a changelog entry.

## Migration outline (not built)

1. Measure first, on a real server (the code of the following steps stays behind a switch that is off until this is done): write cost and watcher latency of option A (the existing counters, 67 topics). Built behind `liveState = "db"`, see the operations guide ("Measure the live state on the state database").
2. Store: documents in the state database for every topic, including the 27 `reads` keys; migrate the `reads` table (rows are rebuildable, a
   migration may drop them).
3. Collector without Redis: `live-collect.py` writes to SQLite, bumps `topics.gen`; the hooks (`live_refresh`) keep their one-line call.
4. Web: topic reads from the database, `/api/events` from the counters only, `features.live` always true, the polling timers kept only as the
   fallback while the stream is down.
5. Default on without a setting: drop the `liveState` option from `config/schema.toml`, run `python3 scripts/schema-gen.py write`, remove
   `liveOn` and `HS_WEB_LIVE` from `configuration.nix`, remove the Redis part of the module.
6. Remove the second store and the mode switch: `reads-collect.sh` and its timer and registry rows, `live_state.py` Redis client, the Data page
   off mode, `capabilities/live-state` Redis docs; update the tests and the docs.
7. Check on a real server, in this order: (a) a fresh install shows the live indicator with no setting; (b) with a page open, change something in a
   terminal (`hs ct create`, `hs share add`, or stop a container) and the open page shows it within a few seconds without a reload; (c) stop the
   collector and the page marks its data as stale; (d) upgrade a server that had `liveState = "redis"`. Not tested on hardware yet.

## Follow-up issues to file

1. Measure on a real server, before the switch is turned on: SQLite write load and `changed` latency with all topics (spike, input to the open
   point on the file).
2. Collector writes documents to the state database; take over the 27 `reads` keys (`reads-collect.sh` and timer removed).
3. Web: topic reads and `/api/events` from the database only; remove the `StateStore` modes and the 503 path.
4. Remove the `liveState` option and the Redis service (schema, `configuration.nix`, `module.nix`, regenerate generated files, upgrade note).
5. Data page and `hs sys live status`: one status for all topics; drop the off-mode half.
6. Docs: rewrite `capabilities/live-state/NOTES.md` and `guide.md`, mark PLAN-web-cache superseded where it names Redis, changelog entry.
7. Real-server check (the terminal-change test above) and the `Pruefliste-Server.md` row.
8. Only if 1 s feels slow on that check: the collector pokes the web server over a unix socket (Decision 9).
9. Finer wake-up groups: named events (for example `service.created`) mapped to exactly the topics they affect, instead of broad groups such
   as `@instances` that wake many topics. Filed as its own issue; not part of this record and not needed for it.

## Open points

1. **Where do the documents live:** `state.db` (one file, one status, writes on disk) or a rebuildable database on `/run` (no disk wear, but a
   second file and a cold start after a reboot)? Recommendation: `state.db` with writes only on change plus one heartbeat row, unless the
   measurement in follow-up 1 shows a problem.
2. **Is a push channel needed later** (a hundred users, a cluster view)? This record says no for a single server; a node pulls a peer through
   the forced-command allowlist (ADR 0013) and never shares a store. If this changes, a new record supersedes this one.
3. **The name of the capability.** `live-state` can stay as a name for the collector or disappear into the web interface (it has no option left).
   Not decided here.
4. **Roles without `webUi`:** nothing runs there, as before. Whether the collector should also serve the deck (PLAN-web-cache phase 6) is left to
   that phase.
5. **Real-server evidence.** The counters-only path ran in tests (`tests/change-counters.sh`), not on hardware. Not tested on hardware yet.
