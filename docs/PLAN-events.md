# Plan: events (audit, 2026-11-04)

Status: audit only, nothing built.

Epic: hobnix/server#139 (event architecture), audit issue #141, next step ADR #143. Baseline: develop at a070a7c. Everything below is read
from code; nothing was run on hardware. `liveState` defaults to `off`, so on a default install most of the live paths below are inactive.
Line numbers are hints and drift; the file and function names are the reference.

## Terms

- **Domain event**: a fact that happened at a time and stays true ("disk sdb removed", "job X failed"). Worth storing, can be listed.
- **Invalidation event**: "topic T may have changed, read it again". Carries no facts; losing one only delays a page until the next read.
- **Delivery guarantee**: `none` (fire and forget, lost if nobody listens), `best effort` (tried once, failure logged), `at least once`
  (retried until acknowledged), `replayable` (a reader can ask from an offset).
- **Durability**: `RAM`, `tmpfs /run` (lost at reboot), `disk` (survives reboot), plus retention if known.

## 1. Transports

| Channel | Code | Shape | Durable | Notes |
| --- | --- | --- | --- | --- |
| Redis pub/sub `hs:v1:changed` | scripts/live-collect.py:99 (only writer), read by `Events` in scripts/web-serve.py:1897 | text `<topic> <gen>` | no (pub/sub, no persistence, RAM only) | only in `liveState = "redis"` |
| Redis pub/sub `hs:v1:refresh` | `live_refresh` (scripts/lib/live.sh -> live_state.py), `RedisStore.request` (web-serve.py:1886) | text `<topic>`, `@<group>`, `*` | no; a message sent while hs-live is not subscribed is lost | fire and forget, always rc 0 |
| Redis key `hs:v1:<topic>` | live-collect.py `collect` | JSON `{ts, gen, rc, out, err, ts_err}`, `out` = raw `hs sys` text | no (RAM, rebuilt by collector) | the state, not an event; `gen` is the only sequence number in the system |
| SSE `GET /api/events` | web-serve.py:2319 `_events` | `event: changed` `{topic, gen}`; `event: down` / `up` `{}`; `: ping` every 15 s; `retry: 3000` | no: no `id:`, no Last-Event-ID replay; per-stream queue of 256, overflow silently dropped (web-serve.py:1905, :1920) | 404 in off mode; max 32 streams; ends on sign-out/lock/6 h |
| SSE `GET /api/sys/jobs/stream/<unit>` | web-serve.py:2267 `_jobs_stream` | `data: {"rows": [...]}` (same rows as `sys jobs tail`), `event: end` | replayable by offset (`?from=N`, journal is the store) | polls `hs sys jobs tail` every 1 s per stream (one subprocess/s/stream); max 6 |
| WebSocket `/api/terminal/ws` | scripts/web_terminal.py | pty bytes | no | not an event channel; listed so it is not mistaken for one |
| Push messages | scripts/notify.sh -> scripts/lib/channels.sh -> scripts/notify/{ntfy,email}.sh | title, body, priority (min..urgent), category (-> class alarm/status/heartbeat/digest) | journal line `hs-notify` always (notify.sh:111/125/136); delivery best effort, no retry; quiet hours hold low/default messages and flush one digest (lib/notify-route.sh) | per-channel last result kept (`chan_result_set`); per-health-key "who was told" (`chan_told_set`) |
| Push, direct to ntfy | vps/hs-watch.sh (via scripts/lib/ntfy.sh `ntfy_send`) | title, body, priority | no | bypasses notify.sh, channels, quiet hours and the journal line (E22) |
| Push, to the Matrix hook | scripts/recipes/files/hs-media-notify.py | app event as a webhook call | no | runs inside the media container (E21) |
| systemd `OnFailure=hs-notify-failure@%N` | `notifyFailure` configuration.nix:125; template `hs-notify-failure@` configuration.nix:666 | unit name -> push "<host>: <unit> failed" | journal | on every hs-* timer service and every `hs_job` unit |
| state.db table `events` | scripts/state-db.py:168 `event()` | `(time, kind, subject, text)`; kinds `new back missing worse forgotten baseline smart-reset smart-<level>` | yes (SQLite, last 2000 kept) | disks only; read by `hs sys state events`, `events-json` |
| `/var/lib/hs/disk-events` | scripts/disk-event.sh:16 (`log=`) | `date TAB action TAB text` | yes (file, append only) | second disk event log beside state.db |
| Job record `/var/lib/hs/jobs/<id>.json` | scripts/lib/job.sh:9 `hs_job_record` -> scripts/job-record.py (or Rust `hobnix job-record`) | one JSON file per job, written atomically; states queued/running/ok/failed/cancelled/interrupted | yes (disk; newest 200 or 30 days, ADR 0004 rule 8) | no publish on write (E17) |
| Journal | `logger -t hs-notify`, unit output of job units | text lines | yes (disk, journald retention) | read by `sys jobs tail`/`log` (scripts/jobs.sh), `hs logs` (scripts/logs.sh) |
| `/run/hs-deck/deck-events.json` | configuration.nix:304 (`hs-deck-status`, every 10 s) | `{schema:1, events:[...]}` from state.db | rebuilt every 10 s (tmpfs /run) | consumer: deck API port 9740 (displays) |
| Health state files | health-check.sh (`health-since`, `health-ack`, last-state keys) | key -> since / acked | yes (files) | change detection for "push when something changes" |

