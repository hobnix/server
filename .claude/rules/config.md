---
paths:
  - "machine.toml*"
  - "config/**"
  - "configuration.nix"
  - "install.nix"
  - "installer/**"
  - "presets/**"
  - "capabilities/**/capability.toml"
  - "capabilities/**/module.nix"
  - "capabilities/options.nix"
  - "capabilities/default.nix"
  - "scripts/lib/machine.sh"
  - "scripts/lib/setting.sh"
  - "scripts/lib/capability.sh"
  - "scripts/machine-*"
  - "scripts/schema-gen.py"
  - "scripts/preset*"
  - "scripts/install-wizard.sh"
  - "scripts/rebuild.sh"
  - "scripts/update.sh"
  - "tests/schema.sh"
  - "tests/machine-toml.sh"
  - "tests/preset.sh"
  - "tests/capabilities.sh"
  - "tests/install-wizard.sh"
---

# machine.toml, schema, capabilities, roles, presets, installer

Loaded when you touch the files above (path-scoped rule). The root CLAUDE.md has the rules that always apply.

- machine.toml (TOML, replaced machine.nix on 2026-10-10, not yet run on the server) also holds `hostName` (Linux + Windows network name, resolved via mDNS)
  and `adDomain` (Samba joins that AD as a member; share logins are domain users; an inline table `{ realm = "...", workgroup = "..." }`).
  configuration.nix and install.nix read it with `builtins.fromTOML (builtins.readFile ./machine.toml)` and fall back to `import ./machine.nix` while
  only the old file exists (remove with scripts/machine-merge.sh one release later). Keys stay flat (the two sets `vlans` and `adDomain` are inline
  tables on ONE line: a `[table]` header would swallow every later key); every default is written ONCE, in `config/schema.toml` (`default`); `config/defaults.nix` is generated from it and the Nix files read `machine = defaults // <machine.toml>`, so a new option needs no `or` (only a default that refers to another setting, like siteName, stays an `or`). TOML has no
  null: "off" = the option is commented out. NEVER grep/sed the file in a script: `scripts/lib/machine.sh` (`machine_get`, `machine_get_json`,
  `machine_has`, `machine_set`, `machine_unset`; knob HS_MACHINE_FILE, default /etc/nixos/machine.toml) calls `scripts/machine-toml.py` (stdlib
  tomllib; get/set/unset edit ONE line and keep the comments, a result that does not parse is not written). `machine.toml.example` is the layout:
  sections (Server, Interface, Network, Storage, Backup, Accounts, Messages, History and status, Hardware), one option per paragraph; a paragraph's
  option is its LAST `name = ...` / `# name = ...` line (exactly one space after the #; prose lines, also in the indented examples, must not look
  like that) and runs to the end of the paragraph; `# name = value` is an optional option that is off. `hs config sync` (scripts/machine-sync.sh,
  tests/machine-toml.sh) rewrites machine.toml in the example's layout with the user's values, so `diff machine.toml machine.toml.example` shows only
  the values: new options appear in their place, commented out; keys the example does not know go into a closing section; the user's own comments in
  the paragraphs are replaced by the example's; copy in /var/lib/hs/machine.toml.before-sync; `--check`/`--list` only report. `hs config check`
  (typos, types from the example's values, missing required = the active options of the example, `CHANGEME`) runs at the start of rebuild.sh.
  `hs config migrate` converts an old machine.nix (`nix-instantiate --eval --strict --json`) and keeps it as machine.nix.migrated; `hs update` does
  it once and then `sync`s. After the sync `hs update` asks (choose: rebuild now / stop here) when options are new and a person is at a terminal
  (`--yes` never asks, `--stop-on-new` always stops, no terminal or HS_CALLER rebuilds; stopping sends an info push and exits 0, `hs rebuild` follows).
  `scripts/machine-merge.sh` is only a shim for the OLD update.sh that runs once from the new checkout. New options need a paragraph like that in the example.
  **The example is generated** from `config/schema.toml` (docs/PLAN-modular-core.md step 1): add or change an option THERE, then run `python3 scripts/schema-gen.py write`
  (it also rewrites `scripts/lib/config-keys.sh`, `config/defaults.nix`, `scripts/lib/capabilities.tsv` and the `CONFIG_KEYS` allowlist in web-serve.py; `tests/schema.sh` fails when any of them is stale or when the Nix files read a key the schema lacks). Never edit those generated files by hand.
  **Capabilities** (step 3, docs/PLAN-modular-core.md): pilots `metrics` (Nix module), `tailscale` (host; first provider: sets `hs.privateInterfaces`, which the web/deck/SSH firewall rules in configuration.nix use instead of naming `tailscale0`; `sshOverIp = false` needs a provider) and `vps` (no Nix: scripts + web; implied by runtime settings via `implied_by` in the manifest -> generated scripts/lib/capabilities.tsv, `python3 scripts/schema-gen.py write`). Registry rows carry flag `capability:<name>` (left out of `hs help` while off, `hs help --all` shows them); nav.js nodes carry `capability` (the web tree hides them, `ui.features.capabilities` from the session answer). optional parts live in `capabilities/<name>/` (`capability.toml` manifest, `module.nix` loaded by capabilities/default.nix only while the part is on, `NOTES.md`). On = named in machine.toml `capabilities` or implied by its old switch (computed in configuration.nix); Nix writes the list to /etc/hs/capabilities, scripts ask `capability_on <name>` (scripts/lib/capability.sh). Options carry `capability = "<name>"` in the schema, tests/capabilities.sh checks manifests and tags. Evaluate Nix changes with `bash scripts/dev/nix-matrix.sh` (each capability alone, all, none, the SSH assertion; CI runs it in the nixos job; in WSL Debian nix is installed: `wsl -d Debian -- bash -lc "cd <repo> && bash scripts/dev/nix-matrix.sh"`). A refactor of the Nix side is proven by comparing `nix-instantiate <nixpkgs/nixos> -A system` store paths before/after with the same scripts/ folder (any change under scripts/ changes the derivation).
  **Extension packages** (docs/PLAN-extensions.md; pilot `games` and `posters`): an optional part is a package folder `capabilities/<name>/` with `extension = true` in capability.toml and its own `commands.tsv` (registry format). `hs ext <name> <command>` is the ONLY user route and `hs sys ext <name> <command>` the machine-readable contract under it; the folder name is the namespace (rows outside `ext <name> ...` / `sys ext <name> ...` are refused by the loader, so no collision and no shadowing of core commands; `list`, `enable`, `disable` are reserved). EVERY reader of the command list goes through `registry_rows` in scripts/lib/registry-load.sh (core registry.tsv + the commands.tsv of the packages that are ON), never `grep registry.tsv`: the hs dispatcher, `hs help`, completion, docs-build, cheatsheet, smoke, tests. A package that is off is invisible. `hs ext list|enable|disable|<name>` (scripts/ext.sh): enable/disable edit machine.toml `capabilities` and, for a package without `module.nix`, the overlay /var/lib/hs/capabilities-on|off that capability.sh and web-serve.py read, so no rebuild. The web reads/changes of a package are declared in its capability.toml (`[[web.reads]]`, `[[web.changes]]`, area `ext/<name>`) and registered by web-serve.py only while it is on. A moved command keeps its old words one release as a core `legacy:<new words>` row. The pilot scripts still live in scripts/ (a script is `scripts/x.sh` or `@/file` in the package). tests/ext.sh, tests/web-ext-test.py.
  **Capabilities with rules of their own** (read the NOTES.md before changing one): `reverse-proxy` (services, descriptor format, the public-route guard, recipes declare their service), `dashboard`, `docker` (manager variants), `network` (router connection), `ad` (Active Directory), `metrics`, `tailscale`, `vps`, `docs` (the guides in the web interface): capabilities/<name>/NOTES.md. Hard rules that stay here: an admin page is never public (the guard in scripts/services.py, `ADMIN_TARGETS`); `hs` only changes or removes proxy routes it made or adopted; a recipe with a web page ends with `declare_service`; Caddy (4c) and DNS (4d-2) are parked; details capabilities/reverse-proxy/NOTES.md, capabilities/dashboard/NOTES.md. **First-run checklist** (7a): `hs sys setup list` (scripts/setup-list.sh: id, done|open, label, command, web page) feeds the web Setup page (/setup) and a reminder on the summary until the runtime setting `setupDone` is true.
  **Runtime settings** (step 2): options with `store = "settings"` in the schema (language, loginMessage, icons, backupNewShares, notifyUrl, heartbeatUrl, webAccent, proxyStatusUrl, vpsHost, webTerminal*) are NOT in machine.toml/the example any more: one file each in /var/lib/hs/settings (the push addresses keep /var/lib/hs/notify-url and heartbeat-url), written by `hs config set` / `hs sys config start set` with no rebuild, read with `setting_get` (scripts/lib/setting.sh; hs-web via `runtime_setting`, the Rust side via `i18n::runtime_setting`), falling back to the /etc/hs file Nix still writes from an old machine.toml line. `hs config migrate-settings` (run by `hs update` before the sync) moves old lines over. A new script that needs such a value calls `setting_get`, never `cat /etc/hs/...`.

- **Roles and the edge node** (guide docs/operations.md, "Run a public edge node"). The `proxyserver` repo is deprecated (2026-10-27): its job is the role `edge` of THIS repo. `role` in machine.toml
  (`homeserver` default | `edge` | `minimal`); `homeserver` implies the capabilities `storage`, `incus`, `samba`, `backup` (their code is capabilities/<name>/module.nix, moved out of configuration.nix;
  keep lists that several parts add to in configuration.nix, gated with `hasStorage`/`hasIncus`/`hasSamba`, because a moved list item can change the store path; prove a refactor of the Nix side by comparing
  `nix-instantiate` store paths before and after). Edge capabilities `edge-mail`, `edge-ports`, `edge-watcher`, `edge-status` (options `edge*`, preset `edge`, `hs-install --role edge`); the facts and the
  status document come from scripts/lib/edge_facts.py (standard library only; test tests/edge-facts.sh), the health check is scripts/edge-health.sh, the watcher is vps/hs-watch.sh (the ONE copy; scripts/lib/ntfy.sh and
  scripts/deck-serve.py are shared too: no "change both" any more for an edge node). Hard rules: never forward 22, 25, 80, 2222 or 41641 (assertion in edge-ports); an edge node's `sshOverIp` is closed only after Tailscale SSH works;
  the status key line is `nodeKeys` (forced command `scripts/node-remote.sh`, `status` only, ssh user root, port 2222, node kind `edge`); the DNS/MX cutover is a checklist and is never done by a command.

- Presets: `presets/<name>.toml` (`[machine]` keys for machine.toml, `[settings]` for the runtime settings, `recipes` to read); `hs preset list|show|apply` (scripts/preset.sh over preset.py) fills only what is NOT set yet, shows a plan and asks first, never overwrites; the public tree has `minimal`, `edge` and `example-server` (a fully equipped server with made-up values); the author's own preset lives in a private repository; tests/preset.sh.

- Installer ISO (step 10a): `installer/iso.nix` (minimal NixOS installer + a copy of the repo in /etc/hs-installer + the command `hs-install` = scripts/install-wizard.sh); build with `scripts/dev/build-iso.sh` (`--eval` only evaluates; CI evaluates on every push and builds on a `v*` tag, attaching the ISO to the release). The wizard erases ONE disk (typed name, or `--confirm-disk`), refuses to run unless /iso is mounted (never on an installed server), writes machine.toml with machine-toml.py, applies a preset and runs nixos-install with install.nix; tests/install-wizard.sh uses HS_INSTALL_SKIP_DISK=1. Not run on real hardware or in a VM yet.

- Time zone: `timeZone = "Europe/Vienna"` in machine.toml (`hs config set timeZone ...`, default none = UTC, which put the Matrix cards 2 h off) sets `time.timeZone`; recipes read the zone from `timedatectl` when they run, so matrix-hook and arr must be run again after a change.

- Login shell is zsh for all users (autosuggestions, syntax highlighting, fzf), prompt is
  starship with plain-text symbols (no Nerd Font needed) in Catppuccin Mocha. Scripts stay
  bash. `environment.enableAllTerminfo` covers Ghostty/Kitty/WezTerm over SSH.

- `gpu` in machine.toml (`"nvidia"`, `"amd"`, `"intel"` or a list; no line = no graphics driver)
  decides what configuration.nix installs: nvidia = videoDrivers + hardware.nvidia (open
  modules) + container toolkit; amd/intel = only the kernel driver (containers bring their own
  Mesa/VAAPI). A server without a card (test server, VM) leaves it out, otherwise the CDI
  generator fails at every switch ("Driver Not Loaded") and `hs update` ends red. hs rebuild
  warns when an NVIDIA card is built in (/sys/class/drm vendor 0x10de) and machine.toml has
  no gpu line, because the default changed from "always nvidia" to "none".

- `incusUi` in machine.toml (default true) -> /etc/hs/incus-ui (on|off). Off: no Incus web UI, port 8443
  closed, no `core.https_address` in the preseed (an address set earlier stays until you unset it by hand:
  `incus config unset core.https_address`), no Incus tile in the Homepage.

- New servers are installed with install.nix (minimal, no pools needed), then switched to
  configuration.nix once the pools exist. No config editing in between.
