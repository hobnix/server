# Documentation

The same tree is the page Docs of the web interface (`hs docs build`); it comes from [`categories.tsv`](categories.tsv). A new file must be
listed there and below, or `tests/docs.sh` complains. Guides follow [GUIDE-TEMPLATE](GUIDE-TEMPLATE.md).

## Guides

| Guide | What it covers |
| --- | --- |
| [Install](install.md) | From an empty machine to a running server, first login, first-run checklist |
| [Containers and apps](containers-and-apps.md) | Containers and VMs, fixed addresses, snapshots, recipes and packages |
| [Users and shares](users-and-shares.md) | The domain, users and groups, shares and their permissions |
| [Storage and disks](storage-and-disks.md) | ZFS and SnapRAID pools, adding and replacing disks, disk health, moving from Unraid |
| [Disk failures](disk-failures.md) | What to check and do, case by case, when a disk or a pool fails |
| [Encryption and vault](encryption-and-vault.md) | One passphrase, the vault, encrypted disks, unlocking |
| [Backup and recovery](backup-and-recovery.md) | Backups, restoring, snapshots, rebuilding a server |
| [Web interface](web-interface.md) | Turning it on, signing in, pages, terminal, appearance |
| [Operations](operations.md) | Health alerts, updates, UPS, remote access, the gateway |

The command reference is generated from the command list (`hs help`, or the page *All commands*).

## Apps and extensions

Every package brings its own guide as `guide.md` in its folder (`packages/<name>/`, `capabilities/<name>/`, or the package's repository). The
Docs page shows them under *Apps* and *Extensions*.

## Contributing

| Document | What it is |
| --- | --- |
| [dev-environment](dev-environment.md) | Running tests, the WSL and VM tiers, the agent workflow |
| [GUIDE-TEMPLATE](GUIDE-TEMPLATE.md) | How a guide is written: shape, rules, the glossary |
| [PLAN-modular-core](PLAN-modular-core.md) | The option schema, capabilities and roles |
| [PLAN-extensions](PLAN-extensions.md) | Extension packages: commands and web pages |
| [PLAN-packages](PLAN-packages.md) | Recipes and extensions as packages, repositories, signed releases |
| [PLAN-capabilities-on-machine](PLAN-capabilities-on-machine.md) | Derived files of an installed capability package |
| [PLAN-recipe-orchestrator](PLAN-recipe-orchestrator.md) | Interactive recipe runs: the orchestrator and its API contract |
| [PLAN-first-run-wizard](PLAN-first-run-wizard.md) | From the ISO to the first dashboard: network, disks, one-time code |
| [PLAN-web-backend](PLAN-web-backend.md) | The web interface backend |
| [THREAT-MODEL-web](THREAT-MODEL-web.md) | Who can reach the web service, what each sign-in can start, protections and open findings |
| [PLAN-disk-health](PLAN-disk-health.md) | Daily SMART baseline, and a disk and pool checklist |
| [PLAN-hardware-runbook](PLAN-hardware-runbook.md) | Runbook for four checks only the owner can run: auto-rollback, rebuild rehearsal, drill report, installer ISO (none run yet) |
| [PLAN-events](PLAN-events.md) | Event sources, consumers and delivery (audit #141 for the event architecture) |
| [events](events.md) | The event catalogue: kind names, levels, payload rules |
| [notify-rules](notify-rules.md) | Which events become push messages: the rules table, mute a kind, Matrix cards |
| [PLAN-jobs](PLAN-jobs.md) | Job system audit: which commands run as jobs, what a job record holds |
| [PLAN-web-cache](PLAN-web-cache.md) | Hot state for the web interface (Redis, collector, live updates) |
| [PLAN-channels](PLAN-channels.md) | Update channels Stable, Beta, Edge on top of develop and main |
| [PLAN-portable-install](PLAN-portable-install.md) | Audit of fixed names and assumptions that break on another machine, options for pools, users and single-disk installs |
| [RELEASE-PROCESS](RELEASE-PROCESS.md) | develop, release branch, main, tags, hotfixes, the milestone branch, ruleset proposals |
| [RELEASE-0.1-checklist](RELEASE-0.1-checklist.md) | The steps to release 0.1.0, what CI and the ISO need, blockers found |
| [RELEASE-NOTES-0.1](RELEASE-NOTES-0.1.md) | Draft release notes of 0.1.0, with the hardware-UNVERIFIED parts |
| [PLAN-docker-instances](PLAN-docker-instances.md) | Docker as a capability: locked instances, child apps, recipes with `runs` |
| [PLAN-selfservice](PLAN-selfservice.md) | Self-service password change for domain users |
| [PLAN-web-auth](PLAN-web-auth.md) | Sign-in and sessions for the web interface |
| [PLAN-website](PLAN-website.md) | Public website: pages, build from the same Markdown, hosting options, release hookup, owner decisions |
| [roadmap](roadmap.md) | Milestones and open work, a snapshot of the GitHub project board |
| [Architecture decisions](adr/README.md) | Decision records (ADRs), starting with Rust behind the `hs sys` contract |
| [CLI-DESIGN](CLI-DESIGN.md) | The look of every `hs` command |
| [Entwicklungsnotizen](Entwicklungsnotizen.md) | Per-feature design notes (grouped by topic) |
