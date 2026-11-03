# Plan: events (audit, 2026-11-03)

Status: audit only, nothing built.

Epic: hobnix/server#139 (event architecture), audit issue #141. Baseline: main at 393700b. Everything below is read from code; nothing was run
on hardware. `liveState` defaults to `off`, so on a default install most of the live paths below are inactive. Line numbers are hints and
drift; the file and function names are the reference.

## Audit (2026-11)

### 1. Transport channels that exist

| Channel | Code | Shape | Durable | Notes |
| --- | --- | --- | --- | --- |
| Redis pub/sub `hs:v1:changed` | scripts/live-collect.py:99 (only writer), read by `Events` in scripts/web-serve.py:1897 | text `<topic> <gen>` | no (pub/sub, no persistence, RAM only) | only in `liveState = "redis"` |
| Redis pub/sub `hs:v1:refresh` | `live_refresh` (scripts/lib/live.sh -> live_state.py:210), `RedisStore.request` (web-serve.py:1886) | text `<topic>`, `@<group>`, `*` | no; a message sent while hs-live is not subscribed is lost | fire and forget, always rc 0 |
| Redis key `hs:v1:<topic>` | live-collect.py `collect` | JSON `{ts, gen, rc, out, err, ts_err}`, `out` = raw `hs sys` text | no (RAM, rebuilt by collector) | the state, not an event; `gen` is the only sequence number in the system |
| SSE `GET /api/events` | web-serve.py:2319 `_events` | `event: changed` `{topic, gen}`; `event: down` / `up` `{}`; `: ping` every 15 s; `retry: 3000` | no: no `id:`, no Last-Event-ID replay; per-stream queue of 256, overflow silently dropped (web-serve.py:1921) | 404 in off mode; max 32 streams; ends on sign-out/lock/6 h |
| SSE `GET /api/sys/jobs/stream/<unit>` | web-serve.py:2267 `_jobs_stream` | `data: {"rows": [...]}` (same rows as `sys jobs tail`), `event: end` | replayable by offset (`?from=N`, journal is the store) | polls `hs sys jobs tail` every 1 s per stream (one subprocess/s/stream); max 6 |
| WebSocket `/api/terminal/ws` | scripts/web_terminal.py | pty bytes | no | not an event channel; listed so it is not mistaken for one |
| Push messages | scripts/notify.sh -> scripts/lib/channels.sh -> scripts/notify/{ntfy,email}.sh | title, body, priority (min..urgent), category (-> class alarm/status/heartbeat/digest) | journal line `hs-notify` always; delivery best effort, no retry; quiet hours hold low/default messages and flush one digest (lib/notify-route.sh) | per-channel last result kept (`chan_result_set`); per-health-key "who was told" (`chan_told_set`) |
| systemd `OnFailure=hs-notify-failure@%N` | configuration.nix:125, :646 | unit name -> push "<host>: <unit> failed" | journal | on every hs-* timer service and every `hs_job` unit |
| state.db table `events` | scripts/state-db.py:168 `event()` | `(time, kind, subject, text)`; kinds `new back missing worse forgotten baseline smart-reset smart-<level>` | yes (SQLite, last 2000 kept) | disks only; read by `hs sys state events`, `events-json` |
| `/var/lib/hs/disk-events` | scripts/disk-event.sh:62 | `date TAB action TAB text` | yes (file, append only) | second disk event log beside state.db |
| `/run/hs-deck/deck-events.json` | configuration.nix:305 (hs-deck-status, every 10 s) | `{schema:1, events:[...]}` from state.db | rebuilt every 10 s | consumer: deck API port 9740 (displays) |
| Health state files | health-check.sh (`health-since`, `health-ack`, last-state keys) | key -> since / acked | yes (files) | change detection for "push when something changes" |

### 2. Sources (who emits what)

