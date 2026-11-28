# 0032: Rust is the main language, Python is retired

Status: Accepted (2026-11-24). Later: ADR 0033 (accepted 2026-11-26, Decided items) changes parts of this record, see "What changes in older records on acceptance" there. Until a step is built, this record applies as written. ADR 0035 (accepted 2026-11-28) changes what "one release side by side" means for 0.15 (decision 4).
Issue: hobnix/core#1189 (epic: Rust as the main language). Related: ADR 0001 (strangler), ADR 0015 (Wasm), ADR 0031 (Rust extensions: shipping, SDK pin, service rules), docs/PLAN-rust.md, docs/PLAN-package-sdk.md, docs/CODE-PRACTICES.md.

## Context

- The core is bash, Python and Rust. ADR 0001 moves code to Rust "when we touch it and it makes sense" and says shell and Python have no deadline for removal.
- Two interpreted languages beside Rust mean three toolchains for contributors and agents, and structured data handled in two other languages than the one that owns the contracts.
- Packages (recipes, capabilities, extensions) are written in shell and TSV today. ADR 0001 decision 5 left them out of scope; the extension protocol (ADR 0010, 0011) and the Rust SDK exist since 0.8.

## Decision

1. Rust is the main language for the core, the tools that ship with it and the packages we write in `hobnix/official`.
2. Python is retired. No new Python program; each existing one gets a target release when the inventory of PLAN-rust.md step 1 is done; the last one leaves the server image and the dev environment with it.
3. Bash stays only where ADR 0001 lists it: launcher, installer and first run, unlock and recovery, `hs update` and rollback, thin wrappers around one external command, `ui.sh` dialogues. These paths must work when the Rust binary is missing.
4. ADR 0001's method is unchanged: the `hs sys` contract is byte for byte stable, a move needs a characterization test and one release side by side, and a move can be undone by one registry line. Decision 5 of ADR 0001 (packages out of scope) is amended: packages may be written in Rust, using the package SDK, and the protocol stays language-neutral.
5. Replacing `scripts/web-serve.py` needs its own record (ADR 0001 decision 4); this record does not decide it. That record is planned for 0.14.
6. The `hs` dispatcher stays a bash launcher until everything behind it is Rust; then a later record decides whether it moves. The command is renamed `hs` to `hn` in the planned rename milestone (`hs` stays as an alias, see docs/PLAN-extensions-access.md); this record does not change that plan, and the Rust code names the binary and prefix `hobnix`/`hn` already.
7. The package SDK is renamed from `hobnix-ext-sdk` to the `hobnix-pkg*` crates in 0.14. This is a breaking change, announced in the 0.13 release notes; `hobnix-ext-sdk` re-exports the new crates for one release, marked deprecated. The SDK stays in this repository (`publish = false`) until its API has survived a release and an outside author has used it.
8. The code practices in docs/CODE-PRACTICES.md apply to all new code in the core and to `hobnix/official`.

## Consequences

- Easier: one language for logic, typed contracts, a single toolchain on the dev machine and in CI, one place to enforce practices.
- Harder: slower edit-and-test than a script; rebuilds for core changes; fewer contributors read Rust; build time and closure size grow (not measured).
- Follow-up issues: inventory, lints and practices, Rust job writer gaps, package SDK (0.14), small Python programs, the web-server ADR, generators, removal of Python.

## Open points

- Target release per Python program (after the inventory).
- Whether the `hs`/`hn` dispatcher moves to Rust (decision 6: later).
- Measured build time and size of `hobnix` on the pinned nixpkgs.
