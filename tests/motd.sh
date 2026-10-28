#!/usr/bin/env bash
# hs motd: three status lines from the state files. No root needed.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1
export HS_STATE_DIR=$WORK/state HS_LOGIN_MESSAGE=$WORK/login-message HS_LOCKED_MARKER=$WORK/locked
mkdir -p "$HS_STATE_DIR"
M="bash $SCRIPTS/motd.sh"
now=$(date +%s)

check_out "before anything ran" "health check has not run yet" $M
check_out "and no backup" "No backup yet" $M
printf '%s\n' "$now" > "$HS_STATE_DIR/health.state"
check_out "no problems listed" "No problems found" $M
printf '%s\nzfs:bulk:DEGRADED\nunit:x\n' "$now" > "$HS_STATE_DIR/health.state"
check_out "two problems" "2 problem\(s\)\. Look at them: hs health" $M
printf 'last_ok=%s\nstatus=ok\n' "$((now - 7200))" > "$HS_STATE_DIR/backup.state"
check_out "a recent backup" "Last successful backup 2 h ago" $M
printf 'last_ok=%s\nstatus=failed\n' "$((now - 7200))" > "$HS_STATE_DIR/backup.state"
check_out "a failed try is a warning" "the last try did not work" $M
printf 'last_ok=%s\nstatus=ok\n' "$((now - 400000))" > "$HS_STATE_DIR/backup.state"
check_out "an old backup is a warning" "4 days ago: hs backup status" $M
check_out "the system line" "system disk [0-9?]+% full" $M
: > "$WORK/locked"
check_out "locked storage comes first" "storage is locked" $M
rm -f "$WORK/locked"
echo uuid > "$HS_STATE_DIR/vault-uuid"; export HS_VAULT_DIR=$WORK/novault
check_out "a closed vault is said (no marker)" "vault is closed: run hs unlock" $M
: > "$WORK/locked"
if $M | grep -q "vault is closed"; then fail "with the marker only the storage line"; else pass "with the marker only the storage line"; fi
rm -f "$WORK/locked"
check_out "an open vault says nothing" "Last successful backup" env HS_VAULT_OPEN=1 $M
if HS_VAULT_OPEN=1 $M | grep -q "vault is closed"; then fail "open: no vault line"; else pass "open: no vault line"; fi
rm -f "$HS_STATE_DIR/vault-uuid"
echo off > "$HS_LOGIN_MESSAGE"
check_eq "switched off: silent" "" "$($M)"
check_out "--force shows it anyway" "Last successful backup" $M --force
check_out "German" "Läuft seit" env HS_LANG=de $M --force
check_out "a wrong option is refused" "usage: hs motd" $M --nope

finish
