#!/usr/bin/env bash
# Provider "reverse-proxy", variant zoraxy (docs/PLAN-modular-core.md step 4). The contract:
#   zoraxy.sh info             key<TAB>value lines: name, public (yes|no), domains (comma separated), mode (read-only|api), note
#   zoraxy.sh list             host<TAB>path<TAB>target<TAB>id for every route the proxy has (host * = the default site)
#   zoraxy.sh check            api mode: "ok" when the API and the rule files list the same routes, else "differ" and the two counts
#   zoraxy.sh ensure H P T     make the route (host, path, target); exit 0 when it is there (or was changed: only a route hs made or adopted),
#                              3 when this variant cannot (read-only), 4 when the route exists with ANOTHER target and is not ours,
#                              5 when the host's root is missing, 1 on an error
#   zoraxy.sh remove H P       take the route away (only a route hs made or adopted; exit 6 if not ours, 7 if the host still has paths)
#   zoraxy.sh owned-list       host<TAB>path of the routes hs made or adopted
#   zoraxy.sh adopt H P        from now on the route (made by hand) is ours to change and remove
#   zoraxy.sh login-check FILE the login in FILE (name, then password) works: exit 0 or 1
#
# Two modes. READ-ONLY: Zoraxy's rule files inside the container are read (the same files `hs ports` reads). API: with the admin login in the
# vault secret zoraxy-admin (`hs services proxy login`) the rules are read and written through Zoraxy's web API: a session cookie from
# POST /api/auth/login (Zoraxy has no API keys), then POST /api/proxy/list|add|vdir/add. The password goes to curl on stdin, never into
# an argument. The admin page is plain HTTP inside the home network (port 8000 or what `hs recipe zoraxy` was told).
# The Zoraxy here sits behind the Cloudflare tunnel, so every route is reachable from the internet (public=yes).
# Test knobs: HS_INCUS, HS_ZORAXY (the container), HS_ZORAXY_URL (the admin address), HS_ZORAXY_CRED (the login file), HS_PYTHON,
# HS_STATE_DIR, HS_SETTINGS_DIR.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/../../lib/setting.sh"
. "$here/../../lib/ui.sh"
. "$here/../../lib/secret.sh"
inc=${HS_INCUS:-incus}
ct=${HS_ZORAXY:-zoraxy}
state=${HS_STATE_DIR:-/var/lib/hs}
cred=${HS_ZORAXY_CRED:-$state/zoraxy-admin}
py=${HS_PYTHON:-python3}; command -v "$py" >/dev/null 2>&1 || py=python
tab=$'\t'
jar=""
cleanup() { [ -z "$jar" ] || rm -f "$jar"; }
trap cleanup EXIT

# api when the login is there and readable; a closed vault leaves the link dangling: read-only, and it says why
mode=read-only; why=""
case "$(secret_state "$cred")" in
  ok) [ -s "$cred" ] && mode=api || why="the login file is empty" ;;
  locked) why="the vault is closed (hs unlock)" ;;
  *) why="no login yet (hs services proxy login)" ;;
esac

admin_url() {
  [ -z "${HS_ZORAXY_URL:-}" ] || { echo "$HS_ZORAXY_URL"; return; }
  local port addr
  port=$(sed -n 's/^PORT=//p' "$state/recipe-$ct.conf" 2>/dev/null | tail -n1 || true); port=${port:-8000}
  addr=$("$inc" list --format json 2>/dev/null | PYTHONUTF8=1 "$py" "$here/../../services.py" addrs | awk -F"$tab" -v c="$ct" '$1 == c { print $2 }')
  [ -n "$addr" ] || return 1
  echo "http://$addr:$port"
}

