#!/usr/bin/env bash
# help: things that run out on a date (certificate, token, domain, credentials): list, add, remove; the health check warns in time
# help.de: Dinge, die an einem Datum ablaufen (Zertifikat, Token, Domain, Zugangsdaten): anzeigen, eintragen, entfernen; der Health-Check warnt rechtzeitig
# args: [list] | add <name> <YYYY-MM-DD> [how to renew...] | remove <name> | --list
# The list lives in /var/lib/hs/expiry, one line per entry: name TAB ISO date TAB how to renew. The health check (every 15
# minutes) reports an entry 30 days before the date ("soon"), again as more urgent 7 days before ("due"), and when it has
# passed ("expired"). `add` with a name that exists changes its date. Ideas to enter: the domain controller's certificate
# (Sept 2028), the Cloudflare tunnel token, the domain registration, the credentials of the off-site backup.
# --list = name TAB date TAB days left TAB ok|soon|due|expired|invalid TAB how to renew (machine readable, used by the health check).
# HS_STATE_DIR: another state folder (tests), HS_EXPIRY_TODAY: pretend today is this date (tests).
set -uo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
file=${HS_STATE_DIR:-/var/lib/hs}/expiry
soon_days=30; due_days=7

usage() { say "usage: hs expiry list | add <name> <YYYY-MM-DD> [how to renew...] | remove <name>"; exit 1; }
day_no() {   # ISO date -> days since 1970 (fails for anything else)
  local s
  [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && s=$(date -u -d "$1" +%s 2>/dev/null) && echo $((s / 86400))
}
today() { day_no "${HS_EXPIRY_TODAY:-$(date +%F)}"; }

rows() {   # name TAB date TAB days TAB state TAB how
  local name date how t d days state
  t=$(today)
  [ -r "$file" ] || return 0
  while IFS=$'\t' read -r name date how; do
    [ -n "$name" ] && [[ "$name" != \#* ]] || continue
    if d=$(day_no "$date"); then
      days=$((d - t))
      if [ "$days" -lt 0 ]; then state=expired
      elif [ "$days" -le "$due_days" ]; then state=due
      elif [ "$days" -le "$soon_days" ]; then state=soon
      else state=ok; fi
    else days=-; state=invalid; fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$date" "$days" "$state" "$how"
  done < "$file"
}

cmd=${1:-list}
case "$cmd" in
  --list) rows ;;
  list)
    out=$(rows)
    if [ -z "$out" ]; then
      note "Nothing is entered. Add something that expires: hs expiry add <name> <YYYY-MM-DD> [how to renew]"
      exit 0
    fi
    {
      thead 'Name' 'Date' 'Days left' 'State' 'How to renew'
      while IFS=$'\t' read -r name date days state how; do
        printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$date" "$days" "$(_tr "$state")" "${how:--}"
      done <<<"$out"
    } | table
    ;;
  add)
    shift
    name=${1:-}; date=${2:-}
    if [ $# -ge 2 ]; then shift 2; else shift $#; fi
    if [ -z "$name" ] && { [ -t 0 ] || [ -n "${HS_GUIDED_TTY:-}" ]; }; then
      name=$(ask "What expires? (a short name)")
      date=$(ask "Until when? (YYYY-MM-DD)")
      set -- "$(ask "How is it renewed? (a hint for you)")"
    fi
    [ -n "$name" ] && [ -n "$date" ] || usage
    case "$name" in *$'\t'*|\#*) fail "The name must not contain a tab or start with #." ;; esac
    day_no "$date" >/dev/null || fail "$(t "'%s' is not a date. Use YYYY-MM-DD." "$date")"
    how="$*"; how=${how//$'\t'/ }
    mkdir -p "$(dirname "$file")"
    tmp=$(mktemp "$file.XXXXXX")
    { [ ! -r "$file" ] || awk -F'\t' -v n="$name" '$1 != n' "$file"; printf '%s\t%s\t%s\n' "$name" "$date" "$how"; } > "$tmp"
    chmod 644 "$tmp"; mv "$tmp" "$file"
    ok "$(t '%s expires on %s' "$name" "$date")"
    ;;
  remove)
    name=${2:-}; [ -n "$name" ] || usage
    { [ -r "$file" ] && awk -F'\t' -v n="$name" '$1 == n {f=1} END {exit !f}' "$file"; } || fail "$(t "No entry called '%s'. See: hs expiry list" "$name")"
    tmp=$(mktemp "$file.XXXXXX")
    awk -F'\t' -v n="$name" '$1 != n' "$file" > "$tmp"; chmod 644 "$tmp"; mv "$tmp" "$file"
    ok "$(t '%s removed' "$name")"
    ;;
  *) usage ;;
esac
