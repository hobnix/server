#!/usr/bin/env bash
# Hobnix-in-Hobnix: boot the installer ISO in a nested Incus VM, install unattended, boot the result, run a smoke check (issue #262,
# docs/adr/0019-nested-test-harness.md). UNVERIFIED: written without Incus, KVM or nix; it has never booted an ISO.
#
#   scripts/dev/nested.sh run [--iso <file>] [--stage iso|smoke|all] [--keep] [--name <vm>]
#   scripts/dev/nested.sh preflight       can this machine run it? (exit 3: no, fall back to `scripts/dev/t vm`)
#   scripts/dev/nested.sh plan [stage]    print the steps without running anything
#
# Exit codes: 0 passed, 1 a check failed, 2 usage, 3 cannot run here (no KVM/nested virtualization/incus), 4 harness or Incus error.
# Logs: .work/nested/<run-id>/ (run.log, console-<stage>.log, result-<stage>.json); .work/nested/latest points at the newest run.
# Knobs: HS_NESTED_ISO (default result-iso/iso/homeserver-installer.iso), HS_NESTED_INCUS (the incus command), HS_NESTED_CPU, _MEM, _DISK.
set -uo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
lib="$root/scripts/dev/nested_lib.py"
incus=${HS_NESTED_INCUS:-incus}
py=${HS_PYTHON:-python3}
cmd=${1:-}
[ $# -eq 0 ] || shift

usage() { echo "usage: scripts/dev/nested.sh run [--iso <file>] [--stage iso|smoke|all] [--keep] [--name <vm>] | preflight | plan [stage]" >&2; }

case "$cmd" in
  preflight) exec "$py" -I "$lib" preflight ;;
  plan)
    if [ $# -gt 0 ]; then exec "$py" -I "$lib" plan "$1"; fi
    for s in iso smoke; do echo "== $s"; "$py" -I "$lib" plan "$s" || exit $?; done
    exit 0 ;;
  run) ;;
  *) usage; exit 2 ;;
esac

iso=${HS_NESTED_ISO:-$root/result-iso/iso/homeserver-installer.iso}; stage=all; keep=false; name=""
while [ $# -gt 0 ]; do
  case $1 in
    --iso) iso=${2:?}; shift 2 ;;
    --stage) stage=${2:?}; shift 2 ;;
    --keep) keep=true; shift ;;
    --name) name=${2:?}; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done
case $stage in iso|smoke|all) ;; *) usage; exit 2 ;; esac
[ "$stage" != smoke ] || [ -n "$name" ] || { echo "--stage smoke needs --name <vm> of an installed VM (kept with --keep)" >&2; exit 2; }

runid=$(date +%Y%m%d-%H%M%S)-$$
logdir=$root/.work/nested/$runid
mkdir -p "$logdir" && ln -sfn "$runid" "$root/.work/nested/latest"
exec > >(tee -a "$logdir/run.log") 2>&1

echo "== preflight"
"$py" -I "$lib" preflight || { echo "Cannot run nested VMs here: use scripts/dev/t vm (docs/dev-environment.md)."; exit 3; }
if [ "$stage" != smoke ]; then
  "$py" -I "$lib" iso-check "$iso" || { echo "no usable ISO: build it with scripts/dev/build-iso.sh or pass --iso"; exit 4; }
fi

[ -n "$name" ] || name=hs-nested-$$
# a throwaway password and key for this run only; the password never appears in argv, only in the environment of the driver
HS_NESTED_PASSWORD=$(head -c 18 /dev/urandom | base64 | tr -d '/+=\n'); export HS_NESTED_PASSWORD
if [ "$stage" != smoke ]; then
  ssh-keygen -q -t ed25519 -N '' -C hs-nested -f "$logdir/key" || { echo "ssh-keygen failed"; exit 4; }
  HS_NESTED_PUBKEY=$(cat "$logdir/key.pub"); export HS_NESTED_PUBKEY
else
  [ -n "${HS_NESTED_PASSWORD_FILE:-}" ] && HS_NESTED_PASSWORD=$(cat "$HS_NESTED_PASSWORD_FILE")
fi
echo "$HS_NESTED_PASSWORD" > "$logdir/password" && chmod 600 "$logdir/password"

cleanup() {
  if $keep; then echo "kept: $incus delete -f $name (password in $logdir/password)"; return; fi
  "$incus" delete -f "$name" >/dev/null 2>&1
}
trap cleanup EXIT

vm_state() { "$incus" list "$name" -f csv -c s 2>/dev/null | head -n1; }
wait_state() {   # wait_state <STATE> <seconds>
  local n=0
  while [ "$(vm_state)" != "$1" ]; do
    n=$((n + 5)); [ "$n" -le "$2" ] || return 1; sleep 5
  done
}
infra() { echo "ERROR: $*"; exit 4; }

rc=0
if [ "$stage" != smoke ]; then
  echo "== create the VM $name from the ISO"
  "$incus" init "$name" --empty --vm \
    -c security.secureboot=false -c "limits.cpu=${HS_NESTED_CPU:-2}" -c "limits.memory=${HS_NESTED_MEM:-3GiB}" \
    -d "root,size=${HS_NESTED_DISK:-20GiB}" || infra "incus init failed"
  "$incus" config device add "$name" iso disk "source=$iso" boot.priority=10 || infra "attaching the ISO failed"
  "$incus" start "$name" || infra "incus start failed"
  echo "== stage iso: boot check and unattended install"
  "$py" -I "$lib" drive iso --vm "$name" --logdir "$logdir"; rc=$?
  [ "$rc" -eq 0 ] || exit "$rc"
  wait_state STOPPED 120 || infra "the VM did not power off after the install"
  "$incus" config device remove "$name" iso || infra "detaching the ISO failed"
fi
if [ "$stage" != iso ]; then
  echo "== stage smoke: boot the installed system"
  if [ "$(vm_state)" != RUNNING ]; then "$incus" start "$name" || infra "incus start failed"; fi
  "$py" -I "$lib" drive smoke --vm "$name" --logdir "$logdir"; rc=$?
fi
echo "== result: exit $rc (logs: $logdir)"
exit "$rc"
