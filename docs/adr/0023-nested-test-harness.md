# 0023: Hobnix-in-Hobnix test harness: nested instances from the ISO

Status: Accepted (2026-11-10)
Issue: hobnix/server#262 (part of #199). Builds on #185 (answers file format), #163 / TODO A5 (rebuild rehearsal) and #175 (ISO boot check).

**UNVERIFIED.** Nothing in this record or in the harness has been run against a real VM: the machine it was written on has no nix, docker,
incus or KVM. What was run: the logic tests (`tests/nested.sh`) with a fake console and a fake `incus`.

## Context (checked 2026-11-08 on develop)

- `tests/zfs-vm.sh` and `tests/rebuild-vm.sh` start Ubuntu VMs with `incus launch images:ubuntu/24.04 --vm` and drive them with `incus exec`.
  They test our scripts on a stock distribution, not the installer ISO and not a NixOS system we installed. `scripts/dev/t vm` runs them.
- `installer/iso.nix` builds the ISO (`scripts/dev/build-iso.sh`); CI builds it only on a `v*` tag (job `iso`) and evaluates it otherwise.
  It already puts the console on `ttyS0`, "so `incus console` of a test VM shows the installer".
- `hs-install` takes every answer as an option (`--role --disk --confirm-disk --hostname --key --preset`, `HS_INSTALL_PASSWORD`). The answers
  file (#185) is specified and checked (`hs installer check-answers`) but `hs-install` does not read it yet.
- The NixOS installer image has no Incus agent, so `incus exec` does not work on it. The serial console is the only channel before the
  system is installed.

## Decision

1. **The harness is a dev tool, not a `hs` command.** `scripts/dev/nested.sh` (bash: Incus calls, cleanup, exit codes, logs) and
   `scripts/dev/nested_lib.py` (everything testable without a VM). No registry row is needed (the registry lists `scripts/*.sh`).
2. **One command, clear exit codes:** `scripts/dev/nested.sh run [--iso f] [--stage iso|smoke|all] [--keep]`. Exit 0 passed, 1 a check
   failed, 2 usage, 3 this machine cannot run it, 4 harness or Incus error. Logs in `.work/nested/<run-id>/` (`run.log`,
   `console-<stage>.log`, `result-<stage>.json`, `latest` symlink).
3. **Incus VM with the ISO as a boot disk.** `incus init --empty --vm` with secure boot off, a 20 GiB root disk, the ISO attached as a
   disk device with `boot.priority=10`. This is what the VM wizard does for an ISO from the library (#259), done by hand so the harness
   does not depend on the web interface.
4. **Driven over the serial console, expect-style.** `incus console` on a pty; the driver waits for a prompt, then runs commands with a
   unique marker (`__HSN<n>__ rc=$?`) to get the exit code. The scenario is data (`build_scenario`) so it can be reviewed and tested.
5. **Two stages.** `iso`: boot check (#175: reaches the shell, `hs-install` and the repository copy are on the image, a disk is visible),
   unattended `hs-install` with options, power off. The harness then detaches the ISO. `smoke`: boots the installed system, logs in as
   `adminuser`, checks hostname, `/etc/nixos`, `systemctl is-system-running` (running or degraded).
6. **Secrets:** a throwaway password and ed25519 key per run, in `.work/nested/<run>/` (mode 600). The password reaches the driver only
   through its environment and is removed from every log (`Redactor`); it is typed on the console of a VM that is deleted afterwards.
   The CI artifact leaves the password and key files out.
7. **Limits, stated:** nested virtualization must be on in the host (preflight checks `/dev/kvm`, the `kvm_intel`/`kvm_amd` `nested`
   parameter, `incus`, `ssh-keygen`). Without it the harness exits 3 and the existing `scripts/dev/t vm` is the fallback (it needs a
   machine with Incus, not a nested one). It is not part of `t quick`, `t root` or `t vm`.
8. **CI:** `.github/workflows/nested.yml`, `workflow_dispatch` only, takes an ISO URL (a release asset). It runs the logic tests, runs
   the preflight and ends with a notice when the runner has no nested virtualization. It gates nothing until someone has seen it pass.
9. **The logic tests run everywhere:** `tests/nested.sh` (a normal quick test, so CI runs it) uses a fake transport and a fake `incus`
   that behaves like the ISO shell and the installed system, and checks exit codes, redaction, cleanup and that a failed step stops the run.

## Consequences

- Easier: an agent or a person can say "does the current ISO install and boot" with one command and read a result file.
- Harder: console scraping is brittle against prompt changes (`PROMPT_ISO`, the login prompt) and slow (an install is minutes to tens of
  minutes). The first real run will find problems nobody could see here.
- The first real run is the acceptance test of this record. Until then the status stays Proposed.

## Open points

- **Rebuild rehearsal (#163) on the nested instance is not implemented.** `tests/rebuild-vm.sh` stays on the Ubuntu VMs. It becomes a third stage
  (`rehearse`: seed shares, back up to a second disk, install a second VM from the ISO, `hs-restore`) once the `iso` stage is seen to work.
- **Capability installs and `hs rebuild` inside the nested system** need a reachable network and the binary cache (ADR 0003); not covered.
- **Answers file instead of options** when `hs-install` reads it (#185 follow-up).
- **Building the ISO in the CI job** (needs nix on the runner, as job `iso` does); today the job takes an ISO URL.
- **A faster channel than the serial console:** `virtualisation.incus.agent` in `installer/iso.nix` would allow `incus exec` on the ISO. Not
  changed here: the ISO cannot be built on the machine this was written on.
