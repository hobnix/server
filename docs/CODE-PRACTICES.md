# Code practices

Contributor document, not a guide. It applies to the core, to `hobnix/official` (recipes, capabilities, extensions) and to every new package we write. Agents load it through `.claude/rules/code-practices.md`, so generated code follows the same rules as written code. Third-party packages are invited to follow it; nothing here is required of them except what `hs pkg validate` checks.

Why this exists: the code base is read far more often than it is written, by people and by agents. Code that is easy to read is easy to review, to change and to trust. Where a rule can be checked by a tool, the tool enforces it (CI); where it cannot, review does.

## Principles

1. **Readable first.** Choose the version a new contributor understands in one pass. A clever shortcut that saves three lines and costs a minute of thought is a loss.
2. **Names carry the meaning.** A name says what a thing is or does in the language of the domain (pool, disk, instance, share, job), not how it is stored. Prefer `failed_disks` over `fd`, `parse_job_record` over `process`. No abbreviations except the ones in the glossary of docs/GUIDE-TEMPLATE.md and the usual short names for loops (`i`, `n`) over a few lines.
3. **One thing per function, one reason per module.** If a function needs "and" in its description, split it. If a file mixes parsing, decisions and output, split it along those lines (ADR 0001 decision 3: service layer in `hobnix-core`, text in `hobnix-cli`).
4. **Comments explain why, not what.** The code says what. A comment gives the reason, the constraint or the incident behind a decision ("a failing `zpool status` must not hide the disk list, #123"). Delete a comment that repeats the code; fix the code if it needs a comment to be understood.
5. **Make wrong states hard to write.** Use types for what the compiler can check: an enum instead of a string with four allowed values, a `Secret` instead of a `String`, a `PoolName` where a bare string would let a disk name slip in.
6. **Fail loudly, early and with context.** An error says what was tried, on which object, and what the user can do. No silent fallbacks that hide a broken state.
7. **Small diffs, tested behaviour.** A change carries its test. A move to Rust carries the characterization test of ADR 0001.

## Rust

Every rule names what checks it: a tool in CI (job `rust` in `.github/workflows/ci.yml`, locally `scripts/dev/t quick rust-cargo`, which `t changed` picks for any change under `rust/`), or review. The lints are set once in `rust/Cargo.toml` (`[workspace.lints]`, every crate has `[lints] workspace = true`) and `rust/clippy.toml`; CI's `-D warnings` turns every warning into an error.

