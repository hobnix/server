#!/usr/bin/env bash
# hs disk selftest, hs secrets, hs system gc --yes. Stand-ins for disk-health and nix-collect-garbage. No root needed.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_STATE_DIR=$WORK/state
BIN=$WORK/bin; mkdir -p "$BIN" "$HS_STATE_DIR"
S=$SCRIPTS

echo "-- disk selftest"
cat > "$BIN/dh.sh" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  --list) printf 'sda\t1T\tHDD\tA\tOK\t1\t\nsdb\t1T\tHDD\tB\tOK\t1\t\nsdc\t1T\tUSB\tC\tOK\t1\t\n' ;;
  --test) echo "dh $*" >> "$DHLOG"; [ "$3" = sdc ] && exit 1; exit 0 ;;
esac
FAKE
chmod +x "$BIN/dh.sh"; export HS_DISK_HEALTH=$BIN/dh.sh DHLOG=$WORK/dh.log; : > "$DHLOG"
T="bash $S/selftest.sh"
check_out "short starts in every disk" "sda: short self-test started" $T short
check_out "a disk that refuses is a warning, not a failure" "sdc: could not start" $T short
check_eq "the tests were asked for each disk" "dh --test short sda
dh --test short sdb
dh --test short sdc
dh --test short sda
dh --test short sdb
dh --test short sdc" "$(cat "$DHLOG")"
check "the start time is kept" grep -q '^short=[0-9]*$' "$HS_STATE_DIR/selftest.state"
$T long >/dev/null 2>&1
check_eq "short and long are both kept" "2" "$(wc -l < "$HS_STATE_DIR/selftest.state" | tr -d ' ')"
check_out "dry run starts nothing" "Would start a long self-test in sda" $T long --dry-run
check_out "a bad kind is refused" "usage" $T weekly
cat > "$BIN/dh-none.sh" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
chmod +x "$BIN/dh-none.sh"
check_out "no disks is an error" "No disk found" env HS_DISK_HEALTH=$BIN/dh-none.sh $T short

echo "-- secrets"
mkdir -p "$WORK/ssh" "$WORK/samba" "$HS_STATE_DIR"
export HS_SSH_DIR=$WORK/ssh HS_SAMBA_PRIVATE=$WORK/samba HS_SECRETS_ANY_OWNER=1
echo pw > "$HS_STATE_DIR/restic-password"; chmod 644 "$HS_STATE_DIR/restic-password"
echo k > "$HS_STATE_DIR/disk-key"; chmod 400 "$HS_STATE_DIR/disk-key"
echo key > "$WORK/ssh/ssh_host_ed25519_key"; chmod 600 "$WORK/ssh/ssh_host_ed25519_key"; chmod 700 "$WORK/samba"
Sx="bash $S/secrets.sh"
out=$($Sx 2>&1 || true)
check_out "a readable password file is WRONG" "restic-password.*644.*WRONG" echo "$out"
check_out "a root-only key is ok" "disk-key.*400.*ok" echo "$out"
check_out "the backup password is flagged as 'store elsewhere'" "restic-password.*YES" echo "$out"
check_out "missing ones say so" "unifi.*not set up" echo "$out"
check_eq "a wrong one gives a non-zero exit" "1" "$($Sx >/dev/null 2>&1; echo $?)"
if grep -q 'pw$' <<<"$out"; then fail "contents are never printed"; else pass "contents are never printed"; fi
$Sx fix >/dev/null 2>&1
check_eq "fix sets 600" "600" "$(stat -c %a "$HS_STATE_DIR/restic-password")"
check_eq "afterwards everything is fine" "0" "$($Sx >/dev/null 2>&1; echo $?)"
out=$($Sx 2>&1 || true)
$Sx fix >/dev/null 2>&1

echo "-- system gc"
cat > "$BIN/nix-collect-garbage" <<'FAKE'
#!/usr/bin/env bash
echo "nix-collect-garbage $*" >> "$(dirname "$0")/calls.log"
FAKE
chmod +x "$BIN/nix-collect-garbage"
check_out "--yes does not ask" "nix-collect-garbage --delete-older-than 14d" bash -c "rm -f $BIN/calls.log; PATH=$BIN:\$PATH bash $S/system.sh gc 14 --yes >/dev/null; cat $BIN/calls.log"
check_out "the default is 30 days" "older-than 30d" bash -c "rm -f $BIN/calls.log; PATH=$BIN:\$PATH bash $S/system.sh gc --yes >/dev/null; cat $BIN/calls.log"
check_out "it says how much was freed" "Freed about" env PATH="$BIN:$PATH" bash "$S/system.sh" gc --yes
check_out "without --yes and without a terminal it does not run" "cancelled" bash -c "echo n | PATH=$BIN:\$PATH bash $S/system.sh gc 14"

finish
