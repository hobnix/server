# 0002: Declarative system state and dynamic runtime state

Status: Proposed
Issue: hobnix/server#252 (epic #121)

## Context

- A NixOS rebuild (`hs rebuild`) is the only way to change the declarative system. It evaluates the whole configuration and can take minutes,
  so a setting that needs one feels slow when it is toggled in the web interface.
- The split already exists in the code, but it is not written down as a rule. `config/schema.toml` gives every option a `store`:
  `machine` (default; `machine.toml`, Nix reads it, a change needs `hs rebuild`) or `settings` (one file in `/var/lib/hs/settings/`, scripts
  read it at run time through `scripts/lib/setting.sh`, no rebuild). Counted on 2026-11-04: 93 options, 63 `machine`, 30 `settings`.
- `scripts/config-change.sh` already ends a plan with a note: "takes effect with hs rebuild" or "takes effect at once; no rebuild is needed".
- Instances (Incus containers, Docker apps), jobs (transient systemd units), `/var/lib/hs` state and package installs for packages without a
  Nix module (`hs pkg`) already change without a rebuild.

## Decision

1. **Two classes.** Declarative system state is everything a NixOS module reads: kernel and boot, hardware, network, firewall, users, system
   services and their unit files, installed system packages. Runtime state is everything else: containers and VMs, apps, jobs, shares'
   contents, files in `/var/lib/hs`, database rows.
2. **The schema is the classification.** Each option in `config/schema.toml` is in exactly one class: `store = "machine"` is declarative,
   `store = "settings"` is runtime. No third class; "restart a service" is runtime if a script can do it, declarative if a unit file changes.
3. **A runtime option is never read by Nix.** It does not appear in a `.nix` file (the generated `config/defaults.nix` excepted). A test enforces
   this, so a runtime option cannot silently start needing a rebuild.
4. **Say it before applying.** Every plan for a change (`hs sys config ... plan`, and the pages built on it) states which class the change is
   in. Wording is fixed: "takes effect at once" or "takes effect with hs rebuild". The web interface shows the same sentence before the
   Apply button.
5. **Prefer runtime.** A new option is `settings` unless Nix has to read it. If a unit only needs a value at start, the unit reads it from the
   settings file, not from the Nix expression.
6. **Runtime state is not lost by a rebuild,** and a rebuild does not need runtime state to be set again. State under `/var/lib/hs` is the
   contract; a rebuild only changes the declarative side.

## Consequences

- Easier: the rule has one source (the schema), the CLI note already exists, and a reviewer can check a new option against rule 5.
- Harder: moving an option from `machine` to `settings` changes where its value lives (migration through the `legacy` field) and needs a
  script that applies it live.
- Candidates to move, from reading `capabilities/*/module.nix` on 2026-11-04, none evaluated yet: `diskSpindownMinutes` (a script,
  `scripts/disk-spindown.sh`, already does the work), `shareSnapshots` and `syncEveryHours` (timers), `metricsDays` and `metricsMaxGB`
  (Prometheus flags, would need a restart). Not candidates: `hostName`, `nic`, `vlans`, `smbAllow` (Samba configuration), `zfsArcMaxGB`
  (boot parameter), the gateway options (unit files).
- Follow-up work, not done by this record:
  - a test for rule 3 (`tests/schema.sh`);
  - the web interface shows the sentence of rule 4 before Apply (check which pages already do);
  - a rebuild duration estimate (nothing measures it today);
  - move at least one candidate, or record per candidate why it cannot move.

## Open points

- How long a rebuild takes is not measured. The "roughly how long" the issue asks for needs real timings from a server; the binary cache
  (#253) changes them.
- Whether a `settings` option that a unit reads at start should restart the unit by itself or leave that to the user.
