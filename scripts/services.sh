#!/usr/bin/env bash
# help: the services of this server (a web page, an API ...) and where they are published: list, check, plan, add, remove, import
# help.de: die Dienste dieses Servers (eine Weboberfläche, eine API ...) und wo sie veröffentlicht sind: list, check, plan, add, remove, import
# args: list | check | plan | add <name> --port <n> (--container <ct> | --host <h>) [...] | edit <name> [...] | show <name> | remove <name> | import [--dry-run] [--yes]
# A service is a small file in /var/lib/hs/services.d (scripts/services.py describes it). Recipes and people write them; the providers
# (the reverse proxy, later DNS, the dashboard ...) are asked to match them. Nothing here changes a proxy yet: `plan` shows what a
# provider has and what the services want, `import` makes services out of the routes the proxy has today (docs/PLAN-modular-core.md step 4).
#
#   hs services list [--plain]          the services (plain: name, title, target, exposure, names, wants; hs sys services list)
#   hs services check                   problems in the files, exit 1 when there are some
#   hs services plan [--plain]          the proxy's routes against the services: ok, add, change, confirm, blocked, violation,
#                                       unresolved, unmanaged (plain: act, host, path, target, service, note; hs sys services plan)
#   hs services add <name> --port N (--container C | --host H) [--title T] [--names a,b] [--fqdn x.y] [--exposure E]
#                    [--public-path /p] [--want reverse-proxy,dns] [--icon I] [--health /]
#   hs services set <name> [--local yes|no] [--public yes|no] [--public-name FQDN]   change an existing service (routes: apply)
#   hs services remove <name>        the description only; routes the proxy has stay (plan shows them as unmanaged)
#   hs services import [--dry-run] [--yes]   one service per route the proxy has, public ones marked public-ok (admin pages never-public)
#   hs services apply [--dry-run] [--confirm <host or service>]...   do what the plan says: add, confirm (publish on the internet),
#                    change (a route hs made or adopted gets another target) and remove (a route hs made or adopted that no service wants
#                    any more). confirm, change and remove need the host name typed when asked, or --confirm <host or service> without a
#                    terminal. Blocked services and violations are never touched. Needs the proxy in api mode.
#   hs services declare <name> --container C --port N ...   what a recipe says about its service (created, or refreshed without touching
#                    what a person decided); hs services tiles: the dashboard tiles of the services that want one
#   hs services adopt [--yes]           routes made by hand that match a service become ones hs may change and remove (a list of
#                    routes in /var/lib/hs/services.state; nothing is sent to the proxy)
#   hs services proxy login             the admin login of the proxy (Zoraxy has no API keys): checked, then kept in the vault (zoraxy-admin)
# The guard: on a public proxy a never-public or private-ok service gets no route, a public-ok one needs a typed confirmation.
#   --proxy public|local  (plan, apply, import, adopt; default public) picks the slot: public = the reverse proxy (Zoraxy), local = the gateway
#                    proxy (Traefik, capability gateway) with the names <label>.<site>.<realm>. The slots are independent: a descriptor wants
#                    them with [want] reverse-proxy and local-proxy. The local proxy must never be public (refused when its info says so).
#   hs services apply --proxy local --adds-only   only the routes to add, no question (what declare_service runs)
#   hs services import --proxy local [--dry-run] [--yes]   the migration: every service without local-proxy gets local-proxy = true
# Test knobs: HS_SERVICES_DIR, HS_STATE_DIR, HS_SETTINGS_DIR, HS_INCUS, HS_PROVIDER_DIR, HS_PYTHON, HS_DNS_SH, HS_CAPABILITIES_FILE.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/ui.sh"
. "$here/lib/setting.sh"
. "$here/lib/secret.sh"
. "$here/lib/capability.sh"
state=${HS_STATE_DIR:-/var/lib/hs}
inc=${HS_INCUS:-incus}
py=${HS_PYTHON:-python3}; command -v "$py" >/dev/null 2>&1 || py=python
svc() { PYTHONUTF8=1 "$py" "$here/services.py" "$@"; }
interactive() { [ -t 0 ] && [ -t 1 ] && [ -z "${HS_CALLER:-}" ] || [ -n "${HS_GUIDED_TTY:-}" ]; }

