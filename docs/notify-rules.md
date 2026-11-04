# Notification rules

Which events of the server's event log become a push message, and how. For owners who want to mute a kind or add a message, and for package authors.

## Before you start

- A running server with at least one notification channel ([Operations](operations.md)).
- Events come from scripts and helpers; the kinds are listed in the [event catalogue](events.md).

## How it works

The service `hs-event-notify` runs every 30 seconds. It reads the event log rows after its cursor, finds the first matching rule and calls
`hs notify` (channels, quiet hours and the journal line work as for every other message). Rows of the kind `notify.*` never trigger a message.
A new server starts at the newest row; history is not replayed. A crash can repeat the one message being sent; a failing send is logged
(`notify.failed`) and does not hold up the other rows.

The helpers next to the film apps run in containers. They write each event as a small file into `.hs-events` in the share `media`;
`hs-event-notify` takes only `pkg.<package>.*` kinds from there, never follows links and drops anything else.

## Mute a kind or add a message

Rules are tab separated rows: kind (or glob), category, priority, title, message. The core rows are in `scripts/lib/notify-rules.tsv`.
Put your own in `/var/lib/hs/notify-rules.d/10-own.tsv`; files there are read first, in name order, and the first match wins.

```bash
printf 'pkg.sabnzbd.queue-done\t-\t-\t-\t-\n' | sudo tee /var/lib/hs/notify-rules.d/10-own.tsv
```

Category `-` means silent. In title and message, `{key}` is a payload key or one of `kind`, `subject`, `level`, `text`.

## Matrix cards

`hs notify --payload-file <json>` hands the event payload to channels that can draw it. The provider `matrix` makes the card of the film apps
from it; other providers ignore it. `hs recipe matrix-hook` creates the channel `matrix`.

## Check that it worked

```bash
journalctl -u hs-event-notify -n 20
hs event list 20
```

Not tested on hardware yet.