## 2. Inventory

One row per source. Owner is the area that owns the code. Kind: `domain`, `invalidation`, `both` (the split is written in Payload), `-`.

| # | Source | Trigger | Payload | Transport | Consumers | Delivery | Durability | Owner | Kind |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| E1 | Live collector `hs-live`: scripts/live-collect.py:99; unit capabilities/live-state/module.nix:26; topics scripts/lib/live-topics.tsv (78 rows) | per-topic interval (5 s..600 s) or `hs:v1:refresh` | `<topic> <gen>`; gen bumps on every successful read, also when `out` is identical; a failed read publishes nothing (only `err`/`ts_err` on the key, seen as `X-HS-Stale` on the next GET) | key SET + PUBLISH `hs:v1:changed` | web `Events` hub -> SSE -> `poll()` re-read | none | RAM | live-state | invalidation |
| E2 | CLI dispatcher: scripts/lib/hs.sh:440-448 | `hs <row>` with flag `changes`, exit 0 only | `live_refresh @<topic flag>` (+ `@ext-<n>`): a group name | `hs:v1:refresh` | collector | none (lost when off or socket missing; no refresh on exit != 0) | RAM | live-state | invalidation |
| E3 | `hs_job` wrapper: scripts/lib/job.sh:43 (`OnFailure=hs-notify-failure@`), :50 (`refresh --all`), :51 (push "<desc> finished" on rc 0) | job start / end | invalidation: start `refresh @jobs`, end `refresh --all`; domain: push "<desc> finished" on rc 0, `OnFailure` push on rc != 0 | `hs:v1:refresh`; push | collector; phone | best effort | RAM (refresh); journal (push line) | core (job.sh) | both |
| E4 | Web `POST /api/start`: scripts/web-serve.py:2479 `store.request(area_refresh(area))`; `AREA_GROUP` :926, `area_refresh` :934 | every start (not the end of the started job) | `@<group>` or `*`; plus local `reads.clear()` (:2478) and plan cache clear | `hs:v1:refresh` | web read cache; collector | none | RAM | web | invalidation |
| E5 | Explicit script hooks (`live_refresh` / `live.sh refresh`), 28 files at a070a7c (70 lines): create-share, disk-detach, disk-event, disk-health, disk-recover, health-check, jobs, lib/hs, lib/job, lib/live, manage-pool, manage-shares, pkg, share-cache, share-cleanup, share-delete, share-perm, share-purge, share-snap, share-undelete, state, sync-shares, temp-disk, unlock, update-preview, update, ups, vault (.sh) | the script changed something | topic list | `hs:v1:refresh` | collector | none | RAM | core (the named scripts) | invalidation |
| E6 | Timers with `&& live.sh refresh`: capabilities/backup/module.nix:21/39/57; capabilities/storage/module.nix:49/61/74/85/157/194/204/233; capabilities/samba/module.nix:134 | backup 04:00, drills, bulk-mount/sync/scrub, cache-mover, share-snapshots, selftests, remote-mount 2 min, sync-shares | group (`@backup`, `@disks`, `@shares`) | `hs:v1:refresh` | collector | none; only on success (`&&`): a failed run leaves the pages on the old value until the topic interval | RAM | backup, storage, samba | invalidation |
| E7 | Timers without a refresh: hs-mac (capabilities/incus/module.nix:122), hs-system-gc (configuration.nix:644), hs-backup-report (capabilities/backup/module.nix:65), hs-smart-baseline (capabilities/storage/module.nix:176; refresh only via state.sh / disk-health paths), hs-nss-warm (capabilities/samba/module.nix:144), hs-edge-watch (capabilities/edge-watcher/module.nix:33) | schedule | nothing to live state; `OnFailure` push where `onFailure` is set (E23) | - | - | pages catch up on interval only | - | incus, core, backup, storage, samba, edge-watcher | - |
| E8 | Health check: unit configuration.nix:609; scripts/health-check.sh:43 (refresh on exit 0) | timer every 15 min | domain: push on change of the problem set, heartbeat, digest flush; invalidation: refresh `health-next health-list status deck` | push; `hs:v1:refresh`; state files | phone; Health page | best effort (push); none (refresh) | disk (problem state files); RAM | core (health-check.sh) | both |
| E9 | udev block add/remove: rule configuration.nix:491 -> `hs-disk-event@` capabilities/storage/module.nix:253 -> scripts/disk-event.sh:16 | disk added / removed | domain: line in `/var/lib/hs/disk-events`, `state.sh collect --event` (state.db row, scripts/state-db.py:168), push (silent in the boot window and for known disks); invalidation: refresh incl. `backup-state` | file; SQLite; push; `hs:v1:refresh` | phone; Bottom panel "Disk events" (`sys state events`); deck | file and DB: written once; push best effort | disk (file; state.db last 2000) | storage | both |
| E10 | UPS: upsmon `NOTIFYCMD` configuration.nix:592 -> scripts/ups.sh `event` | NUT event | domain: push of the NUT event name; invalidation: `live_refresh ups deck status` | push; `hs:v1:refresh` | phone; Summary | best effort | journal (push line) | core (ups.sh) | both |
| E11 | Power / unlock: scripts/power-notice.sh (started/stopping), scripts/unlock.sh:93 (urgent "unlock needed"), :247 (`live_refresh --all`) | boot, shutdown, lock, unlock | domain: push text; invalidation: unlock `refresh --all` | push; `hs:v1:refresh` | phone; pages | best effort | journal (push line) | core | both |
| E12 | Update / rebuild: scripts/update.sh:138/158 (push with `--category`), :100 (refresh `system-updates`); scripts/rebuild.sh:40/42/124 | `hs update`, `hs rebuild` | domain: push (started, stopped, finished, failed); invalidation: refresh `system-updates` | push; `hs:v1:refresh` | phone | best effort | journal (push line) | core | both |
| E13 | Backup: scripts/backup.sh:811 | each result | push per result category, text, priority | push | phone | best effort | journal (push line) | backup | domain |
| E14 | Old reads collector `hs-reads-collect`: configuration.nix:624/631 | every 15 s | rows `reads` in state.db (output, rc, ms); state, not an event; no notification to anyone; skips topic reads in Redis mode | SQLite | web `Reads.collected` (served while <= 3 min old) | - | disk | web | - |
| E15 | Extension reads `[[web.reads]] live = N` (scripts/hs_ext.py:141-155) | rescanned every 60 s | topic `ext-<name>-<words>`; same as E1 | as E1 | as E1 | as E1 | RAM | core (hs_ext.py), the extension owns the read | invalidation |
| E16 | `hs-deck-status`: configuration.nix:304 | every 10 s | consumer of state.db events; re-publishes them as `/run/hs-deck/deck-events.json` | file | deck API port 9740 | none (rebuilt every 10 s) | tmpfs /run | core | domain |
| E17 | Job record: docs/adr/0004-job-record.md (Proposed); `hs_job_record` scripts/lib/job.sh:9 -> scripts/job-record.py; `hs-job-reconcile.service` configuration.nix:655 | `hs_job` start, run, finish; cancel via `<id>.cancel` (scripts/jobs-change.sh:54/67); boot (reconcile marks lost ones `interrupted`) | one JSON state record per job; every transition is a fact. Writing it publishes nothing | file `/var/lib/hs/jobs/<id>.json` | nobody yet: `sys jobs record(s)` is not in scripts/lib/registry.tsv at a070a7c (planned in ADR 0004 rule 9) | written once per transition (atomic) | disk (200 records / 30 days) | core (job.sh) | domain |
| E18 | Journal as a store: `logger -t hs-notify` scripts/notify.sh:111/125/136 (every message, also held and unsent ones, not heartbeats); job unit output | a push; job output | text line | journald | `sys jobs tail` / `log` (scripts/jobs.sh), `hs logs` (scripts/logs.sh) | replayable by line offset (`tail`) | disk (journald retention) | core (notify.sh, jobs.sh) | domain |
| E19 | Notification channel results: `chan_result_set` scripts/lib/channels.sh:184, `chan_told_set` :196 | each send | last result per channel; who was told per health key; state, not an event | files | notify.sh, health-check.sh, channel pages | - | disk | core | - |
| E20 | Quiet hours hold / digest: scripts/lib/notify-route.sh (`route_hold`, `route_flush_text`) | a low/default push in quiet hours | held message, later one digest | file queue | channels, at the end of quiet hours | held until flush (the only queue in the system) | disk | core | domain |
| E21 | Media apps notifier: scripts/recipes/files/hs-media-notify.py (`send --service maintainerr\|sabnzbd --event <name>`); config pushed by scripts/recipes/_media.sh:112-143 | app event inside the container | app event as a webhook call to the Matrix hook; never reaches hs live state or notify.sh | HTTP to the Matrix hook | Matrix room | best effort | - | recipe media | domain |
| E22 | VPS edge watcher: capabilities/edge-watcher/module.nix:29 runs vps/hs-watch.sh; ntfy via scripts/lib/ntfy.sh (vps/hs-watch.sh:15-17, :87) | timer every 5 min | alarm when the heartbeat or a public address changes | HTTP to ntfy, bypassing notify.sh / channels / quiet hours | phone | best effort (state kept in `/var/lib/hs-watch/state`) | disk (state file) | edge-watcher | domain |
| E23 | Edge / service failures: capabilities/edge-mail/module.nix:109, capabilities/edge-status/module.nix:49-51 (tailscaled, nftables, sshd), capabilities/edge-watcher/module.nix:30, capabilities/live-state/module.nix:39; template configuration.nix:666 | unit failed | push "<host>: <unit> failed" | push | phone | best effort | journal | edge-mail, edge-status, edge-watcher, live-state | domain |
| E24 | Changelog / What's new: docs/changelog/*.toml (source, read at build time); per-user seen revision web-serve.py:1981 (`/api/changes/seen`) | release | release facts; no push | file; HTTP | web/src/changes.svelte.js:38 (every 5 min) | none (polled) | disk | web | domain |

