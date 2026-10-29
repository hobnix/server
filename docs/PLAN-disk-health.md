# Disk health: daily SMART baseline and a checklist for both pools

Status: designed 2026-10-29; Part 1 (daily baseline), the `smart-failing` pause, the staggered long test and ERC at boot are built (the owner decided
Part 3 on 2026-10-29); the rest of Part 2 is a checklist only. Nothing here has run on a real server. Not tested on hardware yet.

Part 1 is the design of a **daily SMART baseline check**: it rates every disk healthy, watch or failing from what CHANGED since the last check.
Part 2 is a **checklist** of good practice for the bulk pool (SnapRAID or ZFS on spinning disks) and the fast pool (ZFS on SSD), compared with
what the repository does today. Part 3 lists the questions only the owner can decide.

## Part 1: the daily SMART baseline

### What exists today (reused, not duplicated)

| Piece | What it does | Kept as is |
| --- | --- | --- |
| `scripts/disk-health.sh` | the ONE place (with monitor.sh) that calls `smartctl`; `smart_json <dev> [standby]` with the `-d sat` fallback; absolute verdict OK/WATCH/BAD per disk (`--list`); counters 5/187/199/error log compared with the last PASSED self-test (`/var/lib/hs/disk-tests`) | yes; gets one new mode `--readings` |
| `scripts/state-db.py` (via `scripts/state.sh`) | the ONE writer of `/var/lib/hs/state.db`; table `smart` (realloc/pending/CRC/temp/hours every 15 min from `monitor.sh --disks`), `worse` = growth against the oldest reading of the last 14 days -> problem `disk:<serial>:worse` | yes; gets a table `baseline` and the commands `baseline-run` / `baseline` |
| `scripts/health-check.sh` | the only alarm, every 15 min, sends when the set of problem keys changes; already reads `state.sh problems` | unchanged: the new problems arrive through `state.sh problems` |
| `tests/maintenance-window.sh` | only monitor.sh and disk-health.sh may call smartctl; periodic polling uses `-n standby` | the new code follows both rules |

What is missing: attribute 198, the NVMe values (critical warning, media errors, percentage used, available spare), a once-a-day comparison
with a stored reading, a three-level verdict from the change, WWN as a second identity, explicit rules for first run, replaced disks and
counters that go down. The `smart` table cannot simply grow columns for this: it is fed every 15 minutes from `monitor.sh --disks`, whose
line shape is a contract with the web interface and the exporter path has no 198 and no NVMe values.

### Decisions

1. **Where the baseline lives.** A new table `baseline` in `/var/lib/hs/state.db`, written only by `state-db.py baseline-run` (the database's
   one-writer rule stays: the program is still state-db.py). One row per disk, primary key = the disk's own serial number as smartctl reports
   it (`serial_number`), the same key the inventory (`disks`) uses, so `hs disk <serial> forget` and the health keys line up. The WWN
   (`wwn.naa-oui-id`, or for NVMe `eui-<oui>-<ext_id>` of the first namespace) is stored next to it as a second identity. Never keyed by
   `/dev/sdX`: the kernel name is only stored as "last seen as". A disk without a serial is not tracked (same rule as the inventory's `dev:`
   rows).
2. **What is stored per disk:** hours, 5 reallocated, 197 pending, 198 offline uncorrectable, 199 CRC, NVMe critical warning, media errors,
   percentage used, available spare, available spare threshold; plus `level` (healthy|watch|failing), `level_time`, `note`, `first_read`,
   `last_read`, `last_try`. SAS disks: grown defect list counts as 5, total uncorrected read errors as 198 (Not tested on hardware yet).
