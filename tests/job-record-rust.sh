#!/usr/bin/env bash
# tests/job-record.sh, tests/job-reconcile.sh and tests/jobs-change.sh, unchanged, against the Rust implementation of the job record writer
# (hobnix job-record, issue #137, docs/adr/0001-rust-strangler.md), then scripts/job-record.py and the binary side by side: the same commands
# in two directories; stdout, the last line of stderr, the exit code and every record file must be the same (ids and clock times excepted).
# The binary: HOBNIX_BIN, else rust/target/debug|release/hobnix (cargo build in rust/). Without one, or off Linux, the test is skipped (77).
root=$(cd "$(dirname "$0")/.." && pwd)
bin=${HOBNIX_BIN:-}
if [ -z "$bin" ]; then
  [ "$(uname -s)" = Linux ] || { echo "  skip  needs Linux (WSL) or HOBNIX_BIN"; exit 77; }
  for c in "$root/rust/target/debug/hobnix" "$root/rust/target/release/hobnix"; do [ -x "$c" ] && { bin=$c; break; }; done
fi
[ -n "$bin" ] && [ -x "$bin" ] || { echo "  skip  no hobnix binary (cargo build in rust/, or HOBNIX_BIN)"; exit 77; }
[ "$(uname -s)" = Linux ] || { echo "  skip  needs Linux (flock, /proc, systemd paths)"; exit 77; }
# shellcheck source=tests/lib.sh
. "$root/tests/lib.sh"
unset HOBNIX_LOG HS_CALLER HS_JOBS_DIR HS_JOB_RATE HS_SYSTEMCTL HS_UPTIME_FILE

echo "-- the three job tests against the binary"
tree=$WORK/tree; mkdir -p "$tree/tests"
cp "$root/tests/lib.sh" "$root/tests/job-record.sh" "$root/tests/job-reconcile.sh" "$root/tests/jobs-change.sh" "$tree/tests/"
cp -r "$root/scripts" "$tree/scripts"
# the tests call scripts/job-record.py directly: in this tree it hands over to the binary; hs_job and the scripts use HS_JOB_RECORD/HOBNIX_BIN
printf '#!/usr/bin/env python3\nimport os, sys\nos.execv(%s, [%s, "job-record"] + sys.argv[1:])\n' "'$bin'" "'$bin'" > "$tree/scripts/job-record.py"
for t in job-record job-reconcile jobs-change; do
  if HS_JOB_RECORD=rust HOBNIX_BIN=$bin bash "$tree/tests/$t.sh" > "$WORK/$t.log" 2>&1; then pass "tests/$t.sh passes against Rust"
  else fail "tests/$t.sh against Rust: $(grep -E 'FAIL' "$WORK/$t.log" | head -n 5 | tr '\n' ' ') (log: tail $(tail -n 3 "$WORK/$t.log" | tr '\n' ' '))"; fi
done

