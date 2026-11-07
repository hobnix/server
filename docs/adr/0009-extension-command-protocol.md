# 0009: Command extensions speak versioned JSON over stdin/stdout

Status: Proposed
Issue: hobnix/server#237 (epic #197). Service extensions are #238, permissions #239; neither is decided here.

## Context

- A command of a package is a row in `commands.tsv` that runs a script (docs/PLAN-extensions.md). The contract is "shell and TSV": arguments in
  argv, answers as TSV or text on stdout, failure as the exit code. That is enough for the pilot packages and stays the default.
- It does not fit an extension in another language, nor a call that needs progress, a structured error, a timeout or a clean cancel: today
  `hs` waits for the script as long as it runs, `hs sys` readers cannot tell "failed" from "hung", and a cancelled web job kills the process
  without the script having a chance to clean up.
- ADR 0001 rule 5 keeps package commands shell and TSV "until a protocol is decided"; ADR 0008 leaves it open. This record is that protocol for
  **command extensions** (short-lived: one process per call). Long-running collectors and event consumers are a different lifecycle (#238).
- The core already has the pieces: events (ADR 0005), job records (ADR 0004), secrets only through scripts/lib/secret.sh.

## Decision

1. **One call is one process.** The core starts the command of the row, writes ONE request line to its stdin and closes stdin. The
   extension writes **JSON Lines** to stdout: zero or more `progress`, `log` and `event` messages, then exactly one `result`, then exits.
   Nothing else is on stdout. stderr is free text for diagnostics; the core keeps the first 64 KiB and shows it only on failure.
2. **The format is docs/api/ext-protocol-v1.schema.json.** Every message has `"v": 1` and `"type"`. The request carries `id`, `command` (the
   words after `hs ext <name>`), `argv`, `lang` (`en|de`), `caller` (`cli|web|boot`) and `timeout_ms`. A result is `ok` with optional `data`
   (any JSON) and `text` (what a person is shown), or `ok: false` with `error {code, message}`; the message is one English line and the
   interface translates by `code`.
3. **Versioning.** `v` is an integer. A manifest names the versions the extension speaks (`protocol = [1]` in package.toml; reading it is a
   follow-up, see Consequences); the core picks the highest one both sides know and refuses before starting when there is none. An extension
   that receives a `v` it does not know answers `error.code = unsupported_version` with `supported`, and exits 1. A change that only adds
   optional fields stays version 1: readers ignore fields they do not know. Anything else is a new `v`, and the core keeps speaking the
   old one for at least one `api-level` step (ADR 0008 rule 4).
4. **Exit status agrees with the result.** `ok: true` and exit 0, or `ok: false` and exit 1. Anything else (no result, two results,
   output after the result, a line that is not JSON or not valid for its type, a status that disagrees) is `protocol_error`: the core
   stops the process and reports it; it never guesses.
5. **Limits.** The request is at most 1 MiB; one output line 1 MiB; all stdout 16 MiB. Beyond that the core stops the process
   (`protocol_error`).
6. **Timeout.** Each call has a limit: 30 s by default, a row or manifest may raise it up to 3600 s. At the limit the core sends SIGTERM to the
   process **group**, waits the grace time (5 s) and then sends SIGKILL to the group. The call ends with `timeout` (exit status 124 at the
   boundary of the runner). `timeout_ms` in the request tells the extension the limit; it is a hint, the core enforces it.
7. **Cancellation is SIGTERM.** A cancel (the user presses Ctrl-C, the web interface stops the job) reaches the extension as SIGTERM to its
   process group, again followed by SIGKILL after the grace time. An extension may write a `result` with `error.code = cancelled` inside the
   grace time to clean up and say so; the call ends as `cancelled` (130) whatever it wrote. The grace time is the only promise: an
   extension must not rely on more.
8. **Events go through the core.** An `event` message asks the core to write one entry with `hs event emit` (ADR 0005). The core checks the
   kind against the package's `[[events]]` and drops the others with a warning. The extension never writes the log itself.
9. **No secrets in the request.** `argv` and `data` are not for secrets (CLAUDE.md: secrets never go through argv or the environment). An
   extension that needs one reads it through scripts/lib/secret.sh (or its protocol successor), as every command does today.
10. **The shell contract does not go away.** A row without the protocol keeps today's meaning. A row speaks the protocol only when the
    manifest says so; the machine-readable `hs sys ext ...` lines (TSV with `-` for empty) stay a contract of the web interface, and a
    protocol row is rendered to them by the core, not by the extension.
11. **Any language.** The request is read from the first line of stdin and the answer is written as lines; a shell script with `jq`, Python,
    Go and Rust all qualify. The reference runner is `scripts/lib/ext_proto.py` (stdlib Python); the test extension is
    tests/fixtures/ext-proto/ext.py; both are covered by tests/ext-proto.sh (result, failure, timeout, SIGTERM and SIGKILL, cancel, the kinds of
    protocol error (not the 16 MiB total cap), the schema).

## Consequences

- Easier: structured errors the web interface can translate, progress for long commands, a timeout that really stops a hung script, a clean
  cancel, extensions that are not shell.
- Harder: two ways to write a command; the dispatcher must run both and test both. A protocol extension cannot stream large output (16 MiB
  cap): a bulk command stays on the shell contract or writes a file and returns its path.
- Follow-ups, not built here (the reference runner is the proof that the format works, it is not called by `hs` yet):
  1. `protocol = [1]` and a per-row `timeout` in package.toml / commands.tsv flags, validated by `pkg.py validate`; the dispatcher
     (`hs ext`, `hs sys ext`) calls the runner for such rows and renders `data` to TSV/text.
  2. `hs_job` cancel sends SIGTERM to the process group (ADR 0004) so rule 7 holds for jobs started by the web interface.
  3. An SDK (#197) with the same message types for shell, Python and Go.

## Open points

- Whether `data` of a `sys` row gets a declared shape per command (a schema in the manifest) or stays free JSON.
- A request channel for the extension to ask the core (read a setting, ask a question) in the middle of a call. Version 1 has none: everything
  the extension needs is in the request or read by itself.
- Permissions are #239; a service extension's lifecycle is #238; neither changes these rules.