| Source | Trigger | Emits | Payload | Consumers | Delivery |
| --- | --- | --- | --- | --- | --- |
| Live collector `hs-live` | per-topic interval (78 rows in scripts/lib/live-topics.tsv, 5 s..600 s) or `hs:v1:refresh` | key SET + PUBLISH `changed` | `<topic> <gen>` | web `Events` hub -> SSE -> `poll()` re-read | gen bumps on every successful read, also when `out` is identical; a failed read publishes nothing (only `err`/`ts_err` on the key, seen as `X-HS-Stale` on the next GET) |
| CLI dispatcher | `hs <row>` with flag `changes`, exit 0 (scripts/lib/hs.sh:405-413) | `live_refresh @<topic flag>` (+ `@ext-<n>`) | group name | collector | lost when off/socket missing; no refresh on exit != 0 |
| Background job `hs_job` | start / end (scripts/lib/job.sh:17-26) | start: `refresh @jobs`; end: `refresh --all` + push "<desc> finished" on rc 0; `OnFailure` push on rc != 0 | - | collector; phone | best effort |
| Web change `POST /api/start` | every start (web-serve.py:2477) | `reads.clear()` (+ plan cache) and `store.request(area_refresh(area))` via `AREA_GROUP` | `@<group>` or `*` | web read cache; collector | at start only, not when the started job ends |
| Explicit script hooks | ups.sh:112, health-check.sh:43, state.sh:49/74/77/78, disk-health.sh:12, update.sh:45, update-preview.sh, unlock.sh:247 (`--all`), pkg.sh, jobs.sh stop, ~20 storage/share scripts | `live_refresh <topics>` | topic list | collector | best effort |
| Timers (systemd) | backup 04:00, drills, bulk-sync/scrub, cache-mover, share-snapshots, selftests, remote-mount 2 min, sync-shares | `<script> && live.sh refresh @<group>` | group | collector | refresh only on success (`&&`): a failed run leaves the pages on the old value until the topic interval |
| Timers without a refresh | hs-mac 03:30, hs-system-gc Sun 06:30, hs-backup-report, hs-smart-baseline 03:05 (refresh only via state.sh/disk-health paths), hs-nss-warm, edge timers | nothing to live state | - | - | pages catch up on interval only |
| Health check | timer every 15 min (configuration.nix:607) | push on change of the problem set; heartbeat; digest flush; refresh `health-next health-list status deck` | key set, texts | phone; Health page | push best effort; problem state durable in files |
| udev block add/remove | configuration.nix:483 -> `hs-disk-event@<action>-<kernel>.service` -> disk-event.sh | line in disk-events, `state.sh collect --event` (state.db events), push (silent at boot window and for known disks), refresh incl. `backup-state` | text | phone; Bottom panel "Disk events" (`sys state events`); deck | file + DB durable; push best effort |
| UPS (upsmon `NOTIFYCMD`) | configuration.nix:583 -> `ups.sh event` | push + `live_refresh ups deck status` | NUT event name | phone; Summary | best effort |
| Boot / shutdown / lock | power-notice.sh (started/stopping), unlock.sh (urgent "unlock needed", "unlocked") | push; unlock: `refresh --all` | text | phone; pages | best effort |
| Update / rebuild | update.sh, rebuild.sh | push (started, stopped, finished, failed) + refresh `system-updates` | text | phone | best effort |
| Backup | backup.sh:811 | push per result category | text, priority | phone | best effort |
| Old reads collector | hs-reads-collect every 15 s (configuration.nix:622) | rows in state.db `reads` | output, rc, ms | web `Reads.collected` (served while <= 3 min old) | durable, no notification to anyone; skips topic reads in Redis mode |
| Extension reads | `[[web.reads]] live = N` (scripts/hs_ext.py) | topic `ext-<name>-<words>` | as collector | as collector | rescanned every 60 s |

### 3. Consumers in the browser