echo "-- python and Rust give the same answer"
export HS_JOB_RATE=60 HS_LANG=en
py=$WORK/py; rs=$WORK/rs; ID_py=""; ID_rs=""
cat > "$WORK/systemctl" <<'FAKE'
#!/usr/bin/env bash
# fake systemctl: is-active <unit>
case "$2" in hs-job-alive*) echo active ;; hs-job-wait*) echo activating ;; *) echo inactive; exit 3 ;; esac
FAKE
chmod +x "$WORK/systemctl"
echo "250.5 100.0" > "$WORK/uptime"
norm() {   # ids, clock times and the program name in a message
  sed -E 's/[0-9]{8}-[0-9]{6}-([A-Za-z0-9-]+)-[a-z]{4}/ID:\1/g; s/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z/TIME/g; s/^(job-record|hobnix): /ERR: /'
}
side() {   # side <py|rs> args...  (@ID@ = the id this side got from its last `new`)
  local who=$1 a=() x v; shift
  v=ID_$who
  for x in "$@"; do a+=("${x//@ID@/${!v}}"); done
  if [ "$who" = py ]; then HS_JOBS_DIR=$py python3 "$root/scripts/job-record.py" "${a[@]}"
  else HS_JOBS_DIR=$rs "$bin" job-record "${a[@]}"; fi
}
same() {   # same "label" args...: run on both sides, compare stdout, last stderr line, exit code
  local label=$1 d rc; shift
  for d in py rs; do
    rc=0; side "$d" "$@" > "$WORK/$d.out" 2> "$WORK/$d.err" || rc=$?
    echo "$rc" > "$WORK/$d.rc"
    norm < "$WORK/$d.out" > "$WORK/$d.nout"; tail -n 1 "$WORK/$d.err" | norm > "$WORK/$d.nerr"
  done
  if cmp -s "$WORK/py.nout" "$WORK/rs.nout" && cmp -s "$WORK/py.nerr" "$WORK/rs.nerr" && cmp -s "$WORK/py.rc" "$WORK/rs.rc"; then
    pass "same: $label (exit $(cat "$WORK/py.rc"))"
  else
    fail "differs: $label: python rc $(cat "$WORK/py.rc") [$(tr '\n' '>' < "$WORK/py.nout")] [$(cat "$WORK/py.nerr")] rust rc $(cat "$WORK/rs.rc") [$(tr '\n' '>' < "$WORK/rs.nout")] [$(cat "$WORK/rs.nerr")]"
  fi
}
newboth() {   # newboth label args...: `new` on both sides; the ids go to ID_py/ID_rs
  local label=$1 d; shift
  same "$label" new "$@"
  for d in py rs; do read -r "ID_$d" < "$WORK/$d.out" || true; done
}
files_same() {   # files_same "label": the record file of the current ids, and the file names in both directories
  local label=$1 d
  for d in py rs; do
    v=ID_$d
    norm < "${!d}/${!v}.json" > "$WORK/$d.rec" 2>/dev/null || : > "$WORK/$d.rec"
    (cd "${!d}" && ls -a | norm | sort | tr '\n' ' ') > "$WORK/$d.ls"
    echo "$(stat -c %a "${!d}") $(stat -c %a "${!d}/${!v}.json" 2>/dev/null)" >> "$WORK/$d.ls"
  done
  if cmp -s "$WORK/py.rec" "$WORK/rs.rec" && cmp -s "$WORK/py.ls" "$WORK/rs.ls"; then pass "same files: $label"
  else fail "files differ: $label: $(diff "$WORK/py.rec" "$WORK/rs.rec" | head -n 6 | tr '\n' ' ') $(diff "$WORK/py.ls" "$WORK/rs.ls" | head -n 4 | tr '\n' ' ')"; fi
}

# arguments
same "no words"
same "unknown word" bogus
same "new without --desc" new --slug x
same "new without --slug" new --desc x
same "bad source" new --slug x --desc d --source bogus
same "bad option value" new --slug x --desc -x
same "extra word" run a b
same "step with a word for a number" step 20240101-120000-a-abcd x 1 t
same "cancel with a bad --safe" cancel 20240101-120000-a-abcd --safe maybe
same "cancel without --safe" cancel 20240101-120000-a-abcd
same "bad job id" get nope
same "missing record" get 20240101-120000-gone-abcd
mkdir -p "$py" "$rs"
same "missing record in an existing directory" get 20240101-120000-gone-abcd
same "find-unit with nothing" find-unit hs-job-x-1

newboth "new, all flags" --slug "Pool/Sync!! x" --desc "Café — ü \"quoted\" tab	end" --unit hs-job-pool-sync-1 --source web --initiator alice
files_same "after new"
same "get" get @ID@
same "cancelled on a queued job" cancelled @ID@
same "find-unit with .service" find-unit hs-job-pool-sync-1.service
same "find-unit without .service" find-unit hs-job-pool-sync-1
same "find-unit of another unit" find-unit hs-job-other
same "run" run @ID@
same "step" step @ID@ 1 3 "first"
same "step, rate limited" step @ID@ 2 3 "dropped"
same "step, last of all" step @ID@ 3 3 "last"
same "progress" progress @ID@ 5 10 files
same "progress, rate limited" progress @ID@ 6 10 files
same "progress, done" progress @ID@ 10 10 files
files_same "after steps"
same "finish 3" finish @ID@ 3
files_same "after finish 3"
same "finish 0 again" finish @ID@ 0
files_same "after finish 0"
same "cancel a finished job" cancel @ID@ --by bob --safe yes
same "find-unit of a finished job" find-unit hs-job-pool-sync-1

