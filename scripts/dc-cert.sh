#!/usr/bin/env bash
# help: certificates of the domain controllers (LDAPS) that are valid for the domain name, so ad.home.lan works on every controller
# help.de: Zertifikate der Domänencontroller (LDAPS), die für den Domänennamen gelten, damit ad.home.lan auf jedem Controller funktioniert
# args: ca | request [--dc <instance>] | sign [<request file>|-] | install [--cert <bundle file>|-] [--dc <instance>] [--yes] | show [--dc <instance>] | state [--dc <instance>]
# Samba makes a self-signed certificate per controller, valid only for that controller's own name. Apps that connect to the
# domain name (ad.home.lan, which names every controller) therefore reject it. This gives every controller a certificate
# from ONE small CA of this setup, valid for the domain name and the controller's own name.
#   ca        (once, on the server that keeps the CA) makes the CA: key in the vault ($state/dc-ca-key), certificate $state/dc-ca.pem.
#             The CA may only vouch for names inside the domain (name constraint).
#   request   (on the server of each controller) makes a new key INSIDE the controller and prints a certificate request.
#             The key never leaves the controller.
#   sign      (on the CA server) signs a request, prints the certificate followed by the CA certificate (one bundle).
#   install   (on the server of each controller) checks the bundle against the waiting key, puts certificate, key and CA
#             in Samba's tls folder (the old files stay in tls.before-<date>), restarts the controller's Samba and tests LDAPS.
#   show      subject, names and end date of the certificate a controller uses now, and whether it is checked by the CA.
#   state     the same as key<TAB>value lines for the web interface (hs sys dc state): ca yes|no, ca_until, dc, cert ok|unreadable|none, subject,
#             names, valid_until, days_left, checked yes|no. Never fails for a missing CA or controller; changes nothing.
# request and sign print their result (PEM) on standard output and everything else on standard error, so
#   hs dc cert sign req.csr > bundle.pem   works.
# Test knobs: HS_STATE_DIR, HS_INCUS, HS_DC, HS_MACHINE_FILE, HS_DC_REALM (the domain name instead of adDomain), HS_DC_TLS.
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
. "$here/lib/machine.sh"
. "$here/lib/secret.sh"
. "$here/lib/dc.sh"
state=${HS_STATE_DIR:-/var/lib/hs}
inc=${HS_INCUS:-incus}
ca_key=$state/dc-ca-key
ca_cert=$state/dc-ca.pem
ca_serial=$state/dc-ca.srl
tls=${HS_DC_TLS:-/var/lib/samba/private/tls}   # inside the controller
days=825

usage() {
  say "usage: hs dc cert ca                      (once, on the server that keeps the CA)"
  say "       hs dc cert request [--dc <instance>]   (on each controller's server: prints a request)"
  say "       hs dc cert sign [<file>|-]             (on the CA server: signs a request, prints the bundle)"
  say "       hs dc cert install [--cert <file>|-] [--dc <instance>] [--yes]"
  say "       hs dc cert show [--dc <instance>]"
  exit 1
}
need_root() { [ "$(id -u)" -eq 0 ] || [ "${HS_CALLER:-}" = test ] || fail "Run this with sudo (hs does that for you)."; }
interactive() { [ -t 0 ] && [ -t 1 ] && [ -z "${HS_CALLER:-}" ]; }

realm=""
get_realm() {
  realm=${HS_DC_REALM:-$(machine_get adDomain.realm 2>/dev/null || true)}
  realm=$(tr 'A-Z' 'a-z' <<<"$realm")
  [ -n "$realm" ] || fail_fix "This server has no domain (adDomain in machine.toml)." "hs recipe domain"
}
dc=""
get_dc() {
  [ -n "$dc" ] || dc=$(dc_name)
  "$inc" info "$dc" >/dev/null 2>&1 || fail "$(t "The domain controller '%s' does not exist here." "$dc")"
}
on_dc() { "$inc" exec "$dc" -- "$@" </dev/null; }

