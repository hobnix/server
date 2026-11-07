# 0010: Service extensions: one supervised process, JSON lines both ways, events delivered at least once

Status: Proposed
Issue: hobnix/server#238 (epic #197). Command extensions are ADR 0009 (#237), permissions #239; neither is decided here.

## Context

- A command extension is one short process per call (ADR 0009). Some extensions need a process that stays: a collector that reads a device or
  an API every minute and publishes the newest state, or an event consumer that reacts to entries of the event log (ADR 0005), for example
  to send a message or to start a job.
- Today the only hook is the `sys ext <name> boot` row run by `hs-ext-boot.service` (docs/PLAN-extensions.md "At boot"): it must start
  something *outside* the core (a container) and return within 60 s. Nothing supervises it afterwards, nothing delivers events to it, nobody
  can see whether it still works. The live collector (`scripts/live-collect.py`) runs `hs sys ext ... <words>` on a timer: that covers a
  collector that is a periodic command, not one that holds a connection or state.
- Packages run as root (ADR 0008); what a service may touch is #239. This record only fixes the lifecycle and the messages.

## Decision

1. **A service extension is a package with a `[service]` table** in its manifest: `exec` (a command row's script, `@/file` or a path under
   `scripts/`, same rule as `commands.tsv`), `subscribe` (a list of event kind globs, empty for a pure collector), `health_interval`
   (seconds, 5 to 300, default 30). A package may have commands and a service. Reading the table is a follow-up (see Consequences).
