#!/usr/bin/env bash
# help: notification channels: list, show, add, change, remove, test, and the providers (ntfy, email)
# help.de: Benachrichtigungskanäle: anzeigen, hinzufügen, ändern, entfernen, testen, und die Anbieter (ntfy, E-Mail)
# args: list | --list | show <name> | --show <name> | add <name> --provider <p> [options] | set <name> [options] | remove <name> [--yes] | test <name> | migrate | providers | --providers
#  (capability `notifications`). A channel is a file in /var/lib/hs/notify-channels (scripts/lib/channels.sh); the
# providers are scripts/notify/<provider>.sh. Options of add and set:
#   --provider <p>          (add only) ntfy
#   --min-priority <p>      min, low, default, high or urgent (add: min)
#   --quiet respect|ignore  respect = wait for the end of the quiet hours (default); ignore = always at once
#   --enabled yes|no
#   --categories a,b        the message classes it carries, from alarm,status,heartbeat,digest (add: alarm,status,digest); the provider's `caps` limit them
#   --set key=value        a setting of the provider that is not secret
#   --secret key            a secret setting: the value is read from stdin (one line per --secret), or asked without echo at a terminal
# --list (hs sys notify channels): one channel per line, tab separated, no empty field: name, provider, enabled, minprio, quiet, outside
#   (outside|inside), source (file|derived), ready (ok|incomplete), categories (comma separated), caps (what the provider can carry, comma
#   separated), then the last send: time (epoch seconds or -), ok|failed or -, a short reason or - (never an address or a long token; kept in
#   .results next to the channel files, written by notify.sh and `test`). No channel: no lines.
# --show <name> (hs sys notify channel): key<TAB>value lines; a secret is `set` or `-`, never its value. Exit 1 when unknown.
# --providers (hs sys notify providers): provider, key, label, kind (text|secret), required|optional, pattern (or -), caps (comma separated). One setting per line.
# Test knobs: HS_STATE_DIR, HS_NOTIFY_CHANNELS_DIR, HS_NOTIFY_PROVIDERS, HS_NOTIFY_TIMEOUT.
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
. "$here/lib/channels.sh"
. "$here/lib/notify-route.sh"
# the channel files are root only (0600): a caller that cannot read them goes through sudo
chan_need_root "$0" "$@"

usage() {
  say "usage: hs notify channel list"
  say "       hs notify channel show <name>"
  say "       hs notify channel add <name> --provider <provider> [--min-priority P] [--quiet respect|ignore] [--categories a,b] [--set key=value] [--secret key]"
  say "       hs notify channel set <name> [--enabled yes|no] [--min-priority P] [--quiet respect|ignore] [--categories a,b] [--set key=value] [--secret key]"
  say "       hs notify channel remove <name> [--yes]"
  say "       hs notify channel test <name>"
  say "       hs notify channel migrate"
  say "       hs notify channel providers"
  exit 1
}
interactive() { [ -t 0 ] && [ -t 1 ] && [ -z "${HS_CALLER:-}" ] || [ -n "${HS_GUIDED_TTY:-}" ]; }

valid_prio() { case "$1" in min|low|default|high|urgent) return 0 ;; *) return 1 ;; esac; }
dash() { if [ -n "$1" ]; then printf '%s' "$1"; else printf -- '-'; fi; }

