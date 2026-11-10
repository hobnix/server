# Capability testlab

The test-lab is a thin layer over the nested harness (docs/adr/0023-nested-test-harness.md, `scripts/dev/nested.sh`): it fetches a ref of a
Hobnix repository, builds the installer ISO from it, boots it in an Incus VM, installs unattended and smoke checks the installed system. Stage 1 (the ISO boots and installs) and stage 2 (first boot and smoke check) are 0.1; stages 3 (a bad update rolls back), 4 (backup, restore on a
second clean VM), 5 (pool and file manager on virtual disks) and 6 (headless browser opens every page) are hobnix/server#432 (0.2).
Stage 7, `upgrade` (hobnix/server#435, `--stage 7|upgrade [--from vX.Y.Z]`, never part of `all`, needs no stages 1 and 2) builds the ISO of the last release,
installs it, sets up a share (and an app, `HS_NESTED_UPGRADE_APP`), runs `hs update` to the `--ref` branch and checks health, shares, `state.db` and the
app. The candidate must be a branch of hobnix/server; the signed-tag path of `hs update` is not exercised.
Status: written without Incus, KVM or nix. Not tested on hardware yet.

- **Off by default.** A normal install never gets it: `capabilities = ["testlab"]` in machine.toml, then `hs rebuild`. `testlabNightly = true` adds the
  nightly timer `hs-testlab-nightly` (03:30 on the branch develop). The command (`hs testlab run`), the web page (Monitoring > Test-lab) and the rows
  `hs sys testlab ...` are hidden while it is off.
- **Never runs code from a stranger.** The server fetches the ref itself and only from the allowlist in scripts/testlab.sh (`testlab_url_ok`: https
  GitHub addresses under hobnix/). A ref is a branch, a tag or a commit; `refs/pull/...` and anything with `..` or a leading `-` is refused. It is
  not a self-hosted GitHub runner: nothing starts because someone opened a pull request.
- **A run is a job** (scripts/lib/job.sh): steps and progress on the Jobs page, events `testlab.*` (scripts/lib/event-kinds.tsv), a push message
  on failure. The run folder is `/var/lib/hs/testlab/runs/<run-id>/` with `stage-<n>.json` per stage (`result` is ok, failed,
  skipped or error) and the full `run.log`; the last runs are kept (`HS_TESTLAB_KEEP`, default 14). The VM is deleted afterwards.
- A stage is a number or a name (`stage_name` in scripts/testlab.sh). Stage 2 and stages 3 to 6 need the installed system of stage 1, so asking for
  one runs 1 and 2 first. Stages 3 to 5 are console scenarios (scripts/dev/nested_stages.py, run by nested.sh like `smoke`); 4 also installs a second
  VM and moves the virtual backup disk to it; 5 and 4 use Incus block volumes as virtual disks (storage pool `HS_TESTLAB_STORAGE`, default
  `default`), deleted at the end. Stage 6 runs on the server itself (scripts/dev/testlab-browser.py, playwright) against the VM's web port.
  **Adding a stage** (#435 does): a `stage_name` case and the number in `STAGES_ALL` in testlab.sh, a `stage_<name>` function there, and a scenario in
  `SCENARIOS` of nested_stages.py if it needs the VM console.
- One stage failing does not stop the later ones; the exit code names the first stage that is not ok. A stage 3 to 6 that is `skipped` (stage 6
  without a browser) exits 3 like a machine that cannot run nested VMs: no push message.
- Exit codes of `hs testlab run`: 0 passed, 1 a stage failed, 2 usage or refused, 3 cannot run here (no KVM, no nested virtualization, no incus),
  4 infrastructure error (fetch, ISO build, Incus). A 3 is "skipped", not a failure, and sends no push message.
- Tests: tests/testlab.sh with stand-ins for git, nix, incus and nested.sh (no Incus needed).
