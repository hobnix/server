# Plan: a generic core, capabilities with variants, services and reconcile

Status: PLAN only (2026-10-15). Nothing here is built. Decided in chat 2026-10-15; the open points are at the end.
The aim: the repo is a generic home-server base. Everything that only applies to one setup (Zoraxy, Tailscale, the VPS,
UniFi, Active Directory, Matrix ...) is an optional capability, and the author's own server is just one preset.

## Why

- `machine.toml` has about 45 options in 270 lines of example, and every option lives in four places that must stay in
  step by hand: `machine.toml.example`, `scripts/lib/config-keys.sh`, the `CHANGES` allowlist in `scripts/web-serve.py`
  and the `or default` in `configuration.nix`.
- Integrations are written into the core. Audit of 2026-10-15 (files outside docs/, tests/ and scripts/recipes/):
  - Tailscale: configuration.nix (firewall, `tailscale serve`, router), deck-serve.py, vps-change.sh, web-serve.py and
    six web pages.
  - Zoraxy: ct-change.sh, manage-ct.sh, dns.sh, ports.sh (reads Zoraxy's JSON rule files), web-serve.py and three pages.
  - UniFi: 20 files; `fixed_address` in recipes/_lib.sh, mac.sh, net-ip.sh, first-run.sh, the vault, the web
    Network page, hs-pool tabs. `10.10.95.x` is written into registry.tsv, hs.sh, unifi.sh and the create-instance forms.
  - Active Directory (`adDomain`): configuration.nix, dns.sh, dc-cert.sh, doctor.sh, first-run.sh, web sign-in.
  - VPS (`vpsHost`): configuration.nix, vps.sh, vps-change.sh, web-serve.py, ProxyHead; copies of ntfy.sh,
    deck-serve.py and hs-watch.sh live in the proxyserver repo.
- A recipe cannot offer "also add this to the reverse proxy / Tailscale / DNS": each integration is a manual step
  (`hs dns sync` is run by hand) or hard-coded in the recipe. Removing a container leaves its route and name behind. (`hs dns sync` was removed 2026-10-29; local names come from the gateway.)
- CLAUDE.md carries the author's container table and public-access rules, which are not generic.

## The model

### 1. Option schema (one source of truth)

One file (`config/schema.toml`) lists every option: key, type, default, group, owning capability (or `core`),
`needs_rebuild`, label and help in en/de, and `secret`. It generates:

- `hs config check` (types, unknown keys, required), the web forms and wizard, the `CHANGES` allowlist for settings,
  the docs table, and the `or default` values handed to Nix (`config/defaults.json`).
- `machine.toml.example` and `hs config sync` go away. `machine.toml` holds **deviations from the schema only**.

### 2. Three places for a setting, by when it takes effect

| Place | Holds | Written by | Rebuild |
| --- | --- | --- | --- |
| `machine.toml` | what Nix evaluates: identity, disks, `bulkType`, `gpu`, VLANs, time zone, SSH keys, enabled capabilities | installer / wizard (`machine-toml.py`), by hand | yes |
| `/var/lib/hs/settings/<key>` (one small file each, not one TOML: `language` is read by every `hs` command) | runtime settings: notify URL, accent colour, language, heartbeat ... | web UI, `hs config set` | no |
| `/var/lib/hs/capabilities/<name>.toml` | the chosen variant and its answers | the capability's install | no |

Secrets stay in the vault, never in a repo file.

### 3. Capabilities with variants

A recipe is a **capability**. Two kinds:

- **Generic capabilities** have a contract and several variants, chosen at install time: `reverse-proxy`
  (zoraxy, caddy, nginx), `docker` (arcane, portainer, none), `dns` (unifi, adguard, dnsmasq, ad), `private-access`
  (tailscale), `monitoring`, `dashboard`, `identity` (local, ad), `network` (dhcp, unifi).
- **Targeted capabilities** (pelican, arr, jellyfin, immich ...) are single-purpose and do not need to be generic.
  They only fulfil the minimal contract: install, declare their services.

A capability lives in `capabilities/<name>/` with a manifest (`capability.toml`: title en/de, `provides`, `requires`,
questions, option schema fragment, registry rows, smoke probes, Nix module if any, `NOTES.md`) and the variant scripts.
`requires` names capabilities, never other variants. A capability that is off costs nothing: no Nix, no registry
rows, no web page.

Provider capabilities (reverse-proxy, dns, private-access, monitoring, dashboard) implement three verbs:
`list`, `ensure <service>`, `remove <service>`. One variant is active per provider capability, one `docker` manager
per Docker host.

### 4. Services and reconcile

A recipe (or the web UI, for Docker apps and other manual entries) declares **services**, files in
`/var/lib/hs/services.d/<name>.toml`: name, container, address, ports and protocol, **exposure**
(`never-public` for admin or login-less pages, `private-ok`, `public-ok`), `public_paths` (what a public rule may
reach, e.g. Arcane's webhook, the Kuma status page), icon, health URL. A container can have several services.

`hs services reconcile` (plan, then start; same shape as the other changes) compares the descriptors with every active
provider and ensures or removes. It runs automatically at the end of a recipe and on a timer for add and update;
removals ask first (typed confirmation, a red flow in the interface).

- The recipe's closing questions are generated from the active providers ("add to the reverse proxy? Tailscale?
  dashboard tile?"); answers go into the descriptor.
- Safety lives in the contract: core refuses a public route for a `never-public` service; a `public-ok` one needs
  a typed confirmation. No provider can bypass it. `hs ports` reads the proxy through `list`, not Zoraxy's files.
- Switching a variant (Zoraxy to Caddy) is a re-reconcile.
- A failing provider does not fail the recipe: the service shows "pending" and a notification goes out.

### 5. Identity provider

`identity` has about five verbs (list users, list groups, resolve a name, set share access, authenticate). Variants:
`local` (default; standalone Samba, local users, `valid users` / `write list`) and `ad` (today's behaviour,
`sharesec`, Domain Admins sign in). Web sign-in and `hs manage-shares` talk only to the contract.

### 6. Presets

The author's server becomes `presets/example-server.toml` (enabled capabilities, settings, container list, network layout).
`presets/minimal.toml` is the generic one. CLAUDE.md keeps the core rules; per-capability notes move to
`capabilities/<name>/NOTES.md`; the container table and the public-access section move to the preset.

## What is on in the minimal preset

- Core, always: NixOS base, SSH, zsh, `hs` and the registry, state DB, storage (ZFS or SnapRAID) with standalone
  Samba shares, Incus and `hs ct add`, DHCP/bridge networking, the web UI, the health check, the vault hook
  (inactive unless encrypted), notify (no channel set).
- On by default in the wizard, can be turned off: backup, disk health and self-tests, ZFS snapshots.
- Off until chosen: Tailscale, VPS/proxyserver, metrics, Grafana, AD, reverse proxy, public access, UniFi helper, UPS,
  Matrix, posters, every app recipe.

## Tests

CI runs a matrix: core only, core plus each single capability, and the full example-server preset. A capability that fails
alone is entangled; that is how entanglement is found mechanically. A schema test checks that the schema, the web
allowlists and the Nix defaults cannot drift (they are generated). A contract test per provider capability runs the
three verbs against a fake. The proxy contract is proven with two real variants (zoraxy and caddy).

## Steps (each ships alone, the live server keeps working, `hs config migrate`-style import for old state)

0. Audit (done above); keep the table current as pilots are extracted.
1. Option schema: generate check, forms, allowlists and Nix defaults from it. Pure refactor.
   Part 1 built 2026-10-15: `config/schema.toml` (seeded from the example, which it regenerates byte for byte),
   `scripts/schema-gen.py write|check|list`, derived: `machine.toml.example`, `scripts/lib/config-keys.sh`, the
   `CONFIG_KEYS` allowlist in web-serve.py; `tests/schema.sh`.
   Part 2 built 2026-10-15: `default` per option (the Nix expression after `or`; 38 options), and `tests/schema.sh`
   checks it against configuration.nix and install.nix. The `or default` values were first CHECKED against Nix, then (2026-10-17)
   GENERATED: `config/defaults.nix` is made by `schema-gen.py`, the Nix files read `machine = defaults // fromTOML ...`; verified in
   WSL: the system derivation is byte-identical to the old one for five machine.toml variants.
   Part 3 built 2026-10-16: value rules in the schema (`choices`, `min`, `pattern` + `hint`), read through
   `schema-gen.py rule KEY`; `config-change.sh` no longer has its own `case` per key. The prose line that looked like an
   option (`# webTailscale = true and ...`, the cause of the old 45-vs-44 test failure) was reworded. `needs_rebuild`
   is NOT added yet: today every change waits for `hs rebuild`, so the flag would be true everywhere; it comes with
   step 2 (runtime settings). Still to do in step 1: generate the Nix defaults (needs `nix-instantiate`), en/de
   labels, and the web forms reading the schema instead of hand-written ones.
2. Move runtime-only settings out of `machine.toml`; `machine.toml` shrinks to deviations.
   Built 2026-10-16: schema `store = "settings"` for 12 options, `scripts/lib/setting.sh` (`setting_get/set/unset`), `config-list.py`
   reads the schema (new `store` column), `hs sys config set` and `hs config set` write the file with no rebuild,
   readers switched (hs.sh, i18n.sh, system.sh, motd.sh, backup.sh, health-check.sh, web-serve.py, hs-pool i18n/icons),
   `hs config migrate-settings` (run by `hs update` before the sync), `hs config check` points moved options to it.
   The Nix `or default` entries and the `/etc/hs` files stay for one release (fallback). Not done: siteName and dhcpRange
   (step 6), generating the Nix side from the schema.
3. Capability manifest mechanism and registry `capability:` tag; pilots: metrics (first), vps, tailscale.
   Built 2026-10-16 for metrics: schema option `capabilities` and `capability = "metrics"` tags, `capabilities/metrics/`
   (manifest, NOTES.md, module.nix with the Prometheus block, firewall rule and tmpfiles entry moved out of
   configuration.nix), `capabilities/default.nix` (loads module.nix of the capabilities that are on), `scripts/lib/capability.sh`,
   /etc/hs/capabilities, tests/capabilities.sh. Checked by evaluating the system with Nix in WSL (`metrics = true`,
   `capabilities = ["metrics"]`, neither). Built 2026-10-16 for vps: no Nix module; `implied_by = ["vpsHost", "proxyStatusUrl"]` in the manifest
   (runtime settings switch it on, no rebuild), generated `scripts/lib/capabilities.tsv`, `capability_on` honours it, registry
   flag `capability:vps` (3 rows, left out of `hs help`), `capabilities` in the web session answer and `capability` on the
   nav node, `hs config set` for any runtime setting by the schema's rules. Built 2026-10-16 for tailscale (host): first
   provider of `private-access`: `capabilities/options.nix` declares `hs.privateInterfaces`, `capabilities/tailscale/module.nix`
   sets it and holds `services.tailscale` and `hs-web-tailscale`; configuration.nix opens the web/deck ports and SSH (sshOverIp off)
   on those interfaces and asserts that `sshOverIp = false` has a provider. Still to do: `deckApi` as `status-api`, the Nix side of vps (the HS_WEB_* environment and the
   assertions on the old machine.toml values) once `migrate-settings` has run everywhere.
4. Services and reconcile; reverse-proxy (zoraxy, then caddy), dns, dashboard.
   4a built 2026-10-18: descriptor format and guard (`scripts/services.py`), `hs services list|check|plan|add|remove|import`,
   capability `reverse-proxy` (runtime settings `reverseProxy`, `proxyDomains`; variant scripts in `scripts/providers/reverse-proxy/`),
   the zoraxy variant READ-ONLY, tests/services.sh with a fake incus. Next: 4b zoraxy writes (needs the API of the installed
   version), 4c caddy, 4d dns and dashboard providers, 4e docker (arcane, portainer) and recipes declaring services.
   4b-1 built 2026-10-18: `hs services proxy login` (vault secret zoraxy-admin), zoraxy api mode (session cookie; list, add, vdir/add),
   the API-vs-files self-check, `hs services apply` (adds only, typed host name for public-ok), tests/zoraxy-fake.py +
   tests/services-zoraxy-api.sh.
   4b-2 built 2026-10-19: `change` (upstream add+remove for a root, vdir/edit for a path), `remove` (paths before their root, typed host
   name), `hs services adopt`, ownership lists, `--confirm` takes a host or a service name; only routes hs made or adopted are ever changed
   or removed.
   4e-1 and 4d-1 built 2026-10-19: `declare_service` in recipes/_lib.sh (jellyfin, immich, seerr, uptime-kuma, monitoring; one question per provider
   that is set up, private-ok by default, a recipe never makes a service public), `hs services declare|tiles`, the capability `dashboard`
   (setting `dashboard`, provider `homepage`, removed 2026-10-29: the dashboard is built into the web interface: tiles from `want.dashboard`, `homepage.sh --refresh`, `hs services apply` refreshes it).
   The other recipes call `declare_service` too (2026-10-19: 18 recipes, tests/recipes-declare.sh).
   4e `docker` built 2026-10-19: `MANAGER` arcane | portainer | none per container, variant files in scripts/providers/docker/, switching keeps the data (tests/docker-managers.sh).
   Step 5a built 2026-10-19: `hs recipe <name> --name <ct>` (a container of your own name, a service of its own) and the recipe headers `# kind: generic|personal`, `# needs: docker share tailscale`, `# uses: gpu` (shown by `hs recipe --list`, kept true by tests/recipes-meta.sh).
   5b built (qbittorrent and sabnzbd only): `wait_page <title> <hint>` in _lib.sh (tests/wait-page.sh); sharing a share needs no new helper, `media_storage` in _media.sh already does it. 5c built: `ct_tailscale` in _lib.sh for livekit and stalwart (tests/ct-tailscale.sh); the personal recipes (livekit, domain, cloudflared, zoraxy, pelican, stalwart) are marked `# kind: personal`, and stalwart's Tailscale was already a question. wait_page took over the recipes with a plain web page on 2026-10-20 (options --path --ok --status --match --tries --every --plain; arr, livekit, monitoring, matrix-hook, pelican, sunshine, homeassistant, cloudflared, domain keep their own checks). Left: and the Zoraxy wording in the closing texts of pelican/cloudflared/livekit (generic proxy wording). Step 6a built: the capability `network` (runtime setting `networkProvider`, set by `hs net setup`, migrated for servers with /var/lib/hs/unifi; contract scripts/providers/network/<variant>.sh; `fixed_address` talks only to it; without a provider the recipe says the address is not fixed, as before; `hs net check|ip` are left out of `hs help` while off; tests/network-provider.sh). 6b built: the capability `ad` (on exactly when `adDomain` is set, computed in configuration.nix; `hs user|dns|dc cert` are left out of `hs help` and the web Identity pages are hidden while off; Samba stays standalone; matrix case `ad-domain`). Local users are a later step (an `identity` provider with a `local` variant). Step 7a built: the web Setup page (/setup; a checklist from `hs sys setup list`, scripts/setup-list.sh; each open item links to the page that does it, "Mark setup as finished" sets the runtime setting `setupDone`; a reminder card on the summary until then; tests/setup-list.sh). The settings page from the schema already existed. hs-ui stays frozen (no new features, still starts on a bare `hs`); deleting it waits for. Step 8 built: `presets/minimal.toml` and `presets/example-server.toml` with `hs preset list|show|apply` (gap-filling only, tests/preset.sh); CLAUDE.md split (the author's server -> the author's private notes, the capability paragraphs -> capabilities/<name>/NOTES.md; 38 KB to 30 KB). The full example-server preset is a nix-matrix variant (preset-example, built 2026-10-20). Still to do in step 8: a web card on the Setup page to choose a preset. Next: step 9 (install guide) (personal recipes go through capability checks); parked on request: 4c caddy (a LAN-only second proxy is not needed yet), 4d-2 dns.
   Planned: `hs services import` from
   `recipe-<ct>.conf` and the existing Zoraxy rules; `docker` with arcane and portainer.
5. Recipe base layer shrinks to "ensure the container, declare the services"; targeted recipes get manifests.
6. `identity` provider (`local`, `ad`) and the `network` provider (`dhcp`, `unifi`).
7. Web wizard for first run and settings pages from the schema; freeze hs-ui, delete it when the web UI has parity
   for Disks and pools. The `hs` CLI stays as the headless and recovery path.
8. Presets; split CLAUDE.md. CI matrix built 2026-10-17: `scripts/dev/nix-matrix.sh` (core, each capability alone, all, the legacy
   switches, the sshOverIp assertion), run by the nixos job in ci.yml; add a capability and it is picked up from `capabilities/*/`.
   Still to do in step 8: the full example-server preset as one more variant.
9. Install guide for the minimal preset and the first-run wizard (rewrite of `Homeserver-Anleitung NixOS + Incus + ZFS`):
   it depends on steps 7 and 8.
10a built 2026-10-20: `installer/iso.nix` (evaluates in WSL and in CI), `scripts/install-wizard.sh` = `hs-install` (the OS disk only), `scripts/dev/build-iso.sh`, a CI job that builds the ISO on a `v*` tag; NOT yet booted in a VM or on hardware. Still to do: 10b (web wizard with a one-time token), trying 10a in a throwaway VM.
10. Last, by decision of 2026-10-17: a boot ISO with an install wizard (the first-boot web wizard needs a one-time token
   printed on the console and closes itself afterwards).

## Risks

- A rebuild started from the web can fail half way: run it as a job with the existing `hs update` rollback.
- Provider differences (Zoraxy virtual directories and API, Caddy/nginx generated snippets): the descriptor stays at
  host, upstream and allowed paths; quirks (Wings header workaround) stay in the variant or the targeted recipe.
- The proxyserver repo shares copies of three files with this one: they move into the VPS capability as one unit,
  with a sync check, before the VPS pilot is called done.
- The storage lock gates incus, samba and the timers by hand today: capabilities declare `needs: storage` and are
  gated by the manifest instead.

## Open points

- Where the cousin's server fits: the first non-author preset, to test the generic path early?
- Does the `docker` host stay one container, or can there be several, each with its own manager?
- Format of the answers file for unattended installs (wizard output = `machine.toml` plus `settings.toml`?).