newboth "new, defaults" --slug '!!!' --desc ""
files_same "after new with defaults"
newboth "new, abbreviated and = flags" --sl=eq --de "d" --un u1 --so timer --in ""
files_same "after new, abbreviated"
same "step, negative numbers" step @ID@ -1 -2 "neg"
same "step, spaces and underscores" step @ID@ " 7 " 1_0 "t"
same "finish, with underscores" finish @ID@ 1_0
files_same "after finish 1_0"

newboth "new for cancel" --slug stopme --desc "stop me" --unit hs-job-stop-1 --initiator carol
same "run before cancel" run @ID@
same "cancel" cancel @ID@ --by bob --safe no
same "cancelled on a cancelled job" cancelled @ID@
files_same "after cancel"
same "finish after cancel" finish @ID@ 143
files_same "after finish of a cancelled job"
same "cancel twice" cancel @ID@ --by bob --safe yes
newboth "new, cancel without --by" --slug stopme2 --desc "again"
same "cancel without --by" cancel @ID@ --safe yes
files_same "after cancel without --by"

# records that are not records
for d in py rs; do
  printf '{oops' > "${!d}/20240101-120000-badjson-abcd.json"
  printf '[1, 2]' > "${!d}/20240101-120000-array-abcd.json"
done
same "get invalid JSON" get 20240101-120000-badjson-abcd
same "get a JSON array" get 20240101-120000-array-abcd
same "run invalid JSON" run 20240101-120000-badjson-abcd
same "cancelled on invalid JSON" cancelled 20240101-120000-badjson-abcd
same "cancel a JSON array" cancel 20240101-120000-array-abcd --safe yes
rm -f "$py"/*badjson* "$py"/*array* "$rs"/*badjson* "$rs"/*array*

# reconcile: a unit that is gone, one that is alive, one that is activating, one that began after boot, a record that is not one
export HS_SYSTEMCTL="$WORK/systemctl" HS_UPTIME_FILE=$WORK/uptime
rm -rf "$py" "$rs"; mkdir -p "$py" "$rs"
declare -A IDP IDR
for n in a-gone b-alive c-wait d-fresh e-queued; do
  case $n in a-gone) u=hs-job-gone-1 ;; b-alive) u=hs-job-alive-1 ;; c-wait) u=hs-job-wait-1 ;; d-fresh) u=hs-job-gone-2 ;; *) u=hs-job-gone-3 ;; esac
  newboth "reconcile setup $n" --slug "$n" --desc "job $n
second line" --unit "$u"
  [ "$n" = e-queued ] || same "run $n" run @ID@
  [ "$n" != a-gone ] && [ "$n" != b-alive ] || same "step $n" step @ID@ 1 2 "half"
  if [ "$n" != d-fresh ]; then   # began long before this boot
    for d in py rs; do v=ID_$d; sed -i -E 's/"(queued|started)": "[^"]*"/"\1": "2000-01-01T00:00:00Z"/' "${!d}/${!v}.json"; done
  fi
  IDP[$n]=$ID_py; IDR[$n]=$ID_rs
done
for d in py rs; do printf '{}' > "${!d}/garbage.json"; done
same "reconcile" reconcile
for n in a-gone b-alive c-wait d-fresh e-queued; do
  ID_py=${IDP[$n]}; ID_rs=${IDR[$n]}
  files_same "after reconcile: $n"
done
same "reconcile again" reconcile
rm -f "$py/garbage.json" "$rs/garbage.json"
same "reconcile, nothing left to do" reconcile
export HS_UPTIME_FILE=$WORK/missing
same "reconcile without an uptime file" reconcile
rm -rf "$py" "$rs"
same "reconcile without a directory" reconcile
finish
