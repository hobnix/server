#!/usr/bin/env bash
# scripts/dev/hwtest.sh: the hardware-test trackers (marks, one box per tick, list). A fake gh serves issue and tracker bodies
# from files and records every changing call; nothing talks to GitHub. No root, no network.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

D=$WORK/gh
mkdir -p "$D" "$WORK/bin" "$WORK/dev"
# a copy next to a fake board.sh: the real one never runs here
cp "$SCRIPTS/dev/hwtest.sh" "$WORK/dev/hwtest.sh"
printf '#!/usr/bin/env bash\necho "board $*" >> "%s/calls"\n' "$D" > "$WORK/dev/board.sh"

cat > "$WORK/bin/gh" <<'FAKE'
#!/usr/bin/env bash
# every answer ends in CRLF, as the real gh does on Windows
[ "$1" = api ] || { echo "fake gh: only api" >&2; exit 1; }
shift
method=GET path="" jq="" body="" title="" fields=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method=$2; shift 2 ;;
    --jq) jq=$2; shift 2 ;;
    -f) [ "$method" != GET ] || method=POST
        case "$2" in body=*) body=${2#body=} ;; title=*) title=${2#title=} ;; *) fields="$fields $2" ;; esac
        shift 2 ;;
    --silent|--paginate) shift ;;
    *) path=$1; shift ;;
  esac
