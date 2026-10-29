# Packages: recipes and extensions as one thing, in repositories of their own

Status: design, decided with the owner on 2026-10-28; steps 1 to 5 are built (see "Order of work"); step 6, the public release, is left. It replaces the "Packages from a repository (later)" section of
docs/PLAN-extensions.md and the "recipes as packages" open point there. Goal behind it: the project becomes public and open source, so
other people can write, update and share parts without touching the core.

## Why one concept

A recipe (container or VM with an app in it) and an extension (commands and a page on the host) look different from outside but are built
from the same pieces: scripts, command rows, translations, tests, a web declaration, a service descriptor. Today they are two mechanisms:

| | Recipe now | Extension now |
| --- | --- | --- |
| Where | `scripts/recipes/<name>.sh`, one bash file | `capabilities/<name>/` folder with `capability.toml`, `commands.tsv` |
| Metadata | comment headers (`# kind`, `# needs`, `# uses`, `# input`, `# ask`) | `capability.toml` |
| Commands | `hs recipe <name>`, fixed `sys recipes ...` rows in the core | `hs ext <name> <command>`, rows from its `commands.tsv` |
| Web | the generic Recipes page; no page of its own | `[web.reads]`, `[web.changes]`, `[web.page]` |
| Version | none | none |

After the change both are a **package**. The only difference is `kind`: a `recipe` has an installable payload (a container or VM, a
service descriptor, stored answers), an `extension` is host-side only. A recipe can now also declare commands and a page, so the recipe
`arr` can show a dashboard of its services and basic numbers, and an extension such as Posters stays what it is.

## The package folder

```
<name>/
  package.toml        manifest (below)
  commands.tsv        optional: command rows (registry format; today's rule: only under `ext <name> ...` / `sys ext <name> ...`)
  run.sh              recipe: the idempotent installer (today's scripts/recipes/<name>.sh); extension: not needed
  scripts/ files/     anything the commands or the installer use; `@/file` points here
  i18n/<lang>.tsv     translations, read while the package is on
  NOTES.md            what it is, the rules that stay with it
  tests/              the package's own tests (run by core CI against the package, see "Compatibility")
  module.nix          optional (extension only for now; needs `hs rebuild`)
```

### package.toml

```toml
name        = "arr"
version     = "1.4.0"                 # semver of the PACKAGE (not of the apps inside)
kind        = "recipe"                # recipe | extension
title       = "Radarr, Sonarr, Lidarr, Prowlarr, Bazarr"
title_de    = "Radarr, Sonarr, Lidarr, Prowlarr, Bazarr"
requires_core = ">=1"                 # integer API level of the core helpers, see "The core API"
license     = "MIT"
authors     = ["Name <mail>"]
homepage    = "https://..."

# what today's header lines say
audience    = "generic"               # generic | personal  (`# kind:`; personal = fits one author's setup, hidden by default)
needs       = ["docker", "share"]     # docker share tailscale
uses        = []                      # gpu
input       = "form"                  # form | terminal | none; the questions are [[ask]] tables:
[[ask]]
key = "SOMETHING"
label = "..."
type = "text"                         # text | secret | choice
default = ""

[web.page]                            # unchanged from docs/PLAN-extensions.md; a recipe may use it now
...
```

`kind` (what it is) and `audience` (who it is for) are two fields: the old `# kind: generic|personal` becomes `audience`.

A recipe keeps working as one idempotent bash script built from `_lib.sh`; nothing about how recipes are written changes except where the
metadata lives. A mechanical converter (`hs pkg convert`) turns an old header into `package.toml`; the headers go away after the move.

## Versions and "is there an update"

- `version` is semver of the package: a patch for a fix, a minor for a new feature or question, a major for something that needs a person
  (a changed share, a renamed container). The major bump shows a note from the package's `CHANGES.md` before it applies.
- The server records what is installed in `/var/lib/hs/packages/installed.toml`: name, repository, version, commit, date.
- `hs pkg list` shows installed and available packages with `version installed / available`; `hs pkg updates` lists only those with a newer
  version in their repository; the web Packages page shows the same with an "update available" chip, and the top bar counts them.
  `hs health` does not alarm on an available update (an update is not a problem), but the weekly summary mentions them.
