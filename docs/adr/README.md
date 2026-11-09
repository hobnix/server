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
| [0002](0002-system-state-vs-runtime-state.md) | `store` in the schema separates declarative state (rebuild) from runtime state (at once) | Accepted (2026-11-08) |
| [0003](0003-binary-cache.md) | CI fills a Cachix binary cache; hosts use it as an optional extra source | Proposed |
| [0004](0004-job-record.md) | One JSON file per job in /var/lib/hs/jobs, written by the hs_job wrapper | Proposed |
| [0005](0005-events.md) | Domain events in one log (state.db `events`), invalidations as counters, the stream replays domain events | Proposed |
| [0006](0006-api-in-front-of-cli.md) | The `hs sys` contract is the API; the web interface is a client of it | Proposed |
| [0007](0007-branches-and-releases.md) | `develop` for work, `main` for releases, signed tags | Proposed |
| [0008](0008-capabilities-and-packages.md) | Capabilities with a contract; apps and optional parts are signed packages in their own repositories | Proposed |
| [0009](0009-capability-as-package-kind.md) | A capability is a third package kind; a short list stays in the core | Proposed |
| [0010](0010-extension-command-protocol.md) | Command extensions speak versioned JSON lines over stdin/stdout, with a timeout and SIGTERM cancel | Proposed |
| [0011](0011-extension-service-lifecycle.md) | Service extensions: one supervised process, JSON lines both ways, events delivered at least once | Proposed |
| [0012](0012-roles-and-api-tokens.md) | Three roles (viewer, app manager, admin) checked in the web server; API tokens belong to a person | Proposed |
| [0013](0013-cluster-state-and-partitions.md) | One owner per object, cached read-only copies, a partition degrades to stale (no consensus) | Proposed |
| [0014](0014-extension-permissions.md) | Extension permissions: declare and disclose first, confine services next (options; nothing enforced yet) | Proposed |
| [0015](0015-wasm-runtime-for-extensions.md) | WebAssembly for extension scripts: defer; keep the extension protocol transport-neutral | Proposed |
| [0016](0016-isolating-package-web-components.md) | Package UI stays declarative; third-party code, if ever allowed, runs in a sandboxed iframe | Proposed |
| [0017](0017-capabilities-repository-and-channels.md) | hobnix/capabilities: vendored `module.nix` (pure evaluation), overlay on the machine, CI across repositories, wizard step, channels, release flow | Proposed |
| [0019](0019-vm-gpu-pci-passthrough.md) | VM hardware step: detect IOMMU groups first, pass through by PCI address, bridge by default | Proposed |
| [0021](0021-graphical-vm-console.md) | Graphical VM console: Incus's own VGA console (SPICE) relayed through the web interface; no port, ticketed WebSocket | Proposed |
