# Plan: Docker as a capability, with locked instances and child instances (draft, 2026-11-02)

Status: design only, nothing built, nothing run on hardware. Open questions at the end are for the owner.

## Problem

1. Docker is a recipe today (`hs recipe docker`, capabilities/docker/NOTES.md): an ordinary container the user can delete, rename or
   rebuild, with the manager (arcane, portainer, none) chosen as a recipe preference per container (`MANAGER` in `recipe-<ct>.conf`).
   Nothing in the core knows that this container is infrastructure, and nothing knows that the apps inside it exist.
2. Apps that run inside Docker are invisible to `hs`: not in the instance list, not in backups by name, not in services or routes.
3. The setup wizard of the gateway (web/src/settings/Steps.svelte) shows every step stacked on one page with raw key names. It is correct
   but reads like a settings form, not like a question.

## Decision in one paragraph

The capability `docker` owns ONE locked Incus container (name `docker`) and creates and removes it. Instances get two new facts: `managed_by`
(a capability name; the instance cannot be deleted, renamed or reconfigured except by that capability) and `parent` (the instance an
instance runs inside). Apps that run in Docker are child instances of kind `docker` with `parent = docker`. The manager (web interface,
Arcane, Portainer, none) becomes a setting of the capability, chosen in a step-by-step wizard in the web interface. The same wizard
component replaces the stacked step list used by the gateway. Recipes declare where they can run (`runs = ["lxc", "docker", "vm"]`), so the arr apps no longer need a container of their own
with Docker inside. The gateway itself stays on the host (see the last section).

## Design

### 1. Locked instances (core, no Docker needed)

- Instance property `managed_by = "<capability>"`. Stored where the other per-instance facts live (verify in phase 0: Incus `user.hs.managed_by`
  config key on the instance is the preferred place, so it survives a rebuild and shows in `incus config show`).
- Refused for a locked instance unless the caller is the owning capability: delete, rename, `hs ct <ct> set` of disk shrink or kind, device
  removal, and restore of a snapshot that would change the kind. Allowed: start, stop, restart, snapshot, backup, console, exec by an admin.
