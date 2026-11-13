# Roadmap

Where Hobnix is going and what is open now. For people who want to help or to know what comes next.

**The source is the GitHub project board** ([Hobnix Roadmap](https://github.com/orgs/hobnix/projects/1)), not this page. This page is a
snapshot of it, made with `python3 scripts/roadmap-gen.py write` (it runs `gh project item-list`), and can be behind. Nothing between the markers is edited by hand. Status and priority of an issue are changed on the board.

## Positioning

- **For whom:** the home user of Unraid or a hand-built NAS who wants apps, shares and backups on a system that can be read and rebuilt.
- **Three things Hobnix does better:** rollback of the whole system; a server rebuilt from a backup disk and a passphrase (both not run on a
  real server yet: #161, #163); a server that is a readable git repository with a plan before every change.
- **Out of scope before 1.0:** clusters with shared state, high availability, live migration. ADR 0013 stays a record of why, not a plan.
  Epics outside this (multi-node management, networking management) sit in the milestone "Later — after 1.0".

## Milestones

The milestones are releases in order of work, not dates. An issue without a milestone is not planned yet.

<!-- BEGIN board (python3 scripts/roadmap-gen.py write) -->

### Later â€” after 1.0

2 issues, 0 done.

| Issue | Status | Priority | Title |
| --- | --- | --- | --- |
| [#201](https://github.com/hobnix/server/issues/201) | Backlog | P1 | Epic: Networking Management |
| [#203](https://github.com/hobnix/server/issues/203) | Backlog | P2 | Epic: Multi-node Management |

### 0.1 â€” Trustworthy Foundation

68 issues, 39 done.

| Issue | Status | Priority | Title |
| --- | --- | --- | --- |
| [#128](https://github.com/hobnix/server/issues/128) | In Progress | P0 | Epic: Unified Job System |
| [#139](https://github.com/hobnix/server/issues/139) | In Progress | P0 | Epic: Event Architecture |
| [#163](https://github.com/hobnix/server/issues/163) | In Progress | P0 | Rebuild rehearsal in a VM from backup disk and passphrase (TODO A5) |
| [#171](https://github.com/hobnix/server/issues/171) | In Review | P0 | Disk and pool failure handling review |
| [#385](https://github.com/hobnix/server/issues/385) | In Review | - | Jobs page: show job records (history, step, progress, error) |
| [#386](https://github.com/hobnix/server/issues/386) | In Review | - | File manager jobs: progress on the job record instead of own state files |
| [#387](https://github.com/hobnix/server/issues/387) | In Review | - | Job record for orchestrated recipe runs: waiting state, parent/kind fields, job.waiting events (ADR 0018) |
| [#388](https://github.com/hobnix/server/issues/388) | In Review | - | Long operations that are not jobs: update, rebuild, vault move, pkg fetch |
| [#389](https://github.com/hobnix/server/issues/389) | In Review | - | Report step and progress from the long jobs |
| [#390](https://github.com/hobnix/server/issues/390) | In Review | - | Domain events from backup, update/rebuild, health, UPS and power |
| [#391](https://github.com/hobnix/server/issues/391) | In Review | - | Web: an Events view of the event log |
| [#392](https://github.com/hobnix/server/issues/392) | In Review | - | Incus lifecycle watcher (incus monitor) as an event source |
| [#393](https://github.com/hobnix/server/issues/393) | In Review | - | Restore the settings onto a clean install without the manual restic steps |
| [#397](https://github.com/hobnix/server/issues/397) | In Review | - | CI: the ISO and release job must wait for the test jobs |
| [#398](https://github.com/hobnix/server/issues/398) | In Review | - | CI: build the release ISO from the pinned nixpkgs revision |
| [#399](https://github.com/hobnix/server/issues/399) | In Review | - | CI: release asset checksum with a bare file name, release notes from a file |
| [#520](https://github.com/hobnix/server/issues/520) | In Review | - | Release the core from GitHub in 0.1 (bring the release workflow of #515 to develop, prove it with a beta tag) |
| [#521](https://github.com/hobnix/server/issues/521) | In Review | - | Trust the CI release keys before v0.1.0 (release-ci in all allowed_signers files, environments and secrets) |
| [#522](https://github.com/hobnix/server/issues/522) | Ready | - | Release the package repositories from GitHub (shared workflow for recipes, extensions, capabilities) |
| [#523](https://github.com/hobnix/server/issues/523) | Ready | - | Package versions are raised by the release, not by hand (PR label, prepare-release workflow, CI check) |
| [#147](https://github.com/hobnix/server/issues/147) | Backlog | P0 | Epic: Reactive Live-state |
| [#159](https://github.com/hobnix/server/issues/159) | Backlog | P0 | Epic: Reliability and Recovery |
| [#161](https://github.com/hobnix/server/issues/161) | Backlog | P0 | Run the auto-rollback on the real server and record the result |
| [#165](https://github.com/hobnix/server/issues/165) | Backlog | P0 | Run the first monthly restore-drill report |
| [#169](https://github.com/hobnix/server/issues/169) | Backlog | P0 | Config backup and restore as a documented, tested flow |
| [#415](https://github.com/hobnix/server/issues/415) | Backlog | - | Run the root and VM tests and record the result |
| [#416](https://github.com/hobnix/server/issues/416) | Backlog | - | Work through every guide on a real server and record the date |
| [#417](https://github.com/hobnix/server/issues/417) | Backlog | - | Run the backup additions on a server: app database dumps and VM export |
| [#430](https://github.com/hobnix/server/issues/430) | Backlog | - | Test-lab: run the install, update and restore checks in an Incus VM on the server |

Done: [#121](https://github.com/hobnix/server/issues/121), [#122](https://github.com/hobnix/server/issues/122), [#123](https://github.com/hobnix/server/issues/123), [#124](https://github.com/hobnix/server/issues/124), [#125](https://github.com/hobnix/server/issues/125), [#126](https://github.com/hobnix/server/issues/126), [#127](https://github.com/hobnix/server/issues/127), [#129](https://github.com/hobnix/server/issues/129), [#131](https://github.com/hobnix/server/issues/131), [#133](https://github.com/hobnix/server/issues/133), [#135](https://github.com/hobnix/server/issues/135), [#137](https://github.com/hobnix/server/issues/137), [#141](https://github.com/hobnix/server/issues/141), [#143](https://github.com/hobnix/server/issues/143), [#145](https://github.com/hobnix/server/issues/145), [#149](https://github.com/hobnix/server/issues/149), [#151](https://github.com/hobnix/server/issues/151), [#153](https://github.com/hobnix/server/issues/153), [#155](https://github.com/hobnix/server/issues/155), [#157](https://github.com/hobnix/server/issues/157), [#167](https://github.com/hobnix/server/issues/167), [#252](https://github.com/hobnix/server/issues/252), [#253](https://github.com/hobnix/server/issues/253), [#286](https://github.com/hobnix/server/issues/286), [#288](https://github.com/hobnix/server/issues/288), [#289](https://github.com/hobnix/server/issues/289), [#290](https://github.com/hobnix/server/issues/290), [#291](https://github.com/hobnix/server/issues/291), [#292](https://github.com/hobnix/server/issues/292), [#293](https://github.com/hobnix/server/issues/293), [#294](https://github.com/hobnix/server/issues/294), [#295](https://github.com/hobnix/server/issues/295), [#296](https://github.com/hobnix/server/issues/296), [#297](https://github.com/hobnix/server/issues/297), [#298](https://github.com/hobnix/server/issues/298), [#322](https://github.com/hobnix/server/issues/322), [#323](https://github.com/hobnix/server/issues/323), [#324](https://github.com/hobnix/server/issues/324), [#396](https://github.com/hobnix/server/issues/396)

### 0.2 â€” Safe Updates

14 issues, 3 done.

| Issue | Status | Priority | Title |
| --- | --- | --- | --- |
| [#231](https://github.com/hobnix/server/issues/231) | In Review | P0 | Update channels: stable (tags), beta (release candidates), edge (develop); `hs update` follows the channel; web setting |
| [#233](https://github.com/hobnix/server/issues/233) | In Review | P0 | Release process: develop -> release/* -> main + tag; branch protection on main and develop |
| [#432](https://github.com/hobnix/server/issues/432) | In Review | - | Test-lab: rollback, restore, pool and web page stages |
| [#433](https://github.com/hobnix/server/issues/433) | In Review | - | Security review of the web service: threat model, sessions, request forgery, rate limits |
| [#435](https://github.com/hobnix/server/issues/435) | In Review | - | Upgrade test: install the previous release, update to the new one |
| [#436](https://github.com/hobnix/server/issues/436) | In Review | - | Policy for the nixpkgs pin and NixOS release changes |
| [#437](https://github.com/hobnix/server/issues/437) | In Review | - | Decide the ADRs that already have merged code |
| [#438](https://github.com/hobnix/server/issues/438) | In Review | - | Decide how far the Rust migration goes per release |
| [#458](https://github.com/hobnix/server/issues/458) | In Review | - | Write down the positioning: who Hobnix is for, and what is out of scope before 1.0 |
| [#464](https://github.com/hobnix/server/issues/464) | In Review | - | Decide a release rhythm (a release every few weeks with what is verified) |
| [#439](https://github.com/hobnix/server/issues/439) | Blocked | - | CI: test develop after each merge, faster quick tests, required checks |

Done: [#185](https://github.com/hobnix/server/issues/185), [#219](https://github.com/hobnix/server/issues/219), [#254](https://github.com/hobnix/server/issues/254)

### 0.3 â€” Foundations

9 issues, 1 done.

| Issue | Status | Priority | Title |
| --- | --- | --- | --- |
| [#420](https://github.com/hobnix/server/issues/420) | Backlog | - | Notifications: run channels, routing and the web page on a server; choose the next providers |
| [#423](https://github.com/hobnix/server/issues/423) | Backlog | - | Web: remove the old routes that still redirect |
| [#431](https://github.com/hobnix/server/issues/431) | Backlog | - | Retire TODO.md: /work, the session hook and the roadmap page read the board |
| [#443](https://github.com/hobnix/server/issues/443) | Backlog | - | Web: ratchet test, raw form elements and own styles may only go down |
| [#444](https://github.com/hobnix/server/issues/444) | Backlog | - | Web: form field components (Field, text input, select, textarea, checkbox) |
| [#481](https://github.com/hobnix/server/issues/481) | Backlog | - | Live state on by default, one mode, one store (decide: Redis or the state database) |
| [#482](https://github.com/hobnix/server/issues/482) | Backlog | - | Every read has a topic or a written reason to poll (a check that only allows fewer timers) |
| [#491](https://github.com/hobnix/server/issues/491) | Backlog | - | The `hs` commands print English only: remove the German catalog |

Done: [#442](https://github.com/hobnix/server/issues/442)

### 0.4 â€” Install and Onboarding

7 issues, 0 done.

| Issue | Status | Priority | Title |
| --- | --- | --- | --- |
| [#173](https://github.com/hobnix/server/issues/173) | Backlog | P0 | Epic: Installation and Onboarding |
| [#175](https://github.com/hobnix/server/issues/175) | Backlog | P0 | Boot the ISO on real hardware or a VM, record what breaks |
| [#179](https://github.com/hobnix/server/issues/179) | Backlog | P0 | Network setup and validation step |
| [#181](https://github.com/hobnix/server/issues/181) | Backlog | P0 | Storage discovery and disk adoption in the wizard |
| [#183](https://github.com/hobnix/server/issues/183) | Backlog | P0 | First-run web wizard with a one-time console token |
| [#459](https://github.com/hobnix/server/issues/459) | Backlog | - | Epic: Works on a machine that is not the author's |
| [#489](https://github.com/hobnix/server/issues/489) | Backlog | - | A public website: landing page and the documentation outside the repository |

### 0.5 â€” Capabilities Repository

8 issues, 0 done.

| Issue | Status | Priority | Title |
| --- | --- | --- | --- |
| [#177](https://github.com/hobnix/server/issues/177) | Backlog | P0 | Capability selection step (depends on E18) |
| [#217](https://github.com/hobnix/server/issues/217) | Backlog | P0 | Epic: Capabilities repository and channels |
| [#221](https://github.com/hobnix/server/issues/221) | Backlog | P0 | Vendor `module.nix` into the checkout at install (pure evaluation), instead of --impure |
| [#224](https://github.com/hobnix/server/issues/224) | Backlog | P0 | schema-gen and registry rows regenerated on the machine after install |
| [#225](https://github.com/hobnix/server/issues/225) | Backlog | P0 | Create hobnix/capabilities, move the first optional capability as a pilot |
| [#228](https://github.com/hobnix/server/issues/228) | Backlog | P0 | CI: matrix fetches capabilities from the other repo |
| [#229](https://github.com/hobnix/server/issues/229) | Backlog | P0 | Wizard step: pick capabilities, download, rebuild |
| [#235](https://github.com/hobnix/server/issues/235) | Backlog | P0 | Capability uninstall and version compatibility |

### 0.6 â€” App Lifecycle

18 issues, 9 done.

| Issue | Status | Priority | Title |
| --- | --- | --- | --- |
| [#187](https://github.com/hobnix/server/issues/187) | Backlog | P0 | Epic: Application Lifecycle |
| [#269](https://github.com/hobnix/server/issues/269) | Backlog | - | Import Unraid templates and Proxmox vzdump archives |
| [#465](https://github.com/hobnix/server/issues/465) | Backlog | - | One Install: fetch, what it needs, the questions and the run as one guided job |
| [#466](https://github.com/hobnix/server/issues/466) | Backlog | - | A failed install: name the step, retry from it, remove what is half there |
| [#467](https://github.com/hobnix/server/issues/467) | Backlog | - | One lifecycle for every package kind (available, installed, on, running) and one verb in the interface |
| [#468](https://github.com/hobnix/server/issues/468) | Backlog | - | App contract: every recipe declares health, backup, routes, update and what removal keeps |
| [#469](https://github.com/hobnix/server/issues/469) | Backlog | - | Manifest fields for a store: icon, category, description, pictures, upstream version, what it uses |
| [#470](https://github.com/hobnix/server/issues/470) | Backlog | - | Package version and app version, and an update policy per app |
| [#471](https://github.com/hobnix/server/issues/471) | Backlog | - | Decide: several instances of one app |

Done: [#237](https://github.com/hobnix/server/issues/237), [#238](https://github.com/hobnix/server/issues/238), [#240](https://github.com/hobnix/server/issues/240), [#257](https://github.com/hobnix/server/issues/257), [#263](https://github.com/hobnix/server/issues/263), [#264](https://github.com/hobnix/server/issues/264), [#265](https://github.com/hobnix/server/issues/265), [#266](https://github.com/hobnix/server/issues/266), [#267](https://github.com/hobnix/server/issues/267)

### 0.7 â€” Storage and NAS

9 issues, 1 done.

| Issue | Status | Priority | Title |
| --- | --- | --- | --- |
| [#189](https://github.com/hobnix/server/issues/189) | Backlog | P0 | Epic: Storage Management |
| [#418](https://github.com/hobnix/server/issues/418) | Backlog | - | Backup target outside the house (cloud or another server) |
| [#419](https://github.com/hobnix/server/issues/419) | Backlog | - | Capacity alerts: further automatic mitigation levels |
| [#425](https://github.com/hobnix/server/issues/425) | Backlog | - | File manager: run the write checks in a VM, then switch `fileManagerWrite` on |
| [#426](https://github.com/hobnix/server/issues/426) | Backlog | - | File manager: size calculation, pause, trash, `hs fm` commands, editable path |
| [#460](https://github.com/hobnix/server/issues/460) | Backlog | - | Take over the disks of an Unraid server in place |
| [#463](https://github.com/hobnix/server/issues/463) | Backlog | - | Disk spin-down and power use |
| [#527](https://github.com/hobnix/server/issues/527) | Backlog | - | Back up only chosen parts of a container (include and exclude paths, like a .gitignore) |

Done: [#255](https://github.com/hobnix/server/issues/255)

### 0.8 â€” Extensions and Access

5 issues, 0 done.

| Issue | Status | Priority | Title |
| --- | --- | --- | --- |
| [#197](https://github.com/hobnix/server/issues/197) | Backlog | P1 | Epic: Extension Protocol and SDK |
| [#239](https://github.com/hobnix/server/issues/239) | Backlog | P1 | Enforce extension permissions instead of only declaring them |
| [#313](https://github.com/hobnix/server/issues/313) | Backlog | - | Packages declare the events they provide |
| [#434](https://github.com/hobnix/server/issues/434) | Backlog | - | Roles and API tokens: build what ADR 0012 decides |
| [#462](https://github.com/hobnix/server/issues/462) | Backlog | - | Two-factor login and single sign-on for the web interface |

### 0.9 â€” Web Components

9 issues, 0 done.

| Issue | Status | Priority | Title |
| --- | --- | --- | --- |
| [#191](https://github.com/hobnix/server/issues/191) | Backlog | P1 | Epic: Component Library |
| [#193](https://github.com/hobnix/server/issues/193) | Backlog | P1 | Epic: Storybook and Design System |
| [#445](https://github.com/hobnix/server/issues/445) | Backlog | - | Web: layout components (card or section, row and stack, one muted text style) |
| [#446](https://github.com/hobnix/server/issues/446) | Backlog | - | Web: small pieces (icon, icon button, chip or tag) |
| [#447](https://github.com/hobnix/server/issues/447) | Backlog | - | Web: overlays in ui (dialog, menu, toast) |
| [#448](https://github.com/hobnix/server/issues/448) | Backlog | - | Web: components the roadmap needs (step and progress list, timeline with filters, stepper) |
| [#449](https://github.com/hobnix/server/issues/449) | Backlog | - | Web: component gallery page in the developer section |
| [#450](https://github.com/hobnix/server/issues/450) | Backlog | - | Web: move the pages to the shared components, group by group |
| [#461](https://github.com/hobnix/server/issues/461) | Backlog | - | Demo mode: the web interface with made-up data, no server needed |

### 0.10 â€” Live Interface

5 issues, 0 done.

| Issue | Status | Priority | Title |
| --- | --- | --- | --- |
| [#480](https://github.com/hobnix/server/issues/480) | Backlog | - | Epic: The interface follows events, it does not poll |
| [#483](https://github.com/hobnix/server/issues/483) | Backlog | - | An action shows at once: rows take their pending state from the job event |
| [#484](https://github.com/hobnix/server/issues/484) | Backlog | - | More event sources: disks plugged and pulled (udev), units that start, stop or fail (systemd) |
| [#485](https://github.com/hobnix/server/issues/485) | Backlog | - | End-to-end test: an action updates the open page without a reload, within seconds |
| [#486](https://github.com/hobnix/server/issues/486) | Backlog | - | Measure the delay from "something changed" to "the browser shows it" |

### 0.11 â€” Navigation and Pages

10 issues, 0 done.

| Issue | Status | Priority | Title |
| --- | --- | --- | --- |
| [#427](https://github.com/hobnix/server/issues/427) | Backlog | - | Mobile-friendly web interface and a read-only status page |
| [#451](https://github.com/hobnix/server/issues/451) | Backlog | - | Epic: Navigation and page structure |
| [#452](https://github.com/hobnix/server/issues/452) | Backlog | - | Web: regroup the tree (fewer groups, only places) |
| [#453](https://github.com/hobnix/server/issues/453) | Backlog | - | Web: a page per object (disk, pool, share, instance, user) instead of a drawer with tabs |
| [#454](https://github.com/hobnix/server/issues/454) | Backlog | - | Web: quick look as an overlay, so selecting a row never moves the list |
| [#455](https://github.com/hobnix/server/issues/455) | Backlog | - | Web: the selected row and tab live in the address |
| [#456](https://github.com/hobnix/server/issues/456) | Backlog | - | Web: pools come from data, not from fixed names |
| [#457](https://github.com/hobnix/server/issues/457) | Backlog | - | Web: group pages that show the state of the group, one or two main actions plus a More menu |
| [#487](https://github.com/hobnix/server/issues/487) | Backlog | - | Accessibility: the whole interface by keyboard and with a screen reader |
| [#488](https://github.com/hobnix/server/issues/488) | Backlog | - | Error messages: what happened, why, and the next step, with a stable code |

### 0.12 â€” Package Pages

4 issues, 0 done.

| Issue | Status | Priority | Title |
| --- | --- | --- | --- |
| [#195](https://github.com/hobnix/server/issues/195) | Backlog | P1 | Epic: Declarative WebUI |
| [#424](https://github.com/hobnix/server/issues/424) | Backlog | - | Recipes: status panel and allowlisted actions from the manifest `[web]` section |
| [#472](https://github.com/hobnix/server/issues/472) | Backlog | - | Slots: the fixed places where a package may add to the interface |
| [#473](https://github.com/hobnix/server/issues/473) | Backlog | - | The block list is the component library: a registry with schemas, and the blocks that are missing |

### 0.13 â€” Marketplace

6 issues, 0 done.

| Issue | Status | Priority | Title |
| --- | --- | --- | --- |
| [#205](https://github.com/hobnix/server/issues/205) | Backlog | P2 | Epic: Marketplace and Ecosystem |
| [#474](https://github.com/hobnix/server/issues/474) | Backlog | - | Marketplace as a store: cards, categories, Installed and Updates, a page per package |
| [#475](https://github.com/hobnix/server/issues/475) | Backlog | - | The package index refreshes by itself |
| [#476](https://github.com/hobnix/server/issues/476) | Backlog | - | One place for updates: the system, apps and packages |
| [#477](https://github.com/hobnix/server/issues/477) | Backlog | - | Trust shown plainly: official or community, and a "tested on a real server" date |
| [#478](https://github.com/hobnix/server/issues/478) | Backlog | - | A page for every installed app, built from its manifest |

### 0.14 â€” Translations

4 issues, 0 done.

| Issue | Status | Priority | Title |
| --- | --- | --- | --- |
| [#490](https://github.com/hobnix/server/issues/490) | Backlog | - | Epic: Translations (English is the base, the web interface is translated, German first) |
| [#492](https://github.com/hobnix/server/issues/492) | Backlog | - | Web: one catalog file per language, English as the base, a check that nothing is missing |
| [#493](https://github.com/hobnix/server/issues/493) | Backlog | - | Web: translate the page bodies to German, completely |
| [#494](https://github.com/hobnix/server/issues/494) | Backlog | - | Packages: titles and web texts per language in the manifest, no shell catalogs |

### 0.15 â€” Virtualization

6 issues, 2 done.

| Issue | Status | Priority | Title |
| --- | --- | --- | --- |
| [#199](https://github.com/hobnix/server/issues/199) | Backlog | P1 | Epic: Incus and VM Management |
| [#260](https://github.com/hobnix/server/issues/260) | Backlog | - | VM hardware step: GPU and PCIe passthrough, network bridge |
| [#261](https://github.com/hobnix/server/issues/261) | Backlog | - | Graphical VM console (VNC or SPICE) next to the serial console |
| [#262](https://github.com/hobnix/server/issues/262) | Backlog | - | Hobnix-in-Hobnix test harness: nested instances from the ISO |

Done: [#258](https://github.com/hobnix/server/issues/258), [#259](https://github.com/hobnix/server/issues/259)

### 0.16 â€” Networking and Multi-node

3 issues, 1 done.

| Issue | Status | Priority | Title |
| --- | --- | --- | --- |
| [#421](https://github.com/hobnix/server/issues/421) | Backlog | - | Node: a remote server owned by someone else as a read-only node |
| [#422](https://github.com/hobnix/server/issues/422) | Backlog | - | Edge role: rehearse on a VM or a spare VPS |

Done: [#256](https://github.com/hobnix/server/issues/256)

### 1.0 â€” Stable Ecosystem

3 issues, 0 done.

| Issue | Status | Priority | Title |
| --- | --- | --- | --- |
| [#268](https://github.com/hobnix/server/issues/268) | Backlog | - | WebUI package builder: create, edit and package from the browser |
| [#479](https://github.com/hobnix/server/issues/479) | Backlog | - | Bundles: install several apps that belong together in one go |
| [#495](https://github.com/hobnix/server/issues/495) | Backlog | - | Epic: Blueprints: pick what the server is for and get it set up in one run |

### No milestone

10 issues, 8 done.

| Issue | Status | Priority | Title |
| --- | --- | --- | --- |
| [#207](https://github.com/hobnix/server/issues/207) | Backlog | P1 | Epic: Documentation and Community |
| [#271](https://github.com/hobnix/server/issues/271) | Backlog | - | Funding: GitHub Sponsors and OpenCollective |

Done: [#209](https://github.com/hobnix/server/issues/209), [#211](https://github.com/hobnix/server/issues/211), [#213](https://github.com/hobnix/server/issues/213), [#216](https://github.com/hobnix/server/issues/216), [#270](https://github.com/hobnix/server/issues/270), [#315](https://github.com/hobnix/server/issues/315), [#316](https://github.com/hobnix/server/issues/316), [#317](https://github.com/hobnix/server/issues/317)

<!-- END board -->

## How to take part

- Pick an issue with the label `good first issue` ([CONTRIBUTING.md](https://github.com/hobnix/server/blob/develop/CONTRIBUTING.md)), or ask in a Discussion.
- A change to storage, the network or the firewall is discussed in an issue before it is built.
- Decisions that are hard to undo are written down as records: [Architecture decisions](adr/README.md).