usage() {
  say "usage: hs services list | check | plan | add <name> ... | edit <name> ... | remove <name> | import [--dry-run] [--yes] | apply [--dry-run] [--confirm <host or service>] | adopt [--yes] | proxy login   (plan, apply, import, adopt: [--proxy public|local])"
  exit 1
}

work=$(mktemp -d /tmp/hs-services.XXXXXX)
trap 'rm -rf "$work"' EXIT

# The reverse proxy in use: the runtime setting reverseProxy names the variant, scripts/providers/reverse-proxy/<variant>.sh is it.
variant=$(setting_get reverseProxy 2>/dev/null || true)
provider_dir=${HS_PROVIDER_DIR:-$here/providers}/reverse-proxy
provider() { bash "$provider_dir/$variant.sh" "$@"; }
dash_dir=${HS_DASHBOARD_DIR:-${HS_PROVIDER_DIR:-$here/providers}/dashboard}   # the dashboard providers (test knob HS_DASHBOARD_DIR)

# info, routes and addresses into $work; returns 1 (and says why) when there is no reverse proxy
gather() {
  if [ -z "$variant" ]; then
    $plain || note "$(t 'No reverse proxy is set up (hs recipe zoraxy, then: hs config set reverseProxy zoraxy).')"
    return 1
  fi
  [ -f "$provider_dir/$variant.sh" ] || { $plain || warn "$(t "The reverse proxy '%s' has no provider here." "$variant")"; return 1; }
  provider info > "$work/info.tsv" || { $plain || warn "$(t 'The reverse proxy did not answer.')"; return 1; }
  if [ "$proxy" = local ] && grep -q '^public.yes$' "$work/info.tsv"; then
    fail "$(t 'The local proxy must never be public: its provider says it is.')"
  fi
  provider owned-list > "$work/owned.tsv" 2>/dev/null || : > "$work/owned.tsv"   # the routes hs made or adopted (a variant without the verb: none)
  provider list > "$work/routes.tsv" || { $plain || warn "$(t 'The routes of the reverse proxy could not be read.')"; return 1; }
  "$inc" list --format json 2>/dev/null | svc addrs > "$work/addrs.tsv" || : > "$work/addrs.tsv"
  # the local slot: names that have an explicit DNS record beat the wildcard (best effort, nothing on failure)
  if [ "$proxy" = local ]; then
    : > "$work/explicit.tsv"
    if capability_on ad; then
      timeout 20 bash "${HS_DNS_SH:-$here/dns.sh}" raw > "$work/explicit.tsv" 2>/dev/null || : > "$work/explicit.tsv"
    fi
    slot_args=(--slot local --explicit "$work/explicit.tsv")
  fi
}

cmd=${1:-list}; [ $# -eq 0 ] || shift
plain=false
# --proxy public|local: the slot (plan, apply, import, adopt); list, check and tiles ignore it
proxy=public; slot_args=(); adds_only=false; rest_args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --proxy) shift; proxy=${1:-}; [ "$proxy" = public ] || [ "$proxy" = local ] || usage ;;
    --adds-only) adds_only=true ;;
    *) rest_args+=("$1") ;;
  esac
  shift
done
set -- ${rest_args[@]+"${rest_args[@]}"}
case "$cmd" in plan|apply|import|adopt) ;; *) proxy=public ;; esac
if [ "$proxy" = local ]; then
  # a machine-readable read while the capability is off answers with a status line, not with text
  if [[ " ${rest_args[*]:-} " == *" --plain "* ]] && ! capability_on gateway; then printf 'status\toff\n'; exit 0; fi
  capability_on gateway || fail "$(t 'The gateway proxy is off: put capabilities = ["gateway"] in machine.toml, then hs rebuild.')"
  variant=traefik
  slot_args=(--slot local)