- ONE check in one function (scripts/manage-ct.sh, called by the web backend's change allowlist too). The web and `hs` must not each
  implement it; a test asserts both routes are refused.
- The refusal message names the owner and the way out: "Docker owns this instance. Turn Docker off under Settings, Capabilities, Docker."
- The instance list shows a lock chip (web/src/ui Chip) and the delete action is absent, not disabled.

### 2. Child instances

- Instance kind `docker` (next to `empty`, `vm`; today `hs ct add --kind empty|docker|vm`, where `docker` means a container that has Docker
  inside; rename that old meaning to `docker-host` in help text and keep the flag working for one release as `legacy:`).
- A child has `parent = <instance>`. It is a record, not an Incus instance: name, parent, compose project name, published ports, state read
  from the Docker API inside the parent.
- Reads: `hs sys ct list` (machine-readable shape unchanged; new rows are appended with the kind `docker` and the parent in a NEW trailing
  field, empty written `-`). Check phase 0 that no reader breaks on the extra field.
- State of a child comes from the manager-independent source: `docker compose ls` / `docker ps` run in the parent through `incus exec`
  (read-only, short timeout). With `live-state` (docs/PLAN-web-cache.md) this is one more topic; without it, the normal cache.
- Services and routes: a child declares its service like a recipe does (`declare_service`) but the target is `<parent address>:<published port>`.
  The descriptor gets a `via = "<parent>"` field. The admin-page rule is unchanged: the manager's own page is `never-public` (ADMIN_TARGETS).
- Backups: the unit is the parent (snapshot of the whole `docker` container plus its data volume). A child is never backed up on its own in
  the first version. The list shows "backed up with docker".
- Restore of one child is out of scope for the first version; restoring the parent is the supported path.

### 3. The capability

- `capabilities/docker/capability.toml` keeps `kind = "provider"`, `provides = ["docker-manager"]`. Variants change from
  `arcane, portainer` to `webui, arcane, portainer, none`. A runtime setting `dockerManager` (store = "settings") replaces the
  per-container `MANAGER` recipe preference. Further settings: `dockerStorage` (`fast` | `big`) and `dockerSize` (`s` | `m` | `l`,
  preset names that map to memory and CPU; exact values under Advanced as `dockerMemory`, `dockerCpus`). All in config/schema.toml with
  `capability = "docker"`, then `python3 scripts/schema-gen.py write`.
- Turning the capability on (`hs docker enable`, the wizard's last step) creates the container with `security.nesting=true`, the needed
  `syscalls.intercept.*` keys and a dedicated Incus custom volume for `/var/lib/docker` on the chosen pool, sets `managed_by = docker`, installs
  Docker and the chosen manager (the existing scripts/providers/docker/<variant>.sh files, now also `webui.sh`), declares the service.
- Changing the manager (wizard step reopened) reuses today's rule: the old manager's containers are stopped, its volume and compose file
  stay, nothing is deleted.
- Turning the capability off is destructive and follows the root rule: show a plan (instance name, number of child instances, volume size,
  the date of the newest snapshot), offer a snapshot first, make the user type the NAME `docker`, offer a background job. `hs rebuild` never
  removes the container because an option flipped to false: it stops and says "run `hs docker disable`".
- **Web interface manager (`webui`)**: a page in the existing web interface that lists children (compose projects), shows state, start, stop,
  logs and pull. It talks to the Docker engine of the parent through the same `incus exec` path as the reads, never a socket exposed to the
  network. Compose editing is out of scope for the first version (use Arcane or Portainer for that). Admin-only like every page. Because the
  manager would then be able to run anything as root in the parent, the permission is the same as "may change instances".
- Migration: a server that has `hs recipe docker` installed keeps working. `hs docker adopt` marks that container `managed_by = docker`,
  moves its `MANAGER` value into the setting and registers existing compose projects as children. Until then the recipe still works and
  the capability is off. The recipe is removed from hobnix/recipes one release after `adopt` exists.

### 4. The wizard (web interface only)

- One question per screen: a plain-language question, one grey help line, large option rows (whole row clickable, selected row tinted),
  a progress bar with "Step 2 of 4", a back arrow, a primary button, and a summary screen before anything changes. The mockup from the
  design discussion is the reference.
- Built from the components the web interface already has (web/src/ui, shell/PageHeader, shell/PlanDialog, tokens in web/src/tokens.css); no
  new colours, no new fonts, hard edges (`--r` 0) like the rest. The accent is `--accent`. New: `web/src/ui/Wizard.svelte` (frame, progress,
  back/next) and `web/src/ui/ChoiceList.svelte` (the option rows, radio or check). Both go into the list of shared components in
  .claude/rules/web.md.
- Data-driven, same declaration as the gateway: `[[settings.steps]]` in capability.toml gets two optional fields, `question` (the sentence)
  and `options` (`id`, `label`, `text`, `set = { key = value }`, `recommended`). A step without `options` keeps today's key list. `schema-gen.py`
  validates them like presets today (keys must exist and be named in the step's `keys`). `web/src/settings/steps.js` stays the pure logic and
  is tested in plain node (tests import it).
- Advanced: a link at the bottom left of every screen. It switches the whole wizard to the key/value list of the same draft (the existing
  `Fields` view of Steps.svelte); edits there show up when switching back. Review is always the last screen and opens the plan
  (`docker plan setup --set k=v...`, same change route as the gateway: `apply = "docker setup"`).
- Re-entry: from the Docker page, "Change manager" opens the wizard at that step only. A finished setup opens a summary page, not step 1.
- The gateway page moves to the same component in a later step (phase 5); until then Steps.svelte stays as it is.
- Copy follows the web interface's English and is also in the German strings file the interface uses. Sentence case, no "please", no
  "successfully".

### 5. Recipes: lxc, docker or vm

- A recipe header gets `# runs: lxc docker vm` (next to `# kind:`, `# needs:`, `# uses:`; tests/recipes-meta.sh keeps it true). The install
  flow offers only the declared runtimes and shows them as the same large option rows as the wizard ("In its own container", "In Docker",
  "In its own virtual machine", each with one grey line about cost).
- Default: `docker` when the capability is on and the recipe declares it, otherwise `lxc`. A recipe that needs a GPU or a device passthrough
  (`# uses: gpu`, for example Jellyfin and Tdarr) declares `lxc` only until Docker-in-LXC passthrough has been tested. `vm` is declared only
  where it is required (Samba AD) and is never a default.
- A recipe that supports Docker ships a compose file (the arr recipes already generate one inside their container; the generation moves to
  `scripts/recipes/_lib.sh` helpers that write it into the parent). The recipe's service is declared as for any child (`via = "docker"`).
- Existing installs are not moved. A move command (`hs recipe <name> move --to docker`, data export and import) is a later, separate
  piece of work and is not part of this plan.

### 6. Addresses

- A child is reachable in one of two ways. **Default: a published port on the parent's address**, named by the gateway. **Opt-in per child:
  its own LAN address**, through a Docker `macvlan` or `ipvlan` network inside the parent, for apps that need their own identity (port
  clashes, mDNS or discovery, a separate firewall rule).
- Own addresses need three things that are checked in phase 1 or phase 0, not assumed: the parent's NIC must accept extra MACs (Incus
  `security.mac_filtering=false` on that NIC, or ipvlan), the host cannot reach macvlan children over the same interface (a shim is needed if it
  must), and a reservation must exist for each child MAC (the UniFi path in scripts/unifi.sh today assumes one MAC per Incus instance).
- **Address blocks become configuration.** One schema option per block (`netBlockInfra`, `netBlockInstances`, `netBlockChildren`), each a
  range, defaults chosen so today's addresses stay valid: infrastructure (edge, gateway, locked instances), instances (containers and
  VMs), children (own-address Docker children); everything else stays DHCP. Changing a block applies only to NEW allocations; an existing
  reservation is never moved by a range change.
- **`hs net` owns allocation.** The Docker capability asks it for an address for a MAC and never picks one itself, so the router
  reservation and the block rules live in one place.

### 7. What can go wrong (and what the tests check)

| Risk | Handling |
|---|---|
| Nested Docker in an unprivileged LXC fails (overlay2, AppArmor, cgroups) | Phase 1 is a throwaway container test on real hardware before anything else is built. Not tested on hardware yet. |
| Storage driver on a ZFS-backed pool | Dedicated custom volume for /var/lib/docker, formatted so overlay2 works; ask in phase 1 which pool types are supported. |
| The lock is bypassed through one route | One shared check, tests for `hs`, the web change allowlist and `incus` called by the recipe code. Raw `incus delete` by root is not blocked and is documented. |
| Disabling destroys data | Typed name, plan with counts, snapshot offer, `hs rebuild` refuses to do it silently. |
| Docker's own iptables rules fight the host firewall | Docker runs inside the parent's network namespace, but published ports are reachable on the parent's address: the host nftables rules and the route guard stay the only public path; test that a child port is not reachable from the internet side without a route. |
| Child state read is slow | Read-only, timeout, goes through the collector (`reads-collect.sh`) as a slow read; the web shows the age like every other page. |
| Admin manager on a public route | `never-public` descriptor, covered by the existing guard test. |

## Phases

0. **Inspect** (no code): where instance facts are stored, who reads `hs sys ct list`, how the web allowlist (`CHANGES`) calls manage-ct.sh, and how addresses and reservations are
   allocated today (scripts/net*.sh, mac.sh, unifi.sh: the one-MAC-per-instance assumption, where the current blocks come from).
   Output: a short report in `.work/docker-instances/`. Adjust this plan.
1. **Hardware test** of nested Docker in an Incus container with the settings above on the real pool type. Result goes into this document.
2. **Lock** (`managed_by`, the shared check, the lock chip, tests). Useful alone; the gateway can use it later.
3. **Capability and children**: schema options, `webui` variant, create/enable/disable/adopt commands, `parent` field, list rows, service via
   parent, backups through the parent. Registry rows, smoke probes for new `reads`, docs guide, changelog entry.
4. **Wizard**: `Wizard.svelte`, `ChoiceList.svelte`, capability.toml fields, schema-gen validation, web tests (tests/web-forms-*, steps.js).
5. **Gateway wizard** moves to the same component (visual change only; keys and the `gateway setup` change stay).
6. **Recipes with `runs`**: header, install flow, compose helpers; convert the arr recipes first (they need no GPU), then the others one by one.
7. **Addresses**: block options, allocation through `hs net`, own-address children (after the phase 1 test of macvlan/ipvlan).
8. **Cleanup**: remove the docker recipe from hobnix/recipes, drop the `MANAGER` preference after `adopt` has shipped one release.

Phases 2 and 4 do not touch the same files and can run as separate sessions after phase 0.

## The gateway in a locked container (deferred, not part of this plan)

Not decided. The case for it is tidiness: Traefik leaves the host. The case against is that the gateway is the entry point and the way back in: if
the container or the Incus network is down, the web interface is unreachable exactly when you need it, and the web interface (always on the
host, never in Incus, see web.md) would have to listen on the bridge address as well, which is a new answer to "who can reach the admin
interface". Revisit after phase 2 and a few weeks of running Docker in a locked instance. The locked-instance flag from phase 2 is what such a
move would reuse.

## Decisions (recommended answers, the owner may override any of them)

1. One Docker container, named `docker`. A second host is possible later because `parent` allows it.
2. The web interface manager is read-only in the first version (state, start, stop, logs, pull). No compose editing.
3. No backup of a single child in the first version; the parent is the unit.
4. Published ports on the parent's address by default; an own LAN address per child is opt-in and comes in phase 7.
5. `webui` is the default manager; Arcane and Portainer are the "more features" choices, `none` stays.
6. Address blocks are configuration, defaults keep today's addresses valid, and a range change never moves an existing reservation.
7. `hs net` owns address allocation; the Docker capability only asks it.
8. Recipes declare `runs`; the default is `docker` when available, `lxc` otherwise, `vm` only where required.
9. Existing LXC-with-Docker installs are not moved automatically; a move command is a separate later piece of work.

10. GPU in Docker children: Intel and AMD through `/dev/dri` first (the Incus `gpu` device with the right `gid`, `group_add` in the compose
    file; tested with Jellyfin hardware transcoding in phase 1); NVIDIA through CDI later and marked "Not tested on hardware yet." until it is.
    The Docker capability, not the user, adds and removes the device (the lock forbids a manual change), asked in the wizard only when `gpu` is
    set in machine.toml. Known costs: all children share the card without limits, a driver upgrade needs a restart of the `docker` container,
    and Jellyfin and Tdarr stay `runs = lxc` until the test passes.
11. Reservations: `hs net` holds the desired state, the router the actual state. A mismatch is reported (`hs net check`), never fixed silently;
    `hs net ip <ct> sync` pushes the `hs net` value after confirmation, `hs net adopt` takes the router's value. `hs` changes only entries it
    created or adopted; new allocations are checked against the router's reservations and the DHCP range first.

## Still open

- Whether NVIDIA works at all in Docker inside LXC on the owner's card; found in a later hardware step, not in phase 1.