# the names a request asks for must all lie inside the domain
request_names() {   # request_names <csr file>: one DNS name per line
  openssl req -in "$1" -noout -text 2>/dev/null | grep -o 'DNS:[^, ]*' | sed 's/^DNS://' | sort -u
}
check_names() {   # check_names <csr file>
  local n any=false
  while read -r n; do
    [ -n "$n" ] || continue
    any=true
    [[ "$n" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || fail "$(t "'%s' is not a usable name." "$n")"
    [ "$n" = "$realm" ] || [[ "$n" == *".$realm" ]] || fail "$(t "'%s' is outside the domain %s: refused." "$n" "$realm")"
  done < <(request_names "$1")
  $any || fail "The request names no DNS name."
}

verb=${1:-}; [ $# -gt 0 ] && shift
needs_openssl() { command -v openssl >/dev/null 2>&1 || fail_fix "openssl is not installed on this server." "hs update"; }
yes=false; cert_in=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dc) dc=${2:-}; [ $# -gt 1 ] && shift ;;
    --cert) cert_in=${2:-}; [ $# -gt 1 ] && shift ;;
    --yes) yes=true ;;
    -) cert_in=- ;;
    -*) usage ;;
    *) [ -z "$cert_in" ] || usage; cert_in=$1 ;;
  esac
  shift
done

