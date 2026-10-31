#!/usr/bin/env bash
# hs gateway acme-token: the Cloudflare DNS API token read from stdin, stored as a credential
# (mode 0600) that Traefik receives through systemd LoadCredential + CF_DNS_API_TOKEN_FILE.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en HS_CALLER=test
T=$'\t'
STATE=$WORK/state/acme
mkdir -p "$STATE"
G=$SCRIPTS/gateway.sh
run() { rc=0; out=$(HS_ACME_TOKEN_DIR="$STATE" HS_ACME_TOKEN_STDIN="$1" timeout 30 bash "$G" acme-token 2>&1) || rc=$?; }
has() { grep -q -- "$1" <<<"$out"; }

echo "-- token from the stdin file is stored as a mode-0600 credential"
printf 'dG9rZW4tMTIzNDU2' > "$STATE/stdin.txt"
run "$STATE/stdin.txt"
check_eq "exit 0" 0 "$rc"
has "^status${T}ok$" && pass "status ok" || fail "status: $out"
check_eq "token file written" "dG9rZW4tMTIzNDU2" "$(cat "$STATE/cf-dns-api-token")"
check_eq "token file mode 0600" "600" "$(stat -c '%a' "$STATE/cf-dns-api-token")"

echo "-- empty token refused"
rm -f "$STATE/cf-dns-api-token"
printf '' > "$STATE/empty.txt"
run "$STATE/empty.txt"
check_eq "exit 1" 1 "$rc"
has "^status${T}refused$" && pass "refused on empty" || fail "refused: $out"
check_eq "empty token writes nothing" "no" "$(test -e "$STATE/cf-dns-api-token" && echo yes || echo no)"

finish
