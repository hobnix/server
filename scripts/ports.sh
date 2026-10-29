#!/usr/bin/env bash
# help: open ports of the server and of every running container, and a warning when an admin interface sits behind Zoraxy
# help.de: offene Ports des Servers und jedes laufenden Containers, mit Warnung, wenn eine Verwaltungsoberfläche hinter Zoraxy hängt
# args: [<container>] [--list]
# Read only. Looks at what listens (`ss` on the host and, through `incus exec`, in each running container),
# compares it with a built-in list of expected ports (/var/lib/hs/ports-expected adds to it: lines "name port",
# name = host or a container name, port = 443, 8000-8100 or *), and checks every Zoraxy proxy target against
# the list of admin interfaces (Incus 8443, WebZFS, Arcane, Zoraxy admin 8000, Grafana ...;
# /var/lib/hs/ports-admin adds lines "name port label [warn|info]", name may be a glob).
#
# What this can and cannot see (be honest about it):
#  - Zoraxy keeps its rules as JSON files (conf/proxy/*.config) inside its container. They are read with
#    `incus exec zoraxy -- find/cat`; the field names differ between Zoraxy versions (OriginIpOrDomain or
#    Domain for the target, RootOrMatchingDomain for the host name), both are understood. A rule without a
#    port means 80. Not seen: the "default site", path rules inside one rule, rules typed after the
#    last config write, and anything when the container is stopped or its files are somewhere else.
#  - When no rule file can be read, the fallback is the live connections of the Zoraxy container
#    (`ss state established`): it shows only targets that were used just now, so a rule nobody called
#    is missed. The source column says which of the two was used.
#  - A hostname as target is matched to a container of that name only; an address that belongs to no
#    instance is "unknown target" and never warns.
#  - Nothing here knows whether a service has its own login; the warning means "reachable from the
#    internet through the wildcard tunnel", which the rules of this server forbid for admin interfaces.
#  - ss without root shows no process names; hs runs this as root.
# --list: tab separated, one line per fact, no header:
#   listen  <where>  <proto>  <port>  <bind>  <process>  <status>  <note>
#   proxy   <where>  tcp      <port>  <host name>  <source>  <status>  <note>
# status of listen: expected | admin | unexpected ; loopback-only sockets are left out.
# status of proxy: ok | WARN | info | unknown ; exit code 1 when a WARN was found.
# Stand-ins for tests: HS_INCUS, HS_SS (command for the host's ss), HS_HOST_ADDRS (space separated),
# HS_ZORAXY (container name, default zoraxy), HS_STATE_DIR.
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
. "$here/lib/dc.sh"
dcn=$(dc_name)   # the domain controller is dc1, dc2 or whatever lib/dc.sh finds; the lists below say dc1
incus=${HS_INCUS:-incus}
ss_host=${HS_SS:-ss}
zoraxy=${HS_ZORAXY:-zoraxy}
state=${HS_STATE_DIR:-/var/lib/hs}

usage() {
  say "usage: hs ports [<container>] [--list]"
  say "       open ports of the server and the running containers; warns when an admin interface is behind Zoraxy"
  exit 1
}

only=""; list=false
for a in "$@"; do
  case "$a" in
    --list) list=true ;;
    -*) usage ;;
    *) only=$a ;;
  esac
done

# expected listeners: where, port|range|* (DHCP client 68, LLMNR 5355 and the Windows discovery ports 3702/5357 are normal; random high UDP ports are treated as ephemeral in the loop below)
expected_builtin() { expected_builtin_dc1 | sed "s/^dc1	/$dcn	/"; }
expected_builtin_dc1() {
  cat <<'EOF'
host	22
host	137
host	138
host	139
host	445
host	5353
host	3702
host	5357
host	8443
host	8444
host	9100
host	9633
host	26619
*	22
*	68
*	5355
*	80
*	443
zoraxy	8000
pelican-wings	2022
pelican-wings	8080
docker	*
sunshine	*
steamos	*
dc1	53
dc1	88
dc1	135
dc1	137-139
dc1	389
dc1	445
dc1	464
dc1	636
dc1	3268-3269
dc1	49152-65535
EOF
}