- **Checks** (tool: CI job `rust`; locally `tests/rust-cargo.sh` runs only fmt, clippy and the two test commands, so run the others by hand): `cargo fmt --check`, `cargo clippy --locked --all-targets --all-features -- -D warnings`, `cargo test --locked --all-features`, `cargo test --locked -p hobnix-pkg -p hobnix-pkg-command -p hobnix-pkg-service -p hobnix-ext-sdk` (the SDK built alone, as an extension builds it), `cargo doc --no-deps --all-features` with `RUSTDOCFLAGS=-D warnings`, `cargo deny check`, and the size ratchet. In WSL, set `CARGO_TARGET_DIR` outside the worktree. clippy 1.95 can crash while it prints a finding to a terminal (a bug in rustc's renderer). Run it with output to a pipe or file (the `t` runner does).
- **Toolchain** (tool: CI job `nixos`, `scripts/dev/nixpkgs-pin.sh toolchain-check`): `rust/rust-toolchain.toml` names exactly the rustc of the nixpkgs pin (`config/nixpkgs-pin.toml`), the compiler servers build `rust/` with (`pkgs/hobnix.nix`). The weekly bump moves both in one pull request (`toolchain-sync`). `rust-version` in `[workspace.package]` is the oldest rustc that must build the crates. It follows the toolchain that hobnix/official builds the SDK with (its `rust-toolchain.toml`, CI job `ext-crates`), so it can be lower than the pin. Edition 2024, resolver 3. Release builds keep overflow checks (`[profile.release] overflow-checks = true`) and `panic = "unwind"` (the SDK's command runner catches a panicking handler; the service runner does not).
- **Lints** (tool: clippy): `clippy::pedantic` as a group (with `must_use_candidate`, `many_single_char_names`, `missing_errors_doc` allowed), plus named single lints: rustc `unsafe_code = "forbid"`, `unreachable_pub`, `missing_debug_implementations`, `elided_lifetimes_in_paths`, `unused_qualifications`; clippy `unwrap_used`, `expect_used`, `panic`, `todo`, `unimplemented`, `dbg_macro`, `print_stdout`, `print_stderr`, `indexing_slicing`, `string_slice`, `exit`, `mem_forget`, `allow_attributes`, `allow_attributes_without_reason`. For readability and against silent loss: rustc `redundant_lifetimes`, `single_use_lifetimes`, `trivial_casts`, `trivial_numeric_casts`, `unit_bindings`, `ambiguous_negative_literals`; clippy `clone_on_ref_ptr` (write `Arc::clone(&x)`, so a cheap clone is told from a copy), `unused_result_ok` (no `.ok();` to drop an error), `verbose_file_reads` (`fs::read_to_string`), `mod_module_files` (a module `x` is `x.rs`, its children are in `x/`; no `mod.rs`), `same_name_method`, `rest_pat_in_fully_bound_structs`, `unneeded_field_pattern`, `empty_structs_with_brackets`, `empty_enum_variants_with_brackets`. Limits in `rust/clippy.toml`: `too-many-lines-threshold = 60`, `excessive-nesting-threshold = 5`. Never switch on a whole `restriction` or `nursery` group (review): they contradict each other and change with every clippy release. An `unsafe` exception needs its own review and a `// SAFETY:` comment.
- **No new suppression** (ADR 0035; review): the sentences below describe the ones that exist until they are removed; none is added.
- **Suppressions** (tool: clippy `allow_attributes`, `allow_attributes_without_reason`): `#[expect(lint, reason = "...")]` on the smallest item, never `#[allow]`. An `expect` that stops matching fails the build, so a suppression goes away when the code is fixed. A file-wide `#![expect(..)]` is allowed only as a ratchet: its reason names the issue that removes it (`reason = "ratchet #1307: ..."`). Tests may use `unwrap`, `expect`, `panic` and indexing (`rust/clippy.toml`; an integration test file carries its own `#![expect]`).
- **No panics** (tool: clippy `unwrap_used`, `expect_used`, `panic`, `indexing_slicing`, `string_slice`, overflow checks in release; review for the rest): no `unwrap`, `expect`, `[i]` or `[a..b]` outside tests. Use `get`, slice patterns, `split_once`, `split_at_checked`. An `expect` is allowed only for a condition the code has just made true, with `#[expect(clippy::expect_used, reason)]`. A length or size from outside (a peer, a file, an argument) is checked against a limit before any arithmetic with it, the arithmetic is `checked_*` or `saturating_*`, and a test feeds it absurd values (`ffffffffffffffff`, `usize::MAX`, a negative number, a length past the end).
- **Errors** (review; clippy `missing_errors_doc` is off, so review also checks that a public function says when it fails): a library returns a typed error that implements `std::error::Error + Send + Sync`, carries its cause and returns it from `source()` (`hobnix_core::Error`: `Refused`, `Missing`, `Failed`; ADR 0001 "Errors and logs"). Never `String` or `()` as an error type in new code, and never decide by the text of a message: match the variant. A binary maps the error to the exit code and the one stderr line `hobnix: <message>`.
- **Secrets** (review; a test per type): a secret has the type `Secret` in every signature that carries it (`hobnix_core::Secret`, whose `Debug` and `Display` print `***`). A type that holds a secret in a field that is not a `Secret` (a header value, a derived key, a credential list) gets a hand-written `Debug` that leaves the value out, and a test that the value is not in `format!("{x:?}")`, also through every type that wraps it. An error text never shows a secret: a URL in an error drops its query and user info. Never in a log line, an error or a panic message.
- **Size** (review: aim for 40 lines per function; tool: clippy `too_many_lines` at 60, `excessive_nesting` at 5; tool: `scripts/dev/rust-size-ratchet.sh check` at 400 lines per file before its `#[cfg(test)]` module): above that, split. Files that were already larger are listed in `tests/rust-size-ratchet.tsv` and may not grow; after one shrinks, `rust-size-ratchet.sh lower` lowers its number.
- **Names** (review): types `UpperCamelCase`, functions and variables `snake_case` in full words, constants `UPPER_SNAKE`. Boolean names read as a question (`is_encrypted`, `has_spare`). A function that returns a `Result` is named for what it does, not `try_`.
- **Modules and visibility** (tool: rustc `unreachable_pub`; review): everything is private until another module needs it; inside a binary crate, `pub(crate)`.
- **Dependencies** (tool: `cargo deny check` with `rust/deny.toml`; review): every version is written once, in `[workspace.dependencies]`, and a crate says `name = { workspace = true }` (it may add features). `cargo deny` refuses a yanked crate, a licence outside the allow list, and a registry or git source that is not named. A new RustSec advisory fails a pull request as it fails a push and the nightly run. Each dependency is a cost (Nix builds without network, a locked `Cargo.lock`, review time). A new crate needs a sentence in the pull request: what it replaces, how large it is, how it is maintained. `serde` and `serde_json` are accepted (ADR 0001 "Job store"). cargo turns a feature on for every crate of a build once one crate asks for it (`serde_json/preserve_order`: hobnix-core asks). So a wire format never depends on a feature that another crate may switch on: the SDK writes sorted keys, and a test pins its bytes.
- **Output and logs** (tool: clippy `print_stdout`, `print_stderr`): no `println!` in library code. The CLI writes only the contract lines. Diagnostics go through `hobnix_core::log` (single lines, syslog priority prefix).
- **Time, files and the system** (review) sit behind a small trait (`Host`, `System`, `Clock`) so tests use a fake. No test needs root for logic.
- **Tests** (review): unit tests next to the code for logic; `tests/*.sh` and the `t` runner for behaviour at the `hs` boundary. Test names state the behaviour (`refuses_removal_without_confirm_name`), not the function. A defect fix comes with a test that fails without the fix.
- **Public contracts** (tool: `tests/*-rust.sh` compare the Rust lines with the shell and Python they replace, byte for byte; review): `hs sys` lines, JSON Lines of the package protocol and `registry.tsv` are never changed to make code nicer. Change the code behind them.

## Rust: SDK public API

For the `hobnix-pkg` crates (and the deprecated `hobnix-ext-sdk`) and every crate that extensions build against (review, following the [Rust API Guidelines](https://rust-lang.github.io/api-guidelines/); tool: `cargo doc` with `-D warnings` checks the links in the docs):

- Every public item has a doc comment, errors included: what it is, what it expects, when it fails.
- A public enum or struct that may get a variant or field later is `#[non_exhaustive]` and has a constructor (or builder), so that code outside the crate, tests included, can still build a value.
- A protocol enum accepts values it does not know where the protocol may grow (an `Unknown(String)` variant or an ignored message type), so an older extension keeps working against a newer core.
- A new method on a public trait has a default body, so existing implementations still compile.
- A change to a public signature is a breaking change of the SDK: it goes into the changelog and the version.

## Rust: procedural macros

For a macro crate (review; tool where named):

- The `#[proc_macro]` entry point is thin: it converts the token stream and calls a function on `proc_macro2::TokenStream` that holds the logic. That function has unit tests.
- An input the macro refuses becomes a `compile_error!` with the span of the offending tokens (`syn::Error::to_compile_error`). A macro never panics.
- Each refused input has a `trybuild` compile-fail test with its expected message (tool: `cargo test`).
- Generated code uses absolute paths (`::core::...`, `::hobnix_pkg::...`). It reaches the SDK's internals only through a hidden `#[doc(hidden)] pub mod __private`, which is not part of the public API.
- The macros are re-exported behind a feature of the crate that users depend on, and CI builds with and without that feature (tool: CI job `rust`).

## Rust: async and daemon (from 0.15)

These rules apply from 0.15, when the first async code and the daemon arrive. Until then no checker is configured for a crate that does not exist; review checks them.

- **Do not block the runtime.** Bounded blocking work (a file read, a short command) goes to `spawn_blocking`. Endless loops get their own thread. A blocking task cannot be aborted, so it gets a time limit.
- **Programs are started only by the system layer**, with a time limit, killed on cancel, and always waited for (no zombies).
- **Actors own their state.** Other tasks talk to them over bounded channels; a reply comes back on a `oneshot`. There is no cycle of awaited sends between actors (a deadlock).
- **Every long-lived task has an owner** that keeps its `JoinHandle`, joins it, and handles a panic or an early end.
- **Shutdown** is a cancellation token, then waiting with a deadline. Jobs are systemd units and are never stopped by the daemon's shutdown.
- **`select!`**: every branch is cancel safe, or a comment says why losing it is fine. `write_all`, `read_exact` and `read_to_end` are not cancel safe.
- **Protocol line reads are bounded** (a maximum length, as the SDK's 1 MiB line limit).
- **No blocking lock guard across an `.await`** (tool: clippy `await_holding_lock`, in the default set).
- **Configuration** is read once at start and passed in; no global reads from deep inside.
- **Logs** carry the request, job or event id so lines can be followed. Never a secret. A library installs no tracing subscriber; only the binary does.
- **SQLite:** one task owns writing. A read followed by a write runs in `BEGIN IMMEDIATE`. Every connection sets an explicit `busy_timeout`. The linked SQLite has the fix for the WAL-reset corruption bug (present from 3.7.0 to 3.51.2): 3.51.3 or later, or one of the backports 3.50.7 and 3.44.6 (sqlite.org/wal.html, "The WAL-Reset Bug").

## Shell

Shell stays for glue (ADR 0001 "Stays"; docs/PLAN-rust.md for the list). Practices:

- **Checked by tools:** `bash -n` for every script (pre-commit routine) and `shellcheck -S error` in CI (changed files on a pull request, all files otherwise). Also run on the changed files of a pull request: `shellcheck` at warning level as a ratchet (`scripts/dev/shellcheck-ratchet.sh`, baseline `tests/shellcheck-ratchet.tsv`: a file may not have more findings than listed, a new file none; fewer findings: lower the number with `--update`), and `shfmt -d -i 2 -ci` for layout (reports only, not blocking yet). To adopt: make the `shfmt` step blocking once the flags are checked on a runner; the existing scripts are not reformatted in one go.
- `set -euo pipefail`, quoted expansions, `local` for function variables, `readonly` for constants, no backticks, no `eval`.
- **Names:** variables and functions in full lower-case words (`pool_name`, `list_disks`); environment variables the interface depends on keep their `HS_` names. One function does one thing; a function over about 40 lines is a candidate for a helper or for Rust.
- **Output** only through `scripts/lib/ui.sh`; machine-readable lines never change shape (CLAUDE.md, `.claude/rules/shell.md`).
- **Size limit:** a script over about 300 lines that parses structured data (JSON, `zfs` or `incus` output) or keeps state moves to Rust in 0.15 (ADR 0035). A pipeline of other tools stays shell.
- **Secrets** only through `scripts/lib/secret.sh`, never argv or the environment.

## Python

Python is being retired (docs/PLAN-rust.md). Until a program is replaced: fix bugs, add no new Python program and no new feature to a Python program that ADR 0001 would move, keep the standard library only, add type hints to anything you touch.

## Packages (recipes, capabilities, extensions)

The same practices apply to `hobnix/official`:

- Prefer the package SDK (docs/PLAN-package-sdk.md) over hand-written protocol code, `commands.tsv` rows or manifest boilerplate.
- A recipe stays declarative where it can: the manifest says what; code appears only where logic is needed. A recipe ends with `docs_hint`.
- A package that is not Rust may be bash (small glue) or any language that speaks the protocol; it still follows naming, size, error and comment rules above.
- `hs pkg validate` and the package CI template are the enforced part; naming and readability are checked in review.

## Review checklist

A reviewer (human or the `reviewer` agent) asks, in this order:

1. Does it do what the spec says, and is the behaviour tested?
2. Could a contributor who has not seen it before follow it without asking? (names, size, comments)
3. Are errors specific, and is a wrong state impossible or refused?
4. Is a contract (line shape, protocol, registry) unchanged?
5. Is anything added that is not needed: a dependency, an option, a layer?

## Changing this document

A new rule is added when a review comment is written for the second time, and it names the tool that enforces it, or says that review does. A rule nobody checks is removed.
