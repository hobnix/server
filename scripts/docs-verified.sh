#!/usr/bin/env bash
# help: show when each guide was last checked against the real server, or mark one as checked
# help.de: zeigen, wann jede Anleitung zuletzt am echten Server geprüft wurde, oder eine als geprüft eintragen
# args: [list | --summary | <guide> [YYYY-MM-DD]]
# The dates live in docs/verified.tsv (guide file name without .md, TAB, date, TAB, optional note), part of the repository, written by hand
# with this command after someone worked through the guide on the server. The built pages show the date under their title (docs-build.sh);
# the monthly restore-drill report (hs backup report) counts the guides. A date is never made up: no row = "never checked".
# HS_REPO, HS_DOCS_VERIFIED: tests and stand-ins.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=${HS_REPO:-$(dirname "$here")}
[ -d "$repo/docs" ] || repo=/etc/nixos     # the scripts run from the Nix store on the server, which has no docs/
. "$here/lib/ui.sh"
file=${HS_DOCS_VERIFIED:-$repo/docs/verified.tsv}

usage() {
  say "usage: hs docs verified                      every guide with the date it was last checked on the server"
  say "       hs docs verified <guide> [YYYY-MM-DD] mark a guide as checked (today, or the given day)"
  exit 1
}

# the German guides: the files of docs/ that are not design documents or plans (the same rule as docs-build.sh)
guides() {
  local f b
  for f in "$repo"/docs/*.md; do
    [ -e "$f" ] || continue
    b=$(basename "$f" .md)
    case "$b" in README|CLI-DESIGN|COMMANDS-DESIGN|Entwicklungsnotizen|PLAN-*) continue ;; esac
    printf '%s\n' "$b"
  done | sort
}
date_of() {   # date_of <guide>: the date, empty for none
  [ -f "$file" ] || return 0
  awk -F'\t' -v g="$1" '$0 !~ /^#/ && $1 == g { print $2; exit }' "$file"
}
age_days() {   # age_days <YYYY-MM-DD>
  local then now
  then=$(date -d "$1" +%s 2>/dev/null) || return 1
  now=$(date +%s)
  echo $(( (now - then) / 86400 ))
}

cmd_list() {
  local g d a
  { thead 'Guide' 'Last checked' 'Age'
    while IFS= read -r g; do
      d=$(date_of "$g")
      if [ -n "$d" ]; then a=$(age_days "$d" || echo '?'); printf '%s\t%s\t%s\n' "$g" "$d" "$(t '%s days' "$a")"
      else printf '%s\t%s\t%s\n' "$g" "$(t 'never')" '-'; fi
    done < <(guides); } | table
}

# key=value lines, plain: verified (guides with a date), total, oldest (the oldest date, empty for none), stale (checked more than 365 days ago)
cmd_summary() {
  local g d total=0 ver=0 old="" stale=0 a
  while IFS= read -r g; do
    total=$((total + 1))
    d=$(date_of "$g")
    [ -n "$d" ] || continue
    ver=$((ver + 1))
    if [ -z "$old" ] || [[ "$d" < "$old" ]]; then old=$d; fi
    a=$(age_days "$d" || echo 0)
    [ "$a" -le 365 ] || stale=$((stale + 1))
  done < <(guides)
  printf 'verified=%s\ntotal=%s\noldest=%s\nstale=%s\n' "$ver" "$total" "$old" "$stale"
}

cmd_set() {   # cmd_set <guide> [date]
  local want=$1 day=${2:-$(date +%F)} g found="" tmp
  [[ "$day" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && date -d "$day" +%F >/dev/null 2>&1 || fail "$(t 'Not a date (YYYY-MM-DD): %s' "$day")"
  [[ ! "$day" > "$(date +%F)" ]] || fail "$(t 'That day is still to come: %s' "$day")"
  while IFS= read -r g; do
    if [ "$g" = "$want" ] || [ "$g" = "${want%.md}" ]; then found=$g; break; fi
  done < <(guides)
  if [ -z "$found" ]; then
    # a unique part of the name is enough
    local hits
    hits=$(guides | awk -v w="$want" 'index(tolower($0), tolower(w)) { print }')
    [ -n "$hits" ] && [ "$(printf '%s\n' "$hits" | wc -l | tr -d ' ')" = 1 ] || fail "$(t 'No single guide matches "%s" (see: hs docs verified)' "$want")"
    found=$hits
  fi
  tmp=$file.new
  { [ ! -f "$file" ] || awk -F'\t' -v g="$found" '$0 ~ /^#/ || $1 != g' "$file"
    printf '%s\t%s\n' "$found" "$day"; } > "$tmp"
  # comments first, then the rows in order
  { grep '^#' "$tmp" || true; grep -v '^#' "$tmp" | sort -t$'\t' -k1,1; } > "$file"
  rm -f "$tmp"
  ok "$(t '%s: checked on %s' "$found" "$day")"
  note "$(t 'The file is part of the repository (docs/verified.tsv): commit it, and hs docs build shows the date')"
}

case "${1:-list}" in
  list) cmd_list ;;
  --summary) cmd_summary ;;
  -h|--help) usage ;;
  *) [ $# -le 2 ] || usage; cmd_set "$@" ;;
esac
