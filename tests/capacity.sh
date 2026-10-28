#!/usr/bin/env bash
# scripts/forecast.py, the usage table of scripts/state-db.py and scripts/lib/capacity.sh.
# Fake smartctl, fake state folder, python3 stdlib only, no root.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
command -v python3 >/dev/null || { echo "python3 missing: skipped"; exit 0; }
wp() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }
if command -v cygpath >/dev/null 2>&1; then export HS_TEST_BASH=$(cygpath -m "$BASH"); fi
FC="python3 $(wp "$SCRIPTS")/forecast.py"
D=86400

echo "-- days until full"
# 100 units, 10 per day from 0 at day 0: at day 6 used 60, full in 4 days
series() { local i; for i in 0 1 2 3 4 5 6; do printf '%d\t%d\t100\n' $((i * D)) $((i * 10)); done; }
check_eq "a straight line" "4" "$(series | $FC days-to-full)"
check_eq "not growing" "-" "$(for i in 0 1 2 3 4 5 6; do printf '%d\t50\t100\n' $((i * D)); done | $FC days-to-full)"
check_eq "shrinking" "-" "$(for i in 0 1 2 3 4 5 6; do printf '%d\t%d\t100\n' $((i * D)) $((80 - i)); done | $FC days-to-full)"
check_eq "too few readings" "-" "$(series | head -n 3 | $FC days-to-full)"
check_eq "too short a span" "-" "$(for i in 0 1 2 3 4 5 6; do printf '%d\t%d\t100\n' $((i * 3600)) $((i * 10)); done | $FC days-to-full)"
check_eq "already full" "0" "$(for i in 0 1 2 3 4 5 6; do printf '%d\t%d\t100\n' $((i * D)) $((94 + i)); done | $FC days-to-full)"
check_eq "empty input" "-" "$($FC days-to-full </dev/null)"
check_eq "growth per day in percent" "10.0" "$(series | $FC growth-pct-per-day)"
check_eq "old readings outside the window are ignored" "4" "$({ printf '0\t99\t100\n'; for i in 0 1 2 3 4 5 6; do printf '%d\t%d\t100\n' $((100 * D + i * D)) $((i * 10)); done; } | $FC days-to-full --window 30)"

echo "-- SSD wear"
check_eq "NVMe percentage used" "37" "$(printf 'Critical Warning:                   0x00\nPercentage Used:                    37%%\n' | $FC wear)"
check_eq "SATA wear leveling count counts down" "12" "$(printf '177 Wear_Leveling_Count     0x0013   088   088   000    Pre-fail  Always       -       132\n' | $FC wear)"
check_eq "a disk without a wear value" "-" "$(printf '  5 Reallocated_Sector_Ct   0x0033   100   100   010    Pre-fail  Always       -       0\n' | $FC wear)"
check_eq "hours between two times" "50.0" "$($FC cache-age-hours 180000 0)"

echo "-- usage rows in the state database"
export HS_STATE_DIR=$(wp "$WORK/state") HS_PLAIN=1 HS_CALLER=test
mkdir -p "$WORK/state"
S="bash $SCRIPTS/state.sh"
check_eq "no database, no rows" "" "$($S usage zfs:tank 60)"
HS_NOW=1000000 $S usage-record zfs:tank 50 100
HS_NOW=1000100 $S usage-record zfs:tank 51 100      # within the hour: dropped
HS_NOW=$((1000000 + 4000)) $S usage-record zfs:tank 52 100
check_eq "one reading per hour" "2" "$(HS_NOW=$((1000000 + 5000)) $S usage zfs:tank 60 | wc -l | tr -d ' ')"
check_eq "other volume is separate" "" "$(HS_NOW=$((1000000 + 5000)) $S usage bulk 60)"
$S usage-record "bad key with spaces" 1 100 && fail "a bad key is refused" || pass "a bad key is refused"

