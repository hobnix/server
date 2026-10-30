# Contributing

Hobnix is a NixOS home server: Incus containers on ZFS or SnapRAID, Samba shares, backups, a web interface and one command, `hs`. This
repository is the **core**. The apps (recipes) and the optional parts (extensions) are packages in their own repositories:

- https://github.com/hobnix/recipes (an app that runs in its own container or VM)
- https://github.com/hobnix/extensions (commands and a page on the host)

Each of them has its own `CONTRIBUTING.md` (how to write a package). A change to the helpers a package relies on (`scripts/recipes/_lib.sh`,
the loaders, `scripts/lib/api-level`) belongs here, and its pull request says which packages it touches.

## Before you start

- Open an issue first for anything that changes storage, the network, the firewall or how a command works. Small fixes and docs need none.
- A change that was not run on a real server says so in the pull request. Documentation steps that were not run say "Not tested on hardware yet."

## Working on the core

- Branches are named `feature/<topic>`; open a pull request against `main`. CI runs on pull requests.
- Run the tests of the files you changed through the quiet runner, not raw: `scripts/dev/t quick [name...]` (`scripts/dev/t list` names
  them). Many tests need Linux (use WSL on Windows). Also `bash -n` on a script and `python3 scripts/pkg.py validate` for manifests.
- Rules that every change follows (the full list is in `CLAUDE.md`):
  - **Admin pages are never public.** Incus, Zoraxy, Arcane, Grafana, Tdarr and the like get no public route (`ADMIN_TARGETS` in `scripts/services.py`).
  - **Destructive commands** make the user type the name of the thing that changes, show a plan first and offer a background job for long work.
  - **Terminal output** goes through `scripts/lib/ui.sh` only: no raw `echo` or `printf`, no colours of its own. Lines the web interface reads
    (`hs sys ...`, `--list`, `--dry-run`, `--state`) keep their shape; an empty tab-separated field is written `-`.
  - **Generated files** (`config/defaults.nix`, `scripts/lib/config-keys.sh`, `scripts/lib/capabilities.tsv`, `machine.toml.example`) are never
    edited by hand: edit `config/schema.toml`, then run `python3 scripts/schema-gen.py write`.
  - **A new script** gets a row in `scripts/lib/registry.tsv`; a new `reads` command gets a probe in `scripts/smoke.sh`.
  - **Secrets** are read only through `scripts/lib/secret.sh` and never go through argv or the environment.
  - **Documentation** is English and follows `docs/GUIDE-TEMPLATE.md`.
- **Changelog entries.** A change that users see (a new option, a fixed bug, a changed behaviour) adds one file
  `docs/changelog/<YYYY-MM-DD>-<slug>.toml` with `date`, `type` (feature, fix, change, security), `title` (one line, plain English) and
  optionally `docs` (a guide and anchor) and `body`. One file per change. Check it with `python3 -I scripts/lib/changelog.py validate .`;
  the format is in `docs/changelog/README.md`. CI only warns when a pull request touches the core without an entry.
- Commit messages say what changed and why in a line or two. Stage files by name.

## Reporting a problem

Bugs and ideas: an issue with the template. A vulnerability: not an issue, see `SECURITY.md`.