providers() {   # the provider names
  local f
  for f in "$(chan_providers_dir)"/*.sh; do [ -e "$f" ] && basename "$f" .sh; done
  return 0
}

# the settings of a provider: fills FTYPE[key]=text|secret, FREQ[key]=required|optional, FLABEL[key], FPAT[key]; returns 1 for an unknown provider
load_fields() {
  local k l t r p
  declare -gA FTYPE=() FREQ=() FLABEL=() FPAT=()
  chan_provider_ok "$1" || return 1
  while IFS=$'\t' read -r k l t r p; do
    [ -n "$k" ] || continue
    FTYPE[$k]=$t; FREQ[$k]=$r; FLABEL[$k]=$l; FPAT[$k]=$p
  done < <(bash "$(chan_providers_dir)/$1.sh" fields)
  return 0
}

outside_of() {   # outside_of <name>: outside | inside (the channel must be loaded)
  local o
  o=$(chan_run "${CH[provider]}" where 2>/dev/null) || o=inside
  case "$o" in outside) echo outside ;; *) echo inside ;; esac
}

ready_of() { if chan_run "${CH[provider]}" check >/dev/null 2>&1; then echo ok; else echo incomplete; fi; }

# the message classes a provider can carry, space separated (a provider without `caps` carries the three it always did)
caps_of() {   # caps_of <provider>
  local c
  c=$(bash "$(chan_providers_dir)/$1.sh" caps 2>/dev/null) || c=""
  printf '%s' "${c:-alarm status digest}"
}

cmd_list() {
  local n c
  for n in $(chan_names); do
    chan_load "$n" || continue
    c=$(caps_of "${CH[provider]}")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "${CH[provider]}" "${CH[enabled]}" "${CH[minprio]}" "${CH[quiet]}" \
      "$(outside_of)" "$(chan_source "$n")" "$(ready_of)" "$(dash "${CH[categories]}")" "${c// /,}" "$(chan_result_get "$n")"
  done
}

cmd_list_people() {
  local rows
  rows=$(cmd_list)
  if [ -z "$rows" ]; then
    note "There are no notification channels yet."
    note "Add one: hs notify channel add <name> --provider ntfy --secret url"
    return 0
  fi
  { thead "Channel" "Provider" "On" "Min. priority" "Quiet hours" "Outside" "Source" "Ready" "Carries"
    printf '%s\n' "$rows" | cut -f1-9; } | table
  if ! printf '%s\n' "$rows" | awk -F'\t' '$3 == "yes" && $6 == "outside" && ("," $9 ",") ~ /,alarm,/ { f = 1 } END { exit !f }'; then
    warn "No enabled channel outside this server carries alarms. While the storage is locked this server is down and you will not hear about it."
  fi
}

cmd_show() {   # key<TAB>value
  local k v n=$1
  chan_load "$n" || { echo "There is no channel called $n." >&2; exit 1; }
  load_fields "${CH[provider]}" || true
  printf 'name\t%s\nprovider\t%s\nenabled\t%s\nminprio\t%s\nquiet\t%s\nsource\t%s\noutside\t%s\nready\t%s\ncategories\t%s\n' \
    "$n" "${CH[provider]}" "${CH[enabled]}" "${CH[minprio]}" "${CH[quiet]}" "$(chan_source "$n")" "$(outside_of)" "$(ready_of)" "$(dash "${CH[categories]}")"
  for k in "${!FTYPE[@]}"; do echo "$k"; done | sort | while read -r k; do
    v=${CH[$k]:-}
    if [ "${FTYPE[$k]}" = secret ]; then if [ -n "$v" ]; then v=set; else v=; fi; fi
    printf '%s\t%s\n' "$k" "$(dash "$v")"
  done
}

cmd_show_people() {
  local k v
  while IFS=$'\t' read -r k v; do kv "$k" "$v"; done < <(cmd_show "$1")
}

cmd_providers() {
  local p k c
  for p in $(providers); do
    load_fields "$p" || continue
    c=$(caps_of "$p")
    for k in $(printf '%s\n' "${!FTYPE[@]}" | sort); do
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$p" "$k" "${FLABEL[$k]}" "${FTYPE[$k]}" "${FREQ[$k]}" "$(dash "${FPAT[$k]}")" "${c// /,}"
    done
  done
}

cmd_providers_people() {
  local rows
  rows=$(cmd_providers)
  [ -n "$rows" ] || { note "No providers installed."; return 0; }
  { thead "Provider" "Setting" "Meaning" "Kind" "Needed"; printf '%s\n' "$rows" | cut -f1-5; } | table
}

# opt_*: the parsed options of add and set
opt_provider="" opt_min="" opt_quiet="" opt_enabled="" opt_cats=""
opt_sets=() opt_secrets=()
parse_opts() {
  opt_provider="" opt_min="" opt_quiet="" opt_enabled="" opt_cats=""
  opt_sets=() opt_secrets=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --provider) opt_provider=${2:-}; shift 2 || usage ;;
      --categories) [ $# -ge 2 ] || usage; opt_cats=$2; shift 2 ;;
      --min-priority) opt_min=${2:-}; shift 2 || usage ;;
      --quiet) opt_quiet=${2:-}; shift 2 || usage ;;
      --enabled) opt_enabled=${2:-}; shift 2 || usage ;;
      --set) [ $# -ge 2 ] && [[ "$2" == *=* ]] || usage; opt_sets+=("$2"); shift 2 ;;
      --secret) [ $# -ge 2 ] || usage; opt_secrets+=("$2"); shift 2 ;;
      *) usage ;;
    esac
  done
  [ -z "$opt_min" ] || valid_prio "$opt_min" || fail "$(t 'Not a priority: %s (min, low, default, high or urgent)' "$opt_min")"
  case "$opt_quiet" in ""|respect|ignore) ;; *) fail "The quiet rule is respect or ignore." ;; esac
  case "$opt_enabled" in ""|yes|no) ;; *) fail "enabled is yes or no." ;; esac
  if [ -n "$opt_cats" ]; then
    [[ "$opt_cats" =~ ^(alarm|status|heartbeat|digest)(,(alarm|status|heartbeat|digest))*$ ]] \
      || fail "$(t 'Not a list of message classes: %s (from alarm, status, heartbeat, digest, comma separated)' "$opt_cats")"
  fi
}

# norm_cats <list>: in the fixed order alarm,status,heartbeat,digest, each once
norm_cats() {
  local c out=()
  for c in alarm status heartbeat digest; do case ",$1," in *",$c,"*) out+=("$c") ;; esac; done
  (IFS=,; printf '%s' "${out[*]}")
}

# apply <name> <add|set>: build the conf from the stored one and the options, check it with the provider, write it
apply() {
  local name=$1 mode=$2 k v kv val text caps c dc
  declare -A new=()
  if [ "$mode" = set ]; then
    while IFS= read -r kv || [ -n "$kv" ]; do
      case "$kv" in ""|\#*) continue ;; esac
      new[${kv%%=*}]=${kv#*=}
    done < <(chan_conf "$name")
  else
    new[provider]=$opt_provider; new[enabled]=yes; new[minprio]=min; new[quiet]=respect
  fi
  load_fields "${new[provider]:-ntfy}" || fail "$(t 'There is no provider called %s. Providers: %s' "${new[provider]:-}" "$(providers | tr '\n' ' ')")"
  [ -z "$opt_min" ] || new[minprio]=$opt_min
  [ -z "$opt_quiet" ] || new[quiet]=$opt_quiet
  [ -z "$opt_enabled" ] || new[enabled]=$opt_enabled
  caps=" $(caps_of "${new[provider]}") "
  if [ -n "$opt_cats" ]; then
    for c in ${opt_cats//,/ }; do
      case "$caps" in *" $c "*) ;; *) fail "$(t '%s cannot carry %s (it can carry:%s)' "${new[provider]}" "$c" "${caps% }") " ;; esac
    done
    new[categories]=$(norm_cats "$opt_cats")
  elif [ "$mode" = add ]; then
    # the default classes, as far as the provider can carry them
    dc=""
    for c in alarm status digest; do case "$caps" in *" $c "*) dc+="$c," ;; esac; done
    new[categories]=${dc%,}
  fi
  [ -n "${new[categories]:-}" ] || new[categories]=alarm,status,digest
  for kv in ${opt_sets[@]+"${opt_sets[@]}"}; do
    k=${kv%%=*}; v=${kv#*=}
    [ -n "${FTYPE[$k]:-}" ] || fail "$(t '%s has no setting called %s.' "${new[provider]}" "$k")"
    [ "${FTYPE[$k]}" != secret ] || fail "$(t '%s is a secret: use --secret %s (the value is read from stdin, never from the command line).' "$k" "$k")"
    new[$k]=$v
  done
  for k in ${opt_secrets[@]+"${opt_secrets[@]}"}; do
    [ "${FTYPE[$k]:-}" = secret ] || fail "$(t '%s is not a secret setting of %s.' "$k" "${new[provider]}")"
    if [ -t 0 ]; then val=$(ask_secret "$(t 'Value of %s:' "${FLABEL[$k]}")")
    else IFS= read -r val || true; fi
    [ -n "$val" ] || fail "$(t 'No value for %s on stdin.' "$k")"
    [[ "$val" != *$'\r'* ]] || val=${val//$'\r'/}
    new[$k]=$val
  done
  # the conf text: the fixed keys first, then the provider's, sorted
  text="provider=${new[provider]}"$'\n'"enabled=${new[enabled]}"$'\n'"minprio=${new[minprio]}"$'\n'"quiet=${new[quiet]}"$'\n'"categories=${new[categories]}"$'\n'
  for k in $(printf '%s\n' "${!new[@]}" | sort); do
    case "$k" in provider|enabled|minprio|quiet|categories) continue ;; esac
    [[ "$k" =~ ^[a-z][a-zA-Z0-9_]*$ ]] || continue
    text+="$k=${new[$k]}"$'\n'
  done
  chan_load_text "$name" "$text"
  for k in "${!FREQ[@]}"; do
    if [ "${FREQ[$k]}" = required ] && [ -z "${CH[$k]:-}" ]; then fail "$(t 'The setting %s is needed.' "$k")"; fi
  done
  if ! val=$(chan_run "${CH[provider]}" check 2>&1); then fail "${val:-The settings are not usable.}"; fi
  chan_migrate || fail "The channel list could not be written."
  printf '%s' "$text" | chan_write "$name" || fail "The channel could not be written."
}

cmd_add() {
  local name=${1:-}
  [ -n "$name" ] || usage
  shift
  chan_valid_name "$name" || fail "$(t 'Not a channel name: %s (lower case letters, digits and dashes)' "$name")"
  parse_opts "$@"
  [ -n "$opt_provider" ] || fail "Name the provider: --provider ntfy"
  chan_source "$name" >/dev/null 2>&1 && fail "$(t 'There is already a channel called %s.' "$name")"
  apply "$name" add
  ok "$(t 'Channel %s added' "$name")"
  note "$(t 'Try it: hs notify channel test %s' "$name")"
}

cmd_set() {
  local name=${1:-}
  [ -n "$name" ] || usage
  shift
  chan_valid_name "$name" || fail "$(t 'Not a channel name: %s (lower case letters, digits and dashes)' "$name")"
  chan_source "$name" >/dev/null 2>&1 || fail "$(t 'There is no channel called %s.' "$name")"
  parse_opts "$@"
  [ -z "$opt_provider" ] || fail "The provider of a channel cannot be changed: remove it and add a new one."
  chan_migrate || fail "The channel list could not be written."
  apply "$name" set
  ok "$(t 'Channel %s saved' "$name")"
}

cmd_remove() {
  local name=${1:-} yes=false a
  [ -n "$name" ] || usage
  shift
  for a in "$@"; do case "$a" in --yes) yes=true ;; *) usage ;; esac; done
  chan_valid_name "$name" || fail "$(t 'Not a channel name: %s (lower case letters, digits and dashes)' "$name")"
  chan_source "$name" >/dev/null 2>&1 || fail "$(t 'There is no channel called %s.' "$name")"
  if ! $yes; then
    interactive || fail "Nothing is changed without --yes when there is no terminal."
    confirm_name "$name" "the channel" || fail "cancelled"
  fi
  chan_migrate || fail "The channel list could not be written."
  chan_remove "$name"
  # the heartbeat channel stands for the setting heartbeatUrl: without clearing it the channel would be derived again
  if [ "$name" = heartbeat ]; then setting_unset heartbeatUrl; fi
  ok "$(t 'Channel %s removed' "$name")"
}

# the message is NOT translated (push messages never are); it ignores the minimum priority, the quiet hours and `enabled`
cmd_test() {
  local name=${1:-} err
  [ -n "$name" ] || usage
  chan_load "$name" || fail "$(t 'There is no channel called %s.' "$name")"
  CHAN_CATEGORY=info
  if err=$(chan_run "${CH[provider]}" send default "$(hostname 2>/dev/null || echo server): test message" "This is a test of the notification channel $name." 2>&1); then
    chan_result_set "$name" ok
    ok "$(t 'The test message was handed to channel %s' "$name")"
  else
    chan_result_set "$name" failed "${err:-no answer}"
    fail "$(t 'The test message did not arrive: %s' "${err:-no answer}")"
  fi
}

cmd_migrate() {
  if chan_migrated; then note "Already migrated: the channels are files."; return 0; fi
  chan_migrate || fail "The channel list could not be written."
  ok "The channels are files now"
  note "$(t 'Channels: %s' "$(chan_names | tr '\n' ' ')")"
}

sub=${1:-}
[ -n "$sub" ] || usage
shift
case "$sub" in
  list) cmd_list_people ;;
  --list) cmd_list ;;
  show) [ $# -eq 1 ] || usage; chan_load "$1" || fail "$(t 'There is no channel called %s.' "$1")"; cmd_show_people "$1" ;;
  --show) [ $# -eq 1 ] || usage; cmd_show "$1" ;;
  add) cmd_add "$@" ;;
  set) cmd_set "$@" ;;
  remove) cmd_remove "$@" ;;
  test) [ $# -eq 1 ] || usage; cmd_test "$1" ;;
  migrate) [ $# -eq 0 ] || usage; cmd_migrate ;;
  providers) cmd_providers_people ;;
  --providers) cmd_providers ;;
  *) usage ;;
esac
