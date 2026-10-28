#!/usr/bin/env bash
# hs dc cert: CA, request, sign, install, show, with real openssl and a fake incus that runs the commands of the
# "controller" in a folder of its own. No root, no Samba.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
command -v openssl >/dev/null 2>&1 || { echo "  skip  openssl is not installed"; finish; exit 0; }
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test
export HS_STATE_DIR=$WORK/state HS_DC_REALM=ad.home.lan HS_DC=dc2 HS_DC_TLS=$WORK/dc2/tls HS_INCUS=$WORK/incus
export HS_MACHINE_FILE=$WORK/machine.toml
mkdir -p "$HS_STATE_DIR" "$WORK/dc2"
: > "$HS_MACHINE_FILE"

# a fake incus: info works; exec runs the command here (the folder of the controller is HS_DC_TLS); systemctl does nothing;
# openssl s_client answers like a good server
cat > "$HS_INCUS" <<'EOF2'
#!/usr/bin/env bash
case "$1" in info) exit 0 ;; list) exit 0 ;; esac
[ "$1" = exec ] || exit 1
shift 2   # exec <instance>
[ "$1" = -- ] && shift
case "$1" in
  systemctl) exit 0 ;;
  openssl) if [ "$2" = s_client ]; then echo "    Verify return code: 0 (ok)"; exit 0; fi ;;
  sh) if grep -q 's_client' <<<"$*"; then echo "    Verify return code: 0 (ok)"; exit 0; fi ;;
esac
exec "$@"
EOF2
chmod +x "$HS_INCUS"
D="bash $SCRIPTS/dc-cert.sh"

echo "-- the CA"
check "the CA is made" $D ca
check "key and certificate exist" bash -c "test -s '$HS_STATE_DIR/dc-ca-key' && test -s '$HS_STATE_DIR/dc-ca.pem'"
check_out "the CA says it may sign only inside the domain" "ad.home.lan" bash -c "openssl x509 -in '$HS_STATE_DIR/dc-ca.pem' -noout -text | grep -A3 'Name Constraints'"
check_out "again: it exists already" "exists already" $D ca

echo "-- request, sign, install"
$D request > "$WORK/dc2.csr" 2>"$WORK/request.err" && pass "request" || fail "request ($(tail -2 "$WORK/request.err"))"
check "the request is a PEM and nothing else" bash -c "head -1 '$WORK/dc2.csr' | grep -q 'BEGIN CERTIFICATE REQUEST' && ! grep -qv '^\(-----\|[A-Za-z0-9+/=]*$\)' '$WORK/dc2.csr'"
check "the key waits in the controller" test -s "$WORK/dc2/tls/key.new"
$D sign "$WORK/dc2.csr" > "$WORK/bundle.pem" 2>"$WORK/sign.err" && pass "sign" || fail "sign ($(tail -2 "$WORK/sign.err"))"
check_eq "the bundle holds two certificates" 2 "$(grep -c 'BEGIN CERTIFICATE' "$WORK/bundle.pem")"
check "the certificate is checked by the CA" openssl verify -CAfile "$HS_STATE_DIR/dc-ca.pem" -verify_hostname ad.home.lan <(sed -n '1,/END CERTIFICATE/p' "$WORK/bundle.pem")
check_out "valid for the controller's name and the domain" "DNS:dc2.ad.home.lan.*DNS:ad.home.lan|DNS:ad.home.lan.*DNS:dc2.ad.home.lan" bash -c "sed -n '1,/END CERTIFICATE/p' '$WORK/bundle.pem' | openssl x509 -noout -ext subjectAltName | tr '\n' ' '"
check_out "install" "LDAPS answers" $D install --cert "$WORK/bundle.pem" --yes
check "key.pem replaced key.new" bash -c "test -s '$WORK/dc2/tls/key.pem' && test ! -e '$WORK/dc2/tls/key.new'"
check "the old tls folder is kept" bash -c "ls -d '$WORK/dc2/tls.before-'* >/dev/null"
check_out "show: checked by the CA" "checked by the CA" $D show
check_out "show: both names" "dc2.ad.home.lan ad.home.lan|ad.home.lan dc2.ad.home.lan" $D show

echo "-- refused"
check_out "a second install has no key waiting" "No waiting key" $D install --cert "$WORK/bundle.pem" --yes
openssl req -new -newkey rsa:2048 -nodes -keyout "$WORK/evil.key" -subj "/CN=evil.example.com" -addext "subjectAltName=DNS:evil.example.com" -out "$WORK/evil.csr" 2>/dev/null
check_out "a name outside the domain is refused" "outside the domain" $D sign "$WORK/evil.csr"
printf 'garbage\n' > "$WORK/bad.csr"
check_out "garbage is no request" "not a valid certificate request" $D sign "$WORK/bad.csr"
$D request > "$WORK/dc2b.csr" 2>/dev/null
check_out "a certificate for another key is refused" "does not belong to the key" $D install --cert "$WORK/bundle.pem" --yes
finish