# admin interfaces: where (glob), port or *, label, severity (warn = never behind Zoraxy; info = public on purpose, look closer)
admin_builtin() { admin_builtin_dc1 | sed "s/^dc1	/$dcn	/"; }
admin_builtin_dc1() {
  printf 'host\t8443\tIncus\twarn\n'
  printf 'host\t26619\tWebZFS\twarn\n'
  printf 'host\t9100\tnode-exporter\twarn\n'
  printf 'host\t9633\tsmartctl-exporter\twarn\n'
  printf 'host\t8444\tIncus metrics\twarn\n'
  printf 'host\t9090\tPrometheus (127.0.0.1 only)\twarn\n'
  printf 'zoraxy\t8000\tZoraxy admin\twarn\n'
  printf 'docker\t80\tArcane\twarn\n'
  printf 'monitoring\t*\tGrafana/Prometheus/Loki\twarn\n'
  printf 'uptime-kuma\t*\tUptime Kuma\twarn\n'
  printf 'paperclip\t*\tPaperclip (its agents run shell commands)\twarn\n'
  printf 'homeassistant\t*\tHome Assistant\twarn\n'
  printf 'sunshine\t47990\tSunshine web UI\twarn\n'
  printf 'sunshine\t8083\tSteam Headless desktop (noVNC)\twarn\n'
  printf 'steamos\t5900\tSteam desktop (VNC)\twarn\n'
  printf 'dc1\t*\tdomain controller\twarn\n'
  printf 'pelican-panel\t*\tPelican Panel (public on purpose, but /admin must have its own protection)\tinfo\n'
}

in_range() {   # in_range <port> <spec>: spec is *, N or N-M
  local p=$1 s=$2
  case "$s" in
    '*') return 0 ;;
    *-*) [ "$p" -ge "${s%-*}" ] && [ "$p" -le "${s#*-}" ] ;;
    *) [ "$p" = "$s" ] ;;
  esac
}
is_expected() {   # is_expected <where> <port>
  local w p=$2 n s
  w=$1
  while IFS=$'\t' read -r n s; do
    [ -n "$n" ] || continue
    [ "$n" = "*" ] || [ "$n" = "$w" ] || continue
    in_range "$p" "$s" && return 0
  done < <(expected_builtin; [ ! -r "$state/ports-expected" ] || tr -s ' ' '\t' < "$state/ports-expected")
  return 1
}
admin_of() {   # admin_of <where> <port>: prints "label<TAB>severity" when it is an admin interface
  local w=$1 p=$2 n s l v
  while IFS=$'\t' read -r n s l v; do
    [ -n "$n" ] || continue
    # shellcheck disable=SC2254
    case "$w" in $n) ;; *) continue ;; esac
    if [ "$s" = "*" ] || [ "$s" = "$p" ]; then printf '%s\t%s\n' "$l" "${v:-warn}"; return 0; fi
  done < <(admin_builtin; [ ! -r "$state/ports-admin" ] || sed -E 's/^([^ ]+) +([^ ]+) +(.*[^ ]) +(warn|info)$/\1\t\2\t\3\t\4/; t; s/^([^ ]+) +([^ ]+) +(.*)$/\1\t\2\t\3\twarn/' "$state/ports-admin")
  return 1
}

