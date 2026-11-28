#!/usr/bin/env bash
# Dev tool (not an `hs` command): the hardware-test trackers of the GitHub project (hobnix/core).
# Development and hardware testing are tracked apart: a dev issue closes when its pull request is merged (milestone progress = built);
# what still has to run on a real server is a line in ONE tracker issue per milestone, "Hardware test: <milestone title>" (label
# hardware-test, no milestone, board column Testing while a box is open). Nothing here blocks a release: a line that is not ticked
# is postponed and moves on with the next release, listed in the release notes as not verified.
#   hwtest.sh add <issue> [step ...]   put the closed/merged issue into its milestone's tracker (created on first use), one box per step
#   hwtest.sh tick <issue> [note]      tick the issue's line and steps; comment what was seen; the tracker closes when no box is left
#   hwtest.sh tick <issue> --box <k> [note]
#                                      tick only step k (1 = the first step of that issue); the issue's line is ticked with its last step
#   hwtest.sh list [milestone-text] [--lab|--metal]
#                                      per tracker the counts and the open boxes (the queue for the next session at the server); with
#                                      --lab or --metal only the open boxes of that kind, each under its issue line
#   hwtest.sh migrate [--apply]        one-time: issues in the board column Testing become tracker lines and close (dry run by default)
# Marks: a step starts with [metal] (real hardware), [lab] or [lab:<stage>] (a test-lab stage, [a-z0-9-]+); no mark counts as metal.
# A mark says where a step can run. Whatever the mark, only a run that a person saw ticks a box.
# A box that can be run is a step, or an issue line without steps.
# Needs gh (logged in) and bash with awk. Output is plain text; this is a dev tool, not part of the hs interface.
# Every call goes through the REST API (gh api), never GraphQL: GraphQL has one hourly budget shared with every tool and agent, and it ran
# dry in the middle of the first migration (2026-11-20). The board is written by board.sh (REST as well).
REPO=hobnix/core
LABEL=hardware-test
here=$(cd "$(dirname "$0")" && pwd)

die() { echo "hwtest.sh: $*" >&2; exit 1; }
usage() {
  echo "usage: hwtest.sh add <issue> [step ...] | tick <issue> [--box <k>] [note] | list [milestone] [--lab|--metal] | migrate [--apply]" >&2
  exit 2
}
command -v gh >/dev/null 2>&1 || die "gh is missing"

issue_field() { gh api "repos/$REPO/issues/$1" --jq "$2" 2>/dev/null | tr -d '\r'; }                  # issue number, jq expression
issue_set_body() { gh api -X PATCH "repos/$REPO/issues/$1" -f body="$(cat "$2")" --silent; }          # issue number, body file
issue_comment() { gh api -X POST "repos/$REPO/issues/$1/comments" -f body="$2" --silent; }
issue_close() { gh api -X PATCH "repos/$REPO/issues/$1" -f state=closed -f state_reason=completed --silent; }

ensure_label() {
  gh api "repos/$REPO/labels/$LABEL" --silent 2>/dev/null ||
    gh api -X POST "repos/$REPO/labels" -f name="$LABEL" -f color=0E8A16 -f description="Tracker of the steps to run on a real server" --silent ||
    die "cannot create the label $LABEL"
}

# milestone title of an issue (empty when none)
milestone_of() { issue_field "$1" '.milestone.title // empty'; }

# open trackers as "number<TAB>title"
trackers() { gh api "repos/$REPO/issues?labels=$LABEL&state=open&per_page=100" --jq '.[] | "\(.number)\t\(.title)"' | tr -d '\r'; }

# number of the open tracker for a milestone title (empty when none)
tracker_of() { trackers | awk -F'\t' -v t="Hardware test: $1" '$2 == t { print $1; exit }'; }

