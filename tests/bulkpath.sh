#!/usr/bin/env bash
# scripts/lib/bulkpath.sh: the one place that says where the disks of the bulk array are mounted. No root.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
unset HS_DISKS_ROOT HS_DETACHED_ROOT
. "$SCRIPTS/lib/bulkpath.sh"

echo "-- the helper"
check_eq "root of the pool disks" "/var/lib/hs/disks" "$(disks_root)"
check_eq "detached disks live under /mnt/bulk" "/mnt/bulk/data-04" "$(detached_dir data-04)"
check_eq "a data disk" "/var/lib/hs/disks/data-04" "$(disk_dir data-04)"
check_eq "by its label" "/var/lib/hs/disks/data-04" "$(disk_dir bulk-data-04)"
check_eq "a parity disk" "/var/lib/hs/disks/parity-1" "$(disk_dir bulk-parity-1)"
check_eq "the knob moves them all" "$WORK/x/data-02" "$(HS_DISKS_ROOT=$WORK/x disk_dir data-02)"

echo "-- no script builds a disk path by hand any more"
# code lines (not comments, not texts shown to people) that name /mnt/bulk/data-* or /mnt/bulk/parity-* directly
hits=$(grep -rnE '/mnt/bulk/(data|parity)-' "$SCRIPTS" --include='*.sh' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | grep -vE '(pdone|plt|pl |echo|printf|say |note |warn |fail |help)' | grep -v '/lib/bulkpath.sh:' | grep -v '/rebuild.sh:' || true)   # rebuild.sh names the OLD place on purpose (it moves the disks away from it)
check_eq "every disk path comes from disk_dir / disks_root" "" "$hits"
hits=$(grep -rnE '"/mnt/bulk/\$' "$SCRIPTS" --include='*.sh' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
check_eq "no /mnt/bulk/\$name either" "" "$hits"

echo "-- the scripts that use it still parse"
bad=""
for f in bulk-mount bulk-sync monitor ct-bindings share-overview share-purge manage-shares manage-pool disk-move disk-recover; do bash -n "$SCRIPTS/$f.sh" 2>/dev/null || bad="$bad $f"; done
check_eq "bash -n" "" "$bad"

finish
