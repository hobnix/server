# 0006: The `hs sys` contract is the API; the web interface is a client of it

Status: Accepted (2026-11-10)
Issue: hobnix/server#213 (epic #207). Records decisions already made in docs/PLAN-web-backend.md; nothing here is new.

## Context

- The `hs` command is the one entry to the server. Rows of kind `sys` in `scripts/lib/registry.tsv` are the machine-readable part: reads print
  tab-separated lines, JSON or text; changes are `plan` then `start` (ADR 0001 lists the shapes).
- The web interface (`web/`, Svelte) is served by `scripts/web-serve.py`, one Python process on the host as root (`hs-web.service`), never in an
  instance, because it has to work while the storage is locked.
- docs/PLAN-web-backend.md: "The plan/start contract already is the API." It is written down in `docs/api/openapi.json` (#123), generated from
  `registry.tsv` and `docs/api/sys.toml`.
- A terminal interface that parsed the same lines in a second program was removed on 2026-10-22 (ADR 0001, "History").

## Decision

1. **No second data layer.** The web backend reads and changes the server only by running `hs sys ...` words. It sets `HS_CALLER=web`.
2. **Allowlist.** `READS` and `CHANGES` in `scripts/web-serve.py` list the words, the number and pattern of arguments and the answer kind.
   Nothing outside them runs, nothing goes through a shell, an argument must match its pattern completely. A test checks that every entry is a
   real `sys` row and that no read is a changing command.
3. **Changes are `plan`, then `start`.** The plan says what happens and, for a destructive change, which name the user must type
   (`--confirm <name>`). Progress is read with `sys jobs tail`. The confirmation check lives in the command, not only in the page.
4. **The contract does not change shape.** Output lines, exit codes and the `-` for an empty tab-separated field are a contract with the web
   interface (CLAUDE.md). A new or changed `sys` row regenerates `docs/api/openapi.json` and `web/src/api/sys.gen.d.ts` in the same commit.
5. **The command is the API, not the page.** A feature exists first as an `hs` command with a plan/start contract; the web page, a timer or an
   extension is a caller of it. The language behind the command is free to change (ADR 0001).
6. **Secrets** reach the command on stdin, never in argv or the environment.

## Consequences

- One behaviour to test and document per feature; the command line and the web page cannot drift apart.
- Every web read costs a subprocess; a short cache and one call per question at a time keep that cheap (docs/PLAN-web-backend.md, "Reads").
- A feature cannot be web-only. That is the intended price.
- A versioned HTTP API in front of the same service layer is the goal of epic #121; ADR 0001 rule 4 says it needs its own record before a route
  of `web-serve.py` is replaced.

## Open points

- Whether a Rust HTTP server replaces `scripts/web-serve.py` (ADR 0001 rule 4).
- The API version number and its relation to `api-level` (ADR 0001 rule 4 says one number for packages and the API).
