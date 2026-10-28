#!/usr/bin/env bash
# Integration tests for the storage scripts, on loop devices. Needs root:
#   sudo bash tests/run.sh [name...]        (names: cheatsheet backup adopt crypt vault health migrate i18n commands pool zfs-plan guided phase4 dialogues pool-encrypted snapshots cleanup docs motd snapshots-auto smoke cheatsheet manage-legacy shares-ui matrix-hook dedupe generate-poster)
# CI runs them with REQUIRE_ALL=1 (a skipped test fails). Locally a test skips what the
# kernel can't do (no xfs driver, no device-mapper).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
status=0
names=("$@")
[ ${#names[@]} -gt 0 ] || names=(backup adopt crypt vault health migrate i18n commands pool zfs-plan pool-look pool-bare pool-change disk-event luks-class ct-bindings ct-change share-overview share-change share-delete share-purge user-access user-change overview-status deck-status state-db system-change backup-read backup-change backup-drill-ct jobs-change logs read-timing guided phase4 dialogues pool-encrypted snapshots cleanup docs motd snapshots-auto smoke cheatsheet manage-legacy shares-ui matrix-hook dedupe generate-poster)
for n in "${names[@]}"; do
  echo "== $n"
  bash "$here/$n.sh" || status=1
done
exit $status