2. **One supervised process per service.** The core runs it through ONE static unit template, `hs-ext-svc@<name>.service` (configuration.nix,
   like `hs-ext-boot.service`: no rebuild per package), whose `ExecStart` is the core's bridge (`hs ext svc-run <name>`; the reference is
   scripts/lib/ext_service.py). The unit restarts it with `Restart=on-failure`, `RestartSec=2`, and gives up after 5 starts in 10 minutes
   (`StartLimitBurst`): the unit is then `failed` and the core emits `ext.service-failed` (a core kind, to be registered with #238's follow-up).
   Backoff and restart are systemd's job, not the bridge's.
3. **Which services run.** A service runs while its package is on (`hs ext enable`) and it is not stopped by hand (`hs ext stop <name>`,
   which survives a reboot until `hs ext start <name>`). `hs ext boot` starts the instances of packages that are on; it does not wait for
   `ready`. Switching a package off stops its service first. A package that is off has no unit running.
4. **Messages are JSON lines, `v: 1`, on the service's stdout (to the core) and stdin (to the service).** stdin stays open for the life
   of the process. Schema: docs/api/ext-service-v1.schema.json. Framing, line limit (1 MiB) and the rule that stdout carries nothing else
   are those of ADR 0009; stderr goes to the journal.
   - core to service: `init` (`name`, `lang`, `subscribe`, `health_interval`), `event` (one log row), `shutdown` (`grace_ms`).
   - service to core: `ready`, `health` (`ok`, `text`), `ack` (`id`), `log`, `emit` (an event for the log), `snapshot` (`topic`, `data`).
5. **States** (decided by the core, shown by `hs ext status` and the web interface, never sent by a service):
   `starting` (process started, `init` sent), `running` (`ready` seen and the heartbeat is fine), `degraded` (`health` with `ok: false`, or no
   `health` for 3 times `health_interval`; it goes back to `running` with the next good `health`), `stopping`, `stopped`, `failed`.
6. **Start.** After `init` the service has 30 s to send `ready`; nothing but `ready` may come before it. No `ready` is `failed`
   (`start_timeout`) and the process is killed. A service starts doing its work only after `init`: it reads its configuration from files the
   way commands do (scripts/lib/setting.sh); `init` carries no secrets (ADR 0009 rule 9).
7. **Stop.** `shutdown` is written, stdin closed, and the service has `grace_ms` (10 s) to exit by itself. Then SIGTERM to the process
   group, 2 s later SIGKILL to the group: the same stop as a timeout in ADR 0009. The unit's `TimeoutStopSec` is above the sum.
8. **Health.** The service sends `health` at least every `health_interval` seconds, with `ok: false` and a one-line English `text` when it
   cannot do its work (device gone, API refuses). A missed heartbeat is `degraded`, not `failed`: a blocked service is a person's problem, a
   dead process is the unit's. The core never restarts a `degraded` service by itself.
9. **Event consumers: at least once, in order, with a cursor.** The core delivers rows of the event log (ADR 0005 `events` table) whose
   `source.kind` matches a `subscribe` glob, oldest first, as `event` messages carrying the log `id`. The service answers each with `ack`
   (its `id`) once it has *handled* it. The core keeps one cursor per package, the highest id such that it and everything before it was
   acknowledged or not subscribed, in `/var/lib/hs/ext-cursors/<name>` (an atomic write, runtime state in the sense of ADR 0002). After a
   restart delivery continues after the cursor, so an event that was delivered but not acknowledged comes again: **a consumer must be
   idempotent** (it may use `id` as the key). At most 100 events are unacknowledged at a time; the core pauses delivery until acks arrive. An
   `ack` for an id that was not sent is a protocol error. A cursor older than the oldest kept log row (retention, ADR 0005 rule 2) starts at the
   oldest row; the service gets `init` and can see the gap by `id` (a `resync` message is a later addition if needed).
10. **Collectors publish state by `snapshot`.** The core stores the newest `snapshot` per `topic` as the live topic `ext-<name>-<topic>`
    (docs/PLAN-extensions.md "Live reads") and serves it as a read; the previous one is replaced, nothing is kept as history. For history a
    collector uses `emit`, which the core writes with `hs event emit`, only for kinds declared in the package's `[[events]]`; the others are
    dropped with a warning. The service never opens state.db or Redis itself.
11. **Protocol errors fail the service** (not the core): a line that is not JSON or not valid for its type, a message before `ready`, an
    ack of an unknown id. The bridge stops the process as in rule 7 and exits 1; the unit restarts it under rule 2.
12. **Output limits.** One snapshot is at most 256 KiB; the core accepts at most 50 `emit` messages a minute per service and drops the rest
    with one `warn` log line a minute (a stuck loop must not fill the log, whose retention is 5000 rows).
13. **Reference and proof.** scripts/lib/ext_service.py is the supervisor of rules 4 to 9 and 11 (state changes, ready timeout, heartbeat,
    delivery with acks and the cursor file, shutdown, SIGTERM, SIGKILL) without systemd; tests/fixtures/ext-service/svc.py is a service
    speaking the protocol; tests/ext-service.sh covers them. Rules 2, 3, 10 (the topic store) and 12 are specified, not built.

## Consequences

- Easier: a long-running collector or an event consumer in any language, with the same framing as commands; supervision and restart
  come from systemd, not from a second supervisor in the core; the web interface can show a state per service.
- Harder: one more kind of package to test; at-least-once delivery puts idempotency on the extension author; a degraded service is
  visible but not repaired by the core.
- Follow-ups (not built here; the reference supervisor is not called by `hs`):
  1. `[service]` in package.toml and `pkg.py validate`; `hs ext svc-run|status|start|stop`; the unit template in configuration.nix (needs
     a NixOS review and a hardware run: "Not tested on hardware yet").
  2. A core reader of the event log for delivery (a Rust or Python helper reading state.db through the same function as `hs sys event list`)
     and the topic store for `snapshot`.
  3. Register `ext.service-failed` in scripts/lib/event-kinds.tsv and notify on it.
  4. What a service may touch (files, devices, network) is #239 and must be decided before a third-party service is installable.

## Open points

- Whether the 5-starts-in-10-minutes limit, 30 s ready window and 10 s grace fit real extensions; they are a first guess.
- A service that wants to act on the server (start a job, change a setting): it calls `hs` like any root process today; a request message
  with a permission check belongs to #239.
- Ordering across restarts of the same event for two services is not defined (each has its own cursor).
- Whether the core should read the log with a push (a counter bump, ADR 0005 rule 5) instead of polling once a second.
