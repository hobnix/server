#!/usr/bin/env bash
# scripts/backup.sh read modes for the interface (hs sys backup state|overview|snapshots): no restic, no disk, no root.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en HS_STATE_DIR=$WORK/state HS_BULK=$WORK/bulk HS_BACKUP_NO_MOUNT=1 HS_BACKUP_NEW_SHARES=on
unset HS_CALLER
mkdir -p "$WORK/state" "$WORK/bulk/shares/docs" "$WORK/bulk/shares/media" "$WORK/bulk/sensitive/immich"
echo secret > "$WORK/state/restic-password"
printf 'media\n' > "$WORK/state/backup-off"
printf 'web\njellyfin\n' > "$WORK/state/backup-instances"
printf '%s\t%s\n%s\t%s\n' "$WORK/bulk/shares/docs" 5000000 "$WORK/bulk/shares/media" 1200000000000 > "$WORK/state/share-sizes"
printf 'last_ok=1000\nlast_try=1100\nstatus=ok\nused_pct=41\nsnapshots=12\nrepo_size=88G\noffsite_ok=900\nlast_drill=800\ndrill_ok=800\n' > "$WORK/state/backup.state"
b() { bash "$SCRIPTS/backup.sh" "$@"; }
has() { grep -qF -- "$1" <<<"$out"; }
T=$'\t'

echo "-- state"
out=$(b --state)
has "configured${T}yes" && has "last_ok${T}1000" && has "snapshots${T}12" && has "disk${T}present" && pass "the old keys are still there" || fail "state: $out"
has "offsite${T}" && has "offsite_ok${T}900" && has "last_drill${T}800" && has "drill_ok${T}800" && pass "off-site and drill are in the state" || fail "state new keys: $out"
has "used_bytes${T}" && has "size_bytes${T}" && pass "the byte figures are keys of their own" || fail "bytes: $out"
has "next${T}" && pass "next run is a key (empty without systemd)" || fail "next: $out"
printf 'sftp:me@nas:/backup\n' > "$WORK/state/backup-offsite"
out=$(b --state)
has "offsite${T}sftp:me@nas:/backup" && pass "the off-site repository is named" || fail "offsite: $out"

echo "-- overview"
out=$(b --overview)
has "shares${T}docs${T}on${T}5000000" && pass "a share in the backup with its size" || fail "docs: $out"
has "shares${T}media${T}off${T}1200000000000" && pass "a share left out keeps its size" || fail "media: $out"
has "sensitive${T}immich${T}on${T}-" && pass "an unmeasured share has - as size" || fail "immich: $out"
has "ct${T}web${T}on${T}-" && has "ct${T}jellyfin${T}on${T}-" && pass "the instances in the backup" || fail "ct: $out"
has "always${T}domain controller${T}on" && has "always${T}host files${T}on" && pass "the parts that are always in" || fail "always: $out"

echo "-- snapshots"
out=$(b --snapshots 'bad tag' 2>&1 || true)
has "unknown tag" && pass "a tag that is not shares, host or ct:<name> is refused" || fail "tag: $out"
out=$(b --snapshots 'ct:web;rm' 2>&1 || true)
has "unknown tag" && pass "no shell characters in a tag" || fail "tag chars: $out"

echo "-- find (a fake restic and the repository folder)"
if have jq; then
  mkdir -p "$WORK/repo" "$WORK/bin"; : > "$WORK/repo/config"
  cat > "$WORK/bin/restic" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  *snapshots*--json*) echo '[{"id":"abcdef0123456789","time":"2026-10-20T04:00:01.5Z"},{"id":"1234567890abcdef","time":"2026-10-21T04:00:02Z"}]' ;;
  *find*--json*) echo '[{"snapshot":"abcdef0123456789","matches":[{"path":"/bulk/shares/docs/Rechnung 2025.pdf","type":"file","size":1234}]},{"snapshot":"1234567890abcdef","matches":[{"path":"/bulk/shares/docs/Rechnung 2025.pdf","type":"file","size":1300},{"path":"/bulk/shares/docs/Rechnungen","type":"dir"}]}]' ;;
esac
FAKE
  chmod +x "$WORK/bin/restic"
  out=$(PATH="$WORK/bin:$PATH" HS_BACKUP_MOUNT=$WORK/mnt HS_BACKUP_REPO=$WORK/repo b --find Rechnung 2>&1 || true)
  if has "abcdef01${T}2026-10-20 04:00${T}/bulk/shares/docs/Rechnung 2025.pdf${T}file${T}1234"; then pass "a hit: short snapshot id, time, path, type, bytes"; else fail "find: $out"; fi
  has "12345678${T}2026-10-21 04:00${T}/bulk/shares/docs/Rechnungen${T}dir${T}0" && pass "a folder has size 0" || fail "find dir: $out"
  check_eq "one row per match" 3 "$(grep -c "${T}" <<<"$out")"
  out=$(PATH="$WORK/bin:$PATH" b --find 2>&1 || true); has "usage" && pass "no word: usage" || fail "no word: $out"
else
  skip "jq missing"
fi

finish
