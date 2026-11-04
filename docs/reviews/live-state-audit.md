# Live state: audit against the roadmap section 6

Audit for hobnix/server#149 (epic #147, Reactive Live-state). Date of the code read: 2026-11-04, branch `develop`. Findings only: no code was
changed. Everything below is read in code; **nothing was run on a server**. Not tested on hardware yet.

Roadmap section 6 asks that every state entry carries a **status** (fresh, stale, error), a **revision**, a **source** and an **expiry**.

## What exists

| Part | Where | Holds |
|---|---|---|
| Hot store | Redis, unix socket, 32 MB, `allkeys-lru`, no persistence (`capabilities/live-state`) | key `hs:v1:<topic>` = JSON `{ts, gen, rc, out, err, ts_err}` |
| Collector | `scripts/live-collect.py` (unit `hs-live`) | one thread per topic; runs `hs sys <words>` every N s or on a refresh message; the one writer |
| Topic list | `scripts/lib/live-topics.tsv` (67 rows) + extension reads (`hs_ext.ext_live_rows`, rescan every 60 s) | topic, words, interval, lock mode, capability, change groups |
| Second store | state.db table `reads` (`reads-collect.sh`, `collected-reads.tsv`, 31 rows) | `key, payload, updated, ms, rc`; used when Redis is off; skipped for topics hs-live keeps |
| Counters | state.db table `topics(topic, gen, time)` | invalidation counters; `/api/events` in every mode (#289) |
| Web | `Redis store` in `scripts/web-serve.py` | serves the document, headers `X-HS-Age`, `X-HS-Stale` (only when the last try failed) |
| Events | SSE `changed {topic, gen}`, `down`, `resync`, ids and replay (#290) | no per-entry status |

## Per entry: the four properties

Counts are over the 67 core topics (all handled the same way by code); the 34 `skip` topics and the 22 capability-gated topics change only the
lock behaviour and whether a document exists.

| Property | Redis topic document | `reads` table row | Verdict |
|---|---|---|---|
| Status fresh / stale / error | Not stored. Derivable: `ts`, `ts_err`, `err`, interval. `live status` prints the raw fields; `live check` flags stale (age > 3 x interval), never-read and down. The web sends `X-HS-Stale` (error time) only when `ts_err > ts`; the browser never reads it (grep: only `web-serve.py`). Fresh.svelte shows age only. | None. `rc` of the last run only; a failed run overwrites nothing visible. | Gap: no explicit field, no single definition, not shown in the UI. |
| Revision | `gen`: +1 only when the output differs (#295); an identical read moves `ts`. In `changed {topic, gen}` and `/api/events`. | None per row; the `topics` counter `reads:<key>` stands in. | Redis: met. `reads`: gap. |
| Source | Implicit: the topic name maps to the words of one `hs sys` call in the tsv. Not in the document; `rc` and `err` only. Extension topics: group `ext-<name>`. | Implicit: the key is the words. | Gap: the document does not say who wrote it or from which command. |
| Expiry | No Redis TTL on the key. A topic that stops being refreshed keeps its last document for ever (until LRU eviction or reboot). Staleness is a threshold in `live_state.py check` only; the web serves the old value with `X-HS-Age` and never refuses it. Extension topics that go away are `DEL`ed. | `stale_factor` (40 x ttl) and `stale_max` (1800 s) in the web cache decide whether a kept row is still shown. | Gap: no per-entry max age, no expired state. |
| Last good data kept on failure | Yes: failure without output keeps `out`, sets `err`/`ts_err` (collector). Output with rc != 0 counts as data. A timeout is rc 124 with no output = failure. | The row is kept; no error marker. | Redis: met (#151 is working on the details). |

Other entries that are not topics: the web read cache (`ttl`, `X-HS-Age`, per read spec), the `status` topic (one document for the deck),
`jobs-running` (current state with a record per job, ADR 0004). They follow the same rules as the topics above.

## Gaps

1. **No status field.** Fresh, stale and error are three different thresholds in three places (`check`, `X-HS-Stale`, `Fresh.svelte` colours at
   120 s and 600 s). No place agrees with another.
2. **The UI cannot show an error.** `X-HS-Stale` is sent and not read. A failing collector looks like an old page.
3. **No source in the document**, so a document cannot be traced to its command, collector or version without reading the tsv.
4. **No expiry.** A dead collector (or a stopped topic thread) leaves a document that looks valid; only `live check` raises `live:stale:`.
5. **Two stores with different shapes.** `reads` has no `gen`, no error time, no status; the Data page has to special-case both.
6. **Flat dependencies.** Groups wake topics (`@disks`), but a topic cannot depend on another topic (for example `services-routes` on `ct-list`);
   dependents run on their own interval. Needs the graph of #153.
7. **Polling where an event exists.** `docker-list` and `docker-apps` poll every 30 s; Docker has an event stream (#155).
8. **No inspector.** `hs sys live status` is the only view, in a terminal; the Data page lists reads and intervals, not status or errors (#157).

## Proposed minimal model

One shape for every entry, written by the collector, derived by readers:

```
{ ts, gen, rc, out, err, ts_err,          # as today
  src,        # the words of the read, e.g. "pool info bulk"  (new)
  ttl }       # seconds after ts when the entry counts as expired; default 3 x interval (new)
status = error   when err and ts_err >= ts
         expired when now - ts > ttl
         stale   when now - ts > 1.5 x interval
         fresh   otherwise
```

- One function `status_of(doc, interval, now)` in `live_state.py`, used by `status`, `check`, the web (a new header `X-HS-Status`) and the
  inspector. The three thresholds above collapse into it.
- `live status` gets a status column at the end (a new tab-separated field; the machine contract allows a new last field only with an
  `openapi-gen` update in the same commit).
- No Redis `EXPIRE`: the last good data must stay readable; `expired` is a state, not a deletion.
- `reads` rows: move into the same function by adding `gen` and `err` columns, or retire the table once Redis mode is the default on
  homeservers (decide in the sub-issue).
- Dependencies (#153) and events (#155) build on this: they change when a read runs, not what an entry holds.

## Sub-issues

| Issue | Title |
|---|---|
| #153 | Dependency graph and invalidation propagation (acceptance criteria written) |
| #155 | Docker event stream as an event-driven collector (acceptance criteria written) |
| #157 | State inspector page (acceptance criteria written) |
| #322 | Entry status, source and ttl in the live document (one `status_of`) |
| #323 | Show stale and error state in the web interface (read `X-HS-Status`) |
| #324 | Bring the `reads` table to the live entry shape or retire it |

#148 to #158 (even numbers) are closed duplicates of the epic and its children; work continues on #147 and the odd numbers.
