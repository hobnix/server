---
paths:
  - "packages/**"
  - "scripts/recipes/**"
  - "scripts/recipe*.sh"
  - "scripts/pkg*"
  - "scripts/ext.sh"
  - "scripts/dev/export-package-repos.py"
  - "scripts/lib/recipe-path.sh"
  - "scripts/lib/registry-load.sh"
  - "capabilities/games/**"
  - "capabilities/posters/**"
  - "config/package-repos.toml"
  - "config/trusted-keys/**"
  - "tests/pkg*.sh"
  - "tests/recipe*.sh"
  - "tests/media-recipes.sh"
  - "tests/declare-service.sh"
  - "tests/ext.sh"
  - "tests/matrix-hook.sh"
  - "tests/sunshine.sh"
  - "tests/steamos.sh"
---

# Recipes, packages, extensions

Loaded when you touch the files above (path-scoped rule). The root CLAUDE.md has the rules that always apply.

- **Packages** (docs/PLAN-packages.md; step 1 built 2026-10-28): recipes and extensions are both *packages* with a semver `version` and `requires_core` (the API level in scripts/lib/api-level) in a `package.toml`: `packages/<recipe>/package.toml` (`run.sh` beside it; the header lines of run.sh must agree, tests/pkg.sh) and `capabilities/<ext>/package.toml`. `hs pkg list|updates|validate`, `hs sys pkg list`, scripts/pkg.py; `hs recipe` records the applied version in /var/lib/hs/packages/installed.toml. A new recipe needs its package.toml (`python3 scripts/pkg.py convert scripts/recipes/<name>.sh`). Recipes install themselves from pinned releases (NO community-scripts any more); `piece`/`fetch_pinned`/`ensure_file` in recipes/_lib.sh and `hs recipe <name> --check` do only what changed. A recipe package may carry commands.tsv + `[web.*]` (pilot `arr`: `hs ext arr status`). Repositories: `hs pkg repo|fetch|available|install|update|remove` (scripts/pkg_repo.py; release tags `vX.Y.Z` signed with an SSH key, only the newest tag that verifies against config/trusted-keys/<repo>.allowed_signers (defaults) or the key given at `hs pkg repo add` is used, installs are read-only copies in /var/lib/hs/packages/current, `update` shows the git diff first and needs `--yes` without a terminal; never a branch, never an unsigned tag unless the repo was added `--unsigned`). Step 5 (2026-10-28): recipes moved to packages/<name>/run.sh, the games/posters scripts into their capabilities/ folders (HS_SCRIPTS points them at the core helpers); `python3 scripts/dev/export-package-repos.py [--out <dir>]` writes the clean repositories recipes and extensions (index.toml, one commit, CI that validates against the core via `pkg.py repo-check`); tests/pkg-export.sh proves the way back (signed tag, add, fetch, install). The packages are still ALSO in this repository: they leave it only after the two repositories are published, signed and their keys are in config/trusted-keys/, otherwise a fresh install would have no recipes (the six the core refers to by name are flagged `core = true` in the index). Next: step 6, the public-release cleanup.

- **Recipes and apps** (details: docs/Entwicklungsnotizen.md#recipes-and-apps). `hs recipe <name>` runs packages/<name>/run.sh (found by scripts/lib/recipe-path.sh: the checkout, /etc/nixos, or /var/lib/hs/packages/current for one installed from a repository), idempotent, built from the helpers in scripts/recipes/_lib.sh (+ _media.sh; recipes find them through HS_RECIPE_LIB / HS_SCRIPTS, which recipe.sh exports). A file only one recipe uses sits beside its run.sh (`$(dirname "$0")/x`); shared ones stay in scripts/recipes/files (`ensure_container`, `fixed_address`, `step`, `spin`, `in_ct`, `wait_page` (waits for the container's web page, options in _lib.sh), `ok`/`note`/`warn`/`fail`, `box`); never print raw command output, write new ones the same way. `hs recipe <name> --name <container>` (= `RECIPE_NAME`) runs a recipe a second time under a container name of its own; its answers and its service descriptor (named after the container) are separate. Every recipe has the header lines `# kind: generic|personal`, `# needs: docker share tailscale|-` and `# uses: gpu|-` (tests/recipes-meta.sh checks them against the script). A recipe that needs answers up front also has `# input: form` and one `# ask: KEY|label|text|secret|choice:a,b|default|pattern|when` line per question (`hs sys recipes asks`; the web form sends text as `--set KEY=value` and ONE secret on stdin, which the job reads with `answer KEY` from a root-only file; never read a secret from the environment or argv); `# input: terminal` = needs a person at a terminal (domain). Preferences are asked once and stored in /var/lib/hs/recipe-<ct>.conf; the closing text holds only clicks that cannot wait and ends with `$(docs_hint <guide slug>)`. Under `set -euo pipefail` a `$(sed ... missing-file | tail)` kills the script: add `|| true`. Rules: never a Zoraxy rule for admin or login-less pages (Tdarr, Sunshine 47990/8083, Grafana, Matrix hook, docs site); `hs remote` shares are never in /bulk, parity or backup and arr/Tdarr never get them; Matrix messages go in addition to ntfy, never instead of it, and rooms stay unencrypted; never put a `raw.lxc` `lxc.cgroup2.devices.allow` line on an unprivileged container. The game-streaming server container (sunshine) is PARKED (exits unless RECIPE_FORCE=1). Documentation: the page Docs of the web interface (capability `docs`, on with `webUi = true` unless `webDocs = false`; notes capabilities/docs/NOTES.md); `hs docs build` (scripts/docs-build.sh) writes the Markdown and index.json it serves, `hs update` runs it; the recipe `docs` is gone (2026-10-23). A new English-only doc must be named PLAN-*.md or added to the case in docs-build.sh, and listed in docs/categories.tsv and docs/README.md (tests/docs.sh); guides use no raw HTML tags (the renderer shows them as text).

- Pelican: run artisan as www-data (root-owned cache files cause 500s).

- Wings behind Zoraxy: add response headers `User-Agent: Pelican Wings/<ver> (id:<token_id>)`
  and `Access-Control-Expose-Headers: User-Agent`, otherwise the node heart stays red.

- Pelican allocations must use IP 0.0.0.0, not 10.10.95.31 (Docker only DNATs the bound IP,
  breaking Tailscale access).

- Posters (extension `posters`, off by default): `hs ext posters generate` (old word `hs generate poster` is a legacy row for one release; guided, capabilities/posters/generate-poster-guided.sh) over the system command `hs sys ext posters generate` (generate-poster.sh, never asks, key<TAB>value lines) over capabilities/posters/poster.py (Pillow, `python3.withPackages` in configuration.nix; Inter fonts from recipes/files/matrix-card/fonts). Eyebrow and title required, colour and seed random (the colour derived from the seed, so a seed is reproducible). capabilities/posters/guide.md, tests/generate-poster.sh; not run on the server yet.
