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

- Instance property `managed_by = "<capability>"`, stored as the Incus config key `user.hs.managed_by` on the instance (phase 0 confirmed:
  instance facts are Incus config only, and the backup inventory saves `incus config show --expanded`, so the key is kept in backups).
- Refused for a locked instance unless the caller is the owning capability: delete, rename, `hs ct <ct> set` of disk shrink or kind,
  `--set docker=no` (unsets nesting), `--remove-storage`, device removal. Restore of a snapshot is allowed (snapshots carry the config); a
  check afterwards asserts the restored config still has `user.hs.managed_by` (unverified whether an old snapshot predates the key).
  Allowed: start, stop, restart, snapshot, backup, console, exec by an admin.
- ONE check in one lib function: `scripts/lib/instance.sh` with `instance_owner <ct>` and `refuse_if_locked <ct> <action>`. It is called by
  scripts/manage-ct.sh (after `incus info`, also under `--dry-run`, so the web plan shows the reason before the typed-name dialog; this covers
  the web plan/start and `hs ct`) and by create-share.sh, manage-shares.sh and share-delete.sh, which change instances directly. The owning
  capability is named by the caller mechanism `HS_OWNER=<capability>` in the environment of the call. The web and `hs` must not each
  implement it; a test asserts every route is refused.
- The refusal message names the owner and the way out: "Docker owns this instance. Turn Docker off under Settings, Capabilities, Docker."
- The instance list shows a lock chip (web/src/ui Chip) and the delete action is absent, not disabled.

### 2. Child instances

- Instance kind `docker` (next to `empty`, `vm`; today `hs ct add --kind empty|docker|vm`, where `docker` means a container that has Docker
  inside; rename that old meaning to `docker-host` in help text and keep the flag working for one release as `legacy:`). The rename touches
  three places: `ct-change.sh --type container|docker|vm`, the web CHANGES regex (web-serve.py) and tests/dialogues.sh. Note the
  collision with the `docker` icon/name in ct.js `ctIcons`.
- A child has `parent = <instance>`. It is a record, not an Incus instance: name, parent, compose project name, published ports, state read
  from the Docker API inside the parent.
- Reads: the parent goes in a NEW trailing field of `hs sys ct list` (col 17, empty written `-`); phase 0 found that no reader breaks on an
  extra trailing field (all read by index). Children do NOT come from `manage-ct.sh --list`: running `incus exec ... docker ps` there would
  make the 5 s poll and the 10 s collected read slow and tie them to the Docker engine. Children come from a separate read
  (`hs sys docker list`, its own topic and slow read). Whether ct list appends them from that cached result is open (see Still open).
- If child rows are appended, they use type `docker` and address `-` (or the child's own address only). Every reader (Instances offers
  start/stop/delete that fail with "does not exist"; Shares, NewShare, ServiceForm offer it as bind or target; `servicesOf` matches by IP and
  would show every child service on the parent) filters `type === 'docker'` unless it handles children. Names are unique across instances and
  children and contain no `/` (the CT regex and URLs).
- State of a child comes from the manager-independent source: `docker compose ls` / `docker ps` run in the parent through `incus exec`
  (read-only, short timeout). With `live-state` (docs/PLAN-web-cache.md) this is one more topic that must publish to the `ct-list` group
  (instances, shares, network), otherwise those pages do not refresh on child changes; without it, the normal cache.
- Services and routes: a child declares its service like a recipe does (`declare_service`) but the target is `<parent address>:<published port>`.
  The descriptor gets a `via = "<parent>"` field. The admin-page rule is unchanged: the manager's own page is `never-public` (ADMIN_TARGETS).
- Backups: the unit is the parent. Phase 0 found that container backup is restic over `$INCUS_ROOT/<name>/rootfs` (default pool only) with
  `var/lib/docker/overlay2` and `image` excluded, and a custom volume mounted at `/var/lib/docker` is NOT under rootfs, so named Docker
  volumes would not be backed up at all. App data therefore needs bind directories inside rootfs, or a second volume that backup.sh learns
  to include (open, see Still open), plus a `dump_hook` per child. A child is never backed up on its own in the first version. The list shows
  "backed up with docker".
- Restore of one child is out of scope for the first version; restoring the parent is the supported path.

### 3. The capability

- `capabilities/docker/capability.toml` keeps `kind = "provider"`, `provides = ["docker-manager"]`. Variants change from
  `arcane, portainer` to `webui, arcane, portainer, none`. A runtime setting `dockerManager` (store = "settings") replaces the
  per-container `MANAGER` recipe preference. Further settings: `dockerStorage` (only if a second Incus pool exists, see Still open; today there is one pool, `default` on ZFS fast/incus) and `dockerSize` (`s` | `m` | `l`,
  preset names that map to memory and CPU; exact values under Advanced as `dockerMemory`, `dockerCpus`). All in config/schema.toml with
  `capability = "docker"`, then `python3 scripts/schema-gen.py write`.
