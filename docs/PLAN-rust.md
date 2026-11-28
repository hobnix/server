# Plan: Rust as the main language

Design record. Contributor document, not a guide. Written 2026-11-24 during 0.13. Builds on ADR 0001 (Rust behind the `hs sys` contract) and proposes ADR 0032 (Rust is the main language, Python is retired). Nothing here was built or run on a server; the numbers below that are not counted are marked so. Not tested on hardware yet.

## Where we are

- The core is bash, Python and Rust. Rust is `rust/` with three crates: `hobnix-core` (service layer), `hobnix-cli` (adapter: jobs, secrets so far) and `hobnix-ext-sdk` (extension protocol), about 3.9k lines. Beside it are 227 files in `scripts/` and 102 in `scripts/lib/`, bash and Python (counted 2026-11-24 with `ls`; lines of code not counted).
- ADR 0001 sets the method: strangler. A command moves when it is touched, behind its `hs sys` row, with a characterization test that passes on both implementations. It also lists what stays in shell and says shell and Python have "no deadline for removing them".
- Python programs named in the ADRs: `web-serve.py` (the web backend), `pkg.py`, `forecast.py`, `live-collect.py`, `job-record.py` (already also in Rust), `event-notify.py`, the generators (`schema-gen.py`, `openapi-gen.py`, `openapi-ts-gen.py`, `events-doc-gen.py`) and `changelog.py`. The list is not complete; step 1 below makes it complete.

## Decision proposed (ADR 0032)

1. **Rust is the main language** for the core, the tools that ship with it and the packages we write ourselves.
2. **Python is retired.** No new Python program; a Python program is replaced when ADR 0001's checklist allows, and the ones nobody touches get a scheduled move. The last Python leaves the server image when the last program is replaced. Tools that never run on a server (the generators) move last, and only because two toolchains cost more than they save.
3. **Bash stays, in a small role:** the launcher (`hs` dispatcher until it moves), installer and first run, unlock and recovery, `hs update` and its rollback, thin wrappers around one external command, and the dialogues of `ui.sh` until a later record says otherwise. This is ADR 0001's "Stays" list, unchanged. The reason for bash there is that these paths must work when the Rust binary is missing or broken.
4. **No flag day, no deadline for a single command.** Moves follow the touch rule. Python is the exception: it has a target release per program (step 2), because it is the layer with no reason to stay.

**Changed on 2026-11-28 (ADR 0035):** 0.15 is the Rust release. The touch rule of point 4 is replaced: what ADR 0032 decision 3 does not keep in bash moves in 0.15. A 0.15 beta that has run on the owner's server is the one release side by side. Where this file says "touch rule", "later" or names 0.14 as a target, that change applies. The three "debt" rows below are exceptions that ADR 0035 removes.

## What moves, what stays

| Area | Target | Why |
|---|---|---|
| `hs sys` contract commands (reads, plan, start, jobs) | Rust | typed checks, hot paths, shared logic (ADR 0001) |
| Job store, events, registry, manifest and package tools (`pkg.py`) | Rust | contracts with the web interface and packages; structured data |
| Web backend (`web-serve.py`) | Rust HTTP server, own ADR first (ADR 0001 decision 4) | the biggest Python program; serves root-level actions |
| Collectors and timers (`live-collect.py`, `forecast.py`, `event-notify.py`) | Rust | run every few minutes, parse structured output |
| Generators (`schema-gen`, `openapi-gen`, `openapi-ts-gen`, `events-doc-gen`, `changelog`) | Rust, last, as `xtask`-style dev tools | no server impact; removes Python from the dev environment |
| Installer, first run, unlock, `hs update` and rollback, recovery | bash | must work without the binary |
| Wrappers around one command, small glue | bash | Rust would add a build step and no safety |
| Guided dialogues (`ui.sh`) | bash for now | a later record decides; a Rust terminal UI is not planned |

## Steps

Each step is a board issue (milestone in brackets). A step is done when its characterization tests pass on both implementations for one release (ADR 0001 "Done means").

