# 0008: Capabilities with a contract; apps and optional parts are signed packages in their own repositories

Status: Accepted (2026-11-10)
Issue: hobnix/server#213 (epic #207). Records decisions already made in docs/PLAN-modular-core.md and docs/PLAN-packages.md.

## Context

- Recipes (an app in a container or VM) and extensions (commands and a page on the host) were built from the same pieces but were two
  mechanisms with different metadata (docs/PLAN-packages.md, "Why one concept").
- A capability that is off should cost nothing: no Nix, no registry rows, no web page (docs/PLAN-modular-core.md).
- Packages run as root, so installing one is trusting its author.

## Decision

1. **A capability lives in `capabilities/<name>/`** with a manifest (`capability.toml`). `requires` names capabilities, never other variants.
   A capability that is off adds no Nix, no registry rows, no web page.
2. **Generic capabilities have a contract and variants** chosen at install time (for example reverse-proxy, docker, dns); one variant is
   active per provider capability. Targeted capabilities (single-purpose apps) fulfil only the minimal contract: install, declare their services.
3. **Recipes and extensions are both packages** (`kind = recipe` or `extension`), with `package.toml`, living in the repositories
   hobnix/recipes and hobnix/extensions, fetched by `hs pkg`. The core keeps what it needs to run at all (storage, backup, encryption,
   samba, incus, the web interface, the registry loader, notifications, installer).
4. **The core API is a public contract.** `scripts/recipes/_lib.sh`, `ui.sh`, `i18n.sh`, `secret.sh`, `setting.sh`, `state.sh`, `services.sh
   declare` and the registry format carry an integer `api-level` that only goes up. A function is removed only after one level with a
   deprecation warning. A package states `requires_core`; the core refuses one that needs more.
5. **Trust by signed tags.** Packages are fetched to `/var/lib/hs/packages/<name>@<commit>` (root-owned, read-only); only a tag or commit is
   checked out, never a branch head. The default repositories are trusted by a key shipped in `config/trusted-keys/`; `hs pkg` refuses an
   unsigned or wrongly signed tag. Another repository needs the user to type its name; unsigned needs an explicit switch.
6. **Nothing installs or enables itself.** Update shows the diff between installed and new tag and asks before replacing.
7. **Packages that the core names** (`docker`, `zoraxy`, `monitoring`, `ntfy`, `domain`) ship in recipes but are marked `core = true`; core CI
   refuses a change that breaks them.

## Consequences

- An app can be released without a core release; the cost is a compatibility surface (`api-level`) that must be kept and tested against every
  default package.
- Adding a repository is a trust decision the user makes with the name typed, not a click.
- Whether a core-named package should become a core capability is decided one at a time, not by rule (docs/PLAN-packages.md, "What stays in the core").

## Open points

- The open points and risks of docs/PLAN-packages.md ("Open points", "Risks"), for example when a patch release may apply without showing the diff.
- Rust and packages: ADR 0001 rule 5 keeps package commands shell and TSV; a protocol for packages is a later decision.
