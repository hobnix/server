# Test-lab

The test-lab builds the installer ISO of a Hobnix branch, installs it unattended in a virtual machine on this server and checks that the installed
system comes up. It repeats the checks every night without a person at the machine. It is for a dedicated build server, not for a normal install.

Not tested on hardware yet.

## Before you start
- A server with KVM, [Incus](../../docs/containers-and-apps.md) and nested virtualization, at least 4 GiB of free RAM, 20 GiB of free disk for the
  VM and enough space for a Nix build of the ISO (tens of GiB).
- `nix` and `git` on the server, and network access to GitHub.
- This guide is not tested on hardware yet.

## Switch it on
Not tested on hardware yet.

```bash
sudo hs config set capabilities '["incus", "testlab"]'
```

For the nightly run on `develop` add the line `testlabNightly = true` to `machine.toml`, then rebuild.

```bash
sudo hs rebuild
```

## Run it
Not tested on hardware yet.

```bash
sudo hs testlab run --dry-run
```

It prints the plan and changes nothing. Then start it; it asks whether to run in the background and shows on the Jobs page:

```bash
sudo hs testlab run --ref develop --stage all
```

One stage on its own (by number or name: `install`, `smoke`, `rollback`, `backup`, `pool`, `browser`). A stage from 3 on needs the installed VM, so
stages 1 and 2 run first:

```bash
sudo hs testlab run --stage rollback
```

The web interface has the same under Monitoring > Test-lab (a button that shows the plan first). The server fetches the ref itself and only from
the Hobnix repositories: it never runs code from a pull request of a stranger.

## Read the result
```bash
sudo hs testlab results
```

Each run has one line per stage (1 to 6): `ok`, `failed`, `skipped` (the machine cannot run nested VMs) or `error` (fetch, ISO build or Incus failed). The
run folder `/var/lib/hs/testlab/runs/<run-id>/` holds one `stage-<n>.json` per stage and `run.log`. A failed run sends a push message.

## What it covers
- Stage 1: the ISO boots in a VM and installs unattended (#175).
- Stage 2: the installed system boots and passes the smoke check.
- Stage 3 (rollback): a deliberately bad update (it switches sshd off) goes back to the previous generation by itself.
- Stage 4 (backup): `hs backup init` on a virtual disk, `hs backup now`, `hs backup verify`; then the disk moves to a second, clean VM
  (installed from the same ISO) and `hs backup config restore --from-disk` brings the state back with only the backup password.
- Stage 5 (pool): two virtual disks become the data disks of the pool `bulk`, and the file manager copies a file from one disk to the other.
- Stage 6 (browser): a headless browser (playwright) signs in to the web interface and opens every page of the navigation; a script error, a
  console error, an empty page or a status other than 200 fails the stage. Without playwright on the server the stage is `skipped`.

Stages 3 to 6 were written without Incus, KVM or nix. Not tested on hardware yet. The first real run will most likely need small fixes in the
console scenarios (`scripts/dev/nested_stages.py`).

## What stays manual
- Nothing that stages 1 to 6 cover. Once they are green on the real server, the manual list shrinks to what a virtual machine cannot do (next point).
- A virtual machine cannot check SMART or a really failing disk, GPU passthrough, the UPS, real DNS and certificates, or a VPS.

## Check that it worked
`hs testlab results` lists the run with `ok` for every stage, and `hs job list` shows the job as finished.

## If something goes wrong
- `skipped` with exit 3: this machine has no KVM or no nested virtualization; check `scripts/dev/nested.sh preflight` in the repository.
- `incus launch` of a VM sometimes hangs on the first server (cause unknown): delete the VM named `hs-testlab-<run-id>` (`incus delete -f`) and run again.
- Stage 6 `skipped`: the server has no playwright and no browser. The nightly timer brings them (capability module); for a manual `hs testlab run` the `python3` of your shell needs the playwright package and its browsers. A stage that is `error`
  usually means a console scenario did not match a prompt: read `harness-<stage>/console-<stage>.log` in the run folder.
- Read `run.log` in the run folder; the harness logs of the VM are under `.work/nested/` of the fetched tree, copied into the run folder.

## Related
- [Operations](../../docs/operations.md)