done
say() { printf '%s\n' "$1" | sed 's/$/\r/'; }
file() { [ -f "$1" ] && say "$(cat "$1")"; }
p=${path#repos/hobnix/core/}
if [ "$method" = GET ]; then
  case "$p" in
    "issues?labels="*) file "$FAKE_GH/trackers" ;;
    labels/*) exit 0 ;;
    issues/*) n=${p#issues/}
      case "$jq" in
        .title) file "$FAKE_GH/$n.title" ;;
        .body) file "$FAKE_GH/$n.body" ;;
        .state) say open ;;
        .milestone*) file "$FAKE_GH/$n.ms" ;;
      esac
      true ;;
    orgs/*) file "$FAKE_GH/testing" ;;
    *) echo "fake gh: unknown read $path" >&2; exit 1 ;;
  esac
  exit
fi
echo "$method $p$fields" >> "$FAKE_GH/calls"
case "$method $p" in
  "POST issues") printf '%s\n' "$body" > "$FAKE_GH/900.body"; printf '900\t%s\n' "$title" >> "$FAKE_GH/trackers"; say 900 ;;
  "POST issues/"*/comments) printf '%s\n' "$body" >> "$FAKE_GH/comments" ;;
  "PATCH issues/"*) n=${p#issues/}; [ -z "$body" ] || printf '%s\n' "$body" > "$FAKE_GH/$n.body" ;;
esac
exit 0
FAKE
chmod +x "$WORK/bin/gh"
export FAKE_GH=$D PATH="$WORK/bin:$PATH"
# should the real gh ever be reached, it has no login
export GH_TOKEN=fake GITHUB_TOKEN=fake GH_CONFIG_DIR=$WORK/ghconfig
check_eq "the fake gh is the one in use" "$WORK/bin/gh" "$(command -v gh)"
[ "$(command -v gh)" = "$WORK/bin/gh" ] || { finish; exit 1; }

hw() { bash "$WORK/dev/hwtest.sh" "$@"; }
run() { RC=0; OUT=$(hw "$@" 2>&1) || RC=$?; }

TRACKER='Intro text.

- [ ] #5 Five
  - [ ] unmarked step
  - [ ] [lab:install] install in a VM
  - [ ] [metal] pull a disk
  - [ ] [lab] no stage yet
- [ ] #6 Six
- [ ] #7 Seven
  - [x] [lab:backup] done before
  - [ ] [lab:backup] restore on a real server'

reset() {   # reset [tracker body]
  rm -rf "$D"; mkdir -p "$D"
  printf '100\tHardware test: 0.15\n' > "$D/trackers"
  printf '%s\n' "${1-$TRACKER}" > "$D/100.body"
  local n
  for n in 5 6 7 8; do echo 0.15 > "$D/$n.ms"; echo "Title $n" > "$D/$n.title"; done
  : > "$D/calls"; : > "$D/comments"
}
body() { cat "$D/100.body"; }
calls() { cat "$D/calls"; }
comments() { cat "$D/comments"; }
has_line() { grep -Fxq -- "$2" <<<"$1"; }

refused() {   # refused "what" exit-code regex args...: fails with the code, says why, makes no changing call
  local what=$1 code=$2 re=$3; shift 3
  run "$@"
  check_eq "$what: exit code" "$code" "$RC"
  check_match "$what: message" "$re" "$OUT"
  check_eq "$what: no changing call" "" "$(calls)"
}

echo "add"
reset
run add 8 "plain step" "[metal] a" "[lab] b" "[lab:net-2] c"
check_eq "add works" 0 "$RC"
check "an issue line" has_line "$(body)" "- [ ] #8 Title 8"
for s in "plain step" "[metal] a" "[lab] b" "[lab:net-2] c"; do check "step stored as given: $s" has_line "$(body)" "  - [ ] $s"; done
check_eq "no CR reaches the body" "0" "$(tr -cd '\r' < "$D/100.body" | wc -c | tr -d ' ')"   # not grep: Git Bash drops a CR pattern
check_match "the tracker goes to testing" '^board move 100 testing$' "$(calls)"
run add 8 "again"
check_eq "add is idempotent per issue" "1" "$(grep -c '^- \[ \] #8 ' "$D/100.body")"
reset; : > "$D/trackers"
run add 8 "[lab:x] y"
check_eq "add creates the first tracker" 0 "$RC"
check "the new tracker has the step" has_line "$(cat "$D/900.body")" "  - [ ] [lab:x] y"
for bad in "[Lab] x" "[labs] x" "[lab:] x" "[lab:Stage] x" "[lab: a] x" "[lab:a_b] x" "[Metal] x" "[metal:a] x" "[lab]x" " [lab] x" "[lab x"; do
  reset; : > "$D/trackers"   # not even a tracker is created
  refused "add refuses '$bad'" 1 'not a mark' add 8 "good step" "$bad"
done
reset
refused "add without an issue" 2 '^usage:' add
refused "add with an unknown option" 2 '^usage:' add 8 --force

echo "tick, the whole issue"
reset
run tick 5 "all went well"
check_eq "tick works" 0 "$RC"
check "the issue line is ticked" has_line "$(body)" "- [x] #5 Five"
check "its steps are ticked" has_line "$(body)" "  - [x] [metal] pull a disk"
check "the next issue is not" has_line "$(body)" "- [ ] #6 Six"
check_eq "a whole tick with lab boxes claims no real server" "#5 was seen to run (with lab boxes): all went well" "$(comments)"
check_match "open boxes are counted" 'tracker #100 has 3 open box' "$OUT"
reset
run tick 5
check_eq "no note, no comment" "" "$(comments)"
reset '- [ ] #6 Six'
run tick 6 "seen"
check_match "the last tick closes the tracker" 'state=closed' "$(calls)"
check_match "and moves it to done" '^board move 100 done$' "$(calls)"
check_match "and says so" 'Every box is ticked' "$(comments)"

echo "tick one box"
reset
run tick 5 --box 3 "pulled it"
check_eq "a box tick works" 0 "$RC"
check "that step is ticked" has_line "$(body)" "  - [x] [metal] pull a disk"
check_eq "only that one" "2" "$(grep -c '\[x\]' "$D/100.body")"
check "the issue line stays open" has_line "$(body)" "- [ ] #5 Five"
check_eq "the comment names number and text" "#5 step 3 ([metal] pull a disk) ran on a real server: pulled it" "$(comments)"
run tick 5 --box 1
run tick 5 --box 2
check "still open with one step left" has_line "$(body)" "- [ ] #5 Five"
run tick 5 --box 4
check "the issue line goes with the last step" has_line "$(body)" "- [x] #5 Five"
check "other issues stay" has_line "$(body)" "- [ ] #6 Six"
reset '- [ ] #5 Five
  - [ ] only one'
run tick 5 --box 1
check_match "a box tick closes the tracker too" 'state=closed' "$(calls)"

for k in 0 -1 a 1.5 "" 08; do reset; refused "--box '$k'" 1 'takes the number' tick 5 --box "$k" note; done
reset
refused "a box out of range" 1 'there is no step 5' tick 5 --box 5
refused "an issue without steps" 1 'has no steps' tick 6 --box 1
refused "an issue not in the tracker" 1 'is not in tracker' tick 8 --box 1
refused "a ticked box" 1 'ticked already' tick 7 --box 1 note
refused "--box without a number" 2 '^usage:' tick 5 --box
refused "an unknown option of tick" 2 '^usage:' tick 5 --all
refused "a third argument of tick" 2 '^usage:' tick 5 two words
refused "tick without an issue" 2 '^usage:' tick

echo "only a seen run ticks"
reset
refused "the removed test-lab tick" 2 '^usage:' tick 5 --box 2 --lab run-42 0123abc
refused "the removed test-lab tick without --box" 2 '^usage:' tick 5 --lab run-42 0123abc "log kept"
run tick 5 --box 2 "watched it"
check_eq "a person ticks a lab box" "#5 step 2 ([lab:install] install in a VM) was seen to run (lab box): watched it" "$(comments)"
reset
run tick 5 --box 4 "watched it"
check_eq "[lab] without a stage claims no real server either" "#5 step 4 ([lab] no stage yet) was seen to run (lab box): watched it" "$(comments)"
reset '- [ ] #5 Five
  - [x] [lab:a] ticked before
  - [ ] [metal] pull a disk
- [ ] #6 Six'
run tick 5 "watched it"
check_eq "a lab box ticked before does not change the wording" "#5 ran on a real server: watched it" "$(comments)"

echo "list"
reset
run list
check_eq "list works" 0 "$RC"
check "the counts" has_line "$OUT" "#100 Hardware test: 0.15: 6 open (3 lab, 3 metal), 1 ticked"
check "an open issue line as before" has_line "$OUT" "  - [ ] #5 Five"
check "an open step as before" has_line "$OUT" "    - [ ] unmarked step"
check_eq "every open line and the header" "9" "$(wc -l <<<"$OUT" | tr -d ' ')"
run list --lab
check_eq "--lab: the lab boxes under their issue lines" "#100 Hardware test: 0.15: 6 open (3 lab, 3 metal), 1 ticked
  - [ ] #5 Five
    - [ ] [lab:install] install in a VM
    - [ ] [lab] no stage yet
  - [ ] #7 Seven
    - [ ] [lab:backup] restore on a real server" "$OUT"
run list 0.15 --metal
check_eq "--metal: unmarked, metal and an issue without steps" "#100 Hardware test: 0.15: 6 open (3 lab, 3 metal), 1 ticked
  - [ ] #5 Five
    - [ ] unmarked step
    - [ ] [metal] pull a disk
  - [ ] #6 Six" "$OUT"
run list 9.9
check_eq "a milestone text filters" "" "$OUT"
check_eq "list changes nothing" "" "$(calls)"
refused "an unknown option of list" 2 '^usage:' list --labs
refused "both kinds" 2 '^usage:' list --lab --metal

echo "the rest"
refused "an unknown command" 2 '^usage:' frob
refused "an unknown option of migrate" 2 '^usage:' migrate --aply
refused "migrate with more" 2 '^usage:' migrate --apply now

finish
