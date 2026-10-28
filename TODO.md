# Open work

Status: `[ ]` open, `[~]` in progress, `[x]` done, `[?]` needs a decision or someone at the machine.
Brought up to date with main at #346 on 2026-10-27 (merged: #323 to #340, #346). Rewritten 2026-10-27 after a review of the old list and the roadmap. The old list
(finished rounds, the removed TUI, the vault redesign, the web build-out) is in the git history of this file.

## A. Make what exists trustworthy

1. [~] CI on pull requests only (action minutes ran out when every push ran): `ci.yml` runs on `pull_request`, `v*` tags and by hand,
   with `concurrency` cancelling older runs (2026-10-27). Then find out which tests are red and fix them; run the root/udev tests
   (`tests/pool.sh`, `pool-encrypted.sh`, `adopt.sh`, the share tests that mount pools; `tests/lib.sh` sets `HS_DISKS_ROOT=/mnt/bulk`).
   Known WSL-only failures: one check of `tests/monitor.sh` (reads the real `/dev/sde`), two of `tests/update-preview.sh` (`nix-build`).
2. [?] Work through the guides on the real server (steps marked "Not tested on hardware yet.") in blocks (first `hs rebuild` with `webUi = true`, a click-through of
   every web page, vault, backup, `hs ports`, `hs update --preview`, `hs sys health next`, a full boot cycle, `homeserver reboot`).
   Phase 7 (added 2026-10-27) covers the redesigned web interface, roles and parts, notification channels, `hs ext` and `hs node`.
   Also anything outside the repo that names `/mnt/bulk/data-NN` (own scripts, Prometheus rules, restic include lists).
3. [?] Run the recipes never run on the server, in this order: `sabnzbd`, `arr`, `seerr`, `qbittorrent` (gluetun in an unprivileged
   container is the open question), then Immich on the GPU (`hs recipe immich --ask`) and Grafana logs (`hs recipe monitoring --ask`).
   Check: hard-link test line, `hs backup ct arr on`, /opt/arr/_dump after `hs backup now`, Recyclarr's German templates.
4. [x] The cousin's recovery: data-04 (about 6 TB) was recovered with `hs disk <member> recover`, it took longer than 2 days:
   32876 files, 4.6 T (5113 videos, 22771 photos, 3725 music, 1039 documents, 228 other) in share `recovered` on data-03.
   [ ] data-04 is still out of the pool, read-only: when he has gone through the files, `hs sys disk start data-04 recover-finish`
   (the recover-finish step has not been run on a real disk yet).
   [ ] Write what was learned into docs/storage-and-disks.md (time per TB, numbered / cut-off files).
