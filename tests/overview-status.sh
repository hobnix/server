#!/usr/bin/env bash
# scripts/overview-status.sh (hs sys status): the facts of the Overview as tab separated lines. Fake unlock, jobs, share-cache,
# disk-health, monitor and incus: no root, no disks.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en HS_STATE_DIR=$WORK/state HS_LOCKED_MARKER=$WORK/no-marker
unset HS_CALLER HS_GUIDED_TTY
mkdir -p "$WORK/state"
now=$(date +%s)
printf 'last_try=%s\nstatus=ok\nlast_ok=%s\n' "$((now - 7200))" "$((now - 7200))" > "$WORK/state/backup.state"
printf '2026-10-07 14:56\tplugged in\tzd16, unknown model: empty\n2026-10-08 09:00\ttaken out\tsdz, X: empty\n' > "$WORK/state/disk-events"

cat > "$WORK/unlock" <<'FAKE'
#!/usr/bin/env bash
printf '  Encrypted storage: open ✓\n\nTYPE  DEVICE  STATE\nZFS   fast    open\n'
FAKE
cat > "$WORK/jobs" <<'FAKE'
#!/usr/bin/env bash
printf 'hs-backup.service\tBackup\t09.10. 04:00\t08.10. 04:00\tok\nhs-bulk-scrub.service\tScrub\t11.10. 05:00\t-\tnever\nhs-bulk-sync.service\tSync\t08.10. 15:00\t08.10. 11:00\tfailed\n'
FAKE
cat > "$WORK/cache" <<'FAKE'
#!/usr/bin/env bash
printf 'Upload cache\n  On the SSD pool: 12G of 200G (6%%)\n'
FAKE
cat > "$WORK/smart" <<'FAKE'
#!/usr/bin/env bash
printf 'sda\t250\tSSD\tx\tOK\nsdb\t4000\tHDD\tx\tWATCH\nsdc\t4000\tHDD\tx\tBAD\n'
FAKE
cat > "$WORK/monitor" <<'FAKE'
#!/usr/bin/env bash
printf 'sda\t250\tSSD\tsystem\t31\nsdb\t4000\tHDD\tbulk\t44\nsdc\t4000\tHDD\tbulk\t-\n'
FAKE
cat > "$WORK/incus" <<'FAKE'
#!/usr/bin/env bash
printf 'RUNNING\nRUNNING\nSTOPPED\n'
FAKE
chmod +x "$WORK/unlock" "$WORK/jobs" "$WORK/cache" "$WORK/smart" "$WORK/monitor" "$WORK/incus"
export HS_UNLOCK=$WORK/unlock HS_JOBS=$WORK/jobs HS_SHARE_CACHE=$WORK/cache HS_DISK_HEALTH=$WORK/smart HS_MONITOR=$WORK/monitor HS_INCUS=$WORK/incus
S="bash $SCRIPTS/overview-status.sh"

out=$($S)
echo "-- every fact on its own line"
check_eq "backup: ok, about two hours old" "ok 1" "$(awk -F'\t' '$1 == "backup" { print $2, ($3 >= 7200 && $3 < 7300) }' <<<"$out")"
check_eq "encryption" "encryption	open" "$(grep '^encryption' <<<"$out")"
check_eq "the two timers, with their result, last and next run" "job	hs-bulk-sync.service	failed	08.10. 11:00	08.10. 15:00
job	hs-bulk-scrub.service	never	-	11.10. 05:00" "$(grep '^job' <<<"$out" | sort -r)"
check_eq "the upload cache with its percentage" "cache	12G of 200G (6%)	6" "$(grep '^cache' <<<"$out")"
check_eq "disk health: three disks, two findings" "smart	3	sdb WATCH,sdc BAD" "$(grep '^smart' <<<"$out")"
check_eq "instances: two of three run" "instances	2	3" "$(grep '^instances' <<<"$out")"
check_eq "the hottest disk" "hottest	sdb	44" "$(grep '^hottest' <<<"$out")"
check_eq "the last disk event" "event	2026-10-08 09:00	taken out sdz, X: empty" "$(grep '^event' <<<"$out")"

echo "-- states: locked boot, failed backup, nothing encrypted"
touch "$WORK/marker"
check_eq "the marker of a locked boot wins" "encryption	locked" "$(HS_LOCKED_MARKER=$WORK/marker $S | grep '^encryption')"
printf 'status=failed\nlast_ok=%s\n' "$((now - 90000))" > "$WORK/state/backup.state"
check_eq "a failed backup keeps the age of the last good one" "backup	failed" "$($S | awk -F'\t' '$1 == "backup" { print $1 "\t" $2 }')"
printf 'status=new\n' > "$WORK/state/backup.state"
check_eq "set up, no backup yet" "backup	new	-" "$($S | grep '^backup')"
printf '#!/usr/bin/env bash\necho "Nothing encrypted."\n' > "$WORK/unlock"
check_eq "nothing encrypted" "encryption	none" "$($S | grep '^encryption')"

echo "-- a source that cannot be read leaves its line out"
printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/incus"; printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/smart"; rm -f "$WORK/state/backup.state"
out=$($S)
check_eq "no instances, no smart, no backup line" "0" "$(grep -c '^instances\|^smart\|^backup' <<<"$out")"
check_eq "the rest is still there" "1" "$(grep -c '^hottest' <<<"$out")"

echo "-- the registry row"
check_out "hs sys status runs it" "hottest	sdb" env HS_CALLER=test bash "$SCRIPTS/lib/hs.sh" sys status
finish
