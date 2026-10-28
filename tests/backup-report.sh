#!/usr/bin/env bash
# hs backup report: the monthly drill report. Reads state files only; a fake program stands in for notify.sh. No root, no restic.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1
ST=$WORK/state; mkdir -p "$ST" "$WORK/bin"
export HS_STATE_DIR=$ST HS_BACKUP_NOTIFY=$WORK/bin/fake-notify
cat > "$HS_BACKUP_NOTIFY" <<'F'
#!/bin/sh
printf '%s|%s|%s|%s\n' "$2" "$4" "$1 $3" "$5" >> "$FAKE_SENT"
F
chmod +x "$HS_BACKUP_NOTIFY"
export FAKE_SENT=$WORK/sent
hsb() { bash "$SCRIPTS/backup.sh" "$@"; }
now=$(date +%s); day=86400
echo pw > "$ST/restic-password"

echo "-- everything fresh"
cat > "$ST/backup.state" <<S
status=ok
last_ok=$((now - 3600))
drill_ok=$((now - 10 * day))
used_pct=40
S
out=$(hsb report --dry-run 2>&1)
if grep -q "restore drills are fine" <<<"$out"; then pass "a fresh state is fine"; else fail "a fresh state is fine ($out)"; fi
check_out "the dry run sends nothing" "nothing sent" echo "$out"
check "no message went out" test ! -e "$FAKE_SENT"
hsb report >/dev/null 2>&1
check_out "a real run sends it with low priority" "restore drills are fine.*low" cat "$FAKE_SENT"

echo "-- overdue and failed"
rm -f "$FAKE_SENT"
cat > "$ST/backup.state" <<S
status=failed
last_ok=$((now - 5 * day))
drill_ok=$((now - 60 * day))
drill_ct_ok=$((now - 100 * day))
drill_ct_name=arr
used_pct=95
S
echo "arr $((now - 2 * day)) failed" > "$ST/backup-drill-ct"
echo arr > "$ST/backup-instances"
out=$(hsb report --dry-run 2>&1)
for want in "last backup failed" "Backup: 5 days ago" "File restore drill: 60 days ago" "Container restore drill: 100 days ago.*arr" "failed in the last 35 days: arr" "95% full"; do
  if grep -Eq -- "$want" <<<"$out"; then pass "report says: $want"; else fail "report says: $want ($out)"; fi
done
hsb report >/dev/null 2>&1
check_out "problems go out with high priority" "to look at.*high" cat "$FAKE_SENT"
check_out "and as a problem" "^problem[|]" cat "$FAKE_SENT"

echo "-- the schedule"
check_eq "a server without a backup does nothing on the timer" "" "$(HS_STATE_DIR=$WORK/none bash "$SCRIPTS/backup.sh" report --scheduled 2>&1)"
unit=$(grep -h -A12 'systemd.services.hs-backup-report' "$ROOT/configuration.nix" "$ROOT"/capabilities/*/module.nix)   # the timers moved to capabilities/backup/module.nix
check "the timer has a start time" grep -q 'startAt' <<<"$unit"
check "the timer has the failure hook" grep -q 'onFailure = notifyFailure' <<<"$unit"

finish