| Consumer | Code | Input | Fallback |
| --- | --- | --- | --- |
| `live` store | web/src/live.svelte.js | `/api/events` (`changed` -> `live.gen[topic]`, `open/up/down/error`) | none needed; `live.open=false` |
| `poll(path, ms, topic)` | web/src/data.svelte.js:44 | re-runs effect on `live.gen[t]`, `live.open`, `sync.n`; topic from arg or `features.topics` map | timer `ms` (via polldelay.js) while stream down or no topic; about 70 pages/forms use it |
| Task follower | web/src/ui.svelte.js:67 `follow` | jobs stream SSE | 2 s polling of `sys jobs tail` |
| Bottom panel | web/src/shell/BottomPanel.svelte | polls `jobs running`, `jobs list`, `logs show`, `state events` | - |
| What's new badge | web/src/changes.svelte.js:38 | `setInterval` 5 min | - |
| Fresh / Data pages | shell/Fresh.svelte (`X-HS-Age`), pages/Data.svelte (`live.open`) | headers | - |
| Plan cache | web/src/api.js:93-112 | cleared on every start | - |

### 4. Gaps

1. **Default install has no change events at all.** `liveState` is `off` by default: `/api/events` is 404, a change made with `hs` in a
   terminal or by a timer does not clear the web read cache (PLAN-web-cache.md problem 3 still holds in off mode); pages catch up on TTL /
   stale-while-revalidate (up to 30 min shown, X-HS-Age).
2. **Job end is not an event in the browser.** The web clears its cache and asks for `@<group>` at `start`; the job's end does
   `refresh --all` only in Redis mode. In off mode the page re-reads on its timer after the job ends; nothing ties "task finished" in the
   Tasks tab to re-reading the affected page.
3. **No durable event log.** Everything on Redis is pub/sub; `/api/events` has no `id:` and no replay. Recovery relies on re-reading on
   (re)connect (`announce()` on hub reconnect, `live.open` toggling in the browser). Fine for "state changed", unusable for "what happened".
4. **"Changed" means "read again", not "different".** The collector bumps `gen` and publishes on every successful read even when `out` is
   identical, so every open page re-fetches every topic it follows at the topic interval (for example `ct-list` every 10 s).
5. **A failed read is silent on the stream.** Only `err`/`ts_err` on the key; the browser learns it at its next GET (`X-HS-Stale`). There
   is no `stale` event; Health reports `live:stale:<topic>` only every 15 min.
6. **Refresh lost on failure.** Timer units refresh with `&&`; the dispatcher refreshes only on exit 0. A failed backup or sync changes state
   (last-run result, health) but does not refresh. `OnFailure` sends a push but triggers no refresh.
7. **Timers without refresh:** hs-mac, hs-system-gc, hs-backup-report (and anything run outside `hs`, for example `incus stop` by hand).
8. **No daemon event watchers.** Nothing listens to `incus monitor`, Docker events, ZED (`zpool events`) or systemd unit state changes;
   a container crash or a ZFS fault shows up only at the next collector interval or the 15-min health check (push).
9. **Three separate "happened" logs with different shapes:** state.db `events` (disks, SMART), `/var/lib/hs/disk-events` (udev, duplicate of
   part of the first), the journal (`hs-notify`, job units). Notifications themselves are not stored anywhere the web can list (only the
   per-channel last result and per-health-key "told").
10. **Push delivery is best effort:** no retry or outbox; a provider error is a journal line. Quiet-hours hold is the only queue.
11. **Jobs stream costs a subprocess per second per open stream** (polling `hs sys jobs tail`); it is a stream by shape only.
12. **Stream fan-out is unfiltered and lossy:** every `changed` goes to every stream (all admin today; per-user filtering would need it),
    queue overflow drops silently with no resync signal.
13. **Two refresh vocabularies:** `AREA_GROUP` in web-serve.py and registry `topic:` flags in hs.sh must name the same groups by hand
    (no test seen that compares them; not verified).
14. **Polls that ignore the stream:** `changes.svelte.js` (5 min `setInterval`) and the Bottom panel reads have no topic.

## Open questions

None yet. The design follows from this audit.