### Not events (checked)

- Terminal WebSocket (web/src/shell/Terminal.svelte:43, scripts/web_terminal.py): a byte stream of one shell, no facts, no topics.
- Redis keys `hs:v1:<topic>`: the latest state of a topic (E1 writes it), not a message.
- Update channel state (scripts/lib/update-channel.sh:33/39, `/var/lib/hs/update-channel`): the channel the last update used; a setting remembered.
- `hs smoke`: probes on demand, output only, nothing stored or sent.
- `hs doctor`: a check on demand (scripts/doctor.sh), output only.
- Git pre-commit guard (scripts/dev/install-guards.sh): a developer tool in the clone, not part of the running server.

## 3. Consumers in the browser

| Consumer | Code | Input | Fallback |
| --- | --- | --- | --- |
| `live` store | web/src/live.svelte.js | `/api/events` (`changed` -> `live.gen[topic]`, `open/up/down/error`) | none needed; `live.open=false` |
| `poll(path, ms, topic)` | web/src/data.svelte.js:44 | re-runs effect on `live.gen[t]`, `live.open`, `sync.n`; topic from arg or `features.topics` map | timer `ms` (via polldelay.js) while stream down or no topic; about 70 pages/forms use it |
| Task follower | web/src/ui.svelte.js:67 `follow` | jobs stream SSE | 2 s polling of `sys jobs tail` |
| Bottom panel | web/src/shell/BottomPanel.svelte | polls `jobs running`, `jobs list`, `logs show`, `state events` | - |
| What's new badge | web/src/changes.svelte.js:38 | `setInterval` 5 min | - |
| Fresh / Data pages | shell/Fresh.svelte (`X-HS-Age`), pages/Data.svelte (`live.open`) | headers | - |
| Plan cache | web/src/api.js:93-112 | cleared on every start | - |

