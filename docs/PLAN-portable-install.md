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

## Pools as data: design and owner decisions (#573, #574, #576, #581)

Status: Accepted 2026-11-13 (owner accepted D1-D10 as recommended); building step by step. No storage behaviour changed. Not tested on hardware yet. The full spec (inventory with file counts, Nix
changes, exact content of step 1) is `.work/pools/spec.md` in the working tree of the session that wrote it; this section is the part that
outlasts it.

### Where names are fixed

About 290 files and 2800 hits for the pool names `bulk` and `fast`: scripts (62 files, `manage-pool.sh` the largest), `scripts/lib` (10),
web pages and `web-serve.py` topics (41), tests (112), `capabilities/storage/module.nix` (`boot.zfs.extraPools`, import units), Incus
(`fast/incus`), Samba (`/bulk/shares`), `configuration.nix` and docs. Internal identifiers that are not pool names (`bulkType`,
`bulk-mount.service`, `hs-bulk-sync`, labels `bulk-data-NN`) stay.

### Target model

- Pools are rows in one `pools` table in `machine.toml`: name, `role` (`data` or `apps`), `kind` (`zfs` or `snapraid`). Nix reads it at
  evaluation time, scripts through `scripts/lib/pools.sh`.
- No `pools` line means the legacy rows `bulk` (data, kind from `bulkType`) and `fast` (apps, zfs). The author's server has no such line, so
  nothing changes for it; the store path must stay equal (checked with `nix-instantiate` before and after).
- `pools = {}` is a server with no pool. Code asks for a role ("the data pool", "the apps pool"), not a name.
- No apps pool: nothing is imported at boot, Incus `default` is a `dir` pool on the system disk (no nightly snapshots there), and `hs doctor`,
  `hs motd` and the dashboard say what is missing. This is a setup state, not a health problem.
