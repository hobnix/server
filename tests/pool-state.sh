#!/usr/bin/env bash
# scripts/pool-state.sh (hs sys pool state): the bulk lock, the health-check pause, last scrub and last parity sync, as read-only lines.
# Fake flock, zpool and systemctl: no root, no ZFS.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en HS_LOCK=$WORK/lock HS_LOCK_ADMIN=$WORK/admin HS_BULK_PAUSE=$WORK/paused HS_BULK_TYPE_FILE=$WORK/type
export HS_SCRUB_STATE=$WORK/scrub.state HS_SNAPRAID_CONTENT=$WORK/content HS_NOW=1790000000
BIN=$WORK/bin; mkdir -p "$BIN"
# flock -n 8 succeeds unless $WORK/busy exists
printf '#!/usr/bin/env bash\n[ ! -e "%s/busy" ]\n' "$WORK" > "$BIN/flock"
cat > "$WORK/zpool" <<'FAKE'
#!/usr/bin/env bash
case "$1 $2" in
  "list -H") [ "$3" != nopool ] ;;
  "status bulk") printf '  pool: bulk\n scan: scrub repaired 0B in 00:10:02 with 0 errors on Sun Oct  4 00:24:01 2026\n' ;;
  "status fast") printf '  pool: fast\n scan: scrub in progress since Mon Oct  5 01:00:00 2026\n' ;;
esac
FAKE
cat > "$WORK/systemctl" <<'FAKE'
#!/usr/bin/env bash
[ "$1 $2" = "is-active --quiet" ] && [ -e "$WORK/active-$3" ]
FAKE
chmod +x "$BIN/flock" "$WORK/zpool" "$WORK/systemctl"
export PATH="$BIN:$PATH" HS_ZPOOL=$WORK/zpool HS_SYSTEMCTL=$WORK/systemctl WORK
S="bash $SCRIPTS/pool-state.sh"
first() { $S "$@" | awk -F'\t' -v k="$1" '$1 == k'; }

echo "-- the lock"
check_eq "no lock file yet: free" "lock	free" "$($S | awk -F'\t' '$1 == "lock" { print $1 "\t" $2 }')"
: > "$HS_LOCK"
check_eq "file there, nobody holds it: free" "free" "$($S | awk -F'\t' '$1 == "lock" { print $2 }')"
: > "$WORK/busy"
check_eq "held: busy" "busy" "$($S | awk -F'\t' '$1 == "lock" { print $2 }')"
: > "$HS_LOCK_ADMIN"
check_eq "a pool change owns it: pool-change" "pool-change" "$($S | awk -F'\t' '$1 == "lock" { print $2 }')"
rm -f "$HS_LOCK_ADMIN" "$WORK/busy"
check_eq "not paused" "paused	no" "$($S | awk -F'\t' '$1 == "paused" { print $1 "\t" $2 }')"
: > "$HS_BULK_PAUSE"
check_eq "paused by the health check" "paused	yes" "$($S | awk -F'\t' '$1 == "paused" { print $1 "\t" $2 }')"
check_eq "the lock file is only looked at: still there, still empty" "0" "$(wc -c < "$HS_LOCK" | tr -d ' ')"

echo "-- ZFS: the scan line of zpool status"
echo zfs > "$HS_BULK_TYPE_FILE"
check_eq "bulk: finished without errors" "scrub	bulk	ok" "$($S bulk | awk -F'\t' '$1 == "scrub" { print $1 "\t" $2 "\t" $3 }')"
check_eq "bulk: when" "finished Sun Oct  4 00:24:01 2026, no errors" "$($S bulk | awk -F'\t' '$1 == "scrub" { print $4 }')"
check_eq "fast: in progress" "scrub	fast	running" "$($S fast | awk -F'\t' '$1 == "scrub" { print $1 "\t" $2 "\t" $3 }')"
check_eq "both pools without an argument" "bulk fast" "$($S | awk -F'\t' '$1 == "scrub" { printf "%s ", $2 }' | sed 's/ $//')"
check_eq "no sync line on ZFS" "" "$($S | awk -F'\t' '$1 == "sync"')"
rc=0; $S nopool >/dev/null 2>&1 || rc=$?
check_eq "an unknown pool name is refused" 1 "$rc"

echo "-- SnapRAID: the scrub marker and the parity file"
echo snapraid > "$HS_BULK_TYPE_FILE"
check_eq "never scrubbed, never synced" "scrub	bulk	never|sync	bulk	never" "$($S bulk | awk -F'\t' '$1 == "scrub" || $1 == "sync" { printf "%s\t%s\t%s|", $1, $2, $3 }' | sed 's/|$//')"
echo 1789913600 > "$HS_SCRUB_STATE"; : > "$HS_SNAPRAID_CONTENT"; touch -d @1789827200 "$HS_SNAPRAID_CONTENT"
check_eq "scrub finished, 1 day ago" "scrub	bulk	ok" "$($S bulk | awk -F'\t' '$1 == "scrub" { print $1 "\t" $2 "\t" $3 }')"
check_eq "sync done, 2 days ago" "sync	bulk	ok" "$($S bulk | awk -F'\t' '$1 == "sync" { print $1 "\t" $2 "\t" $3 }')"
: > "$WORK/active-hs-bulk-sync.service"
check_eq "a running sync" "running" "$($S bulk | awk -F'\t' '$1 == "sync" { print $3 }')"
check_eq "every line has 4 columns, none empty" "" "$($S | awk -F'\t' 'NF < 3 || $1 == "" || $2 == "" { print }')"
finish
