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
  machine.toml.example. Edit config/schema.toml, then `python3 scripts/schema-gen.py write`.
- **A new script needs a row** in scripts/lib/registry.tsv (tests/commands.sh); a new `reads` command needs a probe in scripts/smoke.sh; a new
  recipe needs packages/<name>/package.toml and ends with `docs_hint`.
- **Secrets** are read only through scripts/lib/secret.sh and never go through argv or the environment.
- **Docs are English** and follow docs/GUIDE-TEMPLATE.md; a step that was not run on real hardware says "Not tested on hardware yet."
- **Git:** stage files by name after `git status`; no `Co-Authored-By` or "generated with" lines about any AI tool in commits or PRs.
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
The main session orchestrates: it picks a task from TODO.md, delegates, and reads only short reports. Agents in `.claude/agents/`:
`architect` (design, read-only, Opus), `coder` (implements one spec, Sonnet), `implementer` (mechanical edits from an exact spec, Haiku),
`tester` (runs tests, reports failures only, Haiku), `reviewer` (diff against the spec, read-only, Opus), `docs-writer` (guides, Sonnet).
`/work <id>` runs the loop for one TODO task: spec, code, test, review. Specs and reports are files in `.work/<id>/` (git-ignored), not chat;
an agent's final message is at most 150 words: status, files changed, checks run, open questions.
- Ask before building when a request is unclear, has several designs, or touches storage, network or the firewall.
- Read less: Grep/Glob, then Read with offset/limit; do not re-read a file you just edited; never dump command output (`| tail`, `--stat`).
- One task per session; `/clear` between unrelated tasks. Durable facts go in the area rules, not in chat.
