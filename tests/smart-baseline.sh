#!/usr/bin/env bash
# The daily SMART check: A) hs sys disk-health --readings (scripts/disk-health.sh) with fake smartctl and lsblk and the fixtures in
# tests/fixtures/smart; B) the baseline in state.db (scripts/state-db.py baseline-run, state.sh baseline|problems|events) with a fake
# reading source. Needs jq (part A) and python3, no root.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_DISK_HEALTH_NOROOT=1
# a path python can open (on the Windows workstation /tmp is a Git-bash path)
wp() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }
if command -v cygpath >/dev/null 2>&1; then export HS_TEST_BASH=$(cygpath -m "$BASH"); fi   # python must start THIS bash, not WSL's
FIX=$ROOT/tests/fixtures/smart
BIN=$WORK/bin; SMARTD=$WORK/smart; mkdir -p "$BIN" "$SMARTD"
export SMARTDIR=$SMARTD CALLS=$WORK/calls FIXDIR=$FIX; : > "$CALLS"

command -v python3 >/dev/null || { echo "python3 missing: skipped"; exit 0; }
have_jq=true
command -v jq >/dev/null 2>&1 || { have_jq=false; skip "jq is not installed: part A (--readings) not run"; }

if $have_jq; then
cp "$FIX/ata-hdd.json" "$SMARTD/sda.json"; cp "$FIX/nvme.json" "$SMARTD/nvme0n1.json"; cp "$FIX/sas.json" "$SMARTD/sdb.json"
cp "$FIX/ata-hdd.json" "$SMARTD/sdc.json"; cp "$FIX/usb-none.json" "$SMARTD/sdd.json"
: > "$SMARTD/sdc.asleep"
sed -i 's/"S1"/"S3"/' "$SMARTD/sdc.json"

cat > "$BIN/smartctl" <<'FAKE'
#!/usr/bin/env bash
echo "smartctl $*" >> "$CALLS"
dev=$(basename "${*: -1}")
case " $* " in
  *" -n standby "*) if [ -f "$SMARTDIR/$dev.asleep" ]; then cat "$FIXDIR/standby.json"; exit 0; fi ;;
esac
[ ! -f "$SMARTDIR/$dev.json" ] || cat "$SMARTDIR/$dev.json"
FAKE
cat > "$BIN/lsblk" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  "-dnb -o NAME,SIZE,ROTA") printf 'sda 4000000000000 1\nnvme0n1 500000000000 0\nsdb 8000000000000 1\nsdc 4000000000000 1\nsdd 32000000000 0\n' ;;
  *SERIAL*) case "$*" in *sdc*) echo SLEEPY ;; esac ;;
  *PKNAME*) ;;
  *TYPE*) echo disk ;;