case "$verb" in
  ca)
    need_root; needs_openssl; get_realm
    if [ -s "$ca_cert" ]; then
      ok "$(t 'The CA exists already: %s' "$ca_cert")"
      kv "Valid until" "$(openssl x509 -in "$ca_cert" -noout -enddate | sed 's/^notAfter=//')"
      exit 0
    fi
    step "$(t 'Make the CA of the domain %s' "$realm")"
    secret_prepare dc-ca-key || exit 1
    ( umask 077
      openssl req -x509 -newkey rsa:4096 -nodes -keyout "$ca_key" -out "$ca_cert" -days 3650 -sha256 \
        -subj "/O=homeserver/CN=$realm CA (hs)" \
        -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
        -addext "nameConstraints=critical,permitted;DNS:$realm" 2>"$state/dc-ca.err" >/dev/null ) ||
      { tail -n 3 "$state/dc-ca.err" 2>/dev/null | sed 's/^/    /' >&2; rm -f "$state/dc-ca.err"; fail "openssl could not make the CA."; }
    rm -f "$state/dc-ca.err"
    chmod 600 "$ca_key"; chmod 644 "$ca_cert"
    ok "$(t 'CA made. Key (in the vault): %s' "$ca_key")"
    note "$(t 'Certificate for the clients to trust: %s' "$ca_cert")"
    note "It only vouches for names inside the domain. Keep a copy of the key out of reach; whoever holds it can issue certificates for the domain."
    ;;

  request)
    exec 3>&1 1>&2
    need_root; get_realm; get_dc
    host=$dc.$realm
    step "$(t 'Certificate request for %s' "$host")"
    # a new key inside the controller; the live files stay as they are until install
    csr=$("$inc" exec "$dc" -- sh -c 'umask 077; mkdir -p "$3"; openssl req -new -newkey rsa:3072 -nodes -keyout "$3/key.new" -subj "/CN=$1" -addext "subjectAltName=DNS:$2,DNS:$1"' _ "$host" "$realm" "$tls" </dev/null 2>/dev/null) ||
      fail "openssl in the controller could not make the request."
    ok "$(t 'The key waits in the controller: %s/key.new (it never leaves it)' "$tls")"
    note "Take this request to the CA server (hs dc cert sign); the bundle it prints comes back here (hs dc cert install)."
    printf '%s\n' "$csr" >&3
    ;;

  sign)
    exec 3>&1 1>&2
    need_root; needs_openssl; get_realm
    [ -s "$ca_cert" ] || fail_fix "This server has no CA." "hs dc cert ca"
    case "$(secret_state "$ca_key")" in
      ok) ;; locked) secret_locked_exit ;;
      *) fail_fix "The CA key is missing." "hs dc cert ca" ;;
    esac
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    if [ -z "$cert_in" ] || [ "$cert_in" = - ]; then
      if [ -t 0 ]; then note "Paste the request, then press Ctrl-D:"; fi
      cat > "$tmp/req.csr"
    else
      [ -r "$cert_in" ] || fail "$(t 'Cannot read %s' "$cert_in")"
      cp "$cert_in" "$tmp/req.csr"
    fi
    openssl req -in "$tmp/req.csr" -noout -verify >/dev/null 2>&1 || fail "That is not a valid certificate request."
    check_names "$tmp/req.csr"
    names=$(request_names "$tmp/req.csr" | sed 's/^/DNS:/' | paste -sd, -)
    printf 'subjectAltName=%s\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth,clientAuth\n' "$names" > "$tmp/ext"
    openssl x509 -req -in "$tmp/req.csr" -CA "$ca_cert" -CAkey "$ca_key" -CAserial "$ca_serial" -CAcreateserial \
      -days "$days" -sha256 -extfile "$tmp/ext" -out "$tmp/cert.pem" >/dev/null 2>&1 || fail "openssl could not sign the request."
    ok "$(t 'Signed for: %s (valid %s days)' "${names//DNS:/}" "$days")"
    cat "$tmp/cert.pem" "$ca_cert" >&3
    ;;

  install)
    need_root; needs_openssl; get_realm; get_dc
    host=$dc.$realm
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    if [ -z "$cert_in" ] || [ "$cert_in" = - ]; then
      if [ -t 0 ]; then note "Paste the bundle (certificate, then CA certificate), then press Ctrl-D:"; fi
      cat > "$tmp/bundle.pem"
    else
      [ -r "$cert_in" ] || fail "$(t 'Cannot read %s' "$cert_in")"
      cp "$cert_in" "$tmp/bundle.pem"
    fi
    awk -v d="$tmp" '/BEGIN CERTIFICATE/ { n++ } n >= 1 && n <= 2 { print > (d "/part" n ".pem") }' "$tmp/bundle.pem"
    [ -s "$tmp/part1.pem" ] && [ -s "$tmp/part2.pem" ] || fail "The bundle needs two certificates: the controller's and the CA's."
    openssl x509 -in "$tmp/part1.pem" -noout >/dev/null 2>&1 && openssl x509 -in "$tmp/part2.pem" -noout >/dev/null 2>&1 || fail "That is not a certificate bundle."
    openssl verify -CAfile "$tmp/part2.pem" "$tmp/part1.pem" >/dev/null 2>&1 || fail "The certificate is not signed by the CA in the bundle."
    sans=$(openssl x509 -in "$tmp/part1.pem" -noout -ext subjectAltName 2>/dev/null || true)
    grep -q "DNS:$host" <<<"$sans" && grep -q "DNS:$realm" <<<"$sans" ||
      fail "$(t 'The certificate is not valid for both %s and %s.' "$host" "$realm")"
    on_dc test -f "$tls/key.new" || fail_fix "$(t 'No waiting key in %s: the request was made on another controller, or already installed.' "$dc")" "hs dc cert request"
    pub_cert=$(openssl x509 -in "$tmp/part1.pem" -noout -pubkey)
    pub_key=$("$inc" exec "$dc" -- openssl pkey -in "$tls/key.new" -pubout </dev/null 2>/dev/null) || fail "The waiting key cannot be read."
    [ "$pub_cert" = "$pub_key" ] || fail "The certificate does not belong to the key waiting in the controller (a newer request was made since)."
    step "$(t 'Install the certificate in %s' "$dc")"
    kv "Names" "$host, $realm"
    kv "Valid until" "$(openssl x509 -in "$tmp/part1.pem" -noout -enddate | sed 's/^notAfter=//')"
    if ! $yes; then
      interactive || fail "Nothing is changed without --yes when there is no terminal."
      confirm "$(t 'Replace the certificate of %s and restart its Samba (LDAPS is down for a few seconds)?' "$dc")" || fail "cancelled"
    fi
    stamp=$(date +%Y%m%d-%H%M%S)
    on_dc sh -c "cp -a '$tls' '$tls.before-$stamp'"
    "$inc" exec "$dc" -- sh -c "cat > '$tls/cert.pem'" < "$tmp/part1.pem"
    "$inc" exec "$dc" -- sh -c "cat > '$tls/ca.pem'" < "$tmp/part2.pem"
    on_dc sh -c "mv '$tls/key.new' '$tls/key.pem' && chmod 600 '$tls/key.pem' && chmod 644 '$tls/cert.pem' '$tls/ca.pem'"
    spin "$(t 'Restarting Samba in %s' "$dc")" "$inc" exec "$dc" -- systemctl restart samba-ad-dc
    if [ ! -s "$ca_cert" ]; then cp "$tmp/part2.pem" "$ca_cert"; chmod 644 "$ca_cert"; fi
    res=$("$inc" exec "$dc" -- sh -c "for _ in \$(seq 1 20); do openssl s_client -connect 127.0.0.1:636 -servername '$realm' -verify_hostname '$realm' -CAfile '$tls/ca.pem' </dev/null 2>&1 | grep -m1 'Verify return code' && exit 0; sleep 2; done; exit 1" </dev/null || true)
    if grep -q 'code: 0 ' <<<"$res"; then
      ok "$(t 'LDAPS answers with the new certificate and %s is accepted as its name' "$realm")"
    else
      warn "$(t 'LDAPS did not check out (%s). The old files are in %s.before-%s.' "${res:-no answer}" "$tls" "$stamp")"
    fi
    note "$(t 'Clients trust this CA file: %s' "$ca_cert")"
    ;;

  show)
    get_realm; get_dc
    out=$("$inc" exec "$dc" -- sh -c "openssl x509 -in '$tls/cert.pem' -noout -subject -enddate -ext subjectAltName; openssl verify -CAfile '$tls/ca.pem' '$tls/cert.pem'" </dev/null 2>&1) ||
      fail "The certificate of the controller cannot be read."
    step "$(t 'Certificate of %s' "$dc")"
    kv "Subject" "$(sed -n 's/^subject=//p' <<<"$out")"
    kv "Names" "$(grep -o 'DNS:[^, ]*' <<<"$out" | sed 's/^DNS://' | paste -sd' ' -)"
    kv "Valid until" "$(sed -n 's/^notAfter=//p' <<<"$out")"
    if grep -q ': OK$' <<<"$out"; then ok "$(t 'It is checked by the CA file next to it')"; else note "It is not signed by a CA of this setup (Samba's own certificate)."; fi
    ;;

  state)
    get_realm
    if [ -s "$ca_cert" ]; then
      printf 'ca	yes
