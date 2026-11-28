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
| [0001](0001-rust-strangler.md) | Rust grows behind the `hs sys` contract, one command group at a time | Accepted (2026-11-10) |
| [0002](0002-system-state-vs-runtime-state.md) | `store` in the schema separates declarative state (rebuild) from runtime state (at once) | Accepted (2026-11-08) |
| [0003](0003-binary-cache.md) | CI fills a Cachix binary cache; hosts use it as an optional extra source | Accepted (2026-11-10) |
| [0004](0004-job-record.md) | One JSON file per job in /var/lib/hs/jobs, written by the hs_job wrapper | Accepted (2026-11-10) |
| [0005](0005-events.md) | Domain events in one log (state.db `events`), invalidations as counters, the stream replays domain events | Accepted (2026-11-10) |
| [0006](0006-api-in-front-of-cli.md) | The `hs sys` contract is the API; the web interface is a client of it | Accepted (2026-11-10) |
| [0007](0007-branches-and-releases.md) | `develop` for work, `main` for releases, signed tags | Accepted (2026-11-10) |
| [0008](0008-capabilities-and-packages.md) | Capabilities with a contract; apps and optional parts are signed packages in their own repositories | Accepted (2026-11-10) |
| [0009](0009-capability-as-package-kind.md) | A capability is a third package kind; a short list stays in the core | Accepted (2026-11-10) |
| [0010](0010-extension-command-protocol.md) | Command extensions speak versioned JSON lines over stdin/stdout, with a timeout and SIGTERM cancel | Accepted, implemented in 0.8 |
| [0011](0011-extension-service-lifecycle.md) | Service extensions: one supervised process, JSON lines both ways, events delivered at least once | Accepted, implemented in 0.8 |
| [0012](0012-roles-and-api-tokens.md) | Three roles (viewer, app manager, admin) checked in the web server; API tokens belong to a person | Accepted, implemented in 0.8 (no TOTP or SSO yet) |
| [0013](0013-cluster-state-and-partitions.md) | One owner per object, cached read-only copies, a partition degrades to stale (no consensus) | Accepted (2026-11-10) |
| [0014](0014-extension-permissions.md) | Extension permissions: declare and disclose first, confine services next (enforced in 0.8: events, services, opt-in commands) | Accepted, implemented in 0.8 |
| [0015](0015-wasm-runtime-for-extensions.md) | WebAssembly for extension scripts: defer; keep the extension protocol transport-neutral | Accepted (2026-11-10) |
| [0016](0016-isolating-package-web-components.md) | Package UI stays declarative; third-party code, if ever allowed, runs in a sandboxed iframe | Accepted (2026-11-10) |
| [0017](0017-capabilities-repository-and-channels.md) | hobnix/capabilities: vendored `module.nix` (pure evaluation), overlay on the machine, CI across repositories, wizard step, channels, release flow | Accepted (2026-11-10) |
| [0018](0018-interactive-recipe-runs.md) | Interactive recipe runs: an orchestrator job runs steps as sub-jobs, a step asks through a question/answer file protocol, the web talks to the orchestrator only | Accepted (2026-11-09) |
| [0019](0019-vm-gpu-pci-passthrough.md) | VM hardware step: detect IOMMU groups first, pass through by PCI address, bridge by default | Accepted (2026-11-10), unverified |
| [0020](0020-webui-package-builder.md) | The web package builder: a form over the CLI validator, drafts kept apart, publish by pull request or archive; never signs | Accepted (2026-11-10) |
| [0021](0021-graphical-vm-console.md) | Graphical VM console: Incus's own VGA console (SPICE) relayed through the web interface; no port, ticketed WebSocket | Accepted (2026-11-10), behind its switch |
| [0022](0022-first-run-console-token.md) | First-run web setup: one-time console token, single use, expiry, burn counter, bound to the local admin | Accepted (2026-11-10) |
| [0023](0023-nested-test-harness.md) | Hobnix-in-Hobnix: boot the ISO in a nested Incus VM, drive it over the serial console, manual CI job, `t vm` as fallback | Accepted (2026-11-10) |
| [0024](0024-import-proxmox-vzdump.md) | Proxmox vzdump import: read-only plan built, restore into an Incus instance and VM archives proposed | Accepted (2026-11-10), step 1 only |
| [0026](0026-live-state-one-mode-one-store.md) | Live state always on, one mode, one store: the state database instead of Redis; no `liveState` setting | Accepted (2026-11-13), measurement first |
| [0025](0025-translation-scope.md) | Where translation lives: `hs` commands, web, or both; freeze `de.tsv`, web translates, codes only where the web needs them | Accepted (2026-11-10) |
| [0027](0027-package-lifecycle-states.md) | Package lifecycle states: four stages (available, installed, on, running) and flags for every kind; `sys pkg states`; verbs Install/Remove/Update | Accepted (2026-11-16) |
| [0028](0028-error-codes.md) | Error codes: a `code` line beside `reason`, dotted names in one catalogue (error-codes.tsv, generated docs), exit numbers stay 0/1/other | Accepted |
| [0029](0029-component-gallery-instead-of-storybook.md) | The component gallery page (`Developer > Components`) instead of Storybook; triggers to revisit #193 | Accepted (2026-11-18) |
| [0030](0030-ui-sdk-for-the-map.md) | UI SDK for the Network Map: use it for behaviour, exact pin, one part at a time; +37 kB gzip for the first popover | Accepted (2026-11-21), spike result |
| [0031](0031-rust-extensions.md) | Rust extensions: `[[binary]]` shipping, one workspace per crate, SDK pinned by rev, dynamic user and state directory, hardening, no `hs` calls from a service, restart after update | Accepted (2026-11-24), design only |
| [0032](0032-rust-main-language.md) | Rust is the main language, Python is retired, bash stays for launcher, installer and recovery; packages may be Rust | Accepted (2026-11-24) |
| [0033](0033-core-and-daemon.md) | One Rust core with every operation, one daemon `hobnixd`, a Rust CLI and a web API without root (`hobnix-web`) over a local socket | Accepted (2026-11-26), the Decided items |
| [0034](0034-job-system.md) | Every change is a systemd job; records in SQLite beside the events; locks, credentials, cancel, failure and upgrade rules; history kept for years | Accepted (2026-11-26), the Decided items |
| [0035](0035-015-rust-release.md) | 0.15 is the Rust release (steps P0 to P8, a beta on the owner's server is the side-by-side release, no new features beside it); rules have no exceptions | Accepted (2026-11-28) |
