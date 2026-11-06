# Roadmap

Where Hobnix is going and what is open now. For people who want to help or to know what comes next.

**The source is the GitHub project board** ([Hobnix Roadmap](https://github.com/orgs/hobnix/projects/1)), not this page. This page is a
snapshot of it, made with `python3 scripts/roadmap-gen.py write` (it runs `gh project item-list`), and can be behind. The second table is made
from `TODO.md` in the same way. Nothing between the markers is edited by hand. Status and priority of an issue are changed on the board.

## Milestones

The milestones are releases in order of work, not dates. An issue without a milestone is not planned yet.

<!-- BEGIN board (python3 scripts/roadmap-gen.py write) -->

### 0.1 — Trustworthy Foundation

47 issues, 31 done.

| Issue | Status | Priority | Title |
| --- | --- | --- | --- |
| [#128](https://github.com/hobnix/server/issues/128) | In Progress | P0 | Epic: Unified Job System |
| [#139](https://github.com/hobnix/server/issues/139) | In Progress | P0 | Epic: Event Architecture |
| [#171](https://github.com/hobnix/server/issues/171) | In Review | P0 | Disk and pool failure handling review |
| [#252](https://github.com/hobnix/server/issues/252) | In Review | - | ADR: declarative system state vs dynamic runtime state |
| [#322](https://github.com/hobnix/server/issues/322) | Ready | - | Entry status, source and ttl in the live document |
| [#147](https://github.com/hobnix/server/issues/147) | Backlog | P0 | Epic: Reactive Live-state |
| [#153](https://github.com/hobnix/server/issues/153) | Backlog | P0 | Dependency graph and invalidation propagation |
| [#155](https://github.com/hobnix/server/issues/155) | Backlog | P0 | Docker event stream as an event-driven collector |
| [#157](https://github.com/hobnix/server/issues/157) | Backlog | P0 | State inspector page (developer section) |
| [#159](https://github.com/hobnix/server/issues/159) | Backlog | P0 | Epic: Reliability and Recovery |
| [#161](https://github.com/hobnix/server/issues/161) | Backlog | P0 | Run the auto-rollback on the real server and record the result |
| [#163](https://github.com/hobnix/server/issues/163) | Backlog | P0 | Rebuild rehearsal in a VM from backup disk and passphrase (TODO A5) |
| [#165](https://github.com/hobnix/server/issues/165) | Backlog | P0 | Run the first monthly restore-drill report |
| [#169](https://github.com/hobnix/server/issues/169) | Backlog | P0 | Config backup and restore as a documented, tested flow |
| [#323](https://github.com/hobnix/server/issues/323) | Backlog | - | Show stale and error state in the web interface |
| [#324](https://github.com/hobnix/server/issues/324) | Backlog | - | Bring the reads table to the live entry shape or retire it |

Done: [#121](https://github.com/hobnix/server/issues/121), [#122](https://github.com/hobnix/server/issues/122), [#123](https://github.com/hobnix/server/issues/123), [#124](https://github.com/hobnix/server/issues/124), [#125](https://github.com/hobnix/server/issues/125), [#126](https://github.com/hobnix/server/issues/126), [#127](https://github.com/hobnix/server/issues/127), [#129](https://github.com/hobnix/server/issues/129), [#131](https://github.com/hobnix/server/issues/131), [#133](https://github.com/hobnix/server/issues/133), [#135](https://github.com/hobnix/server/issues/135), [#137](https://github.com/hobnix/server/issues/137), [#141](https://github.com/hobnix/server/issues/141), [#143](https://github.com/hobnix/server/issues/143), [#145](https://github.com/hobnix/server/issues/145), [#149](https://github.com/hobnix/server/issues/149), [#151](https://github.com/hobnix/server/issues/151), [#167](https://github.com/hobnix/server/issues/167), [#253](https://github.com/hobnix/server/issues/253), [#286](https://github.com/hobnix/server/issues/286), [#288](https://github.com/hobnix/server/issues/288), [#289](https://github.com/hobnix/server/issues/289), [#290](https://github.com/hobnix/server/issues/290), [#291](https://github.com/hobnix/server/issues/291), [#292](https://github.com/hobnix/server/issues/292), [#293](https://github.com/hobnix/server/issues/293), [#294](https://github.com/hobnix/server/issues/294), [#295](https://github.com/hobnix/server/issues/295), [#296](https://github.com/hobnix/server/issues/296), [#297](https://github.com/hobnix/server/issues/297), [#298](https://github.com/hobnix/server/issues/298)

### 0.2 — Usable Platform

20 issues, 0 done.

| Issue | Status | Priority | Title |
| --- | --- | --- | --- |
| [#231](https://github.com/hobnix/server/issues/231) | In Progress | P0 | Update channels: stable (tags), beta (release candidates), edge (develop); `hs update` follows the channel; web setting |
| [#173](https://github.com/hobnix/server/issues/173) | Backlog | P0 | Epic: Installation and Onboarding |
| [#175](https://github.com/hobnix/server/issues/175) | Backlog | P0 | Boot the ISO on real hardware or a VM, record what breaks |
| [#177](https://github.com/hobnix/server/issues/177) | Backlog | P0 | Capability selection step (depends on E18) |
| [#179](https://github.com/hobnix/server/issues/179) | Backlog | P0 | Network setup and validation step |
| [#181](https://github.com/hobnix/server/issues/181) | Backlog | P0 | Storage discovery and disk adoption in the wizard |
| [#183](https://github.com/hobnix/server/issues/183) | Backlog | P0 | First-run web wizard with a one-time console token |
| [#185](https://github.com/hobnix/server/issues/185) | Backlog | P0 | Unattended answers file format (open point in PLAN-modular-core) |
| [#217](https://github.com/hobnix/server/issues/217) | Backlog | P0 | Epic: Capabilities repository and channels |
| [#219](https://github.com/hobnix/server/issues/219) | Backlog | P0 | ADR: capability as a package kind; what stays in core (storage, samba, incus, web, notify, hs) |
| [#221](https://github.com/hobnix/server/issues/221) | Backlog | P0 | Vendor `module.nix` into the checkout at install (pure evaluation), instead of --impure |
| [#224](https://github.com/hobnix/server/issues/224) | Backlog | P0 | schema-gen and registry rows regenerated on the machine after install |
| [#225](https://github.com/hobnix/server/issues/225) | Backlog | P0 | Create hobnix/capabilities, move the first optional capability as a pilot |
| [#228](https://github.com/hobnix/server/issues/228) | Backlog | P0 | CI: matrix fetches capabilities from the other repo |
| [#229](https://github.com/hobnix/server/issues/229) | Backlog | P0 | Wizard step: pick capabilities, download, rebuild |
| [#233](https://github.com/hobnix/server/issues/233) | Backlog | P0 | Release process: develop -> release/* -> main + tag; branch protection on main and develop |
| [#235](https://github.com/hobnix/server/issues/235) | Backlog | P0 | Capability uninstall and version compatibility |
| [#191](https://github.com/hobnix/server/issues/191) | Backlog | P1 | Epic: Component Library |
| [#193](https://github.com/hobnix/server/issues/193) | Backlog | P1 | Epic: Storybook and Design System |
| [#254](https://github.com/hobnix/server/issues/254) | Backlog | - | Disaster-recovery bootstrap in the installer |

### 0.3 — Application Platform

13 issues, 0 done.

| Issue | Status | Priority | Title |
| --- | --- | --- | --- |
| [#187](https://github.com/hobnix/server/issues/187) | Backlog | P0 | Epic: Application Lifecycle |
| [#195](https://github.com/hobnix/server/issues/195) | Backlog | P1 | Epic: Declarative WebUI |
| [#197](https://github.com/hobnix/server/issues/197) | Backlog | P1 | Epic: Extension Protocol and SDK |
| [#237](https://github.com/hobnix/server/issues/237) | Backlog | P1 | Define the command-extension protocol (versioned JSON over stdin/stdout, timeouts, cancellation) |
| [#238](https://github.com/hobnix/server/issues/238) | Backlog | P1 | Define the service-extension lifecycle (long-running collectors and event consumers) |
| [#239](https://github.com/hobnix/server/issues/239) | Backlog | P1 | Enforce extension permissions instead of only declaring them |
| [#240](https://github.com/hobnix/server/issues/240) | Backlog | P1 | Rust extension SDK |
| [#257](https://github.com/hobnix/server/issues/257) | Backlog | - | ADR: roles and API tokens (viewer, app manager, admin) |
| [#263](https://github.com/hobnix/server/issues/263) | Backlog | - | Docker guided wizard that ends in the compose and .env editor |
| [#264](https://github.com/hobnix/server/issues/264) | Backlog | - | Import a Docker Compose file as an app |
| [#265](https://github.com/hobnix/server/issues/265) | Backlog | - | hs create package <name> --template=recipe\|extension\|capability |
| [#266](https://github.com/hobnix/server/issues/266) | Backlog | - | Research: WebAssembly runtime for extension scripts |
| [#267](https://github.com/hobnix/server/issues/267) | Backlog | - | Research: isolating third-party web components in package UI |

### 0.4 — Virtualization

6 issues, 0 done.

| Issue | Status | Priority | Title |
| --- | --- | --- | --- |
| [#199](https://github.com/hobnix/server/issues/199) | Backlog | P1 | Epic: Incus and VM Management |
| [#258](https://github.com/hobnix/server/issues/258) | Backlog | - | VM creation wizard: name, resources and disk placement |
| [#259](https://github.com/hobnix/server/issues/259) | Backlog | - | ISO library: pick a local ISO or fetch from a URL with checksum verification |
| [#260](https://github.com/hobnix/server/issues/260) | Backlog | - | VM hardware step: GPU and PCIe passthrough, network bridge |
| [#261](https://github.com/hobnix/server/issues/261) | Backlog | - | Graphical VM console (VNC or SPICE) next to the serial console |
| [#262](https://github.com/hobnix/server/issues/262) | Backlog | - | Hobnix-in-Hobnix test harness: nested instances from the ISO |

### 0.5 — Storage and NAS

2 issues, 0 done.

| Issue | Status | Priority | Title |
| --- | --- | --- | --- |
| [#189](https://github.com/hobnix/server/issues/189) | Backlog | P0 | Epic: Storage Management |
| [#255](https://github.com/hobnix/server/issues/255) | Backlog | - | Storage incident workflow: degraded pool or failing disk, guided step by step |

### 0.6 — Networking and Multi-node

3 issues, 0 done.

| Issue | Status | Priority | Title |
| --- | --- | --- | --- |
| [#201](https://github.com/hobnix/server/issues/201) | Backlog | P1 | Epic: Networking Management |
| [#203](https://github.com/hobnix/server/issues/203) | Backlog | P2 | Epic: Multi-node Management |
| [#256](https://github.com/hobnix/server/issues/256) | Backlog | - | ADR: cluster state and split-brain behaviour for multi-node |

### 1.0 — Stable Ecosystem

3 issues, 0 done.

| Issue | Status | Priority | Title |
| --- | --- | --- | --- |
| [#205](https://github.com/hobnix/server/issues/205) | Backlog | P2 | Epic: Marketplace and Ecosystem |
| [#268](https://github.com/hobnix/server/issues/268) | Backlog | - | WebUI package builder: create, edit and package from the browser |
| [#269](https://github.com/hobnix/server/issues/269) | Backlog | - | Import Unraid templates and Proxmox vzdump archives |

### No milestone

11 issues, 2 done.

| Issue | Status | Priority | Title |
| --- | --- | --- | --- |
| [#207](https://github.com/hobnix/server/issues/207) | Backlog | P1 | Epic: Documentation and Community |
| [#209](https://github.com/hobnix/server/issues/209) | Backlog | P1 | Issue templates: feature, bug, architecture proposal, spike, documentation |
| [#211](https://github.com/hobnix/server/issues/211) | Backlog | P1 | Code of conduct, Discussions, good first issues |
| [#213](https://github.com/hobnix/server/issues/213) | Backlog | P1 | ADR folder and first ADRs (Rust strategy, API in front of CLI, develop/main, capability packages) |
| [#216](https://github.com/hobnix/server/issues/216) | Backlog | P1 | Roadmap page in the docs |
| [#270](https://github.com/hobnix/server/issues/270) | Backlog | - | Contributions: require DCO sign-off (or decide on a CLA) |
| [#271](https://github.com/hobnix/server/issues/271) | Backlog | - | Funding: GitHub Sponsors and OpenCollective |
| [#313](https://github.com/hobnix/server/issues/313) | Backlog | - | Packages declare the events they provide |
| [#317](https://github.com/hobnix/server/issues/317) | Backlog | - | Docs: disk and pool failure runbook per case |

Done: [#315](https://github.com/hobnix/server/issues/315), [#316](https://github.com/hobnix/server/issues/316)

<!-- END board -->

## Open work from TODO.md

`TODO.md` is the working list of the maintainers: bigger pieces than one issue, with the history of what was merged and what was run on a
real server. An item can appear here and on the board.

<!-- BEGIN todo (python3 scripts/roadmap-gen.py write) -->

| Section | Done | Items |
| --- | --- | --- |
| A. Make what exists trustworthy | 1 | 7 |
| B. Features that fit the design | 0 | 9 |
| C. Recipes (when one is needed, we do it) | 0 | 0 |
| D. Nodes: every server is a node of one repo (design agreed 2026-10-27) | 0 | 4 |
| E. Notifications as a capability (decided 2026-10-27) | 0 | 3 |
| F. Web interface: one source of truth per object (decided 2026-10-27) | 2 | 5 |
| G. File manager (description 2026-10-28) | 2 | 5 |

Not done yet:

| Item | State | What |
| --- | --- | --- |
| A1 | in progress | CI on pull requests only (action minutes ran out when every push ran) |
| A2 | needs a decision | Work through the guides on the real server (steps marked "Not tested on hardware yet.") in blocks (first hs... |
| A3 | needs a decision | Run the recipes never run on the server, in this order |
| A5 | open | Rebuild rehearsal in a VM from only the backup disk and the passphrase (turns docs/backup-and-recovery.md f... |
| A6 | in progress | Monthly restore-drill report pushed to ntfy (the drills exist |
| A7 | open | Housekeeping |
| B8 | in progress | hs update with auto-rollback |
| B9 | in progress | One interface for app-database dumps (Postgres for Immich / Synapse / Authentik, SQLite for the arr apps) s... |
| B10 | in progress | VM coverage in hs backup ct (Incus VMs, not only the domain controller) |
| B11 | open | Later: a cloud (or other) backup target next to the local disk. Not needed now. (The backup to the other se... |
| B12 | in progress | Capacity and trend alerts (pool fill forecast, SSD wear, cache-mover backlog, backup growth, from state.db... |
| B13 | in progress | Notification routing |
| B14 | in progress | Web: the proxyserver pages need the keys the status document still lacks (mail, watcher, game_ports, certif... |
| B15 | in progress | arr: Recycling Bin in Radarr and Sonarr (set by hand now), Remove Completed on the SABnzbd client, the Jell... |
| B16 | open | Investigate the sudo stall of 3 to 5 s (winbind group lookup suspected; sampler log /tmp/slowsudo.log) |
| D1 | in progress | Node registry (hs node add\|list\|remove, local node first), web tree with nodes at the top, the proxyserver... |
| D2 | open | The cousin's server as a read-only node (reuses hs sys deck, the one-read status document) |
| D3 | in progress | A minimal base profile (users, SSH, hs, Tailscale, health, notify) and the edge capabilities (mail, game po... |
| D4 | open | Cut over side by side (the VPS carries the MX and the public ports) |
| E1 | in progress | Plan and step 1 (channel store, provider interface, ntfy as provider #1, hs notify channel ...) |
| E2 | in progress | The Notifications web page |
| E3 | in progress | A second provider (Matrix or email), then the rest as needed |
| F3 | in progress | ; not run in a browser against the real server) Redesign, then retire the duplicated routes |
| F4 | in progress | Game streaming and Posters are capabilities games and posters, off by default (nothing in the tree on a fre... |
| F5 | in progress | Extensions: a package manifest with a [web] section (page as data: reads, actions, a fixed layout; no JavaS... |
| G1 | open | Design from the owner, answers to the open questions at the end of the plan |
| G4 | open | Safety switch: fileManagerWrite is off by default. Run the file manager checks in a VM (copy, move, delete,... |
| G5 | open | Not built: fm du and Calculate size, pause, trash, hs fm ... user commands, the editable path field, owner... |

<!-- END todo -->

## How to take part

- Pick an issue with the label `good first issue` ([CONTRIBUTING.md](https://github.com/hobnix/server/blob/develop/CONTRIBUTING.md)), or ask in a Discussion.
- A change to storage, the network or the firewall is discussed in an issue before it is built.
- Decisions that are hard to undo are written down as records: [Architecture decisions](adr/README.md).