fi
case "$cmd" in
  list)
    [ "${1:-}" != --plain ] || plain=true
    rows=$(svc list)
    if $plain; then [ -z "$rows" ] || printf '%s\n' "$rows"; exit 0; fi
    if [ -z "$rows" ]; then note "$(t 'No services yet. Make them from the proxy routes with: hs services import')"; exit 0; fi
    { thead 'Service' 'Title' 'Target' 'Exposure' 'Names' 'Wants'; printf '%s\n' "$rows"; } | table ;;
  check)
    out=$(svc check) && { ok "$(t 'The service files are fine.')"; exit 0; }
    printf '%s\n' "$out" | while IFS= read -r l; do warn "$l"; done
    exit 1 ;;
  plan)
    [ "${1:-}" != --plain ] || plain=true
    if ! gather; then $plain && printf 'status\tnone\n'; exit 0; fi
    svc plan --info "$work/info.tsv" --routes "$work/routes.tsv" --addrs "$work/addrs.tsv" --owned "$work/owned.tsv" ${slot_args[@]+"${slot_args[@]}"} > "$work/plan.tsv"
    # in api mode the API and the rule files must tell the same story, else nothing should be written on the strength of the API
    selfcheck=$(provider check 2>/dev/null || true)
    case "$selfcheck" in differ*) printf 'warn\t-\t-\t-\t-\tthe API and the rule files list different routes (%s)\n' "$(cut -f2- <<<"$selfcheck" | tr '\t' '/')" >> "$work/plan.tsv" ;; esac
    if $plain; then cat "$work/plan.tsv"; exit 0; fi
    step "$(t 'Services and the reverse proxy')"
    kv "Proxy" "$(awk -F'\t' '$1 == "name" { print $2 }' "$work/info.tsv") ($(awk -F'\t' '$1 == "public" { print ($2 == "yes" ? "public" : "private") }' "$work/info.tsv"), $(awk -F'\t' '$1 == "mode" { print $2 }' "$work/info.tsv"))"
    pnote=$(awk -F'\t' '$1 == "note" { print $2 }' "$work/info.tsv")
    [ -z "$pnote" ] || note "$pnote"
    if [ ! -s "$work/plan.tsv" ]; then note "$(t 'No services want a route and the proxy has none.')"; exit 0; fi
    { thead 'Action' 'Host' 'Path' 'Target' 'Service' 'Note'; cat "$work/plan.tsv"; } | table
    n=$(awk -F'\t' '$1 == "violation"' "$work/plan.tsv" | wc -l | tr -d ' ')
    [ "$n" -eq 0 ] || warn "$(t '%s route(s) exist that the guard forbids: a never-public or private-ok service is on the public proxy.' "$n")" ;;
  apply)
    dry=false; confirmed=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --dry-run) dry=true ;;
        --yes) ;;
        --confirm) shift; [ -n "${1:-}" ] || usage; confirmed+=("$1") ;;
        *) usage ;;
      esac
      shift
    done
    gather || exit 1
    mode=$(awk -F'\t' '$1 == "mode" { print $2 }' "$work/info.tsv")
    svc plan --info "$work/info.tsv" --routes "$work/routes.tsv" --addrs "$work/addrs.tsv" --owned "$work/owned.tsv" ${slot_args[@]+"${slot_args[@]}"} > "$work/plan.tsv"
    tabc=$(printf '\t')
    # first what is added or changed, hosts before their paths; then what is removed, paths before their hosts
    if $adds_only; then
      todo=$(awk -F'\t' '$1 == "add"' "$work/plan.tsv" | sort -t"$tabc" -k2,2 -k3,3)
    else
      todo=$({ awk -F'\t' '$1 == "add" || $1 == "confirm" || ($1 == "change" && $6 !~ /adopt it first/)' "$work/plan.tsv" | sort -t"$tabc" -k2,2 -k3,3
               awk -F'\t' '$1 == "remove"' "$work/plan.tsv" | sort -t"$tabc" -k2,2 -k3,3r; })
    fi
    rest=$(awk -F'\t' '$1 == "blocked" || $1 == "violation" || $1 == "unresolved" || $1 == "conflict" || $1 == "invalid" || ($1 == "change" && $6 ~ /adopt it first/)' "$work/plan.tsv")
    if [ "$proxy" = local ]; then step "$(t 'Making the local names of the services')"; else step "$(t 'Making the routes of the services')"; fi
    if [ -z "$todo" ]; then
      note "$(t 'Nothing to do.')"
    else
      if [ "$mode" != api ] && ! $dry; then
        fail_fix "$(t 'The proxy is read-only here, so no route can be made.')" "hs services proxy login"
      fi
      case "$(provider check 2>/dev/null || true)" in
        differ*) fail "$(t 'The API and the rule files of the proxy list different routes: nothing is made until that is understood.')" ;;
      esac
      done_n=0; failed=0; skipped=0
      while IFS=$'\t' read -r act host path target service _; do
        [ -n "$act" ] || continue
        # a route that goes on the internet, is changed or is removed needs the host name typed (or --confirm <host or service>)
        if [ "$act" = confirm ] || [ "$act" = change ] || [ "$act" = remove ]; then
          ok_host=false
          for c in ${confirmed[@]+"${confirmed[@]}"}; do
            if [ "$c" = "$host" ] || { [ "$service" != - ] && [ "$c" = "$service" ]; }; then ok_host=true; fi
          done
          if ! $ok_host && ! $dry && interactive; then
            case "$act" in
              confirm) warn "$(t "%s is public-ok: this puts '%s' on the internet." "$service" "$host")" ;;
              change) warn "$(t "This changes the live route %s%s to %s." "$host" "$path" "$target")" ;;
              remove) warn "$(t "This removes the live route %s%s." "$host" "$path")" ;;
            esac
            [ "$(ask "$(t 'Type the host name to confirm')" "")" = "$host" ] && ok_host=true || true
          fi
          if ! $ok_host && ! $dry; then
            note "$(t "%s%s: needs the typed confirmation (--confirm %s)" "$host" "$path" "$host")"
            skipped=$((skipped + 1)); continue
          fi
          # one confirmation covers the host: its other routes
          confirmed+=("$host")
        fi
        if $dry; then
          case "$act" in
            remove) note "$(t 'Would remove %s%s' "$host" "$path")" ;;
            change) note "$(t 'Would change %s%s -> %s' "$host" "$path" "$target")" ;;
            *) note "$(t 'Would make %s%s -> %s' "$host" "$path" "$target")" ;;
          esac
          continue
        fi
        rc=0
        if [ "$act" = remove ]; then cmd_out=$(provider remove "$host" "$path" 2>&1) || rc=$?; else cmd_out=$(provider ensure "$host" "$path" "$target" 2>&1) || rc=$?; fi
        if [ "$rc" -eq 0 ]; then
          ok "$(t '%s%s -> %s (%s)' "$host" "$path" "$target" "$cmd_out")"; done_n=$((done_n + 1))
        else
          warn "$(t '%s%s could not be made: %s' "$host" "$path" "$cmd_out")"; failed=$((failed + 1))
        fi
      done <<<"$todo"
      $dry || status_line "Routes" "$(t '%s done, %s failed, %s waiting for a confirmation' "$done_n" "$failed" "$skipped")" "$([ "$failed" -eq 0 ] && echo ok || echo bad)"
    fi
    # blocked services and violations are not touched here: say so, whether or not something was done
    if [ -n "$rest" ]; then
      note "$(t 'Left alone (see hs services plan): %s row(s) that are blocked, violations, conflicts or routes not made by hs (adopt them first).' "$(grep -c . <<<"$rest")")"
    fi
    # the dashboard follows the services: the tiles of those that want one are written again
    dash=$(setting_get dashboard 2>/dev/null || true)
    if ! $dry && [ -n "$dash" ] && [ -f "$dash_dir/$dash.sh" ] && [ -n "$(svc tiles --addrs "$work/addrs.tsv")" ]; then
      if out=$(bash "$dash_dir/$dash.sh" sync 2>&1); then ok "$(t 'Dashboard: %s' "$out")"
      else warn "$(t 'The dashboard could not be refreshed: %s' "$out")"; fi
    fi
    [ "${failed:-0}" -eq 0 ] || exit 1 ;;
  adopt)
    yes=false
    for a in "$@"; do case "$a" in --yes) yes=true ;; *) usage ;; esac; done
    gather || exit 1
    svc plan --info "$work/info.tsv" --routes "$work/routes.tsv" --addrs "$work/addrs.tsv" --owned "$work/owned.tsv" ${slot_args[@]+"${slot_args[@]}"} > "$work/plan.tsv"
    rows=$(awk -F'\t' '$1 == "ok" && $6 ~ /^not adopted/ { print $2 "\t" $3 "\t" $4 "\t" $5 }' "$work/plan.tsv")
    step "$(t 'Routes made by hand that match a service')"
    if [ -z "$rows" ]; then note "$(t 'Nothing to adopt.')"; exit 0; fi
    { thead 'Host' 'Path' 'Target' 'Service'; printf '%s\n' "$rows"; } | table
    n=$(grep -c . <<<"$rows")
    if ! $yes; then
      interactive || fail "$(t 'Adopting writes a list of routes: run it on a terminal, or add --yes.')"
      confirm "$(t 'Let hs change and remove these %s route(s) from now on?' "$n")" || { note "$(t 'Nothing written.')"; exit 0; }
    fi
    while IFS=$'\t' read -r host path _; do
      [ -n "$host" ] || continue
      provider adopt "$host" "$path" > /dev/null || fail "$(t "Could not adopt %s%s." "$host" "$path")"
    done <<<"$rows"
    ok "$(t '%s route(s) adopted.' "$n")"
    note "$(t 'A service that no longer wants one of them now shows it as a remove row in hs services plan.')" ;;
  declare)
    # what a recipe says about its service (scripts/recipes/_lib.sh declare_service): created, or the facts refreshed and nothing a person decided touched
    [ $# -ge 1 ] || usage
    svc declare "$@" ;;
  tiles)
    # the dashboard tiles: group, title, link, description, icon, name (--containers: the containers they live in; --table: for people)
    if [ "${1:-}" = --containers ]; then svc tiles --containers; exit 0; fi
    plain=true
    "$inc" list --format json 2>/dev/null | svc addrs > "$work/addrs.tsv" || : > "$work/addrs.tsv"
    extra=()
    if gather; then
      svc plan --info "$work/info.tsv" --routes "$work/routes.tsv" --addrs "$work/addrs.tsv" --owned "$work/owned.tsv" ${slot_args[@]+"${slot_args[@]}"} > "$work/plan.tsv" &&
        extra=(--plan "$work/plan.tsv" --info "$work/info.tsv")
    fi
    if capability_on gateway; then   # a service with a gateway name links to <name>.<siteName>.<domain>
      declare -F machine_get >/dev/null || . "$here/lib/machine.sh"
      . "$here/lib/localdomain.sh"
      ld=$(local_domain)
      [ -z "$ld" ] || extra+=(--local-domain "$ld")
    fi
    tiles_out=$(svc tiles --addrs "$work/addrs.tsv" ${extra[@]+"${extra[@]}"})
    if [ "${1:-}" != --table ]; then [ -z "$tiles_out" ] || printf '%s\n' "$tiles_out"; exit 0; fi   # plain: hs sys services tiles
    if [ -z "$tiles_out" ]; then note "$(t 'No service wants a tile on the dashboard (hs services declare ... --want dashboard).')"; exit 0; fi
    { thead 'Group' 'Title' 'Link' 'Description' 'Icon' 'Service'; printf '%s\n' "$tiles_out"; } | table ;;
  proxy)
    [ "${1:-}" = login ] || usage
    [ -n "$variant" ] || fail_fix "$(t 'No reverse proxy is set up.')" "hs config set reverseProxy zoraxy"
    user=${HS_PROXY_USER:-}; pass=${HS_PROXY_PASS:-}
    if [ -z "$user" ]; then
      interactive || fail "$(t 'The login is asked for on a terminal.')"
      user=$(ask "$(t 'Admin name of the proxy')" admin)
      pass=$(ask_secret "$(t 'Password')")
    fi
    [ -n "$user" ] && [ -n "$pass" ] || fail "$(t 'A name and a password are needed.')"
    ( umask 077; printf '%s\n%s\n' "$user" "$pass" > "$work/cred" )
    out=$(provider login-check "$work/cred" 2>&1) || fail "$(t 'The proxy did not accept the login: %s' "$out")"
    secret_prepare zoraxy-admin "$state" || fail_fix "$(t 'The vault is closed.')" "hs unlock"
    mkdir -p "$state"
    ( umask 077; cat "$work/cred" > "$state/zoraxy-admin" )
    chmod 600 "$state/zoraxy-admin" 2>/dev/null || true
    ok "$(t 'The login works and is kept in the vault.')"
    note "$(t 'Next: hs services plan')" ;;
  add)
    [ $# -ge 1 ] || usage
    svc add "$@" && ok "$(t "Service '%s' is described." "$1")" || fail "$(t "Could not add '%s'." "$1")" ;;
  set)
    [ $# -ge 2 ] || usage
    svc set "$@" && ok "$(t "Service '%s' is changed (Apply makes the route)." "$1")" || fail "$(t "Could not change '%s'." "$1")" ;;
  apps)
    rows=$(svc apps); [ -z "$rows" ] || printf '%s\n' "$rows" ;;   # hs sys services app
  edit)
    [ $# -ge 1 ] || usage
    svc edit "$@" && ok "$(t "Service '%s' is changed." "$1")" || fail "$(t "Could not change '%s'." "$1")" ;;
  show)
    [ $# -eq 1 ] || usage
    svc show "$1" ;;
  remove)
    [ $# -eq 1 ] || usage
    svc remove "$1" && ok "$(t "Service '%s' is removed (its routes stay)." "$1")" || fail "$(t "'%s' is not a service." "$1")" ;;
  import)
    dry=false; yes=false
    for a in "$@"; do case "$a" in --dry-run) dry=true ;; --yes) yes=true ;; *) usage ;; esac; done
    if [ "$proxy" = local ]; then
      # the migration: every service without local-proxy gets it (descriptors only, no provider asked)
      svc import --slot local > "$work/import.tsv"
      if [ ! -s "$work/import.tsv" ]; then note "$(t 'Every service already says whether it wants a local name.')"; exit 0; fi
      step "$(t 'Services that get a local name')"
      { thead 'Action' 'Service' 'Names' 'Target'; cat "$work/import.tsv"; } | table
      n=$(grep -c . "$work/import.tsv")
      $dry && { note "Dry run: nothing written."; exit 0; }
      if ! $yes; then
        interactive || fail "$(t 'Importing writes service files: run it on a terminal, or add --yes.')"
        confirm "$(t 'Give these %s service(s) a local name (local-proxy = true)?' "$n")" || { note "$(t 'Nothing written.')"; exit 0; }
      fi
      svc import --slot local --write > /dev/null
      ok "$(t '%s service(s) now want a local name.' "$n")"
      note "$(t 'Next: hs services plan --proxy local, then hs services apply --proxy local')"
      exit 0
    fi
    gather || exit 1
    svc import --info "$work/info.tsv" --routes "$work/routes.tsv" --addrs "$work/addrs.tsv" > "$work/import.tsv"
    if [ ! -s "$work/import.tsv" ]; then note "$(t 'The proxy has no routes to make services of.')"; exit 0; fi
    step "$(t 'Services found in the routes of the proxy')"
    { thead 'Action' 'Service' 'Target' 'Exposure' 'Hosts' 'Note'; cat "$work/import.tsv"; } | table
    creates=$(awk -F'\t' '$1 == "create"' "$work/import.tsv" | wc -l | tr -d ' ')
    [ "$creates" -gt 0 ] || { note "$(t 'Nothing new to describe.')"; exit 0; }
    $dry && { note "Dry run: nothing written."; exit 0; }
    if ! $yes; then
      interactive || fail "$(t 'Importing writes service files: run it on a terminal, or add --yes.')"
      confirm "$(t 'Describe these %s service(s)?' "$creates")" || { note "$(t 'Nothing written.')"; exit 0; }
    fi
    svc import --info "$work/info.tsv" --routes "$work/routes.tsv" --addrs "$work/addrs.tsv" --write > /dev/null
    ok "$(t '%s service(s) described in %s' "$creates" "${HS_SERVICES_DIR:-${HS_STATE_DIR:-/var/lib/hs}/services.d}")"
    note "$(t 'Check the exposure of each: public-ok means it is reachable from the internet today.')" ;;
  *) usage ;;
esac
