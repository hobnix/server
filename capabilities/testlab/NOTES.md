# Capability testlab

The test-lab is a thin layer over the nested harness (docs/adr/0023-nested-test-harness.md, `scripts/dev/nested.sh`): it fetches a ref of a
Hobnix repository, builds the installer ISO from it, boots it in an Incus VM, installs unattended and smoke checks the installed system. Milestone
0.1 covers stage 1 (the ISO boots and installs) and stage 2 (first boot and smoke check). Stages 3 to 6 are hobnix/server#432 (0.2).
The stage `upgrade` (hobnix/server#435, `--stage upgrade [--from vX.Y.Z]`, not part of `all`) builds the ISO of the last release, installs it, sets up a share
(and an app, `HS_NESTED_UPGRADE_APP`), runs `hs update` to the `--ref` branch and checks health, shares, `state.db` and the app. Its result is
`stage-upgrade.json`. The candidate must be a branch of hobnix/server; the signed-tag path of `hs update` is not exercised.
Status: written without Incus, KVM or nix. Not tested on hardware yet.

- **Off by default.** A normal install never gets it: `capabilities = ["testlab"]` in machine.toml, then `hs rebuild`. `testlabNightly = true` adds the
  nightly timer `hs-testlab-nightly` (03:30 on the branch develop). The command (`hs testlab run`), the web page (Monitoring > Test-lab) and the rows
  `hs sys testlab ...` are hidden while it is off.
- **Never runs code from a stranger.** The server fetches the ref itself and only from the allowlist in scripts/testlab.sh (`testlab_url_ok`: https
  GitHub addresses under hobnix/). A ref is a branch, a tag or a commit; `refs/pull/...` and anything with `..` or a leading `-` is refused. It is
  not a self-hosted GitHub runner: nothing starts because someone opened a pull request.
- **A run is a job** (scripts/lib/job.sh): steps and progress on the Jobs page, events `testlab.*` (scripts/lib/event-kinds.tsv), a push message
  on failure. The run folder is `/var/lib/hs/testlab/runs/<run-id>/` with `stage-1.json` and `stage-2.json` per stage (`result` is ok, failed,
  skipped or error) and the full `run.log`; the last runs are kept (`HS_TESTLAB_KEEP`, default 14). The VM is deleted afterwards.
- Stage 2 needs the installed system of stage 1, so `--stage 2` runs both (and only stage 2 is reported as the one asked for in the summary line).
- Exit codes of `hs testlab run`: 0 passed, 1 a stage failed, 2 usage or refused, 3 cannot run here (no KVM, no nested virtualization, no incus),
  4 infrastructure error (fetch, ISO build, Incus). A 3 is "skipped", not a failure, and sends no push message.
- Tests: tests/testlab.sh with stand-ins for git, nix, incus and nested.sh (no Incus needed).
