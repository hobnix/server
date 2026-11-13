#!/usr/bin/env bash
# Dev tool (not an `hs` command): read and move issues of the GitHub project board (hobnix/server, project 1).
#   board.sh open [N]      up to N (default 4) open issues of the current milestone: "#<n> [<status>] <title>"
#   board.sh show <n>      title, labels and body of an issue
#   board.sh move <n> <backlog|ready|in-progress|in-review|blocked|done>   set the board Status
# `open` is quiet (exit 0, no output) when gh is missing, not logged in, offline or slower than 5 s: it runs in the session hook.
REPO=hobnix/server
PROJECT_ID=PVT_kwDOFNAdbs4Bp-c9
STATUS_FIELD=PVTSSF_lADOFNAdbs4Bp-c9zhoXlec

cmd_open() {
  local n="${1:-4}" ms st
  command -v gh >/dev/null 2>&1 || return 0
  ms=$(timeout 5 gh api "repos/$REPO/milestones?state=open" --jq '
    map({t: .title, v: (.title | split(" ")[0] | [scan("[0-9]+") | tonumber])})
    | map(select(.v | length > 0)) | sort_by(.v) | .[0].t // empty' 2>/dev/null) || return 0
  [ -n "$ms" ] || return 0
  st=$(timeout 5 gh project item-list 1 --owner hobnix --limit 500 --format json \
    --jq '.items[] | "\(.content.number)|\(.status // "-")"' 2>/dev/null) || st=""
  timeout 5 gh issue list --repo "$REPO" --milestone "$ms" --state open --limit 100 \
    --json number,title --jq 'sort_by(.number)[] | "\(.number)|\(.title)"' 2>/dev/null \
    | awk -F'|' -v n="$n" -v st="$st" '
        BEGIN { c = split(st, l, "\n"); for (i = 1; i <= c; i++) { split(l[i], f, "|"); s[f[1]] = f[2] } }
        NR <= n { t = substr($0, length($1) + 2); printf "#%s [%s] %s\n", $1, ($1 in s ? s[$1] : "-"), substr(t, 1, 90) }'
  return 0
}

cmd_show() {
  [ -n "${1:-}" ] || { echo "usage: board.sh show <n>" >&2; return 2; }
  gh issue view "$1" --repo "$REPO" || { echo "board.sh: cannot read issue #$1" >&2; return 1; }
}

cmd_move() {
  local n="${1:-}" want="${2:-}" opt id
  case "$want" in
    backlog) opt=d073b39b ;;
    ready) opt=0747646d ;;
    in-progress) opt=7ebbdff7 ;;
    in-review) opt=4e0504f7 ;;
    blocked) opt=68455b7f ;;
    done) opt=81ffda49 ;;
    *) echo "usage: board.sh move <n> <backlog|ready|in-progress|in-review|blocked|done>" >&2; return 2 ;;
  esac
  [ -n "$n" ] || { echo "usage: board.sh move <n> <status>" >&2; return 2; }
  id=$(gh project item-list 1 --owner hobnix --limit 500 --format json -q ".items[]|select(.content.number==$n)|.id") \
    || { echo "board.sh: cannot read the board" >&2; return 1; }
  [ -n "$id" ] || { echo "board.sh: issue #$n is not on the board" >&2; return 1; }
  gh project item-edit --id "$id" --project-id "$PROJECT_ID" --field-id "$STATUS_FIELD" --single-select-option-id "$opt" >/dev/null \
    || { echo "board.sh: could not set the status of #$n" >&2; return 1; }
  echo "#$n -> $want"
}

case "${1:-}" in
  open) shift; cmd_open "$@" ;;
  show) shift; cmd_show "$@" ;;
  move) shift; cmd_move "$@" ;;
  *) echo "usage: board.sh open [N] | show <n> | move <n> <status>" >&2; exit 2 ;;
esac
