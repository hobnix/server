# shellcheck shell=bash
# What the last rebuild switched to, for `hs update` ("nothing changed: skip the rebuild") and the health check ("running system = checkout?").
# The stamp is $HS_STATE_DIR/last-rebuild-rev: rev=<git HEAD>, prev=<the rev before the last change of rev>, dirty=0|1 (tracked files changed in the checkout), machine=<fingerprint>, time=<epoch>.
#   config_fingerprint [repo]   a short hash of the two files that are NOT in Git but change the system: machine.toml and hardware-configuration.nix
#   stamp_get <key>             one value of the stamp, or nothing
# Test knobs: HS_REPO, HS_MACHINE_FILE, HS_STATE_DIR.
config_fingerprint() {
  local repo=${1:-${HS_REPO:-/etc/nixos}} m h
  m=${HS_MACHINE_FILE:-$repo/machine.toml}
  h=$repo/hardware-configuration.nix
  { [ -r "$m" ] && cat "$m"; printf '\n--\n'; [ -r "$h" ] && cat "$h"; } 2>/dev/null | sha256sum | cut -c1-16
}
stamp_get() { sed -n "s/^$1=//p" "${HS_STATE_DIR:-/var/lib/hs}/last-rebuild-rev" 2>/dev/null | head -n1 || true; }
