#!/usr/bin/env bash
# hs backup init and hs vault init name a missing tool before they change anything (rehearsal of Case A, #163): the tools are left off PATH.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

# a PATH with the basic tools only: no restic, mkfs.ext4, wipefs, cryptsetup
BIN=$WORK/bin; mkdir -p "$BIN"
for t in bash sh dirname basename cat sed tr date env grep awk readlink mkdir id uname ls head tail cut sort wc rm cp mv touch printf stat mktemp find jq tput; do
  p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$BIN/$t"
done
export HS_STATE_DIR=$WORK/state HS_PLAIN=1 HS_CALLER= HS_BACKUP_YES=1
mkdir -p "$WORK/state"

echo "-- hs backup init"
out=$(PATH=$BIN bash "$SCRIPTS/backup.sh" init /dev/null 2>&1); rc=$?
check "backup init stops without restic" test "$rc" != 0
check "and names what is missing" grep -q 'restic' <<<"$out"
check "and says nothing was changed" grep -q 'Nothing was changed' <<<"$out"
out=$(PATH=$BIN bash "$SCRIPTS/backup.sh" init --dry-run /dev/null 2>&1); rc=$?
check "the dry run stops too" test "$rc" != 0

echo "-- hs vault init"
out=$(PATH=$BIN bash "$SCRIPTS/vault.sh" init --dry-run /dev/null 2>&1); rc=$?
check "vault init stops without cryptsetup" test "$rc" != 0
check "and names cryptsetup" grep -q 'cryptsetup' <<<"$out"
finish
