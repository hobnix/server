# notifications

Push messages go to **channels** (name, provider, settings, minimum priority, quiet-hours rule, the message classes it carries); ntfy and
email are providers and several channels run in parallel. Plan, vocabulary, decisions of 2026-10-27:. Steps 1 and 2
are built (store, providers ntfy and email, message classes, the web page); webhook, telegram, matrix and atom are plans. No Apprise.

- Not on by default. On = named in `capabilities`, or `notifyUrl` / `notifyUrlSecond` / the runtime setting `notifications` set. The Setup
  checklist entry "Set up notifications" runs `hs config set notifications true` (no rebuild). `hs update` runs `channel migrate` once it is on.
- Channels: one file each in `/var/lib/hs/notify-channels/<name>.conf` (`key=value`), written only by scripts/notify-channel.sh
  (`hs notify channel list|show|add|set|remove|test|migrate|providers`; `hs sys notify channels|channel <name>|providers` are the plain
  lines for the web interface; `hs sys notify plan|start` = scripts/notify-change.sh, the changes of the page). Library: scripts/lib/channels.sh.
  The folder is 0700 and the files 0600 (root only); `hs notify` and `hs notify channel` run themselves through `sudo` when the caller
  cannot read the folder (`chan_need_root`). Secrets enter through stdin (`--secret key`), never argv, and are shown as `set`. They are NOT
  in the vault (the lock alarm must work while it is closed).
- Message classes (`categories` of a channel): `alarm` (alarm, lock, problem), `status` (ok, start, stop, info), `heartbeat`, `digest`.
  Default for a new channel: `alarm,status,digest`. A provider says what it can carry (`caps`). `heartbeat` bypasses the quiet hours, the
  minimum priority and the digest, is never held and is not written to the journal. `urgent` passes every minimum; a disabled channel is
  silent. A channel that ignores the quiet hours is not in the digest; one without `digest` never gets it.
- The old `heartbeatUrl` is derived as the channel `heartbeat` (ntfy, class heartbeat only) as long as there is no file of it; health-check.sh
  sends the heartbeat through `notify.sh --category heartbeat`. `remove heartbeat` clears the setting. vps/hs-watch.sh still reads the ntfy
  topic. scripts/lib/ntfy.sh is mirrored in the proxyserver repo and was NOT changed.
- Providers: `scripts/notify/<provider>.sh send <priority> <title> <body>` (settings as `CH_<key>` in the environment, `CH_CATEGORY`),
  `fields`, `check`, `where`, `caps`. Exit 0 delivered, 1 could not deliver, 2 not usable. The providers are the ONLY `curl` that sends a
  push message (ntfy through scripts/lib/ntfy.sh; email = `curl smtp://`, the login in a 0600 config file, never argv). A failing channel
  never blocks the others.
- Routing (quiet hours, digest, minimum priority) stays in scripts/notify.sh and scripts/lib/notify-route.sh, above the providers.
- Migration: while `/var/lib/hs/notify-channels/.migrated` does not exist, channels `main` (notifyUrl) and `second` (notifyUrlSecond,
  notifySecondMinPriority) are DERIVED in memory with `@setting:` references; the first change (or `migrate`) writes them as files. An
  upgrade therefore changes nothing and loses no alarm.
- At least one enabled channel that carries alarms should live outside this server (everything here is down while storage is locked):
  `list` shows `outside`; the page warns; the health check has the problem `notify:no-outside-channel` (only while the capability is on).
- Web: web/src/pages/Notifications.svelte (/operations/notifications), form web/src/forms/ops/ChannelForm.svelte; `READS` notify channels|providers
  and `CHANGES["notify"]` in scripts/web-serve.py.
- Tests: tests/notify-channel.sh, tests/web-notify-change.sh (+ web-notify-test.py), tests/notify-route.sh, tests/ntfy-style.sh.
