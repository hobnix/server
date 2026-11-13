# Hobnix server (repository hobnix/server)

NixOS home server: Incus containers on ZFS or SnapRAID, Samba shares, backups, a web interface, one command `hs`. The repo lives at
/etc/nixos on a server. Apply changes with `hs rebuild` or `hs update`. Commands are `scripts/<name>.sh`, `hs help` lists them,
`scripts/lib/registry.tsv` is the one list. Apps (recipes) and optional parts (extensions) are packages that live in their own repositories, hobnix/recipes and
hobnix/extensions (docs/PLAN-packages.md); the core fetches them with `hs pkg`.

## Rules that always apply
- **Admin pages are never public.** Incus, Zoraxy, Arcane, the docs site, Grafana, Tdarr get no public route (guard: `ADMIN_TARGETS`
  in scripts/services.py).
- **Destructive commands** make the user type the NAME of the thing that changes (the disk, not the pool), show a plan first, and offer a
  background job for long work. Never put a reboot or wipe in the same code block as the step it depends on.
- **Terminal output only through scripts/lib/ui.sh** (step, ok, note, warn, fail, spin, table, kv ...): no raw `echo`/`printf`, no own colours.
  Machine-readable lines (`hs sys ...`, `--list`, `--dry-run`, `--state`) are a contract with the web interface: never change their shape; an
  empty tab-separated field is written `-`.
- **Generated files are never edited by hand:** config/defaults.nix, scripts/lib/config-keys.sh, scripts/lib/capabilities.tsv,
  machine.toml.example. Edit config/schema.toml, then `python3 scripts/schema-gen.py write`. Also generated: docs/api/openapi.json (from registry.tsv and
  docs/api/sys.toml: `python3 scripts/openapi-gen.py write` in the same commit as a new or changed `sys` row), and web/src/api/sys.gen.d.ts (TypeScript types from openapi.json:
  `python3 scripts/openapi-ts-gen.py write` in the same commit as an openapi.json change), and the kinds table in docs/events.md (from
  scripts/lib/event-kinds.tsv: `python3 scripts/events-doc-gen.py write`).
- **A new script needs a row** in scripts/lib/registry.tsv (tests/commands.sh); a new `reads` command needs a probe in scripts/smoke.sh; a new
  recipe needs packages/<name>/package.toml and ends with `docs_hint`; a user-visible change adds a docs/changelog entry.
- **Secrets** are read only through scripts/lib/secret.sh and never go through argv or the environment.
- **Docs are English** and follow docs/GUIDE-TEMPLATE.md; a step that was not run on real hardware says "Not tested on hardware yet."
- **Branches:** `develop` is the default branch: feature branches start from it and pull requests target it. `main` holds released code
  only and takes nothing but a release pull request (develop into main, merge commit, no squash) followed by a signed `vX.Y.Z` tag on
  main. A hotfix branches from main, goes into main, then back into develop. Details: docs/dev-environment.md "Branches and releases".
- **Git:** never edit, commit or switch branches in the primary checkout (stays on main; work in your own worktree; guard: scripts/dev/guard-primary-checkout.sh, `bash scripts/dev/install-guards.sh` once per clone); stage files by name after `git status`; no `Co-Authored-By` or "generated with" lines about any AI tool in commits or PRs; every commit carries `Signed-off-by` of the configured git user (`git commit -s`, or the hook from install-guards.sh adds it); the DCO check has no exemption for agent PRs.
- **Honest reports:** say what failed or was not run. Never claim a result that was not seen.

## Where the detail is
Area rules load by themselves when you touch matching files (`.claude/rules/`): storage, web, packages, commands, shell, config, monitoring,
instances. Longer per-feature history: docs/Entwicklungsnotizen.md (read the matching section before changing that area). Design records:
docs/PLAN-*.md. Per-area folders carry their own CLAUDE.md (web/, packages/, capabilities/).

## Testing
Run tests through the quiet runner, never raw: `scripts/dev/t quick [name...]` prints only failures and one summary line per test
(`scripts/dev/t list` names them, `t root` runs the root tests on loop devices, `t vm` the throwaway VM; see docs/dev-environment.md). Before
a commit: `t quick` for the tests of the files you changed, `bash -n` for scripts, `python3 scripts/pkg.py validate` for manifests.
`tests/i18n.sh` and root tests need Linux (WSL); on Windows Git Bash many tests are slow.

## Working with agents (save context)
The main session orchestrates: it picks an issue from the board (`scripts/dev/board.sh open`), delegates, and reads only short reports. Agents in `.claude/agents/`:
`architect` (design, read-only, Opus), `coder` (implements one spec, Sonnet), `implementer` (mechanical edits from an exact spec, Haiku),
`tester` (runs tests, reports failures only, Haiku), `reviewer` (diff against the spec, read-only, Opus), `docs-writer` (guides, Sonnet).
`/work <issue number>` runs the loop for one board issue: spec, code, test, review. Specs and reports are files in `.work/<id>/` (git-ignored), not chat;
an agent's final message is at most 150 words: status, files changed, checks run, open questions.
- Ask before building when a request is unclear, has several designs, or touches storage, network or the firewall.
- Read less: Grep/Glob, then Read with offset/limit; do not re-read a file you just edited; never dump command output (`| tail`, `--stat`).
  docs/Entwicklungsnotizen.md is about 120 KB: Grep for the section heading, then Read only that range; never read it whole.
- Agent models come from each agent's `model:` line (do not set CLAUDE_CODE_SUBAGENT_MODEL: it overrides all of them).
- One task per session; `/clear` between unrelated tasks. Durable facts go in the area rules, not in chat.
