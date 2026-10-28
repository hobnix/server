# Extension packages

Status: step 1 built (2026-10-27): the loader, `hs ext`, the manifest web declarations, Games and Posters as the pilot. Not built: the
repository location with pinned commits, the page layouts of  ("Extensions"), recipes as packages.

An **extension** is an optional part of the server that is not in the core: Game PCs, Posters, later more. It is a **package**: one folder
that carries everything the extension adds (commands, scripts, help texts, translations, tests, a web declaration). Switching it on adds
those commands to `hs`; switching it off makes them disappear. Decided by the owner on 2026-10-27.

## Rules of the commands

- `hs ext <name> <command>` is the **only** user route into an extension. `hs sys ext <name> <command>` is the machine-readable contract under
  it (what the web interface reads and changes through; plain output, same rules as every `hs sys` row, see CLAUDE.md).
- The **folder name is the namespace**. A package can only add rows under its own name, so two packages cannot collide and a package cannot
  shadow a core command (`hs disk`, `hs pool`, `hs backup`, ... stay the core's). The test for what is core: "could someone else write this?".
  Core commands keep their natural names; only optional parts go under `ext`.
- `hs ext list` shows the packages and whether each is on, `hs ext enable <name>` / `hs ext disable <name>` switch one, and `hs ext <name>`
  without a command lists that package's commands (also while it is off, marked as such).
- The names `list`, `enable` and `disable` are reserved (they are core commands under `hs ext`).
- When a command moves into a package, its old words stay for **one release** as a `legacy:<new words>` row in the core registry: they print
  "has moved to the extension ...: hs ext ..." on stderr and still run when the extension is on; when it is off they only name
  `hs ext enable <name>` and exit 1. Legacy rows carry the flag `nohelp`. (Pilot: `hs pc ...` and `hs generate poster`. The old `hs sys pc ...`,
  `hs sys poster ...`, `hs sys generate poster` are gone without a legacy row: only the web interface read them, and it was changed with them.)

## The package folder

Today a package is a folder `capabilities/<name>/` of this repository (an extension is a capability with a few more files; nothing else about
capabilities changes). The lookup is **one function** (`ext_package_dir` in scripts/lib/registry-load.sh, `ext_roots` in scripts/web-serve.py),
so a second location, `/var/lib/hs/packages/<name>@<commit>`, can be added later without touching a reader.

| File | What |
| --- | --- |
| `capability.toml` | the manifest of a capability (docs/PLAN-modular-core.md) plus `extension = true` and the optional `[[web.reads]]` / `[[web.changes]]` tables below |
| `commands.tsv` | the command rows, same columns as scripts/lib/registry.tsv (kind, path, script, args, help, help.de, flags) |
| `NOTES.md` | what the package is and the rules that stay with it |
| `module.nix` | optional. A package with a NixOS module needs `hs rebuild` to be switched on or off; one without does not |
| scripts | a script named in `commands.tsv` is a path under `scripts/` (the pilot packages keep theirs there) or `@/file`, a file inside the package folder |
| `i18n/<lang>.tsv` | optional. Translations (English text, TAB, translation), read by scripts/lib/i18n.sh while the package is on |
| tests | `tests/<name>.sh` as for every feature; tests/ext.sh tests the format itself |

The scripts of the pilot packages moved into their folders on 2026-10-28 (`@/pc.sh`, `@/generate-poster.sh`, ...; posters also carry poster.py and a copy of the Inter
fonts). A package script finds the core helpers through `HS_SCRIPTS` (set by the `hs` dispatcher; fallback `<package>/../../scripts`), and the legacy rows
of the core registry only name a placeholder script: the dispatcher runs the script of the new row. Their translations still live in scripts/lib/i18n/de.tsv
(a package `i18n/<lang>.tsv` is read when it exists).

### commands.tsv

Rows are exactly the registry format. Valid rows of a package called `<name>`:

- user rows: path `ext <name> <command words...>` (at least one command word; `hs ext <name>` alone is the listing, not a row)
- sys rows: path `sys ext <name> <command words...>`
- at least the first six columns; user rows need help and help.de (or the script header's `# help:` / `# help.de:`), a `topic:` flag and
  `reads` or `changes` (tests/commands.sh checks this for every package)
- `script` without `..` and not absolute, or `@/file`; the same words not twice; no `legacy:` flag

Anything else is **refused**: the row is left out when the commands are loaded and listed by `registry_refused` (tests/commands.sh fails on
any refused row of the repository's packages). A refused row never reaches `hs`, `hs help`, completion, docs or the web interface.

### The web declaration

The web interface renders pages from its own code. A package does not ship JavaScript (hs-web runs as root, the allowlists are the security
boundary). It declares only which `hs sys ext <name> ...` calls the existing pages may use, in `capability.toml`:

```toml
[[web.reads]]            # GET /api/sys/ext/<name>/<words>
words = "list"           # the sys row `sys ext <name> list`
kind = "tsv"             # tsv | json | text
ttl = 30                 # seconds the answer is reused
args = ['^[a-z]{1,8}$']  # optional: one pattern per value the row takes (a <x> in its path)

[[web.changes]]          # POST /api/plan and /api/start with area "ext/<name>"
patterns = ['^go$', '^[a-z]{1,8}$']          # an exact shape: one pattern per argument
[[web.changes]]
fixed = ['^make$']                           # or: fixed words, then options in any order
opts = [ { flag = "--size", pattern = '^[0-9]{1,3}$' } ]   # no pattern = a switch; repeats = true allows it twice
```

scripts/web-serve.py (`ext_load_web`, refreshed at most every 3 s, so `hs ext enable` needs no restart) registers these entries only while the
package is on, with these checks. If any check fails the whole declaration of that package is ignored and the reason is logged:

- every read must be a sys row of the package's own `commands.tsv` (with `<x>` for each value); a read cannot be named `plan`, `start`, `stop`,
  `delete` or `purge`;
- changes need the rows `sys ext <name> plan ...` and `sys ext <name> start ...` (the plan-then-start pattern of the web changes);
- patterns are compiled and limited in length; kinds and ttl are range-checked; flags look like `--word`;
- reads always land under `ext/<name>/...` and changes under the area `ext/<name>`: a manifest cannot name a core read or another package.

Core pages stay in `web/src/`; the Games and Posters pages read `/api/sys/ext/games/...` and `/api/sys/ext/posters/...`. The answers are the
same bytes as before the move (the rows run the same scripts).

### The page declaration (`[web.page]`)

A package gets a page without shipping code: `[web.page]` is DATA that the one generic renderer (web/src/shell/GenericPage.svelte, the format is
the comment at the top of that file) draws at `/extensions/<name>`. The tree shows an Extensions group only while a package with a page is on.

```toml
[web.page]
title = "Game streaming"                     # also the tree label; icon = a Phosphor name; crumb, sub optional
[[web.page.actions]]                         # page buttons: plan = ["ext/<name>", args...] opens the plan dialog; form = "PcForm" opens a dialog of the
label = "Add PC"                             # closed list in pages/Extension.svelte (a package cannot bring code)
form = "PcForm"
[[web.page.blocks]]                          # table | kv | cards | text | empty | gallery
type = "table"
read = "list"                                # the WORDS of a [[web.reads]] entry above
key = "name"
columns = [ { key = "name", label = "Name" }, { key = "state", label = "State", kind = "dot", map = { up = ["ok", "answers"] } } ]
rowActions = [ { label = "Wake", plan = ["ext/games", "{name}", "wake"] } ]   # {column} = the row's value
```

web-serve.py (`_ext_page`) hands the declaration to the session answer (`features.extensions`) only while the package is on, and drops the whole
package declaration when a block reads something the package did not declare as a read, when a plan names another area, or the block type is
unknown. The page can therefore ask for nothing the manifest's reads and changes did not already allow; tests/web-ext-test.py checks that every
plan of the shipped pages is accepted by the changes.

## Switching on and off

`hs ext enable <name>` writes the name into machine.toml `capabilities` (through scripts/lib/machine.sh, comments stay). For a package
**without** `module.nix` it also writes the name to `/var/lib/hs/capabilities-on`, which scripts/lib/capability.sh and the web interface read
beside `/etc/hs/capabilities`, so the package is on at once, without a rebuild. For a package **with** a Nix module it only edits machine.toml
and says that `hs rebuild` is needed. `hs ext disable` is the reverse: `capabilities-off` wins over every other source until the next rebuild.
After a rebuild `/etc/hs/capabilities` and machine.toml agree and the overlay says nothing new. A package that is on for another reason (an
old switch, an implied setting) stays on after `disable`; the list shows it.

`hs help`, `hs help --all`, completion, `hs sys registry`, docs-build (the command pages), the cheat sheet, smoke and the web allowlists all read
the merged list (`registry_rows` in scripts/lib/registry-load.sh; the knob `HS_REGISTRY` names the core file, `HS_PACKAGES_DIR` the folder of
the packages, both for tests). A package that is off adds nothing anywhere. On the server the scripts run from a copy in the Nix store without
`capabilities/`, so the loader reads the packages from the checkout in /etc/nixos.

## Security

- Every command of a package runs **as root** like the core's (`hs` escalates). Installing a package is trusting its author. Today the only
  packages are the ones in this repository, reviewed with the rest.
- The namespace rule is enforced where the rows are loaded, not by convention: a package cannot add, replace or shadow a command of the core
  or of another package, cannot point a row at a script outside `scripts/` and its own folder, and cannot carry `legacy:` rows.
- A package that reads its own scripts with `@/file` runs files from the checkout in /etc/nixos, which is owned by adminuser, not from the
  immutable Nix store. adminuser can already sudo, but this is why the pilot packages keep their scripts in `scripts/` and why a pinned location
  (below) matters.
- The web interface gets only what the manifest declares, and only through the allowlist checks above. A package cannot add a page, a route,
  a header or a script to the browser; it cannot reach a core read or change. Admin pages stay without a public route (CLAUDE.md).
- Switching a package on is a change of the server's configuration: it needs a person at `hs ext enable` (root) or a machine.toml edit.
  Nothing downloads or enables a package by itself.

## Packages from a repository (later)

Superseded by docs/PLAN-packages.md (2026-10-28): recipes and extensions become one package format, with versions, repositories and signed tags. What follows is the earlier sketch.

Recipes and extensions in a repository of their own, loaded at a **pinned commit** set in machine.toml (for example
`packages = [{ name = "mail-tools", repo = "...", commit = "..." }]`), checked out to `/var/lib/hs/packages/<name>@<commit>`:

- only the commit in machine.toml is ever checked out, never a branch; a new commit is a change of machine.toml;
- `hs update` shows the **diff** between the installed commit and the new one (commands.tsv, scripts, the web declaration) and asks, because
  packages run as root;
- the package folder is copied to the store-like location and made root-owned and read-only, so `@/file` scripts no longer come from a folder
  a user can write to;
- the same loader reads it: only `ext_package_dir` / `ext_roots` learn the new location. The rules above do not change.

## Order of work

1. Loader, `hs ext`, namespace rule, web declaration, Games and Posters as the pilot (done, tests/ext.sh, tests/web-ext-test.py).
2. The `[web]` page layouts and the template renderer of  after the web redesign; Games or Posters first.
3. Move the pilot scripts and translations into the package folders.
4. The repository location with pinned commits.
