"""Console scenarios of the test-lab stages 3 to 5 (hobnix/server#432), run by nested_lib.py on an INSTALLED VM (the one stage 1 made).

UNVERIFIED: written without Incus, KVM or nix. Not tested on hardware yet. The commands are the real `hs` commands of this repository, but no
step ran against a real system; the first real run will show which one needs a different prompt or option.

Adding a stage (for example the upgrade test, #435) is one entry in SCENARIOS: a function (params) -> list of steps (see
nested_lib.build_scenario for the kinds; `login` and the `strip` option of `capture` are added here and in run_steps). Nothing else in this file
changes. params: password (of adminuser), hostname, backup_pass (the restic password of the stage `backup`, only for `restore`), disks (the
Incus device names of the virtual disks a stage may use: dict name -> device name).
"""

LOGIN = r"\n[^\n]*login: $"


def _q(s):
    return "'" + s.replace("'", "'\\''") + "'"


def step(kind, text, **kw):
    d = {"kind": kind, "text": text}
    d.update(kw)
    return d


def login_root(params):
    """Reach a root shell on the console of an installed VM: log in as adminuser when a login prompt is shown, then `sudo -i`."""
    user, pw = "adminuser", params["password"]
    return [
        step("login", "", user=user, secret=pw, timeout=420, what="the console is logged in as adminuser"),
        step("send", "sudo -i"),
        step("wait", r"(?:\[sudo\] password for %s: ?|\[root@[^\]]*\]# )$" % user, timeout=30, what="sudo asks for the password or gives a root shell"),
        step("send_secret", pw),
        step("wait", r"\[root@[^\]]*\]# ", timeout=30, what="a root shell"),
    ]


def disk_by_name(params, key, var):
    """A step that finds the virtual disk (an Incus disk device named params['disks'][key]) in the VM: /dev/disk/by-id/...incus_<name>."""
    name = params["disks"][key]
    return step("capture", "readlink -f /dev/disk/by-id/*incus_%s | head -n1" % name, var=var, strip=True, what="the virtual disk %s is visible" % key)


# ---------------------------------------------------------------- stage 3: a bad update rolls back by itself
def rollback(params):
    """Put a bad commit on a local origin of /etc/nixos (it switches sshd off after the switch), run `hs update --yes`, and expect that the
    update goes back to the previous generation by itself and sshd runs again (scripts/update.sh, scripts/rebuild.sh rollback_now)."""
    bad = "{ lib, ... }: { services.openssh.enable = lib.mkForce false; }"
    return login_root(params) + [
        step("capture", "readlink /run/current-system", var="before", strip=True, what="the generation before the update"),
        step("capture", "git -C /etc/nixos rev-parse --abbrev-ref HEAD", var="branch", strip=True, what="/etc/nixos is on a branch"),
        step("run_var", "test {branch} != HEAD", what="not a detached checkout"),
        step("run", "rm -rf /var/tmp/hs-lab-origin.git /var/tmp/hs-lab-work && git init -q --bare /var/tmp/hs-lab-origin.git", what="a local origin for /etc/nixos"),
        step("run_var", "git -C /etc/nixos push -q /var/tmp/hs-lab-origin.git HEAD:refs/heads/{branch}", what="the current state goes to the local origin"),
        step("run", "git -C /etc/nixos remote set-url origin /var/tmp/hs-lab-origin.git && git -C /etc/nixos fetch -q origin", what="/etc/nixos follows the local origin"),
        step("run_var", "git -C /etc/nixos branch -q --set-upstream-to=origin/{branch}", what="the branch tracks it"),
        step("run_var", "git clone -q -b {branch} /var/tmp/hs-lab-origin.git /var/tmp/hs-lab-work", what="a work copy for the bad commit"),
        step("run", "printf '%%s\\n' %s > /var/tmp/hs-lab-work/hs-testlab-bad.nix" % _q(bad), what="the bad module (sshd off)"),
        step("run", "sed -i 's|imports = \\[ ./hardware-configuration.nix \\]|imports = [ ./hardware-configuration.nix ./hs-testlab-bad.nix ]|' "
                    "/var/tmp/hs-lab-work/configuration.nix && grep -q hs-testlab-bad /var/tmp/hs-lab-work/configuration.nix",
             what="configuration.nix imports it"),
        step("run_var", "cd /var/tmp/hs-lab-work && git add hs-testlab-bad.nix configuration.nix && "
                        "git -c user.name=testlab -c user.email=testlab@localhost commit -q -m 'bad update' && git push -q origin HEAD:{branch}; cd /",
             what="the bad update is published"),
        # the update builds the new system, switches, finds sshd stopped and goes back; its exit code is not the point, the state afterwards is
        step("capture", "hs update --yes 2>&1 | tail -n 40", var="update_out", timeout=2400, strip=True, what="hs update --yes runs (and goes back)"),
        step("run", "systemctl is-active sshd", timeout=120, what="sshd runs again after the update"),
        step("run_var", "test \"$(readlink /run/current-system)\" = {before}", what="the system is on the generation from before the update"),
        step("run", "test ! -e /etc/nixos/hs-testlab-bad.nix || ! systemctl is-active sshd | grep -qv '^active$'", what="the bad change is not live"),
    ]


