#!/usr/bin/env bash
# help: change the notification channels without asking anything: what would happen (plan), then do it (start)
# help.de: die Benachrichtigungskanäle ändern, ohne etwas zu fragen: was passieren würde (plan), dann ausführen (start)
# args: plan|start add <name> --provider <p> [options] | set <name> [options] | remove <name> [--confirm <name>] | test <name> | migrate
# System command (hs sys notify plan|start): for the web interface and tests. It never asks and prints plain key<TAB>value lines like
# expiry-change.sh. The work is notify-channel.sh's; this script checks the input against the provider's fields and says what would happen.
# Options of add and set: --provider <p> (add), --min-priority P, --quiet respect|ignore, --enabled yes|no, --categories a,b,
# --set key=value (a text setting, may repeat), --secret key (ONE secret setting; its value is the first line of stdin, never an argument).
# plan: exit 0 = allowed, 1 = refused, 2 = something is missing (status needs, needs<TAB>what). Output: status ok|refused|needs,
#   reason<TAB><text>, heading|step|note|warn|danger|command<TAB><line>, confirm_name<TAB><name> (remove: red, the name of the channel is typed),
#   long<TAB>no. A secret is never printed.
# start: the same checks, then status<TAB>done (or refused with the reason). test: done when the channel took the message.
# Test knobs: HS_NOTIFY_CHANNEL (stand-in for notify-channel.sh), HS_NOTIFY_PROVIDERS.
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/channels.sh"
channel=${HS_NOTIFY_CHANNEL:-$here/notify-channel.sh}

refuse() { printf 'status\trefused\nreason\t%s\n' "$1"; exit 1; }
needs() { printf 'status\tneeds\nneeds\t%s\n' "$1"; exit 2; }

verb=${1:-}; action=${2:-}; name=${3:-}
case "$verb" in plan|start) ;; *) echo "usage: notify-change.sh plan|start add|set|remove|test <name> ... | migrate" >&2; exit 1 ;; esac
case "$action" in
  add|set|remove|test) [ -n "$name" ] || refuse "a channel name is needed"; shift 3 ;;
  migrate) shift 2 ;;
  *) refuse "unknown action (add, set, remove, test or migrate)" ;;
esac
if [ "$action" != migrate ]; then
  [[ "$name" =~ ^[a-z][a-z0-9-]{0,30}$ ]] || refuse "invalid name (lower case letters, digits and dashes, at most 31)"
fi

provider="" minp="" quiet="" enabled="" cats="" confirm=""
sets=() secrets=()
while [ $# -gt 0 ]; do
  case "$1" in
    --provider)     [ "$action" = add ] || refuse "the provider of a channel cannot be changed"; provider=${2:-}; shift 2 || refuse "--provider needs a value" ;;
    --min-priority) minp=${2:-}; shift 2 || refuse "--min-priority needs a value" ;;
    --quiet)        quiet=${2:-}; shift 2 || refuse "--quiet needs a value" ;;
    --enabled)      enabled=${2:-}; shift 2 || refuse "--enabled needs a value" ;;
    --categories)   cats=${2:-}; shift 2 || refuse "--categories needs a value" ;;
    --set)          [[ "${2:-}" == *=* ]] || refuse "--set needs key=value"; sets+=("$2"); shift 2 ;;
    --secret)       [ -n "${2:-}" ] || refuse "--secret needs a setting name"; secrets+=("$2"); shift 2 ;;
    --confirm)      confirm=${2:-}; shift 2 || refuse "--confirm needs a value" ;;
    *) refuse "unknown option $1" ;;
  esac
done
case "$action" in add|set) ;; *) [ ${#sets[@]} -eq 0 ] && [ ${#secrets[@]} -eq 0 ] && [ -z "$minp$quiet$enabled$cats$provider" ] || refuse "this action takes no options" ;; esac
[ ${#secrets[@]} -le 1 ] || refuse "one secret at a time"
case "$minp" in ""|min|low|default|high|urgent) ;; *) refuse "the minimum priority is min, low, default, high or urgent" ;; esac
case "$quiet" in ""|respect|ignore) ;; *) refuse "the quiet rule is respect or ignore" ;; esac
case "$enabled" in ""|yes|no) ;; *) refuse "enabled is yes or no" ;; esac
[ -z "$cats" ] || [[ "$cats" =~ ^(alarm|status|heartbeat|digest)(,(alarm|status|heartbeat|digest))*$ ]] || refuse "the message classes are alarm, status, heartbeat and digest"

