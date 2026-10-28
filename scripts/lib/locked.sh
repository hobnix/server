# shellcheck shell=bash
# storage_locked: true while encrypted storage waits for `hs unlock` (marker /run/hs/storage-locked,
# written by unlock.sh --boot). Never exists on a server without encryption.
# HS_LOCKED_MARKER points tests at another path.
storage_locked() { [ -e "${HS_LOCKED_MARKER:-/run/hs/storage-locked}" ]; }

# refuse_if_locked: for commands that rebuild/restart the system. Needs lib/ui.sh (fail exits 1).
refuse_if_locked() {
  if storage_locked; then
    note "A rebuild would restart services while the encrypted disks are closed (Incus would fail)."
    fail "The encrypted storage is locked. Run first: hs unlock"
  fi
}