## 4. Gaps

All were checked against develop at a070a7c.

1. **Default install has no change events at all** (E1, E2, E4). `liveState` is `off` by default: `/api/events` is 404, a change made with
   `hs` in a terminal or by a timer does not clear the web read cache (PLAN-web-cache.md problem 3 still holds in off mode); pages catch up
   on TTL / stale-while-revalidate (up to 30 min shown, X-HS-Age).
2. **Job end is not an event in the browser** (E3, E4, E17). The web clears its cache and asks for `@<group>` at `start`; the job's end does
   `refresh --all` only in Redis mode. In off mode the page re-reads on its timer after the job ends; nothing ties "task finished" in the
   Tasks tab to re-reading the affected page.
3. **No durable event log for the browser** (E1). Everything on Redis is pub/sub; `/api/events` has no `id:` and no replay. Recovery relies
   on re-reading on (re)connect (`announce()` on hub reconnect, `live.open` toggling in the browser). Fine for "state changed", unusable
   for "what happened".
4. **"Changed" means "read again", not "different"** (E1). The collector bumps `gen` and publishes on every successful read even when `out`
   is identical, so every open page re-fetches every topic it follows at the topic interval (for example `ct-list` every 10 s).
5. **A failed read is silent on the stream** (E1). Only `err`/`ts_err` on the key; the browser learns it at its next GET (`X-HS-Stale`).
   There is no `stale` event; Health reports `live:stale:<topic>` only every 15 min.
