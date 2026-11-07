#!/usr/bin/env bash
# The service-extension lifecycle v1 (docs/adr/0011-extension-service-lifecycle.md): the reference supervisor scripts/lib/ext_service.py against a test
# service (tests/fixtures/ext-service/svc.py): init and ready, delivery of subscribed events with acks and a cursor, health and heartbeat,
# shutdown, SIGTERM/SIGKILL, a start timeout, protocol errors, and the schema file. No root, python3 only.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
command -v python3 >/dev/null || { echo "python3 missing: skipped"; exit 0; }
RUN="python3 -I $SCRIPTS/lib/ext_service.py"
SVC=$ROOT/tests/fixtures/ext-service/svc.py
export SVC_LOG=$WORK/svc.log
EV=$WORK/events.jsonl
for r in '1 job failed a' '2 backup done b' '3 job failed c' '4 job done d'; do
  set -- $r
  printf '{"id":%s,"time":1700000000,"source":"%s","kind":"%s","subject":"%s","level":"info","text":"t","payload":null}\n' "$1" "$2" "$3" "$4" >> "$EV"
done

go() {   # go <mode> <run-for> [extra runner options]: out = the runner's lines, rc = its exit status
  local m=$1 f=$2; shift 2
  : > "$SVC_LOG"; rc=0
  out=$($RUN run --name fixsvc --run-for "$f" --grace 1 "$@" -- python3 -I "$SVC" "$m" 2>&1) || rc=$?
}
final() { printf '%s\n' "$out" | tail -n1 | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"; }
states() { printf '%s\n' "$out" | python3 -I -c '
import json,sys
print(" ".join(d["state"] for d in map(json.loads, sys.stdin) if d.get("type") == "state"))'; }

echo "-- start, run, stop"
go good 3 --subscribe 'job.*' --events "$EV" --cursor "$WORK/cur" --health-interval 1
check_eq "a service that is ready and healthy is stopped on request: exit 0" "0 stopped" "$rc $(final 'd["state"]')"
check_eq "the states are starting, running, stopping, stopped" "starting running stopping stopped" "$(states)"
check_eq "init names the package and the subscription" "fixsvc ['job.*']" "$(head -n1 "$SVC_LOG" | python3 -I -c 'import json,sys; d=json.loads(sys.stdin.readline()); print(d["name"], d["subscribe"])')"
check_eq "the service gets shutdown last" shutdown "$(tail -n1 "$SVC_LOG" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["type"])')"
check_eq "only the subscribed events are delivered (job.failed 1 and 3, job.done 4)" "1 3 4" "$(grep '"type": "event"' "$SVC_LOG" | python3 -I -c 'import json,sys; print(" ".join(str(json.loads(l)["id"]) for l in sys.stdin))')"
check_eq "the cursor is the last acknowledged id" 4 "$(cat "$WORK/cur")"
go good 3 --subscribe 'job.failed' --events "$EV" --cursor "$WORK/cur" --health-interval 1
check_eq "a restart does not repeat what was acknowledged" "0" "$(grep -c '"type": "event"' "$SVC_LOG")"
echo 2 > "$WORK/cur"
go good 3 --subscribe 'job.failed' --events "$EV" --cursor "$WORK/cur" --health-interval 1
check_eq "from cursor 2 only newer matching events arrive" "3" "$(grep '"type": "event"' "$SVC_LOG" | python3 -I -c 'import json,sys; print(" ".join(str(json.loads(l)["id"]) for l in sys.stdin))')"
check_eq "the cursor moves past events the service did not subscribe to" 4 "$(cat "$WORK/cur")"
echo 0 > "$WORK/cur"
go noack 3 --subscribe 'job.*' --events "$EV" --cursor "$WORK/cur" --health-interval 1
check_eq "without acks the cursor stays where it was (at-least-once)" 0 "$(cat "$WORK/cur")"
go emit 1 --health-interval 1
check_out "emit and snapshot messages are passed on" '"type":"snapshot"' printf '%s' "$out"
check_out "emit is passed on" 'pkg.fixsvc.seen' printf '%s' "$out"

echo "-- health"
go unhealthy 1.5 --health-interval 1
check_out "health ok=false makes the state degraded" 'degraded' printf '%s' "$(states)"
go silent 1.5 --health-interval 0.2 --missed 2
check_out "no heartbeat makes the state degraded" 'degraded' printf '%s' "$(states)"

echo "-- failures"
go crash 5 --health-interval 1
check_eq "a service that exits is failed (exit 1)" "1 failed exited" "$rc $(final 'd["state"] + " " + d["code"]')"
go badmsg 5 --health-interval 1
check_eq "a bad line is a protocol error" "1 protocol_error" "$rc $(final 'd["code"]')"
go ackbad 5 --health-interval 1
check_eq "an ack of an id that was not sent is a protocol error" "1 protocol_error" "$rc $(final 'd["code"]')"
go garbagefirst 5 --health-interval 1
check_eq "garbage before ready is a protocol error" "1 protocol_error" "$rc $(final 'd["code"]')"
go earlyack 5 --health-interval 1
check_eq "a message before ready is a protocol error" "1 protocol_error" "$rc $(final 'd["code"]')"
go longline 5 --health-interval 1
check_eq "a line over 1 MiB is a protocol error" "1 protocol_error" "$rc $(final 'd["code"]')"
# a deaf service with many large events must not freeze the supervisor: the stop still comes
BIG=$WORK/big.jsonl; python3 -I -c '
import json
for i in range(1, 301):
    print(json.dumps({"id": i, "time": 1, "source": "job", "kind": "failed", "subject": "s", "level": "info", "text": "t", "payload": {"p": "x" * 4000}}))' > "$BIG"
s=$SECONDS; go deaf 2 --subscribe 'job.*' --events "$BIG" --health-interval 1
check_eq "a service that stops reading does not block the stop" "0 stopped" "$rc $(final 'd["state"]')"
[ $((SECONDS - s)) -le 12 ] && pass "...in time" || fail "the stop took $((SECONDS - s)) s"
rc=0; $RUN run --name fixsvc --cursor /nonexistent/dir/c --subscribe 'job.*' --events "$EV" --health-interval 1 -- python3 -I "$SVC" good >/dev/null 2>&1 || rc=$?
check_eq "an error in the supervisor itself is not silent" 1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
sleep 0.5
if left=$(pgrep -af "^python3 -I $SVC good"); [ -n "$left" ]; then fail "the service is left running after a supervisor error: $left"; else pass "...and the service is not left running"; fi
s=$SECONDS; go slowready 30 --ready-timeout 1
check_eq "no ready in time: exit 75" "75 start_timeout" "$rc $(final 'd["code"]')"
[ $((SECONDS - s)) -le 6 ] && pass "the start timeout stops the process" || fail "start timeout took $((SECONDS - s)) s"
s=$SECONDS; go stubborn 1 --health-interval 1
check_eq "a service that ignores shutdown and SIGTERM is killed, the stop still counts as requested" "0 stopped" "$rc $(final 'd["state"]')"
[ $((SECONDS - s)) -le 8 ] && pass "SIGKILL follows" || fail "kill took $((SECONDS - s)) s"
sleep 0.3
if left=$(pgrep -af "^python3 -I $SVC"); [ -n "$left" ]; then fail "a service process is left behind: $left"; else pass "no process is left behind"; fi
rc=0; $RUN run --name Bad -- true >/dev/null 2>&1 || rc=$?
check_eq "a bad package name is refused" 2 "$rc"

echo "-- schema"
SCHEMA=$ROOT/docs/api/ext-service-v1.schema.json
check "the schema is valid JSON" python3 -I -c "import json; json.load(open('$SCHEMA'))"
check "the schema and the supervisor agree" python3 -I - "$SCHEMA" "$SCRIPTS/lib" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[2])
import ext_service as p
d = json.load(open(sys.argv[1]))["$defs"]
assert {r["$ref"].split("/")[-1] for r in d["fromService"]["oneOf"]} == set(p.FROM_SERVICE)
assert set(d["state"]["enum"]) == set(p.STATES)
assert d["init"]["properties"]["v"]["const"] == p.VERSION
assert {r["$ref"].split("/")[-1] for r in d["fromCore"]["oneOf"]} == {"init", "event", "shutdown"}
PY
finish