echo "-- capacity problems"
export HS_BACKUP_STATE=$WORK/none HS_CAP_CACHE=$WORK/nocache
# fake pool tooling: no zpool, no snapraid: only the root filesystem and the backup figure
. "$SCRIPTS/lib/capacity.sh"
for i in 0 1 2 3 4 5 6; do HS_NOW=$((2000000 + i * D)) $S usage-record backup $((50 + i * 5)) 100; done
printf 'used_pct=80\n' > "$WORK/backup.state"
out=$(HS_BACKUP_STATE=$WORK/backup.state HS_NOW=$((2000000 + 6 * D)) HS_CAP_MIN_FILL=60 capacity_problems)
check_out "the backup disk is forecast (4 days: urgent)" "^forecast:backup:urgent	the backup disk will be full in about 4 days" echo "$out"
check_out "the key has no numbers" "^forecast:backup:urgent	" echo "$out"
out=$(HS_BACKUP_STATE=$WORK/backup.state HS_NOW=$((2000000 + 6 * D)) HS_CAP_WARN_DAYS=2 capacity_problems)
if grep -q '^forecast:backup' <<<"$out"; then fail "far enough away is quiet"; else pass "far enough away is quiet"; fi
printf 'used_pct=40\n' > "$WORK/backup.state"
out=$(HS_BACKUP_STATE=$WORK/backup.state HS_NOW=$((2000000 + 6 * D)) capacity_problems)
if grep -q '^forecast:backup' <<<"$out"; then fail "a mostly empty disk is quiet"; else pass "a mostly empty disk is quiet"; fi

echo "-- the backup disk in bytes, and urgent below 7 days"
G=1000000000
for i in 0 1 2 3 4 5 6; do HS_NOW=$((3000000 + i * D)) $S usage-record backup-bytes $((500 * G + i * 50 * G)) $((1000 * G)); done
printf 'used_pct=80
used_bytes=%s
size_bytes=%s
' $((800 * G)) $((1000 * G)) > "$WORK/backup.state"
out=$(HS_BACKUP_STATE=$WORK/backup.state HS_NOW=$((3000000 + 6 * D)) capacity_problems)
check_out "the byte readings give the forecast, 4 days is urgent" "^forecast:backup:urgent	the backup disk will be full in about 4 days" echo "$out"
if grep -q '^forecast:backup	' <<<"$out"; then fail "urgent replaces the plain key"; else pass "urgent replaces the plain key"; fi
out=$(HS_BACKUP_STATE=$WORK/backup.state HS_NOW=$((3000000 + 6 * D)) HS_CAP_URGENT_DAYS=3 capacity_problems)
check_out "7 to 30 days keeps the plain key (threshold 3 here)" "^forecast:backup	the backup disk will be full" echo "$out"
if grep -q ':urgent' <<<"$out"; then fail "no urgent key above the threshold"; else pass "no urgent key above the threshold"; fi

echo "-- wear of an SSD and the cache backlog"
cat > "$WORK/smartctl" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  *nvme0n1*) printf 'Percentage Used:                    %s%%\n' "${WEAR_NVME:-10}" ;;
  *sda*)     printf '177 Wear_Leveling_Count     0x0013   %s   088   000    Pre-fail  Always       -       1\n' "${WEAR_SDA:-100}" ;;
esac
FAKE
chmod +x "$WORK/smartctl"
export HS_SMARTCTL=$WORK/smartctl HS_CAP_DISKS="printf 'nvme0n1\nsda\n'"
out=$(WEAR_NVME=82 WEAR_SDA=004 capacity_problems)
check_out "80 % is a plan" "^ssd:nvme0n1:wear	SSD nvme0n1 has used 82 %" echo "$out"
check_out "96 % is urgent" "^ssd:sda:wear-high	SSD sda has used 96 %" echo "$out"
out=$(capacity_problems)
if grep -q '^ssd:' <<<"$out"; then fail "healthy SSDs are quiet"; else pass "healthy SSDs are quiet"; fi
mkdir -p "$WORK/nocache"
touch -d '3 days ago' "$WORK/nocache/old.bin"
check_out "a three day old upload is a backlog" "^space:cache-backlog	uploads have been waiting in the SSD cache for (7[0-9]|8[0-9]) hours" capacity_problems
rm "$WORK/nocache/old.bin"; touch "$WORK/nocache/new.bin"
out=$(capacity_problems)
if grep -q '^space:cache-backlog' <<<"$out"; then fail "a fresh upload is fine"; else pass "a fresh upload is fine"; fi

finish