- A package update does **not** change a running app by itself. For a recipe it replaces the package files and says "run
  `hs recipe <name>` to apply"; the recipe is idempotent, so running it again applies the new version. Updating the apps inside the
  container is a separate thing (their images, `hs update` for the OS), and a recipe pins its image tags in its own script, so a package
  version change is the only way those move.
- `requires_core` is checked on install and update: a package that needs a newer core than the server has is shown as "needs hs update
  first", never half installed.

## Repositories

- Two repositories are on by default: **recipes** and **extensions**. Each is a git repository with `index.toml` at the root
  (one table per package: name, version, kind, title, path, `requires_core`) and one folder per package. The index is what `hs pkg
  updates` and the web page read, so listing does not clone every package.
- The list lives in machine.toml (`packageRepos`, the defaults are written by the schema, so a new server has them). A user adds one with
  `hs pkg repo add <url>`, removes with `hs pkg repo remove <name>`, `hs pkg repo list` shows them with their trust state.
- Packages are fetched to `/var/lib/hs/packages/<name>@<commit>`, owned by root and read-only (so `@/file` scripts do not come from a
  folder adminuser can write; closes the point in docs/PLAN-extensions.md "Security"). Only a **tag or commit** is ever checked out, never a
  branch head. The repo's latest release tag is the "available" version.
- Two repositories with the same package name: the second is **refused** with a message; the first one wins, nothing is shadowed
  silently. A package is addressed by `name`; `repo/name` is accepted where it must be exact.
- The core repository keeps only what the core needs to run at all. Packages the core refers to by name (for example `docker` as a need,
  the `docs` capability) are listed in "What stays in the core" below.

### Trust (decision: signed tags for repos beyond the defaults)

Packages run as root, so installing one is trusting its author.

- The two default repositories are trusted by a key shipped in the core (`config/trusted-keys/`), the same way a Linux distribution ships
  its signing keys. Every release tag is signed (SSH or GPG signature); `hs pkg` verifies the tag before it checks anything out and
  refuses an unsigned or wrongly signed tag.
- Adding another repository shows its URL and the signer fingerprint(s) and needs the user to **type the repository name** to confirm,
  after which that key is trusted for that repository only. A repository without signed tags cannot be added by default; there is an
  explicit `--unsigned` switch that makes the user type the name twice and marks the repository "unsigned" in every list.
- `hs update` (and the web update) shows the **diff** between the installed and the new tag (manifest, command rows, web declaration,
  scripts) and asks before replacing anything. `--yes` does not skip that for a package whose diff touches `commands.tsv`, `[web.*]` or a
  new `needs`; it applies silently only for a pure patch release of a package the user already approved at that major version
  (open point below).
- Nothing downloads or enables a package by itself; `enable` stays a person's action as today.

## The core API (what packages may rely on)

Moving recipes out of the repository turns `scripts/recipes/_lib.sh`, `scripts/lib/ui.sh`, `i18n.sh`, `secret.sh`, `setting.sh`, `state.sh`,
`services.sh declare` and the registry format into a **public contract**. Each gets documented in `docs/Package-API.md` with an integer `HS_API_LEVEL` (starts at 1 and only goes up). Rules:

- a function in the contract is only removed after one API level where it prints a deprecation warning;
- `requires_core` names the lowest level a package works with; the core refuses a package that needs more;
- core tests run every package of the default repositories against the current core (see "Compatibility").

## No third-party installers: our own formulas

Decision 2026-10-28: the project no longer depends on community-scripts (https://community-scripts.org and the GitHub repository
`community-scripts/Incus`). Every reference goes: the command `hs ct add-community` (`scripts/cs.sh`, `manage-ct.sh --create-cs/--cs-list`),
its entry in the guided container dialog, the German guides (Container einrichten 2.4, Homeserver-Anleitung 9.2 and the curl note), the
README row, the `var_ram`/`var_os` note in CLAUDE.md and the build dependencies configuration.nix keeps for them.

