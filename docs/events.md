# Event catalogue

The names, levels and payloads of the events that scripts write to the event log. For developers; the design is in ADR 0005 (docs/adr/0005-events.md).

## The list

The one list is `scripts/lib/event-kinds.tsv`: one line per kind with the columns `kind`, `level`, `payload keys` and `meaning`. A script may emit
only a kind that is listed there (`tests/event-log.sh` fails otherwise). Add the line in the same change that adds the `event_emit`.

## Names

- A kind is `<area>.<what>`, lower case, digits and `-` only: `storage.missing`, `job.failed`, `notify.held`. The area is the part before the first dot
  and is stored as `source`.
- The name says what happened, in the past tense or as a state (`missing`, `failed`, `held`), not what to do.
- A package (a recipe or an extension) uses the prefix `pkg.<package>.`, for example `pkg.photos.indexed`. These kinds are not required in the core file; the core lists only those of the media helper that it ships (`pkg.sabnzbd.*`, `pkg.maintainerr.*`).
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
| `pkg.maintainerr.planned` | info | `service`, `name`, `label`, `icon`, `title`, `sub?`, `body`, `fields?`, `footer?`, `poster_url?` | a lower version of a film was found and is announced (media helper; subject: the service) |
| `pkg.maintainerr.deleted` | info | `service`, `name`, `label`, `icon`, `title`, `sub?`, `body`, `fields?`, `footer?`, `poster_url?` | a lower version of a film was deleted (media helper; subject: the service) |
| `pkg.maintainerr.test` | info | `service`, `name`, `label`, `icon`, `title`, `sub?`, `body`, `fields?`, `footer?`, `poster_url?` | the test message of Maintainerr (Script) (media helper; subject: the service) |
| `pkg.sabnzbd.added` | info | `service`, `name`, `label`, `icon`, `title`, `sub?`, `body`, `fields?`, `footer?`, `poster_url?` | a download was queued (media helper; subject: the service) |
| `pkg.sabnzbd.unpacking` | info | `service`, `name`, `label`, `icon`, `title`, `sub?`, `body`, `fields?`, `footer?`, `poster_url?` | a download is being unpacked (media helper; subject: the service) |
| `pkg.sabnzbd.finished` | info | `service`, `name`, `label`, `icon`, `title`, `sub?`, `body`, `fields?`, `footer?`, `poster_url?` | a download finished (media helper; subject: the service) |
| `pkg.sabnzbd.failed` | warn | `service`, `name`, `label`, `icon`, `title`, `sub?`, `body`, `fields?`, `footer?`, `poster_url?` | a download failed (media helper; subject: the service) |
| `pkg.sabnzbd.queue-done` | info | `service`, `name`, `label`, `icon`, `title`, `sub?`, `body`, `fields?`, `footer?`, `poster_url?` | the download queue is empty (media helper; subject: the service) |
| `pkg.sabnzbd.disk-full` | error | `service`, `name`, `label`, `icon`, `title`, `sub?`, `body`, `fields?`, `footer?`, `poster_url?` | SABnzbd reports a full disk (media helper; subject: the service) |
| `pkg.sabnzbd.error` | warn | `service`, `name`, `label`, `icon`, `title`, `sub?`, `body`, `fields?`, `footer?`, `poster_url?` | SABnzbd reports an error (media helper; subject: the service) |
| `pkg.sabnzbd.warning` | info | `service`, `name`, `label`, `icon`, `title`, `sub?`, `body`, `fields?`, `footer?`, `poster_url?` | SABnzbd reports a warning (media helper; subject: the service) |
| `pkg.sabnzbd.test` | info | `service`, `name`, `label`, `icon`, `title`, `sub?`, `body`, `fields?`, `footer?`, `poster_url?` | the test message of SABnzbd (media helper; subject: the service) |

<!-- END generated -->

Not tested on hardware yet.
