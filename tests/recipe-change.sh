#!/usr/bin/env bash
# hs sys recipes plan|start <recipe> run (scripts/recipe-change.sh): a recipe is run as a job without questions; one that needs something
# typed (header `# input: terminal`) and the parked sunshine are refused. A fake recipes folder and recipe.sh stand in.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en
unset HS_CALLER HS_GUIDED_TTY
T=$'\t'
R=$WORK/recipes; mkdir -p "$R"/{fine,token,sunshine,vpn}
printf '# recipe: Fine: an app\n# kind: generic\n# needs: -\n# input: none\n# uses: -\n' > "$R/fine/run.sh"
printf '# recipe: Token: asks a token\n# kind: generic\n# needs: -\n# input: terminal\n# uses: -\n' > "$R/token/run.sh"
printf '# recipe: Sunshine\n' > "$R/sunshine/run.sh"
export HS_RECIPES_DIR=$R
run() { rc=0; out=$(timeout 20 bash "$SCRIPTS/recipe-change.sh" "$@" </dev/null 2>/dev/null) || rc=$?; }
has() { grep -q -- "$1" <<<"$out"; }

run plan fine run;                 check_eq "plan: exit 0" 0 "$rc"
has "^command${T}hs recipe fine\$" && pass "plan names the command" || fail "$out"
has "^long${T}yes" && pass "it is a long job" || fail "$out"
run plan fine run --name fine2;    check_eq "a name of its own is allowed" 0 "$rc"
has "hs recipe fine --name fine2" && pass "the command has the name" || fail "$out"
run plan fine run --name 'A b';    check_eq "a bad container name is refused" 1 "$rc"
run plan token run;                check_eq "a recipe that needs typing is refused" 1 "$rc"
has "hs recipe token" && pass "the reason names the command" || fail "$out"
run plan sunshine run;             check_eq "sunshine is parked" 1 "$rc"
run plan nosuch run;               check_eq "an unknown recipe is refused" 1 "$rc"
run plan '../x' run;               check_eq "a path is refused" 1 "$rc"
run plan fine stop;                check_eq "an unknown action is refused" 1 "$rc"
run plan fine run --bogus;         check_eq "an unknown option is refused" 1 "$rc"
run start token run;               check_eq "start repeats the checks" 1 "$rc"

echo "-- a recipe with questions (# ask: lines)"
cat > "$R/vpn/run.sh" <<'RCP'
# recipe: Vpn: a recipe with questions
# kind: generic
# needs: -
# input: form
# ask: PROVIDER|Provider|text|proton|[a-z]+|
# ask: KIND|Protocol|choice:wg,ovpn|wg||
# ask: COUNTRIES|Countries|text|||
# ask: KEY|Private key|secret|||KIND=wg
# ask: ADDR|Address|text||[0-9./]+|KIND=wg
# ask: USER|User|text||[^ ]+|KIND=ovpn
# ask: PASS|Password|secret|||KIND=ovpn
RCP
runin() { local in=$1; shift; rc=0; out=$(printf '%s\n' "$in" | timeout 20 bash "$SCRIPTS/recipe-change.sh" "$@" 2>/dev/null) || rc=$?; }
run plan vpn run;                                 check_eq "an answer is missing: exit 2" 2 "$rc"
has "^needs${T}ADDR" && pass "names ADDR" || fail "$out"
has "^needs${T}KEY" && pass "and the secret KEY" || fail "$out"
has "^needs${T}COUNTRIES" && fail "a text question without a pattern may stay empty" || pass "COUNTRIES may stay empty"
runin 's3cret' plan vpn run --set ADDR=10.2.0.2/32; check_eq "all answered: exit 0" 0 "$rc"
has "kept secret" && pass "the plan says the secret stays secret" || fail "$out"
grep -q "s3cret\|10.2.0.2" <<<"$out" && fail "the plan must not print the answers" || pass "no answer is printed"
runin 'x' plan vpn run --set ADDR=abc;            check_eq "an answer that does not fit the pattern is refused" 1 "$rc"
runin 'x' plan vpn run --set KIND=zzz --set ADDR=1;  check_eq "a choice outside the list is refused" 1 "$rc"
runin 'x' plan vpn run --set NOPE=1;              check_eq "a question the recipe does not ask is refused" 1 "$rc"
runin 'x' plan vpn run --set KEY=hack;            check_eq "a secret cannot be given as an argument" 1 "$rc"
runin 'u' plan vpn run --set KIND=ovpn --set USER=bob; check_eq "the other protocol asks for its own fields" 0 "$rc"
run plan vpn run --set KIND=ovpn;                 check_eq "...and needs USER and PASS" 2 "$rc"
has "^needs${T}PASS" && pass "PASS is missing" || fail "$out"