# ss output on stdin -> proto, port, bind, process of everything that is not loopback-only
parse_ss() {
  awk '
    { proto = $1; sub(/^tcp.*/, "tcp", proto); sub(/^udp.*/, "udp", proto)
      if (proto != "tcp" && proto != "udp") next
      local = $5; port = local; sub(/.*:/, "", port)
      if (port !~ /^[0-9]+$/) next
      bind = local; sub(/:[^:]*$/, "", bind); gsub(/[][]/, "", bind); sub(/%.*/, "", bind)
      if (bind ~ /^127\./ || bind == "::1") next
      if (bind == "*" || bind == "0.0.0.0" || bind == "::" || bind == "") bind = "all"
      proc = "-"
      if (match($0, /\(\("[^"]+"/)) proc = substr($0, RSTART + 3, RLENGTH - 4)
      key = proto " " port
      if (key in seen) next
      seen[key] = bind
      printf "%s\t%s\t%s\t%s\n", proto, port, bind, proc }'
}

# incus list as csv (name, state, type, addresses; addresses may span lines) -> name state type address, one line per address
instances() {
  "$incus" list -f csv -c n,s,t,4 2>/dev/null | awk '
    { buf = buf (buf == "" ? "" : " ") $0; q += gsub(/"/, "\"")
      if (q % 2 == 0) { emit(buf); buf = ""; q = 0 } }
    function emit(r,   name, st, ty, rest, n, ip) {
      n = index(r, ","); name = substr(r, 1, n - 1); r = substr(r, n + 1)
      n = index(r, ","); st = substr(r, 1, n - 1); r = substr(r, n + 1)
      n = index(r, ","); ty = substr(r, 1, n - 1); rest = substr(r, n + 1)
      n = 0
      while (match(rest, /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/)) {
        ip = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
        printf "%s\t%s\t%s\t%s\n", name, st, ty, ip; n++
      }
      if (n == 0) printf "%s\t%s\t%s\t-\n", name, st, ty
    }'
}

host_addrs() {
  if [ -n "${HS_HOST_ADDRS:-}" ]; then printf '%s\n' $HS_HOST_ADDRS
  else ip -4 -o addr show 2>/dev/null | awk '{ sub(/\/.*/, "", $4); print $4 }' || true; fi
}

# Zoraxy rules -> source, host name, target host, port
proxy_targets() {
  local rules
  rules=$("$incus" exec "$zoraxy" -- sh -c 'find / -xdev -path "*/conf/proxy/*.config" -type f 2>/dev/null | while read -r f; do echo "## $f"; cat "$f"; echo; done' 2>/dev/null || true)
  if grep -q '^## ' <<<"$rules"; then
    awk '
      function flush(   i, t, h, p) {
        for (i = 1; i <= nt; i++) {
          t = tg[i]; sub(/^https?:\/\//, "", t); sub(/\/.*/, "", t)
          h = t; p = 80
          if (t ~ /:[0-9]+$/) { p = t; sub(/.*:/, "", p); h = t; sub(/:[0-9]+$/, "", h) }
          printf "rules\t%s\t%s\t%s\n", (dom == "" ? "-" : dom), h, p
        }
        nt = 0; dom = ""
      }
      /^## / { flush(); next }
      { l = $0
        while (match(l, /"RootOrMatchingDomain" *: *"[^"]*"/)) { v = substr(l, RSTART, RLENGTH); sub(/^[^:]*: *"/, "", v); sub(/"$/, "", v); dom = v; l = substr(l, RSTART + RLENGTH) }
        l = $0
        while (match(l, /"(OriginIpOrDomain|Domain)" *: *"[^"]+"/)) { v = substr(l, RSTART, RLENGTH); sub(/^[^:]*: *"/, "", v); sub(/"$/, "", v); tg[++nt] = v; l = substr(l, RSTART + RLENGTH) } }
      END { flush() }' <<<"$rules"
    return 0
  fi
  # fallback: what the Zoraxy container is talking to right now (outgoing connections to a low port)
  "$incus" exec "$zoraxy" -- ss -H -tn state established 2>/dev/null | awk '
    { l = $3; p = $4; lp = l; sub(/.*:/, "", lp); h = p; sub(/:[^:]*$/, "", h); pp = p; sub(/.*:/, "", pp)
      if (lp + 0 >= 32768 && pp + 0 < 32768 && !(h in s)) { s[h " " pp] = 1; printf "live\t-\t%s\t%s\n", h, pp } }' | sort -u || true
}

# ── what runs ─────────────────────────────────────────────────────────────────
inst=$(instances || true)
mapfile -t running < <(awk -F'\t' 'toupper($2) == "RUNNING" && !seen[$1]++ { print $1 }' <<<"$inst")
if [ -n "$only" ]; then
  found=false
  for c in ${running[@]+"${running[@]}"}; do [ "$c" != "$only" ] || found=true; done
  [ "$only" = host ] || $found || fail_fix "$(t "No running instance called '%s'." "$only")" "hs ct list"
fi

listen_rows=""   # where proto port bind process status note
for where in host ${running[@]+"${running[@]}"}; do
  [ -z "$only" ] || [ "$only" = "$where" ] || continue
  if [ "$where" = host ]; then
    # shellcheck disable=SC2086
    out=$($ss_host -H -tulnp 2>/dev/null || true)
  else
    out=$("$incus" exec "$where" -- ss -H -tulnp 2>/dev/null) || { listen_rows+="$where"$'\t-\t-\t-\t-\tno-ss\t'"ss not available inside"$'\n'; continue; }
  fi
  while IFS=$'\t' read -r proto port bind proc; do
    [ -n "$port" ] || continue
    if lab=$(admin_of "$where" "$port"); then st=admin; note=${lab%%$'\t'*}
    elif is_expected "$where" "$port"; then st=expected; note="-"
    elif [ "$proto" = udp ] && [ "$port" -ge 32768 ]; then st=expected; note="ephemeral"   # random high UDP ports: QUIC, mDNS answers, resolver sockets
    else st=unexpected; note="-"; fi
    listen_rows+="$where"$'\t'"$proto"$'\t'"$port"$'\t'"$bind"$'\t'"$proc"$'\t'"$st"$'\t'"$note"$'\n'
  done < <(parse_ss <<<"$out" | sort -t$'\t' -k2,2n)
done

# ── what Zoraxy proxies ───────────────────────────────────────────────────────
proxy_rows=""; warns=0
zoraxy_note=""
{
  if ! awk -F'\t' -v z="$zoraxy" 'toupper($2) == "RUNNING" && $1 == z { f = 1 } END { exit !f }' <<<"$inst"; then
    zoraxy_note=$(t "Zoraxy ('%s') is not running or does not exist: the proxy check was skipped." "$zoraxy")
  else
    haddrs=" $(host_addrs | tr '\n' ' ') "
    targets=$(proxy_targets || true)
    [ -n "$targets" ] || zoraxy_note=$(t "No Zoraxy rule could be read and no connection is open: the proxy check found nothing.")
    while IFS=$'\t' read -r src dom th tp; do
      [ -n "$th" ] || continue
      where=$(awk -F'\t' -v a="$th" '$4 == a { print $1; exit }' <<<"$inst")
      [ -n "$where" ] || { case "$haddrs" in *" $th "*) where=host ;; esac; }
      [ -n "$where" ] || where=$(awk -F'\t' -v a="$th" '$1 == a { print $1; exit }' <<<"$inst")
      if [ -z "$where" ]; then
        proxy_rows+="?"$'\t'"tcp"$'\t'"$tp"$'\t'"$dom"$'\t'"$src"$'\t'"unknown"$'\t'"$th"$'\n'
      elif lab=$(admin_of "$where" "$tp"); then
        sev=${lab#*$'\t'}; lab=${lab%%$'\t'*}
        if [ "$sev" = info ]; then st=info; else st=WARN; warns=$((warns + 1)); fi
        proxy_rows+="$where"$'\t'"tcp"$'\t'"$tp"$'\t'"$dom"$'\t'"$src"$'\t'"$st"$'\t'"$lab"$'\n'
      else
        proxy_rows+="$where"$'\t'"tcp"$'\t'"$tp"$'\t'"$dom"$'\t'"$src"$'\t'"ok"$'\t'"-"$'\n'
      fi
    done <<<"$targets"
  fi
}

# ── output ────────────────────────────────────────────────────────────────────
if $list; then
  while IFS=$'\t' read -r w rest; do [ -z "$w" ] || printf 'listen\t%s\t%s\n' "$w" "$rest"; done <<<"$listen_rows"
  while IFS=$'\t' read -r w rest; do [ -z "$w" ] || printf 'proxy\t%s\t%s\n' "$w" "$rest"; done <<<"$proxy_rows"
  [ "$warns" -eq 0 ] || exit 1
  exit 0
fi

step "$(t 'Listening ports (loopback only is left out)')"
unexp=$(awk -F'\t' '$6 == "unexpected" { n++ } END { print n + 0 }' <<<"$listen_rows")
if [ "$unexp" -eq 0 ]; then status_line "Listeners" "All expected" ok; else status_line "Listeners" "$(t '%s unexpected' "$unexp")" warn; fi
{
  thead 'Where' 'Proto' 'Port' 'Bind' 'Program' 'Status'
  while IFS=$'\t' read -r w proto port bind proc st note; do
    [ -n "$w" ] || continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$w" "$proto" "$port" "$bind" "$proc" "$st$([ "$note" = - ] || printf " (%s)" "$note")"
  done <<<"$listen_rows"
} | table
if [ "$unexp" -gt 0 ]; then
  note "$(t '%s listener(s) are not in the list of expected ports. If they are fine: add a line "<name> <port>" to %s.' "$unexp" "$state/ports-expected")"
fi

step "$(t 'What Zoraxy passes on')"
[ -z "$zoraxy_note" ] || note "$zoraxy_note"
if [ "$warns" -gt 0 ]; then status_line "Admin interfaces" "$(t '%s behind Zoraxy' "$warns")" bad
elif [ -n "$proxy_rows" ]; then status_line "Admin interfaces" "None behind Zoraxy" ok; fi
if [ -n "$proxy_rows" ]; then
  {
    thead 'Target' 'Port' 'Host name' 'Source' 'Status' 'What'
    while IFS=$'\t' read -r w _ port dom src st note; do
      [ -n "$w" ] || continue
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$w" "$port" "$dom" "$src" "$st" "$note"
    done <<<"$proxy_rows"
  } | table
  while IFS=$'\t' read -r w _ port dom _ st note; do
    [ "$st" = WARN ] || continue
    warn "$(t "%s (port %s, %s) is reachable from the internet through the Zoraxy rule for '%s'." "$w" "$port" "$note" "$dom")"
  done <<<"$proxy_rows"
fi
if [ "$warns" -gt 0 ]; then
  note "$(t 'Remove these rules in the Zoraxy admin interface (it is never given a rule itself). Admin interfaces stay internal.')"
  exit 1
fi
exit 0