# ---------------------------------------------------------------- stage 4: backup on this VM, restore onto a second clean VM
def backup(params):
    """On the first VM: set up the backup disk (a virtual disk), write a marker file into /var/lib/hs, back up, check the snapshot, and keep the
    restic password stays in the VM: testlab.sh pulls /var/lib/hs/restic-password with `incus file pull`, never through the console log."""
    return login_root(params) + [
        disk_by_name(params, "backup", "dev"),
        step("run_var", "test -b {dev}", what="the backup disk is a block device"),
        step("run_var", "HS_BACKUP_YES=1 hs backup init {dev}", timeout=300, what="hs backup init makes the disk the backup disk"),
        step("run", "mkdir -p /var/lib/hs && echo hs-testlab-marker > /var/lib/hs/testlab-marker", what="a marker file in the state folder"),
        step("run", "hs backup now", timeout=1800, what="hs backup now finishes"),
        step("run", "hs backup list | grep -q .", what="a snapshot is listed"),
        step("run", "hs backup verify", timeout=900, what="hs backup verify passes"),
        step("run", "sync && umount /var/lib/hs-backup 2>/dev/null; sync", expect_rc=None, what="the disk is quiet before it is moved"),
    ]


def restore(params):
    """On the second, clean VM (a fresh install): the backup disk was moved here. Read the host snapshot from the disk with only the backup
    password (hs backup config restore --from-disk) and expect the marker file of the first VM back."""
    pw = params["backup_pass"]
    return login_root(params) + [
        disk_by_name(params, "backup", "dev"),
        step("run_var", "test -b {dev}", what="the backup disk is attached to the second VM"),
        step("run", "test ! -e /var/lib/hs/testlab-marker", what="the second VM is clean: no marker yet"),
        step("send_var", "HS_BACKUP_YES=1 hs backup config restore --from-disk {dev} latest --with-state; echo \"__RESTORED__ rc=$?\"",
             what="hs backup config restore --from-disk starts"),
        step("wait", r"[Pp]assphrase[^\n]*: ?$", timeout=120, what="it asks for the backup password"),
        step("send_secret", pw),
        step("wait", r"__RESTORED__ rc=0", timeout=900, what="the restore finished"),
        step("run", "grep -qx hs-testlab-marker /var/lib/hs/testlab-marker", what="the marker file of the first VM is back"),
    ]


# ---------------------------------------------------------------- stage 5: a pool and the file manager on virtual disks
def pool(params):
    """Two virtual disks become the data disks of the pool bulk (SnapRAID, no parity), then the file manager copies a file from one data disk
    to the other. The file manager is read only until fileManagerWrite is on (scripts/fm.sh), so it is switched on first."""
    return login_root(params) + [
        disk_by_name(params, "pool1", "d1"),
        disk_by_name(params, "pool2", "d2"),
        step("run_var", "test -b {d1} && test -b {d2}", what="both virtual disks are block devices"),
        step("capture", "hs sys pool start bulk add --disks $(basename {d1}),$(basename {d2}) --role data --fs ext4 --confirm bulk", var="start", timeout=120,
             strip=True, what="the pool is created as a background job"),
        step("run_var", "echo {start} | grep -q 'status.*started'", what="the job started"),
        step("run", "u=$(hs job list --plain 2>/dev/null | awk '/pool/ {print $1; exit}'); [ -z \"$u\" ] || while systemctl is-active --quiet \"$u\"; do sleep 5; done",
             timeout=1800, what="the pool job finishes"),
        step("run", "hs pool bulk | grep -q data", what="hs pool bulk lists the data disks"),
        step("run", "mountpoint -q /bulk", what="/bulk is mounted"),
        step("run", "hs config set fileManagerWrite true", what="the file manager may write"),
        step("run", "hs sys fm locations | grep -q 'disk:data-01' && hs sys fm locations | grep -q 'disk:data-02'", what="the file manager sees both data disks"),
        step("run", "mkdir -p /var/lib/hs/disks/data-01/testlab && echo hs-testlab > /var/lib/hs/disks/data-01/testlab/a.txt", what="a test file on the first data disk"),
        step("run", "hs sys fm ls disk:data-01 --path testlab | grep -q a.txt", what="the file manager lists it"),
        step("run", "printf 'a.txt\\0' | hs sys fm start copy --from disk:data-01 --path testlab --to disk:data-02 --to-path testlab | grep -q 'status.*done'",
             timeout=300, what="the file manager copies it to the second data disk"),
        step("run", "for i in 1 2 3 4 5 6 7 8 9 10 11 12; do [ -f /var/lib/hs/disks/data-02/testlab/a.txt ] && break; sleep 5; done; "
                    "grep -qx hs-testlab /var/lib/hs/disks/data-02/testlab/a.txt", timeout=120, what="the copy arrived with the same content"),
    ]


SCENARIOS = {
    "rollback": rollback,
    "backup": backup,
    "restore": restore,
    "pool": pool,
}
