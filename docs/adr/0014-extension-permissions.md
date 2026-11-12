# 0014: Extension permissions: declare and disclose first, confine services next

Status: Accepted (2026-11-10): declare and disclose (step 1 and 1b, built in hobnix/server#239). Step 2 (confining services) and step 3 (a command broker) are not decided; open points 2 and 3 stay open until third-party packages are a goal.
Step 1 as built: `permissions = [...]` in package.toml (optional for now: absent shows as "not declared"), vocabulary and checks in scripts/lib/pkg_perms.py, validated by `pkg.py validate`, `repo-check` and at install; shown by `hs ext list`, `hs pkg install|update`; new permissions in an update need the typed package name or `--accept-permissions`. A declared permission is NOT a sandbox: commands run as root.
Step 1b (#239): the declaration is enforced against the manifest at run time. `hs_ext.ext_declarations` (web reads, changes, pages, live topics) skips a package whose `permissions` do not cover what its manifests use, and `hs ext enable` refuses it (`pkg.py perms-check`); a package without `permissions` is not checked. Not tested on hardware yet.
Issue: hobnix/server#239 (epic #197). Related: ADR 0010 (command protocol, #237), ADR 0011 (service lifecycle, #238); both Proposed in their own pull requests.

This record writes down the options and a recommendation. It does not enforce anything: no manifest declares a permission today, and no
document decides on a sandbox, so enforcement would mean inventing both the vocabulary and the mechanism (and `net` is a network and firewall
decision, which the owner takes).

## Context (checked 2026-11-07 on develop)
- package.toml / capability.toml declare NO permission list. The fields that look like one: `needs` (docker, share, tailscale) and `uses` (gpu)
  of recipes (scripts/pkg.py: NEEDS, USES) are *requirements the recipe installs or asks for*, checked against the run.sh header, not a grant
  that anything enforces. Extensions declare `requires`, `provides`, `extension`, `nix`, `[[web.reads]]`, `[[web.changes]]`, `[web.page]`, `[[events]]`.
- Already enforced (by loaders, tested): the namespace of command rows, scripts only under scripts/ or the package folder, no `legacy:` rows,
  web calls only through the declared reads/changes allowlist, page blocks only over declared reads, event kinds only `pkg.<name>.*`.
- docs/PLAN-extensions.md "Security" states the decision of record: every command runs as root, installing a package is trusting its author,
  trust comes from signed tags and the diff shown by `hs pkg update` (ADR 0008 rules 5 and 6). No sandbox decision exists in any PLAN or ADR.
- ADR 0010 (#237) and 0011 (#238) add two more things a package does that need a policy: a service process, and `emit` of event kinds.

So there is no declared permission the core could enforce today other than what it already enforces. Enforcing more means first inventing the
vocabulary and picking a mechanism; the mechanism decides what a package can do (files, network, host commands), which the task says not to
guess when it touches network or storage. Hence: proposal only.

## Decision options

### A permission vocabulary (draft, for the owner to cut down)
| Key | Meaning | Today |
| --- | --- | --- |
| `web.read` / `web.change` | the declared reads and changes | enforced by web-serve.py |
| `events.emit = [kinds]` | kinds the package may write | kinds are prefix-checked, not per call |
| `events.subscribe = [globs]` | event kinds a service receives (ADR 0010) | specified |
| `fs.write = [paths]` | paths below /var/lib/hs/ext/<name>, /etc/hs/..., a share | none |
| `fs.read = [paths]` | same, read only | none |
| `net = none/lan/internet` | outgoing connections | none (touches network: owner) |
| `host = [commands]` | `hs` commands or system tools it may call (incus, systemctl, ...) | none |
| `secrets = [names]` | secrets read through scripts/lib/secret.sh | none |
| `devices = [gpu, ...]` | devices | `uses` of recipes |

### Mechanisms
1. **Declare and disclose (no enforcement).** `permissions = [...]` is required in the manifest, validated by `pkg.py validate`, shown by `hs ext list`,
   `hs pkg install` and in the diff of `hs pkg update` (a new permission is highlighted and needs the typed name). Cheap, honest about being trust,
   and the prerequisite of everything else. It does not stop a malicious package.
2. **systemd confinement for services and jobs.** A service (ADR 0010) already runs as a unit, so `ProtectSystem=strict`, `ReadWritePaths=` from `fs.write`,
   `PrivateNetwork=` or `IPAddressAllow=` from `net`, `NoNewPrivileges`, `PrivateDevices` follow from the manifest with no new code. Commands run through
   `hs` as root; they could be wrapped by `systemd-run --pipe --wait -p ...` with the same properties. Enforces fs and net for real, but:
   `net` properties (IPAddressAllow, PrivateNetwork) are a network and firewall decision, and a root process can undo most of it unless the unit
   drops root (`User=` or DynamicUser), which breaks packages that call `incus` (needs the socket) or write /etc/hs.
3. **Unprivileged user per package plus a command broker.** The package runs as `hs-ext-<name>` and asks the core for privileged things through a
   request channel (the "open point" of ADRs 0009 and 0010), which checks `host`, `secrets` and `events.emit` against the manifest. This is the only
   design that enforces `host` and `secrets`; it is also a rewrite of every package that today calls hs commands directly (games, posters,
   ad-selfservice, passthrough, arr) and of the shell contract.
4. **Do nothing beyond what is enforced** and say so on the install prompt (current state).

## Recommendation (the decision this record proposes)
Step 1 now (declare, validate, disclose, show in the update diff); step 2 for services only, as part of the ADR 0010 unit, once the owner has decided
what `net` may mean (it is the firewall's business); step 3 only if third-party packages become a goal, since it needs the broker and a migration.
Do not claim enforcement for commands until step 3: root commands can read any file the manifest does not list.

## Consequences (if the recommendation is accepted)

- Step 1 is a small change (a manifest key, `pkg.py validate`, text in `hs ext list`, `hs pkg install` and the update diff) and can be a follow-up issue.
- Packages stay root-trusted until step 3; documentation must say so, and must not call a declared permission "enforced".
- Step 2 changes configuration.nix (the unit of ADR 0011) and needs a hardware run: "Not tested on hardware yet".

## Open points (decisions needed from the owner)
1. Is "trust the author, show what they ask for" (step 1) enough for v1, or must commands be confined too?
2. What may `net = lan|internet` mean, and who enforces it (unit properties vs the firewall)? (touches network, firewall)
3. May a package ever run as non-root (needs the broker)?
