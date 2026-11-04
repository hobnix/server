# Event catalogue

The names, levels and payloads of the events that scripts write to the event log. For developers; the design is in [ADR 0005](adr/0005-events.md).

## The list

The one list is `scripts/lib/event-kinds.tsv`: one line per kind with the columns `kind`, `level`, `payload keys` and `meaning`. A script may emit
only a kind that is listed there (`tests/event-log.sh` fails otherwise). Add the line in the same change that adds the `event_emit`.

## Names

- A kind is `<area>.<what>`, lower case, digits and `-` only: `storage.missing`, `job.failed`, `notify.held`. The area is the part before the first dot
  and is stored as `source`.
- The name says what happened, in the past tense or as a state (`missing`, `failed`, `held`), not what to do.
- An extension uses the prefix `ext.<name>.`, for example `ext.photos.indexed`. These kinds are not listed in the core file.
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

| Area | Kinds | Subject | Payload |
| --- | --- | --- | --- |
| `storage` | new, back, missing, worse, forgotten, baseline, smart-reset, smart-watch, smart-failing, smart-healthy | the disk serial | none |
| `job` | queued, running, ok, failed, cancelled, interrupted | the job id | `failed`: `exit` |
| `notify` | sent, held, failed | the channel (`held`: the category) | none |
| `disk` | plugged, removed, other | the kernel name | none |

Not tested on hardware yet.