Two recipes use it today and need a formula of their own first: `pelican` (panel and wings: `pelican-panel`, `pelican-wings`) (and `homepage`, removed 2026-10-29: the dashboard is built into the web interface).
They are written like every other recipe (`ensure_container`, `step`, `spin`, `in_ct`, from the makers' releases or images, pinned and
checked, see "Smart updates"), asking nothing interactive, so they also become web-startable. Until both exist, `cs.sh` stays; the removal
is the last commit of that work, not the first. A free-form installer for "any app" is not replaced: whoever wants an app we do not have
writes a package (that is what the repositories are for).

## Smart updates: do only what changed

A recipe run today is idempotent but not frugal: it downloads and rebuilds what is already current. A recipe (and the package loader)
must **detect what is up to date and skip it**:

- **A stamp per piece.** `_lib.sh` gets `stamp_get <key>` / `stamp_set <key> <value>` (a root-only file per container, inside the
  container for things that live in it, in `/var/lib/hs/recipe-<ct>.stamps` for host-side things). A piece is a downloaded binary, an
  image tag, a generated config, a database schema version.
- **`fetch_pinned <name> <url> <sha256> <dest>`**: compares the stamp and the file on disk with the pin; downloads only when they
  differ, verifies the checksum, then sets the stamp. A recipe states the version it wants (a release tag, an image digest) in one
  place at the top, so a package update that moves the pin is exactly what makes it download the new thing.
- **`ensure_image <ct> <image:tag>`** pulls only when the local image id differs from the wanted digest; **`ensure_file <path>`**
  rewrites a config only when its generated content changed (and keeps a copy of a hand-edited one, as the removed `homepage` did).
- **`hs recipe <name> --check`** (no changes, no questions): prints one line per piece, `current` or `would update: <piece>
  (<old> -> <new>)`, exit 0 when everything is current. The web Packages page shows it as the detail of an "update available" chip.
  The plan lines of `--dry-run` become the same list, so the preview says what will really be downloaded.
- **Packages themselves** follow the same rule: the repository index carries a version and a content hash per package; `hs pkg update`
  fetches (shallow, sparse) only the packages whose hash differs from `installed.toml`. Unchanged packages cost one small index read.
- A step that detects "current" prints it as `ok` (no spinner, no download progress), so a re-run of a healthy recipe is short and quiet.

Rules: a pin is never "latest"; the recipe never upgrades the app inside a container without the pin changing; `--check` must be safe
to run as a timer (nothing written except stamps it reads).

## Commands

`hs pkg` is the single family; the old words stay for one release as `legacy:` rows.