- Turning the capability on (`hs docker enable`, the wizard's last step) creates the container with `security.nesting=true`, the needed
  `syscalls.intercept.*` keys and a dedicated Incus custom volume for `/var/lib/docker` (on ZFS a block-type volume, `--type=block` with
  ext4, or ZFS 2.2 or newer, because overlay2 needs it; Not tested on hardware yet) on the chosen pool, sets `managed_by = docker`, installs
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
  `security.mac_filtering=false` on that NIC, or ipvlan; unverified on the UniFi VLAN), the host cannot reach macvlan children over the same
  interface (a shim is needed if it must), and a reservation must exist for each child MAC (phase 0: every path reads one MAC,
  `expanded_devices.eth0.hwaddr`, and mac.sh pins only eth0).
- **Address blocks become configuration.** Phase 0 found there is no allocator and there are no configured blocks today: the ranges exist
  only as a comment and defaults in `fixed_address` (recipes/_lib.sh: first free of `.40-.99`, then `.50-.99`, in the container's /24; comment:
  .10-.19 access from outside, .20-.29 apps, .30-.39 games, .40-.49 tools) and as `unifi-write-networks` (default 10.10.95.0/24). One schema
  option per block (`netBlockInfra`, `netBlockInstances`, `netBlockChildren`), each a range. The defaults must encode those recipe ranges
  (.10-.99 by purpose) and `unifi-write-networks`: infrastructure (locked instances; the edge node is remote and the gateway runs on the
  host IP, so neither needs a block entry), instances (containers and VMs), children (own-address Docker children); everything else stays
  DHCP. Changing a block applies only to NEW allocations; an existing reservation is never moved by a range change.
- **`hs net` owns allocation.** The Docker capability asks it for an address for a MAC and never picks one itself, so the router
  reservation and the block rules live in one place. First `hs net` must absorb the two paths to the router that exist today: manage-ct.sh
  `fix_ip` and net-ip.sh (both call scripts/unifi.sh `set-ip` directly) and recipes `fixed_address` (through the provider
  scripts/providers/network/<np>.sh); one path via the provider. It also keeps a state file of the reservations hs created (Decision 11 needs
  it; nothing records them today).

### 7. What can go wrong (and what the tests check)

| Risk | Handling |
|---|---|
| Nested Docker in an unprivileged LXC fails (overlay2, AppArmor, cgroups) | Phase 1 is a throwaway container test on real hardware before anything else is built. Not tested on hardware yet. |
| Storage driver on a ZFS-backed pool | Dedicated custom volume for /var/lib/docker; overlay2 on ZFS needs a block-type volume (`--type=block`, ext4) or ZFS 2.2 or newer (unverified); ask in phase 1 which pool types are supported. |
| The lock is bypassed through one route | One shared lib check (scripts/lib/instance.sh). Routes that change instances without manage-ct.sh: create-share.sh (raw.idmap), manage-shares.sh (device source, restart), share-delete.sh (device remove), recipes/_lib.sh (limits.memory, gpu, nvidia.*, tun, restarts), mac.sh (eth0 override); each calls the check or gets the `HS_OWNER` bypass for the owning capability. Tests for `hs`, the web change allowlist and `incus` called by the recipe code. Raw `incus delete` by root is not blocked and is documented. |
| Child with its own MAC on a bridged NIC | Needs `security.mac_filtering` off on that NIC; unverified on the UniFi VLAN (phase 7 test). |
| Deleting the parent leaks child reservations | Deleting clears only eth0's reservation; the delete plan lists child reservations and removes them (via the `hs net` state file). |
| `ct-list` live topic (instances, shares, network) misses child changes | The docker read must publish to the `ct-list` topic group; a test asserts it. |
| Disabling destroys data | Typed name, plan with counts, snapshot offer, `hs rebuild` refuses to do it silently. |
| Docker's own iptables rules fight the host firewall | Docker runs inside the parent's network namespace, but published ports are reachable on the parent's address: the host nftables rules and the route guard stay the only public path; test that a child port is not reachable from the internet side without a route. |
| Child state read is slow | Read-only, timeout, goes through the collector (`reads-collect.sh`) as a slow read; the web shows the age like every other page. |
| Admin manager on a public route | `never-public` descriptor, covered by the existing guard test. |

## Phases

0. **Inspect** (no code) DONE. Report: `.work/docker-instances/phase0.md` (git-ignored; findings summarized here, plan adjusted above).
   - Instance facts are Incus config only; `user.hs.managed_by` fits and is kept in backups.
   - `hs sys ct list` has 16 fields, all readers use indexes; an extra trailing field breaks none, extra ROWS would.
   - manage-ct.sh covers web plan/start and `hs ct`, but shares, recipe helpers and mac.sh change instances directly: the check is a lib function.
   - No address allocator and no blocks exist; two paths to the router (unifi.sh direct, provider); reservations are not recorded.
   - Container backup excludes custom volumes and docker overlay2; Incus has one pool (`default`, ZFS fast/incus), none on bulk.
   - `docker` already means "nested host" in ct-change.sh, the web regex, tests/dialogues.sh and ct.js icons.
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
- Whether children appear in `hs sys ct list` at all. Phase 0 recommends: the parent field is col 17 and children stay OUT of ct list in
  phase 3 (only `hs sys docker list`), because every page would treat a child row as an Incus instance.
- Where app data lives: bind directories inside the parent's rootfs (backed up today), or a second volume that backup.sh learns to include.
- Storage choice: drop `dockerStorage` `big` (one pool only), or create a new Incus pool on bulk (on snapraid bulk is ext4 + mergerfs).
