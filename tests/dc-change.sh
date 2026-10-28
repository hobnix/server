#!/usr/bin/env bash
# hs sys dc plan|start and hs sys dc state (scripts/dc-change.sh, dc-cert.sh state): make the CA, renew the certificate of the controller on this
# server (red, a job), and read the state. Real openssl, a fake incus that runs the controller's commands in a folder, a fake systemd-run.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
command -v openssl >/dev/null 2>&1 || { echo "  skip  openssl is not installed"; finish; exit 0; }
export HS_LANG=en HS_PLAIN=1
export HS_CALLER=test   # dc-cert.sh needs root; the tests run as nobody
unset HS_GUIDED_TTY
T=$'\t'
export HS_STATE_DIR=$WORK/state HS_DC_REALM=ad.home.lan HS_DC=dc2 HS_DC_TLS=$WORK/dc2/tls HS_INCUS=$WORK/incus HS_RUN_DIR=$WORK/run
export HS_MACHINE_FILE=$WORK/machine.toml
mkdir -p "$HS_STATE_DIR" "$WORK/dc2" "$WORK/run" "$WORK/bin"
: > "$HS_MACHINE_FILE"
cat > "$HS_INCUS" <<'EOF2'
#!/usr/bin/env bash
case "$1" in info) [ "${2:-}" = dc2 ] && exit 0 || exit 1 ;; list) exit 0 ;; esac
[ "$1" = exec ] || exit 1
shift 2
[ "$1" = -- ] && shift
case "$1" in
  systemctl) exit 0 ;;
  openssl) if [ "$2" = s_client ]; then echo "    Verify return code: 0 (ok)"; exit 0; fi ;;
  sh) if grep -q 's_client' <<<"$*"; then echo "    Verify return code: 0 (ok)"; exit 0; fi ;;
esac
exec "$@"
EOF2
chmod +x "$HS_INCUS"
# systemd-run: the command line goes into a file, nothing starts
cat > "$WORK/bin/systemd-run" <<FAKE
#!/usr/bin/env bash
for a in "\$@"; do printf '%s\n' "\$a"; done >> "$WORK/jobcalls"
printf -- '-----\n' >> "$WORK/jobcalls"
FAKE
chmod +x "$WORK/bin/systemd-run"; export PATH="$WORK/bin:$PATH"
run() { rc=0; out=$(timeout 60 bash "$SCRIPTS/dc-change.sh" "$@" </dev/null 2>/dev/null) || rc=$?; }
has() { grep -q -- "$1" <<<"$out"; }

echo "-- state without a CA"
out=$(bash "$SCRIPTS/dc-cert.sh" state 2>/dev/null)
has "^ca${T}no" && pass "no CA" || fail "$out"
has "^dc${T}dc2" && has "^cert${T}ok" || has "^cert${T}unreadable" && pass "the controller is named, its certificate is read or reported unreadable" || fail "$out"

echo "-- make the CA"
run plan renew;  check_eq "renew without a CA is refused" 1 "$rc"; has "There is no CA" && pass "says why" || fail "$out"
run plan ca;     check_eq "plan ca: exit 0" 0 "$rc"
has "^confirm_name" && fail "making the CA is not red" || pass "no typed word"
run start ca;    check_eq "start ca: exit 0" 0 "$rc"; has "^status${T}done" && pass "done" || fail "$out"
check "the CA certificate exists" test -s "$HS_STATE_DIR/dc-ca.pem"
run plan ca;     check_eq "a second CA is refused" 1 "$rc"; has "exists already" && pass "says it exists" || fail "$out"

echo "-- renew"
run plan renew;  check_eq "plan renew: exit 0" 0 "$rc"
has "^confirm_name${T}dc2" && pass "the controller is typed" || fail "$out"
has "^danger" && pass "red" || fail "$out"
run start renew; check_eq "no confirmation: refused" 1 "$rc"
run start renew --confirm dc1; check_eq "wrong name: refused" 1 "$rc"
run plan renew --dc dc9; check_eq "a controller that is not here is refused" 1 "$rc"; has "terminal" && pass "points at the terminal" || fail "$out"
: > "$WORK/jobcalls"; run start renew --confirm dc2; check_eq "start renew: exit 0" 0 "$rc"
has "^status${T}started" && pass "a job was started" || fail "$out"
grep -qx "renew-job" "$WORK/jobcalls" && pass "the job is the renewal" || fail "$(cat "$WORK/jobcalls")"

echo "-- the renewal itself (request, sign, install in one go)"
rc=0; rout=$(timeout 120 bash "$SCRIPTS/dc-change.sh" start renew-job --dc dc2 2>&1 </dev/null) || rc=$?
check_eq "the renewal runs through" 0 "$rc"
check "key.pem is in place" test -s "$WORK/dc2/tls/key.pem"
check "no temporary folder is left" test -z "$(ls -A "$WORK/run")"
out=$(bash "$SCRIPTS/dc-cert.sh" state 2>/dev/null)
has "^cert${T}ok" && pass "the certificate is readable" || fail "$out"
has "^checked${T}yes" && pass "it is checked by the CA" || fail "$out"
has "^names${T}.*ad.home.lan" && pass "it names the domain" || fail "$out"
has "^days_left${T}[0-9]" && pass "days left is a number" || fail "$out"
has "^ca_until${T}" && pass "the CA has an end date" || fail "$out"

echo "-- bad calls"
run plan bogus;          check_eq "unknown action: refused" 1 "$rc"
run plan ca --dc dc2;    check_eq "--dc is only for renew" 1 "$rc"
run plan renew --dc 'a b'; check_eq "a bad instance name is refused" 1 "$rc"
finish