# login with the credentials in file $1 (name, then password); sets $jar and $url. The password travels on stdin.
login() {
  local file=$1 reply page
  url=$(admin_url) || { echo "the Zoraxy container has no address" >&2; return 1; }
  jar=$(umask 077; mktemp /tmp/hs-zoraxy-jar.XXXXXX)
  # Every POST to the admin page needs a CSRF token (Zoraxy uses gorilla/csrf): the login page sets the cookie zoraxy_csrf and carries
  # the token in <meta name="zoraxy.csrf.Token" content="...">; it goes back in the header X-CSRF-Token, together with the cookie.
  page=$(curl -s -m 15 -L -c "$jar" -b "$jar" "$url/login.html" 2>/dev/null) || { echo "Zoraxy does not answer at $url" >&2; return 1; }
  csrf=$(sed -n 's/.*name="zoraxy\.csrf\.Token" *content="\([^"]*\)".*/\1/p' <<<"$page" | head -n1)
  [ -n "$csrf" ] || { echo "Zoraxy sent no CSRF token with its login page ($url/login.html)" >&2; return 1; }
  reply=$(PYTHONUTF8=1 "$py" -c '
import sys, urllib.parse
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
sys.stdout.write(urllib.parse.urlencode({"username": lines[0], "password": lines[1] if len(lines) > 1 else "", "rmbme": "false"}))' "$file" \
    | curl -s -m 15 -c "$jar" -b "$jar" -H "X-CSRF-Token: $csrf" --data @- "$url/api/auth/login" 2>/dev/null) || { echo "Zoraxy does not answer at $url" >&2; return 1; }
  is_ok "$reply" || { echo "Zoraxy refused the login: $(tr -d '\r\n' <<<"$reply" | cut -c1-120)" >&2; return 1; }
}
api() {   # api <path> [curl form arguments...]: a POST with the session cookie; the answer on stdout
  local p=$1; shift
  curl -s -m 20 -b "$jar" -H "X-CSRF-Token: $csrf" "$@" "$url$p"
}
# Zoraxy's success answer is the JSON string "OK" (utils.SendOK); the case is ignored
is_ok() { [ "$(tr -d ' \r\n' <<<"$1" | tr 'A-Z' 'a-z')" = '"ok"' ]; }
ok_reply() { is_ok "$1"; }

routes_from_files() {
  local rules
  rules=$("$inc" exec "$ct" -- sh -c 'find / -xdev -path "*/conf/proxy/*.config" -type f 2>/dev/null | while read -r f; do echo "## $f"; cat "$f"; echo; done' 2>/dev/null) || return 1
  PYTHONUTF8=1 "$py" "$here/zoraxy-list.py" <<<"$rules"
}
list_api() {   # the routes through the API; needs login to have run in THIS shell (not in a $(...) of its own)
  local body
  body=$(api /api/proxy/list --data type=host) || return 1
  case "$body" in "["*) ;; *) echo "unexpected answer of /api/proxy/list: $(cut -c1-100 <<<"$body")" >&2; return 1 ;; esac
  PYTHONUTF8=1 "$py" "$here/zoraxy-list.py" --json <<<"$body"
}
routes_from_api() { ( trap '[ -z "$jar" ] || rm -f "$jar"' EXIT; login "$cred" && list_api ); }   # its own session, its own cookie file
routes() { if [ "$mode" = api ]; then routes_from_api; else routes_from_files; fi; }

# the routes hs made (zoraxy.created) or adopted (zoraxy.adopted): the only ones it may change or remove
sdir="$state/services.state"
owned_rows() { { cat "$sdir/zoraxy.created" 2>/dev/null || true; cat "$sdir/zoraxy.adopted" 2>/dev/null || true; } | awk -F"$tab" '$1 != "" { print $1 "\t" ($2 == "" ? "/" : $2) }' | sort -u; }
is_owned() { owned_rows | grep -qxF "$1$tab$2"; }
drop_owned() {   # drop_owned <host> <path>
  local f
  for f in zoraxy.created zoraxy.adopted; do
    [ -f "$sdir/$f" ] || continue
    awk -F"$tab" -v h="$1" -v p="$2" '!($1 == h && $2 == p)' "$sdir/$f" > "$sdir/$f.new" && mv "$sdir/$f.new" "$sdir/$f"
  done
}
norm() { sed -E 's#^https?://##; s#/.*##; /:[0-9]+$/!s#$#:80#' <<<"$1"; }

