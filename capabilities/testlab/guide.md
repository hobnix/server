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

The web interface has the same under Monitoring > Test-lab (a button that shows the plan first). The server fetches the ref itself and only from
the Hobnix repositories: it never runs code from a pull request of a stranger.

## Read the result
```bash
sudo hs testlab results
```

Each run has one line per stage: `ok`, `failed`, `skipped` (the machine cannot run nested VMs) or `error` (fetch, ISO build or Incus failed). The
run folder `/var/lib/hs/testlab/runs/<run-id>/` holds `stage-1.json`, `stage-2.json` and `run.log`. A failed run sends a push message.

## What it covers
- Stage 1: the ISO boots in a VM and installs unattended (#175).
- Stage 2: the installed system boots and passes the smoke check.

## What stays manual
- A bad update that rolls back by itself, backup and restore onto a second machine, pools and the file manager on virtual disks, and the web pages
  in a browser: these are stages 3 to 6, planned for 0.2 (hobnix/server#432).
- A virtual machine cannot check SMART or a really failing disk, GPU passthrough, the UPS, real DNS and certificates, or a VPS.

## Check that it worked
`hs testlab results` lists the run with `ok` for stage 1 and 2, and `hs job list` shows the job as finished.

## If something goes wrong
- `skipped` with exit 3: this machine has no KVM or no nested virtualization; check `scripts/dev/nested.sh preflight` in the repository.
- `incus launch` of a VM sometimes hangs on the first server (cause unknown): delete the VM named `hs-testlab-<run-id>` (`incus delete -f`) and run again.
- Read `run.log` in the run folder; the harness logs of the VM are under `.work/nested/` of the fetched tree, copied into the run folder.

## Related
- [Operations](../../docs/operations.md)