1. **Inventory** (0.13): list every `.py` and every script over 300 lines with its owner area, size and the ADR 0001 verdict (moves, stays). Output: a table in this file. No code.
2. **Practices and lints** (0.13): `docs/CODE-PRACTICES.md`, the path-scoped rule, `[workspace.lints]`, `shellcheck` warning level on changed files, `shfmt`. Existing code gets `#[allow]` with a reason or is fixed in passing.
3. **Close the Rust gaps in the job writer** (0.13 if small): the Rust writer does not know the `error` field and falls back to Python (PLAN-app-lifecycle, PLAN-recipe-orchestrator). Needed before Python can leave the job path.
4. **Package SDK design** (0.13 as a document, build in 0.14): docs/PLAN-package-sdk.md.
5. **Replace the small Python programs** (0.14 and later): `event-notify.py`, `live-collect.py`, `forecast.py`, `job-record.py` (delete after a release of side-by-side), then `pkg.py`.
6. **ADR for the Rust web server** (0.14): decides whether and how `web-serve.py` is replaced, the API version, and the cutover. The web backend moves only after this record is accepted.
7. **Move the generators and the changelog tool** (after step 5 or 6).
8. **Remove Python from the server image and the dev environment.** The release notes say so a release earlier.

Target releases for 5 to 8 are set when the inventory (step 1) shows the real size. They are not promised here.

## Inventory (step 1)

Counted 2026-11-24 on `origin/develop` with `git ls-files` and `wc -l`. "Called by" comes from `grep` for the file name in `scripts/`, `capabilities/`, `configuration.nix`, `install.nix`, `.github/` and `scripts/lib/registry.tsv`; the match is a first answer, not a full call graph, and the verdicts are proposals for review. Nothing was run on a server. Not tested on hardware yet.

Counts: 132 Python files (63 runtime, 7 generators, 10 dev tools, 52 tests, fixtures and examples) and 44 shell scripts over 300 lines (31 runtime, 13 tests). The Python rows add up to `git ls-files '*.py' | wc -l`.

Reading the verdict column, after ADR 0001 and ADR 0032:

