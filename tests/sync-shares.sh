#!/usr/bin/env bash
# scripts/sync-shares.sh on the SSD pool: the share `apps` on fast keeps the owners of its files (--fix-owner hands over only the top folder).
# Fake net, testparm, zfs, stat, chown, chmod, find on PATH: no root, no Samba, no ZFS.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_FAST=$WORK/fast
BIN=$WORK/bin; mkdir -p "$BIN" "$HS_FAST/shares/apps" "$HS_FAST/shares/notes"
export CALLS=$WORK/calls; : > "$CALLS"
cat > "$BIN/net" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  "conf listshares") ;;
  "conf getparm "*) ;;
  *) echo "net $*" >> "$CALLS" ;;
esac
FAKE
cat > "$BIN/testparm" <<'FAKE'
#!/usr/bin/env bash
case "$*" in *security*) echo USER ;; esac
FAKE
cat > "$BIN/zfs" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  *"-d 1 fast/shares") printf 'fast/shares\nfast/shares/apps\nfast/shares/notes\n' ;;
  "list -H -o name fast") echo fast ;;
  *) exit 1 ;;
esac
FAKE
cat > "$BIN/stat" <<'FAKE'
#!/usr/bin/env bash
echo root
FAKE
for c in chown chmod find; do printf '#!/usr/bin/env bash\necho "%s $*" >> "$CALLS"\n' "$c" > "$BIN/$c"; done
chmod +x "$BIN"/*
export PATH=$BIN:$PATH
echo zfs > "$WORK/bulk-type"
S="bash $SCRIPTS/sync-shares.sh"

if [ "$(cat /etc/hs/bulk-type 2>/dev/null || echo zfs)" = snapraid ]; then
  skip "this machine uses the snapraid layout (sync-shares reads /etc/hs/bulk-type)"; finish; exit $?
fi

echo "-- --check lists the fast shares and changes nothing"
out=$($S --check 2>&1)
check_out "apps on fast is found" "^apps +belongs to root" echo "$out"
check_out "a normal fast share is found" "^notes +belongs to root" echo "$out"
check_out "a fast share is missing in Samba" "^notes +missing \($HS_FAST/shares/notes\)" echo "$out"
check_eq "no chown" "" "$(grep -c '^chown' "$CALLS" | sed 's/^0$//')"

echo "-- --fix-owner skips the files of apps"
: > "$CALLS"
out=$($S --fix-owner 2>&1 || true)
check_out "apps is left as it is" "^apps .*left as it is: the files of the Docker apps keep their owners" echo "$out"
check_eq "apps: only the top folder is handed over" "chown adminuser:users $HS_FAST/shares/apps" "$(grep "^chown.*/apps" "$CALLS" | head -n 1)"
check_eq "apps: no file walk" "0" "$(grep -c "^find.*/apps" "$CALLS" || true)"
check_eq "notes: its files are walked" "1" "$(grep -c "^find.*/notes" "$CALLS" || true)"

echo "-- without Samba (no net command) it says so and stops"
mv "$BIN/net" "$BIN/net.off"
out=$($S --check 2>&1); rc=$?
check_eq "exit code 1" "1" "$rc"
check_out "says Samba is not installed" "Samba is not installed" echo "$out"
mv "$BIN/net.off" "$BIN/net"
finish
