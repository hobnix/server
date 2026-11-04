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
