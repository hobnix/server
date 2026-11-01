#!/usr/bin/env bash
# The live-state hooks: the dispatcher (scripts/lib/hs.sh) asks the collector for the group of a `changes` row after exit 0 (HS_LIVE_LOG records
# the call instead of the socket), a failed change and a read ask for nothing; reads-collect.sh skips what has a topic when the live socket exists.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
wp() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }
T=$'\t'
cat > "$WORK/ok.sh" <<'S'
#!/usr/bin/env bash
echo "ran $*"
S
cat > "$WORK/fail.sh" <<'S'
#!/usr/bin/env bash
exit 3
S
printf 'user%szok%s%s/ok.sh%s-%s-%s-%stopic:disks,changes\n' "$T" "$T" "$WORK" "$T" "$T" "$T" "$T" > "$WORK/reg.tsv"
printf 'user%szfail%s%s/fail.sh%s-%s-%s-%stopic:disks,changes\n' "$T" "$T" "$WORK" "$T" "$T" "$T" "$T" >> "$WORK/reg.tsv"
printf 'user%szplain%s%s/ok.sh%s-%s-%s-%schanges\n' "$T" "$T" "$WORK" "$T" "$T" "$T" "$T" >> "$WORK/reg.tsv"
printf 'user%sext zz go%s%s/ok.sh%s-%s-%s-%stopic:system,changes
' "$T" "$T" "$WORK" "$T" "$T" "$T" "$T" >> "$WORK/reg.tsv"
printf 'user%szread%s%s/ok.sh%s-%s-%s-%stopic:disks,reads\n' "$T" "$T" "$WORK" "$T" "$T" "$T" "$T" >> "$WORK/reg.tsv"
export HS_REGISTRY=$(wp "$WORK/reg.tsv") HS_LIVE_LOG=$(wp "$WORK/live.log") HS_PLAIN=1 HS_LANG=en HS_CALLER=test
HS="bash $SCRIPTS/lib/hs.sh"
: > "$WORK/live.log"
out=$($HS zok a b); check_eq "a change: the script's output stays" "ran a b" "$out"
check_eq "a change that succeeds asks for its group" "@disks" "$(cat "$WORK/live.log")"
: > "$WORK/live.log"; $HS zfail >/dev/null 2>&1; rc=$?
check_eq "a failed change keeps its exit code" "3" "$rc"
check_eq "...and asks for nothing" "0" "$(grep -c . "$WORK/live.log")"
$HS zplain >/dev/null; check_eq "a change without topic: asks for @system" "@system" "$(cat "$WORK/live.log")"
: > "$WORK/live.log"; $HS zread >/dev/null
check_eq "a read asks for nothing" "0" "$(grep -c . "$WORK/live.log")"

: > "$WORK/live.log"; $HS ext zz go >/dev/null 2>&1
check_eq "an extension change also asks for @ext-<name>" "@system,@ext-zz" "$(paste -sd, "$WORK/live.log")"

echo "-- reads-collect.sh in Redis mode"
if command -v python3 >/dev/null; then
  CALLS=$WORK/calls; : > "$CALLS"
  cat > "$WORK/hs-stub" <<STUB
#!/usr/bin/env bash
shift
echo "\$*" >> "$CALLS"
echo ok
STUB
  printf 'status\t10\nct list\t10\n' > "$WORK/list.tsv"
  printf 'status\tstatus\t15\trun\n' > "$WORK/topics.tsv"
  export HS_COLLECTED_FILE=$WORK/list.tsv HS_BIN=$WORK/hs-stub HS_LIVE_TOPICS=$WORK/topics.tsv HS_STATE_DIR=$(wp "$WORK/state") HS_LOCKED_MARKER=$(wp "$WORK/none")
  mkdir -p "$WORK/state"
  HS_LIVE_SOCKET=/nonexistent/x.sock bash "$SCRIPTS/reads-collect.sh" --all
  check_eq "no live socket: every read runs" "2" "$(grep -c . "$CALLS")"
  : > "$CALLS"
  sock=$WORK/live.sock
  python3 - "$sock" <<'PY' &
import socket, sys, time
s = socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])
s.listen(1)
time.sleep(20)
PY
  pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -S "$sock" ] && break; sleep 0.3; done
  if [ -S "$sock" ]; then
    HS_LIVE_SOCKET=$sock bash "$SCRIPTS/reads-collect.sh" --all
    check_eq "live socket: only the read without a topic runs" "ct list" "$(cat "$CALLS")"
    check_eq "--list still names both" "2" "$(HS_LIVE_SOCKET=$sock bash "$SCRIPTS/reads-collect.sh" --list | grep -c .)"
  else skip "no unix socket on this system"; fi
  kill "$pid" 2>/dev/null
else skip "python3 missing"; fi
finish