# does the channel exist (a derived one counts)?
exists=false
if bash "$channel" --show "$name" >/dev/null 2>&1; then exists=true; fi

# the secret is the first line of stdin (a plan gets it too, to know it is there); it never leaves this variable
secret=""
if [ ${#secrets[@]} -gt 0 ]; then
  IFS= read -r secret || true
  secret=${secret//$'\r'/}
fi

# the provider's fields: key, kind, required|optional, pattern; caps
declare -A FKIND=() FREQ=() FPAT=() FLABEL=()
caps=""
load_provider() {
  local p k l t r pat c
  while IFS=$'\t' read -r p k l t r pat c; do
    [ "$p" = "$1" ] || continue
    FKIND[$k]=$t; FREQ[$k]=$r; FPAT[$k]=$pat; FLABEL[$k]=$l; caps=$c
  done < <(bash "$channel" --providers 2>/dev/null)
  [ -n "$caps" ]
}

case "$action" in
  add)
    [ -n "$provider" ] || needs "provider"
    $exists && refuse "There is already a channel called $name."
    ;;
  set|remove|test)
    $exists || refuse "There is no channel called $name."
    provider=$(bash "$channel" --show "$name" 2>/dev/null | awk -F'\t' '$1 == "provider" { print $2 }')
    ;;
esac

declare -A val=()
if [ "$action" = add ] || [ "$action" = set ]; then
  load_provider "$provider" || refuse "There is no provider called $provider."
  for kv in ${sets[@]+"${sets[@]}"}; do
    k=${kv%%=*}; v=${kv#*=}
    [ "${FKIND[$k]:-}" = text ] || refuse "$provider has no text setting called $k (a secret goes in with --secret)."
    [[ "$v" != *$'\n'* && "$v" != *$'\t'* ]] || refuse "the value of $k is one line without a tab"
    val[$k]=$v
  done
  for k in ${secrets[@]+"${secrets[@]}"}; do
    [ "${FKIND[$k]:-}" = secret ] || refuse "$k is not a secret setting of $provider."
    [ -n "$secret" ] || needs "${FLABEL[$k]}"
    val[$k]=$secret
  done
  for k in "${!val[@]}"; do
    pat=${FPAT[$k]:--}
    if [ "$pat" != - ] && [ -n "${val[$k]}" ] && ! [[ "${val[$k]}" =~ $pat ]]; then refuse "the value of ${FLABEL[$k]} does not look right"; fi
  done
  if [ -n "$cats" ]; then
    for c in ${cats//,/ }; do
      case ",${caps}," in *",$c,"*) ;; *) refuse "$provider cannot carry $c (it can carry: ${caps//,/, })." ;; esac
    done
  fi
  if [ "$action" = add ]; then
    for k in "${!FREQ[@]}"; do
      [ "${FREQ[$k]}" = required ] || continue
      [ -n "${val[$k]:-}" ] || needs "${FLABEL[$k]}"
    done
    # the provider's own check with the values given so far (a text it refuses, e.g. a host that is no host)
    envs=()
    for k in "${!val[@]}"; do envs+=("CH_$k=${val[$k]}"); done
    if ! err=$(env ${envs[@]+"${envs[@]}"} bash "$(chan_providers_dir)/$provider.sh" check 2>&1 >/dev/null); then
      refuse "${err:-The settings are not usable.}"
    fi
  fi
fi

# the command as it is shown: never the secret
cmd=(hs notify channel "$action")
[ "$action" = migrate ] || cmd+=("$name")
[ -z "$provider" ] || [ "$action" != add ] || cmd+=(--provider "$provider")
[ -z "$minp" ] || cmd+=(--min-priority "$minp")
[ -z "$quiet" ] || cmd+=(--quiet "$quiet")
[ -z "$enabled" ] || cmd+=(--enabled "$enabled")
[ -z "$cats" ] || cmd+=(--categories "$cats")
for kv in ${sets[@]+"${sets[@]}"}; do cmd+=(--set "$kv"); done
for k in ${secrets[@]+"${secrets[@]}"}; do cmd+=(--secret "$k"); done
[ "$action" != remove ] || cmd+=(--yes)

if [ "$verb" = start ]; then
  if [ "$action" = remove ] && [ "$confirm" != "$name" ]; then refuse "type the name of the channel to confirm: $name"; fi
  run=(bash "$channel" "$action")
  [ "$action" = migrate ] || run+=("$name")
  [ -z "$provider" ] || [ "$action" != add ] || run+=(--provider "$provider")
  [ -z "$minp" ] || run+=(--min-priority "$minp")
  [ -z "$quiet" ] || run+=(--quiet "$quiet")
  [ -z "$enabled" ] || run+=(--enabled "$enabled")
  [ -z "$cats" ] || run+=(--categories "$cats")
  for kv in ${sets[@]+"${sets[@]}"}; do run+=(--set "$kv"); done
  for k in ${secrets[@]+"${secrets[@]}"}; do run+=(--secret "$k"); done
  [ "$action" != remove ] || run+=(--yes)
  rc=0
  if [ -n "$secret" ]; then out=$(printf '%s\n' "$secret" | HS_CALLER=ui "${run[@]}" 2>&1) || rc=$?
  else out=$(HS_CALLER=ui "${run[@]}" </dev/null 2>&1) || rc=$?; fi
  if [ "$rc" -ne 0 ]; then
    printf 'status\trefused\nreason\t%s\n' "$(printf '%s' "$out" | sed -e 's/^[[:space:]]*//' -e 's/^[✗!] *//' | awk 'NF' | tail -n 1)"
    exit 1
  fi
  printf 'status\tdone\n'
  exit 0
fi

printf 'status\tok\n'
case "$action" in
  add)
    printf 'heading\tadd the channel %s (%s)\n' "$name" "$provider"
    printf 'step\tsave the settings of %s (the secret stays on the server and is never shown again)\n' "$name"
    printf 'step\tit carries: %s\n' "${cats:-alarm, status, digest (the default)}"
    printf 'note\tTry it afterwards with the Test button.\n' ;;
  set)
    printf 'heading\tchange the channel %s\n' "$name"
    [ -z "$enabled" ] || printf 'step\tswitch it %s\n' "$([ "$enabled" = yes ] && echo on || echo off)"
    [ -z "$minp" ] || printf 'step\tthe lowest priority it gets: %s\n' "$minp"
    [ -z "$quiet" ] || printf 'step\tquiet hours: %s\n' "$quiet"
    [ -z "$cats" ] || printf 'step\tit carries: %s\n' "$cats"
    [ ${#sets[@]} -eq 0 ] && [ ${#secrets[@]} -eq 0 ] || printf 'step\tnew settings: %s\n' "$(for kv in ${sets[@]+"${sets[@]}"}; do printf '%s ' "${kv%%=*}"; done; for k in ${secrets[@]+"${secrets[@]}"}; do printf '%s (secret) ' "$k"; done)" ;;
  remove)
    printf 'heading\tremove the channel %s\n' "$name"
    printf 'step\tdelete its settings, the secret with them\n'
    printf 'danger\tYou stop hearing from this server through %s. Adding it again needs the secret again.\n' "$name"
    printf 'confirm_name\t%s\n' "$name" ;;
  test)
    printf 'heading\tsend a test message to %s\n' "$name"
    printf 'step\thand one message to the channel, whatever its minimum priority, classes and the quiet hours\n' ;;
  migrate)
    printf 'heading\twrite the channels as files\n'
    printf 'step\tturn the channels derived from the old settings into files (nothing is lost)\n' ;;
esac
printf 'command\t%s\n' "${cmd[*]}"
printf 'long\tno\n'