ca_until	%s
' "$(openssl x509 -in "$ca_cert" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"
    else
      printf 'ca	no
'
    fi
    [ -n "$dc" ] || dc=$(dc_name)
    printf 'dc	%s
' "$dc"
    if ! "$inc" info "$dc" >/dev/null 2>&1; then printf 'cert	none
'; exit 0; fi
    if out=$("$inc" exec "$dc" -- sh -c "openssl x509 -in '$tls/cert.pem' -noout -subject -enddate -ext subjectAltName; openssl verify -CAfile '$tls/ca.pem' '$tls/cert.pem'" </dev/null 2>&1); then
      printf 'cert	ok
'
      printf 'subject	%s
' "$(sed -n 's/^subject=//p' <<<"$out")"
      printf 'names	%s
' "$(grep -o 'DNS:[^, ]*' <<<"$out" | sed 's/^DNS://' | paste -sd' ' -)"
      end=$(sed -n 's/^notAfter=//p' <<<"$out")
      printf 'valid_until	%s
' "$end"
      e=$(date -d "$end" +%s 2>/dev/null || true)
      [ -z "$e" ] || printf 'days_left	%s
' "$(( (e - $(date +%s)) / 86400 ))"
      if grep -q ': OK$' <<<"$out"; then printf 'checked	yes
'; else printf 'checked	no
'; fi
    else
      printf 'cert	unreadable
'
    fi
    ;;

  *) usage ;;
esac
