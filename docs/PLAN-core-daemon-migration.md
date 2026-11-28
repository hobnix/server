# Plan: migration map of Core and Jobs

Design record. Contributor document, not a guide. Step P0 of [PLAN-core-daemon.md](PLAN-core-daemon.md) (section 15.1), written 2026-11-26 on the
branch `0.14`. It says for every command, background service, timer, web route, stored file and package hook who owns it after the move, in which step
it moves, which test guards it and when the old part goes. Nothing here is built or run on a server. Not tested on hardware yet.

The records behind it are ADR 0033 (`docs/adr/0033-core-and-daemon.md`) (core and daemon) and ADR 0034 (`docs/adr/0034-job-system.md`) (job system), both
**Proposed**. Where this map picks an owner the plan does not name, the row says "map's reading" or lands in [Missing from the plan](#missing-from-the-plan);
such a row is a proposal for the owner, not a decision. The gaps the map first found are answered below the tables
([Missing from the plan](#missing-from-the-plan), step "P0, rest", #1337, 2026-11-27).

## How it was counted

All counts were made on 2026-11-26 in this repository, branch `0.14`, with the commands named. They are a first answer from `grep`, not a call graph.

| What | Source | Command | Count |
|---|---|---|---|
| Registry rows | `scripts/lib/registry.tsv` | `grep -v '^#' ... \| cut -f1 \| sort \| uniq -c` | 628 rows: 299 `sys`, 329 `user` |
| `sys` groups | the same file | second word of the path, `awk -F'\t' '$1=="sys"{split($2,a," "); print a[2]}' \| sort -u` | 70 groups |
| `user` groups | the same file | first word of the path | 73 groups |
| Rows that run Rust | the same file | `grep -c 'rust:'` (one header line left out) | 5 rows: `sys secrets plan\|start`, `sys remote codes\|claim\|accept` |
| Package rows in this repository | `capabilities/edge-status/commands.tsv` | `ls capabilities/*/commands.tsv` | 2 rows (`sys edge status`, `edge health`) |
| Units of our own | `configuration.nix`, `install.nix`, `capabilities/*/module.nix` | `grep -nE 'systemd\.(services\|timers)\.'` | 46 services (`hs-*` and `bulk-mount`; `install.nix` repeats `hs-web` and `hs-setup-code`), 26 of them timed (`startAt`, `OnCalendar`, `OnUnitInactiveSec`) |
| Other hooks of the system | the same files | `grep -nE 'udev\.extraRules\|zed\.d\|NOTIFYCMD\|interactiveShellInit'` | 2 udev rules, 1 ZED zedlet, 1 UPS hook, 2 shell init blocks |
| Web routes | `scripts/web-serve.py` `do_GET`, `do_POST` (lines 3187 to 3696) | read by hand | 35 path and method pairs (19 GET including static files, 16 POST) in 15 route groups below |
| Stored names | `scripts/`, `rust/*/src`, `capabilities/`, `configuration.nix` | `grep -rhoE '(HS_STATE_DIR...\|/var/lib/hs)/[A-Za-z0-9_.-]+'`, the same for `/run/hs`, `*.lock` | about 100 names below `/var/lib/hs`, 25 below `/run`; `/var/lib/hobnix` has **no** reference in the code |
| Database tables | `scripts/state-db.py` | `grep -n 'CREATE TABLE'` | 15 tables in `/var/lib/hs/state.db` |
| Package hooks | `docs/Package-API.md`, `docs/PLAN-packages.md`, `docs/extensions.md`, `scripts/lib/registry-load.sh` | manifest tables and loader rules | 15 kinds below |

Names below `/var/lib/hs` that are built from a variable inside a script (`$STATE/...`, `$st/...`) are only partly caught by the pattern; the stored files
table therefore lists groups, and a name found later goes into the group of its script.

## Rules that hold for every row

- **Front and logic move apart.** A `user` row is a human front: it moves to the Rust CLI in P5 (the plan allows it after P2) and calls the scripts until
  its area moved. The logic of the area (reads, plan, apply) moves into the core in P7. A `sys` row is retired when its last caller is gone (ADR 0033 D7).
- **Every change is a job** (ADR 0034 Decided 1). An area whose change is not a job today gains a record when it moves.
- **"Removed when" follows ADR 0001:** the characterization test passes on old and new, one release side by side, then the old part goes. Where a row
  says "P7", it means: after that release, when no caller of the area's rows is left. Scripts that stay go with P8 at the latest, as far as the bash rules
  of ADR 0032 decision 3 allow.
- **0.15 (ADR 0035, 2026-11-28):** all steps are in 0.15, and a 0.15 beta that has run on the owner's server is the one release side by side.
- **Test names** are files in `tests/` that exist today; a characterization test for a group that has none is written first (ADR 0001 "Must").
- Step **-** means the plan gives the part no move (it stays bash, Nix, or a package's own).

## Commands

Grouped by area. Each row covers the `sys` groups (row count in brackets) and the `user` groups named in it; together the rows cover all 70 `sys` and
73 `user` groups.

### Core foundations and jobs (P1, P2, P3)

| Rows | Current behaviour | New owner | Step | Test | Old part removed when |
|---|---|---|---|---|---|
| sys `event` (1), `audit` (1); user `event` (4), `audit` (1) | `event.sh` / `scripts/lib/event.sh` `event_emit` writes `state.db` `events` (best effort, rc 0); `audit.sh` writes `audit.ok`/`audit.failed` through it; `event-notify.sh` rows | core event writer (P1); history in `history.db` (P2); audit events stay until after P7 (ADR 0034 Decided 8) | P1, P2 | event-log, event-emitters, event-retention, event-topics, events-doc, audit | `hs event emit` stays as the bash path's entry until P8; the Python insert goes when the core owns the schema (P1) |
| sys `jobs` (12); user `job` (5), `jobs` (1, `jobs reconcile`) | `jobs.sh` reads systemd and the JSON records; `jobs-change.sh` stop and run (marks `cancelled` first); `jobs-answer.sh` (ADR 0018); `job-reconcile.sh` at boot; writer `hobnix job-record` with `job-record.py` fallback | core job module over SQLite; `hobnixd` job monitor | P2 (records, cancel, answer), P3 (monitor) | jobs, jobs-change, jobs-records, job-record, job-record-rust, job-reconcile, job-cancel, job-steps, hs-job, ask-protocol, web-jobrecords | `job-record.py` with #1268; the JSON files after the records moved and one release; `jobs-change.sh` and the unit-name risk list when every operation declares its cancel (P2) |
| sys `live` (5), `state reads`, `state read-put`, `state read-get` (3 of `state`); user `live` (2), `timing` (1) | `live.sh` refresh, status, inspect, raw, check; `hs-live` collector; `read-timing.sh`, `live-load.sh`, `live-measure.sh` measure it | core reads, `hobnixd` live-state actor (scheduling, watchers, subscriptions); still writes the `live` table until P6 | P3, values to memory after P6 | live-state, live-db, live-demand, live-e2e, live-hook, live-load, live-measure, change-counters, refresh-groups, web-live | the collector unit after its side-by-side release (P3); the table and the `read-*` rows after P6; `live measure` and `timing` are the measurement tools of section 14 and stay until the baseline is done |
| sys `registry` (1), `complete` (1) | the dispatcher answers the row list and shell completion (`scripts/lib/hs.sh`, cache `/run/hs/complete`) | Rust CLI (generated from the operation declarations) | P5 | commands, help-search | P8, with the shell dispatcher if unused |
| sys `ext` (2); user `ext` (8), `generate` (1), `pc` (4) | `ext.sh`: extension list, enable, start, logs; extension services through `ext_service.py`; `pc` and `generate` are `ext.sh` rows | core extension host (protocol types shared with the SDK); `hobnixd` supervises the services | P3 (may slip to the next milestone, plan 15.2) | ext, ext-proto, ext-service, ext-service-reach, ext-events, ext-confine, ext-state, ext-state-root, ext-sdk-rust, ext-sdk-examples | `ext_service.py`, `hs_ext.py`, `ext_proto.py`, `ext_confine.py` after one release with the Rust host |

### Apps and instances (P4 first, then P7)

| Rows | Current behaviour | New owner | Step | Test | Old part removed when |
|---|---|---|---|---|---|
| sys `apps` (8); user `apps` (2) | `apps-list.sh`, `apps-change.sh` (plan, start), `apps-recover.sh`, `apps-remove.sh`, `apps-version.sh`; `apps-policy.sh`, `apps-autoupdate.sh` | core operations; app start and stop is the end-to-end case of P4 (job, watcher, per-resource refresh, served through `web-serve.py` and a Rust-backed `sys` row) | P4 (start, stop), P7 (rest) | apps-change, apps-version, apps-autoupdate, app-health, web-apps | the `sys apps` rows after P6 and P7 |
| sys `ct` (14); user `ct` (24), `mac` (1) | `manage-ct.sh`, `ct-change.sh`, `ct-pools.sh`, `ct-bindings.sh`, `ct-access.sh`; `ct-guided.sh`, `ct-update-all.sh`, `import-vzdump.sh`; `mac.sh` | core operations over the Incus API (system access layer) | P7 | ct-change, ct-read, ct-pools, ct-bindings, ct-lock, ct-autostart, ct-update-all, ct-tailscale, import-vzdump, web-forms-instances | P7; guided dialogues with P5 |
| sys `recipes` (6); user `recipe` (2) | `recipes-list.sh`, `recipe-change.sh`, `recipe-asks.sh`, `recipe-steps.sh`, `recipes-versions.sh`; `recipe-orchestrate.sh` (ADR 0018) | core operation; the recipe SDK of #1219 builds on the job model | P7 (jobify parts: #1219 in Core and Jobs, plan 15.2) | recipe-change, recipe-pieces, ask-protocol, ask-long, steps, web-recipe-questions, web-recipe-wizard | P7 |
| sys `docker` (13), `docker-app` (2), `docker-registry` (2); user `docker` (12) | `docker.sh`, `docker-setup.sh`, `docker-app-change.sh`, `docker-registry-change.sh`, `docker-import.sh`, `import-unraid.sh`; all through `incus exec docker` | core operations; Docker reached as plan 4.2 says (open point 8) | P7 | docker-cap, docker-app-change, docker-app-doc, docker-gpu, docker-import, docker-migrate, docker-move-apps, docker-registry, web-docker-change, web-docker-apps | P7 |
| sys `iso` (4); user `iso` (3) | `iso.sh`, `iso-change.sh` | core | P7 | iso | P7 |
| sys `blueprint` (3), `preset` (3); user `blueprint` (3), `preset` (3) | `blueprint.sh`, `blueprint-change.sh`, `preset.sh`, `preset-change.sh` (presets also serve the installer) | core; the installer path of `preset.py` stays (PLAN-rust inventory) | P7 | blueprint, preset, preset-change | P7; the installer part stays bash/Python until PLAN-rust step 8 |

### Packages (P3 host, P7 manager)

| Rows | Current behaviour | New owner | Step | Test | Old part removed when |
|---|---|---|---|---|---|
| sys `pkg` (14); user `pkg` (17) | `pkg.sh`, `pkg.py` and `pkg_*.py`, `pkg-refresh.sh`, `pkg-change.sh`, `pkg-bundle.sh` | core package manager; `hobnixd` for extension services | P7 (plan 11 "Package manager") | pkg, pkg-change, pkg-change-perms, pkg-index, pkg-index-repo, pkg-repo, pkg-refresh, pkg-remove, pkg-deps, pkg-events, pkg-binary, pkg-blocks, pkg-slots, pkg-vendor, pkg-migrate, pkg-new, pkg-rows, pkg-restart, pkg-perms, pkg-bundle, pkg-community | P7; `pkg.py` per PLAN-rust step 5 |

### Storage (last, P7)

| Rows | Current behaviour | New owner | Step | Test | Old part removed when |
|---|---|---|---|---|---|
| sys `pool` (10); user `pool` (10), `bulk-mount` (1), `cache-mover` (1) | `manage-pool.sh`, `pool-list.sh`, `pool-state.sh`, `pool-change.sh`, `pool-import.sh`, `pool-record.sh`, `bulk-sync.sh`, `bulk-mount.sh`, `cache-mover.sh`; passwords to jobs as `/run/hs/job-pass.*` | core operations with declared locks (ADR 0034 Planned 10, 11); boot mount stays bash | P7, storage last | pool, pools, pool-change, pool-list, pool-state, pool-import, pool-record, pool-encrypted, pool-bare, pool-nopool, pool-add-df, pool-look, bulklock, bulk-sync-limits, bulk-sync-skip, bulk-switch, zfs-plan | P7; `bulk-mount.sh` stays (boot path) |
| sys `disk` (8), `disk-health` (1), `monitor` (1), `state` (15 of 18: disks, events, smart, problems, baseline, collect, forget, inventory, history, deck rows), `temp-disk` (1), `storage` (1); user `disk` (22), `temp-disk` (1), `monitor` (1), `zed-event` (1) | `disk-health.sh`, `disk-change.sh`, `disk-move.sh`, `disk-detach.sh`, `disk-event.sh`, `disk-spindown.sh`, `disk-replace.sh`, `disk-erc.sh`, `selftest.sh`, `state.sh` over `state-db.py`, `monitor.sh`, `storage-discover.sh`, `temp-disk.sh`, `zed-event.sh` | core reads over the system access layer (SMART, udev, ZFS); measurements in their own tables (plan 6.2 "Measurements are not events") | P7, storage last | disk-list, disk-event, disk-detach, disk-move, disk-wipe, disk-forget, disk-erc, disk-spindown, disk-recover, smart-baseline, state-db, monitor, storage-discover, zed-event, web-disk-change | P7; `disk recover` is a recovery command and stays bash |
| sys `shares` (16), `share` (2), `cache` (1); user `share` (14), `snapshots` (4) | `manage-shares.sh`, `share-overview.sh`, `share-change.sh`, `share-delete.sh`, `share-purge.sh`, `share-undelete.sh`, `share-parity.sh`, `share-cache.sh`, `create-share.sh`, `sync-shares.sh`, `share-snap*.sh`, `snapshots-auto.sh` | core operations (Samba through the system access layer) | P7 | share-change, share-delete, share-purge, share-restore, share-cleanup, share-overview, share-parity, shares-read, sync-shares, create-share, snapshots, snapshots-auto, web-forms-shares | P7 |
| sys `fm` (9); user `fm` (6) | `fm.sh`, `fm-cmd.sh`; own progress files beside the job record (ADR 0004) | core operations as jobs | P7 | fm, web-forms-fm, web-files-contract, web-files-selection | P7; the file manager's own state files when its jobs use the record |
| sys `incident` (3); user `storage` (4) | `storage-incident.sh`: recovery path | bash (ADR 0001 Stays: recovery); `--state` and plan rows may move (PLAN-rust inventory) | - | storage-incident, recover, locked-guard | stays |
| sys `unlock` (3), `encryption` (1), `vault` (3), `secrets` (2, already `rust:secrets`); user `unlock` (1), `vault` (9), `secrets` (2), `web` (1, `web-unlock-login.sh`) | `unlock.sh` (boot, stdin, alarm), `vault.sh`, `vault-change.sh` behind `hobnix secrets` | bash for unlock and vault (ADR 0032 decision 3); `secrets` is already core | - (secrets: done, P8 removes the fallback) | unlock-order, unlock-alarm, vault, vault-change, vault-change-rust, vault-consumers, crypt, luks-class, web-unlock, web-unlock-login | `vault-change.sh` after a server ran the binary (ADR 0001 "Pilot"); unlock stays |

### Backup (P7)

| Rows | Current behaviour | New owner | Step | Test | Old part removed when |
|---|---|---|---|---|---|
| sys `backup` (10); user `backup` (26) | `backup.sh` (restic), `backup-change.sh`; scheduled runs through `hs-backup*` units | core operations as jobs; scheduled runs are jobs (plan 5.1) | P7 | backup, backup-change, backup-config, backup-read, backup-report, backup-offsite, backup-vm, backup-drill-ct, backup-restore-datasets, backup-restore-owner, backup-state-restore, backup-newshares, backup-disk-hidden, web-backup-drill | P7 |

### People, access, security (P6 with the web, P7)

| Rows | Current behaviour | New owner | Step | Test | Old part removed when |
|---|---|---|---|---|---|
| sys `users` (8), `admin` (2); user `user` (11), `group` (5) | `manage-users.sh`, `user-access.sh`, `user-change.sh`, `users-show.sh`, `user-guided.sh`, `users-roles.sh`, `admin-change.sh` | core (rules), `hobnixd` (sign-in, sessions, roles) | P6, P7 | user-change, user-access, users-local, users-roles, admin-change, admin-user, web-forms-users, web-roles | P7 |
| sys `token` (3); user `token` (3) | `token.sh`, `token-change.sh`, `token_store.py` (`/var/lib/hs/api-tokens.json`) | `hobnixd` (ADR 0012 rules move to operations) | P6 | token, web-roles | with P6 |
| sys `ssh-key` (3); user `ssh-key` (3) | `ssh-key.sh`, `ssh-key-change.sh` | core | P7 | ssh-key, web-ssh-key, web-ssh-key-py | P7 |
| sys `dc` (3); user `dc` (5) | `dc-cert.sh`, `dc-change.sh` (domain controller) | core | P7 | dc-cert, dc-change | P7 |

### Network and services (P7)

| Rows | Current behaviour | New owner | Step | Test | Old part removed when |
|---|---|---|---|---|---|
| sys `services` (8), `routes` (2), `ports` (1); user `services` (16), `ports` (1) | `services.sh`, `services.py` (`ADMIN_TARGETS` guard), `services-change.sh`, `ports.sh`; service files in `/var/lib/hs/services.d` | core; the admin-route guard becomes a core rule | P7 | services, services-change, services-stats, services-traefik-public, services-zoraxy-api, declare-service, ports, traefik-provider, network-provider, web-routes, web-proxy | P7 |
| sys `gateway` (6); user `gateway` (5) | `gateway.sh`, `gateway-setup.sh`, `gateway_render.py` | core | P7 | gateway, gateway-setup, gateway-traefik, gateway-acme-token | P7 |
| sys `net` (4), `netmap` (3), `unifi` (4), `dns` (1); user `net` (5), `dns` (2) | `net-nics.sh`, `net-check.sh`, `net-change.sh`, `net-ip.sh`, `netmap.sh`, `netmap-counters.sh`, `unifi.sh`, `dns.sh` | core | P7 | net, net-change, net-check, netmap, netmap-counters, dns, web-netmap, web-netcheck | P7 |
| sys `remote` (5, three already `rust:`), `peers` (2), `node` (7), `vps` (2), `deck` (1); user `remote` (10), `node` (6), `vps` (1) | `remote.sh`, `hobnix pair` (codes, claim, accept), `peer-change.sh`, `node.sh`, `node-change.sh`, `node-remote.sh`, `vps-change.sh`, `vps.sh`, `deck-status.sh` | core: reads, changes and pairing (pairing is already in `hobnix-core` `pair`); the deck feed is `hobnixd`'s ([gap 1](#missing-from-the-plan)) | P7 | remote, remote-pair, node, peer-change, vps-watch, deck-status, web-node-change, web-nodes, web-vps, web-remote-code | P7 |

### Health, notifications, configuration, system (P3, P7)

| Rows | Current behaviour | New owner | Step | Test | Old part removed when |
|---|---|---|---|---|---|
| sys `health` (7), `status` (1), `motd` (1), `hardware` (1), `ups` (1), `expiry` (3); user `health` (6), `status` (1), `motd` (1), `ups` (1), `expiry` (3), `fans` (1) | `health-check.sh` (every 15 min), `health.sh`, `health-ack.sh`, `health-change.sh`, `overview-status.sh`, `motd.sh`, `hardware.sh`, `ups.sh`, `expiry.sh`, `expiry-change.sh`, `fans.sh` | core for checks and delivery, daemon for scheduling (plan 11 "Health and notifications"; own design first) | P7 (after its design) | health, health-zfs, overview-status, motd, ups, expiry, fans, web-health-change, web-health-info, web-expiry-change | P7 |
| sys `notify` (5); user `notify` (9) | `notify.sh`, `notify-channel.sh`, `notify-change.sh`; `event-notify.sh`/`event-notify.py` every 30 s | core delivery; event notifications move into `hobnixd` (P3); `hs-notify-failure@` stays independent (ADR 0034 Planned 14) | P3 (event notifications), P7 (channels) | notify-channel, notify-route, ntfy-style, event-notify, web-notify-change | `event-notify.py` and its timer after P3's side-by-side release; `notify.sh` stays for `hs-notify-failure@` |
| sys `config` (4), `setup` (3), `parts` (4), `rebuild` (1), `release` (3), `changes` (1); user `config` (7), `machine-merge` (1), `changes` (1), `setup-code` (1) | `config-read.sh`, `config-change.sh`, `config.sh`, `machine-sync.sh`, `machine-merge.sh`, `setup-list.sh`, `setup-change.sh`, `parts.sh`, `part-change.sh`, `pending-rebuild.sh`, `release-channel.sh`, `release-change.sh`, `changes.sh`, `setup-code.sh` | core (plan 11 "Configuration": own design first) | P7 | machine-toml, settings, schema, config-overlay, schema-overlay, apply-effect, setup-change, setup-list, pending-rebuild, release-channel, update-channel, changes, capabilities | P7 |
| sys `system` (7), `power` (2), `logs` (3); user `system` (5), `update` (2), `rebuild` (1), `reboot` (1), `shutdown` (1), `doctor` (1), `cleanup` (1), `report` (1), `smoke` (1) | `system-change.sh`, `system.sh`, `update.sh`, `update-preview.sh`, `rebuild.sh`, `power.sh`, `power-notice.sh`, `doctor.sh`, `cleanup.sh`, `system-updates.sh`, `report.sh`, `logs.sh`, `smoke.sh` | `hs update`, rollback and rebuild stay bash (ADR 0032 decision 3); reads (`doctor`, `cleanup`, `updates`, `report`, `logs`) to the core; an update does not run beside a job that cannot be interrupted (ADR 0034 Planned 10) | P7 for reads; - for update | system, system-change, system-updates, update-preview, update-rollback, power, power-notice, doctor, cleanup, logs, smoke, rebuild-checks, web-system-reboot | P7 for reads; update stays |
| sys `migrate` (2), `testlab` (3); user `migrate` (3), `testlab` (2), `installer` (3), `first-run` (1), `docs` (2), `cheatsheet` (1) | `migrate-unraid.sh`, `migrate.sh`, `migrate-check.sh`, `testlab.sh`, `testlab-change.sh`, `install-wizard.sh`, `answers.sh`, `install-restore.sh`, `first-run.sh`, `docs-build.sh`, `docs-verified.sh`, `cheatsheet.sh` | installer, first run: bash (stays); migration dialogue stays bash, parsers to the core (PLAN-rust); testlab: dev driver, stays; docs and cheatsheet: thin tools, stay ([gap 9](#missing-from-the-plan)) | - | migrate, migrate-unraid, import-unraid, install-wizard, install-restore, first-run, testlab, docs, docs-verified, cheatsheet | stays |

## Background services and timers

46 units of our own. "Timed" names the start rule. Timers are front ends in the plan (section 2: "timer -> CLI or core"); a scheduled run that changes
something becomes a job (plan 5.1). Decided by the owner (2026-11-27, [gap 2](#missing-from-the-plan)): the systemd timer stays and starts the
core operation of its area, so it moves in the step of its area and keeps working while `hobnixd` is stopped.

| Unit (file) | Current behaviour | New owner | Step | Test | Old part removed when |
|---|---|---|---|---|---|
| `hs-web` (configuration.nix, install.nix) | `web-serve.py` as root | `hobnix-web` (no root) and `hobnixd` | P6 | web-login, web-roles, web-live, web-cache, web-events | no route left in `web-serve.py` (P6), then P8 |
| `hs-live` (capabilities/live-state) | `live-collect.py`: reads, Docker and Incus watchers, `live` table | `hobnixd` live-state actor | P3 | live-state, live-db, live-e2e | after its side-by-side release (P3) |
| `hs-unit-watch` (configuration.nix) | `unit-watch.py`: marks topics of changed units | `hobnixd` watcher (systemd over D-Bus) | P3 | unit-watch | after its side-by-side release (P3) |
| `hs-event-notify` + timer, every 30 s | `event-notify.sh`/`.py`: matches events with `notify-rules.tsv`, calls `hs notify`, takes in package events from containers | `hobnixd` (event notifications) | P3 | event-notify | after its side-by-side release (P3) |
| `hs-ext-boot`, `hs-ext-svc@`, transient `hs-ext-run-<name>` | `ext.sh boot`, `ext.sh svc-run`, `ext_service.py` bridge | `hobnixd` extension supervisor; units stay systemd units | P3 (may slip) | ext-service, ext-service-reach, ext-confine | after one release with the Rust host |
| `hs-job-reconcile` (before `hs-web`) | `job-reconcile.sh` marks interrupted jobs at boot | core job module; the `hobnixd` job monitor does the same after a daemon restart | P2, P3 | job-reconcile | when the records are in SQLite and the monitor runs (P3) |
| transient `hs-job-<slug>-<HHMMSS>` | `hs_job` (job.sh) | core job module, systemd runs the unit (ADR 0034 Decided 2) | P2 | hs-job, job-record | P2 for the writer; `hs_job` stays for bash paths that run without the binary |
| `hs-notify-failure@` | `notify.sh` on any failed timer unit | stays independent of the daemon (ADR 0034 Planned 14) | - | notify-channel | stays |
| `hs-backup` 04:00, `hs-backup-drill` 15th, `hs-backup-drill-ct` 22nd, `hs-backup-report` 25th | `backup.sh now/drill/report --scheduled`, then `live.sh refresh` | timer calls the backup operation as a job | with backup (P7) | backup, backup-drill-ct, backup-report | P7 |
| `hs-bulk-sync` (every `syncEveryHours`), `hs-bulk-scrub` Sun 05:00, `hs-cache-mover` every 15 min | `bulk-sync.sh`, `cache-mover.sh --if-full` under `/run/hs-bulk.lock` | timer calls the storage operation as a job with declared locks | with storage (P7, last) | bulk-sync-limits, bulk-sync-skip, bulklock | P7 |
| `hs-share-snapshots` hourly, `hs-sync-shares` 03:35, `hs-remote-mount` every 2 min | `snapshots-auto.sh run`, `sync-shares.sh` + `manage-shares.sh --measure`, `remote.sh mount-all` | timer calls the share operation as a job; `remote` unassigned | with shares (P7) | snapshots-auto, sync-shares, remote | P7 |
| `hs-state-collect` minutely, `hs-smart-baseline` 03:05, `hs-selftest-short` Sat 03:10, `hs-selftest-long` 03:15, `hs-fm-trash-empty` 03:35 | `state.sh collect`, `state.sh baseline-run`, `selftest.sh`, `fm.sh trash-empty` | core reads (collect is a routine health read, not a job); self-tests and trash emptying are jobs | with storage and health (P7) | state-db, smart-baseline, fm | P7 |
| `hs-health-check` every 15 min | `health-check.sh` (or `edge-health.sh` on an edge node) | core checks, daemon scheduling (plan 11) | with health (P7) | health | P7 |
| `hs-apps-autoupdate` :00 and :30, `hs-pkg-refresh` daily, `hs-system-gc` Sun 06:30 | `apps-autoupdate.sh`, `pkg-refresh.sh`, `system.sh gc 30 --yes` + `apps-version.sh --summary` | timer calls the core operation as a job | with apps, pkg, system (P7) | apps-autoupdate, pkg-refresh, system | P7 |
| `hs-mac` 03:30 (capabilities/incus) | `mac.sh` | core (instances) | P7 | none found by name; write one first | P7 |
| `hs-deck-status` every 20 s, `hs-deck-api`; `hs-edge-status` every 10 s, `hs-edge-api` (edge-status); `hs-edge-watch` every 5 min (edge-watcher) | `deck-status.sh` and `state.sh *-json` into `/run/hs-deck`, `deck-serve.py` on port 9740; `edge-status.sh`; `vps/hs-watch.sh` | deck feed (`hs-deck-status`): `hobnixd`; `deck-serve.py` (`hs-deck-api`, `hs-edge-api`) stays a server of its own until `hobnix-web` can serve the deck API; the edge units stay unchanged until P7 | P7 | deck-status, edge-facts, vps-watch | `hs-deck-status` after one release side by side with the daemon's feed |
| `hs-unlock`, `hs-unlock-alarm`, `bulk-mount`, `hs-disk-erc`, `hs-disk-spindown`, `hs-pci-bind`, `hs-boot-notice`, `hs-shutdown-notice`, `hs-setup-code` | boot and shutdown paths: `unlock.sh --boot/--alarm`, `bulk-mount.sh`, `disk-erc.sh apply`, `disk-spindown.sh apply`, PCI bind script, `power-notice.sh`, `hs setup-code boot` | bash or core per unit ([gap 3](#boot-and-shutdown-units)) | per unit | unlock-order, unlock-alarm, disk-erc, disk-spindown, power-notice, first-run | per unit |
| `hs-disk-event@` (udev rule), ZED zedlet `all-hobnix.sh`, UPS `NOTIFYCMD` | `disk-event.sh <action> <name>`, `zed-event.sh`, `ups.sh event` | the hooks stay and start the core operation of their area; `hobnixd` only watches for refreshes ([gap 4](#missing-from-the-plan)) | P7 (storage; UPS with health) | disk-event, zed-event, ups | the hooks stay; their scripts at P7 |
| `hs-nss-warm` minutely (samba, "temporary") | inline script: warms winbind and DNS lookups, logs slow ones | **goes** ([gap 10](#missing-from-the-plan)) | - | none found by name | after a week of a real server's journal shows no slow lookup |
| `hs-web-tailscale` | inline script: `tailscale serve` for the web port | Nix (thin wrapper) | - | none found by name | stays |
| `hs-testlab-nightly` 03:30 (testlab) | `testlab.sh run` | dev tool, stays | - | testlab, testlab-live | stays |
| Units of other software: `incus`, `incus-startup`, `samba-smbd`, `samba-winbindd`, `zfs-mount`, `traefik`, `postfix`, `tailscaled`, `nftables`, `sshd` | Nix sets `whenUnlocked`, `OnFailure` and service options | Nix; "the system owns its state" (plan 1) | - | rebuild-checks | stays |
| Shell init (zsh and bash in configuration.nix) | `hs motd` at SSH login, `hs sys complete` for completion | Rust CLI | P5 | motd, commands | P8 with `sys complete` |

## Web routes (`scripts/web-serve.py`)

| Route group | Current behaviour | New owner | Step | Test | Old part removed when |
|---|---|---|---|---|---|
| static files, `/theme.css`, `/favicon.svg`, `GET /api/hello` | frontend files and theme from `HS_WEB_ROOT` | `hobnix-web` | P6 | web-login, web-redirects | P6 |
| `POST /api/login`, `/api/logout`, `/api/setup`; `GET /api/session`, `/api/sessions`; `POST /api/sessions/end`, `/end-others` | sign-in (`ntlm_auth`, `unix_chkpwd`), sessions in `/run/hs-web/sessions.json`, CSRF, first setup (`first_run.py`) | `hobnixd` checks sign-in and keeps sessions; `hobnix-web` cookies and request protections | P6 | web-login, web-roles, first-run, web-first-run-steps | P6 |
| bearer tokens on every route | `_bearer_refused`, `TOKEN_CHANGE_ALLOWED` | `hobnixd` | P6 | token, web-roles | P6 |
| `GET /api/sys/<words>` (allowlist `READS`), `POST /api/plan`, `/api/start` (allowlist `CHANGES`) | runs `hs sys` as a subprocess with role check, short cache, warm-up thread | `hobnixd` runs core operations over the socket, route group by route group with P7 | P6 with P7 | web-ratchet, web-cache, web-plan-cache, web-plan-dialog, web-roles, openapi | when no `sys` row is called (P6, P7) |
| `GET /api/events`, `POST /api/events/subscribe`, `/api/live/refresh`, `/api/live/sample` | SSE: domain events with replay, `changed` from counters, push socket `/run/hs/live.sock`, demand | `hobnix-web` SSE fed by `hobnixd` subscriptions | P6 | web-events, web-live, live-demand, change-counters | P6, then the counters table goes |
| `GET /api/sys/jobs/stream/<unit>`, `/api/logs/stream/<unit>`, `/api/netmap/stream` | journal and samples as SSE | live connections: `hobnix-web` streams, `hobnixd` decides who may open one (plan 11) | P6 | web-progress, logs, web-netmap | P6 |
| `POST /api/terminal`, `GET /api/terminal/ws`, `POST /api/vmconsole`, `GET /api/vmconsole/ws` | `web_terminal.py` (pty in a transient unit, tmux), `web_vmconsole.py` (SPICE relay, ticket) | live connections as above | P6 | web-terminal, web-terminal-pty, web-vmconsole | P6 |
| `POST /api/unlock` | `hs sys unlock stdin`, passphrase on stdin, only while locked | `hobnix-web` route; unlock logic stays bash; must work while storage is locked (plan 9) | P6 (route) | web-unlock, web-unlock-login | P6 for the route; `unlock.sh` stays |
| `POST /api/remote/claim`, `/api/remote/push` | pairing door without a session (another server types a code) | `hobnix-web` route; pairing logic in the core | P6 (route), P7 (rest of remote) | web-remote-code, remote-pair | P6 for the route |
| `GET /api/proxy/status` | reverse proxy status thread | core (services) | P6 | web-proxy | P6 |
| `GET /api/poster/<name>` | pictures from `/var/lib/hs/posters` | `hobnix-web` (files), core (apps) | P6 | web-apps | P6 |
| `GET /api/docs/<path>` | the built docs site | `hobnix-web` | P6 | web-docs | P6 |
| `GET`/`POST /api/changes/seen` | per-user last seen changelog revision | `hobnixd` (per-user state) | P6 | web-changes | P6 |
| `GET /api/settings-layout` | settings overlay layout | `hobnix-web` (generated from the core's settings) | P6 | web-settings-layout | P6 |
| `GET /api/board` | dashboard tiles, also without a session on a private address (`dashboardOpen`) | `hobnix-web` with `hobnixd` check | P6 | web-board | P6 |
| background threads (lines 2116 to 2890) | warm-up, events watcher and lease, push listener, netmap sampler | `hobnixd` (live state) and `hobnix-web` (streams) | P6 | web-events, web-netmap | P6 |
| `deck-serve.py` (`hs-deck-api`, port 9740) | serves `/run/hs-deck/*.json` | a server of its own until `hobnix-web` can serve the deck API | after P6 | deck-status | when `hobnix-web` serves the deck API |

## Stored files

What the backup does today: `scripts/backup.sh` `host_files` copies `/var/lib/hs` (except the disk mount points), `/var/lib/hs-ext`,
`/var/lib/private/hs-ext`, `/var/lib/samba/private`, `/var/lib/hs-gateway/acme` and, while the vault is open, the vault secrets. Plan 6.1 asks for each
stored file whether it is backed up or can be rebuilt: see [Backed up or rebuildable](#backed-up-or-rebuildable).

| Store | Current behaviour | New owner | Step | Test | Old part removed when |
|---|---|---|---|---|---|
| `state.db` `events`, `rollups` | event log (5000 rows, 90 days), monthly package counts; file copy in backup | core, moved to `history.db` with the ids kept, SQLite backup | P2 | event-log, event-retention, state-db | after the move and one release |
| `state.db` `live`, `topics`, `heartbeat`, `demand`, `live_delay`, `reads` | live documents and counters; rebuildable (ADR 0026) | `hobnixd`; memory after P6 | P3, P6 | live-db, change-counters | after P6 |
| `state.db` `disks`, `smart`, `baseline`, `samples`, `usage`, `hours`, `meta` | disk inventory, SMART readings (400 days), fill levels, schema version | core measurements (plan 6.2); they stay in `state.db` at P2, backed up ([gap 5](#missing-from-the-plan)) | P7 (storage, health) | state-db, smart-baseline, capacity | the health and notifications design (#1380) decides |
| `/var/lib/hs/jobs/<id>.json` | job records (ADR 0004); backed up as files | core, rows in `history.db` | P2 | job-record, jobs-records | after the records moved and one release |
| `/var/lib/hs/api-tokens.json`; `/run/hs-web/sessions.json`, `cache.json`, `probe.tsv` | token hashes (0600, before unlock); sessions in tmpfs; web caches | `hobnixd` (security) | P6 | token, web-login, web-cache | P6 |
| `/var/lib/hs/settings`, `machine.toml.before-*`, `machine.toml.built`, `generated`, `capabilities-on`, `last-rebuild-rev`, `last-rebuild-seconds`, `update-channel`; `/run/hs-machine-cache` | runtime settings (ADR 0002), copies before a change, rebuild marks, a 30 s cache of `machine.toml` answers | core (configuration); rebuild and update marks stay with bash `hs update` | P7 | settings, machine-toml, update-channel, pending-rebuild | P7 |
| `/var/lib/hs/packages`, `pkg-events`, `pkg-index-state`, `installed.toml`, `ext`, `ext-svc`, `ext-emit`; `/var/lib/hs-ext`, `/var/lib/private/hs-ext`; `/run/hs-ext-cred` | installed packages, their event declarations, extension service state and cursors, private key copies for `LoadCredential` | core package manager, `hobnixd` extension host | P3, P7 | pkg, pkg-events, ext-state, ext-service | with the host (P3) and `pkg.py` (P7) |
| `/var/lib/hs/services.d`, `services.state`, `ports-admin`, `ports-expected`, `gateway-setup.before` | service descriptions (written by recipes and people), route state | core (services) | P7 | services, declare-service, ports, gateway-setup | P7 |
| `/var/lib/hs/notify-channels`, `notify-url`, `notify-held`, `notify-rules.d`, `heartbeat-url`, `matrix-hook`, `event-notify.cursor`, `event-notify.lock`, `.event-notify-payload`, `health.state`, `health-ack`, `expiry` | channels, quiet-hours queue, rules, notifier cursor, health state and acknowledgements | core (delivery), `hobnixd` (event notifications) | P3, P7 | notify-channel, event-notify, health, expiry | P3 for the cursor, P7 for the rest |
| `/var/lib/hs/disks` (mount points), `disk-key`, `disk-events`, `detached`, `disk-used`, `wear-cache`, `spindown-power.tsv`, `scrub.state`, `parity-skip`, `parity-limits`, `sync-refused`, `bulk-closed`, `recovering`, `adopting`, `removals`, `removed`, `incident-paused`, `selftest.state`, `disk-tests`, `share-sizes`, `snapshots-off`, `remote-mounts` | storage state; `disk-events` is the old log ADR 0005 imports once | core (storage), recovery marks with bash | P7 (last) | disk-event, bulk-sync-skip, storage-incident, share-parity, disk-spindown | P7; `disk-events` once imported |
| `/var/lib/hs/vault-header`, `vault-uuid`, `vault-binds`, `luks-uuids`, `luks-headers`, `restic-password`; `/var/lib/hs-vault` | vault and encryption metadata, secrets (restic password excluded from the backup) | bash (unlock and recovery) and `scripts/lib/secret.sh` | - | vault, crypt, luks-class | stays |
| `/var/lib/hs/backup.state`, `backup-dump`, `backup-offsite.env`, `.backup.lock`; `/run/hs-backup.lock` | backup results, dump commands, offsite settings, locks | core (backup) | P7 | backup, backup-offsite | P7 |
| `/var/lib/hs/apps`, `apps-autoupdate.json`, `apps-autoupdate.lock`, `stat-<app>`, `recipe-*`, `posters`, `blueprints.toml`, `iso`, `docker-registries.tsv`, `docker-registry-<host>`, `docker-manager-legacy`, `docker-manager-undo`, `unifi`, `migrate.state` | app, recipe, blueprint, ISO, Docker and migration state | core (their areas) | P7 | apps-autoupdate, blueprint, iso, docker-registry, migrate | P7 |
| `/var/lib/hs/first-run.json`, `setup-choice`, `pci-bind.log`, `testlab`, `testlab-marker`, `docs-site`, `metrics`, `live-measure-<date>` | first run, boot log, dev lab, docs build, metrics capability, measurement results | first run and boot: bash; docs and testlab stay; metrics goes with health ([gap 9](#missing-from-the-plan)) | - (metrics: P7) | first-run, testlab, docs, live-measure | stays; metrics P7 |
| `/var/lib/hs/nodes.tsv`, `vps-key`, `tailscale-authkey`, `deck-history`, `remote-offers`, `remote-<peer>.cred`, `.remote.lock`; `/run/hs/remote-codes.json`; `/run/hs-deck/*` | nodes, VPS key, pairing, deck history and feed | core (remote, nodes, VPS); deck history and feed: `hobnixd` | P7 | remote, remote-pair, deck-status, node | P7 |
| `/run/hs/ask/<id>/` | questions and answers of waiting jobs (ADR 0018) | core job module | P2 | ask-protocol | P2 |
| `/run/hs/job-pass.*`, `job-unraid-pass.*` | passwords handed to a job as temporary files | systemd credentials (ADR 0034 Planned 11) | P2 | pool-change, migrate-unraid | P2 |
| `/run/hs-bulk.lock`, `disk-event.lock`, the record locks of `job-record.py` and `token_store.py` | `flock` locks | core locks held by the job process (ADR 0034 Planned 10) | P2 | bulklock, disk-event | when no bash path takes them (P8) |
| `/run/hs/storage-locked` | mark that the storage is locked | bash (unlock) | - | locked-guard | stays |
| `/run/hs/live.sock`, `live-load.json`, `live-push.json` | push datagram socket and live load numbers | `hobnixd` socket (open point: shape and permissions) | P3 | live-load, web-live | P3 |
| `/run/hs/complete`, `/run/hs/fuse-bin`, `/run/hs/temp-*`, `/run/hs-auth.*`, `/run/hs-apps` | completion cache, backup mount helper, temporary disks, registry login, app run files | their areas | with their area | commands, backup, docker-registry | with their area |
| `/var/lib/hobnix` | no reference in the code (grep over `scripts/`, `rust/`, `capabilities/`, `*.nix`, `pkgs/`) | - | - | - | - |

## Package hooks

| Hook | Current behaviour | New owner | Step | Test | Old part removed when |
|---|---|---|---|---|---|
| `commands.tsv` user rows (`ext <name> ...`, owned `words`) | loaded by `registry-load.sh` into the dispatcher | Rust CLI loads them | P5 | pkg-rows, commands | P8 with the dispatcher |
| `commands.tsv` `sys` rows (`sys ext <name> ...`, `sys <word> ...`) | `sys` contract rows of a package, plan/start pairs | core package manager: a new way to declare operations (plan 10, #1379); package contract change with a deprecation release | before P8 | pkg-rows, openapi | when the replacement has survived its deprecation release |
| `protocol = [1]` command rows, `timeout:`, `confine` (ADR 0010, 0014) | JSON lines over stdin and stdout, run by `ext_proto.py` | core extension host (same message types as the SDK) | P3 | ext-proto, ext-confine | after one release with the Rust host |
| `[service]` (ADR 0011, 0031) | one supervised process, `hs-ext-run-<name>`, events at least once, cursors | `hobnixd` extension supervisor | P3 | ext-service, ext-service-reach, ext-events | as above |
| `[[binary]]` (ADR 0031) | Rust extension binaries | core package manager | P7 | pkg-binary, ext-sdk-rust | - |
| `[[events]]` with `retention` | kinds installed to `/var/lib/hs/pkg-events/<package>.tsv`; classes `ephemeral`, `audit`, `metric` | core; classes become `ephemeral`, `normal`, `important`, `metric`, stored on the row (ADR 0034 Decided 6, Planned 15) | P2 | pkg-events, event-retention | after the deprecation release of `audit` |
| `[[web.reads]]`, `[[web.changes]]`, `[[web.actions]]` with `role` | allowlist entries of a package, role at least the row's (ADR 0012 decision 9) | operations with roles in `hobnixd` | P6 | web-roles, pkg-perms | P6 |
| `[web.page]`, blocks, tabs, state, slots | declarative package pages (`pkg_blocks.py`, `pkg_slots.py`) | core package manager, `hobnix-web` serves them | P6, P7 | pkg-blocks, pkg-slots, web-blocks, web-slots | P7 |
| `[app]` (`routes`, `uses`, `update`, `remove`, `health`, `backup`, `version`), `[[health]]` | the app contract (level 9) read by `pkg.py`, `apps-*.sh`, `app_health.py` | core (apps, health) | P7 | apps-change, app-health, pkg | P7 |
| `[[ask]]` and recipe `# ask:` headers, `ask_q` | questions before and during a recipe run (ADR 0018) | core job module (questions), recipe SDK (#1219) | P2, P7 | ask-protocol, recipe-change | P7 |
| recipe scripts (`scripts/recipes/_lib.sh` and the recipes in their repository) | run as a job by `recipe-change.sh` and `recipe-orchestrate.sh` | the package's own; the core runs them as jobs | P2 (job), recipe SDK later | recipe-change, recipe-pieces | - |
| `[integrations.*]` and `permissions` | integration keys handed by `LoadCredential`, permissions declared and confined (ADR 0014) | core package manager, `hobnixd` | P3, P7 | pkg-perms, pkg-change-perms, ext-confine | P7 |
| `[[probe]]` | smoke probes of a package (`pkg_probes.py`, `smoke.sh`) | core | P7 | smoke | P7 |
| service files in `services.d` written by recipes; events from containers (`hs-media-notify.py` emitting `pkg.<package>.*`) | written into the core's state, read by `services.py`; events taken in by `event-notify` | core (services); `hobnixd` (event intake) | P3, P7 | services, event-notify | P7 |
| capability `module.nix` (vendored, ADR 0017) | Nix modules of capabilities | Nix | - | capabilities, capabilities-vendor | stays |

## Missing from the plan

The parts the map found without an owner or a step, each with its answer (#1337, 2026-11-27). "Owner decided" means the maintainer chose it on that day.
"Map's reading" follows from the plan, the decision records and the code; it is confirmed with the review of this change, not before.

| # | Gap | Answer | Owner and step | Source |
|---|---|---|---|---|
| 1 | **Remote, edge and displays** (`remote`, `peers`, `node`, `vps`, `deck` rows; `hs-deck-status`, `hs-deck-api`, `hs-edge-status`, `hs-edge-api`, `hs-edge-watch`, `deck-serve.py`, `vps/hs-watch.sh`; the routes `/api/remote/claim` and `/api/remote/push`; `nodes.tsv`, `deck-history`, `/run/hs-deck`) | ADR 0033 item 22 is confirmed: the reads and the pairing go to the core, the deck feed to `hobnixd`, `deck-serve.py` stays a server of its own until `hobnix-web` can serve the deck API. The edge-node units stay unchanged until they move | core and `hobnixd`, P7 (after 0.15) | Owner decided. That the changes of these areas are core operations too follows from D1 |
| 2 | **Timers** | systemd timers stay and start the core operation (through the CLI or the core, plan section 2) of their area. A scheduled change is a job. They keep working while `hobnixd` is stopped. Not timers of this kind: the polling programs that move into the daemon (`hs-event-notify` at P3, and the deck feed `hs-deck-status` by gap 1) | the area of each timer, in that area's step | Owner decided. The two exceptions follow from step P3 and gap 1 |
| 3 | **Boot and shutdown units** | none of them needs the daemon; [which part is bash and which is core](#boot-and-shutdown-units) | per unit | Map's reading |
| 4 | **Event sources outside the daemon** (the udev rules that start `hs-disk-event@` and `hs-disk-spindown`, the ZED zedlet, the UPS `NOTIFYCMD`) | the hooks stay, keep firing and start the core operation of their area. The operation they start is the producer of its events (plan 7 rule 4); the `hobnixd` watcher only sends refresh signals. The UPS countdown unit `hs-ups-deadline` stays with its hook | core; storage at P7, UPS with health at P7 | Owner decided (the hooks stay, the daemon only watches). The producer rule is the map's reading |
| 5 | **Measurement tables** (`disks`, `smart`, `baseline`, `samples`, `usage`, `hours`, with `meta`) | they stay in `state.db` at P2; P2 moves only events, job records and their daily totals to `history.db`. They are backed up, so `state.db` needs a safe SQLite backup too, not only `history.db`. Where they live later is part of the health and notifications design | core; no move in 0.15; design #1380 | Owner decided |
| 6 | **Backed up or rebuildable** for each stored file (plan 6.1) | [the table below](#backed-up-or-rebuildable) | core | Map's reading |
| 7 | **Lock files beyond the bulk lock** | [the list below](#lock-files); which of them the core takes over and the fixed order are decided with the job system | core, P2 (#1339, ADR 0034 open point 7) | List: read in the code |
| 8 | **Package `sys` rows** | packages get a new way to declare operations before `sys` can go; it needs a deprecation release | core package manager, before P8 (#1379) | Map's reading |
| 9 | **Docs, cheatsheet, testlab, metrics** | `docs build`, `docs verified` and `cheatsheet` **stay** as thin tools; their `user` rows get the Rust front at P5 like all others, and they change when the command list comes from the core (`sys registry`, P5 to P8). `testlab` and `hs-testlab-nightly` **stay** (a development tool). `/var/lib/hs/metrics` is written by `health-check.sh` and moves with health; the `metrics` capability stays Nix | stays; metrics: core, P7 | Map's reading |
| 10 | **`hs-nss-warm`** | **goes**, after the journal of a real server (`journalctl -t hs-nss-warm --since -7d`) shows no slow lookup over a week. Until then it stays unchanged. Not checked on a server yet | removed by a change of its own, outside the steps of the move | Owner decided |
| 11 | **Measurement of section 14** | **baseline taken** on 2026-11-27: both runs and the latency, on `v0.13.0-beta.2` with the script of #1333 ([section 14.2](PLAN-core-daemon.md#142-baseline-of-a-real-server-before-any-port) of the plan). **Open:** the build time of `hobnix` on a server, and the Ctrl-C check of the script (box in the tracker "Hardware test: 0.14", #1366) | the owner of the server | - |
| 12 | **The move of events out of `state.db`** into `history.db` | it is part of step P2, with the event ids kept | core, P2 (#1340) | Plan section 15, step P2 |

### Boot and shutdown units

Map's reading. All stay systemd units, and none may need `hobnixd` to run.

| Unit | Logic | Step |
|---|---|---|
| `hs-unlock`, `hs-unlock-alarm` | bash, stays (unlock, ADR 0032 decision 3) | - |
| `bulk-mount` | bash, stays (boot path of the storage) | - |
| `hs-pci-bind` | stays the script inside the Nix module: it runs before the pools are imported | - |
| `hs-setup-code` | stays with the first run (bash) | - |
| `hs-boot-notice`, `hs-shutdown-notice` | `power-notice.sh` stays bash; it sends through `notify.sh`, which stays for alerts without the daemon | - |
| `hs-disk-erc`, `hs-disk-spindown` | the logic moves to the core with storage; the unit stays and calls it. `unlock.sh` still starts the units of `/etc/hs/unlock-units` | P7 |
| `hs-ext-boot` | extension host. Whether the unit stays or the daemon's supervisor starts the enabled services itself is part of that step's design | P3 (#1341; may slip) |
| `hs-job-reconcile` | see its row in the table of units above | P2, P3 |

### Backed up or rebuildable

The class says what a backup must hold; this table does not change what `scripts/backup.sh` copies today. Classes:

- **backed up:** it cannot be made again, or it is a person's choice.
- **rebuildable:** the server makes it again; a lost copy costs time, not data.
- **left out:** kept out of the backup on purpose.
- **not kept:** in `/run`, gone at a reboot.

**A name that is not listed here is backed up until somebody shows that it can be rebuilt.** The classes are the map's reading from the code and the
names of the files, except the measurement tables (owner decided). No restore was run for this table. Not tested on hardware yet.

| Stored (below `/var/lib/hs` unless a path is given) | Class |
|---|---|
| `state.db`: `events`, `rollups` (move to `history.db` at P2) | backed up |
| `state.db`: `disks`, `smart`, `baseline`, `samples`, `usage`, `hours`, `meta` | backed up |
| `state.db`: `live`, `topics`, `heartbeat`, `demand`, `live_delay` | rebuildable (ADR 0026) |
| `state.db`: `reads` (written by nobody since ADR 0026) | rebuildable |
| `jobs/<id>.json` | backed up |
| `api-tokens.json` | backed up |
| `settings`, `capabilities-on` and `capabilities-off`, `update-channel`, `setup-choice`, `first-run.json` | backed up |
| `machine.toml.before-*` | backed up |
| `machine.toml.built`, `last-rebuild-rev`, `last-rebuild-seconds`, `generated/` | rebuildable (from the next rebuild or the installed packages) |
| `packages/` (installed packages, the repository indexes and their serial floor), `pkg-events` | backed up |
| `ext`, `ext-svc`, `ext-emit`, `/var/lib/hs-ext`, `/var/lib/private/hs-ext` | backed up (the packages' own state and cursors) |
| `services.d`, `services.state`, `ports-admin`, `ports-expected`, `gateway-setup.before`, `/var/lib/hs-gateway/acme` | backed up |
| `notify-channels`, `notify-url`, `notify-rules.d`, `notify-held`, `heartbeat-url`, `matrix-hook`, `media-ntfy`, `event-notify.cursor`, `health.state`, `health-ack`, `expiry` | backed up |
| `disks/` (mount points of the pool disks) | left out (the data on the disks has its own backup rules) |
| `detached`, `recovering`, `adopting`, `removals`, `removed`, `incident-paused`, `bulk-closed`, `sync-refused`, `parity-skip`, `parity-limits`, `snapshots-off`, `remote-mounts`, `scrub.state`, `selftest.state`, `disk-tests`, `disk-events`, `spindown-power.tsv` | backed up (marks and history of this disk set) |
| `disks-seen`, `share-sizes`, `disk-used`, `wear-cache` | rebuildable (a later run records or measures them again) |
| `disk-key`, `vault-binds`, `vault-header`, `luks-headers`, `zoraxy-admin`, `grafana-admin`, `dc-ca*`, `cf-dns-api-token`, `/var/lib/hs-vault` secrets, `/var/lib/samba/private` | backed up (a secret in the vault only while the vault is open) |
| `vault-uuid`, `luks-uuids` | backed up; a restore skips them on purpose (`state_skip`) |
| `restic-password`, `restic-offsite-password`, `backup-offsite.repo`, `backup-offsite.credentials` and their copies in the vault | left out (they protect or name the backup itself) |
| `backup-offsite.env`, `backup-on`, `backup-off`, `backup-rules/`, `backup-dump` | backed up |
| `backup.state` | rebuildable (later runs write it again) |
| `backup-inventory/`, `backup-dc/` | rebuildable on the running server; they stay in the snapshot, because a lost server is rebuilt from that copy |
| `apps`, `apps-autoupdate.json`, `recipe-*`, `posters`, `blueprints.toml`, `docker-registries.tsv`, `docker-registry-<host>`, `docker-manager-legacy`, `docker-manager-undo`, `unifi*`, `migrate.state` | backed up |
| `iso/` (while the ISO library is in its default folder) | backed up (an uploaded image may not be available again) |
| `dhcp-ranges` | rebuildable (`hs net setup` writes it again from the router) |
| `nodes.tsv`, `vps-key`, `node-key-*`, `tailscale-authkey`, `remote-offers`, `remote-<peer>.cred` | backed up |
| `deck-history` | rebuildable (it holds the last 24 hours) |
| `pci-bind.log`, `live-measure-<date>` | backed up (cannot be recorded again) |
| `docs-site/`, `metrics/`, `reports/`, `testlab/` (runs, ISO cache, golden systems) | rebuildable |
| `/run/hs-web/*`, `/run/hs/*`, `/run/hs-deck/*`, `/run/hs-ext-cred`, `/run/hs-apps`, `/run/hs-machine-cache` | not kept |

Seen while classifying, read in the code and not in a snapshot: of `/var/lib/hs` the host snapshot leaves out only the disk mount points and the backup's
own secrets, so rebuildable folders such as `testlab/` (with its cached ISO images, where the test lab is used) are copied too. Leaving them out is a
change to the backup and is not decided here.

### Lock files

Read in the code on 2026-11-27 (`flock` in `scripts/`, file locks in `rust/`; development tools left out). The column "Takes over" is the map's reading
and an input for #1339.

| Lock | Held for | Takes over |
|---|---|---|
| `/run/hs-bulk.lock` | work that changes the pool: sync, scrub, cache mover, share and disk changes | core job module, the same file as bash (plan 5.2), from P2 |
| `/run/hs-backup.lock` (`.backup.lock` when `/run` is not writable) | a backup run and other writes to the repository | core, with backup (P7) |
| `apps-autoupdate.lock` | one automatic update run | core, with apps (P7) |
| `packages/index/<name>/.lock` | everything that writes a repository index or runs git for it | core package manager (P7) |
| `testlab/lock` | one test lab run | stays with the test lab |
| `jobs/<id>.lock` (`job-record.py`, `hobnix job-record`) | one write of one job record | goes when the records are in SQLite (P2) |
| `api-tokens.json.lock` | one write of the token store | `hobnixd` (P6) |
| the `.lock` beside the pairing code store (`rust/hobnix-core/src/pair.rs`) | one read and write of the codes | already in the core |
| the extension state folder itself (`ext_state.py`) | moving a package's state folder | extension host (P3) |
| `disk-event.lock` | one disk event at a time | core, with storage (P7) |
| `event-notify.lock` | one notifier run | goes with the notifier (P3) |
| `.remote.lock` | one mount setup of a remote share | core, with remote (P7) |

`scripts/backup.sh` does not name the bulk lock. Whether any run holds two of these locks at once was not traced; the fixed order of plan 5.2 needs that
first (#1339).