6. **Refresh lost on failure** (E2, E6). Timer units refresh with `&&`; the dispatcher refreshes only on exit 0. A failed backup or sync
   changes state (last-run result, health) but does not refresh. `OnFailure` sends a push but triggers no refresh.
7. **Timers without refresh** (E7): hs-mac, hs-system-gc, hs-backup-report (and anything run outside `hs`, for example `incus stop` by
   hand).
8. **No daemon event watchers.** Checked: no `incus monitor`, `docker events`, `zpool events` or ZED zedlet in scripts or `*.nix`; `zfs-zed`
   appears only as a log filter in scripts/logs.sh:45. A container crash or a ZFS fault shows up only at the next collector interval (E1)
   or the 15-min health check (E8).
9. **Four separate "happened" logs with different shapes** (E9, E17, E18): state.db `events` (disks, SMART), `/var/lib/hs/disk-events`
   (udev, duplicate of part of the first), the job record (jobs), the journal (`hs-notify`, job units). Notifications themselves are not
   stored anywhere the web can list (only the per-channel last result and per-health-key "told", E19).
10. **Push delivery is best effort** (E3, E8..E13, E18): no retry or outbox; a provider error is a journal line. Quiet-hours hold (E20) is
    the only queue.
11. **Jobs stream costs a subprocess per second per open stream** (polling `hs sys jobs tail`); it is a stream by shape only.
12. **Stream fan-out is unfiltered and lossy** (E1): every `changed` goes to every stream (all admin today; per-user filtering would need
    it), queue overflow drops silently with no resync signal.
