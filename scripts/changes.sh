#!/usr/bin/env bash
# help: what changed in Hobnix since the last update (--since <YYYY-MM-DD>, --all)
# help.de: was sich an Hobnix seit dem letzten Update geändert hat (--since <JJJJ-MM-TT>, --all)
# args: [--since <YYYY-MM-DD> | --all | --from <rev>] [--list | --count]
# The changelog is one TOML file per change in docs/changelog (format: scripts/lib/changelog.py). "New" is measured in Git revisions of the
# checkout: by default the entries added between the revision before the last update (stamp key prev) and the running revision (stamp key
# rev, HEAD if that is unknown; after a rolled-back update the checkout is ahead of what runs). Without a usable
# base (no prev in the stamp, unknown revision, no .git) the 10 newest entries are shown.
# --list = machine readable, tab separated, an empty field is -. First one line: range TAB base TAB head TAB mode (update|from|since|all|newest;
#   base is the revision, the date or -, head is - without .git), then entry lines, newest first (date, then id, descending):
#   entry TAB id TAB date TAB type TAB title TAB docs|- TAB body|-   (body on one line: each newline becomes the two characters \n)
# --count = one number: how many entry lines the same selection gives.
# HS_REPO: another checkout (tests), HS_STATE_DIR: another state folder (tests), HS_CHANGELOG_DIR: another changelog folder (tests).
set -uo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
. "$here/lib/stamp.sh"
repo=${HS_REPO:-/etc/nixos}
g() { git -c safe.directory="$repo" -C "$repo" "$@"; }
cl() { python3 -I "$here/lib/changelog.py" "$@"; }

usage() { say "usage: hs changes [--since <YYYY-MM-DD> | --all]"; exit 1; }

since=""; from=""; all=0; mode_out=human
while [ $# -gt 0 ]; do
  case "$1" in
    --since)
      [ $# -ge 2 ] || usage
      [[ "$2" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && date -d "$2" +%F >/dev/null 2>&1 || fail "$(t "'%s' is not a date. Use YYYY-MM-DD." "$2")"
      since=$2; shift 2 ;;
    --from)
      [ $# -ge 2 ] || usage
      [[ "$2" =~ ^[0-9a-f]{7,40}$ ]] || fail "$(t "'%s' is not a revision." "$2")"
      from=$2; shift 2 ;;
    --all) all=1; shift ;;
    --list) mode_out=list; shift ;;
    --count) mode_out=count; shift ;;
    *) usage ;;
  esac
done

head=$(g rev-parse HEAD 2>/dev/null) || head=""
[ -n "$head" ] || head=-
base=-; mode=update; out=""
if [ -n "$since" ]; then
  mode=since; base=$since
  out=$(cl rows "$repo" --since "$since")
elif [ "$all" = 1 ]; then
  mode=all
  out=$(cl rows "$repo")
else
  if [ -n "$from" ]; then mode=from; cand=$from; else cand=$(stamp_get prev); fi
  # the end is the revision the stamp says is running: after a rolled-back update the checkout is ahead of it
  run=$(stamp_get rev)
  if [ -n "$run" ] && [ "$run" != "$head" ] && [ "$head" != - ] && g cat-file -e "$run^{commit}" 2>/dev/null; then head=$run; fi
  if [ "$head" != - ] && [ -n "$cand" ] && g cat-file -e "$cand^{commit}" 2>/dev/null; then
    base=$cand
    out=$(g diff --name-only --diff-filter=A "$base" "$head" -- docs/changelog 2>/dev/null | cl rows "$repo" --files)
  else
    mode=newest
    out=$(cl rows "$repo" --limit 10)
  fi
fi

n=0
[ -z "$out" ] || n=$(grep -c '^entry' <<<"$out" || true)

case "$mode_out" in
  list)
    printf 'range\t%s\t%s\t%s\n' "$base" "$head" "$mode"
    [ -z "$out" ] || printf '%s\n' "$out"
    exit 0 ;;
  count)
    printf '%s\n' "$n"
    exit 0 ;;
esac

if [ "$n" -eq 0 ]; then
  case "$mode" in
    update|from) ok "$(t 'Nothing new since the last update.')" ;;
    *) ok "$(t 'No changes in that range.')" ;;
  esac
  exit 0
fi
case "$mode" in
  newest) note "$(t 'No earlier update recorded: the %s newest changes.' "$n")" ;;
  update) line "$(t 'Changes since the last update (%s):' "${base:0:7}")" ;;
esac
{
  thead 'Date' 'Type' 'Change' 'Guide'
  while IFS=$'\t' read -r _ _ d ty ti dc _; do printf '%s\t%s\t%s\t%s\n' "$d" "$ty" "$ti" "$dc"; done <<<"$out"
} | table
note "$(t 'More: hs changes --all, or the What is new page in the web interface.')"
exit 0
