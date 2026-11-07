# Architecture decision records

One file per decision that is hard to undo: `NNNN-<slug>.md` (four digits, lower case slug). A record is never rewritten after it is
accepted; a later record supersedes it and both say so in their Status line. Longer plans stay in docs/PLAN-*.md; feature history stays in
docs/Entwicklungsnotizen.md.

## Shape

```
# NNNN: <decision in a few words>
Status: Proposed | Accepted (YYYY-MM-DD) | Superseded by NNNN
Issue: hobnix/server#<n>
## Context        what is true today, with file names
## Decision       numbered rules, each one testable
## Consequences   what gets easier, what gets harder, what follows (issues)
## Open points    what this record does not decide
```

## Records

| Record | Decision | Status |
| --- | --- | --- |
| [0001](0001-rust-strangler.md) | Rust grows behind the `hs sys` contract, one command group at a time | Proposed |
| [0002](0002-system-state-vs-runtime-state.md) | `store` in the schema separates declarative state (rebuild) from runtime state (at once) | Proposed |
| [0004](0004-job-record.md) | One JSON file per job in /var/lib/hs/jobs, written by the hs_job wrapper | Proposed |
| [0003](0003-binary-cache.md) | CI fills a Cachix binary cache; hosts use it as an optional extra source | Proposed |
| [0005](0005-events.md) | Domain events in one log (state.db `events`), invalidations as counters, the stream replays domain events | Proposed |
| [0006](0006-api-in-front-of-cli.md) | The `hs sys` contract is the API; the web interface is a client of it | Proposed |
| [0007](0007-branches-and-releases.md) | `develop` for work, `main` for releases, signed tags | Proposed |
| [0008](0008-capabilities-and-packages.md) | Capabilities with a contract; apps and optional parts are signed packages in their own repositories | Proposed |
| [0009](0009-capability-as-package-kind.md) | A capability is a third package kind; a short list stays in the core | Proposed |