intro() {
  printf '%s\n' "One box per merged change that still has to run on a real server, grouped by issue. Tick a box only for a run somebody saw, and say"
  printf '%s\n' "what was seen in a comment. A box that is not ticked is postponed: it carries over, it never blocks a release. Maintained with"
  printf '%s\n' "\`bash scripts/dev/hwtest.sh\` (add, tick, list); see docs/dev-environment.md, Branches and releases, item 7."
  printf '\n'
}

# Create a tracker for a milestone title; prints its number and puts it on the board in Testing (board.sh adds an issue that is not there).
make_tracker() {
  local ms="$1" n
  ensure_label
  n=$(gh api -X POST "repos/$REPO/issues" -f title="Hardware test: $ms" -f "labels[]=$LABEL" -f body="$(intro)" --jq .number | tr -d '\r') ||
    die "cannot create the tracker"
  bash "$here/board.sh" move "$n" testing >/dev/null 2>&1 || echo "hwtest.sh: could not set #$n to Testing on the board" >&2
  echo "$n"
}

# Add "- [ ] #N title" with sub-boxes to a body held in $1 (a file); idempotent per issue.
add_to_body() {
  local file="$1" n="$2" title="$3"; shift 3
  if grep -q "^- \[[ xX]\] #$n " "$file"; then
    echo "hwtest.sh: #$n is in the tracker already" >&2
    return 0
  fi
  { printf -- '- [ ] #%s %s\n' "$n" "$title"
    for s in "$@"; do printf -- '  - [ ] %s\n' "$s"; done; } >> "$file"
}

# mark of a step text: "metal", "lab" or "lab:<stage>" (empty when it has none)
mark_of() {
  local LC_ALL=C re='^\[(metal|lab|lab:[a-z0-9-]+)\]( |$)'
  if [[ $1 =~ $re ]]; then echo "${BASH_REMATCH[1]}"; fi
}

# Refuse a step that looks as if it was meant to carry a mark but has none of the valid ones: it would count as metal without a word.
check_step() {
  local like='^[[:space:]]*\[[[:space:]]*([Ll][Aa][Bb]|[Mm][Ee][Tt][Aa][Ll])'
  if [[ $1 =~ $like ]] && [ -z "$(mark_of "$1")" ]; then
    die "not a mark: \"$1\" (use [metal], [lab] or [lab:<stage>], stage of a-z, 0-9 and -, then a space; nothing changed)"
  fi
}

cmd_add() {
  local n="${1:-}" title ms t tmp s opt='^--[a-z-]*(=[^[:space:]]*)?$'
  case "$n" in ""|-*) usage ;; esac
  shift
  for s in "$@"; do
    [[ ! $s =~ $opt ]] || usage
    check_step "$s"
  done
  title=$(issue_field "$n" .title); [ -n "$title" ] || die "cannot read issue #$n"
  ms=$(milestone_of "$n"); [ -n "$ms" ] || die "issue #$n has no milestone: set one first"
  t=$(tracker_of "$ms"); [ -n "$t" ] || t=$(make_tracker "$ms")
  tmp=$(mktemp); issue_field "$t" .body > "$tmp" || die "cannot read tracker #$t"
  add_to_body "$tmp" "$n" "$title" "$@"
  issue_set_body "$t" "$tmp" || die "cannot update tracker #$t"
  rm -f "$tmp"
  bash "$here/board.sh" move "$t" testing >/dev/null 2>&1 || true
  echo "#$n -> tracker #$t ($ms)"
}

# the step lines of issue $1 in the body file $2
steps_of() {
  awk -v n="$1" '
    $0 ~ "^- \\[[ xX]\\] #" n " " { on = 1; next }
    on && /^  - \[[ xX]\]/ { print; next }
    { on = 0 }' "$2"
}