case "${1:-}" in
  info)
    printf 'name\tzoraxy\npublic\tyes\n'
    printf 'domains\t%s\n' "$(setting_get proxyDomains 2>/dev/null | tr -d ' ' || true)"
    printf 'mode\t%s\n' "$mode"
    [ -z "$why" ] || printf 'note\t%s\n' "$why" ;;
  list) routes ;;
  check)
    [ "$mode" = api ] || { echo "not in api mode"; exit 0; }
    a=$(routes_from_api | sort) || exit 1
    f=$(routes_from_files | sort) || exit 1
    # the file list has the ids of the files, the API list the host names: compare host, path and target only
    # the default site (host *, Zoraxy's "root" rule) is not in the list of /api/proxy/list (type=host) and is not ours to manage: leave it out
    a=$(cut -f1-3 <<<"$a" | grep -v "^\*$tab" || true); f=$(cut -f1-3 <<<"$f" | grep -v "^\*$tab" || true)
    if [ "$a" = "$f" ]; then echo ok; else printf 'differ\t%s\t%s\n' "$(grep -c . <<<"$a")" "$(grep -c . <<<"$f")"; fi ;;
  login-check)
    [ -r "${2:-}" ] || { echo "usage: zoraxy.sh login-check FILE" >&2; exit 1; }
    login "$2" ;;
  owned-list)
    owned_rows ;;
  adopt)
    host=${2:-}; path=${3:-/}
    [ -n "$host" ] || { echo "usage: zoraxy.sh adopt <host> <path>" >&2; exit 1; }
    is_owned "$host" "$path" && { echo "already ours"; exit 0; }
    mkdir -p "$sdir" && printf '%s\t%s\t%s\n' "$host" "$path" "$(date +%F)" >> "$sdir/zoraxy.adopted" && echo "adopted" ;;
  ensure)
    host=${2:-}; path=${3:-/}; target=${4:-}
    [ -n "$host" ] && [ -n "$target" ] || { echo "usage: zoraxy.sh ensure <host> <path> <target>" >&2; exit 1; }
    [ "$mode" = api ] || { echo "refused: Zoraxy is read-only here ($why)" >&2; exit 3; }
    login "$cred" || exit 1
    have=$(list_api) || exit 1
    cur=$(awk -F"$tab" -v h="$host" -v p="$path" '$1 == h && $2 == p { print $3; exit }' <<<"$have")
    if [ -n "$cur" ]; then
      [ "$(norm "$cur")" = "$(norm "$target")" ] && { echo "already there"; exit 0; }
      # another target: only for a route hs made or adopted
      is_owned "$host" "$path" || { echo "the route exists with the target $cur and was not made by hs: adopt it first (hs services adopt)" >&2; exit 4; }
      if [ "$path" = / ]; then
        # the new origin first, then the old one goes: the host is never without a target
        reply=$(api /api/proxy/upstream/add --data-urlencode "ep=$host" --data-urlencode "origin=$target" --data-urlencode respt=0 \
          --data-urlencode maxconn=0 --data-urlencode tls=false --data-urlencode tlsval=false --data-urlencode bpwsorg=false \
          --data-urlencode active=true) || exit 1
        ok_reply "$reply" || { echo "Zoraxy: $(tr -d '\r\n' <<<"$reply" | cut -c1-160)" >&2; exit 1; }
        reply=$(api /api/proxy/upstream/remove --data-urlencode "ep=$host" --data-urlencode "origin=$cur") || exit 1
        if ! ok_reply "$reply"; then
          api /api/proxy/upstream/remove --data-urlencode "ep=$host" --data-urlencode "origin=$target" >/dev/null 2>&1   # back to how it was
          echo "Zoraxy could not drop the old target: $(tr -d '\r\n' <<<"$reply" | cut -c1-160)" >&2; exit 1
        fi
      else
        reply=$(api /api/proxy/vdir/edit --data-urlencode type=host --data-urlencode "vdir=$path" --data-urlencode "path=$host" \
          --data-urlencode "domain=$target$path" --data-urlencode reqTLS=false --data-urlencode skipValid=false) || exit 1
        ok_reply "$reply" || { echo "Zoraxy: $(tr -d '\r\n' <<<"$reply" | cut -c1-160)" >&2; exit 1; }
      fi
      echo "changed ($cur -> $target)"; exit 0
    fi
    if [ "$path" = / ]; then
      reply=$(api /api/proxy/add --data-urlencode type=host --data-urlencode "rootname=$host" --data-urlencode "ep=$target" \
        --data-urlencode tls=false --data-urlencode bypassGlobalTLS=false) || exit 1
    else
      grep -q "^$host$tab/$tab" <<<"$have" || { echo "the root of $host is missing: add it first" >&2; exit 5; }
      reply=$(api /api/proxy/vdir/add --data-urlencode type=host --data-urlencode "endpoint=$host" --data-urlencode "path=$path" \
        --data-urlencode "domain=$target$path" --data-urlencode reqTLS=false --data-urlencode skipValid=false) || exit 1
    fi
    ok_reply "$reply" || { echo "Zoraxy: $(tr -d '\r\n' <<<"$reply" | cut -c1-160)" >&2; exit 1; }
    # what this script made: the only routes it may change or remove later (together with the ones adopted)
    mkdir -p "$sdir" 2>/dev/null && printf '%s\t%s\t%s\t%s\n' "$host" "$path" "$target" "$(date +%F)" >> "$sdir/zoraxy.created" 2>/dev/null
    echo "added" ;;
  remove)
    host=${2:-}; path=${3:-/}
    [ -n "$host" ] || { echo "usage: zoraxy.sh remove <host> <path>" >&2; exit 1; }
    [ "$mode" = api ] || { echo "refused: Zoraxy is read-only here ($why)" >&2; exit 3; }
    login "$cred" || exit 1
    have=$(list_api) || exit 1
    if ! awk -F"$tab" -v h="$host" -v p="$path" '$1 == h && $2 == p { f = 1 } END { exit !f }' <<<"$have"; then
      drop_owned "$host" "$path"; echo "already gone"; exit 0   # nothing to remove, whoever made it
    fi
    is_owned "$host" "$path" || { echo "refused: the route was not made by hs (adopt it first if it should be managed)" >&2; exit 6; }
    if [ "$path" = / ]; then
      # a host rule takes its paths with it: not while another route of the host is still there
      if awk -F"$tab" -v h="$host" '$1 == h && $2 != "/" { f = 1 } END { exit !f }' <<<"$have"; then
        echo "refused: $host still has paths; remove them first" >&2; exit 7
      fi
      reply=$(api /api/proxy/del --data-urlencode "ep=$host") || exit 1
    else
      reply=$(api /api/proxy/vdir/del --data-urlencode type=host --data-urlencode "vdir=$path" --data-urlencode "path=$host") || exit 1
    fi
    ok_reply "$reply" || { echo "Zoraxy: $(tr -d '\r\n' <<<"$reply" | cut -c1-160)" >&2; exit 1; }
    drop_owned "$host" "$path"
    echo "removed" ;;
  *) echo "usage: zoraxy.sh info|list|check|owned-list|adopt <host> <path>|ensure <host> <path> <target>|remove <host> <path>|login-check <file>" >&2; exit 1 ;;
esac
