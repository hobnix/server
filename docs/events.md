# Event catalogue

The names, levels and payloads of the events that scripts write to the event log. For developers; the design is in ADR 0005 (docs/adr/0005-events.md).

## The list

The one list of core kinds is `scripts/lib/event-kinds.tsv`: one line per kind with the columns `kind`, `level`, `payload keys` and `meaning`. A script may emit
only a kind that is listed there (`tests/event-log.sh` fails otherwise). Add the line in the same change that adds the `event_emit`.

## Names

- A kind is `<area>.<what>`, lower case, digits and `-` only: `storage.missing`, `job.failed`, `notify.held`. The area is the part before the first dot
  and is stored as `source`.
- The name says what happened, in the past tense or as a state (`missing`, `failed`, `held`), not what to do.
- A package (a recipe or an extension) uses the prefix `pkg.<package>.`, for example `pkg.photos.indexed`. A package declares its kinds in `package.toml` `[[events]]` (see "Package events" below); the core file lists core kinds only.
- A kind is never renamed after a release, because stored rows and the web interface refer to it. Add a new kind and stop emitting the old one.

## Level

`info` for a fact, `warn` when someone should look soon, `error` when something failed. The level in the list is the default; a caller may pass
`--level` for one exceptional row. Choose by what the owner has to do, not by how interesting the event is.

## Subject and text

- `subject` is what the event is about, one token: a disk serial, a job id, a channel, a share name. The list says what it is when it is not obvious.
- `text` is one English line with key words only. The interface translates by `kind`, so never build a sentence the interface has to parse.

## Payload

The payload is optional extra data for programs. Rules:

- A flat JSON object. Keys are lower case words with `_`; values are strings, numbers or booleans (no nested objects, no `NaN`).
- The keys of a kind are listed in the third column, separated by commas. `-` means the kind has no payload. A key that is not always present is
  written with a `?` at the end, for example `reason?`.
- Facts only, no secrets (passwords, tokens, keys) and nothing that is already in `subject`.
- Keys are only added, never removed or given a new meaning. If that is not possible, add a new kind. The row field `v` is the version of the row layout, not of a payload.
- Keep it short: a payload over 1 KB is a sign that the data belongs in a file or a job record.

## Today

<!-- BEGIN generated from scripts/lib/event-kinds.tsv (python3 scripts/events-doc-gen.py write) -->

| Kind | Level | Payload keys | Meaning |
| --- | --- | --- | --- |
| `storage.new` | info | none | a disk was seen for the first time (plugged in) |
| `storage.back` | info | none | a missing disk is back |
| `storage.missing` | warn | none | a known disk is not there any more |
| `storage.worse` | warn | none | SMART values of a disk grew within the watch window |
| `storage.forgotten` | info | none | a missing disk was removed from the inventory on purpose |
| `storage.baseline` | info | none | first reading of the daily SMART check for a disk |
| `storage.smart-reset` | info | none | the SMART baseline of a disk was taken again |
| `storage.smart-watch` | info | none | the daily SMART check rates a disk as watch |
| `storage.smart-failing` | info | none | the daily SMART check rates a disk as failing |
| `storage.smart-healthy` | info | none | the daily SMART check rates a disk as healthy again |
| `job.queued` | info | none | a job was accepted and waits |
| `job.running` | info | none | a job started |
| `job.ok` | info | none | a job finished successfully |
| `job.failed` | error | `exit` | a job failed |
| `job.cancelled` | info | none | a job was stopped on purpose |
| `job.interrupted` | warn | none | a job was running when the server restarted |
| `notify.sent` | info | none | a push message was delivered to a channel (subject: the channel) |
| `notify.held` | info | none | a push message was held back (quiet hours) |
| `notify.failed` | warn | none | a push message could not be delivered |
| `disk.plugged` | info | none | a disk was plugged in (udev; subject: the kernel name) |
| `disk.removed` | warn | none | a disk was taken out (udev; subject: the kernel name) |
| `disk.other` | info | none | an old disk-events line with a label that is not known (import only) |
| `storage.pool-fault` | warn | none | a ZFS pool or one of its devices has a fault (ZED zedlet; subject: the pool; level error when a device is faulted or unavailable) |
| `live.collector-failed` | warn | none | a live-state read failed; the last good data stays served as stale (subject: the topic; once per change into error) |
| `live.collector-recovered` | info | none | a live-state read works again after a failure (subject: the topic) |
| `audit.ok` | info | `actor`, `exit` | a command that changes the system finished with exit 0 (hs dispatcher; subject: the words typed, never the arguments after them) |
| `audit.failed` | warn | `actor`, `exit` | a command that changes the system failed (hs dispatcher; subject: the words typed, never the arguments after them) |

<!-- END generated -->

## Package events (when installed)

A package (recipe or extension) may declare the events it provides in `package.toml`. The kind is written without the prefix: `kind = "failed"`
of the package `sabnzbd` is the event `pkg.sabnzbd.failed`.

