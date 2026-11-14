# Hobnix 0.1.0 release notes (draft)

Draft for the release "0.1 Trustworthy Foundation", built from the 155 entries in `docs/changelog/` (2026-10-28 to 2026-11-09). Re-read before the
tag. The same text is the body of the release pull request and of the GitHub release.

**Read this first.** Hobnix 0.1.0 has not been run on real hardware as a whole. The installer ISO has never been booted, a restore from
backup has never been run, and the Hobnix-in-Hobnix test harness has never run against a real VM. Items below marked **UNVERIFIED** were
written and tested only with fakes, fixtures and unit tests. Do not trust this release with the only copy of your data.

## What 0.1.0 is
A NixOS home server: Incus containers and VMs on ZFS or SnapRAID, Samba shares, backups, one command `hs`, a web interface. Apps and
extensions are packages from their own repositories (hobnix/recipes, hobnix/extensions), installed only from signed release tags. Installer ISO
on every release tag. Update channels stable, beta and edge exist; the first stable tag is this one.

## Hardware-UNVERIFIED parts
Open issues that ask for a run on real hardware, still open at the time of writing:
- #161 run the auto-rollback on the real server and record the result
- #163 rebuild rehearsal in a VM from backup disk and passphrase
- #165 first monthly restore-drill report
- #171 disk and pool failure handling review (the written runbook `docs/reviews/disk-failure-handling.md` and the guide have never been followed on a real failing disk)
- #175 boot the ISO on real hardware or a VM (milestone 0.2)

Merged work that says UNVERIFIED in its pull request or changelog entry:
- Installer restore from backup disk and password, `hs-restore` (issue #254, PR #362). Only a fake `restic` was used.
- Hobnix-in-Hobnix nested test harness and the manual `nested` workflow (issue #262, PR #374). The harness never ran against a real VM, the
  workflow never ran.
- Graphical VM console relay (PR #379, ADR 0021): the connection exists, no picture yet.
- Unraid template and Proxmox vzdump import (PR #382): tested only with small archives built by the tests.
- Gateway setup steps and ACME via Cloudflare DNS-01, Docker pages and editor, package events, ZFS fault events and pushes, config restore, storage
  incident workflow, first-run token, extension boot hook: each entry in `docs/changelog/` says "not tested on hardware" or UNVERIFIED in its body.
- Every guide section that ends with "Not tested on hardware yet." (docs/containers-and-apps.md, docs/install.md, docs/web-interface.md).

## Installer and first setup
- The installer ISO (`hs-install`) and `hs-restore` (UNVERIFIED, see above). Unattended installs: `hs installer check-answers`.
- First setup in the browser with a one-time code from the console (server part; UNVERIFIED).
- ISO library: add install images from a file or URL, checked against a checksum. Create-instance wizard with disk placement and install from an ISO.

## Updates, channels and packages
- Update channels stable, beta, edge, set in Settings or `updateChannel`; beta and edge never update by themselves. Tags are verified against the release key.
  A server made by the installer has no git checkout yet; see the blockers in `docs/RELEASE-0.1-checklist.md`.
- `hs changes` and the "What's new" page list what an update brought.
- Apps and extensions come from their own repositories; the Marketplace, install, update and remove of several at once, `hs pkg remove`,
  `hs pkg new`, the package builder, declared package permissions (refused when exceeded), compatibility checks before an extension switches on.
- Apps declare their own events and notification rules. Recipes can say where they may run.

## Storage, backup and recovery
- Shares: hide or show a share, shares on the SSD pool, orphaned or long-named shares can be deleted, a share is listed only for people with read access.
- Disks: daily SMART baseline, ERC and staggered self-tests; convert a disk and discard its files (`--discard`); pool members show usage; closed disks can be
  emptied in Files; parity sync no longer stops on emptied log files; Health no longer claims "no parity disk" and reports a pool that did not import.
- The settings backup and `Put the server settings back from the backup` (UNVERIFIED); a guide says what it holds.
- Disk failures: a case-by-case guide, a storage incident workflow, plugged-in and removed disks in the event log, ZFS faults shown and pushed at once (UNVERIFIED).
- Backup of new instances is a setting (`backupNewInstances`).

## Jobs, events and live state
- One event log; an event catalogue (`hs event kinds`); `hs audit` (who did what); jobs write their changes to the log, stopping a job is recorded, and after a restart
  the server says which jobs were interrupted. Job records are readable through the API.
- Optional live state through Redis; pages follow it (Summary, Storage, Apps, Instances, Network, Users, Backup, extensions); one status for every
  live value, last good data shown with a warning when a read fails; a state inspector page; the top bar says when data could not be read.
- Push messages come from the event log. A change made with `hs` shows up in the web interface.
- Runtime settings no longer need a rebuild or `machine.toml`; changes that wait for a rebuild are listed and applied by one rebuild; every change says
  when it takes effect.

## Apps, Docker and instances
- Docker as part of Hobnix (UNVERIFIED): page with list, start, stop, logs, pull; compose file and `.env` editor with Test and Save; paste a `docker run`
  command; private registries; apps live in one share; `hs docker import`, `move-apps`; deleting an app keeps its data unless asked.
- Instances owned by a capability are locked against deletion and device changes; VMs have a Console button (connection only).
- Dashboard of tiles replaces the Homepage app. Apps show their version and say Repair when current.
- Import from Unraid templates and Proxmox vzdump archives (UNVERIFIED).

## Network and gateway
- Gateway: passthrough to another server, guided setup, paths, forward auth, headers, a public Traefik variant; cloudflared over an internal Incus link;
  optional ACME via Cloudflare DNS-01 (parts UNVERIFIED).
- Network, DNS, language and region settings as one-question wizards; network card list; sign-in through the gateway on port 80.

## Web interface
- Spinners on every button that starts a job; plan dialogs open at once; dangerous dialogs have a red Start button; the Reboot and Shutdown buttons work;
  the task log follows output; bulk selection; capability pages have tabs and status tags; editing users and groups; the browser terminal can be switched on.

## Fixes worth knowing
Rebuild with options and mail subjects, the long-question crash of the terminal prompt, `hs share <share> auto` SIGPIPE, UniFi lists with many clients,
Docker app actions, "not installed from a repository" on update, Domain Admins permission removal, recipe German texts.

## Known gaps
- `main` has never held a release; this is the first tag. No tag, no release exists before it.
- The beta mode of `release.sh` and a beta ISO are not built.
- Open P0 issues of the milestone are listed in `docs/RELEASE-0.1-checklist.md`.
- Languages: the documentation is English only; terminal output has German texts for most commands.
