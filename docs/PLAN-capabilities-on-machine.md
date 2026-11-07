# Plan: derived files of an installed capability package (draft, 2026-11-07)

Status: first slice built (issue #224, epic #217). Context: docs/adr/0009-capability-as-package-kind.md rule 6, docs/PLAN-packages.md.

## Problem

`scripts/schema-gen.py write` makes the derived files in the checkout from `config/schema.toml` and `capabilities/*/capability.toml`.
A capability package fetched by `hs pkg` lives in `/var/lib/hs/packages/current/<name>` (read-only, root) and the scripts run from a copy in
`/nix/store`, so nothing in the checkout can be regenerated at install time. The derived files that a package changes are:

| File | Needed because a package ... | Slice |
| --- | --- | --- |
| `scripts/lib/capabilities.tsv` | can be implied by a runtime setting (`implied_by`) | built: overlay |
| registry rows | ships `commands.tsv` | already works: `registry_rows` reads installed packages |
| `config/schema.toml` options, `config-keys.sh`, the `CONFIG_KEYS` allowlist, `layout.gen.json`, `machine.toml.example` | declares options (`capability = "<name>"`) | not built: options |
| `config/defaults.nix` | has a Nix option default | not built, needs a rebuild |

## Built: the overlay

`python3 scripts/schema-gen.py overlay [write|check|list] [--packages DIR] [--out DIR]` reads `DIR/<name>/capability.toml` of every
installed package (default `/var/lib/hs/packages/current`) and writes `capabilities.tsv` to `/var/lib/hs/generated/`. `capability.sh` and
`hs_ext.py` read that file after the core one. A package named like a core capability is refused (nothing is shadowed); a manifest whose
name differs from its folder is refused. The checkout is never touched. `hs pkg install|update|remove` calling `overlay write` is not
wired yet: the capability kind does not exist in `scripts/pkg.py` until #225.

## Not built: options of a package (several designs)

1. **Overlay for every consumer** (recommended): a package ships `options.toml` (the same `[[item]]` tables as the schema, all with its
   own `capability`); `overlay write` validates them against the core schema (no key clash) and writes `schema.overlay.json`;
   `hs config`, `config-change.sh`, `web-serve.py` and the web settings layout read it next to the core schema. No rebuild for options with
   `store = "settings"`.
2. **Merge into the checkout** at `/etc/nixos`: a package install runs `schema-gen.py write` there. Simple, but it edits tracked files
   (`git status` dirty, `hs update` conflicts) and breaks the "generated files are never edited" flow.
3. **Packages may not declare options**: only runtime settings that the core schema already knows. Cheapest; limits what a capability can be.

Options in `store = "machine"` need `hs rebuild` in every design; that was not run (no nix on the development machine).

Not tested on hardware yet.
