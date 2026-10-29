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
| [PLAN-web-backend](PLAN-web-backend.md) | The web interface backend |
| [PLAN-disk-health](PLAN-disk-health.md) | Daily SMART baseline, and a disk and pool checklist |
| [PLAN-web-cache](PLAN-web-cache.md) | Hot state for the web interface (Redis, collector, live updates) |
| [CLI-DESIGN](CLI-DESIGN.md) | The look of every `hs` command |
| [Entwicklungsnotizen](Entwicklungsnotizen.md) | Per-feature design notes (grouped by topic) |