- **moves**: replaced by Rust when ADR 0001's checklist holds (behind its registry row, one release side by side). Python has a target release per program; shell has none (touch rule).
- **stays**: shell kept by ADR 0001 (launcher, installer and first run, unlock and recovery, `hs update` and rollback, thin wrappers, `ui.sh` dialogues).
- **retire**: Python that is not a program of the server (tests, dev tools, fixtures) leaves with step 8, or earlier together with the subject it tests.
- **Target** is filled only where this plan already names a release (step 5: 0.14 and later). The web backend and the generators have no release yet: ADR 0032 decision 5 and step 7 leave them open. `-` means none named.
- **(new)** marks a Python file added after ADR 0001 (2026-11-10). `ext_state.py` (#1195), `pkg_blueprint.py` and `schema_options.py` (#1197) merged after the first count and have their rows now; the step 1 done condition holds again.

### Python: runtime programs (63)

Sorted by size. All of them move except where stated, because ADR 0032 retires Python.

Rule: no new Python program after ADR 0032. The three rows marked "debt" (`ext_state.py`, `pkg_blueprint.py`, `schema_options.py`) were added before it and accepted as debt by the maintainer's decision of 2026-11-24 ("merge, list as debt"); their target release is `-` until this plan names one.

| Path | Lines | Called by | Verdict | Target |
|---|---|---|---|---|
| `scripts/web-serve.py` | 4126 | systemd unit `hs-web` (configuration.nix, install.nix) | moves: own ADR first (ADR 0032 decision 5) | - |
| `scripts/state-db.py` | 1578 | `hs` commands and scripts (audit, disk-event, deck-status), event-notify, live state | moves: state store behind `hs sys` rows | - |
| `scripts/pkg_repo.py` | 1420 | pkg.py, pkg.sh, hs_ext.py | moves: package tools (with pkg.py) | 0.14 and later (step 5) |
| `scripts/services.py` | 1359 | `hs` scripts (apps-change, cleanup, config, ct-change ...), web-serve.py | moves: services and routes, guard `ADMIN_TARGETS` | - |
| `scripts/live-collect.py` | 948 | systemd unit of the `live-state` part | moves: collector | 0.14 and later (step 5) |
| `scripts/pkg.py` | 960 | `hs` scripts (apps-*, pkg.sh), app_autoupdate.py | moves: manifest and package tool | 0.14 and later (step 5) |
| `scripts/lib/ext_service.py` | 910 | ext.sh, event.sh, integration.sh, hs_ext.py | moves: extension protocol host | - |
| `scripts/live_state.py` | 546 | live-collect.py, live.sh, state-db.py, hs_ext.py | moves with live-collect.py | 0.14 and later (step 5) |
| `scripts/job-record.py` | 536 | scripts (apps-change, apps-recover, fm, job-reconcile ...) | moves: also in Rust; delete after one release side by side | 0.14 and later (step 5) |
| `scripts/lib/edge_facts.py` | 533 | edge-health.sh, edge-status.sh | moves: structured facts | - |
| `scripts/pkg_new.py` | 478 | `hs pkg new` (pkg.sh), pkg.py | moves with pkg.py | 0.14 and later (step 5) |
| `scripts/hs_ext.py` | 459 | web-serve.py, live-collect.py, live_state.py, pkg_repo.py | moves with the extension host | - |
| `scripts/web_terminal.py` | 449 | web-serve.py | moves with the web backend | - |
| `scripts/lib/ext_proto.py` | 443 | lib/hs.sh, registry-load.sh, pkg_binary.py | moves: protocol (Rust SDK exists) | - |
| `scripts/recipes/files/matrix-card/bot.py` | 423 | matrix-card recipe (runs in the app container) | moves with the recipe (package-owned) | - |
| `scripts/lib/pkg_index.py` (new) | 418 | pkg.py, pkg.sh, pkg_repo.py | moves with pkg.py | 0.14 and later (step 5) |
| `scripts/app_version.py` (new) | 395 | apps-version.sh, app_autoupdate.py, pkg.py | moves with pkg.py | 0.14 and later (step 5) |
| `scripts/machine-toml.py` | 370 | config-list.py, install-restore.sh, lib/machine.sh | moves: reads machine.toml (contract with config) | - |
| `scripts/gateway_render.py` | 368 | gateway.sh, traefik providers | moves: renders gateway config | - |
| `scripts/event-notify.py` | 356 | event-notify.sh (timer `hs-event-notify`) | moves: timer program | 0.14 and later (step 5) |
| `scripts/token_store.py` (new) | 330 | token.sh, token-change.sh, web-serve.py | moves: secrets path, with the web backend | - |
| `scripts/recipes/files/matrix-card/card.py` | 328 | matrix-card recipe (runs in the app container) | moves with the recipe (package-owned) | - |
| `scripts/lib/pkg_app.py` (new) | 318 | pkg.py, pkg_new.py, pkg_repo.py | moves with pkg.py | 0.14 and later (step 5) |
| `scripts/web_vmconsole.py` | 317 | web-serve.py | moves with the web backend | - |
| `scripts/app_autoupdate.py` (new) | 307 | apps-autoupdate.sh | moves with pkg.py | 0.14 and later (step 5) |
| `scripts/lib/pkg_integrations.py` (new) | 286 | pkg.py, ext_service.py | moves with pkg.py | 0.14 and later (step 5) |
| `scripts/lib/pkg_slots.py` (new) | 283 | pkg.py, hs_ext.py, health-check.sh, web-serve.py | moves with pkg.py | 0.14 and later (step 5) |
| `scripts/recipes/files/matrix-card/specs.py` | 277 | matrix-card recipe (runs in the app container) | moves with the recipe (package-owned) | - |
| `scripts/live_measure.py` (new) | 270 | live-measure.sh | moves with live-collect.py | 0.14 and later (step 5) |
| `scripts/first_run.py` | 235 | setup-change.sh, setup-code.sh, web-serve.py | stays for now: first run must work without the binary (ADR 0001 Stays); revisit with the web ADR | - |
| `scripts/lib/pkg_vendor.py` (new) | 234 | pkg.py, pkg_repo.py, CI | moves with pkg.py | 0.14 and later (step 5) |
| `scripts/lib/answers.py` | 222 | answers.sh, apps-change.sh, backup-change.sh ... | moves: structured answers file | - |
| `scripts/lib/docker_import.py` | 213 | docker-import.sh | moves: parser | - |
| `scripts/lib/pkg_events.py` | 201 | pkg.py, event-notify.py | moves with pkg.py | 0.14 and later (step 5) |
| `scripts/recipes/files/hs-media-notify.py` | 200 | recipe `_media.sh` (runs in the app container) | moves with the recipe (package-owned) | - |
| `scripts/lib/docker_app_doc.py` | 198 | docker.sh, docker-app-change.sh | moves: parser | - |
| `scripts/lib/pkg_binary.py` (new) | 192 | pkg.py, pkg_repo.py | moves with pkg.py | 0.14 and later (step 5) |
| `scripts/lib/unraid_import.py` | 186 | import-unraid.sh | moves: parser of foreign data; low priority | - |
| `scripts/lib/ext_confine.py` (new) | 180 | ext.sh, ext_service.py, pkg_perms.py | moves with the extension host | - |
| `scripts/lib/ask-q.py` | 175 | ask.sh, recipes/_lib.sh, apps-change.sh, jobs-answer.sh | moves: question protocol (ADR 0018) | - |
| `scripts/lib/ext_state.py` (new) | 169 | ext.sh, tests/ext-state.sh (ext_service.py not yet) | moves: debt, see below | - |
| `scripts/lib/pkg_perms.py` | 168 | pkg.py, pkg_integrations.py, hs_ext.py | moves with pkg.py | 0.14 and later (step 5) |
| `scripts/unit-watch.py` (new) | 164 | systemd unit `hs-unit-watch` | moves: long-running watcher | 0.14 and later (step 5) |
| `scripts/lib/pkg_blocks.py` (new) | 155 | pkg.py, pkg_slots.py | moves with pkg.py | 0.14 and later (step 5) |
| `scripts/lib/pkg_protocol.py` (new) | 155 | pkg.py, pkg_repo.py, ext_service.py | moves with pkg.py | 0.14 and later (step 5) |
| `scripts/lib/vzdump_import.py` | 155 | import-vzdump.sh | moves: parser | - |
| `scripts/lib/ext_sdk.py` (new) | 153 | ext_sdk.sh, pkg_new.py | moves: Python SDK for extensions; ADR 0032 decision 7 (SDK crates) | - |
| `scripts/forecast.py` | 143 | backup.sh, health-check.sh, capacity.sh, state-db.py | moves: timer/collector class | 0.14 and later (step 5) |
| `scripts/pkg_states.py` (new) | 131 | pkg.py, pkg.sh, app_health.py | moves with pkg.py | 0.14 and later (step 5) |
| `scripts/lib/pkg_blueprint.py` (new) | 127 | pkg.py (manifest checks) | moves: debt, see below | - |
| `scripts/lib/iommu.py` | 130 | none in scripts (test only; `tests/iommu.sh`) | retire or move: check for a caller first | - |
| `scripts/config-list.py` | 116 | backup.sh, config-read.sh | moves with machine-toml.py | - |
| `scripts/preset.py` | 116 | install-wizard.sh, install-restore.sh, lib/answers.py | stays for now: installer path (ADR 0001 Stays) | - |
| `scripts/lib/ct-image.py` | 110 | backup.sh (`hs backup drill ct`) | moves with backup.sh | - |
| `scripts/lib/docs-index.py` | 108 | docs-build.sh, recipes/_lib.sh | moves: docs index builder | - |
| `scripts/app_health.py` (new) | 94 | apps-list.sh | moves with pkg.py | 0.14 and later (step 5) |
| `scripts/providers/reverse-proxy/zoraxy-list.py` | 77 | zoraxy.sh | moves with the Zoraxy provider; thin helper | - |
| `scripts/job-records.py` | 76 | jobs.sh | moves with job-record.py | 0.14 and later (step 5) |
| `scripts/lib/schema_options.py` (new) | 44 | preset.py (checks of presets and blueprints) | moves: debt, see below | - |
| `scripts/lib/pkg_probes.py` (new) | 75 | smoke.sh | moves with pkg.py | 0.14 and later (step 5) |
| `scripts/deck-serve.py` | 70 | systemd unit `hs-deck-api` (configuration.nix, edge-status part) | moves: small server, also runs on edge nodes | - |
| `scripts/lib/pkg_restart.py` (new) | 49 | pkg.sh | moves with pkg.py | 0.14 and later (step 5) |
| `scripts/lib/pkg_roles.py` (new) | 31 | pkg.py, pkg_slots.py, hs_ext.py | moves with pkg.py | 0.14 and later (step 5) |

### Python: generators (7)

Run in CI or by the developer, never on a server, except `changelog.py`, which `hs changes` uses. They move last (step 7).

| Path | Lines | Called by | Verdict | Target |
|---|---|---|---|---|
| `scripts/schema-gen.py` | 903 | generator: config/schema.toml to defaults.nix, config-keys.sh, capabilities.tsv; also read by config scripts | moves last | - |
| `scripts/openapi-gen.py` | 299 | generator: registry.tsv + sys.toml to openapi.json (CI) | moves last | - |
| `scripts/lib/changelog.py` | 190 | `hs changes` (registry), changelog-check.sh, release-gate.sh; parses docs/changelog | moves: ships with the core (runtime use), `changelog` tool | - |
| `scripts/openapi-ts-gen.py` | 163 | generator: openapi.json to sys.gen.d.ts (CI) | moves last | - |
| `scripts/roadmap-gen.py` | 121 | generator: roadmap doc | moves last | - |
| `scripts/events-doc-gen.py` | 86 | generator: event-kinds.tsv to docs/events.md (CI) | moves last | - |
| `scripts/errors-doc-gen.py` (new) | 79 | generator: error-codes.tsv to docs (CI) | moves last | - |

### Python: dev tools (10)

| Path | Lines | Called by | Verdict | Target |
|---|---|---|---|---|
| `scripts/dev/nested_lib.py` | 429 | nested.sh, nested_check.py, nested_stages.py | retire with Python (step 8) | - |
| `scripts/dev/nested_stages.py` (new) | 406 | nested.sh, nested_lib.py | retire with Python (step 8) | - |
| `scripts/dev/testlab-browser.py` (new) | 265 | scripts/testlab.sh, tests/testlab-live.sh | retire with Python (step 8) | - |
| `scripts/dev/nested_check.py` (new) | 258 | scripts/dev/nested.sh, test | retire with Python (step 8) | - |
| `scripts/dev/reads-inventory.py` (new) | 232 | dev tool, tests/reads-ratchet.sh | retire with Python (step 8) | - |
| `scripts/dev/web-inventory.py` (new) | 155 | dev tool, tests/web-inventory.sh | retire with Python (step 8) | - |
| `scripts/dev/web-actions.py` (new) | 136 | dev tool, tests/web-actions.sh | retire with Python (step 8) | - |
| `scripts/dev/untested.py` (new) | 126 | dev tool (`hwtest`, tests/untested.sh) | retire with Python (step 8) | - |
| `scripts/dev/leak-scan.py` | 94 | dev tool, by hand | retire with Python (step 8) | - |
| `scripts/dev/core-names-check.py` (new) | 74 | CI, tests/core-names.sh | retire with Python (step 8) | - |

### Python: tests, fixtures and examples (52)

Test files are not programs of the server. Each is retired when the subject it tests moves, or in step 8 at the latest.

| Path | Lines | Called by | Verdict | Target |
|---|---|---|---|---|
| `tests/live-state-test.py` | 1506 | test (run by `t`) | retire with the subject it tests | - |
| `tests/web-login-test.py` | 1491 | test (run by `t`) | retire with the subject it tests | - |
| `tests/web-live-test.py` | 1283 | test (run by `t`) | retire with the subject it tests | - |
| `tests/web-terminal-test.py` | 722 | test (run by `t`) | retire with the subject it tests | - |
| `tests/web-ext-test.py` | 559 | test (run by `t`) | retire with the subject it tests | - |
| `tests/nested-test.py` | 530 | test (run by `t`) | retire with the subject it tests | - |
| `tests/token-test.py` | 410 | test (run by `t`) | retire with the subject it tests | - |
| `tests/live-db-test.py` | 397 | test (run by `t`) | retire with the subject it tests | - |
| `tests/web-roles-test.py` | 336 | test (run by `t`) | retire with the subject it tests | - |
| `tests/web-vmconsole-test.py` | 329 | test (run by `t`) | retire with the subject it tests | - |
| `tests/web-docker-change-test.py` | 311 | test (run by `t`) | retire with the subject it tests | - |
| `tests/first-run-test.py` | 304 | test (run by `t`) | retire with the subject it tests | - |
| `tests/web-cache-test.py` | 257 | test (run by `t`) | retire with the subject it tests | - |
| `tests/live-demand-test.py` | 235 | test (run by `t`) | retire with the subject it tests | - |
| `tests/web-board-test.py` | 213 | test (run by `t`) | retire with the subject it tests | - |
| `tests/web-plan-cache-test.py` | 209 | test (run by `t`) | retire with the subject it tests | - |
| `tests/web-unlock-test.py` | 196 | test (run by `t`) | retire with the subject it tests | - |
| `tests/web-changes-test.py` | 188 | test (run by `t`) | retire with the subject it tests | - |
| `tests/web-docs-test.py` | 188 | test (run by `t`) | retire with the subject it tests | - |
| `tests/web-forms-ops-test.py` | 181 | test (run by `t`) | retire with the subject it tests | - |
| `tests/live-e2e-test.py` | 177 | test (run by `t`) | retire with the subject it tests | - |
| `tests/web-forms-storage-test.py` | 174 | test (run by `t`) | retire with the subject it tests | - |
| `tests/web-proxy-test.py` | 165 | test (run by `t`) | retire with the subject it tests | - |
| `tests/web-forms-users-test.py` | 163 | test (run by `t`) | retire with the subject it tests | - |
| `tests/zoraxy-fake.py` | 163 | test fixture | retire with the subject it tests | - |
| `tests/answers-test.py` | 150 | test (run by `t`) | retire with the subject it tests | - |
| `tests/web-ssh-key-test.py` | 149 | test (run by `t`) | retire with the subject it tests | - |
| `tests/web-plan-start-test.py` | 138 | test (run by `t`) | retire with the subject it tests | - |
| `tests/web-convert-test.py` | 129 | test (run by `t`) | retire with the subject it tests | - |
| `tests/docker-import-test.py` | 119 | test (run by `t`) | retire with the subject it tests | - |
| `tests/pool-names-ratchet-test.py` | 117 | test (run by `t`) | retire with the subject it tests | - |
| `tests/docker-app-doc-test.py` | 111 | test (run by `t`) | retire with the subject it tests | - |
| `tests/web-gaps-test.py` | 109 | test (run by `t`) | retire with the subject it tests | - |
| `tests/web-netmap-stream-test.py` | 106 | test (run by `t`) | retire with the subject it tests | - |
| `tests/iommu-test.py` | 94 | test (run by `t`) | retire with the subject it tests | - |
| `tests/fixtures/ext-service/svc.py` | 91 | test fixture | retire with the subject it tests | - |
| `tests/fixtures/ext-proto/ext.py` | 90 | test fixture | retire with the subject it tests | - |
| `tests/web-forms-shares-test.py` | 90 | test (run by `t`) | retire with the subject it tests | - |
| `tests/web-forms-fm-test.py` | 87 | test (run by `t`) | retire with the subject it tests | - |
| `tests/nested-check-test.py` | 85 | test (run by `t`) | retire with the subject it tests | - |
| `tests/testlab-live-test.py` | 82 | test (run by `t`) | retire with the subject it tests | - |
| `tests/web-forms-instances-test.py` | 81 | test (run by `t`) | retire with the subject it tests | - |
| `tests/web-node-test.py` | 70 | test (run by `t`) | retire with the subject it tests | - |
| `tests/web-vps-test.py` | 69 | test (run by `t`) | retire with the subject it tests | - |
| `tests/web-ratchet-test.py` | 66 | test (run by `t`) | retire with the subject it tests | - |
| `tests/web-overlay-test.py` | 62 | test (run by `t`) | retire with the subject it tests | - |
| `tests/web-notify-test.py` | 61 | test (run by `t`) | retire with the subject it tests | - |
| `tests/web-a11y-axe-test.py` | 55 | test (run by `t`) | retire with the subject it tests | - |
| `tests/web-buttons-test.py` | 50 | test (run by `t`) | retire with the subject it tests | - |
| `tests/web-builder-test.py` | 38 | test (run by `t`) | retire with the subject it tests | - |
| `sdk/examples/python/hello.py` (new) | 29 | example for the extension SDK (`tests/ext-sdk-examples.sh`) | stays: the protocol is language-neutral, keep one Python example | - |
| `tests/web-files-contract-build.py` | 28 | test (run by `t`) | retire with the subject it tests | - |

### Shell: runtime scripts over 300 lines (31)

"Rows" counts registry rows that run the script; `sys` rows are the contract with the web interface. A script with `sys` rows moves group by group (ADR 0001 "When a command moves to Rust"), so the verdict names what moves first and what stays. Rows from `scripts/lib/registry.tsv`.

| Path | Lines | Called by | Verdict |
|---|---|---|---|
| `scripts/backup.sh` | 1975 | `hs backup ...` (34 rows, 8 `sys`) | moves: when the `sys` rows are touched; dialogues stay |
| `scripts/manage-pool.sh` | 1543 | `hs pool ...` (12 rows, 5 `sys`) | moves: `sys` reads first; destructive dialogues stay |
| `scripts/fm.sh` | 1201 | `hs fm ...` (9 rows, all `sys`) | moves: file manager `sys` rows |
| `scripts/docker.sh` | 990 | `hs docker ...` (16 rows, 10 `sys`) | moves: `sys` rows |
| `scripts/docker-app-change.sh` | 986 | `sys docker-app plan|start` (2 rows) | moves: plan/start pair |
| `scripts/recipes/_lib.sh` | 797 | sourced by recipes, docker.sh, ask.sh | stays: recipe glue, package-owned; recipes move on their own |
| `scripts/health-check.sh` | 634 | `hs health` and `sys health` (3 rows), doctor.sh, timers | moves: structured checks |
| `scripts/remote.sh` | 606 | `hs remote ...` (12 rows, 2 `sys`) | moves: `sys` rows; pairing dialogue stays |
| `scripts/storage-incident.sh` | 535 | `hs storage incident` (7 rows, 3 `sys`), web-serve.py | stays: recovery path (ADR 0001); `--state` and `plan` rows may move |
| `scripts/testlab.sh` | 518 | `hs testlab` (3 rows), nested.sh | stays: dev lab driver |
| `scripts/services.sh` | 492 | `hs services ...` (24 rows, 8 `sys`) | moves: with services.py |
| `scripts/lib/hs.sh` | 443 | sourced by most scripts (launcher support) | stays: launcher (ADR 0001) |
| `scripts/lib/ui.sh` | 441 | sourced by every script | stays: dialogues (ADR 0001, ADR 0032 decision 3) |
| `scripts/manage-ct.sh` | 433 | `hs ct ...` (20 rows, 8 `sys`) | moves: `sys` rows |
| `scripts/apps-change.sh` | 401 | `sys apps plan|start` (2 rows) | moves: plan/start pair |
| `scripts/manage-shares.sh` | 394 | `hs share ...` (8 rows, 7 `sys`) | moves: `sys` rows |
| `scripts/config-change.sh` | 381 | `sys config plan|start` (2 rows) | moves: plan/start pair, with schema-gen output |
| `scripts/manage-users.sh` | 376 | `hs user ...` (11 rows, 4 `sys`) | moves: `sys` rows |
| `scripts/ext.sh` | 373 | `hs ext ...` (15 rows, 2 `sys`) | moves with the extension host |
| `scripts/rebuild.sh` | 361 | `hs rebuild`, `hs system rebuild` (2 rows) | stays: rebuild path (ADR 0001 `hs update` and rollback) |
| `scripts/pkg.sh` | 348 | `hs pkg ...` (25 rows, 9 `sys`) | moves with pkg.py |
| `scripts/install-wizard.sh` | 341 | `hs installer` (1 row) | stays: installer (ADR 0001) |
| `scripts/gateway.sh` | 340 | `hs gateway ...` (9 rows, 4 `sys`) | moves: with gateway_render.py |
| `scripts/smoke.sh` | 330 | dev and CI smoke probes | stays: probe driver |
| `scripts/disk-health.sh` | 325 | `hs disk ...` (7 rows, 3 `sys`), health-check.sh | moves: SMART parsing |
| `scripts/migrate-unraid.sh` | 320 | `hs migrate unraid` (3 rows), web-serve.py | stays: guided migration dialogue; parsers move |
| `scripts/ports.sh` | 320 | `hs ports` (2 rows) | moves: structured reads |
| `scripts/disk-change.sh` | 319 | `sys disk plan|start` (2 rows) | stays: destructive, root-level; revisit after the `sys` rows |
| `scripts/vault.sh` | 315 | `hs vault ...` (12 rows, 3 `sys`), first-run.sh, doctor.sh | stays: unlock and recovery (ADR 0001); secrets rows already `rust:` |
| `scripts/notify-channel.sh` | 314 | `hs notify ...` (11 rows, 3 `sys`) | moves: channels config; secrets via secret.sh |
| `scripts/share-change.sh` | 312 | `sys share plan|start` (2 rows) | moves: plan/start pair |

### Shell: tests over 300 lines (13)

| Path | Lines | Called by | Verdict |
|---|---|---|---|
| `tests/services.sh` | 650 | test (run by `t`) | stays: moves with its subject |
| `tests/fm.sh` | 584 | test (run by `t`) | stays: moves with its subject |
| `tests/docker-cap.sh` | 484 | test (run by `t`) | stays: moves with its subject |
| `tests/testlab.sh` | 433 | test (run by `t`) | stays: moves with its subject |
| `tests/apps-change.sh` | 399 | test (run by `t`) | stays: moves with its subject |
| `tests/ext-service-reach.sh` | 388 | test (run by `t`) | stays: moves with its subject |
| `tests/docker-app-change.sh` | 374 | test (run by `t`) | stays: moves with its subject |
| `tests/pkg-index-repo.sh` | 368 | test (run by `t`) | stays: moves with its subject |
| `tests/remote-pair.sh` | 361 | test (run by `t`) | stays: moves with its subject |
| `tests/gateway.sh` | 358 | test (run by `t`) | stays: moves with its subject |
| `tests/pkg.sh` | 357 | test (run by `t`) | stays: moves with its subject |
| `tests/notify-channel.sh` | 343 | test (run by `t`) | stays: moves with its subject |
| `tests/ext-confine.sh` | 305 | test (run by `t`) | stays: moves with its subject |

## Shell scripts that stay: rules

- A script that stays gets no new structured-data parsing. When a change needs it, the change moves that part to Rust (the touch rule).
- The launcher keeps its fallbacks: a `rust:` row runs the binary, falls back to the script while the binary is missing (ADR 0001 decision 2).
- A bash script over about 300 lines is reviewed for a move each time it is touched.

## Risks and costs

- **Build time and size.** Rust builds are slower than editing a script. The Nix build and the binary cache (ADR 0003) carry this; the build time and closure size of `hobnix` are not measured here. Measure before step 6.
- **Editing on the server.** Today a script on `/etc/nixos` can be fixed in place. A Rust change needs a rebuild. That is acceptable for the core (changes come through `hs update`) and is the reason recovery stays in bash.
- **Contributors.** Fewer people read Rust than shell. The practices document, the SDK and the characterization tests are meant to lower that barrier; a "good first issue" label for small Rust moves helps.
- **Dependencies.** Each crate is a cost under Nix without network (CODE-PRACTICES). The `std`-only rule of `hobnix-core` stays, with `serde` and `serde_json` as the accepted exception.
- **Rewrite risk.** Every move is a behaviour change risk. The characterization test, the side-by-side release and the one-line way back are the guard; never move without them.

## Open points

1. **Decided 2026-11-24 (ADR 0032 decision 6):** the `hs` dispatcher stays a bash launcher until everything behind it is Rust, then a later record decides. The rename `hs` to `hn` is its own milestone (PLAN-extensions-access.md); `hs` stays as an alias. New Rust code and docs say `hobnix`/`hn` where they name the product, and no rename work is part of this plan.
2. A Rust terminal UI for dialogues: ADR 0001 notes that `hs-ui` (ratatui) was removed in 2026-10 because it duplicated parsing. Not planned.
3. Whether the web frontend build (Node, in `web/`) is affected: it is not; Node stays a build-time tool and is not on the server.