5. [ ] Rebuild rehearsal in a VM from only the backup disk and the passphrase (turns docs/backup-and-recovery.md from "Not tested on hardware yet." into a test).
6. [~] (merged #325: `hs backup report` + timer on the 25th, `hs docs verified`; not run; #339 clears stale restic locks at the start of a run) Monthly restore-drill report pushed to ntfy (the drills exist: `hs backup drill`); a "last verified" date per guide.
7. [ ] Housekeeping:
   - remove `boot.initrd.systemd.emergencyAccess = true;` from the server's /etc/nixos/hardware-configuration.nix, `hs rebuild`, reboot once;
   - set up the heartbeat + VPS watcher (second ntfy topic -> `heartbeatUrl`, `watchSites` on the VPS, docs/operations.md) and
     test it by stopping the heartbeat for 45 min;
   - the domain controller certificate expires September 2028 (put it into `hs expiry`);
   - shares created before the domain join are still open to everyone (close them in `hs share <share> perm`);
   - optional: `hs unlock --setup-key`.

## B. Features that fit the design

8. [~] (merged #323 2026-10-27, not run on the server) `hs update` with auto-rollback: after the switch the health check runs for 5 minutes, on failure the previous generation is
   switched back (a rollback exists already in update.sh; this makes the health check trigger it).
9. [~] (merged #325, not run on the server) One interface for app-database dumps (Postgres for Immich / Synapse / Authentik, SQLite for the arr apps) so the file-level
   restic copy is always consistent. A per-container dump hook exists; it needs a standard shape and recipes that use it.
10. [~] (merged #325: `incus export` of the VM into restic; not run) VM coverage in `hs backup ct` (Incus VMs, not only the domain controller).
11. [ ] Later: a cloud (or other) backup target next to the local disk. Not needed now. (The backup to the other server and the
    off-site copy are built; set up when wanted.)
12. [~] (merged #326 and PR #328: forecasts, urgent below 7 days, backup forecast from bytes, SSD wear, "notify and pause" behind `autoMitigate`; further mitigation levels still open, each needs a question first; not run on the server) Capacity and trend alerts (pool fill forecast, SSD wear, cache-mover backlog, backup growth, from state.db and Prometheus) and
    **automatic mitigation** when something bad is about to happen (a disk turns red and will be dropped: pause syncs, stop writes, start
    a copy, notify). Touches storage: each action needs a design question first; start with "notify and pause".
13. [~] (merged #326, web Health page with ack/resume in PR #329; decided: everything below high is held in quiet hours, `hs backup` is not paused) Notification routing: severities, quiet hours, a second channel (Matrix is used for cards), acknowledging a problem.
14. [~] (the node pages exist since the web redesign phase 2D; the edge status document carries these keys since #335; not run against a real VPS) Web: the proxyserver pages need the keys the status document still lacks (`mail`, `watcher`, `game_ports`, `certificate`, `revision`,
    `os`, `region`, `tailscale_info`, `settings`; shapes in docs/PLAN-web-backend.md). Folded into D, since the VPS becomes a node.
    (The `vps update|watch` buttons exist; with nodes they become `sys node <name> update|watch` where the node allows it.)
15. [~] (merged #324: Recycling Bin and Remove Completed through the API, jq code never run; Jellyfin Connect is a note only) arr: Recycling Bin in Radarr and Sonarr (set by hand now), Remove Completed on the SABnzbd client, the Jellyfin Connect entry;
    later the other server's library as a read-only, unmonitored root folder (waits for the remote-pool branch).
16. [ ] Investigate the sudo stall of 3 to 5 s (winbind group lookup suspected; sampler log /tmp/slowsudo.log). Has not shown up in a while.

## C. Recipes (when one is needed, we do it)

Nextcloud or Seafile, Paperless-ngx, Vaultwarden (review the vault threat model first), Audiobookshelf, Navidrome, AdGuard Home /
Pi-hole behind the DNS capability, Frigate (GPU), a restic REST server for other devices.

## D. Nodes: every server is a node of one repo (design agreed 2026-10-27)

The proxyserver repo is DEPRECATED (decided 2026-10-27; archive it only after the cutover): the proxyserver stops being its own repo: it becomes a node with a different set of capabilities. Your server is the local (main) node,
the cousin's server and the VPS are remote nodes. Storage, Incus, Samba, backup and the like become capabilities too, and the install
wizard asks which of them to set up.

Rules: the main node pulls from a peer through a narrow read allowlist (like `READS` in web-serve.py), a peer never gets a shell or control
of the main node, the VPS key never gets more than fixed words. The cousin's server is another person's: read-only first, actions only
when he creates the key and allows them. No shared control plane.

1. [~] (merged #327: `hs node`, ssh forced command `status`; 7 open questions at the end of the plan for the user; web side merged with the redesign phase 2D, #346: Nodes page, `hs sys node plan|start`, remote nodes as tree roots, the proxyserver pages under the node; not run) Node registry (`hs node add|list|remove`, local node first), web tree with nodes at the top, the proxyserver pages become a node's pages.
2. [ ] The cousin's server as a read-only node (reuses `hs sys deck`, the one-read status document).
3. [~] (merged #335: roles `homeserver|edge|minimal`, storage/incus/samba/backup as capabilities, edge-mail/ports/watcher/status, wizard `--role edge`, `hs edge health`; not run on a VPS; the commands of storage/incus/samba/backup are hidden from `hs help` on a node without them) A minimal base profile (users, SSH, `hs`, Tailscale, health, notify) and the edge capabilities (mail, game ports, watcher, status
   document); storage and Incus become capabilities; wizard options. Rehearse in a VM or on a spare VPS.
4. [ ] Cut over side by side (the VPS carries the MX and the public ports): new edge node next to the old one, compare, switch DNS/MX,
   then archive the proxyserver repo. Its copies of ntfy.sh, deck-serve.py and hs-watch.sh disappear.

## E. Notifications as a capability (decided 2026-10-27)

ntfy is hard-coded today. The capability `notifications` owns a list of channels (provider, settings, minimum priority, quiet hours yes/no);
ntfy is one provider among several (email, Matrix, Telegram, generic webhook, Atom feed for history, maybe Apprise); several channels run in
parallel and one failing never blocks the others. With the capability on, the web interface gets a Notifications page (add, edit, test).
Routing (quiet hours, digest, acknowledging, urgent) stays central above the providers. At least one channel must live outside this server
(everything here is down while storage is locked); the page warns otherwise. The old `notifyUrl` / `notifyUrlSecond` become a first ntfy
channel automatically. "ntfy.sh is the only curl" becomes "providers are the only curl".

1. [~] (merged #331 and #334; not run on the server) Plan and step 1 (channel store, provider interface, ntfy as provider #1, `hs notify channel ...`).
   Decided: categories `alarm|status|heartbeat|digest`, each channel ticks the ones it carries (page = channels x categories); the heartbeat
   becomes a channel with `heartbeat` ticked, outside the quiet-hours/priority/digest rules; the old `heartbeatUrl` is derived as such a channel.
2. [~] (merged with #335 and rebuilt on the new components in #346: channels x categories matrix, `sys notify plan|start`; not run) The Notifications web page.
3. [~] (an `email` provider exists, merged #335; not run) A second provider (Matrix or email), then the rest as needed. Which one is open: ask what bothers the user about ntfy beyond the hard-coding.

## F. Web interface: one source of truth per object (decided 2026-10-27)

Today several pages show the same disks, pools and shares. Goal: one page per object (Disk, Pool, Share, Container, Node); every other page
only summarises and links. The tree is not set in stone: duplicated routes can go. Nodes are the roots (main, edge, cousin's), each node's
subtree shows only the capabilities it has. Order: the current todos first, then the redesign; the planning starts now so new pages fit.
New pages are frozen except Notifications (built to the new navigation).

1. [x] Inventory and navigation plan (merged #333).
2. [x] Brief for Claude Design (merged #338; the design prototype and handoff are in web/design/).
3. [~] (merged #340 shell: tokens, shared components, node-rooted routing, halftone; #346 phase 1 and the phase 2 pages: Pools, Disks, Shares, Backup, Instances, Apps, Services, Network, Notifications, Summary, Health, Nodes, Settings part switches; not run in a browser against the real server) Redesign, then retire the duplicated routes. Decided: every node, the local one too, lives under `/node/<name>/...`.
   [ ] Open: look through every page on the server (Pruefliste phase 7.1), then remove the old routes that still redirect.
4. [~] (merged #336; not run) Game streaming and Posters are capabilities `games` and `posters`, off by default (nothing in the tree on a fresh server).
   On the existing server add them to `capabilities` in machine.toml (the example-server preset has them) and `hs rebuild`.
5. [~] (merged #337 `hs ext` loader and bb448ef: GenericPage renderer, extension pages from `[web.page]`; recipes' status panel and the repository of their own are open) Extensions: a package manifest with a `[web]` section (page as data: reads, actions, a fixed layout; no JavaScript from packages), the
   same section for recipes (status panel, a few allowlisted actions); later recipes and extensions in a repository of their own at a pinned commit.
   Commands: `hs ext <name> <command>` / `hs sys ext <name> <command>`, a package carries its own command rows; pilot Games and Posters (merged #337).

## G. File manager (description 2026-10-28)

Two panes (disk or pool left, disk or pool right), bulk selection, copy / move / delete / rename through plans and background jobs, with the rule that a pool disk and its own
pool never meet (data loss of 2026-10-18). Description and open questions: docs/PLAN-file-manager.md. The owner designs it, then: `hs sys fm ...` backend (storage code, tested in a VM),
the Storage > Files page, entry points from Disks, Pools and Shares.

1. [ ] Design from the owner, answers to the open questions at the end of the plan.
2. [x] Backend `hs sys fm locations|pair|ls|plan|start|progress` (built 2026-10-28, folders only in tests; `stat`/`du` not built).
3. [x] The page Storage > Files (built; entry points from Disks, Pools and Shares are links with `?left=&path=&right=`). Page and backend are integrated and covered by a contract test (tests/web-files-contract.sh).
4. [ ] **Safety switch**: `fileManagerWrite` is off by default. Run the VM checklist (docs/PLAN-file-manager.md 7a, docs/Pruefliste-Server.md 7.6), then switch it on.
5. [ ] Not built: `fm du` and Calculate size, pause, trash, `hs fm ...` user commands, the editable path field, owner and mode in Info.

## Later / ideas

- Immutable offline copy: a rotating second backup disk with a swap reminder (tied to `hs expiry`).
- Mobile-friendly web UI; a read-only status page per family member.
- Quiet hours / fan schedule (`hs fans`).
- Boot time (36 s) and the managed switch's edge-port setting for the 8 s DHCP wait.
- Synapse media (`/var/lib/matrix-synapse/media_store`) lives on the container's root disk; look again past about 50 GB (notes in git history).
- Moving `/mnt/bulk/pool` out of `/mnt` (skipped on purpose).
- Parked: Caddy as a second reverse proxy, other router providers than UniFi, Incus clustering, guest accounts through Authentik.
- Known: `incus launch` of a VM sometimes hangs on this host (cause unknown).