| Command | What |
| --- | --- |
| `hs pkg list [--kind recipe\|extension]` | installed and available, version, state |
| `hs pkg updates` | only those with a newer version |
| `hs pkg install <name>` / `remove <name>` | fetch to the packages folder and register; remove deletes the package files only (a recipe's container is `hs ct`, never touched here) |
| `hs pkg update [<name>]` | show the diff, ask, replace |
| `hs pkg enable <name>` / `disable <name>` | what `hs ext enable/disable` does today (capabilities overlay) |
| `hs pkg repo add\|remove\|list` | repositories |
| `hs pkg convert <old>` | one-off: old recipe header or capability folder to `package.toml` |
| `hs recipe <name> ...`, `hs ext <name> ...` | unchanged for users: still how a recipe is run and an extension's commands are called; the namespace rule from docs/PLAN-extensions.md stays |

Machine-readable twins: `hs sys pkg list|updates|repos|plan|start` with the same plan-then-start pattern as other web changes. The web page
Packages (tree: next to Recipes and Extensions, which merge into it over time) shows the list with version and update chips; Recipes and
Extensions pages stay as filtered views.

## What stays in the core

"Could someone else write this?" decides, as for extensions. The core keeps: storage, backup, encryption, vault, samba, incus, the web
interface and its generic renderers, `hs services`, the registry loader, notifications, metrics, docs build, tailscale, vps, edge roles,
presets, the installer. These stay capabilities of the core.

Recipes that other parts reference by name (`docker` is a **need**, `zoraxy` is the reverse proxy the `reverse-proxy` capability
manages, `homepage` (removed 2026-10-29, the dashboard is built into the web interface) was the dashboard capability's backend, `domain` is the Active Directory capability's installer, `monitoring`, `ntfy`)
are the **hard cases**: they ship in recipes but are marked `core = true` in the index; core CI refuses a core change that breaks
them, and a fresh install fetches them as part of setup. Whether some should rather become a core capability is decided one by one in
step 3, not by rule.

## Personal packages

Decision: author-specific recipes stay in recipes with `audience = "personal"`: hidden from `hs pkg list` and the web page unless
the user asks (`--all` / "show personal"), never installed by a preset except the author's own. Today these are `cloudflared`, `domain`,
`livekit`, `pelican`, `stalwart`, `zoraxy` (header `kind: personal`); several of them (`domain`, `zoraxy`) are the hard cases above, so
before the repository is made public each is checked: does it contain addresses, names or choices of one household? The facts belong in
the author's private preset repository and stay out of the package; the public tree keeps `presets/example-server.toml` with made-up values.

## Compatibility and CI across repositories

- recipes and extensions each carry a CI job that checks out the core at the `requires_core` level it claims, runs the
  package validators (manifest, registry rows, `tests/recipes-meta.sh` equivalent, shellcheck, `bash -n`, dry-run of every recipe) and
  the package's own tests.
- The core repository's CI checks out the default repositories at their latest tags and runs the same validators, so a core change
  that breaks a package is seen before release. The API level rule above is what keeps this from becoming an unmanageable matrix.
- Tests that today reach into `scripts/recipes/` or `capabilities/games` directly (tests/recipes-meta.sh, tests/ext.sh, tests/generate-poster.sh,
  tests/i18n.sh CORE list, tests/docs.sh) are split: format checks stay in the core against a tiny fixture package; per-package tests move
  with the package.
- Documentation: guides for a package live with the package (`docs/<slug>.md` inside it) and `hs docs build` collects them from the
  installed packages, so the docs page shows only what is installed; the German-for-the-cousin rule stays for the default repositories,
  community packages may ship English only.

## Order of work

Each step is shippable on its own and keeps the server working.

1. **Format and versions, in this repository** (built 2026-10-28: `scripts/pkg.py`, `packages/<recipe>/package.toml`,
   `capabilities/{games,posters}/package.toml`, `hs pkg list|updates|validate`, `hs sys pkg list`, installed versions recorded by
   `hs recipe`, tests/pkg.sh; the header lines stay the source until step 2 and the test keeps both in step). `package.toml` for every capability that is an extension and every recipe (converter,
   header lines stay as the source until the loader reads the manifest, then go). Add `version` everywhere (start at `1.0.0`), the
   `HS_API_LEVEL`, `hs pkg list` / `updates` reading local files only, `installed.toml`. Tests: manifest validator, converter round trip.
2. **Own formulas and smart updates.** `pelican` gets an installer of its own, `_lib.sh` gets the stamp and pin helpers
   ("Smart updates"), `--check` on every recipe; then `cs.sh` and every community-scripts reference are removed.
3. **Recipes get commands and pages** (built 2026-10-28: the loader and `scripts/web-serve.py` read `packages/<name>/commands.tsv` and the `[web.*]` tables of its `package.toml`; a recipe package is on once `hs recipe` has applied it; pilot `arr`: `hs ext arr status`, `hs sys ext arr status`, the page "Films and series"; `hs ext list` shows extensions only, `hs ext enable` refuses a recipe). Loader reads `commands.tsv` and `[web.page]` of recipes. Pilot: `arr` page with its services, state
   and basic counts (reads through `hs sys ext arr ...`). The generic Recipes page keeps working for recipes without a page.
4. **Repositories and trust** (built 2026-10-28: `scripts/pkg_repo.py`, `hs pkg repo|fetch|available|install|update|remove`, defaults in config/package-repos.toml, trusted keys in config/trusted-keys/<name>.allowed_signers, added repositories in /var/lib/hs/packages/repos.toml instead of a machine.toml option; installs go to /var/lib/hs/packages/current/<name> (read-only, the loaders read that folder), the one before to previous/; tests/pkg-repo.sh with SSH-signed tags in a local git repository; the two default repositories fail closed until their key files exist; the default URLs are github.com/hobnix/recipes and github.com/hobnix/extensions). `/var/lib/hs/packages/<name>@<commit>`, the loader's second location (`ext_package_dir`, `ext_roots`),
   `index.toml`, `hs pkg repo`, tag signing and verification, diff-and-ask in `hs update` and the web update, default repositories in the
   schema. Done against a local file:// repository first, so it is testable on the Windows checkout and in CI without the network.
5. **Split** (built 2026-10-29). The recipes are in github.com/hobnix/recipes (`recipes/<name>/`), the extensions in github.com/hobnix/extensions
   (`extensions/<name>/`); both carry `index.toml`, their own tests (`tests/run-all.sh`, run against a checkout of the core through `HS_CORE`),
   a CI that checks the core out, and German texts of their own (`i18n/de.tsv` per package; a recipe's file is loaded by `scripts/recipes/_lib.sh`).
   Releases are tags `vX.Y.Z` signed with the release key in `config/trusted-keys/{recipes,extensions}.allowed_signers`. The core holds no package
   any more: `hs pkg install --core` (called by `hs first-run`) fetches the five `core = true` recipes, `tests/fixtures/pkgtree` is the small fixture
   its own tests use, and its CI has a job `packages` that runs both repositories' validators and tests against the core. `gateway` stays a core
   capability; `passthrough` is an extension that requires it. Found on the way: the export from Windows dropped every executable bit (fixed in a
   release after v1.0.0), and the old i18n check matched part of a longer line, which had hidden an untranslated text. Left over: the web
   interface's `readsfor.js` still names the pages of games and posters; `hs pkg convert` and the header-versus-manifest check of the validator have
   done their job and can go; no fresh install or update of an existing server was run yet.
6. **Public release.** Personal data audit (including git history of the split repositories: secrets, hostnames, mail addresses), LICENSE
   per repository, CONTRIBUTING (how to write a package, the API doc, the review rule that a diff touching `commands.tsv`/`[web.*]`/`needs`
   is called out), issue and PR templates, a security contact, the trusted-key process (who may sign, how a key is rotated).

## Open points (decide when the step is reached)

- **Gateway and passthrough** (decided 2026-10-29): `gateway` (Traefik on the host, the `local-proxy` slot, ships a Nix module) is a core
  capability and stays here. `passthrough` (forward outside domains to reverse proxies on the LAN, `requires = ["gateway"]`, no Nix module)
  is an extension and moves to the extensions repository. An extension may therefore require a core capability; `hs pkg install` has to refuse it
  when the capability is missing, and the extensions CI checks it against the core. Recipes that publish services on the gateway (`arr`)
  only use the generic `hs services` interface, never gateway files, so they work without it.

- **Silent patch updates**: whether a patch release of an already approved package may apply without a diff prompt (leaning: only for
  packages in the default repositories, never for added ones).
- **Name of the core** and the organisation/URLs (`hobnix-*`): affects the default `packageRepos` values and the trusted keys.
- **API level numbering and the deprecation window** (one level, or a fixed number of releases).
- **Multi-instance recipes** (`--name`): the package is installed once, instances are the containers; the manifest may need a flag for
  recipes that cannot run twice.
- **Package-supplied Nix modules** (`module.nix`): a third-party Nix module is arbitrary code evaluated into the system. Leaning: only
  the default repositories may ship one; packages from added repositories are scripts only.
- **Rollback**: `hs pkg update` keeps the previous `@<commit>` folder until the next successful update so `hs pkg rollback <name>` is a
  symlink switch; whether that is worth the disk space (it is small) and the web button.
- **Uninstall of a recipe's payload**: stays `hs ct remove`; `hs pkg remove` never deletes data.

## Risks

- The helper API becomes a promise to strangers; getting it wrong later is expensive. Mitigation: step 1 documents and levels it before
  any split, and step 4 happens only after the loader works with a repository on disk.
- Root-run third-party code. Mitigation: signed tags, typed confirmation, diffs, no auto-apply, no shell for the VPS key, nothing
  public by default (the admin-page rule applies to every package: the guard in scripts/services.py stays).
- Test and docs plumbing that assumes everything is in one tree (listed under "Compatibility"); most of the work of step 4 is there, not in
  the loader.