3. **The comparison is against the previous successful reading** (rolling baseline: after every run the stored values are the current
   ones). Rules, per run (delta = now minus stored):

   | Level | When (any of) |
   | --- | --- |
   | failing | pending (197) grew; offline uncorrectable (198) grew; reallocated (5) grew by 10 or more; a NEW NVMe critical-warning bit; NVMe media errors grew by 10 or more; NVMe available spare fell to or below its threshold (it was above) |
   | watch | reallocated grew by 1 to 9; CRC (199) grew; NVMe media errors grew by 1 to 9; NVMe available spare fell (still above the threshold); NVMe percentage used grew by 3 or more in one run |
   | healthy | none of the above |

   Absolute values are deliberately NOT judged here: `hs disk list` (disk-health.sh) and the existing health checks (`disk:<name>:pending`,
   `disk:<name>:bad`, `ssd:<dev>:wear`) keep doing that. The thresholds are constants in state-db.py (environment knobs for tests only).
4. **Hold.** A level is kept for 7 days after the run that set it, even when the next runs see no change; a higher level replaces a lower one
   at once. Without the hold the problem would disappear the next night and health-check would send "all clear" for a disk that just lost
   sectors. `hs health ack <id>` silences it earlier.
5. **First run.** A disk without a row gets one with its current values, level healthy, note `first reading`. When the table was empty at the
   start of the run (the very first run on a server), no events are written (like the inventory's silent seed); later a new disk gets an
   event `baseline`.
6. **Replaced or removed disks.** A new disk has a new serial: new row, first-run rules. A removed disk keeps its row while the inventory lists
   it as `missing` (no SMART problem is reported for a missing disk: `disk:<serial>:missing` already is); `hs disk <serial> forget` deletes the
   baseline row with the rest; rows not read for 400 days are deleted (the `smart` table's retention).
7. **Counter resets.** The whole row is taken again (event `smart-reset`, level healthy, no alarm) when the stored WWN and the read WWN are
   both known and differ (a different disk with the same serial, e.g. behind a bridge), or when the power-on hours went DOWN by more than one.
   A single counter that only ever grows (5, 199, media errors, percentage used) and went down (firmware update, controller reset) is set to
   the new value with an event `smart-reset` and no alarm. 197, 198, spare and the critical warning may go down normally (a pending sector is
   remapped, a warning clears): that is just stored.
8. **Spin-down.** Every read uses `smartctl -n standby` (through `smart_json ... standby`). A disk that is asleep is not read; only
   `last_try` changes. So that a disk that sleeps all day is still checked, a disk whose last successful reading is 6 days old or more (or
   that was never read) is read once more in the same run WITHOUT the standby flag, which wakes it. The run is in the maintenance window, where
   waking a disk is allowed. At most one wake per disk and week.
9. **Timer.** `hs-smart-baseline.service`, `startAt = "*-*-* 03:05:00"` (maintenance window; the SnapRAID sync at 03:00 has just woken the
   bulk disks), `onFailure = notifyFailure`, in `capabilities/storage/module.nix` next to `hs-state-collect`. Not `whenUnlocked`: SMART
   works on locked LUKS disks and the collector also runs while locked. The reading happens before the database transaction is opened, so
   the minutely collector is never blocked for long.
10. **How an alarm surfaces.** `state.sh problems` (already read by health-check.sh) gets:
    - `disk:<serial>:smart-failing` TAB `disk <model> (S/N <serial>) got worse since the last daily SMART check: <note>. Replace it soon. Details: hs disk <dev> health`
    - `disk:<serial>:smart-watch` TAB `disk <model> (S/N <serial>) changed since the last daily SMART check: <note>. Details: hs disk baseline`
    - `smart:stale` TAB `the daily SMART check has not run for <n> days. Check: systemctl status hs-smart-baseline` (after 2 days and 1 hour; only once the check has run at least once)

    Keys carry no numbers, so a growing count does not re-send; watch -> failing is a new key and sends. The old `disk:<serial>:worse` line
    is no longer printed for a disk that has a baseline row (the daily check owns the "changed" verdict; no double message). The
    `autoMitigate` triggers ARE extended for `disk:*:smart-failing` only (owner decision 3, scripts/health-check.sh); `smart-watch` never
    pauses anything. Push text and problem text are never translated.
11. **Machine-readable line** `hs sys state baseline` (also `hs disk baseline` in a pipe), one line per disk, tab separated, `-` for an empty
    field, columns only ever added at the end:
    `serial  dev  kind  level  level_time  last_read  first_read  wwn  realloc  pending  uncorr  crc  nv_crit  nv_media  nv_used  nv_spare  present  note`
    (`kind` HDD|SSD|NVMe, `level` healthy|watch|failing, times in epoch seconds, `present` ok|missing|unknown|- from the inventory). Order:
    failing, watch, healthy, then by dev.
    The reading line between disk-health.sh and state-db.py (`disk-health.sh --readings`) is a second, internal contract:
    `name  state  kind  serial  wwn  hours  realloc  pending  uncorr  crc  nv_crit  nv_media  nv_used  nv_spare  nv_spare_thr  model`
    (`state` read|asleep|unreadable).
12. **Commands and registry.** `hs disk baseline` (user, reads; a table for people), `hs disk baseline run` (user, changes, root; reads now and
    shows the table), `hs sys state baseline` and `hs sys state baseline-run` (sys). A smoke probe for `hs disk baseline`. The web interface
    gets the problems on the Health page with no change; a column on the Disks page and an allowlist entry `("state", "baseline")` in
    web-serve.py are a follow-up.
13. **Schema keys: none.** The schedule is fixed like the other maintenance timers, the thresholds are constants like health-check's
    `max_temp`. (Open question 1.)
14. **i18n.** The people view in state.sh uses `t`/`thead`/`status_line`; new strings go into `scripts/lib/i18n/de.tsv` (state.sh is already in
    CORE of tests/i18n.sh). Machine lines, problem texts and events stay English.

### Three views of disk health, and how they differ

| View | Question it answers | Compared with |
| --- | --- | --- |
| `hs disk list` / `hs disk <disk> health` (disk-health.sh) | Is this disk OK right now? | absolute values; counters since the last passed self-test |
| `disk:<serial>:worse` (state-db.py collect, every 15 min) | Did realloc/pending/CRC grow within 14 days? | oldest reading in 14 days; replaced by the daily check for disks that have a baseline |
| `hs disk baseline` (new, daily) | What changed since yesterday's reading? | the previous successful reading, with a 7 day hold |

### Testable without hardware, and what is not

Testable (tests/smart-baseline.sh, fake `smartctl`, `lsblk`, a fake disk-health for state-db.py, JSON fixtures in `tests/fixtures/smart/`):
the `--readings` line for an ATA HDD, an NVMe, a SAS disk, a sleeping disk and a USB disk without SMART; `-n standby` on the normal pass and
no standby flag on the wake pass; first run silent; growth -> watch/failing; problem keys; the hold and its end; counter decrease; hours
going down and WWN change -> reset; a missing disk gives no SMART problem; forget removes the row; `worse` suppressed; `smart:stale`;
the registry rows, the smoke coverage, the timer pattern in tests/maintenance-window.sh.

Not testable here, so marked "Not tested on hardware yet." until seen on the server: real smartctl JSON of the owner's disks (raw value
encodings of 5/197/198/199 differ by vendor; some Seagate firmwares pack several numbers in one raw value), `-n standby` behind the SAS HBA
and USB bridges (a SCSI disk may not report standby and wake), the weekly wake under `diskSpindownMinutes`, the SAS mapping, the time a
run takes with all disks, the systemd timer itself (`bash scripts/dev/nix-matrix.sh` only evaluates it).

## Part 2: checklist for both pools

Marks: **done** = the repository does it today (file named); **missing** = not done; **decision** = the owner chooses (Part 3).

### SMART and self-tests (every disk)

| Item | Good practice | Today | Mark |
| --- | --- | --- | --- |
| Short self-test | weekly | `hs-selftest-short` Sat 03:10, all disks (capabilities/storage/module.nix) | done |
| Long self-test | monthly; on 16+ TB disks it takes 20 to 30 hours | `hs-selftest-long` on the 1st at 03:15, all disks at once; it overlaps the next 03:00 sync and the 04:00 backup (slows them, does not break them) | decided (owner decision 4): `hs-selftest-long` now runs every night at 03:15 in ONE disk, ordered by serial (`selftest.sh long --night`); done |
| Schedule stopped | alarm | health-check `selftest:short` (14 d) / `selftest:long` (45 d) | done |
| Failed self-test | alarm | disk-health BAD -> `disk:<name>:bad` | done |
| Absolute SMART verdict | failed assessment, pending, uncorrectable = replace | disk-health.sh BAD; `disk:<name>:smart`, `disk:<name>:pending` | done |
| Change since last check | daily delta per disk, keyed by serial/WWN | 14-day `worse` for 5/197/199 only | missing (Part 1) |
| NVMe values | critical warning, media errors, spare, wear | shown and judged absolutely by disk-health.sh; wear by capacity.sh `ssd:<dev>:wear` | done (absolute); delta missing (Part 1) |
| SAS disks | grown defects, uncorrected errors | not read | missing (Part 1 maps two values; Not tested on hardware yet) |
| Polling without waking disks | `smartctl -n standby`, `hdparm -C` | monitor.sh, disk-health.sh `--list`, tests/maintenance-window.sh | done |
| Exporter polling | must not wake disks | metrics capability, smartctl exporter every 5 min; its own standby check is assumed, not seen | decision (verify on the server: `hdparm -C` stays standby across a scrape) |
| USB bridges | `-d sat` | `smart_json` fallback | done |
| smartd | optional | not used: own timers + health-check give one alarm path | done (deliberately) |
| Temperature | HDD under 45 °C sustained, alarm at 55 | `disk:<name>:temp` at 55 °C, WATCH at 55 in disk-health | done |
| Error recovery time (ERC/TLER, `smartctl -l scterc,70,70`) | set on disks in a redundant ZFS vdev so a bad sector does not stall the pool for minutes; matters less for SnapRAID | `hs-disk-erc` at boot (scripts/disk-erc.sh), only members of a ZFS mirror or raidz; disks without support are skipped with a note | done (owner decision 5) |
| Head parking (attribute 193, `hdparm -B`) | watch load cycles on drives with aggressive APM | not read, `-B` never set | missing (low priority) |

### Spin-down (bulk HDDs)

| Item | Good practice | Today | Mark |
| --- | --- | --- | --- |
| Standby timer | opt-in, only on bulk/parity/backup HDDs | `diskSpindownMinutes`, `hdparm -S` via hs-disk-spindown (scripts/disk-spindown.sh) | done |
| APM (`hdparm -B`) | 127 or lower allows standby; 255 forbids it on some drives; set only when `-S` alone is ignored | `-S` only, no `-B` fallback (documented in the notes) | decided (owner decision 6): no `-B` fallback; done |
| Maintenance window | all disk-touching jobs 03:00 to about 06:00 | table in docs/Entwicklungsnotizen.md#storage; tests/maintenance-window.sh | done; the new 03:05 timer is added to both |
| SMART polling vs. sleep | `-n standby`; read a sleeping disk at most weekly, inside the window | daily list/monitor never wake; self-tests wake on purpose | done; weekly wake of the baseline is new (Part 1, decision 8) |
| Hourly ZFS snapshots | every snapshot writes to the pool and wakes the mirror | `shareSnapshots` off by default, documented | done |

### Bulk pool, SnapRAID layout

| Item | Good practice | Today | Mark |
| --- | --- | --- | --- |
| Parity sync | daily, after a check for mass deletions | `hs-bulk-sync` 03:00 (`syncEveryHours`), refuses above 100 removed files (`max_removed`, scripts/bulk-sync.sh) | done |
| Scrub | weekly, a part of the array, so all of it within about 2 months | `hs-bulk-scrub` Sun 05:00, `scrub -p 12 -o 0` (12 % a week, oldest blocks first: the whole array in about 9 weeks) | done |
| Scrub too old / never | alarm | `bulk:scrub-old` (21 d), `bulk:scrub-never` | done |
| Scrub found errors | alarm, then `snapraid -e fix` by a person | the unit fails -> `hs-notify-failure`; no automatic fix | done (fix stays manual on purpose) |
| Content files | on several disks | system disk + every data disk (scripts/bulk-mount.sh) | done |
| Parity at least as large as the largest data disk | enforced | scripts/manage-pool.sh refuses otherwise | done |
| Second parity | from about 5 to 6 data disks | possible (`2-parity`), not suggested by any check | decision (open question 7) |
| Filesystem | ext4 `-m 0`, parity `-T largefile4`, `noatime` | scripts/manage-pool.sh, bulk-mount.sh | done |
| Sync pauses on a failing disk | do not sync over a dying disk | `autoMitigate` (opt-in) pauses on `disk:*:smart`, `disk:*:bad` and `disk:*:smart-failing`, not on `smart-watch` | done (opt-in; owner decision 3) |
| `snapraid smart` | optional failure estimate | not used | missing (low value next to Part 1) |

### Bulk pool, ZFS layout (spinning mirrors)

| Item | Good practice | Today | Mark |
| --- | --- | --- | --- |
| ashift | 12 (4K sectors), set explicitly, cannot change later | `zpool create -o ashift=12` (scripts/manage-pool.sh) | done |
| Properties | `compression=lz4`, `atime=off`, `xattr=sa` | same line | done |
| recordsize | 1M on datasets with large media files (less metadata, faster scrub) | default 128K | decision (open question 8) |
| Scrub | every 2 to 4 weeks on large HDD mirrors, weekly is fine | ZFS autoScrub Sun 05:00, no random delay | done |
| Scrub errors / old / never | alarm | health-check `zfs:<pool>:scrub-errors|scrub-old|scrub-never` | done |
| Pool state | alarm on DEGRADED/FAULTED | health-check `zpool status -x` every 15 min | done |
| ZED (ZFS event daemon) mails | optional | not configured; health-check covers it within 15 min | done (deliberately) |
| ARC limit | leave room for containers | `zfsArcMaxGB` | done |

### Fast pool (ZFS on SSD/NVMe)

| Item | Good practice | Today | Mark |
| --- | --- | --- | --- |
| ashift | 12 (13 for some NVMe with 8K pages: measure first) | 12 | done |
| TRIM | periodic `zpool trim` (or `autotrim=on`) | `services.zfs.trim.enable` (weekly) | done |
| Scrub | weekly | same autoScrub | done |
| Wear | alarm before the rated endurance is used | capacity.sh `ssd:<dev>:wear|wear-high`; disk-health WATCH at 90 % | done |
| Wear rate | a sudden jump in writes | not watched | missing (Part 1: +3 % in one day = watch) |
| Spin-down | never for SSD/NVMe | disk-spindown.sh skips them | done |

## Part 3: decisions of the owner

Decided on 2026-10-29:

1. **No switch and no tuning in machine.toml.** Always on with the storage capability; the thresholds are named constants in one place.
2. **Weekly wake: yes.** A disk that has slept for 6 days is read once at 03:05.
3. **Pause on `smart-failing`** (with `autoMitigate`): yes. Not on `smart-watch`.
4. **Long self-tests are staggered:** one disk per night, ordered by serial.
5. **ERC/TLER at boot: only on members of a ZFS mirror or raidz.** SnapRAID data and parity disks keep the default. Disks without support are skipped with a note.
6. **No `hdparm -B` fallback.** A disk that ignores `-S` gets a note, nothing is changed.
7. **Second parity: a note only** from 5 data disks, never enforced.
8. **`recordsize=1M` for media shares** on new datasets only; other shares stay at 128K.
