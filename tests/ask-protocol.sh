#!/usr/bin/env bash
# Interactive recipe runs (ADR 0018 stage 3, docs/PLAN-recipe-orchestrator.md): the question/answer file protocol, the orchestrator, `jobs answer`.
# A stand-in systemd-run starts a unit in the background, a stand-in recipe asks questions (text with a retry, choice, secret), the test plays
# the person with `jobs-answer.sh`. No root, no systemd, no hardware: "Not tested on hardware yet."
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); # the stand-in units run on their own: the exit trap stops every one of them (a step that still waits would keep the test runner's pipe open)
reap() { local p; for p in $(cat "$T/units.pids" 2>/dev/null) $(jobs -p); do pkill -TERM -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done; sleep 0.3; pkill -KILL -f "$T" 2>/dev/null; true; }
trap 'reap; rm -rf "$T"' EXIT
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok:   $1"; else echo "FAIL: $1 (got: $3 | want: $2)"; fail=1; fi; }
mkdir -p "$T/bin" "$T/recipes/quiz" "$T/out"
cat > "$T/bin/systemd-run" <<'FAKE'
#!/usr/bin/env bash
unit=""
( while [ $# -gt 0 ]; do
    case "$1" in -E) export "$2"; shift 2 ;; --unit=*) unit=${1#--unit=}; shift ;; --*) shift ;; *) break ;; esac
  done
  echo "$unit" >> "$HS_FAKE_UNITS"
  exec "$@" ) </dev/null >>"$HS_FAKE_LOG" 2>&1 &
echo $! >> "$HS_FAKE_UNITS.pids"
FAKE
cat > "$T/bin/systemctl" <<'FAKE'
#!/usr/bin/env bash
echo "systemctl $*" >> "$HS_FAKE_LOG"
exit 0
FAKE
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" HS_FAKE_LOG="$T/log" HS_FAKE_UNITS="$T/units" HS_JOBS_DIR="$T/jobs" HS_RUN_DIR="$T/run" HS_STATE_DIR="$T/state" \
  HS_EVENT_NOROOT=1 HS_STATE_DB="$T/ev.db" HS_JOB_RECORD=python HS_PLAIN=1 HS_LANG=en HS_ASK_POLL=0.1 HS_ASK_NOUNITCHECK=1 HS_SYSTEMCTL="$T/bin/systemctl" \
  HS_RECIPES_DIR="$T/recipes" HS_NOTIFY="$T/notify" HS_OUT="$T/out" HS_CALLER=test
