#!/usr/bin/env bash
# help: send a push message to the address in machine.toml (notifyUrl); always written to the journal
# help.de: schickt eine Nachricht aufs Handy an die Adresse aus machine.toml (notifyUrl); steht immer auch im Journal
# args: [--dry-run] [--flush] [--category <name>] <title> <message> [priority]
set -euo pipefail
. "$(dirname "$0")/lib/i18n.sh"
. "$(dirname "$0")/lib/ntfy.sh"
. "$(dirname "$0")/lib/setting.sh"
. "$(dirname "$0")/lib/notify-route.sh"
. "$(dirname "$0")/lib/channels.sh"
# the channel files are root only (0600): a caller that cannot read them goes through sudo
chan_need_root "$0" "$@"

usage() {
  say "usage: hs notify [--dry-run] [--category <name>] <title> <message> [priority]"
  say "  priority   min, low, default, high or urgent (default: the category's)"
  say "  category   alarm, lock, problem, ok, start, stop, info or heartbeat: sets the icon (default: from the priority)"
  say "  --dry-run  only print what would be sent"
  say "  --flush    send what the quiet hours held back (no title or message)"
  exit 1
}

dry=false
flush=false
category=""
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=true; shift ;;
    --flush) flush=true; shift ;;
    --category) [ $# -ge 2 ] || usage; category=$2; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
if $flush; then [ ${#args[@]} -eq 0 ] || usage; args=(flush flush); fi
[ ${#args[@]} -ge 2 ] && [ ${#args[@]} -le 3 ] || usage
title=${args[0]}
message=${args[1]}
priority=${args[2]:-}
[ -n "$category" ] || category=$(ntfy_category_for "${priority:-default}")
ntfy_category "$category"
priority=${priority:-$NTFY_PRIO}

# The channels (scripts/lib/channels.sh): files in /var/lib/hs/notify-channels, or, until the first change,
# `main` and `second` derived from the old settings notifyUrl, notifyUrlSecond and notifySecondMinPriority (an address written by
# `hs recipe ntfy` to /var/lib/hs/notify-url still wins over machine.toml). Each channel has a provider (scripts/notify/<provider>.sh).

# Quiet hours (setting quietHours): below high a message waits for the end of the window; high and urgent go at once.
quiet=false
route_quiet_now && quiet=true
hold=false
class=$(chan_class "$category")   # alarm | status | heartbeat: the channels that carry it
# the heartbeat is never held and bypasses the quiet hours, the minimum priority and the digest
if $quiet && [ "$(route_rank "$priority")" -lt 4 ] && [ "$class" != heartbeat ]; then hold=true; fi

# wanted_channels <priority> <mode> <class>: the names of the enabled channels that carry the message class, want a message of this
# priority and have the quiet rule <mode> (respect|ignore, or all). A disabled channel stays silent, whatever the priority; urgent passes
# every minimum; the heartbeat ignores the minimum.
wanted_channels() {
  local n
  for n in $(chan_names); do
    chan_load "$n" || continue
    [ "${CH[enabled]}" = yes ] || continue
    chan_carries "$3" || continue
    [ "$2" = all ] || [ "${CH[quiet]}" = "$2" ] || continue
    if [ "$3" != heartbeat ] && [ "$1" != urgent ]; then
      [ "$(route_rank "$1")" -ge "$(route_rank "${CH[minprio]}")" ] || continue
    fi
    echo "$n"
  done
}

if $dry; then
  if $flush; then
    printf 'held: %s message(s)
' "$(route_held_count)"
    exit 0
  fi
  # a held message still goes at once to the channels that ignore the quiet hours
  if $hold; then mode=ignore; else mode=all; fi
  mapfile -t going < <(wanted_channels "$priority" "$mode" "$class")
  if [ -z "$(chan_names)" ]; then say "No notifyUrl set, would only write to the journal:"
  elif [ ${#going[@]} -eq 0 ]; then say "Would send to no channel:"
  else printf '%s
' "$(t 'Would send to %s:' "${going[0]}")"; fi
  printf '  %-10s%s
' "$(_tr 'title:')" "$title"
  printf '  %-10s%s
' "$(_tr 'priority:')" "$priority"
  printf '  %-10s%s
' "$(_tr 'category:')" "$category ($NTFY_ICON)"
  # the routing lines are plain on purpose: they are for the machine, not a translated sentence
  if $hold; then echo "  route:    held until the quiet hours end"; fi
  for ((i = 1; i < ${#going[@]}; i++)); do echo "  also to:  ${going[$i]}"; done
  ntfy_body "$message" "$category" | sed 's/^/  /'
  exit 0
fi

# deliver <title> <message> <category> <priority> [respect|ignore|all] [class]: the channels in turn (all, or only those with that quiet
# rule) that carry the class (default: the class of the category); a failure of one never stops the others. Succeeds when no channel
# wanted the message or at least one took it.
deliver() {
  local n err attempted=0 got=false told=()
  CHAN_CATEGORY=$3
  for n in $(wanted_channels "$4" "${5:-all}" "${6:-$(chan_class "$3")}"); do
    chan_load "$n" || continue
    attempted=$((attempted + 1))
    # the provider's own error (e.g. "429 Too Many Requests") goes to the journal, not to the terminal of `hs update`
    if err=$(chan_run "${CH[provider]}" send "$4" "$1" "$2" 2>&1); then got=true; told+=("$n"); chan_result_set "$n" ok
    else chan_result_set "$n" failed "${err:-no answer}"
      logger -t hs-notify -- "could not send '$1' to channel $n: ${err//$'
'/ }" 2>/dev/null || true; fi
  done
  # HS_NOTIFY_KEYS (set by the health check): the problems this message is about; who took it is kept per problem
  [ -z "${HS_NOTIFY_KEYS:-}" ] || [ ${#told[@]} -eq 0 ] || chan_told_set "$HS_NOTIFY_KEYS" "${told[*]}"
  $got || [ "$attempted" -eq 0 ]
}

# What the quiet hours held back goes out first, as ONE message, as soon as the window is over.
flush_held() {
  local text t b
  [ "$(route_held_count)" -gt 0 ] || return 0
  text=$(route_flush_text)
  t=${text%%$'\t'*}; b=${text#*$'\t'}
  logger -t hs-notify -- "[default] $t" 2>/dev/null || true
  if deliver "$(hostname): $t" "$b" info default respect digest; then route_held_clear; fi
}

if $flush; then
  $quiet || flush_held
  exit 0
fi

# The journal keeps every message, also without notifyUrl and also while it is held: journalctl -t hs-notify
plain=${message//\`/}; plain=${plain//\*\*/}   # the journal gets no markdown
[ "$class" = heartbeat ] || logger -t hs-notify -- "[$priority] $title: ${plain//$'\n'/; }" 2>/dev/null || true

if [ "$class" = heartbeat ]; then
  # every 15 minutes, not held, not in the journal; the channels that carry it get it at once
  deliver "$title" "$message" "$category" "$priority" all heartbeat || { [ -z "${HS_NOTIFY_STRICT:-}" ] || exit 1; }
  exit 0
fi
if $hold; then
  route_hold "$title" "$message" "$priority" "$category" || true
  deliver "$title" "$message" "$category" "$priority" ignore || true   # channels that ignore the quiet hours get it now
  exit 0
fi
$quiet || flush_held
# Callers are jobs that already have a problem; a message that can't be delivered (no internet, service down) must
# not make them fail as well. HS_NOTIFY_STRICT=1: the caller wants to know (hs-unlock-alarm retries until the network is up)
if ! deliver "$title" "$message" "$category" "$priority"; then
  [ -z "${HS_NOTIFY_STRICT:-}" ] || exit 1
fi