# after a tick: store body file $3 in tracker $2 of issue $1 and post comment $4 (empty: none); close the tracker when no box is left
finish_tick() {
  local n="$1" t="$2" tmp="$3" comment="$4" left
  issue_set_body "$t" "$tmp" || die "cannot update tracker #$t"
  [ -z "$comment" ] || issue_comment "$t" "$comment" || echo "hwtest.sh: ticked, but the comment on #$t failed; post it by hand: $comment" >&2
  left=$(grep -c '\[ \]' "$tmp" || true)
  rm -f "$tmp"
  if [ "$left" = 0 ]; then
    issue_comment "$t" "Every box is ticked."
    issue_close "$t" && bash "$here/board.sh" move "$t" done >/dev/null 2>&1
    echo "#$n ticked; tracker #$t closed (nothing left)"
  else
    echo "#$n ticked; tracker #$t has $left open box(es)"
  fi
}

# refuse a tick: remove the body file $1, say why, change nothing
refuse() { rm -f "$1"; shift; die "$* (nothing changed)"; }

cmd_tick() {
  local n="" note="" box="" has_box=false args=0
  local ms t tmp steps count line text parent comment
  while [ $# -gt 0 ]; do
    case "$1" in
      --box) { [ $# -ge 2 ] && ! $has_box; } || usage
             has_box=true; box="$2"; shift 2 ;;
      --*) usage ;;
      *) args=$((args + 1))
         case $args in 1) n="$1" ;; 2) note="$1" ;; *) usage ;; esac
         shift ;;
    esac
  done
  [ -n "$n" ] || usage
  if $has_box; then
    [[ $box =~ ^[1-9][0-9]{0,5}$ ]] || die "--box takes the number of a step, 1 or higher, not \"$box\" (nothing changed)"
  fi
  ms=$(milestone_of "$n"); [ -n "$ms" ] || die "issue #$n has no milestone"
  t=$(tracker_of "$ms"); [ -n "$t" ] || die "no open tracker for \"$ms\""
  tmp=$(mktemp); issue_field "$t" .body > "$tmp"

  if ! $has_box; then
    awk -v n="$n" '
      $0 ~ "^- \\[[ xX]\\] #" n " " { sub(/\[ \]/, "[x]"); on = 1; print; next }
      on && /^  - \[[ xX]\]/ { sub(/\[ \]/, "[x]"); print; next }
      { on = 0; print }' "$tmp" > "$tmp.new" && mv "$tmp.new" "$tmp"
    finish_tick "$n" "$t" "$tmp" "${note:+#$n ran on a real server: $note}"
    return
  fi

  grep -q "^- \[[ xX]\] #$n " "$tmp" || refuse "$tmp" "#$n is not in tracker #$t"
  steps=$(steps_of "$n" "$tmp")
  [ -n "$steps" ] || refuse "$tmp" "#$n has no steps in tracker #$t: tick it without --box"
  count=$(printf '%s\n' "$steps" | grep -c .)
  [ "$box" -le "$count" ] || refuse "$tmp" "#$n has $count step(s), there is no step $box"
  line=$(printf '%s\n' "$steps" | sed -n "${box}p")
  case "$line" in
    "  - [ ] "*) text=${line#"  - [ ] "} ;;
    *) refuse "$tmp" "step $box of #$n is ticked already" ;;
  esac
  comment="${note:+#$n step $box ($text) ran on a real server: $note}"
  # the issue's line is ticked with its last open step
  parent=0
  [ "$(printf '%s\n' "$steps" | grep -c '^  - \[ \]')" != 1 ] || parent=1
  awk -v n="$n" -v k="$box" -v parent="$parent" '
    $0 ~ "^- \\[[ xX]\\] #" n " " { if (parent + 0) sub(/\[ \]/, "[x]"); on = 1; c = 0; print; next }
    on && /^  - \[[ xX]\]/ { if (++c == k + 0) sub(/\[ \]/, "[x]"); print; next }
    { on = 0; print }' "$tmp" > "$tmp.new" && mv "$tmp.new" "$tmp"
  finish_tick "$n" "$t" "$tmp" "$comment"
}

