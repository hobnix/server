# 0017: The capabilities repository: layout, vendored Nix modules, regeneration on the machine, CI across repositories, channels and release flow

Status: Accepted (2026-11-10)
Issue: hobnix/server#217 (epic), with #221, #224, #225, #228, #229, #231 and #233. Builds on ADR 0007 (branches and releases), ADR 0008
(capabilities and packages) and ADR 0009 (a capability is a package kind); it does not repeat them.

This record is a plan. Nothing in it except the empty repository hobnix/capabilities is built. Numbers 0015 and 0016 are taken by records
that are still open in their own pull requests, so this one is 0017.

## Context (checked 2026-11-08 on develop)

- ADR 0009 decided that `kind = "capability"` is a package kind, that the repository is `hobnix/capabilities` (`index.toml`, one folder per
  package), that a capability with a `module.nix` may come only from a default repository, and that derived files are produced on the
  machine. It left open *how* the module reaches a pure evaluation (#221), *where* regeneration runs (#224), the CI (#228), the wizard
  (#229) and the repository itself (#225).
- `capabilities/` in the core has 20 folders; 12 have a `module.nix` (backup, edge-mail, edge-ports, edge-status, edge-watcher, gateway,
  incus, live-state, metrics, samba, storage, tailscale). `capabilities/default.nix` loads `./<name>/module.nix` for every capability that is
  on; `configuration.nix` computes the list of enabled capabilities from `machine.toml` (`capabilities`, plus implied ones).
- The system is a plain, non-flake NixOS configuration in /etc/nixos (no `flake.nix`; `scripts/rebuild.sh` runs `nixos-rebuild switch`).
  `grep -rn impure` finds no `--impure` today. The risk is future: the obvious way to load a package's module is
  `import /var/lib/hs/packages/current/<name>/module.nix`, an absolute path outside the checkout. That evaluates only impurely (and not at
  all under flakes), cannot be evaluated by `scripts/dev/nix-matrix.sh` in CI, and makes the system closure depend on a mutable directory.
- `scripts/pkg.py` supports `recipe` and `extension` only; packages install to `/var/lib/hs/packages/current/<name>` (read-only, root).
  `scripts/schema-gen.py overlay` already writes `capabilities.tsv` to `/var/lib/hs/generated/` for installed capability manifests
  (docs/PLAN-capabilities-on-machine.md); package options are not built.
- Channels are built for the core (PR #280, #281; docs/PLAN-channels.md): `updateChannel`, signed tags verified against
  `config/trusted-keys/server.allowed_signers`, `hs pkg` follows beta tags. Not built: the first signed release, `release.sh beta`, the
  installer ISO policy, web texts (#231 open boxes).
- `hobnix/capabilities` exists (created 2026-11-03: `main`, `develop`, AGPL-3.0 licence, a one-line README). Neither branch is protected.
  `hobnix/server` is AGPL-3.0; `hobnix/recipes` is MIT. `hobnix/recipes` and `hobnix/extensions` use the layout `index.toml` +
  `<kind>/<name>/package.toml`, a `check` workflow that checks out the core and runs `pkg.py validate`, `pkg.py repo-check` and the repository's tests,
  and `scripts/dev/release.sh` for tags. The core's `packages` job checks both out the other way round.

## Decision

### A. Repository `hobnix/capabilities` (#225)

1. **Layout** follows the other package repositories:
   ```
   index.toml                     versions of every package (must equal package.toml; pkg.py repo-check)
   capabilities/<name>/package.toml    kind = "capability" manifest (rule 4)
   capabilities/<name>/module.nix      optional Nix module (rule 8)
   capabilities/<name>/commands.tsv, options.toml, i18n/, scripts/, web, tests/, NOTES.md   as for any package
   tests/run-all.sh               runs every package's tests against a core checkout (HS_CORE=...)
   .github/workflows/check.yml    the same shape as hobnix/recipes
   README.md LICENSE CONTRIBUTING.md SECURITY.md
   ```
2. **Licence AGPL-3.0**, as hobnix/server (already in place): a `module.nix` is evaluated into the core's system and is a derivative of it.
   hobnix/recipes and hobnix/extensions stay MIT; that difference is deliberate and is recorded in the README.
3. **Branches** as ADR 0007: `develop` is the default branch, `main` holds released code, release = merge commit + signed `vX.Y.Z` tag cut by
   `release.sh`. `main` and `develop` are protected (rule 28). Contributions need a DCO sign-off once hobnix/server#270 is decided; until then
   CONTRIBUTING says "sign off with `git commit -s`".
4. **The manifest is `package.toml`** (ADR 0009 rule 3), with the existing `capability.toml` fields in the same file:

   ```toml
   name = "example"                  # = folder
   version = "1.0.0"                 # semver; the index must agree
   kind = "capability"
   title = "..."  ;  title_de = "..."
   requires_core = ">=7"             # API level of the core helpers
   requires_nix_api = 1              # level of the option names the module reads or sets under hs.* (new, rule 9)
   requires = ["gateway"]            # other capabilities (never variants)
   provides = [] ; needs = [] ; implied_by = [] ; variants = {}
   core = false                      # true: the core refuses to run without it (ADR 0009 rule 2)
   module = "module.nix"             # optional; present only for default-repository packages
   options = "options.toml"         # optional, #224
   ```
   `scripts/pkg.py validate` and `repo-check` gain the `capability` kind in the core first (a core PR), then hobnix/capabilities can pass
   its own CI.
5. **Versioning is per package** (semver in `package.toml` and `index.toml`) and per repository (signed `vX.Y.Z` tag on `main`). A server
   installs a package at the version the repository tag's index names; nothing is fetched from a branch head. A change that needs a newer core
   raises `requires_core`; a change that people must act on is a major bump (rule of hobnix/recipes CONTRIBUTING).
6. **Pilot (#225):** the first capability that moves is one **without** `module.nix`, so that the Nix path is not on the critical path of the
   first move. Candidates named by ADR 0009: `ad` (a manifest only; `configuration.nix` still computes it from `adDomain`, so it needs the
   `core = true`-style check first), `network`, `docs`. The owner picks (open question 1). The repository scaffold of this task (README,
   LICENSE, CONTRIBUTING, `index.toml` with no packages, a manifest example under `examples/`, an empty `check.yml`) is the target; it moves
   no capability.

### B. Nix modules reach a pure evaluation by vendoring (#221)

7. **No `--impure`, ever, for capabilities.** `hs rebuild`, the installer and the nix-matrix job evaluate the configuration without
   `--impure` and without `NIX_PATH` entries that point into /var/lib/hs.
8. **Vendoring at install.** When `hs pkg install|update|remove` changes a capability that has a `module.nix`, it copies (not symlinks) the
   verified package tree of that capability into **`/etc/nixos/vendor/capabilities/<name>/`** and rewrites
   **`/etc/nixos/vendor/capabilities.lock`** (one line per package: name, version, commit, sha256 of the tree). `vendor/` is listed in the
   checkout's `.git/info/exclude` (not tracked, so `hs update`'s fast-forward never conflicts, and `git status` stays clean).
   `capabilities/default.nix` loads `./<name>/module.nix` from the core tree for core capabilities and from `../vendor/capabilities` for the
   vendored ones, by the same rule as today (enabled and present). Both are relative paths inside the checkout, so evaluation is pure.
9. **Integrity at evaluation.** `default.nix` reads the lock with `builtins.fromTOML`/`readFile` and asserts, for every vendored module that
   it is about to import, that `builtins.hashFile "sha256"` of its `module.nix` equals the lock entry (a pure builtin); a mismatch is an
   evaluation error that names the package. `hs pkg` re-verifies the signature and the tree hash when vendoring, so the trust chain is:
   signed tag, then `/var/lib/hs/packages/current/<name>@<commit>`, then the vendored copy with its recorded hash. Removing a package
   removes its vendored folder and lock line; the next `hs rebuild` applies it.
10. **A name that exists in the core is refused** (nothing shadowed, as the overlay does), and a package from a non-default repository
    never gets a vendored `module.nix` (ADR 0009 rule 4); `pkg.py` refuses at install, not at rebuild.
11. **Module API.** A vendored module receives the same arguments a core module gets today (`{ config, lib, pkgs, hs, ... }`).
    The option names it may read or set under `hs.*` carry an integer `requires_nix_api` that only goes up, with the deprecation rule
    of ADR 0008 rule 4. The core states the current level in `capabilities/options.nix`.
12. **Installing is not enabling.** Vendoring happens at install; the module is imported only while the capability is in `machine.toml`
    `capabilities` (or implied). The wizard (rule 21) sets that list and calls `hs rebuild`.

### C. Derived files after install (#224)

13. **Settings-only options need no rebuild and no checkout change.** A package ships `options.toml` (the `[[item]]` tables of
    `config/schema.toml`, every item with its own `capability = "<name>"`). `schema-gen.py overlay write` validates them against the core schema
    (no key clash, no unknown `store`) and writes, into `/var/lib/hs/generated/`: `capabilities.tsv` (built), `schema.overlay.json`,
    `config-keys.overlay`, `layout.overlay.json`. `hs config`, `config-change.sh`, `web-serve.py`, the `CONFIG_KEYS` allowlist and the web
    settings layout read the overlay after the core's file. This is design 1 of docs/PLAN-capabilities-on-machine.md; designs 2 (edit the
    checkout) and 3 (no options) are rejected: 2 breaks "generated files are never edited" and `hs update`, 3 limits what a capability can be.
14. **Options with `store = "machine"` and Nix defaults** are not in `config/defaults.nix`. Their defaults are declared by the module
    (`mkOption { default = ...; }`), and the value comes from `machine.toml` through the loader that already reads `machine.<key>`. They take
    effect at `hs rebuild`, and the overlay marks them "needs rebuild" so the web shows the same notice as for core machine options.
15. **Registry rows** already come from installed packages (`registry_rows`); nothing new. **When it runs:** `hs pkg install|update|remove`
    calls `schema-gen.py overlay write` as its last step and fails the install if the overlay does not validate (the package is then not
    activated; the previous overlay stays). A boot-time unit re-runs `overlay write` so a lost `/var/lib/hs/generated` is rebuilt from
    the installed packages, never the reverse.
16. **Removal leaves nothing:** overlay files are rewritten without the package; its options disappear from `hs config` and the web, while
    stored values in `machine.toml` / settings stay (never deleted, ADR 0009 rule 7) and are reported as "unused setting".

### D. CI across both repositories (#228)

17. **Both directions are checked, with one rule: a repository's CI checks out the other repository at the ref its own ref names.**
    - hobnix/capabilities `check` (every push and pull request): check out `hobnix/server` at the branch of the same name if it exists,
      else `develop` (a pull request that also needs a core change names the core branch in its description, read by the workflow);
      run `pkg.py validate`, `repo-check`, the package tests (`HS_CORE=...`), and the nix matrix (rule 18).
    - hobnix/server `packages` job (exists for recipes and extensions): add `hobnix/capabilities` at `develop` with the same two steps.
    - Release gate: the core's release pull request (develop into main) runs the matrix against `hobnix/capabilities` **`main`**
      (what stable servers get), not `develop`.
18. **Nix matrix.** `scripts/dev/nix-matrix.sh` gets `--vendor <dir>`: it vendors the packages of that checkout the way `pkg.py` does
    (rule 8) into the temporary copy, then evaluates the existing variants (each capability alone, all on, none), now also one variant per
    vendored capability. Evaluation stays pure. A capability that breaks alone, or whose `requires_core` / `requires_nix_api` is not met by
    the core under test, fails the job with the package name.
19. **Cost control.** The matrix needs Nix and Cachix (the `nixos` job today); it runs in hobnix/capabilities only when a `module.nix`,
    `package.toml` or `options.toml` changes (path filter, as `changes` in the core's ci.yml). Documentation-only pull requests run
    `validate` only.
20. **Required checks** for branch protection are the job names `check` (capabilities) and the core's existing required jobs.

### E. The wizard step (#229)

21. **A step "Optional parts" in the setup wizard and the web setup** (after storage, before the first rebuild) lists capability packages
    from the index of the default repository at the stable tag (`hs sys pkg list --kind capability`, existing contract). The user ticks what they want;
    `requires` are ticked and shown ("needs gateway"); `core = true` ones are not offered. The wizard shows the plan (what will be
    fetched, which tag, signed by which key, whether a rebuild is needed) and asks to confirm, then: `hs pkg install` each (rules 8, 15),
    write `machine.toml` `capabilities`, `hs rebuild` as a background job (jobs, ADR 0004). A package without `module.nix` takes effect at once.
22. **Offline or first install:** the installer ISO carries the stable index and the packages that were stable when the ISO was cut, so
    the wizard works without a network; a network is needed only for newer ones.
23. **Terminal and web use one contract:** a `hs pkg` plan line format (new rows only; existing shapes untouched). Strings go through
    `ui.sh` and i18n.

### F. Channels for capabilities (#231 completes)

24. **Capabilities follow the server's `updateChannel`** exactly as recipes and extensions do (docs/PLAN-channels.md): stable = newest
    signed `vX.Y.Z` tag of hobnix/capabilities; beta = newest tag incl. `-beta.N`; no edge for packages (a trust rule of ADR 0008: only
    tags or commits). `hs update` and `hs pkg updates` print `channel: <name> (<ref>)`.
25. **Compatibility gates the channel:** the newest tag a server may take is the newest whose every package's `requires_core` and
    `requires_nix_api` the installed core meets. A newer capability tag that needs a newer core is shown, not installed ("waits for core
    vX"). This is what lets the repositories release independently (#235).
26. **Order of updates:** the core moves first, then packages; a core update that would break an installed package (CI matrix rule 17)
    is not released. Beta and stable never apply unattended when a package ships a `module.nix` or a major bump (needs the owner's confirmation and
    a rebuild); a patch of a package without a module may apply silently only for default repositories (the open point of PLAN-packages).

### G. Release flow and branch protection (#233; write-up only for hobnix/server)

27. **Flow** (ADR 0007 made concrete, no `release/*` branch, owner decision 2026-11-10): `feature/*` → `develop`; `develop` is the release
    candidate (bug fixes only while a release is tested; the next milestone is built on its own long-lived branch); a pull request
    `develop` → `main` with a **merge commit**, signed `vX.Y.Z` tag on `main`, `main` merged back into `develop`. Beta tags
    `vX.Y.Z-beta.N` are signed on `develop`, as ADR 0007 says. The same flow applies to hobnix/recipes, hobnix/extensions and
    hobnix/capabilities via `release.sh` (which gains `beta`).
28. **Branch protection** (settings, `gh api`):
    - `main`: pull request required (1 approval, none for the sole owner while the team is one person: open question 5), required status checks
      (core: the jobs of ci.yml; packages: `check`), **linear history not required** (merge commits), no force pushes, no deletion,
      admins included, signed commits not required (tags are signed, ADR 0007), only the release pull request and hotfixes target it.
    - `develop`: pull request required, required checks, no force pushes, no deletion, auto-delete of merged branches.
    - **hobnix/capabilities (new repository): applied by this task.** **hobnix/server, hobnix/recipes, hobnix/extensions: not applied; this
      record is the write-up (the owner decides).**
29. **Required for the first release:** the real public key in `config/trusted-keys/server.allowed_signers` and the first signed tag on
    hobnix/server (the open boxes of #231). hobnix/capabilities needs its own `config/trusted-keys/capabilities.allowed_signers` in the core
    (same release key, one line: the core decides whom it trusts).

## Phased rollout

| Phase | What | Issues | Gate |
| --- | --- | --- | --- |
| 0 | This record accepted; empty `hobnix/capabilities` scaffold with protection on `main` and `develop` | #225 (repository only) | owner answers the open questions |
| 1 | Core: `capability` kind in `pkg.py` (validate, repo-check, install, list), trusted key file, `hs sys pkg list --kind` | #225, #238 | tests/pkg.sh |
| 2 | Vendoring (rules 8 to 12) and `nix-matrix.sh --vendor`; a throwaway test capability with a `module.nix` proves a pure evaluation | #221, #228 | nix-matrix green, no `--impure` anywhere |
| 3 | Overlay for options, installed from `hs pkg` (rules 13 to 16) | #224 | tests for validation, removal |
| 4 | Pilot: move one capability without `module.nix`; the core's list of capabilities shrinks by one; CI both ways | #225, #228 | both repositories green, a server installs it from the stable tag |
| 5 | Wizard step (rules 21 to 23) with the installer ISO carrying the index | #229 | tested on a throwaway VM and on hardware ("Not tested on hardware yet." until then) |
| 6 | Channels complete for capabilities and compatibility gating (rules 24 to 26), first signed core release, `release.sh beta` | #231, #235 | stable followed on a real server |
| 7 | Release flow and protection on the remaining repositories (rules 27, 28) | #233 | owner approval |
| 8 | Move the capabilities that have a `module.nix`, one at a time, starting with the least entangled (decided per capability, ADR 0009 rule 2) | #217 follow-ups | each: matrix green with it removed from the core |

Phases 1 to 3 are core-only and can run in parallel after phase 0 (they touch `pkg.py`, `nix-matrix.sh`/`default.nix`, `schema-gen.py`).

## Consequences

- A capability becomes releasable and channel-gated without a core release; the price is a second tree of Nix modules whose compatibility
  with the core is only as good as the matrix and `requires_nix_api`.
- A vendored copy means the running system is described by files in /etc/nixos that are not in git. They are reproducible from
  `capabilities.lock` plus the packages directory; the config backup (`hs backup config`) must include `vendor/` or the lock, and a rebuild
  rehearsal should be able to recreate it. Both are follow-ups.
- `hs update` (ff-only on the core) and `hs pkg update` are separate steps; a window exists where the core is new and a vendored module is
  old. Rule 25 and rule 9 turn that into a refused rebuild with a named package instead of a silent breakage.
- hobnix/capabilities carries AGPL while the other package repositories are MIT: a recipe author moving to capabilities relicenses.

## Decided by the owner (2026-11-10)

1. **Pilot capability:** `network`, if its manifest has no `module.nix` dependency (checked in phase 4); otherwise `docs`.
2. **Vendor location:** `/etc/nixos/vendor/capabilities/`, ignored by git.
3. **Licence:** AGPL-3.0 (as set).
4. **No `release/*` branches.** `develop` is the release candidate; beta tags come from `develop` (rule 27 as above).
5. **Approvals on `main`:** status checks and the pull request only, no required review while the team is one person.
6. **Trust key:** the core release key; the core lists it in `config/trusted-keys/capabilities.allowed_signers`.
7. **Cross-repository CI pairing:** a branch of the same name if it exists, else `develop` (rule 17).
8. **Silent patch updates** of packages without a module: no, until a real server has run the flow once; then default repositories only.
9. **`edge` does not follow** capabilities' `develop` (tags only).
10. **Backup of `vendor/`:** `hs backup config` includes `vendor/` and its lock, so a rebuild does not depend on reaching a repository.
