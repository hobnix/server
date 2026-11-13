# Plan: from the ISO to the first dashboard

**Status: Accepted 2026-11-13.** The owner accepted the recommendation of every decision below (1A, 2, 3, 4, 5, 6, 7); no question is open.

Design for the epic [#173](https://github.com/hobnix/server/issues/173) (Installation and Onboarding, milestone 0.4): someone who does not
know NixOS boots the stick, installs, opens a web page, sets the first password and lands on a dashboard with the first choices made. This
page decides what to keep, what to rework and in which order to build it. It changes no behaviour. **Nothing here was run on hardware or in a
VM. Not tested on hardware yet.** Read together with [Install](install.md), ADR 0022 (`docs/adr/0022-first-run-console-token.md`) (the token),
ADR 0023 (`docs/adr/0023-nested-test-harness.md`) (the nested test harness), [THREAT-MODEL-web](THREAT-MODEL-web.md) and
[PLAN-hardware-runbook](PLAN-hardware-runbook.md).

## Before you start
- The rules that stay fixed: admin pages are never public; secrets are read only through `scripts/lib/secret.sh`; a destructive step shows
  a plan first and makes the person type the NAME of the disk; terminal output goes through `scripts/lib/ui.sh`; machine-readable `hs sys`
  lines do not change shape.
- [#459](https://github.com/hobnix/server/issues/459): no pool name (`bulk`, `fast`) and no node name (`homeserver`) may be hard-coded in
  anything new here. The wizard asks for names or reads them from data.
- [#217](https://github.com/hobnix/server/issues/217): the "choose capabilities" step is only as good as capability packaging. Until #217
  lands, the wizard offers the capabilities that exist in `capabilities/` and the presets; it does not pretend to install packages.

## What exists today (checked 2026-11-13 on 0.4)

| Part | State | Verdict |
| --- | --- | --- |
| `installer/iso.nix` (minimal installer image, repo copy in `/etc/hs-installer`, `hs-install`, `hs-restore`, serial console) | CI evaluates it on every push and builds it on a `v*` tag. **Never booted.** | **Keep.** Add the boot-time pieces below. |
| `scripts/install-wizard.sh` (`hs-install`) | Erases one disk (typed name or `--confirm-disk`), refuses without `/iso`, writes `machine.toml`, applies a preset, runs `nixos-install` with `install.nix`, git checkout of the repository. Takes every answer as an option. Tests with `HS_INSTALL_SKIP_DISK=1`. | **Keep the core, rework three things:** it asks for no network check, it never looks at the other disks, and it ends with "ssh in", not "open the page". |
| `install.nix` (minimal system after install) | DHCP on any card, SSH for `adminuser`. **No web interface, no setup code.** | **Rework.** This is the gap between "installed" and "first dashboard". |
| ADR 0022 + `scripts/first_run.py` + `scripts/setup-code.sh` + `POST /api/setup` + `Login.svelte` "First setup" | Server part built and tested (`tests/first-run.sh`). The record names the missing parts: boot unit and installer hook. | **Keep as decided.** Build the missing parts (#183). |
| `scripts/first-run.sh` (`hs first-run`) + `scripts/setup-list.sh` | Terminal: language, notify address, core packages, checklist. Fixed pool name in two places: `first-run.sh` tests `mountpoint -q /bulk` and `ls /bulk/shares`; `setup-list.sh` reads `$HS_SETUP_BULK` (default `/bulk`), hints `hs pool bulk add` and links `/storage/pools/bulk`. | **Rework** the checklist to read pools from data (#459); keep the command. |
| `web/src/ui/Wizard.svelte` | One question per screen frame (progress bar, back, primary button). Used by the Settings wizards declared in `config/schema.toml`. Knows no capability. | **Keep as the frame.** The first-run wizard is a page that uses it. |
| `hs preset list\|show\|apply` | Fills only what is not set, plan first, never overwrites. `minimal`, `edge`, `example-server`. | **Keep.** The wizard's "what is this server for" step is a preset (later a blueprint, [#495](https://github.com/hobnix/server/issues/495)). |
| `scripts/net-nics.sh` (`hs sys net nics`) | Physical cards with link and MAC, for the Network settings wizard. | **Reuse** for the network step. |
| `hs disk list`, `hs sys pool disks`, `hs pool <pool> add` | Disk health, the disks the interface offers, pool creation (filesystem and encryption asked). | **Reuse** for storage discovery. Adoption of existing data is new. |
| `scripts/dev/nested.sh` (ADR 0023) | Boots the ISO in a nested Incus VM, runs an unattended `hs-install`, boots the result. **Never run.** | **This is #175's tool.** |

## The flow

```
 1 boot the stick          console shows: "hs-install" and a one-line network state
 2 hs-install (terminal)   network check -> disk list -> plan -> type the disk NAME -> install
 3 reboot, first boot      console banner: address + one-time code (issued by a boot unit)
 4 browser on the LAN      http://<name>.local:8480  ->  "First setup": code + new password
 5 first-run wizard (web)  language -> network confirm -> storage -> "what is this for" (preset) -> notifications
 6 dashboard               the checklist (`setup-list`) shows what is still open
```

Steps 1 to 3 are the terminal, because there is no web page before an installed system exists. Steps 4 to 6 are the web, because the owner
should not need SSH. SSH with the key stays as the second way in (the key is already asked in step 2).

### Step 2: network check before anything is erased
`hs-install` reads the route it runs on today and trusts it. Add, before the disk question:
1. Show the cards (`ip -o link`, same data as `hs sys net nics`), the address and the default route.
2. Check: link up, an address, a default route, DNS (`getent hosts` of the git origin), and the time (a wrong clock breaks TLS and signature checks).
3. On failure say which one and what to do (cable, DHCP on the router, a fixed address). Offer to continue offline: `nixos-install` needs the
   binary cache (ADR 0003 (`docs/adr/0003-binary-cache.md`)), so offline is allowed only when the closure is on the stick (see option A below).
Result: a fixed `nic` and `smbAllow` written the way it is today, and a **validation line** the later web step can repeat.

Wi-Fi: not supported for the install (a server uses a cable). The check says so in one line if the only card is wireless.

### Step 3 and 4: the one-time token (ADR 0022 stays)
- Boot unit `hs-setup-code.service` in `install.nix` (and the full configuration): `ConditionPathExists=` the flag file, runs
  `hs setup-code issue` only while the flag is `pending`, `StandardOutput=tty`, `TTYPath=/dev/console` (also on `ttyS0`). The banner shows the
  address (`<hostName>.local` and the IP) next to the code. Never `/etc/issue`, never the journal (ADR 0022 rule 3 (`docs/adr/0022-first-run-console-token.md`)).
- The installer creates the flag as its last step (`first-run.json`, `pending`). An upgraded server has no flag, so it never sees the wizard (rule 1).
- Threat model: unchanged from ADR 0022 (100-bit code, 60 min, burn counter, LAN only, plain HTTP limit accepted by the owner on 2026-11-10).
  The wizard after the password uses the normal session, CSRF and the existing `CHANGES` allowlist: it adds **no new unauthenticated route**
  except what ADR 0022 already has. Admin pages are not made public by any of it: the web interface is LAN/Tailscale only.
- Secrets: the new password goes on stdin to `chpasswd` (already built). The wizard never asks for a key or token that `scripts/lib/secret.sh` would have to hold.

### Step 5: the wizard pages
Each step is a plan and start through the existing `plan`/`start` API, so a step shows what it changes before it does it and can be repeated
from Settings later. The frame is `Wizard.svelte`; the steps are declared as data like the Settings wizards (`[[page.steps]]`), not hand-built per page.

| Step | Asks | Writes | Skippable |
| --- | --- | --- | --- |
| Language and name | web language, server name check | `language` (runtime setting), `hostName` shown, not changed (a rename needs a rebuild) | yes |
| Network | confirms the card and address the installer found; repeats the validation line | `nic`, `smbAllow` only if the person changes them | yes |
| Storage | the disks found, what is on them, adopt or create (below) | nothing until the plan is confirmed | yes ("later") |
| What is this server for | a preset (`hs preset list`); capabilities that need #217 are listed greyed with "later" | `hs preset apply <name>` | yes (`minimal`) |
| Notifications | an ntfy-style address, optional test message | `notifyUrl` is a secret setting that the web cannot set today (`settable = no`, and `hs first-run` passes it on argv): the step is **terminal-only until the schema marks it settable and the address goes on stdin through `secret.sh`**; the web step shows the state and the command | yes |

The terminal `hs first-run` stays, same questions, for people who prefer SSH. Both call the same `hs config set`.

### Storage discovery and adoption (#181)
Rules from the project: destructive commands show a plan and make the person type the NAME of the thing that changes (the disk, not the pool).
1. **Discover (read only):** every disk except the system disk and the stick, with size, bus, model, health (`hs disk list`), and what is on
   it: ZFS pool members (`zpool import` without importing), LUKS, other filesystems, SnapRAID data/parity labels, empty. One new `hs sys` read
   (`hs sys storage discover`, rows: disk, size, kind, label, state; `-` for an empty field) so the web page and the terminal show the same thing. Being a `sys` row it needs a registry row, a smoke probe if it is `reads`, `docs/api/sys.toml`, and the regenerated openapi and TypeScript types (`openapi-gen.py`, `openapi-ts-gen.py`).
2. **Classify:** *empty* (free to use), *known Hobnix data* (a pool or array this software made: adopt), *foreign data* (something else: only
   shown, never touched by the wizard; the person wipes it from the disk page, with the typed name).
3. **Adopt:** a known pool is imported under **its own name** (`zpool import <name>`); no assumption that it is called `bulk`. An existing
   SnapRAID array is read from its config. Adoption changes nothing on the disks. It shows the plan (pool name, mountpoint, what Hobnix will
   create inside) and needs one confirmation.
4. **Create:** an empty disk goes through the existing `hs pool <name> add` flow (filesystem, encryption asked). The pool name is asked, with a
   suggestion, and validated; any number of pools and any name (#459). Wiping a disk that has data needs the typed disk name, a plan first, and
   offers a background job.
5. **Nothing to do** is a valid answer: a single-disk install with no extra disks says what is missing ("no storage pool yet; shares need one") and continues ([#459](https://github.com/hobnix/server/issues/459) done-when).

## What can be tested where

| What | In the repo's test lab (no hardware) | Needs real hardware or a person |
| --- | --- | --- |
| `hs-install` logic, answers, machine.toml, preset | `tests/install-wizard.sh` (`HS_INSTALL_SKIP_DISK=1`) | partitioning on a real disk, NVMe naming, BIOS vs UEFI quirks |
| Network check functions | unit tests with a fake `ip`/`getent` (pattern of `HS_SYS_NET`) | a real router, no-DHCP networks, a dead cable |
| Token, flag, `/api/setup`, throttle | `tests/first-run.sh`, `tests/web-login*` | the banner on a real screen and a real serial port |
| Boot unit prints code only on tty | a NixOS VM test or the nested harness: boot, read the console log, assert the code is **not** in the journal | a display attached to a server |
| ISO boots, installs, reboots | `scripts/dev/nested.sh run` (nested Incus VM, `--stage iso` then `smoke`); needs KVM and nested virtualization; CI: manual workflow `nested` | a real UEFI/BIOS box, USB stick writing, vendor firmware |
| Storage discovery | parsers with fixture output (`zpool import`, `lsblk`, `blkid`); loop-device root tests (`t root`) for create and wipe | real disks, SMART, hot-plug, ZFS import of a pool from another machine |
| Wizard pages | Svelte tests in plain node (`steps.js` pattern) and a browser run against `web-serve.py` | a phone on the LAN, mDNS (`<name>.local`) on the owner's router |
| The whole path, once | the nested harness end to end plus a scripted browser | the owner's run of [#175](https://github.com/hobnix/server/issues/175) on a real machine, written down |

Rule: every doc line for a step that only the lab ran says "Tested in a VM only", every line nobody ran says "Not tested on hardware yet."

## Decisions for the owner (all accepted 2026-11-13 as recommended)

1. **Is the web interface part of the minimal installed system?** (the biggest one)
   - **A (recommended):** `install.nix` includes `hs-web` and the setup unit, fetched from the binary cache during `nixos-install`. First
     dashboard needs no console rebuild. Cost: a longer install and a network needed at install time (checked in step 2). The ISO stays small.
   - B: put the closure on the stick. Offline install works; the ISO grows by the web package and its dependencies, and every release rebuilds it.
   - C: keep today's flow (install, SSH in, `hs config set webUi true`, `hs rebuild`, then the code). Nothing to build, but the promise
     "no NixOS knowledge needed" is not kept.
2. **Where does the token banner appear?** Recommended: console and serial only, as ADR 0022 says, plus the address. Alternative: also a QR code
   on the console. A QR is convenient on a phone, still not logged; add later if wanted.
3. **How does the person find the server?** mDNS is only enabled by the `samba` capability module, not by `install.nix`, so `<name>.local` does not resolve on the minimal system. Recommended: add avahi to `install.nix` (small) and print `<hostName>.local` plus the IP in the banner. Alternative: the IP only.
   If mDNS is unreliable on the owner's network the IP is the fallback; no cloud relay is built.
4. **Network step: fixed address in the wizard?** Recommended: DHCP only in 0.4, with the advice "reserve the address on your router";
   a static-address form comes later. Reason: a wrong static address on a headless box locks the owner out, and there is no rollback yet.
5. **Storage step scope in 0.4.** Recommended: discover + adopt known ZFS pools + create on empty disks. SnapRAID adoption is read and shown
   (not changed) and moves to 0.5 unless the owner wants it now. Wiping foreign data stays on the disk page, not in the wizard.
6. **Wizard re-entry.** Recommended: after `done` the wizard is gone; every step is reachable in Settings, and "Setup" on the dashboard lists
   what is open. `hs setup-code reset` stays console only (ADR 0022).
7. **Capabilities step before #217.** Recommended: ship the step with presets only and hide per-capability choices until #217; avoids a wizard that must be rebuilt.

## Check that it worked
- The plan is accepted when each sub-issue below has scope and acceptance criteria and the epic's Review boxes are ticked.
- `scripts/dev/nested.sh plan` lists the steps the harness will run; `python3 scripts/pkg.py validate` and `scripts/dev/t quick docs` pass.

## Work breakdown

| Issue | Scope | Depends on |
| --- | --- | --- |
| [#175](https://github.com/hobnix/server/issues/175) Boot the ISO, record what breaks | Run the nested harness, then one real box; write findings into the runbook; each break becomes an issue | none; first |
| [#179](https://github.com/hobnix/server/issues/179) Network setup and validation | Step 2 check in `hs-install`, a repeatable validation read, the web Network step | #175 findings |
| [#181](https://github.com/hobnix/server/issues/181) Storage discovery and adoption | `hs sys storage discover`, classify, adopt, create, typed-name wipe | #459 (names), none for discovery |
| [#183](https://github.com/hobnix/server/issues/183) First-run web wizard with token | Boot unit, installer flag, minimal system serves the web (decision 1), wizard pages, banner | decision 1; wizard steps need #179 and #181 |

New sub-issues: [#580](https://github.com/hobnix/server/issues/580) (minimal system serves the web interface) and [#581](https://github.com/hobnix/server/issues/581) (checklist without fixed pool names).
