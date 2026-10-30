---
paths:
  - "scripts/lib/registry.tsv"
  - "scripts/lib/i18n.sh"
  - "scripts/lib/i18n/**"
  - "scripts/lib/docs-index.py"
  - "scripts/hs*.sh"
  - "scripts/lib/hs.sh"
  - "scripts/docs-build.sh"
  - "docs/**"
  - "tests/commands.sh"
  - "tests/i18n.sh"
  - "tests/docs*.sh"
  - "tests/dialogues.sh"
  - "tests/smoke*.sh"
---

# Commands, registry, language, docs

Loaded when you touch the files above (path-scoped rule). The root CLAUDE.md has the rules that always apply.

- **Commands, registry and language** (details: docs/Entwicklungsnotizen.md#commands-registry-and-language). `scripts/lib/registry.tsv` is the one list of commands (kind user|sys, path, script, fixed args, help, help.de, flags `guided`, `legacy:<new>`, `topic:`, `tab:`, `reads|changes`); a new script needs a row (tests/commands.sh). `hs sys ...` rows are machine-readable and plain. Look of every user command: docs/CLI-DESIGN.md and scripts/lib/ui.sh components (no raw echo/printf, no own colours/boxes; `thead`+`table`, `status_line`, `kv`, `trail`). Language: `language` in machine.toml, scripts/lib/i18n.sh with English text as key and scripts/lib/i18n/<lang>.tsv; add a translated script to CORE in tests/i18n.sh (run it on the server, not on Windows). Machine-readable output, push messages and health problems are never translated. Guided dialogues take every answer as an option and refuse without a terminal and without `--yes`. `hs smoke` (probe list), `hs motd` and the other small commands are described in the notes.

- A user-visible change adds docs/changelog/<date>-<slug>.toml (format: scripts/lib/changelog.py; CI warns).
- Documentation is English (one template and glossary: docs/GUIDE-TEMPLATE.md). The nine core guides are docs/install.md, containers-and-apps.md,
  users-and-shares.md, storage-and-disks.md, encryption-and-vault.md, backup-and-recovery.md, web-interface.md, operations.md and the generated
  command reference; a package's guide is `guide.md` in its folder (`packages/<name>/`, `capabilities/<name>/`) and `hs docs build` collects it
  under Apps / Extensions. Each step shows the `hs` command first. Steps marked "Not tested on hardware yet." have not been run on a real server.
  Design notes of removed plans are not part of the public tree (docs/Entwicklungsnotizen.md and the kept PLAN-* documents are).

- Round of 2026-10-11 (UPS, config drift + `hs update` rollback, `hs expiry`, container restore drill, smoke coverage, cheat sheet, qBittorrent, test runner): details in docs/Entwicklungsnotizen.md#round-of-2026-10-11-none-of-it-run-on-the-server-yet; checklist for the real server: the operations guide. Rules: a new test needs no list entry (tests/run-all.sh finds it); a new `reads` command needs a probe in scripts/smoke.sh (`hs smoke --coverage`); a new recipe ends with `$(docs_hint <slug>)`.