esac
FAKE
chmod +x "$BIN"/*
export PATH=$BIN:$PATH
D="bash $SCRIPTS/disk-health.sh"
T=$'\t'

echo "-- A: --readings"
out=$($D --readings)
check_eq "an ATA disk: values, wwn, model" "sda${T}read${T}HDD${T}S1${T}5-5358-123456789${T}1000${T}0${T}0${T}0${T}3${T}-${T}-${T}-${T}-${T}-${T}WDC WD40EFRX" "$(grep '^sda' <<<"$out")"
n=$(grep '^nvme0n1' <<<"$out")
check_out "an NVMe disk: kind and wwn" "^nvme0n1${T}read${T}NVMe${T}N1${T}eui-9528-42${T}500${T}-${T}-${T}-${T}-${T}0${T}0${T}4${T}100${T}10${T}" echo "$n"
check_out "a SAS disk: grown defects, uncorrected, model" "^sdb${T}read${T}HDD${T}Z1${T}-${T}2000${T}2${T}-${T}0${T}-${T}.*ST8000NM$" echo "$out"
check_out "a sleeping disk is not read; serial from lsblk" "^sdc${T}asleep${T}HDD${T}SLEEPY${T}-${T}-${T}-${T}-${T}-${T}-${T}-${T}-${T}-${T}-${T}-${T}-$" echo "$out"
check_out "a disk without SMART data is unreadable, serial -" "^sdd${T}unreadable${T}SSD${T}-${T}-${T}" echo "$out"
check_eq "every line has 16 fields and none is empty" "" "$(awk -F'\t' 'NF != 16 { print NR": "NF } { for (i = 1; i <= NF; i++) if ($i == "") print NR": empty "i }' <<<"$out")"
check_eq "five disks" "5" "$(wc -l <<<"$out" | tr -d ' ')"
check_eq "the normal pass reads every disk with -n standby" "5" "$(grep -c -e '-n standby -j -a /dev/' "$CALLS" | tr -d ' ')"
: > "$CALLS"
out=$($D --readings --wake sdc)
check_eq "--wake reads only that disk" "1" "$(wc -l <<<"$out" | tr -d ' ')"
check_out "and it is read" "^sdc${T}read${T}HDD${T}S3${T}" echo "$out"
check_eq "without the standby flag" "0" "$(grep -c -e '-n standby' "$CALLS" | tr -d ' ')"
check_out "--wake needs names" "usage" $D --readings --wake
fi

# ---------------------------------------------------------------- B: the baseline in state.db
export HS_CALLER=test HS_STATE_DIR=$(wp "$WORK/state") HS_LOCKED_MARKER=$(wp "$WORK/no-marker")
export HS_MONITOR=$WORK/monitor HS_LSBLK=$WORK/lsblk-state HS_STATE_SMART_EVERY=0
mkdir -p "$WORK/state"
export MON=$WORK/mon.txt LS=$WORK/ls.txt RD=$WORK/rd.txt RD_WAKE=$WORK/rd-wake.txt DHCALLS=$WORK/dh.calls
: > "$DHCALLS"; : > "$RD_WAKE"
printf '#!/usr/bin/env bash\ncat "$MON"\n' > "$WORK/monitor"
printf '#!/usr/bin/env bash\ncat "$LS"\n' > "$WORK/lsblk-state"
cat > "$WORK/dh" <<'FAKE'
#!/usr/bin/env bash
if [ "${2:-}" = --wake ]; then echo "wake $3" >> "$DHCALLS"; cat "$RD_WAKE"; else cat "$RD"; fi
FAKE
chmod +x "$WORK/monitor" "$WORK/lsblk-state" "$WORK/dh"
export HS_DISK_HEALTH=$WORK/dh
S="bash $SCRIPTS/state.sh"
DAY=86400; T0=2000000

# rd name state kind serial wwn hours realloc pending uncorr crc crit media used spare thr model
rd() { local IFS=$'\t'; printf '%s\n' "$*"; }
SW=W1
s1() { rd sda read HDD S1 "$SW" "$1" "$2" "$3" 0 "$4" - - - - - WDC; }               # hours realloc pending crc
n1() { rd nvme0n1 read NVMe N1 E1 500 - - - - "$1" 0 "$2" "$3" 10 Samsung; }          # crit used spare
n2() { rd nvme1n1 read NVMe N2 E2 500 - - - - 0 0 "$1" 100 10 Samsung; }              # used
run_at() { HS_NOW=$((T0 + $1 * DAY)) $S baseline-run; }
prob_at() { HS_NOW=$((T0 + $1 * DAY)) $S problems; }
lvl() { $S baseline | awk -F'\t' -v s="$1" '$1 == s { print $4 }'; }
note_of() { $S baseline | awk -F'\t' -v s="$1" '$1 == s { print $18 }'; }

echo "-- B1: the first run seeds silently"
{ s1 1000 0 0 3; n1 0 4 100; } > "$RD"
run_at 0
check_eq "both disks healthy with the note first reading" $'N1\thealthy\tfirst reading\nS1\thealthy\tfirst reading' "$($S baseline | awk -F'\t' '{print $1 "\t" $4 "\t" $18}' | sort)"
check_eq "no event" "" "$($S events)"

echo "-- B2: CRC grows: watch"
{ s1 1000 0 0 5; n1 0 4 100; } > "$RD"
run_at 1
check_eq "S1 is watch" "watch" "$(lvl S1)"
check_out "problem smart-watch with the numbers" $'^disk:S1:smart-watch\t.*CRC 3 -> 5' prob_at 1
check_out "event smart-watch" $'\tsmart-watch\tS1\t' $S events

echo "-- B3: pending sectors: failing"
{ s1 1000 0 2 5; n1 0 4 100; } > "$RD"
run_at 2
check_eq "S1 is failing" "failing" "$(lvl S1)"
check_out "problem smart-failing" $'^disk:S1:smart-failing\t' prob_at 2
check_eq "and no smart-watch line for S1 any more" "0" "$(prob_at 2 | grep -c 'disk:S1:smart-watch')"

echo "-- B4: hold for 7 days"
run_at 3
check_eq "still failing the day after" "failing" "$(lvl S1)"
run_at 11
check_eq "healthy after 8 quiet days" "healthy" "$(lvl S1)"
check_eq "no smart problem" "0" "$(prob_at 11 | grep -c 'smart-')"

echo "-- B5: NVMe: critical warning, spare across the threshold, wear"
{ s1 1000 0 2 5; n1 0 4 100; n2 4; } > "$RD"
run_at 12
{ s1 1000 0 2 5; n1 4 4 100; n2 4; } > "$RD"
run_at 13
check_eq "critical warning 0 -> 4: failing" "failing" "$(lvl N1)"
{ s1 1000 0 2 5; n1 4 4 9; n2 7; } > "$RD"
run_at 14
check_out "spare 100 -> 9 across threshold 10 is in the note" "NVMe spare % 100 -> 9" note_of N1
check_eq "wear 4 -> 7: watch" "watch" "$(lvl N2)"

echo "-- B6: a counter that went down is a reset, not a verdict"
{ s1 1000 5 2 5; n1 4 4 9; n2 7; } > "$RD"
run_at 15
check_eq "realloc 0 -> 5: watch" "watch" "$(lvl S1)"
{ s1 1000 2 2 5; n1 4 4 9; n2 7; } > "$RD"
run_at 16
check_out "event smart-reset" $'\tsmart-reset\tS1\t.*reallocated went down 5 -> 2' $S events
check_eq "the level stays" "watch" "$(lvl S1)"

echo "-- B7: hours down or another WWN: the baseline is taken again"
{ s1 10 2 2 5; n1 4 4 9; n2 7; } > "$RD"
run_at 17
check_eq "healthy again" "healthy" "$(lvl S1)"
check_out "with the reason" "^baseline taken again: power-on hours went down" note_of S1
SW=W2; { s1 11 2 2 5; n1 4 4 9; n2 7; } > "$RD"
run_at 18
check_out "another WWN: the same" "^baseline taken again: a different disk" note_of S1

echo "-- B8: a sleeping disk is woken once in 6 days"
rd sdc asleep HDD S3 - - - - - - - - - - - - > "$WORK/asleep.txt"
rd sdc read HDD S3 W3 2000 0 0 0 0 - - - - - Seagate > "$RD_WAKE"
{ s1 12 2 2 5; n1 4 4 9; n2 7; cat "$WORK/asleep.txt"; } > "$RD"
run_at 19
check_eq "never read: woken" "wake sdc" "$(cat "$DHCALLS")"
check_eq "and stored" "healthy" "$(lvl S3)"
: > "$DHCALLS"
run_at 20
check_eq "a recent reading: no wake" "" "$(cat "$DHCALLS")"
rd sdc read HDD S3 W3 2100 1 0 0 0 - - - - - Seagate > "$RD_WAKE"
run_at 25
check_eq "6 days old: woken again" "wake sdc" "$(cat "$DHCALLS")"
check_eq "the values are stored (realloc 1)" "1" "$($S baseline | awk -F'\t' '$1 == "S3" { print $9 }')"

echo "-- B9/B11: a missing disk raises no smart problem; the old worse is replaced by the baseline"
{ s1 12 2 3 5; n1 4 4 9; n2 7; cat "$WORK/asleep.txt"; } > "$RD"
run_at 26
check_out "S1 failing" $'^disk:S1:smart-failing\t' prob_at 26
mon() { printf '%s\t%s\tHDD\t%s\t%s\tOK\t100\t%s\t%s\t%s\tx\t-\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7"; }   # name bytes role temp realloc pending crc
printf 'sda S1 WDC\nsdb N1 Samsung\n' > "$LS"
{ mon sda 4000000000000 "bulk 01" 30 0 0 0; mon sdb 500000000000 fast 30 0 0 0; } > "$MON"
HS_NOW=$((T0 + 26 * DAY + 100)) $S collect
{ mon sda 4000000000000 "bulk 01" 30 0 0 0; mon sdb 500000000000 fast 30 8 0 0; } > "$MON"
HS_NOW=$((T0 + 26 * DAY + 200)) $S collect
check_out "the inventory marks N1 worse" $'\tworse\tN1\t' $S events
check_eq "but no disk:N1:worse problem (the baseline rates it)" "0" "$(HS_NOW=$((T0 + 26 * DAY + 300)) $S problems | grep -c 'disk:N1:worse')"
printf 'sdb N1 Samsung\n' > "$LS"
mon sdb 500000000000 fast 30 8 0 0 > "$MON"
HS_NOW=$((T0 + 26 * DAY + 400)) $S collect
check_out "S1 is missing" $'^disk:S1:missing\t' env HS_NOW=$((T0 + 26 * DAY + 500)) $S problems
check_eq "and has no smart problem" "0" "$(HS_NOW=$((T0 + 26 * DAY + 500)) $S problems | grep -c 'disk:S1:smart-')"

echo "-- B10: forget"
check_out "forget S1" "Forgot S1" $S forget S1 --yes
check_eq "S1 is gone from the baseline" "0" "$($S baseline | grep -c '^S1')"

echo "-- B12: the daily check stopped"
check_out "three days later: smart:stale" $'^smart:stale\t' prob_at 29

echo "-- B14: without root the command refuses early"
if [ "$(id -u)" != 0 ]; then
  check_out "a clear message, no traceback" "needs root" env HS_DISK_HEALTH_NOROOT= bash "$SCRIPTS/state.sh" baseline-run
fi

echo "-- B13: the machine line"
check_eq "18 fields, none empty" "" "$($S baseline | awk -F'\t' 'NF != 18 { print NR": "NF } { for (i = 1; i <= NF; i++) if ($i == "") print NR": empty "i }')"
check_eq "state-db.py never asks a disk itself" "0" "$(grep -c 'smartctl -' "$SCRIPTS/state-db.py" | tr -d ' ')"

echo "-- B15: a sleeping disk that gives no reading is woken once a week, not every night"
rd sde asleep SSD S4 - - - - - - - - - - - - > "$RD"
: > "$RD_WAKE"; : > "$DHCALLS"
run_at 40
run_at 41
run_at 45
check_eq "woken on day 40 only" "wake sde" "$(cat "$DHCALLS")"
run_at 46
check_eq "and again after 6 days" $'wake sde\nwake sde' "$(cat "$DHCALLS")"

echo "-- B16: a finding after the hold, and a lower one during the hold, are not lost"
x() { rd "$1" read HDD "$2" "W$2" 100 0 "$3" 0 "$4" - - - - - WDC; }               # dev serial pending crc
{ x sdf X1 0 0; x sdg X2 0 0; } > "$RD"
run_at 50
{ x sdf X1 2 0; x sdg X2 2 0; } > "$RD"
run_at 51
check_eq "both failing" "failing failing" "$(lvl X1) $(lvl X2)"
{ x sdf X1 2 0; x sdg X2 2 3; } > "$RD"
run_at 52
check_eq "a lower finding in the hold: still failing" "failing" "$(lvl X2)"
check_out "and the CRC finding stays in the note" "pending 0 -> 2.*CRC 0 -> 3" note_of X2
{ x sdf X1 2 3; x sdg X2 2 3; } > "$RD"
run_at 60
check_eq "after the hold a new finding is the level" "watch" "$(lvl X1)"
check_out "and it raises an event" $'\tsmart-watch\tX1\t' $S events 100
check_eq "no finding after the hold: healthy" "healthy" "$(lvl X2)"

finish
