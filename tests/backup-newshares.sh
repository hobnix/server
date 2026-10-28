#!/usr/bin/env bash
# Backup: with backupNewShares off, new shares start out of the backup; the shares that are in it at the
# switch stay in; toggles keep the lists in step. Temp folders only (no root, no restic needed).
set -uo pipefail
S=${1:-$(dirname "$0")/../scripts}
T=$(mktemp -d)
export HS_STATE_DIR=$T/state HS_BULK=$T/bulk
mkdir -p "$HS_STATE_DIR" "$HS_BULK/shares/fotos" "$HS_BULK/shares/media" "$HS_BULK/shares/old" "$HS_BULK/sensitive/immich"
echo old > "$HS_STATE_DIR/backup-off"          # "old" was switched off before
sh() { bash "$S/backup.sh" --shares | awk -F'\t' '$1 == "share" { print $2 "=" $3 }' | sort | tr '\n' ' '; echo; }
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok:   $1"; else echo "FAIL: $1 (got: $3 | want: $2)"; fail=1; fi; }

export HS_BACKUP_NEW_SHARES=on
check "default on: everything but 'old'" "fotos=on immich=on media=on old=off " "$(sh)"
check "default on: no on-list is written" "no" "$([ -e "$HS_STATE_DIR/backup-on" ] && echo yes || echo no)"

export HS_BACKUP_NEW_SHARES=off
check "default off: today's shares are kept (migration)" "fotos=on immich=on media=on old=off " "$(sh)"
check "the on-list was written" "fotos immich media" "$(tr '\n' ' ' < "$HS_STATE_DIR/backup-on" | sed 's/ $//')"
mkdir "$HS_BULK/shares/newshare"
check "a share created later starts off" "fotos=on immich=on media=on newshare=off old=off " "$(sh)"
bash "$S/backup.sh" newshare on >/dev/null
check "switching it on" "fotos=on immich=on media=on newshare=on old=off " "$(sh)"
bash "$S/backup.sh" media off >/dev/null
check "switching media off" "fotos=on immich=on media=off newshare=on old=off " "$(sh)"
check "media is in the off-list too" "media" "$(grep -x media "$HS_STATE_DIR/backup-off")"

echo "-- a toggle before any migration must not drop the others"
rm -rf "$HS_STATE_DIR" "$HS_BULK/shares/newshare"; mkdir -p "$HS_STATE_DIR"
bash "$S/backup.sh" fotos off >/dev/null
check "only fotos changed" "fotos=off immich=on media=on old=on " "$(sh)"

echo "-- not writable (no root): the old rule applies, nothing breaks"
rm -rf "$HS_STATE_DIR" "$HS_BULK/shares/newshare"; mkdir -p "$HS_STATE_DIR"; echo media > "$HS_STATE_DIR/backup-off"; chmod 555 "$HS_STATE_DIR"
check "read-only state" "fotos=on immich=on media=off old=on " "$(sh)"
chmod 755 "$HS_STATE_DIR"
rm -rf "$T"
exit $fail