- Single disk: same state. Shares wait for a pool and `hs share add` says so; apps keep working. The first-run checklist (#581) reads the rows;
  `hs sys setup list` keeps its shape.
- Rows are written only by `hs pool` (create) and `hs pool record` (shows a plan, asks, never automatic).

### Steps (small PRs, each behaviour-preserving until step 5)

1. `scripts/lib/pools.sh` and `tests/pools.sh`, read-only, no caller.
2. Ratchet guard: `tests/pool-names-ratchet-test.py` with a baseline of per-file counts that may only fall; new files may have none.
3. Schema option `pools` and the Nix modules read the rows (store path equal without the line).
4. First-run checklist from the rows (#581).
5. The no-pool state: messages, refusals, `hs sys pool list`, `hs pool record`, installer writes `pools = {}` (#574, #576).
6. Shares follow pools (`--pool`, `--fast` stays as alias).
7. `hs pool` accepts any ZFS pool name (create path shows "a NEW pool", typed NAME stays).
8. Readers loop over rows (health, backup, capacity, overview).
9. Web pages and routes, two or three pages per PR.
10. Instances (`hs ct` uses the apps pool).
11. Only if D6 allows: a SnapRAID pool with another name.

### Risks

A wrong row can skip an import or publish the wrong folder, so absent means legacy forever and rows are never written silently. ZFS and
SnapRAID differ: SnapRAID has one config, one mergerfs unit, one lock and labels `bulk-*` (xfs labels hold 12 characters), so at most one
SnapRAID pool. Incus never changes the driver or source of `default`, so later apps pools become extra Incus pools. Web contract lines
(`hs sys setup list`, `hs sys pool ...`, health ids, live topics) keep their shape.

### Decisions for the owner (Accepted 2026-11-13: all recommendations D1-D10)

| Id | Question | Options | Recommended |
| --- | --- | --- | --- |
| D1 | Where the rows live (blocks step 3) | machine.toml table; runtime TSV read impurely by Nix; ZFS property | machine.toml |
| D2 | Role names (step 1) | `data`/`apps`; `bulk`/`fast`; `hdd`/`ssd` | `data`/`apps` (CLI option `--use`, since `--role` already names disk roles) |
| D3 | Shares on a one-disk server (step 5) | none until a pool; a pool kind `dir` on the system disk | none now, `dir` later if asked |
| D4 | Default pool of a share (step 6) | first data pool, `--pool` to choose; every share names its pool; a setting | first data pool |
| D5 | Incus `default` pool (steps 3, 10) | pinned to what it was first, later pools added beside it; rebuild `default` | pinned; no snapshot schedule on a `dir` default |
| D6 | SnapRAID pools (steps 7, 11) | one, named `bulk`; one, any name; several | one named `bulk` now, any name as step 11 |
| D7 | Pool name rule (step 1) | `^[a-z][a-z0-9]{0,11}$` minus reserved words | as written |
| D8 | Are `bulk` and `fast` reserved? | plain names, legacy default only; reserved | plain names |
| D9 | "No pool" in health | notes only; a health problem | notes only |
| D10 | Legacy server missing a derived pool | doctor offers `hs pool record`; `hs update` writes the line | doctor offers it |

Open for verification in step 3: whether `hs config check` accepts nested tables, and what the Incus preseed does when re-applied to an
existing pool.

## Q2 in detail: local users and Samba without a domain controller (#575)

Status: design only (issue #575, step 1). No user or Samba behaviour was changed. Not tested on hardware yet: nothing here was run on a server or in a VM.
This section is the design of option Q2-A above. It is kept separate from the pool design (Q1).

### Where the domain controller is needed today

- `scripts/manage-users.sh` runs every user and group operation through `samba-tool` and `ldbsearch` inside the DC instance; without it, it stops with "No domain controller". `scripts/user-change.sh` (group SID through `wbinfo`), `scripts/manage-shares.sh` (`describe`, `principals` through `wbinfo`), `scripts/sync-shares.sh`, `scripts/temp-disk.sh` and `scripts/backup.sh` ("Domain Admins only" for new shares when `security = ADS`) depend on winbind too.
- The Users, Groups and Certificates pages and the `hs user` rows are hidden without the capability `ad` (`capability:ad` in `registry.tsv`, `capability: 'ad'` in `web/src/nav.js`).
- The name `adminuser` is a literal in about 90 files: Samba `force user` and `valid users` (`capabilities/samba/module.nix`), `configuration.nix` and `install.nix` (account, tmpfiles, `HS_WEB_LOCAL_USER`), `scripts/install-wizard.sh`, `sync-shares.sh`, `create-share.sh`, `manage-pool.sh`, `backup.sh` and more.
- Already independent of the domain: share ACLs through `sharesec`, the password hand-over (stdin, a 0600 file in `/run/hs`), `scripts/user-access.sh`.

### Target model

- **Back end:** derived, no new setting. `adDomain` set: the domain back end runs exactly as today. Not set: local back end. `adDomain` already switches Samba `security`, nss and krb5; a second key could disagree with it.
- **Admin account:** new setting `adminUser`, default `adminuser`, chosen at install only (the installer asks). It is the SSH/sudo/web login and the owner of every file on the shares.
- **Share user:** a Unix account (uid 2000-2999, no home, no shell, locked Unix password, not in wheel) plus a Samba password (`smbpasswd`). It can open shares and nothing else; it cannot sign in to the web interface (every web user is root-equivalent until roles, ADR 0012).
- **Group:** a Unix group (gid 2000-2999), members through `gpasswd`. No "Domain Users" and no local admin group; the admin account is the admin.
- **Rights:** per-share ACLs (`sharesec`) with local SIDs, as with the domain. Files stay `force user = <admin>` on disk, so per-person rights are Samba-level, not Unix-level; the guide says so. New shares start closed to the admin in local mode.
- **Web and wizard:** the Users and Groups pages read the same `hs sys users ...` lines (shape unchanged) and only change wording and hide mail/description. The wizard sets the admin's login password; the Samba password of the admin and the first other person come after the first rebuild (`hs user <admin> passwd`, `hs user add`), shown as a setup item.
- **AD only:** domain sign-in to the web, `hs user flush`, mail/description, group names with spaces, DNS and certificates, SSO.
- **Coexistence:** one dispatch line in `manage-users.sh` after option parsing; with `adDomain` set the existing code path runs unchanged, and the Nix values for `adminUser = "adminuser"` must be identical to today's (store-path compare).
- **Migration local to domain:** documented manual steps (list, set up domain, recreate users with new passwords and rights, remove old accounts and dead ACL entries); domain to local is not supported.
- **Security:** passwords never on argv or in the environment (stdin only, `printf` is a builtin); `scripts/lib/secret.sh` is for secrets `hs` stores and `hs` stores no user password; hashes live in Samba's `passdb.tdb`. Names are validated by fixed patterns; deleting a user asks for the typed name.

### Steps (each small and behaviour-preserving for a server with `adDomain`)

1. `adminUser` setting (schema, Nix, `scripts/lib/admin.sh`), default unchanged.
2. Scripts use `admin_user` instead of the literal; a test keeps new literals out.
3. Installer asks the admin name.
4. Local back end for users and groups (`users-backend.sh`, `users-local.sh`, dispatch line, registry tags).
5. Share rights locally, after a VM probe (below).
6. Web wording and navigation.
7. Guide, notes, changelog.

Tests: new `tests/admin-user.sh` and `tests/users-local.sh` with fake `useradd`, `smbpasswd`, `pdbedit` that check each argv and that the password only arrives on stdin; extensions of `tests/sync-shares.sh`; all through `scripts/dev/t quick`.

### Not verified (checked first in the step that needs it)

- A standalone `smbd` honours a share ACL that holds only `S-1-22-2-<gid>` (Unix group) or a passdb user SID (VM probe, step 5; fallback: `S-1-22-1-<uid>` or `net groupmap`).
- NixOS (`users.mutableUsers` default) keeps accounts added by command across `hs rebuild` (step 4, VM).
- `passdb.tdb` is in the folder that is bind-mounted into the vault.
- The navigation filter in `web/src/nav.js` also applies to child entries.

### Owner decisions for Q2 (answered 2026-11-13)

- **D1 Rights mechanism.** A: share ACLs (`sharesec`) with local SIDs, as with the domain: one mechanism, the Shares page, `user-access.sh` and the health check stay as they are. B: `valid users` / `write list` per share, as the first plan text said: easier to read in `smb.conf`, but a second rights model next to the ACLs. **Recommended: A**, B only if the VM probe fails.
- **D2 Migration to a domain.** A: documented manual steps only. B: a command `hs user migrate-to-domain`. **Recommended: A**; B only when someone needs it.

Decided without asking (say if you disagree): back end derived from `adDomain`; `adminUser` is install-time only; share users have no shell, home or web sign-in; ids 2000-2999; new shares start closed to the admin in local mode.

**Answered:** D1 = A (share rights through `sharesec`, with a fallback to B only if the VM probe fails), D2 = A (migration to a domain as documented steps, no `hs` command). The "decided without asking" list stands.
