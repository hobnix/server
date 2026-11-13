# Plan: works on a machine that is not the author's (audit, 2026-11-13)

Status: step 1 (audit and plan) done for epic #459. Nothing in storage, network or firewall behaviour was changed. Open questions at the end are for the
owner. Not tested on hardware yet: this is a reading of the code, not a run on a second machine.

## Problem

The project grew on one server. A second person meets names and assumptions that only hold for the author. This page lists them, says for each
whether it is fixed or filed, and recommends an answer to the three design questions the epic leaves open.

## How the audit was done

`git grep` for `bulk`, `fast`, `homeserver`, `proxyserver`, `homeserver-installer`, `adminuser`, `ad.home.lan`, `dc1`, host and network literals
(`192.168.`, `eth0`, `Europe/Berlin`), then reading the places the hits cluster: `capabilities/storage/module.nix`, `capabilities/samba/module.nix`,
`configuration.nix`, `scripts/manage-pool.sh`, `scripts/manage-users.sh`, `scripts/install-wizard.sh`, `scripts/lib/sharepath.sh`, `presets/`.
Counts are files, not lines, and the web interface was only searched, not read page by page (its pool pages are in the navigation epic, #453).

## Findings

| Id | Finding | Where | Decision |
| --- | --- | --- | --- |
| P1 | Pool names `bulk` and `fast` are literals; the code knows exactly two pools with two roles | ~100 files: `capabilities/storage/module.nix` (`extraPools`), `scripts/lib/sharepath.sh`, `create-share.sh`, `manage-pool.sh`, `health-check.sh`, `web-serve.py` topics (`pool-info-bulk`), web pages Pools, Disks, Apps, Marketplace; tests | Issue #573 |
| P2 | `boot.zfs.extraPools` always lists `fast`; Incus uses `fast/incus`; a machine without an SSD pool has no defined state | `capabilities/storage/module.nix:25`, `scripts/manage-pool.sh:1252` | Issue #574 |
| P3 | The bulk layout is `zfs` or `snapraid` from `bulkType`; the file `/etc/hs/bulk-type` is read in several scripts, and the share tier code treats `fast` as always ZFS | `configuration.nix`, `scripts/lib/sharepath.sh:59` | Part of #573 |
| U1 | Without a domain controller the only login is `adminuser`; `hs user add` needs the instance `dc1` | `scripts/manage-users.sh:7,32,67`, `docs/users-and-shares.md` | Issue #575 |
| U2 | `adminuser` is a fixed name: Samba `force user`, web login (`HS_WEB_LOCAL_USER`), `sync-shares.sh`, `install-wizard.sh`, tmpfiles rules | 90+ places, `capabilities/samba/module.nix:57`, `configuration.nix:322,360` | Part of #575 |
| I1 | The installer takes exactly one disk: 1 GB boot, 8 GB swap, rest ext4, no encryption; with a one-disk machine there is no disk left for a pool and nothing says so | `scripts/install-wizard.sh:155-217` | Issue #576 |
| I2 | The installer is not the problem for NVMe or BIOS machines: `nvme*`/`mmcblk*` partition names and `--bios` are handled | `scripts/install-wizard.sh:113,155` | Fine, no action |
| N1 | `hs-nss-warm` looks up `ad.home.lan` and `adminuser` on every machine, with or without a domain | `capabilities/samba/module.nix:151` | Issue #577 |
| N2 | CA subject `/O=homeserver` | `scripts/dc-cert.sh:101` | Issue #577 |
| N3 | The legacy node `proxyserver` (kind `vps`) and its pages exist for one setup; the schema values are examples, `vpsHost` and `proxyStatusUrl` have no default | `scripts/node.sh`, `config/schema.toml:997-1022`, `web/src/nav.js` | Noted in #577, solved by the nodes work |
| N4 | ISO file name `homeserver-installer`, default host name `homeserver`, role `homeserver` | `installer/iso.nix:34`, `config/schema.toml:32` | Keep: `homeserver` is the product's role name, not the author's host; the host name is asked by the installer. Renaming would break CI (`nested.yml`) and tests for no gain |
| N5 | Presets: `example-server` is labelled "made-up values to copy from" (realm `AD.HOME.LAN`, `Europe/Berlin`, NVIDIA); `edge` and `minimal` carry no hardware | `presets/*.toml` | Fine: values are never overwritten, the description says they are examples. The wizard does not pick `example-server` by default |
| N6 | Defaults that are for Germany: `language = "de"` and `keyMap = "de"` appear only as examples; the defaults are `en` and the kernel default | `config/schema.toml:137-157`, `configuration.nix:34` | Fine, no action |
| N7 | Private address ranges `10/8`, `172.16/12`, `192.168/16` as "LAN" in firewall rules; `eth0` inside instances | `capabilities/gateway/module.nix:51`, `configuration.nix:258`, `capabilities/incus/module.nix:26` | Fine for a home LAN; a LAN with a public range or an unusual setup is out of scope. Firewall behaviour is not changed in this step |
| N8 | Guides use `homeserver`, `192.168.1.10` and `AD.EXAMPLE.LAN` as example values | `docs/*.md` | Fine: marked as examples ("Use your own") |
| T1 | "One person who is not the author installs it and writes down what broke" | epic #459 | Cannot be done by an agent; stays an open box on the epic |

Findings with "Fine" need no work. The three trivial renames this audit looked for do not exist: the names left are either examples, the
product's own role name, or tied to storage or the domain (so not trivial). No code was changed.

## Design questions and options

### Q1 Pools: any number and any name (#573, #574)

| Option | What it is | Cost | Risk |
| --- | --- | --- | --- |
| A. Pool data | Each pool is a row (name, role `data` or `apps`, kind `zfs` or `snapraid`) in one file the scripts and Nix read; any number of rows | Large: ~100 files move from literals to a lookup; tests need a second pool name | Migration of existing `bulk`/`fast`; the web pools page is already planned "from data" (#453) |
| B. Rename only | Two roles stay, their names become settings (`dataPool`, `appsPool`) | Medium | Does not give "any number"; the code stays shaped for exactly two |
| C. Document | Say that pools must be called `bulk` and `fast` | None | A stranger with a pool called `tank` is stuck |

**Recommendation: A, in two steps.** First a lookup library (`scripts/lib/pools.sh` and a Nix list) that returns the pools and their roles, with
`bulk` and `fast` as the rows written for an existing server, so nothing changes for it. Then move the scripts one command at a time (`share`,
`pool`, `health-check`, backup, Incus) and the web topics. A pool has a role, not a name, in the code: shares live on the pool with role `data`
(or a share names its pool), Incus on the pool with role `apps`. A server with no `apps` pool is valid (#574).

### Q2 Local users and Samba without a domain controller (#575)

| Option | What it is | Cost | Risk |
| --- | --- | --- | --- |
| A. Local accounts | `hs user add` creates a Unix user and a Samba password (`smbpasswd`) when there is no domain; per-share rights through Unix groups and Samba `valid users` / `write list`; the admin name becomes a setting | Medium: `manage-users.sh` splits into two back ends behind one interface; the web Users page reads the same data | Two back ends to test; moving from local accounts to a domain later needs a documented migration (accounts are recreated) |
| B. Only adminuser | Keep as it is, say so in the guide | None | One person, one password, no per-person rights. "Household" is the target group |
| C. Always the domain | Make the controller part of the install | Large | Needs 2 GB RAM and a VM for a file server; wrong for a small box |

**Recommendation: A.** Local accounts are the normal NAS experience and need no VM. Keep the domain as the second variant already described in
`docs/users-and-shares.md`. Files still become `force user = <admin>` on disk (as today), so per-person rights are Samba-level, not Unix-level;
the guide must say that. Make the admin account name a setting with default `adminuser` so nothing changes for existing servers.

### Q3 Single-disk install (#576, #574)

| Option | What it is | Cost | Risk |
| --- | --- | --- | --- |
| A. Honest minimum | Installer stays as is; after a one-disk install, `hs`, `hs doctor` and the dashboard say plainly: no pool, no redundancy, no encryption; apps and shares live in a directory on the system disk, marked "no protection" | Small to medium | Data on the system disk is lost with the disk; fine when it says so |
| B. Partition the one disk | Installer asks how much of the disk is for the system and leaves the rest as an empty partition for a pool | Medium: storage code builds pools on whole disks, a partition path is new | A pool on a partition is a storage behaviour change; needs its own review and the hardware runbook |
| C. Refuse | Installer stops when only one disk exists | Small | Excludes the smallest machines (mini PC, laptop) |

**Recommendation: A first, B later if wanted.** A is a message and a defined state, not new storage code, and it turns "does not work" into "works,
and here is what it lacks". Encryption of the system disk is out of scope: pools can be encrypted (`hs pool ... --encrypt`), the system disk
holds no user data once a pool exists. B stays a question for after A has been run on a real machine.

## Order of work

1. #577 (small, no design) and the guide text for Q3-A.
2. Q3-A and #574 together: they define "a server with no pool".
3. Q2-A (#575), independent of storage.
4. Q1-A (#573), the largest, after #574 so "no pool" is already a valid state.
5. T1: one person other than the author installs it on their hardware and writes down what broke.

## Open questions for the owner

1. **Q1:** option A (pool data, two steps), B (rename only) or C (document)? Recommended: A.
2. **Q2:** local accounts (A), or keep `adminuser` only (B)? Recommended: A, rights at Samba level.
3. **Q3:** honest minimum (A) now, partitioning the single disk (B) only later? Recommended: A.
4. **N4:** keep the names `homeserver` and `homeserver-installer`? Recommended: keep.
