# Plan: game servers, and the foundation they need

Design record. Contributor document, not a guide. Written 2026-11-28 from a design discussion with the owner. **Nothing here is built.** Epic:
hobnix/core#1409, milestone 0.15; the issues are listed in section 9. Not tested on hardware yet.

Related: [PLAN-core-daemon.md](PLAN-core-daemon.md), [PLAN-package-sdk.md](PLAN-package-sdk.md), [PLAN-app-lifecycle.md](PLAN-app-lifecycle.md),
ADR 0014, 0018, 0031, 0033, 0034.

## 1. Goal

Enshrouded as the first native game server, managed from one page. Behind it: a foundation (recipe runner, recipe SDK, core operations, backups of
app data) that the next recipes use too.

## 2. Decided by the owner

**Changed later on 2026-11-28.** Where the list below, section 9 or another section says otherwise, this applies:

- 0.15 is the Rust release (ADR 0035, `docs/adr/0035-015-rust-release.md`): no new product features are built in it. The game server feature work of this
  plan, the ingress contract (#918) included, is in milestone 0.16 "Game servers and autopilot". The design records (#1411, #1412), the prototype
  (#1410) and the backup fix (#1408) stay in 0.15. This replaces decision 5 for the feature work.
- Networking and Multi-node is renumbered from 0.18 to **0.19**: where this plan says 0.18, read 0.19.
- Basic VPS forwarding (#1419, #1420) is in 0.19, not in 0.15 (changes decision 11).
- The prototype (#1410) runs in a disposable container on the owner's server.
- Browser download and upload come with `hobnix-web`; nothing is added to the Python web server (answers open point O1).
- The fix of #1408 is written in Rust, with the port of the backup command.
- Extension actions as jobs (#1126) are in 0.15.

1. The published recipe waits for the new Rust core and SDK. No shell recipe is published first.
2. The extension is only a manager (like Portainer). A recipe registers through an integration so the manager finds it. Installing, starting, stopping and
   backing up must work without it. Rename `game-lobbies` to `game-servers` (stated as "probably").
3. One lobby = one game server = one container.
4. First release: install and update; start, stop, status; read-only logs; manual and scheduled backups with an external copy; restore; server name and
   password at setup. Later: automatic updates, idle sleep, a shell in the container, a full settings editor, a public wake-link page, player count (unless
   testing makes it easy).
5. The foundation and this work are part of milestone **0.15** (this replaces an earlier choice of a milestone after it). New volume operations are written
   in Rust in 0.15, although PLAN-core-daemon ports the existing storage commands last (P7). The backup bug is fixed in 0.15 on `develop` (#1408). The
   foundation comes first.
6. The live world is on a **private volume**, not a share. Volumes appear in the web interface, are in the backup, and get the same functionality as shares
   where it makes sense. Backups can be downloaded and uploaded. Copying finished backups to a share is optional.
7. Backups: hourly while running if files changed; after a clean stop; before updates and restores (server stopped); on request.
8. Retention: hourly 24 hours; daily 14 days; before update or restore the last 5 together; manual until deleted. The page shows the space used.
9. Saved world versions go into Hobnix's regular backup, to the configured destination (a backup disk in the same machine is not off site). The page shows
   when the last external copy succeeded. Restore brings back the world only by default, settings optional: stop, save the current state, restore, return to
   the previous running or stopped state. A failed restore leaves the server stopped and says why.
10. A recipe **declares** its ports. Ingress follows automatically: the local side or the VPS edge opens what is needed. Cooperation between packages
    of this kind is a goal of the project. The design is section 5.10.
11. Ingress in 0.15: the contract (#918), the home network case and basic VPS forwarding. UniFi (#919) and wake on connect (#921) stay in 0.18. The path
    from the VPS goes through the home server. Public rules are closed while a server is stopped and expire on the VPS after 7 days without renewal. A public
    reach needs a plan and the typed instance name once, and again only to expose more.
12. Updates are manual, to the newest game build, with a pinned GE-Proton: backup first and warn that players are disconnected. A restored world does not
    bring the old game version back.
13. Roles: viewer sees state; app-manager reads logs, starts, stops, backs up, restores, downloads and uploads the world; admin removes, purges and handles
    settings and anything with passwords. Access for single friends is later.
14. Removing a server keeps world and backups unless they are deleted with the typed name; a new server can use a kept volume. An existing world is imported
    after the install, through restore. Old manual lobbies are dropped.

Wanted: GE-Proton as the runtime. No evidence was found that it is faster than Wine for this server, so the prototype compares them.

## 3. How it works

```text
INSTALL / UPDATE
Marketplace -> job -> job runner (root, core) <-> recipe program (no root)
                          -> container, volume, service, game files, game description

DAILY USE
game-servers page -+
hs command --------+-> core operation -> job -> container / volume
schedule ----------+   (reads the game description; the recipe is not running)
```

| Part | Owns |
|---|---|
| Recipe `enshrouded` | install and update; the description of its server; later any game-specific helper |
| Core | permissions, jobs, instances, volumes, services, logs, snapshots, backup, restore, transfer |
| Extension `game-servers` | finds game servers, shows state and logs, offers the core's actions, wake links |
| Recipe SDK | the typed way a recipe asks the core |

**Rule:** what touches the host or enforces a safety rule is in the core. Knowledge about a third-party tool (SteamCMD, Proton, a game) is in the recipe, and
later in a shared crate.

**Shared code:** a Rust crate compiled into each recipe, not a package installed on the server. Not created before the second game; until then it is a module
of the Enshrouded recipe. ADR 0031 decision 2 allows shared crates as path dependencies outside the package tree (written for extensions; recipes need the
same rule). Library packages are out of scope.

## 4. What exists today

Read from the code of 0.14.1 and of `develop` on 2026-11-28, before the issues were filed. Nothing was run.

| Area | Today | Gap |
|---|---|---|
| Rust core | `rust/hobnix-core` has db, error, events, jobs, log, pair, secret, secrets | no operation model, no system access layer, nothing for Incus, volumes or services |
| Recipe SDK | none; recipes are shell over `scripts/recipes/_lib.sh` | PLAN-package-sdk writes `hobnix-pkg-recipe` only after two or three Rust recipes exist |
| Unprivileged recipes | none; ADR 0014 leaves the command broker undecided, ADR 0031 has none | new decision |
| Volumes | `hs ct <ct> storage add fast <name> <path>` creates and attaches an Incus volume (`scripts/manage-ct.sh`) | no list of volumes of their own, no snapshot, delete or restore command for them |
| Volumes in the backup | **not included:** `scripts/backup.sh` backs up `<instance>/rootfs` for a container; the backup scripts never mention volumes | data-loss risk for anyone using a `fast` volume today (#1408). Read from the code, not reproduced |
| Volumes and snapshots | `hs ct <ct> restore` says attached storage is not part of a snapshot | same |
| Web interface | Storage > Shares lists "instance volumes": these are the instances' own disks | attached volumes are not listed there |
| Share snapshots | hourly: 24 hourly, 7 daily, 4 weekly (`scripts/snapshots-auto.sh`) | retention is fixed and for shares only |
| Downloads | `web-serve.py` sets `Content-Disposition` only for inline images and files; no general download found | download and upload to build |
| Integrations | `rows()` in `scripts/lib/pkg_integrations.py` gives one row per package and integration, filled from `services.d/<package>.toml`; values are short plain text | two servers of one recipe do not both appear |
| Package rename | `renamed_from` is written into the index; no other code under `scripts/` reads it | installed packages would not follow a rename |
| Ports of an app | `[app.uses] ports` is a list of numbers (`pkg_app.py`); a service descriptor has one HTTP or HTTPS port | no protocol, purpose or UDP |
| Reconciler for HTTP | `services.d` descriptors with `want` slots; `hs services plan` and `apply`; the local proxy applies additions by itself | HTTP by host name only; Traefik cannot name-route a UDP game |
| VPS edge (`edge-ports`) | static lists in `machine.toml`, applied by NixOS; one target address for the game pool; 22, 25, 80, 2222, 41641 refused; the Tailscale ACL is changed by hand on purpose. Its notes say it never ran on a real VPS (#422) | nothing the home server can change |
| Home to VPS | the node key runs a forced command with the fixed words `status` and `pair` (`scripts/node-remote.sh`) | no word that changes ports |
| LAN | instances sit on bridges of the home network with their own address; no host rule for their ports was found in the files read | whether anything must be opened on the host for LAN access is to be tested |
| Planned already | #918 (`ingress.port_forward`, `[[ports]]`; moved to 0.15 by this plan), #919 (UniFi) and #921 (VPS edge with wake) in 0.18; #920 later; #1275 private access | this plan builds on them |
| `game-lobbies` | saved lobbies, state, container snapshot restore, wake links (no page serves them); players = TCP connections | UDP games count 0; restore does not touch volumes; commands do not opt into confinement |

## 5. What is needed

The IDs are used by the issues of section 9. Names of tables and operations are proposals.

### 5.1 Core: the operation model (input to 0.15)

- **C1** An operation (plan 4.1) can be requested by a **job acting for a package**, not only by a person: the allowed targets are part of the request context
  and are checked in the core.
- **C2** The resource is the **instance** (`instance:<name>`), never the package. One package can have many instances.
- **C3** A job record carries the package and the instance (also asked by #1126).
- **C4** The system access layer's Incus trait is shaped for storage volumes, volume snapshots, devices and exec, even if 0.15 builds only start and stop.
- **C5** Each operation declares plan, apply, locks and cancel class as plan 4.1 and 5 say, and is safe to repeat where its name says "ensure".

### 5.2 Core: operations

| ID | Operations | Notes |
|---|---|---|
| **C6** instances | ensure, start, stop, restart, remove, state, fixed address, exec and put file inside | settings are limited: never privileged, no host path, devices only as declared and approved |
| **C7** services in an instance | ensure unit, enable, start, stop with timeout, state | a forced stop is reported, never counted as a clean stop |
| **C8** logs | read the last lines, follow | bounded output, role check; logs may hold personal data |
| **C9** volumes | ensure, attach, detach, list, size, delete keeping the data, list deleted, restore deleted, purge | purge is destructive: typed name and a plan |
| **C10** volume snapshots | create, list, delete, retention policy, read files from a snapshot | one retention engine; shares can move to it later |
| **C11** volume backup | include or exclude, back up from a snapshot, restore, last external success | on by default for app data |
| **C12** app backup and restore | the sequence of decision 9, using the app description | restore copies files; it does not roll the volume back (that can destroy newer snapshots) |
| **C13** transfer | export a backup as an archive, import an archive | see 5.6 |
| **C14** schedule | per-instance backup schedule: timer starts the operation | works with the daemon stopped (plan 11) |
| **C15** ports and services | declare TCP and UDP ports; the existing service rules | `ADMIN_TARGETS` stays; nothing becomes reachable from the internet without the approval of 5.10 |
| **C16** secrets | per-instance secrets for a package (#1125) | never in argv, environment, job records or logs |

### 5.3 Recipe runner (needs an ADR first)

- **R1** The recipe program runs as an unprivileged user. The job runner (root, core) talks to it over a private connection that it opens itself; the
  connection is the identity. The recipe never gets a user's session.
- **R2** Rights = what the manifest declares **and** the user approved in the plan, limited to the instances and volumes of this job.
- **R3** Only typed operations. A command line is accepted only for exec **inside** the job's own unprivileged instance.
- **R4** The runner does not depend on `hobnixd`: a daemon restart does not stop a job.
- **R5** Progress, questions (ADR 0018), cancel at safe points, and a clear state after failure or reboot.
- **R6** A failed first install never deletes a volume that existed before. What it created is listed and can be removed.
- **R7** Shipping: a recipe is a `[[binary]]` like a Rust extension (ADR 0031): hash checked, built by the release preparation.
- **R8** Shell recipes keep working unchanged.

The ADR amends ADR 0014 (broker) and states how it relates to ADR 0031 decisions 7 and 8 (those are about services; they stay).

### 5.4 Recipe SDK `hobnix-pkg-recipe`

- **S1** Wire messages in `hobnix-pkg` beside the command and service ones.
- **S2** Hooks: install, configure, update, remove. Steps with `check` and `apply` (#1219), so a second run changes only what differs.
- **S3** Typed calls for C6 to C10, C15, C16.
- **S4** A fake core in `hobnix-pkg-test`; a template for `hs pkg new`.
- **S5** Change the rule "only after two or three Rust recipes": Enshrouded is the first user. The API stays marked unstable until a second recipe uses it.

### 5.5 App description

- **M1** What the core needs is typed in `[app]` of `package.toml` and stored per instance: service units and stop timeout; data sets (volume, path inside the
  instance, which files are the world, which are settings, which hold secrets, how to get a consistent copy); log source; ports. `[app]` exists
  (`scripts/lib/pkg_app.py`); which of its planned keys are acted on must be checked first.
- **M2** `[integrations.gameserver]` holds only what the manager needs to find a server and its game-specific features (console kind, player count method).
  A fact is written in one place.
- **M3** Integrations are listed **per instance**, with an instance column. The `sys` row shape is a contract: add, do not change.
- **M4** `instances = "many"` works for this recipe (PLAN-app-lifecycle Q7).

### 5.6 Safety rules for app data

The container can write the volume, and root on the host reads it. So:

- Never follow a symbolic link out of the volume; open files relative to the volume root. No devices, sockets or hard links to outside.
- An imported archive is checked before anything is written: no absolute path, no `..`, no links or special files, limits on size and file count. It is
  unpacked into a new folder, then swapped in by the restore sequence.
- An export contains the world by default. Settings need a higher role and a warning, because they can hold passwords.

### 5.7 Web interface

- **W1** Volumes in Storage, with size, instance, pool, backup state and last external copy.
- **W2** The same functions as shares where they make sense:

| Function of a share | For a volume |
|---|---|
| list, size, create | yes |
| delete keeping the data, restore | yes |
| rename | later (it must update the attachment) |
| snapshots: manual, automatic, list, restore | yes |
| backup on or off, restore from backup | yes |
| browse files | read only, with the rules of 5.6 |
| Samba permissions, visibility, upload cache, SnapRAID parity | no |

- **W3** Download and upload of backups. In today's `web-serve.py` or in `hobnix-web` (P6, later): to decide.
- **W4** Page blocks: a log view. #1123 (terminal) and #1124 (RCON) are not needed for Enshrouded. Check first whether a log block exists.
- **W5** Extension actions as jobs (#1126), calling core operations without running as root itself. This needs the same permission check as R2.

### 5.8 Extension `game-servers`

- **G1** Rename; commands, state folder, page, events. Old manual lobbies are dropped (the guide marks the package untested).
- **G2** Servers come from the integration; no per-game code.
- **G3** Start, stop, logs, backups, restore, download and upload through core operations. The container snapshot restore goes away.
- **G4** Wake links stay; the public page is later.

### 5.9 Package manager

- **P1** The client follows `renamed_from`: installed state, saved data, enabled state and permissions move.

### 5.10 Ingress

**Model: declared wishes, one reconciler per provider. Events only wake it.** An "open" or "close" event that gets lost must not leave a port open to the
internet. PLAN-core-daemon section 7 says the same: events are not commands, and a disconnected watcher misses events.

```text
recipe declares [[ports]] -> core stores them per instance, with the port numbers given out
person sets the reach of the instance (once)
        -> core computes the wanted rules -> event `ingress.changed` (a wake-up only)
        -> each provider reads ALL its wanted rules, lists its own real rules, adds and removes the difference
        -> reports the state of every rule: open, pending, refused (why), failed (why)
also run: at boot, after a rebuild, after the provider comes back, and on a slow timer
```

**Who says what**

| Who | Says | Never says |
|---|---|---|
| Recipe | per port: name, protocol, default number, purpose (`play`, `query`, `web`, `admin`), required or optional, whether the number may differ per server | where it is reachable, which router or VPS |
| Core | the number each instance gets (no clash, kept for the life of the instance, static forwards counted) | |
| Person | the reach per instance, and which provider | |
| Provider | what it can do (protocols, port range, wake) and the real state | |

`[[ports]]` (#918) becomes the one place for ports; `[app.uses] ports` is then derived from it.

**Reach**

| Reach | Means | Provider |
|---|---|---|
| `lan` (default) | home network | none if the test confirms that nothing must be opened |
| `private` | also over private access | the private-access interface (#1275) |
| `public-edge` | also from the internet through the VPS | `edge-ports` |
| `public-router` | also from the internet through the home router | `router-unifi` (#919) |

**What is automatic.** Choosing a public reach once shows a plan (ports, protocol, path, who can connect) and needs the typed instance name. After that,
install, restart, a changed address, a reboot and removal are handled without questions. A new port, for example added by a recipe update, **widens** the
exposure and needs a new yes. Closing never needs one. No package sets the reach, and enabling a provider changes no instance (#1275 rule).

**Safety rules**

1. An `admin` port is never public. This is checked in the core and again by the provider (the `ADMIN_TARGETS` rule for TCP and UDP).
2. **The VPS has its own policy**, set by a person on the VPS: allowed port ranges, allowed targets, forbidden ports, a maximum number of rules. The home
   server can only act inside it. A broken or taken-over home server must not turn the VPS into an open forwarder.
3. The home server sends the **whole wanted set** (on stdin, like `pair`), not "open" and "close". A new fixed word of the forced command, with a key of its
   own, so the status key stays read only. This needs an ADR.
4. A provider touches only rules it tagged (`hobnix:<instance>:<port>`). A clash with a rule made by hand is reported, never overwritten.
5. Unknown means closed: a wish that cannot be read or checked opens nothing.
6. Rules on the VPS have a lease that the home server renews; it lasts 7 days, to survive an outage, so a rebuilt or lost home server does not
   leave forwards behind for ever.
7. Dynamic rules on the VPS live in their own nftables table, are saved, and come back after a reboot and a `nixos-rebuild` (to be tested). The static
   `edge-ports` options keep working.

**The path from the VPS to the instance.** Today the game pool goes to one tailnet address. Two ways for many servers: (a) private access in every instance,
each with its own ACL entry; (b) **decided:** the home server is the one target on the tailnet and forwards to its instances. (b) needs one ACL entry for
a port range, set once by hand, after which the core gives out ports only inside the range. (b) is also where the home firewall gets rules. To be tested.
`edge-ports` masquerades, so the game server sees the address of the edge, not the player's: bans by address will not work. The install plan says so.

**Stopped servers.** A public rule is closed while the instance is stopped. With wake on connect (#921, later) the edge keeps the port and answers
itself until the server runs. A wake from the internet starts a server, so it is opted into per instance and rate limited.

**Showing it.** One view per instance: each port, the reach asked, the provider, the real state, the address to join, the last check. A rule that is "open"
on the provider is not proof that players get through; an outside check (`edge-watcher`) is easy for TCP and needs a game query for UDP.

**LAN names.** The local name of the gateway points at the host, so it does not lead to a game server on its own address. The first version shows
`address:port`. DNS records are not written by `hs` today.

**HTTP routes** stay as they are. The ingress model is shaped so that the two reverse-proxy slots can become providers of it later; no rewrite now.

### 5.11 The pattern behind it: packages cooperate through contracts (proposed)

The same steps work for more than ports: a package **declares a need**, the core stores it, an event wakes the **providers**, each makes reality match and
**reports back**. Packages never call or configure each other, and name an interface, never a product.

| Need declared | Possible provider | Result |
|---|---|---|
| ports | VPS edge, router, private access | reachable |
| data to keep | backup | backed up, with the age of the last copy |
| health check | health, notifications | alert and recovery message |
| web page or join address | proxies, dashboard | route and tile |
| metrics | `metrics` | graphs |
| activity (players, requests) | later: idle sleep, safe updates | stop when idle, update when empty |
| secret | secret store (#1125) | created, delivered, removed with the instance |

Rules for every contract: it has a version; a fake provider and a shared test; no provider means "reported, not done", never a failed install; removing an
instance withdraws every need; the **install plan lists what will happen** ("also: backed up nightly, UDP port on the VPS, tile on the dashboard").

**Two kinds of automation, not to be mixed:**
- *Make it so, soon* (ingress, tile, monitoring): wanted state and reconcile.
- *Must happen before the next step* (backup before update): a step of the same job. An event cannot make a job wait.

Do not build a general framework first. Build ingress with these rules, then use it for a second contract and extract what is shared.

## 6. What should move into Rust

Move a thing when the foundation needs it. Do not port for its own sake.

| From | What | When |
|---|---|---|
| `_lib.sh`: `ensure_container`, `fixed_address`, `address`, `in_ct`, `wait_internet`, `wait_page` | instance operations | with C6 |
| `_lib.sh`: `piece`, `stamp_get`, `stamp_set`, `fetch_pinned`, `ensure_file`, `check_done` | idempotent steps in the SDK; downloads with checksum | with S2 |
| `_lib.sh`: `declare_service`, `service_*`, `declare_dump`, `backup_with_dump`, `seed_backup_rules` | app description and service operations | with M1, C15 |
| `manage-ct.sh`: storage add | volume operations | with C9; the old command calls the core |
| `snapshots-auto.sh` | retention engine | built new for volumes (C10); shares switch later |
| `lib/backup-rules.sh` and the instance part of `backup.sh` | what is backed up | new volume part in Rust only if the fix of #1408 is not enough |

Stays as it is: installer, unlock, recovery, `hs update` and rollback (ADR 0032 decision 3); shell recipes; the rest of `backup.sh`.

**Decided (decision 5):** PLAN-core-daemon moves "storage last" (P7). C9 to C12 are new storage operations and are written in Rust in 0.15; the porting
of existing storage commands stays in P7. PLAN-core-daemon needs a note that says so.

## 7. Prototype: find out before designing the API

A disposable container, nothing published. Each answer goes into this file.

1. GE-Proton (pinned, checksum) and Wine: start without a Steam client, CPU, memory, a long run, `ntsync`.
2. SteamCMD: anonymous install of app 2278520; how to read the installed and the newest build.
3. Stop: which signal saves the world, how long it takes, how to tell that it saved.
4. Saves: which files, how they are written; restore snapshots, including some taken during a save.
5. Read files from an Incus volume snapshot on ZFS, safely (decides C10 and C11).
6. Ports: which are needed (guides say UDP 15637); joining from the LAN and over Tailscale.
7. Player count: A2S or logs.
8. Console: third-party sources say there is no RCON and no input; confirm.
9. Settings file: format, secrets, whether an update rewrites it.
10. Memory, CPU and disk for a sensible default and a minimum.
11. Running the game as a non-root user inside the container.
12. Import of an existing world from a player's PC or another host.

## 8. Open decisions

| # | Question | Recommendation |
|---|---|---|
| O1 | Download and upload: in today's web server or only with `hobnix-web` (P6) | decided 2026-11-28: with `hobnix-web` |
| O2 | "Daily 14 days" (decision 8) | the newest backup of each day is kept 14 days |

Open also in 0.15 and needed here: ADR 0033 items P-a (how an operation is declared) and P-b (system access layer), which #1338 needs first. The contracts of
5.11 are a direction, not yet a decision.

## 9. Order and issues

All in 0.15. Epic: #1409.

1. #1408 (backup bug) and the input C1 to C5 to #1338, before that design is fixed.
2. Prototype (section 7). It does not wait for the core.
3. The ADRs, then the core operations, then runner and SDK, then recipe and extension. F4 onward builds on 0.15 steps P1 and P2.
4. Ingress (F14 to F16) can run beside F5 to F7; F13 needs F14.

This makes 0.15 much larger. PLAN-core-daemon already names P3 as the largest risk to its size.

| ID | Title | Contains | Needs | Where |
|---|---|---|---|---|
| #1408 | Backup: volumes attached to an instance are not included | see the issue | - | core |
| F0 #1409 | Epic: game servers and the recipe foundation | this plan | - | core |
| F1 #1410 | Prototype: Enshrouded in a disposable container | section 7 | a real server or VM | core |
| F2 #1411 | ADR: unprivileged recipe runner | R1 to R8, C1 | #1338 | core |
| F3 #1412 | ADR: app description and per-instance integrations | M1 to M4 | F1 | core |
| F4 #1413 | Core: instance, service and log operations | C6 to C8 | #1338, 0.15 P2 | core |
| F5 #1414 | Core: volume operations and web pages | C9, W1, W2 | #1338 | core |
| F6 #1415 | Core: volume snapshots, retention, backup, schedule | C10, C11, C14 | F1 (point 5), F5, #1408 | core |
| F7 #1416 | Core: app backup, restore, export and import | C12, C13, 5.6, W3 | F3, F6 | core |
| F8 #1421 | Core: recipe runner | R1 to R8 | F2, F4, 0.15 P2 | core |
| F9 #1422 | SDK: `hobnix-pkg-recipe` | S1 to S5 | F8 | core |
| F10 #1417 | Core: app description, instances and integrations | M1 to M4, C16 | F3, #1125 | core |
| F11 #1418 | Package manager: follow `renamed_from` | P1 | - | core |
| F12 #1423 | Extension: `game-servers` | G1 to G4, W4, W5 | F7, F10, F11, #1126 | hobnix/official |
| F13 #1424 | Recipe: `enshrouded` | decision 4 | F1, F7, F9, F10, F14 | hobnix/official |
| #918 | Ingress contract, `[[ports]]`, port numbers, reconciler, view (F14, extends the issue) | 5.10, C15 | F3 | core |
| F15 #1419 | ADR: changing ports on a node (word, key, VPS policy, lease) | safety rules 2, 3, 6, 7; path (b) | F14 | core |
| F16 #1420 | `edge-ports` as an ingress provider, without wake | 5.10 | F15, #422 | core |

#919 (UniFi) and #921 (wake) stay in 0.18. All issues above are filed; F14 is #918, moved here from 0.18.

Seen on 2026-11-28: #924 is open in 0.12; #1123, #1124 and #1126 are open in 0.14; #1125 is open in 0.15. Whether any of them moves is the owner's call.

## 10. Check that it worked

On a real server: install two Enshrouded servers; join one; stop and start both with the extension off; back up while a player is in the world; restore a
world; download it and upload it again; remove a server and attach its kept volume to a new one; restore from the external backup after deleting the volume.
Set one server to public through the edge and join from outside; reboot home server and VPS; lose one `ingress.changed` event and see the timer repair it;
remove the server and see that no rule is left on either side.
Not tested on hardware yet.