echo "-- a usb question (vendor:product)"
mkdir -p "$R/printer"
cat > "$R/printer/run.sh" <<'RCP'
# recipe: Printer: a recipe with a usb question
# kind: generic
# needs: -
# input: form
# ask: PRINTER_USB|Printer|usb|||
RCP
run plan printer run;                              check_eq "a usb answer is missing: exit 2" 2 "$rc"
has "^needs${T}PRINTER_USB" && pass "names PRINTER_USB" || fail "$out"
run plan printer run --set PRINTER_USB=04f9:0042;  check_eq "a vendor:product is taken" 0 "$rc"
run plan printer run --set PRINTER_USB=04F9:0042;  check_eq "upper case is refused" 1 "$rc"
run plan printer run --set PRINTER_USB=04f9;       check_eq "a half id is refused" 1 "$rc"
check_out "asks prints the usb kind" "^PRINTER_USB${T}Printer${T}usb${T}-${T}-${T}-" env HS_RECIPES_DIR=$R bash "$SCRIPTS/recipe-asks.sh" printer
has "^needs${T}ADDR" && fail "ADDR belongs to the other protocol" || pass "ADDR does not count for ovpn"

echo "-- start: the answers reach the job, the secret as a file"
mkdir -p "$WORK/lib"
cat > "$WORK/lib/job.sh" <<JOB
hs_job() {
  shift 3
  { echo "ENV:\$HS_JOB_ENV"; echo "CMD:\$*"; } >> "$WORK/jobs"
  # the secret file exists while the job would run: copy what it holds
  d=\$(sed -n 's/^HS_SECRETS_DIR=//p' <<<"\$HS_JOB_ENV"); [ -z "\$d" ] || { ls -l "\$d" | awk '{ print "MODE:" \$1 }' >> "$WORK/jobs"; cat "\$d"/* >> "$WORK/secretseen"; }
  echo hs-job-test-1
}
JOB
cp "$SCRIPTS/recipe-change.sh" "$WORK/recipe-change.sh"; cp "$SCRIPTS/lib/recipe-path.sh" "$WORK/lib/"; mkdir -p "$WORK/run"
: > "$WORK/jobs"; : > "$WORK/secretseen"
rc=0; out=$(printf 's3cret\n' | HS_RUN_DIR="$WORK/run" timeout 20 bash "$WORK/recipe-change.sh" start vpn run --name vpn2 --set ADDR=10.2.0.2/32 --set COUNTRIES=AT 2>/dev/null) || rc=$?
check_eq "start: exit 0" 0 "$rc"
has "^status${T}started" && pass "a job was started" || fail "$out"
grep -q "^RECIPE_ADDR=10.2.0.2/32" "$WORK/jobs" && pass "the answer is RECIPE_ADDR in the job's environment" || fail "$(cat "$WORK/jobs")"
grep -q "RECIPE_PROVIDER=proton" "$WORK/jobs" && pass "the default is passed on" || fail "$(cat "$WORK/jobs")"
grep -q "RECIPE_COUNTRIES=AT" "$WORK/jobs" && pass "an optional answer is passed on" || fail "$(cat "$WORK/jobs")"
grep -q "s3cret" "$WORK/jobs" && fail "the secret must not be in the environment or the command" || pass "the secret is not in the environment or the command line"
check_eq "the job could read the secret from its file" "s3cret" "$(cat "$WORK/secretseen")"
grep -q "CMD:bash -c .*recipe.sh vpn --name vpn2" "$WORK/jobs" && pass "the job removes the folder when it ends, then runs the recipe" || fail "$(cat "$WORK/jobs")"
rm -rf "$WORK/run"; mkdir -p "$WORK/run"
rc=0; out=$(printf '\n' | HS_RUN_DIR="$WORK/run" timeout 20 bash "$WORK/recipe-change.sh" start vpn run --set ADDR=10.2.0.2/32 2>/dev/null) || rc=$?
check_eq "start without the secret: refused (needs)" 2 "$rc"
check_eq "no secret folder is left behind" "" "$(ls -A "$WORK/run" 2>/dev/null)"

echo "-- hs sys recipes asks"
a=$(HS_RECIPES_DIR=$R bash "$SCRIPTS/recipe-asks.sh" vpn)
check_out "a row per question" "^PROVIDER${T}Provider${T}text${T}proton${T}" echo "$a"
check_out "the condition is a column" "^KEY${T}Private key${T}secret${T}-${T}-${T}KIND=wg" echo "$a"
check_out "the last row says how it is answered" "^input${T}form" echo "$a"
check_out "a recipe without questions says none" "^input${T}none" env HS_RECIPES_DIR=$R bash "$SCRIPTS/recipe-asks.sh" fine
check_out "domain needs a terminal" "^input${T}terminal" env -u HS_RECIPES_DIR bash "$SCRIPTS/recipe-asks.sh" domain
check_out "qbittorrent has a form" "^input${T}form" env -u HS_RECIPES_DIR bash "$SCRIPTS/recipe-asks.sh" qbittorrent
finish
