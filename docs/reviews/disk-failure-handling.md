# Disk and pool failure handling: review

Review for hobnix/server#171 (epic #159, Reliability and Recovery). Date of the code read: 2026-11-04, branch `develop`. Findings only: no
storage code was changed. Not tested on hardware yet. Everything below comes from reading code and docs; **nothing was run on a ZFS or SnapRAID
server**, so every behaviour claim is "read in code" unless it says otherwise.

## Scope

Failure cases: ZFS pool degraded or faulted, a disk gone, SMART failing, a SnapRAID disk failure or missing parity, scrub errors, a pool that
does not import at boot, a full pool. For each: what detects it, what is raised (event log, health, notify), what the web and `hs` show, what the
docs tell the user to do, and what is missing.

## How the pieces work today (read in code)

- **Health check** `scripts/health-check.sh`, unit `hs-health-check`, every 15 minutes (`startAt = "*:0/15"`, configuration.nix). It builds a list of
  problems with keys, sends one push when the list changes, and an "all clear" at the end (notify.sh). This is the only path to a push for a disk
  or pool problem.
- **Event log** (ADR 0005): `scripts/zed-event.sh` (zedlet `all-hobnix.sh`) writes `storage.pool-fault` and refreshes the disks live data. The
  disk collector in `scripts/state-db.py` writes `storage.missing`, `storage.worse` and friends. The event log does not push by itself.
- **Mitigation**: with `autoMitigate` on, a failing disk, a bad ZFS state or a missing bulk member pauses sync, scrub and cache mover. Off by default.
- **Jobs**: `hs-bulk-sync`, `hs-bulk-scrub` and other `hs-*` units have `onFailure = notifyFailure`, which pushes at once.

## Table

"Detected" = something notices. "Alerted" = push or event. "Shown" = web or `hs`. "Documented" = a recovery step in the docs.

| Case | Detected | Alerted | Shown | Documented | Gap |
| --- | --- | --- | --- | --- | --- |
| ZFS pool DEGRADED or FAULTED (imported pool) | health check: `zpool status -x` not healthy, key `zfs:<pool>:<state>`; zedlet on `resource.fs.zfs.statechange` | event `storage.pool-fault` at once; push at the next health run (up to 15 min) | Health page, `hs health`, disks group refreshed by the zedlet | table row "`DEGRADED` pool: replace the disk" and "Replace a disk" (ZFS resilver) | no push at once; the guide has no steps for a disk that is gone (offline, `zpool clear`, replace by GUID); whether `hs pool replace` works for a vanished ZFS disk was not verified |
| A disk gone (unplugged, dead) | state db marks it missing (`disk:<serial>:missing`, event `storage.missing`); SnapRAID member not mounted (`bulk:<name>:<state>`); ZFS: the pool goes DEGRADED | push at the next health run; event | Health, `hs disk list` shows MISSING | "a disk is MISSING: plug it in, or replace it" | none big; "Gone for good? hs disk X forget" is in the problem text only |
| SMART failing | health check: `disk:<name>:smart` (overall FAIL), `:pending` (pending sectors), `:bad` (disk-health.sh verdict); daily SMART check events `storage.smart-failing`, `storage.worse` | push at the next health run; autoMitigate can pause the bulk jobs | Health, `hs disk list`, `hs disk <d> health` | "Disk health" section | `storage.smart-failing` is registered with level `info` in event-kinds.tsv (the emitting code was not found by grep, so the real level is unverified); no smartd, so no faster path than 15 min |
| SnapRAID data disk failed | member not ONLINE (`bulk:<name>:<state>`); `hs pool bulk sync` refuses ("not mounted") | push at the next health run; the nightly sync fails and `onFailure` pushes | Health, `hs pool bulk` | "Replace a disk" (rebuild from parity) | no short "a disk died: what first, what not to do" beyond the replace section |
| SnapRAID parity missing | `bulk:no-parity` ("a failed disk loses its data"); sync refuses without a parity line | push at the next health run | Health | "Replace a disk" says a data disk cannot be replaced without parity | no steps to rebuild a lost parity disk (add a new parity disk, sync) in "If something goes wrong" |
| Scrub errors, ZFS | health: `zfs:<p>:scrub-errors` (error count in the `scan:` line), `scrub-old` (21 days), `scrub-never`; pool-state.sh `scrub` line | push at the next health run | Health, `hs sys pool state` | operations.md threshold table only | no recovery text (which files: `zpool status -v`, restore from backup, `zpool clear`); a failed `zfs-scrub` unit is not checked (only `hs-*`, bulk-mount, samba), so a scrub that never starts shows up only after 21 days |
| Scrub errors, SnapRAID | `hs-bulk-scrub` exits non-zero ("The check did not finish") and `onFailure` pushes; `bulk:scrub-old` / `scrub-never` | push | Health | "Keep the data protected" describes the scrub | no text on what to do when the scrub reports damage (`snapraid fix`) |
| Pool does not import at boot | **nothing**: the health check loops over `zpool list`, so a pool that is not imported is not in the loop; `zfs-import-*` units are not in the failed-unit check; `/bulk` is skipped on ZFS | none | pool-state.sh prints "the pool is not there" for the scrub line only; no Health entry | none | the most serious gap: a missing `bulk` or `fast` pool is silent. Encrypted pools waiting for the passphrase are handled separately (`storage:locked`) |
| Pool full | health: `space:pool:<p>` and `space:/bulk` at 90 %, cache check, capacity forecast (`forecast:<volume>:urgent`) | push at the next health run | Health, capacity page | operations.md threshold table | SnapRAID: only the merged `/bulk` is checked, not each data disk (whether capacity.sh covers it was not verified in full) |

## Gaps, ranked

1. **A pool that does not import is not reported.** Proposed issue: "Health: report a ZFS pool that is not imported, and failed zfs-import and
   zfs-scrub units". Accept: a known pool missing from `zpool list` produces a health problem; `zfs-import-*` and `zfs-scrub` failed units are
   checked like `hs-*`; test with a stubbed `zpool`; docs row.
2. **`storage.pool-fault` does not push.** The zedlet writes an event and refreshes live data only; the user hears about it at the next 15-minute
   health run. Proposed issue: "ZFS fault: start the health check from the zedlet". Accept: zed-event.sh starts `hs-health-check` without blocking
   and without failing ZED; a test with a stub notifier. Not verified: how often ZED fires for the same fault.
3. **No recovery runbook for failures.** The guide has one table row. Proposed issue: "Docs: failure runbook per case (ZFS degraded, disk gone,
   parity lost, scrub errors, pool not imported)". Accept: a section in storage-and-disks.md per case with what to check first, what not to do,
   the command, and "Not tested on hardware yet."
4. **SnapRAID: one full data disk is not seen.** Only `/` and `/bulk` are checked. Proposed issue: "Health: fullness per data disk on SnapRAID".
   Accept: a data or parity disk at 90 % produces `space:<member>`; test with a stubbed df. Verify first that capacity.sh does not already do it.

Not proposed as issues because not verified: the `storage.smart-failing` level; `hs pool replace` for a ZFS disk that is gone; what ZED does
without the NixOS default `services.zfs.zed`.

## What was not checked

No hardware, no VM and no test run. Web pages were not opened; only the scripts that feed them were read. The state db code that emits
`storage.smart-*` was not located. Hot spares, ZFS special devices and encrypted-pool failure paths were not reviewed.
