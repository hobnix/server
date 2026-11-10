# 0009: A capability is a third package kind; a short list stays in the core

Status: Accepted (2026-11-10)
Issue: hobnix/server#219 (epic #217). Extends ADR 0008 (capabilities and packages); does not repeat it.

## Context

- ADR 0008 decided that capabilities have a manifest and a contract, that recipes and extensions are signed packages in their own
  repositories, and that the core keeps "what it needs to run at all". It names two package kinds (`recipe`, `extension`) and lists the
  core in one sentence (decision 3). It does not say how an optional capability that ships Nix (`module.nix`) becomes a package, and it
  leaves the core list loose (docs/PLAN-packages.md "What stays in the core" also names metrics, tailscale, vps, edge roles and docs).
- Today `capabilities/<name>/` holds 20 folders: 12 with a `module.nix`, the others scripts and web only (`ls capabilities/*/module.nix`).
  `scripts/pkg.py` accepts `kind` = `recipe` or `extension` only; `hs pkg new` has no capability template (docs/PLAN-packages.md, #238).
- The epic (#217) wants a repository `hobnix/capabilities` with optional capabilities as packages, so a capability can be released and
  put on a channel (docs/PLAN-channels.md) without a core release.

## Decision

1. **`kind = "capability"` is the third package kind.** A capability package is a `package.toml` (as for the other kinds: name, version,
   `requires_core`, title en/de) that also carries what `capability.toml` carries today (`requires`, `provides`, `needs`, `nix`,
   `implied_by`, `variants`). It lives in the repository `hobnix/capabilities` (`index.toml`, one folder per package), is fetched, signed
   and verified by `hs pkg` exactly like the other kinds (ADR 0008 rule 5), and is addressed by `name`.
2. **What stays in the core, by rule.** A part stays in the core when the server cannot start, be reached, store data or be recovered
   without it. That is: storage (pools, SnapRAID, encryption, vault), backup and restore, samba, incus, the web interface with its generic
   renderers, the registry loader, notifications (`notify`), `hs` itself (dispatcher, `ui.sh`, `i18n.sh`, `secret.sh`, `setting.sh`,
   `state.sh`), the installer, `hs pkg`. Everything else that ADR 0008 / PLAN-packages call a capability (metrics, tailscale, vps, the edge
   roles, docs, gateway, dashboard, network, ad, reverse-proxy, docker, live-state) is a *candidate* for the capabilities repository and
   moves one at a time (see Consequences), never as one batch. A candidate that another part refuses to run without
   (`needs`, ADR 0008 rule 7) is marked `core = true` in the index, as for recipes.
3. **The manifest has one source.** After a capability is a package, `package.toml` is its manifest and `capability.toml` is removed from
   that folder; `scripts/schema-gen.py` and the loader read the installed packages. Until then both formats are read and
   `tests/capabilities.sh` checks that they agree (the same bridge step 1 of docs/PLAN-packages.md used for recipes).
4. **A capability package that ships a `module.nix` comes only from a default repository.** This closes the open point "Package-supplied
   Nix modules" of docs/PLAN-packages.md for the capability kind: a third-party Nix module is arbitrary code evaluated into the system, so
   a repository added by the user may ship scripts, commands and web declarations, never `module.nix`. How the module reaches a pure Nix
   evaluation is #221 and is not decided here.
5. **Installing is not enabling** (ADR 0008 rule 6). `hs pkg install` fetches and verifies; enabling is the existing machine.toml
   `capabilities` list, and a package with a `module.nix` takes effect only after `hs rebuild`. A package without one takes effect at
   once (overlay /var/lib/hs/capabilities-on|off), as extensions do today.
6. **Core-side generated files are produced on the machine for installed packages** (schema options with `capability = "<name>"`,
   `capabilities.tsv`, registry rows). #224 decides where and when; the rule here is that a package that is not installed adds nothing,
   and a package that is removed leaves no rows, options or pages behind.
7. **Removal and compatibility are part of the kind.** A capability refuses removal while an enabled capability `requires` it, and
   states `requires_core` like every package (ADR 0008 rule 4). Version-compatibility checks between capabilities and the core are #235.
   Removal never deletes data a capability created (PLAN-packages: "`hs pkg remove` never deletes data").

## Consequences

- A capability can be released and channel-gated on its own; the cost is that Nix modules now have a second source of truth outside the
  core tree, so the nix-matrix job (`scripts/dev/nix-matrix.sh`) must run against the installed or vendored set (#221).
- The core list becomes testable: a part is on the list because a start without it fails, not because of history.
- Follow-ups: #221 (vendored `module.nix`), #224 (regeneration after install), #235 (uninstall, compatibility), #225 and #228 (the new
  repository and the first move; pilot candidates are the capabilities without `module.nix`, for example `ad`, `network`, `docs`).
- The 20 existing folders are not moved by this record.

## Open points

- Which candidate moves first, and whether `metrics`, `tailscale` and `vps` ever leave the core (PLAN-packages lists them as core today).
- Whether `core = true` capability packages are fetched by `hs pkg install --core` at first run, as the five recipes are.
- The API level for capabilities beyond `requires_core` (for example a level for the `module.nix` option names under `hs.*`).