13. **Two refresh vocabularies** (E2, E4): `AREA_GROUP` in web-serve.py and registry `topic:` flags in hs.sh must name the same groups by
    hand. Checked: `git grep -l AREA_GROUP -- tests` is empty, so no test compares them.
14. **Polls that ignore the stream** (E24): `changes.svelte.js` (5 min `setInterval`) and the Bottom panel reads have no topic.
15. **Two push paths, three with the media notifier** (E21, E22 against E3, E8..E13): notify.sh/channels versus vps/hs-watch.sh -> ntfy
    directly, and hs-media-notify.py -> Matrix. Quiet hours, channel choice and the journal line apply only to the first.
16. **Job record transitions publish nothing** (E17): the record is durable, but the web learns a job ended only by polling (or by
    `refresh --all` in Redis mode, E3, which is an invalidation and not "job X ended"). No reader row exists yet at a070a7c.
17. **No common event id or time format** (E9, E17, E18): state.db `events` has a `time` column, disk-events is `date TAB action TAB text`,
    the journal has its own timestamp, the job record uses ISO 8601 UTC. No shared id links a disk-events line to its state.db row or its
    push.
18. **`OnFailure` gives a push, no record and no refresh** (E7, E23) for timers that are not `hs_job`: the job record covers only `hs_job`
    units.

## 5. Questions for ADR #143

No answers here; the facts are from this audit.

1. Which rows are domain events that must be stored, and which are invalidations that may stay lossy?
   Domain or both: E3, E8..E13, E16..E18, E20..E24. Invalidation only: E1, E2, E4..E6, E15.
2. One durable store or several: state.db `events`, `/var/lib/hs/disk-events`, journal `hs-notify`, job records: merge, keep, or index?
   Four stores today (E9, E17, E18, gap 9), four formats (gap 17). Only state.db has a retention by count (2000); the job record has 200 or
   30 days; the journal has journald's.
3. Is the job record the model for other domain events (one writer, atomic files), or does a common log replace it?
   E17 has one writer, atomic files, a reconcile step at boot and states; it is Proposed, not accepted, and nothing reads it yet.
4. Does `/api/events` need ids and replay (Last-Event-ID), or is "re-read on reconnect" enough for invalidations?
   Today no `id:`, `gen` per topic only (E1, gap 3). The jobs stream already replays by offset (`?from=N`).
5. Lost-update risks: refresh only on success (`&&`, exit 0), refresh sent while hs-live is down, SSE queue overflow (web-serve.py Events,
   `queue.Queue(maxsize=256)` :1905) with no resync signal, off mode (no events at all). Which must be closed?
   E2 and E6 skip failures (gap 6); `hs:v1:refresh` is lost if nobody listens (E2); overflow is dropped silently (gap 12); off mode: gap 1.
6. Should "changed" mean "different" (compare `out` before bumping gen)?
   E1 bumps on every successful read (gap 4); `ct-list` re-fetches every 10 s for every open page.
7. Duplicates to remove: two disk logs; three push paths; `AREA_GROUP` versus registry `topic:` flags.
   E9 writes both a file and a DB row; push paths: notify.sh, vps/hs-watch.sh -> ntfy, hs-media-notify.py -> Matrix (E21, E22, gap 15);
   gap 13 for the vocabulary, with no test.
8. Push delivery: is best effort acceptable, or does a durable outbox (retry) belong to the store?
   No retry anywhere; quiet-hours hold (E20) is the only queue (gap 10); `chan_result_set` keeps only the last result (E19).
9. Which sources need daemon watchers (incus monitor, Docker events, ZED, systemd unit state) and are they in scope for 0.1?
   None exists (gap 8); `OnFailure` covers failed units only, not stopped containers or ZFS faults (E23, gap 18).
10. Who owns the event vocabulary (topic names, event kinds) across core, capabilities and packages (extension topics `ext-<n>-...`)?
    Topics: scripts/lib/live-topics.tsv (core) plus extension topics from hs_ext.py (E15); state.db kinds are in state-db.py; push
    categories are in notify.sh; the media notifier has its own event names (E21).

## Open questions

None yet. The design follows from this audit.
