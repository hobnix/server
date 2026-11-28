---
paths:
  - "rust/**/*.rs"
  - "scripts/**/*.sh"
  - "packages/**/*"
  - "capabilities/**/*"
---

# Code practices

Loaded when you touch the files above (path-scoped rule). The full text is docs/CODE-PRACTICES.md; read it before you write new code in a language you have not touched this session.

- Readable first: names in full words from the domain (`failed_disks`, not `fd`), one thing per function (about 40 lines), one reason per module (about 400 lines), comments say why, never what.
- Rust: no `unwrap`/`expect`/`[i]`/`[a..b]` outside tests (use `get`, slice patterns); an untrusted length is checked against a limit, computed with `checked_*`, and tested with absurd values. Typed errors (`Error + Send + Sync`, `source()`), never `String`/`()`, never decide by message text. A secret is a `Secret`; a type holding one otherwise gets a hand-written `Debug` and a test. No new suppression, `#[expect]` and `#[allow]` alike (ADR 0035); existing ones are being removed. Functions about 40 lines (60 is the clippy limit), files 400 lines before tests (`scripts/dev/rust-size-ratchet.sh`). Versions once in `[workspace.dependencies]`; a wire format never depends on a cargo feature. `forbid(unsafe_code)`, no `println!` in library code, a trait for the system so tests use a fake. SDK API, macro and async rules: docs/CODE-PRACTICES.md.
- Rust checks before a commit (in WSL, `CARGO_TARGET_DIR` outside the worktree; `scripts/dev/t quick rust-cargo` runs them): in `rust/`, `cargo fmt --check`, `cargo clippy --locked --all-targets --all-features -- -D warnings`, `cargo test --locked --all-features`. Send clippy's output to a pipe: clippy 1.95 can crash when it prints to a terminal.
- Shell: `set -euo pipefail`, quoted expansions, output through `ui.sh`; a script over about 300 lines that parses structured data moves to Rust in 0.15 (ADR 0035).
- No new Python program; fix bugs only (docs/PLAN-rust.md).
- Contracts (`hs sys` lines, package protocol, `registry.tsv`) never change for tidiness.
