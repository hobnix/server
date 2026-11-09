# Runbook: the four checks only the owner can run

Four roadmap items cannot be done by a program or an assistant, because they need the real server, a real backup disk or a machine to boot
an ISO on: [#161](https://github.com/hobnix/server/issues/161), [#163](https://github.com/hobnix/server/issues/163),
[#165](https://github.com/hobnix/server/issues/165) and [#175](https://github.com/hobnix/server/issues/175). This page gives the exact
commands, what good looks like, and a template for the result of each.

**None of this has been run.** Every command below was checked to exist in this repository (`scripts/lib/registry.tsv`, the scripts and
the guides it points to), but nobody has executed these steps on hardware or in a VM, and the "expected output" lines come from reading
the scripts, not from a run. Where a line says "expect", it is the code's intent. If reality differs, that difference is the result: write
it down, do not fix the text to match. Commands that are not `hs` commands (`lsblk`, `nixos-rebuild`, `journalctl`, `incus`) are standard
tools and are named only where the guides use them or where there is no `hs` command.

How to hand in a result: fill the template, paste it as a comment on the issue, and open a pull request for every guide text that turned
out wrong. After you really worked through a guide on the server, `hs docs verified <guide>` records the date. Never enter a date for a
step that was not run.

| Check | Issue | Needs | Time | Risk |
| --- | --- | --- | --- | --- |
| [1. Auto-rollback](#1-auto-rollback-of-hs-update-161) | #161 | the real server, a second SSH session | 15 minutes plus a build | restarts services twice; the server stays reachable by SSH |
| [2. Rebuild rehearsal](#2-rebuild-rehearsal-in-a-vm-163) | #163 | a VM host, the backup disk (read-only), the passphrase | half a day | none for the server if the disk is attached read-only |
| [3. Monthly drill report](#3-first-monthly-restore-drill-report-165) | #165 | the real server, the backup disk plugged in | 30 minutes plus waiting for the timers | the drills write temporary files to `/var/tmp` |
| [4. Installer ISO](#4-boot-the-installer-iso-175) | #175 | a spare machine or a VM with UEFI | 1 to 2 hours | erases the target disk of the VM or spare machine only |

Do 3 first (it is the cheapest and shows whether the backup you rely on in check 2 is healthy), then 1, then 2, then 4.

## 1. Auto-rollback of `hs update` (#161)

Goal: see the real server switch back to the previous generation by itself, and record how long it takes and what you were told.
The safety net is described in [Operations](operations.md#update-with-a-safety-net) and implemented in `scripts/rebuild.sh`. The
repository test `tests/update-rollback.sh` covers it only with stand-ins for `nixos-rebuild`, `systemctl` and `incus`; the real switch
has never been exercised.

### Before you start
- Be at the console or have a second way in (a second SSH session is enough: the rollback keeps `sshd` running, but a service restart can
  drop the first session).
- The encrypted storage is unlocked (`hs unlock --status`); `hs update` and `hs rebuild` refuse while it is locked.
- `hs health` reports nothing. A problem that exists before the update does not count as new.
- **The update must change the built system.** If the build produces the same system, nothing is switched, and a rollback would go to the
  generation *before* the current one, which is not what you want to test. A pending upstream commit (see the preview) or a
  configuration change you want anyway is what you need.

```bash
hs update --preview
```

Expect the new commits, a diffstat and any new `machine.toml` options. If it lists nothing, wait for a real change.

### Record the starting point

```bash
sudo hs system info
```

```bash
hs health
```

Write down the repository revision and the current generation. The list of generations is also what `hs system rollback` prints first.

### How the test is provoked
`rebuild.sh` takes the list of health problems **before** the switch, then after the switch (and after `sshd` and Incus answer) looks at
the health check. A problem key that was not there before and is still there is a reason to roll back. The check ends as soon as nothing
new is left, so the new problem must exist **by the time the watch starts**, that is, while the build is running.

The harmless way to make a new problem is an entry in the expiry list that is already past. It adds the key `expiry:rollback-test:expired`
to the health check and touches nothing else:

```bash
sudo hs expiry add rollback-test 2020-01-01 test entry for the rollback check, remove it afterwards
```

Do **not** run that yet. Open a second SSH session, type the command above and leave it unsent.

### Run it

```bash
sudo hs update
```

A terminal is asked first; answer `y` when it offers to go back. (`sudo hs update --yes` goes back at once; use it if you want to see the
unattended path, which is what the nightly timer and the web interface use.)

The moment the line "Building the system and switching to it" appears, press Enter in the second session. If the build is very fast and
"Watching the health check for new problems" appears before you were ready, the entry came too late and the update will simply succeed:
remove the entry (below) and try again with the next real change.

**Expect:** after the switch, "Watching the health check for new problems (up to 5 minutes)", then a warning naming
`expiry:rollback-test:expired`, then (after your `y`) "Going back to the previous generation", then "Rolled back to the previous
generation" and a push message "update rolled back". `hs update` ends with a failure exit code on this path, which is intended.

### Check the result

```bash
sudo hs system info
```

```bash
hs health
```

The generation must be the one from before the update. `hs health` still lists the `rollback-test` entry (it is only a list entry, not
a fault of the system). Check that your push address received "update rolled back". Optionally `hs smoke`.

### Clean up (always)

```bash
sudo hs expiry remove rollback-test
```

```bash
hs expiry list
```

### Rollback and safety
- If the automatic rollback fails, the output says so and a push "ROLLBACK FAILED" is sent. By hand:

  ```bash
  sudo nixos-rebuild switch --rollback
  ```

- `hs system rollback` does the same by hand with a confirmation. Afterwards `hs rebuild` returns to the configuration in `/etc/nixos`.
- Never run the test with `--no-rollback`; that switches the net off.
- If the machine does not answer at all, use the console and the boot menu: the older generations are listed there.
- Other paths worth a second run when you have time (each needs a way to break things safely, so they are not scripted here): a
  switch that fails half way, `sshd` not running after the switch, Incus not answering. They are in the code but have no recipe for a safe
  trigger on a real server. Record "not run" for them.

### Results template (#161)

```text
Date / server:
Revision before -> after:       generation before:        generation after rollback:
hs update --preview showed:
Command used (with or without --yes):
Build time:                     time from "Watching" to "Rolled back":
Did the warning name expiry:rollback-test:expired?  yes / no
Question asked on the terminal?  yes / no (answer given:)
Push "update rolled back" arrived?  yes / no (how long after:)
Exit code of hs update:
Server reachable by SSH the whole time?  yes / no
hs health after:
Expiry entry removed?  yes / no
What differed from this runbook:
Not run (other paths):
```

## 2. Rebuild rehearsal in a VM (#163)

Goal (TODO A5): rebuild a server in a throwaway VM from **only the backup disk and the passphrase**, and record where
[Rebuild the server](backup-and-recovery.md#rebuild-the-server) does not match reality. This is the one thing that would tell you the
backup can save you.

What already exists, and what does not: `tests/rebuild-vm.sh` (`scripts/dev/t vm`) restores host files and shares from a **test**
repository into a clean Ubuntu VM and compares checksums. It does not cover the NixOS install, boot order, the vault or pools, and it
does not use your real backup disk. This runbook covers the rest. Case A of the guide is the path; the installer path
(`hs-restore`) is a second run. Both are marked "Not tested on hardware yet."

### Before you start
- A machine that can run a UEFI VM with USB or disk passthrough. Two ways, pick one:
  - An Incus host (the server itself works, but then run the rehearsal with the VM's network cut off from your real LAN; see the notes
    below), or
  - any desktop with a hypervisor of your choice. The repository does not prescribe one.
- The **backup password** from your password manager (not from the server) and the **vault passphrase** if you want to try the vault.
- The backup disk, **attached read-only** to the VM if the hypervisor allows it. The restore only reads it. Do not attach it to the
  VM while the real server is still writing a nightly backup (04:00): run it in the daytime and keep the disk unmounted on the server.
- The NixOS installer image or the Hobnix installer image (section 4). Download or build as in [Install](install.md).
- Two small empty virtual disks as the stand-in system disk and (optionally) data disks. **Name the disks only by `by-id`** and check
  with `lsblk` in the VM that you are about to erase a virtual disk.
- A copy of the repository URL the server was built from.

If the VM host is an Incus server, a VM with an ISO is created like this (verified flags, [Containers and apps](containers-and-apps.md#install-a-virtual-machine-from-an-iso-image)):

```bash
hs iso add <file-or-url> --checksum <sha256>
```

```bash
hs ct add --kind vm --name rehearsal --disk 60 --iso <name.iso>
```

```bash
hs ct rehearsal console
```

If the guest does not boot, Secure Boot may be the cause: `incus config set rehearsal security.secureboot=false`. The guide says
that hobnix does not set it for you. Attaching a physical backup disk to an Incus VM is **not** covered by an `hs` command and has not
been tried here; the safe alternative is an image copy of the backup disk on the host, attached as a second disk. Record which way you
took. **Do not boot the VM on the LAN with the old server's name and address** while the real server is running (two machines with one
`hostId`, one SSH host key and one MAC are a conflict): use an isolated network or leave the VM's network off until step 5.

### Step by step
The steps are those of Case A in [Backup and recovery](backup-and-recovery.md#case-a-the-system-disk-is-gone-the-data-disks-are-fine).
Do not paste them again here; open that guide next to this page and keep the log below. For each step record: did the command exist, did
it do what the guide says, how long did it take, and what was missing.

| Guide step | What to check | Expected |
| --- | --- | --- |
| 1. Passwords | the backup password opens the repository | `restic snapshots` lists snapshots, one tagged `host` |
| 2. Disk | partitions as written | ESP, root, a third partition labelled `vault`; `lsblk` shows them |
| 3. Repository | `git clone` of your configuration repository works | `/mnt/etc/nixos` exists |
| 4. Host files | the restore brings back `machine.toml`, `/var/lib/hs` and the SSH host keys | the files exist under `/tmp/host` and are copied |
| 5. Hardware config | generated again, no `boot.initrd.luks` block | UUIDs of the new disk |
| 6. Install | `nixos-install --no-root-passwd` ends without an error | unmount works |
| 7. Boot order | the VM boots from the new disk | login prompt or SSH on port 22 |
| 8. First boot | `ssh admin@homeserver`, `sudo hs rebuild` | the build ends; storage is locked |
| 9. Vault | `sudo hs vault init /dev/disk/by-partlabel/vault`, password put back | `hs vault status` shows an open vault |
| 10. Pools | with virtual data disks: import or create | `hs pool bulk` is happy |
| 11. Containers | `sudo incus admin recover`, `hs ct list` | instances listed (only if you attached the pool) |
| 12. Finish | `hs first-run`, `hs doctor`, `hs health` | green, or a list of what is open |

After step 12:

```bash
sudo hs unlock
```

```bash
hs doctor
```

```bash
hs health
```

Then Case B on the empty virtual data disks: `sudo hs pool bulk add`, then `sudo hs backup restore latest /bulk/shares --to /`,
`sudo hs backup restore latest /bulk/sensitive --to /`, `sudo hs share repair`. Compare checksums: on the **real** server (the backup
is a snapshot, so choose three files that did not change) and in the VM:

```bash
sha256sum <file>
```

Finally `sudo hs backup now` and `sudo hs backup drill` inside the VM: it must back up to **a different repository path or a copy**,
never to the real backup disk. If the disk is read-only this fails on purpose; record that and stop there.

### Second run: the installer path
Boot the VM from the installer image with the backup disk attached and run (see [Restore from a backup](install.md#restore-from-a-backup)):

```bash
sudo hs-restore --dry-run
```

Expect the disk labelled `backup` mounted **read-only**, the password asked without echo, a list of host snapshots, and a plan that names
the system disk to be erased, the server name, role, time zone and SSH key from the restored `machine.toml`, and no `restic-password`.
Then the real run (it asks for the **name of the system disk**; unattended it needs `--disk <name> --confirm-disk <same name>`):

```bash
sudo hs-restore
```

The checklist in that guide section is the list of things to tick.

### Rollback and safety
- The only erased disk is the virtual system disk. The backup disk is mounted read-only and refused as a target by the installer; check
  `findmnt` shows `ro` before you continue.
- Delete the VM and its disks when you are done. If you copied the backup disk or its image, delete the copy: it contains your data and
  the restic repository (encrypted, but still).
- Do not type the backup password into a place that logs it (a shared terminal, a chat). Use `--password-file` on a RAM-disk file
  in the VM, or type it.
- If the rehearsal shows the guide is wrong, send a pull request with the fix and keep the entry here.

### Results template (#163)

```text
Date / VM host / hypervisor:
Backup disk attached how (read-only? image copy?):
Backup snapshot used (id, date, tags):
Per step 1-12: ok / differs / failed, minutes, note:
  1:   2:   3:   4:   5:   6:
  7:   8:   9:  10:  11:  12:
Case B: pool created? shares restored? checksums equal for N of N files:
hs doctor / hs health at the end:
hs-restore --dry-run: disk found? read-only? snapshots listed? plan correct?
hs-restore real run: finished? boot ok? SSH without host-key warning?
Total time from empty VM to a working server:
What the guide says that is wrong or missing (list, one line each):
Pull requests opened for the fixes:
Guides worked through (for hs docs verified):
Left over and deleted? (VM, disks, image copy)  yes / no
```

## 3. First monthly restore-drill report (#165)

Goal: see the first real monthly report, and record whether the drills it summarises really ran and whether the message is useful. The
drills and the report exist ([Backup and recovery](backup-and-recovery.md#check-that-restoring-works), `scripts/backup.sh`) and are
covered by `tests/backup-report.sh`; they have not run on the server.

### Before you start
- A backup disk is set up and the nightly backup has run at least once: `hs backup status`.
- `/var/lib/hs/restic-password` exists (the drill timers and the report only run then).
- Free space in `/var/tmp` of about twice the size of the largest container for `drill ct` (`HS_DRILL_TMP` changes the place).
- A push address, so the message arrives (`hs config set notifications true`; [Operations](operations.md#get-push-messages)).

### Run what the timers would run

```bash
hs backup status
```

```bash
sudo hs backup drill
```

Expect five files restored and compared, ending equal. It sets `drill_ok` in `/var/lib/hs/backup.state`.

```bash
sudo hs backup drill ct
```

This one is long (a container restore, boot and delete) and asks to run as a background job; `hs job follow <unit>` follows it. Expect a
throwaway `hs-drill-*` instance without a network that starts and is deleted, a check of the domain controller backup file, and one VM
checked if a VM is in the backup. It sets `drill_ct_ok`, `drill_ct_name` and `drill_dc_ok`. A failure is a **result**, not something to
retry away: save the output.

Prove that no drill instance is left behind:

```bash
hs ct list
```

No instance named `hs-drill-*` may be listed.

### Read the report without sending it, then send it

```bash
sudo hs backup report --dry-run
```

Expect a title line with the priority, one line per check (backup, file drill, container drill, VM drill, domain controller backup file,
off-site copy, disk fullness, "Guides checked on the server: N of M"), and the closing "(dry run, nothing sent)". Everything fine reads
"restore drills are fine (low)"; an overdue item makes it "N thing(s) to look at (high)" and the line starts with `!`.

```bash
sudo hs backup report
```

Check the push message arrived with the same text. Then look at what the timers do by themselves. They run on the 15th (file drill,
05:30), the 22nd (container drill, 05:30) and the 25th (report, 08:00):

```bash
systemctl list-timers 'hs-backup-*'
```

```bash
journalctl -u hs-backup-report -u hs-backup-drill -u hs-backup-drill-ct
```

The real **first monthly** report is the one of the next 25th. Do not call #165 done on a manual run: record the manual result now and
the timer result after the 25th.

If a guide was worked through on the server in the meantime, record it:

```bash
hs docs verified <guide>
```

### Rollback and safety
- The drills never write to the real shares: the file drill restores to a temporary folder, the container drill to a throwaway instance
  that is deleted (also on Ctrl+C or a failure). If one is left behind after a crash, `hs ct list` shows it; the next run sweeps it.
- `hs backup report` only reads `backup.state` and sends one message. It touches no disk and no restic.
- Empty `/var/tmp` leftovers only after you looked at them.

### Results template (#165)

```text
Date / server:
hs backup status: last backup, snapshots, disk fullness:
File drill: ran? equal files N of N? time:
Container drill: ran? which container? booted? time? output saved?
VM / domain controller checks: what was reported:
Leftover hs-drill-* instance?  yes / no
backup report --dry-run text (paste):
Push message arrived?  yes / no; same text?  yes / no; priority:
Timers (list-timers output): next run of each:
After the 15th / 22nd / 25th (fill in later): did the timers run? journal status? report message (paste):
Was the report understandable and useful?  what to change:
```

## 4. Boot the installer ISO (#175)

Goal: boot `homeserver-installer.iso` once, on real hardware or in a VM, and write down every place where it breaks or surprises.
[Install, option A](install.md#option-a-the-installer-image) and `installer/iso.nix` describe it; the wizard is `scripts/install-wizard.sh`.
CI only **evaluates** the ISO configuration and builds it on a release tag; no one has booted it. Everything in the install guide that
depends on it is marked "Not tested on hardware yet."

### Before you start
- The image: download `homeserver-installer.iso` from a release of the server repository (check that one exists), or build it on a machine
  with Nix:

  ```bash
  bash scripts/dev/build-iso.sh --eval
  ```

  `--eval` only proves the configuration is sound. The real build:

  ```bash
  bash scripts/dev/build-iso.sh
  ```

  The script writes the image under `result-iso/iso/`; the comment at the top of the script says `result/`, which is a difference to note
  in the results. Record the file size and `sha256sum` of the image.
- **UEFI is required** (a BIOS-only machine only works for the role `edge`). A VM must have UEFI firmware. If it refuses to boot, switch
  Secure Boot off (for an Incus VM: `incus config set <name> security.secureboot=false`).
- A target disk of **at least** the size of a minimal NixOS install (the guide gives no figure: record what you used) that you may erase,
  and a second disk (a virtual one is fine) to prove it stays untouched.
- On a real machine: a USB stick you may erase. Writing the image to a stick **erases the stick**; name the right device (`lsblk` first):

  ```bash
  lsblk -o NAME,SIZE,MODEL,TRAN
  ```

  ```bash
  sudo dd if=<image.iso> of=/dev/<stick> bs=4M status=progress conv=fsync
  ```

- Your public SSH key in a file, to give to `--key-file`.

### Boot and run

1. Boot from the image in UEFI mode. In a VM on an Incus server, `hs iso add <file> --checksum <sha256>`, then
   `hs ct add --kind vm --name isotest --disk 40 --iso <name.iso>` and `hs ct isotest console` (leave with Ctrl+a q).
2. At the console, look at what you got: the banner says `hs-install` and `hs-restore` exist. Note anything else.
3. Dry run first. It changes nothing:

   ```bash
   sudo hs-install --dry-run
   ```

   Expect the questions (system disk, server name, SSH key, time zone, preset) and then the plan. Check that the **stick or the CD is not
   offered** as a target and that the data disk is listed but not selected.
4. A **wrong confirmation must cancel**: type a name that is not the disk's. Nothing may be erased.
5. The real run. **This erases the one disk you name and type.** Unattended form, to test the options:

   ```bash
   sudo hs-install --disk <name> --confirm-disk <same name> --hostname isotest --key-file <file> --timezone Europe/Vienna --preset minimal
   ```

6. When it says it is done, shut down and remove the image, **in a separate step** (the repository rule: never a reboot in the same
   block as the step before it). Then boot from the disk.
7. After the boot:

   ```bash
   ssh adminuser@isotest
   ```

   Expect the login by key only. Then follow [First start](install.md#first-start): `hs doctor`, `hs health`, `hs first-run`, and
   `sudo hs rebuild` with the installed configuration. Note how long the first build takes and whether it needs the network.

### Things to watch for (write each down, even if fine)
- Does the image boot at all in UEFI mode? On which hardware or hypervisor?
- Is the network up without help (DHCP)? Does name resolution work during the install?
- Is the target disk listed with a sensible name and size? Is the `by-id` name shown?
- Does the install finish without internet, or does it need it (and what for)?
- Is the second disk untouched afterwards (`lsblk`, `blkid`)?
- Does `machine.toml` hold a generated `hostId`, the host name, the time zone and the preset?
- Do the firmware boot entry and the boot order work after the install?
- The install guide says "adminuser" in some places and "admin" in the recovery guide: which user exists, and which does the SSH key belong to?
- Anything on the console that is cut off, unreadable (colours, no `gum`), or asks for something the guide does not mention.

### Rollback and safety
- The only data lost is the target disk (and the USB stick when you write the image to it). Use a VM or a spare machine, never the real
  server: the wizard only runs from the stick (it refuses when nothing is mounted at `/iso`), but pointing it at the wrong disk is your
  risk. Name the disk by size and model, and check `lsblk` twice.
- A failed install leaves a half-written disk: wipe it in the VM or re-run the install on it. Nothing else is changed.
- Delete the VM, its disks and the image copy afterwards: `hs ct isotest remove` for an Incus VM (asks for the name).
- Do not put a real password into the test machine's `machine.toml`; the wizard asks for the password of `adminuser`, use a throwaway.

### Results template (#175)

```text
Date / hardware or hypervisor / UEFI? Secure Boot on or off:
Image: where from (release / built), size, sha256:
build-iso.sh --eval OK?  build OK?  (path of the image:)
Booted?  yes / no; how long to the console:
Network at boot (DHCP ok?):
hs-install --dry-run: questions as in the guide? target disks listed correctly? stick excluded?
Wrong confirmation cancels?  yes / no
Real run: command used, finished?  yes / no; time:  error text (paste):
Second disk untouched?  yes / no
After boot: SSH by key ok? host name ok? hs doctor / hs health output:
sudo hs rebuild on the installed system: ok? time? needed network?
hs-restore (if tried; see section 2):
Every difference from install.md (one line each):
Anything unreadable or confusing on the console:
Pull requests / issues opened:
Left over and deleted? (VM, disks, stick)  yes / no
```

## After all four
- Comment on each issue with the filled template. Do not close an issue from this page; closing is the owner's decision after reading
  the result.
- Open pull requests for text that was wrong, and record the date of each guide you worked through with `hs docs verified <guide>`.
- Remove the line "Not tested on hardware yet." only from steps you saw work.
