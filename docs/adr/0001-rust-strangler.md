# 0001: Rust behind the hs sys contract (strangler)

Status: Proposed
Issue: hobnix/server#122 (epic #121)

## Context

- There is no Rust in the repository today. The contract is `hs sys ...`: the rows of kind `sys` in `scripts/lib/registry.tsv` (about 226 of
  484 rows), run by the `hs` dispatcher (`scripts/lib/hs.sh`, `scripts/lib/registry-load.sh`, which also loads the `commands.tsv` of every
  enabled extension).
- Shapes of the contract: reads print tab-separated lines (an empty field is `-`), JSON, or text. Changes are `<area> plan ...` (key and value
  lines: status, needs, reason, step, note, warn, danger, command, confirm_name, long, option; exit 0 ok, 1 refused, 2 something missing) and
  `<area> start ... --confirm <name>` (starts a background job, prints the unit). Progress is `hs sys jobs tail <unit> [N]`. Secrets come on
  stdin, never in argv or the environment (`scripts/lib/secret.sh`). `HS_CALLER` (cli, web, job, timer, test) says who calls.
- The web backend (`scripts/web-serve.py`, Python standard library, root on the server, never in an instance) runs only allowlisted `hs sys`
  words (`READS`, `CHANGES`) as subprocesses, with a short cache. `docs/PLAN-web-backend.md` says the plan/start contract already is the API.
- Packages (recipes, extensions) live in other repositories and talk to the core through shell and TSV (`commands.tsv`,
  `scripts/lib/api-level`, today 6; `docs/PLAN-packages.md`).
- History: a Rust terminal interface (`hs-ui`, ratatui) existed until 2026-10-22 and was removed when the web interface replaced it
  (docs/Entwicklungsnotizen.md, section "Interface (hs-ui)"). It was a second consumer of `hs sys` and parsed the lines again. Lesson: Rust
  beside the contract duplicates parsing; this time Rust goes behind it.
- Roadmap rule: move code to Rust when we touch it and it makes sense.

## Decision

1. **Strangler.** The `hs sys` rows are the contract. A command moves to Rust by replacing the implementation behind its registry row. Path
   words, arguments, flags, output lines, exit codes, stdin rules and job units stay byte for byte the same. A caller (web interface, timers,
   extensions, people) cannot tell which language answered. Shell and Python stay valid implementations; there is no deadline for removing them.
