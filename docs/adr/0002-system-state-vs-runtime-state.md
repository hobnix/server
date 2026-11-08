# 0002: Declarative system state and dynamic runtime state

Status: Accepted (2026-11-08)
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
- Follow-up work (status after acceptance, see "Accepted 2026-11-08" below): the test for rule 3 is done (`tests/schema.sh`), the sentence of
  rule 4 and the duration are done (`tests/apply-effect.sh`), candidates to move are recorded per option.

## Open points (before acceptance, kept for the record)

- How long a rebuild takes is not measured. The "roughly how long" the issue asks for needs real timings from a server; the binary cache
  (#253) changes them.
- Whether a `settings` option that a unit reads at start should restart the unit by itself or leave that to the user.

## Candidates checked (2026-11-04): none moves now

No option moves from `machine` to `settings` in this step. Each candidate was checked against the module that reads it:

- `diskSpindownMinutes`: read in `capabilities/storage/module.nix` to write the standby timer's unit. Storage (disk power), and the unit would
  have to read the value from a settings file. Not moved without a test on hardware.
- `shareSnapshots`: switches the unit `hs-share-snapshots` on or off with `lib.mkIf`, so the unit itself is declarative. Storage (snapshots).
- `syncEveryHours`: becomes the `startAt` of the SnapRAID sync timer, a unit file. Storage (parity sync).
- `metricsDays`, `metricsMaxGB`: Prometheus flags `retentionTime` and the size cap in `capabilities/metrics/module.nix`. Moving them needs a
  wrapper that reads the settings file and restarts Prometheus, and the size cap protects the system disk. Possible later, not safe to do
  untested.

Another finding of the same check: twelve options that are already `store = "settings"` are still read by `configuration.nix`
(`backupNewShares`, `heartbeatUrl`, `icons`, `language`, `loginMessage`, `notifyUrl`, `proxyStatusUrl`, `vpsHost`, `webAccent`, `webTerminal`,
`webTerminalIdleMinutes`, `webTerminalMaxHours`). They are turned into `/etc/hs/*` files or `HS_WEB_*` variables, so rule 3 does not hold for
them yet. `tests/schema.sh` lists them as known violations (the list may only shrink) and fails for any new one. Taking them out of the Nix
files is the next step, one option at a time, because the web service reads some of them from its environment.

The rebuild duration: `hs rebuild` now writes the seconds of the last successful build to `/var/lib/hs/last-rebuild-seconds`, and a plan that
needs a rebuild adds "The last rebuild took about N min." when that file exists. Nothing is shown before the first measured rebuild.

### Update: no live option is read by Nix any more

The twelve options (`backupNewShares`, `heartbeatUrl`, `icons`, `language`, `loginMessage`, `notifyUrl`, `proxyStatusUrl`, `vpsHost`,
`webAccent`, `webTerminal`, `webTerminalIdleMinutes`, `webTerminalMaxHours`) are no longer read by `configuration.nix`: the `/etc/hs/*` files,
the `HS_WEB_*` variables and the three assertions (language, proxyStatusUrl, vpsHost; the schema `choices`/`pattern` check them when set) are gone.
Every reader already used `setting_get` / `runtime_setting` or `/var/lib/hs/notify-url` and `heartbeat-url`, and `hs config migrate-settings`
(run by `hs update`) moves an old `machine.toml` line into the settings store. A rebuild without `hs update` no longer carries such a line over.
`tests/schema.sh` now lists no exceptions, so rule 3 holds. Not tested on hardware yet.

## Accepted 2026-11-08

The owner accepted the record with the two-class model as it stands. Decisions made at acceptance:

- **No third class.** There is no "needs restart" class between declarative and runtime. A restart of a service is a runtime action: a script does
  it, and the plan names the unit it restarts. A change that needs a unit file or a Nix expression to change is declarative and takes a rebuild.
- **Rule 4 is enforced.** Every plan of a change that touches configuration carries one note with the fixed sentence ("takes effect at once" or
  "takes effect with hs rebuild"), made by `scripts/lib/effect.sh`; the web dialogs show it above the steps, before Apply, and offer "Rebuild now"
  after a change that waits for a rebuild. `tests/apply-effect.sh` fails for a script that writes machine.toml or the settings without it.
- **Timing honesty.** A rebuild sentence adds "The last rebuild took about N min." from `/var/lib/hs/last-rebuild-seconds`, and before one was
  measured says that a rebuild takes several minutes and that none was timed on this server. No figure is invented.
- **`metricsDays` and `metricsMaxGB`** should later become runtime options of the metrics capability: a wrapper reads them from the settings
  store and restarts Prometheus (a runtime action that names the unit). Not done now: it needs a test on the real server, and the size cap protects
  the system disk.
- **Still open** (the owner decides): whether a runtime option that a unit reads only at start restarts that unit by itself or leaves it to the
  person; and the rebuild timing once the binary cache (hobnix/server#253) is in use, which changes every figure above.

Not tested on hardware yet.