printf '#!/usr/bin/env bash\necho "$*" >> "%s/notified"\n' "$T" > "$T/notify"; chmod +x "$T/notify"
printf '# recipe: Quiz\n# kind: generic\n# needs: -\n# input: steps\n' > "$T/recipes/quiz/run.sh"
# the stand-in for recipe.sh: asks like a recipe does
cat > "$T/recipe.sh" <<RCP
#!/usr/bin/env bash
. "$here/scripts/lib/ui.sh"; . "$here/scripts/lib/ask.sh"
interactive() { [ -t 0 ] && [ -t 1 ]; }
answer() { local e="RECIPE_\$1"; printf '%s' "\${!e:-}"; }
port=\$(ask_q PORT text "Which port" 8080 '[0-9]+') || exit \$?
n=1; until [[ "\$port" =~ ^[0-9]+\$ ]]; do n=\$((n+1)); port=\$(ASK_ERROR="That is not a number." ASK_ATTEMPT=\$n ask_q PORT text "Which port" 8080 '[0-9]+') || exit \$?; done
mode=\$(ask_q MODE choice "Mode" fast "" fast,slow) || exit \$?
pw=\$(ask_q PASSWORD secret "Admin password") || exit \$?
printf '%s' "\$port" > "\$HS_OUT/port"; printf '%s' "\$mode" > "\$HS_OUT/mode"; printf '%s' "\$pw" > "\$HS_OUT/pw"
RCP
export HS_RECIPE=$T/recipe.sh
J() { python3 "$here/scripts/job-record.py" "$@"; }
field() { python3 -c 'import json,sys
v=json.load(sys.stdin)
for k in sys.argv[1].split("."):
    v=v.get(k) if isinstance(v,dict) else None
print("" if v is None else v)' "$1"; }
wait_state() { local i; for i in $(seq 1 200); do [ "$(J get "$1" | field state)" = "$2" ] && return 0; sleep 0.1; done; return 1; }
wait_key() { local i; for i in $(seq 1 200); do [ "$(J get "$id" | field waiting.key)" = "$1" ] && [ "$(J get "$id" | field waiting.attempt)" = "${2:-1}" ] && return 0; sleep 0.1; done; return 1; }
answer() { local v=$1; shift; printf '%s\n' "$v" | bash "$here/scripts/jobs-answer.sh" "$id" "$@" 2>/dev/null; }   # as the web server does: value on stdin
has() { grep -c "$1" <<<"$r"; }

out=$(bash "$here/scripts/recipe-change.sh" start quiz run --interactive --by alice --role app-manager </dev/null)
id=$(awk -F'\t' '$1=="job"{print $2}' <<<"$out")
check "start prints status started" "1" "$(grep -c '^status.started' <<<"$out")"
check "the job is an orchestration of the person who started it" "orchestration alice" "$(J get "$id" | field kind) $(J get "$id" | field initiator)"

wait_state "$id" waiting; check "a question puts the job in state waiting" "PORT" "$(J get "$id" | field waiting.key)"
check "the record names kind and default" "text 8080" "$(J get "$id" | field waiting.kind) $(J get "$id" | field waiting.default)"
check "a push message names the recipe and the question" "1" "$(grep -c 'quiz: Which port' "$T/notified")"
check "job.waiting is in the event log" "1" "$([ "$(python3 "$here/scripts/state-db.py" event-list 50 2>/dev/null | grep -c 'job.waiting')" -ge 1 ] && echo 1)"
seq=$(J get "$id" | field waiting.seq)

r=$(answer 8080 --seq 99 --key PORT);   check "a stale seq is refused" "1" "$(has status.stale)"
r=$(answer 8080 --seq "$seq" --key OTHER); check "a wrong key is stale too" "1" "$(has status.stale)"
r=$(answer 8080 --seq "$seq" --key PORT --by bob --role app-manager); check "someone else (not admin) may not answer" "1" "$(has status.refused)"
check "and the question still waits" "waiting" "$(J get "$id" | field state)"
r=$(answer "ab" --seq "$seq" --key PORT --by alice --role app-manager); check "the initiator answers (the step decides about the text)" "1" "$(has status.done)"
r=$(answer "x" --seq "$seq" --key PORT --by alice --role app-manager);  check "a double submit is harmless" "1" "$(has status.stale)"

wait_key PORT 2
check "a retry shows the error text and the next attempt" "That is not a number. 2" "$(J get "$id" | field waiting.error) $(J get "$id" | field waiting.attempt)"
seq=$(J get "$id" | field waiting.seq)
r=$(answer 9090 --seq "$seq" --key PORT --by carol --role admin); check "an admin may answer" "1" "$(has status.done)"

wait_key MODE; seq=$(J get "$id" | field waiting.seq)
r=$(answer medium --seq "$seq" --key MODE --role admin); check "a choice outside the choices is refused" "1" "$(has status.refused)"
r=$(answer slow --seq "$seq" --key MODE --role admin);   check "a choice is accepted" "1" "$(has status.done)"

wait_key PASSWORD
check "a secret question has no default in the record" "secret" "$(J get "$id" | field waiting.kind)$(J get "$id" | field waiting.default)"
seq=$(J get "$id" | field waiting.seq)
SECRET='S3cret-Pass-9f2'
r=$(answer "$SECRET" --seq "$seq" --key PASSWORD --role admin); check "the secret is accepted" "1" "$(has status.done)"
wait_state "$id" ok; check "the run ends ok" "ok" "$(J get "$id" | field state)"
check "the step got every answer" "9090 slow $SECRET" "$(cat "$T/out/port") $(cat "$T/out/mode") $(cat "$T/out/pw")"
check "no secret in the job records" "0" "$(grep -rlF "$SECRET" "$T/jobs" | wc -l)"
check "no secret in the event log" "0" "$(python3 "$here/scripts/state-db.py" event-list 200 2>/dev/null | grep -cF "$SECRET")"
check "no secret in the unit logs or the notifications" "0" "$(cat "$T/log" "$T/notified" | grep -cF "$SECRET")"
check "the question folder is gone" "0" "$(ls "$T/run/ask" 2>/dev/null | wc -l)"
check "the sub-job names its orchestration" "1" "$(bash "$here/scripts/jobs.sh" --children "$id" 2>/dev/null | wc -l)"
check "the events include job.resumed" "1" "$([ "$(python3 "$here/scripts/state-db.py" event-list 200 2>/dev/null | grep -c job.resumed)" -ge 1 ] && echo 1)"

echo "-- timeout: nobody answers"
export HS_ASK_TIMEOUT=2
out=$(bash "$here/scripts/recipe-change.sh" start quiz run --interactive --by alice </dev/null); id=$(awk -F'\t' '$1=="job"{print $2}' <<<"$out")
wait_state "$id" cancelled; check "an unanswered question cancels the run" "cancelled" "$(J get "$id" | field state)"
check "with the reason input_timeout" "input_timeout" "$(J get "$id" | field error.category)"
check "the sub-job's unit was stopped" "1" "$([ "$(grep -c '^systemctl stop hs-job-recipe-quiz-run' "$T/log")" -ge 1 ] && echo 1)"
unset HS_ASK_TIMEOUT

echo "-- ten refused answers: the step stops (exit 75) and the record says input_rejected"
cat > "$T/recipe2.sh" <<RCP
#!/usr/bin/env bash
. "$here/scripts/lib/ui.sh"; . "$here/scripts/lib/ask.sh"
interactive() { false; }
answer() { :; }
n=1; while :; do ASK_ERROR=no ASK_ATTEMPT=\$n ask_q PORT text Port >/dev/null || exit \$?; n=\$((n+1)); done
RCP
. "$here/scripts/lib/job.sh"
id2=$(hs_job_record new --slug t --desc t --unit u --source cli --initiator x); hs_job_record run "$id2"
export HS_JOB_ID=$id2 HS_ASK_DIR=$T/ask2; mkdir -p "$HS_ASK_DIR"
( while :; do sleep 0.1
    s=$(ls "$HS_ASK_DIR/q" 2>/dev/null | grep -m1 '\.json$'); s=${s%%.*}
    [ -z "$s" ] || printf 'x\n' | python3 "$here/scripts/lib/ask-q.py" accept "$HS_ASK_DIR" "$s" PORT; done ) 2>/dev/null &
w=$!
bash "$T/recipe2.sh" >/dev/null 2>&1; rc=$?
kill "$w" 2>/dev/null
hs_job_record finish "$id2" "$rc" >/dev/null; hs_job_record error "$id2" --category input_rejected --message x >/dev/null 2>&1 || true
check "the step stopped with 75" "75" "$rc"
check "the record names input_rejected" "input_rejected" "$(J get "$id2" | field error.category)"
unset HS_JOB_ID HS_ASK_DIR

echo "-- the terminal and the up-front answer work without HS_ASK_DIR"
Q=". '$here/scripts/lib/ui.sh'; . '$here/scripts/lib/ask.sh'; interactive() { false; }"
check "an answer up front wins" "7000" "$(RECIPE_PORT=7000 bash -c "$Q; answer() { local e=RECIPE_\$1; printf '%s' \"\${!e:-}\"; }; ask_q PORT text Port 1")"
check "no terminal, nothing up front: the default" "1234" "$(bash -c "$Q; answer() { :; }; ask_q PORT text Port 1234")"
printf 'PORT=5555\nPORT=6666\n' > "$T/script"
check "the fake answerer plays its lines in order" "5555 6666" "$(HS_ASK_SCRIPT=$T/script bash -c "$Q; answer() { :; }; a=\$(ask_q PORT text Port 1); b=\$(ask_q PORT text Port 1); echo \$a \$b")"

echo "-- the container relay: the answer goes in on stdin, never argv"
cat > "$T/bin/incus" <<'FAKE'
#!/usr/bin/env bash
echo "incus $*" >> "$HS_FAKE_LOG"; cat > "$HS_OUT/relayed"
FAKE
chmod +x "$T/bin/incus"
printf 'PASSWORD=Relay-9z\n' > "$T/script2"
HS_ASK_SCRIPT=$T/script2 bash -c "$Q; answer() { :; }; ask_q_exec web1 PASSWORD secret Password -- sh -c 'cat > /etc/pw'"
check "the command in the container got the answer on stdin" "Relay-9z" "$(cat "$T/out/relayed")"
check "the answer is not in the incus command line" "0" "$(grep -c 'Relay-9z' "$T/log")"
exit $fail