2. **One dispatcher, one list.** `hs` and `scripts/lib/registry.tsv` stay the only entry and the only list. A moved row names the Rust binary
   instead of a script. Form (decided in #125): the script column holds `rust:<subcommand>`, and `hs` runs it as `hobnix <subcommand>` with the
   same arguments. The dispatcher, tests/commands.sh, `hs help`, `hs sys registry` and the shell completion treat a `rust:` value as a valid
   script entry. This is implemented with the pilot (#127), not with the skeleton. Going back to the old script is a one-line change of that row.
3. **Service layer.** Rust code is split in two crates. `hobnix-core` is the service layer: typed inputs, typed results and errors; reads,
   `plan` and `start` as functions; no terminal output, no colours, no argv parsing, no translation. `hobnix-cli` is the adapter: it parses the
   `hs sys` words, calls the service and writes the existing lines. Every later caller (a Rust HTTP API, tests) calls `hobnix-core`, never the
   adapter's text. Human commands (kind `user`, `scripts/lib/ui.sh` dialogues) are not part of the service layer in this record.
4. **Transition for the web.** Until a later ADR says otherwise, the web backend keeps calling `hs sys` as a subprocess. A versioned HTTP API
   in front of `hobnix-core` is the goal of #121. It is described by the OpenAPI document of #123, and its version follows `api-level` (one
   number for packages and the API). Whether a Rust HTTP server replaces `scripts/web-serve.py` is undecided; that gets its own ADR before any
   route of `web-serve.py` is replaced.
5. **Packages are out of scope.** Extension and recipe commands stay shell and TSV; the core keeps loading their `commands.tsv`. A protocol for
   packages is the job of E12, not of this record. Moving a core command must not change `api-level`.
6. **Same rules as today.** Rust code runs as root on the server like the scripts. Secrets only on stdin or through the vault files that
   `secret.sh` reads (a Rust reader of the same files, never argv or environment). A destructive `start` keeps the typed `--confirm <name>`
   check inside the service, not only in the caller. Long work is a job (`scripts/lib/job.sh` units until E02 decides the job system).
7. **Build.** Rust is built by Nix inside this repository (no network at build time, locked dependencies), like `pkgs/hs-web.nix`. CI builds,
   runs `cargo clippy` and the tests (#125). The workspace and the CI job exist (`rust/`); the Nix build is a follow-up in #125 and is not done
   yet.

### When a command moves to Rust

A command group (all `hs sys <area> ...` rows of one script, for example `pool info|members|state`) moves only when all "must" items hold and at
least one "good reason" holds. It does not move when one "stays" item holds. Python commands (`pkg.py`, `forecast.py`, `live-collect.py` and
others) follow the same checklist.

Must:
- It is being changed anyway for a feature or a fix ("touch it, move it"). No move for the move's sake, except the pilot (#127).
- Characterization tests exist first: a `tests/<name>.sh` that records today's output for fixed inputs (fake `incus`, `zfs`, `smartctl`, as the
  tests already do). The same test passes against the Rust implementation, unchanged.
- Its output kind and fields are written in the OpenAPI document (#123).
- Its errors map onto the existing exit codes and stderr text (#126).

Good reasons (at least one):
- It parses structured output (JSON of incus, zfs, smartctl, restic) or keeps state, where shell quoting or `jq` chains have caused bugs.
- It is on a hot path: a `READS` entry with a short ttl, the `WARM` list of `web-serve.py`, or a timer that runs every few minutes.
- It is a destructive `plan` or `start` whose checks gain from types (pool, disk, share changes).
- Its logic is shared by several commands, so one Rust function replaces copies.

Stays (shell or Python):
- Thin wrappers around one external command.
- Anything that must work when the Rust binary is missing or broken: the installer and first run (`installer/`, `scripts/install-wizard.sh`,
  `scripts/first-run.sh`), unlocking the storage, `hs update` and its rollback, and recovery and rescue commands.
- Human (kind `user`) commands and guided dialogues, until a later ADR.
- Package commands (decision 5).

Done means: the characterization test passes on both implementations for one release (side by side, the row can switch back). Then the row
points at Rust and the old script is deleted. After that docs/Entwicklungsnotizen.md gets the history line, and no `hs sys` line has changed.

## Consequences

- Easier: typed checks for destructive work; one service that the web interface and `hs` share; a move can be undone by one registry line.
- Harder: two languages in the core for a long time; a Rust toolchain for whoever touches a moved group; a bigger Nix build and a dependency
  hash to update; tests for moved groups need Linux (WSL), like the root tests today.
- The contract can no longer change by accident: #123 writes it down, #124 gives the web interface the same types.
- Follow-up issues:
  - #123 OpenAPI document of the read, plan, start and jobs-tail contract (decision 1 is what it describes).
  - #124 TypeScript types for `web/`, generated from #123.
  - #125 Cargo workspace `hobnix-core` and `hobnix-cli`, Nix build (the registry column form is decided, decision 2), CI build and clippy (decision 7).
  - #126 Typed errors mapped to exit codes 0/1/2 and stderr; structured logs to the journal, never a secret in a log.
  - #127 First pilot, one command group, chosen with the job-system audit of #128 (E02) so the service layer is not shaped around the wrong
    job abstraction.

## Open points

- Whether a Rust HTTP server replaces `scripts/web-serve.py` (decision 4).
- The job system (E02) and the package protocol (E12).
- Which command group is the pilot (#127, after #128).
- Whether human (kind `user`) commands ever move.

## Errors and logs (#126)

- Errors are `hobnix_core::Error` (`Refused`, `Missing`, `Failed`). Exit codes: 0 success, 1 refused or failed, 2 missing.
- The CLI prints an error to stderr as `hobnix: <message>` and nothing to stdout.
- Log events are single lines on stderr, `<P>event key=value ...`; `<P>` is the syslog priority that journald reads (3 error, 4 warn, 6 info, 7 debug). The level comes from `HOBNIX_LOG` (default `info`).
- `Secret` prints `***` for both `{}` and `{:?}`; the value is read only with `expose()`.
- A log field whose key contains password, passwd, secret, token, key or passphrase (any case) is written as `***`.
- Std only: no new dependencies, so the later Nix build needs no network.