# Reads a tracker body. First line: the counts "open lab metal ticked" of the boxes that can be run; then, when $1 is lab or metal, the
# open boxes of that kind, each group under its issue line.
boxes() {
  LC_ALL=C awk -v want="$1" '
    function keep(line) { out = out "  " line "\n" }
    function flush() {
      if (top != "" && !has) {
        if (top ~ /^- \[ \]/) { metal++; if (want == "metal") keep(top) } else ticked++
      }
      top = ""
    }
    /^- \[[ xX]\] / { flush(); top = $0; has = 0; shown = 0; next }
    /^  - \[[ xX]\] / {
      has = 1
      if ($0 !~ /^  - \[ \]/) { ticked++; next }
      kind = ($0 ~ /^  - \[ \] \[lab(:[a-z0-9-]+)?\]( |$)/) ? "lab" : "metal"
      if (kind == "lab") lab++; else metal++
      if (want == kind) { if (top != "" && !shown) { keep(top); shown = 1 } keep($0) }
      next
    }
    { flush() }
    END { flush(); printf "%d %d %d %d\n%s", lab + metal, lab, metal, ticked, out }'
}

cmd_list() {
  local want="" kind="" args=0 t title body result open lab metal ticked
  while [ $# -gt 0 ]; do
    case "$1" in
      --lab|--metal) [ -z "$kind" ] || usage; kind=${1#--} ;;
      --*) usage ;;
      *) args=$((args + 1)); [ $args -le 1 ] || usage; want="$1" ;;
    esac
    shift
  done
  trackers | while IFS=$'\t' read -r t title; do
    case "$title" in *"$want"*) ;; *) continue ;; esac
    body=$(issue_field "$t" .body)
    result=$(printf '%s\n' "$body" | boxes "$kind")
    read -r open lab metal ticked <<<"$result"
    printf '#%s %s: %s open (%s lab, %s metal), %s ticked\n' "$t" "$title" "$open" "$lab" "$metal" "$ticked"
    if [ -z "$kind" ]; then
      printf '%s\n' "$body" | grep '\[ \]' | sed 's/^/  /'
    else
      printf '%s\n' "$result" | sed 1d
    fi
  done
}

# Issues of the board column Testing that are not trackers, as "number<TAB>milestone<TAB>title" (REST: the Status field is id 437753319).
testing_items() {
  gh api --paginate "orgs/hobnix/projectsV2/1/items?per_page=100&fields=437753319" \
    --jq '.[] | select(.content_type == "Issue") | select(.fields[0].value.name.raw == "Testing") | "\(.content.number)\t\(.content.milestone.title // "-")\t\(.content.title)"' |
    tr -d '\r' | grep -v "Hardware test: " || true
}

cmd_migrate() {
  local apply=false n ms title t state
  { [ $# -eq 0 ] || { [ $# -eq 1 ] && [ "$1" = "--apply" ]; }; } || usage
  export BOARD_CACHE; BOARD_CACHE=$(mktemp)   # the board is listed once, not once per move
  [ "${1:-}" = "--apply" ] && apply=true
  testing_items | sort -t$'\t' -k2,2 -k1,1n | while IFS=$'\t' read -r n ms title; do
    [ "$ms" != "-" ] || { echo "skip  #$n (no milestone): $title"; continue; }
    state=$(issue_field "$n" .state)
    if $apply; then
      if [ "$state" = open ]; then
        cmd_add "$n" >/dev/null || { echo "FAILED #$n"; continue; }
        t=$(tracker_of "$ms")
        issue_comment "$n" "Development is merged. The run on a real server is tracked in #$t (Hardware test: $ms); this issue closes so the milestone shows what is built." &&
          issue_close "$n"
      fi
      bash "$here/board.sh" move "$n" done >/dev/null 2>&1
      echo "moved #$n [$ms]"
    else
      echo "would move #$n [$ms] ($state) $title"
    fi
  done
  $apply || echo "(dry run: nothing changed; run with --apply)"
}

case "${1:-}" in
  add) shift; cmd_add "$@" ;;
  tick) shift; cmd_tick "$@" ;;
  list) shift; cmd_list "$@" ;;
  migrate) shift; cmd_migrate "$@" ;;
  *) usage ;;
esac
