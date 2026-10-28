#!/usr/bin/env bash
# hs share repair / hs share repair (sync-shares.sh) and hs share <share> cache, hs sys cache state (share-cache.sh):
# the parts that need no real Samba, ZFS or mergerfs, with fake net, testparm, zfs on PATH. No root.
# sync-shares: only the parent /bulk/sensitive carries folders here (folders under /bulk/shares are checked for their owner
# with stat, which needs the real path); the folders of /bulk/shares are the real server's to test.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1
BIN=$WORK/bin; mkdir -p "$BIN"
export CALLS=$WORK/calls; : > "$CALLS"

cat > "$BIN/net" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  "conf listshares") printf 'photos\nghost\n' ;;
  "conf getparm photos path") echo /bulk/sensitive/photos ;;
  "conf getparm ghost path") echo /nonexistent/ghost ;;
  "conf getparm "*) ;;
  *) echo "net $*" >> "$CALLS" ;;
esac
FAKE
cat > "$BIN/testparm" <<'FAKE'
#!/usr/bin/env bash
case "$*" in *security*) echo USER ;; *workgroup*) echo HOME ;; esac
FAKE
cat > "$BIN/zfs" <<'FAKE'
#!/usr/bin/env bash
# zfs list -H -o name -d 1 bulk/<parent>: the parent first, then its datasets
case "$*" in
  *bulk/shares) echo bulk/shares ;;
  *bulk/sensitive) printf 'bulk/sensitive\nbulk/sensitive/photos\nbulk/sensitive/old\nbulk/sensitive/Global\n' ;;
esac
FAKE
chmod +x "$BIN"/*
export PATH=$BIN:$PATH

if [ "$(cat /etc/hs/bulk-type 2>/dev/null || echo zfs)" = snapraid ]; then
  skip "this machine uses the snapraid layout: the ZFS listing is faked, the test would not mean anything"; finish; exit $?
fi

echo "-- hs share repair --check"
S="bash $SCRIPTS/sync-shares.sh"
out=$($S --check 2>&1)
check_out "a share that exists with the right path is ok" "^photos +ok" echo "$out"
check_out "a folder without a share is missing" "^old +missing \(/bulk/sensitive/old\)" echo "$out"
check_out "a reserved name is skipped" "^Global +name is reserved, skipped" echo "$out"
check_out "a registry share whose folder is gone is reported" "^ghost +folder /nonexistent/ghost is gone; remove with: hs share cleanup" echo "$out"
check_out "the summary names the fix" "1 share\(s\) missing. Add them with: hs share repair" echo "$out"
check_eq "--check changes nothing" "" "$(cat "$CALLS")"
check_out "an unknown option prints the usage" "usage: hs share repair" $S --bogus

echo "-- hs share repair (adds the missing ones)"
: > "$CALLS"
out=$($S 2>&1)
check_out "the new share is added" "^old +added \(/bulk/sensitive/old\)" echo "$out"
check_eq "sensitive folders are read-only and run as root" "net conf addshare old /bulk/sensitive/old writeable=n guest_ok=n
net conf setparm old force user root" "$(cat "$CALLS")"
check_out "without a domain the new share starts open, and it says so" "open to every Samba user" echo "$out"

echo "-- hs share repair (--fix-owner) goes through the registry"
fake=$WORK/reg; mkdir -p "$fake/lib"
cp "$SCRIPTS"/lib/hs.sh "$SCRIPTS"/lib/capability.sh "$SCRIPTS"/lib/registry-load.sh "$SCRIPTS"/lib/ui.sh "$SCRIPTS"/lib/i18n.sh "$SCRIPTS"/lib/setting.sh "$SCRIPTS"/lib/job.sh "$SCRIPTS/lib/registry.tsv" "$fake/lib/"; cp -r "$SCRIPTS"/lib/i18n "$fake/lib/"
cp "$SCRIPTS/sync-shares.sh" "$fake/"
F="env HS_CALLER=t HS_COMPLETE_DIR=$WORK/complete bash $fake/lib/hs.sh"
: > "$CALLS"
out=$($F share repair 2>&1)
check_out "the same script runs (with --fix-owner; no folder under /bulk/shares here)" "^old +added" echo "$out"

echo "-- hs share <share> cache on the ZFS layout"
C="bash $SCRIPTS/share-cache.sh"
check_out "status explains that the cache is a snapraid thing" "exists only on the snapraid layout" $C
check_eq "status exits 0" "0" "$($C >/dev/null 2>&1; echo $?)"
check_out "on is refused with the reason" "exists only on the snapraid layout" $C photos on
check_eq "and exits 1" "1" "$($C photos on >/dev/null 2>&1; echo $?)"
check_out "the size is refused too" "Only on the snapraid layout" $C size 100G
check_out "a size needs a unit" "usage" $C size 100
check_out "the verb must be on or off" "usage" $C photos maybe
check_out "one word is not enough" "usage: hs share <share> cache" $C photos
check_eq "--state: unsupported, nothing waiting (what the interface reads)" $'unsupported\t0' "$($C --state photos)"
check_eq "hs sys cache state through the registry" $'unsupported\t0' "$(cp "$SCRIPTS/share-cache.sh" "$fake/"; $F sys cache state photos)"
check_out "hs share <share> cache on through the registry" "exists only on the snapraid layout" $F share photos cache on
finish