```toml
[[events]]
kind    = "failed"                 # required; ^[a-z0-9][a-z0-9-]{0,39}$ (no dots); full kind pkg.<name>.failed
level   = "warn"                   # required; info | warn | error
label   = "Download failed"        # required; 1..60 chars, one line, no tab, not "-"
icon    = "warning-octagon"        # optional; ^[a-z0-9-]{1,40}$ (Phosphor icon name)
meaning = "a download failed (subject: the service)"   # required; 1..200 chars, one line, no tab, not "-"
payload = ["service", "name", "sub?"]   # optional; keys ^[a-z][a-z0-9_]{0,31}\??$, no duplicates
notify  = { category = "problem", priority = "high", title = "{name}: {label}", message = "{body}" }   # optional default rule
```

`notify`: `category` is required (alarm, lock, problem, ok, start, stop or info), `priority` is optional (min, low, default, high, urgent), `title`
and `message` are required (1..300 chars, one line; write a line break as the two characters `\n`). Unknown keys, a kind twice and a bad value
are problems: `hs pkg` refuses to install such a package, and `python3 scripts/pkg.py validate` and `repo-check` report them.

`hs pkg` writes the declaration to `/var/lib/hs/pkg-events/<package>.tsv` (10 tab-separated columns, `-` = empty; see
`scripts/lib/pkg_events.py`) and deletes it when the package is removed or a version declares no events. Four readers use it:

- the level of an event (`scripts/state-db.py`),
- the notification rules (`scripts/event-notify.py`; order: your drop-ins, the packages by name, the core file; see docs/notify-rules.md),
- the spool allowlist (a container may leave only events of packages that have a declaration),
- the catalogue below (core copy only).

If an event has no `label` or `icon` in its payload, the notification fills them in from the declaration.

Transition: the events of the media helper (`pkg.sabnzbd.*`, `pkg.maintainerr.*`) are kept as a copy in the same format in
`scripts/lib/pkg-events/` until hobnix/recipes declares them. An installed file of the same package replaces the copy completely.
The table is generated from that folder:

<!-- BEGIN package events generated from scripts/lib/pkg-events (python3 scripts/events-doc-gen.py write) -->

| Kind | Level | Payload keys | Meaning | Push message |
| --- | --- | --- | --- | --- |
| `pkg.maintainerr.planned` | info | `service`, `name`, `label`, `icon`, `title`, `sub?`, `body`, `fields?`, `footer?`, `poster_url?` | a lower version of a film was found and is announced (media helper; subject: the service) | info, default |
| `pkg.maintainerr.deleted` | info | `service`, `name`, `label`, `icon`, `title`, `sub?`, `body`, `fields?`, `footer?`, `poster_url?` | a lower version of a film was deleted (media helper; subject: the service) | info, default |
| `pkg.maintainerr.test` | info | `service`, `name`, `label`, `icon`, `title`, `sub?`, `body`, `fields?`, `footer?`, `poster_url?` | the test message of Maintainerr (Script) (media helper; subject: the service) | info, low |
| `pkg.sabnzbd.added` | info | `service`, `name`, `label`, `icon`, `title`, `sub?`, `body`, `fields?`, `footer?`, `poster_url?` | a download was queued (media helper; subject: the service) | info, low |
| `pkg.sabnzbd.unpacking` | info | `service`, `name`, `label`, `icon`, `title`, `sub?`, `body`, `fields?`, `footer?`, `poster_url?` | a download is being unpacked (media helper; subject: the service) | info, min |
| `pkg.sabnzbd.finished` | info | `service`, `name`, `label`, `icon`, `title`, `sub?`, `body`, `fields?`, `footer?`, `poster_url?` | a download finished (media helper; subject: the service) | ok, default |
| `pkg.sabnzbd.failed` | warn | `service`, `name`, `label`, `icon`, `title`, `sub?`, `body`, `fields?`, `footer?`, `poster_url?` | a download failed (media helper; subject: the service) | problem, high |
| `pkg.sabnzbd.queue-done` | info | `service`, `name`, `label`, `icon`, `title`, `sub?`, `body`, `fields?`, `footer?`, `poster_url?` | the download queue is empty (media helper; subject: the service) | info, low |
| `pkg.sabnzbd.disk-full` | error | `service`, `name`, `label`, `icon`, `title`, `sub?`, `body`, `fields?`, `footer?`, `poster_url?` | SABnzbd reports a full disk (media helper; subject: the service) | alarm, urgent |
| `pkg.sabnzbd.error` | warn | `service`, `name`, `label`, `icon`, `title`, `sub?`, `body`, `fields?`, `footer?`, `poster_url?` | SABnzbd reports an error (media helper; subject: the service) | problem, high |
| `pkg.sabnzbd.warning` | info | `service`, `name`, `label`, `icon`, `title`, `sub?`, `body`, `fields?`, `footer?`, `poster_url?` | SABnzbd reports a warning (media helper; subject: the service) | problem, default |
| `pkg.sabnzbd.test` | info | `service`, `name`, `label`, `icon`, `title`, `sub?`, `body`, `fields?`, `footer?`, `poster_url?` | the test message of SABnzbd (media helper; subject: the service) | info, low |

<!-- END generated -->

Not tested on hardware yet.
