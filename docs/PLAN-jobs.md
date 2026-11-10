# Plan: unified job system

Design record of epic #128 (Unified Job System). Contributor document, not a guide. The audit below is the factual base; the unified design follows it.

## Audit (2026-11)

Read-only inventory of today's job mechanism. Nothing in the code changed. It was written from Grep and partial reads on Windows; nothing was run on a server. Lines marked (unverified) were inferred, not seen and need a server check. Not tested on hardware yet.

### 1. The mechanisms today

| Mechanism | Where | What it is |
|---|---|---|
| `hs_job <slug> <desc> -- cmd...` | scripts/lib/job.sh | `systemd-run` transient unit `hs-job-<slug>-<HHMMSS>`, `OnFailure=hs-notify-failure@<unit>`, success push via notify.sh, env `HS_CALLER=job`, `HS_LANG`, `PATH`, plus `HS_JOB_ENV` lines and `HS_DISK_PASSPHRASE_FILE` (a path). Prints the unit name. Calls `live.sh refresh @jobs` at start and `--all` at end. |
| CLI `long` flag | scripts/lib/hs.sh `long_guard` (l.300) + registry flag `long` | On a terminal, warns and offers "run in background"; yes → `hs_job` with the whole command. `--foreground` skips. No offer when `HS_CALLER` is set or no tty. |
| Own CLI offers | manage-pool.sh `offer_job` (l.549, snapraid bulk only), ct-update-all.sh `--background`, docker.sh `as_job` (`--job`) | Same `hs_job`, own question. |
| Web `plan`/`start` | scripts/*-change.sh via web-serve.py `_change` (l.2439) | `start` prints `status started` + `unit` (job) or `status done` (ran inline, 60 s timeout in `_run`). `long yes/no` in the plan is display only; it does NOT decide job vs inline. |
| Scheduled jobs | configuration.nix `hs-*` services with `startAt` (+ `notifyFailure`) | Not `hs_job`; listed by `jobs.sh --list` (timers only). |
| Other systemd-run | system-change.sh l.110 (reboot/shutdown, delayed `--on-active`, name `hs-job-system-*` but NOT via hs_job: no OnFailure, no live refresh); backup.sh l.905 `hs-backup-browse` (`--collect`, a service not a job); ups.sh l.99 `hs-ups-deadline`; web-serve.py l.2574 unlock unit (`--wait`); web_terminal.py shells | Outside the job list (except the reboot unit while it waits/runs, as `hs-job-*`). |
| File manager | fm.sh `start` (l.770-797) | `hs_job fm-<op>` plus its OWN record in `/var/lib/hs/fm/jobs/` (see §3). Test modes use `nohup` + pid file. |

### 2. Commands with long-running or destructive work vs job

Legend: JOB = always a job; ASK = CLI offers a job (long_guard or own); FG = runs in the foreground / inline; WEB-INLINE = web start runs it synchronously inside the 60 s request.

#### Web interface (`hs sys <area> plan|start`)

| Area / action | Long or destructive | Job? |
|---|---|---|
| pool add/adopt/replace/remove/convert/close/open | destructive, long on snapraid | JOB (all actions, pool-change.sh l.116) |
| system sync/scrub/update/rollback/gc | long; rollback destructive | JOB |
| system reboot/shutdown | destructive | own delayed systemd-run, unit `hs-job-system-<action>-HHMMSS`, no OnFailure/notify |
| share * (all 15 actions incl. delete/purge/rollback/restore) | some destructive/long | JOB (every action, even toggles) |
| ct * (start/stop/…/delete/create/update/update-all) | update long, delete destructive | JOB (every action) |
| user * (all) | delete destructive | JOB (every action) |
| vault header-backup/move/close/secrets-fix | move long (unverified) | JOB |
| backup toggle/now/verify/prune/drill/browse/offsite-*/init | now/verify/prune/drill long, init destructive | JOB (every action, even toggle) |
| disk wipe / temp-copy / recover / move | destructive / long | JOB |
| disk test short\|long, forget, recover-finish | test long runs in drive firmware | WEB-INLINE (unverified for forget/recover-finish) |
| fm copy/move/delete… | long, delete destructive | JOB + own fm record |
| docker-app pull/rebuild/app-save/delete | long; delete destructive | JOB |
| docker-app start/stop/restart/recreate/app-write | `up -d` may pull images | WEB-INLINE (`timeout 30` on compose) |
| docker enable (docker-setup.sh) / gateway-setup | long (rebuild) | JOB (docker.sh `--job`, gateway-setup l.252) |
| services apply | long (rebuild/proxy) | JOB; all other services actions WEB-INLINE |
| dc renew | long-ish | JOB; dc ca WEB-INLINE (unverified) |
| recipe run | long | JOB |
| vps update | long | JOB; vps watch JOB too |
| admin cache-mover, fans-clean | long | JOB; test-push, pin-macs WEB-INLINE |
| jobs run <timer> | long | starts the timer's service (not hs_job) |
| pkg fetch | network, can be slow | JOB (`sys pkg start fetch` answers `status started` + `unit`; #388) |
| pkg repo-add | network, one repository | WEB-INLINE on purpose: the person needs the answer (accepted, or refused and not kept) at once; its plan says `long no` (#388) |
| pkg install/update/remove, repo-remove | install/update run code as root | WEB-INLINE (re-checked 2026-11-09 in scripts/pkg-change.sh: no `hs_job`) |
| config set/apply/sync/migrate, part enable/disable | effect at next rebuild | WEB-INLINE (no rebuild started) |
| node, peer (offer/add/attach/…), net setup, notify, ssh-key, expiry, health, docker-registry | short | WEB-INLINE |

#### CLI (`hs ...`, user rows of scripts/lib/registry.tsv)

| Command | Long / destructive | Job? |
|---|---|---|
| rows flagged `long`: cache-mover, backup now/drill/drill ct/verify/prune, temp-disk copy, disk temp copy, disk <d> recover, disk <d> move, ct <ct> update, pool <p> sync, system gc, docker enable, docker move-apps | yes | ASK (long_guard) |
| pool <p> add/replace/remove/convert/close/open | destructive, long | ASK only for bulk + snapraid (`offer_job`); ZFS: FG |
| ct update-all | long | ASK (`--background`/`--foreground`) |
| update, rebuild | long (minutes) | ASK (`long` flag, #388) |
| system update, system rebuild | long (minutes) | the web runs them as a job (system-change.sh); the CLI words are `hs update` / `hs rebuild` |
| storage incident replace | long, destructive | ASK (`long` flag; was missing from this table) |
| system rollback | destructive | FG |
| backup restore, backup init, backup offsite | long / destructive | FG |
| share <s> restore, share <s> rollback, share restore-kept, share cleanup, share repair | long / destructive | FG |
| ct <ct> restore, ct <ct> remove, ct add, ct <ct> storage remove | destructive / long | FG |
| disk <d> detach/attach, disk replace, disk <d> test, disk selftest, disk baseline run | long / destructive | FG |
| vault move | long (copies secrets) | ASK (`long` flag, #388; it asks nothing, so a job loses no question) |
| vault init, vault close | destructive | FG |
| user <u> remove, group <g> remove, user flush | destructive | FG |
| pkg install/update/remove, ext enable/disable | runs code / network | FG |
| pkg fetch | network | FG on the CLI (a few seconds to a minute; the web uses a job) |
| docker disable | destructive | FG (unverified whether docker.sh `as_job` is used for disable) |
| shutdown, reboot | destructive | FG (power.sh) |
| migrate, first-run, installer, preset apply | long | FG |

Scheduled (timers in configuration.nix, e.g. health-check every 15 min, `system gc` Sun 06:30, backup, bulk sync/scrub): run as their own `hs-*.service`, listed by `hs job list`, notify via `notifyFailure`.

### 3. The job record today (fields and storage)

There is no job record of its own. What exists:

| Field | Source | Stored where / how long |
|---|---|---|
| unit name `hs-job-<slug>-<HHMMSS>` | job.sh | systemd (transient). Successful transient units are unloaded when inactive (unverified: default CollectMode); failed ones stay until `reset-failed`/reboot |
| description (`hs pool bulk add data-3` …) | `--description` | systemd unit property |
| state running/ok/failed/never/unknown, exit status | jobs.sh `show_unit`/`tail_job` from `ActiveState`, `Result`, `ExecMainStatus` | systemd only; gone with the unit → `unknown` |
| started, last (exit time), next (timer) | `ActiveEnterTimestamp`, `ExecMainExitTimestamp`, timer `NextElapseUSecRealtime` | systemd; formatted `dd.mm. HH:MM` (no year) |
| command | `ExecStart` argv | systemd (inside `bash -c` wrapper, so it shows the wrapper, unverified) |
| log lines | journald `-u <unit>` (sudo lines filtered) | journal, journald retention |
| who started it | only web: `web change: <user>: <area> <args>` line in hs-web's journal; fm: `--by` in audit.log | not linked to the unit |
| key (area + args) for the button busy state | web/src/jobkey.js, `tasks` in web/src/ui.svelte.js | browser memory only; lost on reload, not shared between browsers |
| instant changes ("done-N") | `trackDone` in ui.svelte.js | browser memory only |
| fm job: files/bytes done+total, speed, eta, current, phase, result, pid, skipped/failed lists | fm.sh | `/var/lib/hs/fm/jobs/<id>.{state,sel,skipped,failed}`, `<unit>.alias`, `busy/`, `claims/`; `fm/audit.log` (time, by, op, from, to, counts, result) |

Readers: `hs sys jobs list|running|tail|--show|--log` (jobs.sh), `/api/sys/jobs/stream/<unit>` SSE (web-serve.py l.2267), BottomPanel.svelte (polls `jobs/running` 5 s, `jobs/list` 15 s), doctor.sh, overview-status.sh, health-check.sh (failed hs-* services). Control: `hs sys jobs plan|start stop|run` (jobs-change.sh; red confirm for pool/sync/scrub/backup-init/share-purge units).

### 4. Gaps

1. No history of `hs_job` jobs: `jobs.sh --list` shows timers only, `--running` only active units; a finished job is visible only by unit name while systemd still has it, or through the journal.
2. Unit names carry HHMMSS without a date: two runs of the same slug at the same time on different days share one journal unit name, so `tail`/`log` mix runs (unverified in practice). Same slug in the same second → `systemd-run` fails.
3. No initiator, source (cli/web/timer), arguments, or start/end time with year kept per job; the web audit line is not linked to the unit.
4. The web decides job vs inline per script, not from `long`: pkg fetch/repo-add say `long yes` but run inline (60 s request timeout); pkg install/update and docker-app start/restart/recreate (may pull) also inline.
5. Many cheap web actions are jobs (share/backup toggles, user/ct start-stop): fine for traceability, but every one is a systemd unit + notification "finished" push (unverified whether toggles push).
6. CLI: many destructive/long commands run in the foreground with no job offer (update, rebuild, rollback, backup restore, vault move, share restore/rollback, ct restore/remove, disk detach/replace, ZFS pool changes). The CLAUDE.md rule "offer a background job for long work" is not met there.
7. reboot/shutdown units use the `hs-job-` prefix but skip `hs_job` (no OnFailure, no @jobs refresh).
8. Browser Tasks list is per tab and in memory: after reload the button busy state and finished-task output are lost; jobs started elsewhere appear only while running.
9. Two job models: fm has a rich progress record on disk; every other job has only the journal. No common progress format.
10. Timestamps are `dd.mm. HH:MM` strings (no year, local time) in the machine-readable contract.
11. `HS_JOB_ENV` values land in the unit environment (`systemctl show -p Environment`, readable by root only); fine for answers, must never carry a secret (rule kept by convention only).

### 5. Checks on a server before the design is final

- `systemctl show hs-job-<x> -p CollectMode`, and whether a finished successful `hs-job-*` is still loaded (gap 1, section 3).
- `journalctl -u <same unit name>` across two days (gap 2).
- Read the start branches of docker disable, vault move and dc ca (marked unverified).

Risks: the tables come from Grep of `hs_job` calls and `long` lines, so an action that starts a job through another helper could be missing. Registry rows change often; rebuild the CLI table from `scripts/lib/registry.tsv` when the design is written.

## Unified design

Decided in #388 (2026-11-09), from the code on develop, not from a running server.

**The rule.** A job is right when the work is long, the person does not need to answer anything while it runs, and a closed terminal must not stop it. A command that asks mid-run (a typed name after a plan, a choice) stays in the foreground, because a job has no terminal and would lose the question (ADR 0018 plans the answer protocol for recipes). The CLI offers a job through the `long` registry flag (`long_guard`, scripts/lib/hs.sh): on a terminal only, never when `HS_CALLER` is set, `--foreground` skips, and since #388 `--dry-run`, `-h` and `--help` are not offered a job either. The web runs a change as a job when its `*-change.sh` calls `hs_job`; `long yes|no` in a plan is display only.

| Command | Decision | Why |
|---|---|---|
| `update`, `rebuild` | `long` flag: offer a job | minutes; the web already does the same through system-change.sh. In a job the questions of `update.sh` take their no-terminal answers (a beta or edge channel stops with exit 3 without `--yes`; a failed switch rolls back at once). |
| `vault move` | `long` flag | it asks nothing |
| `pkg fetch` (web) | job: `status started` + `unit` | long network read, the answer is only "done" |
| `pkg repo-add` (web) | stays inline, plan says `long no` | the person needs "accepted" or "refused, not kept" at once |
| `system rollback` | FG | destructive, asks, short once it runs |
| `backup restore`, `share restore|rollback`, `ct restore|remove`, `disk detach|replace` | FG for now | each asks a typed name or a choice after its plan; offering a job after the confirmation (as `manage-pool.sh offer_job` does for bulk pools) is the way, one command per change. Not done here. |

**Not verified:** the web path of `disk detach` and `disk replace` (scripts/disk-change.sh has `hs_job` only for `wipe` and `temp-copy`, so they probably run inline there); no row of this plan was checked on a running server with systemd. Step and progress reporting is #389.
