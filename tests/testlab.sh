#!/usr/bin/env bash
# The test-lab (scripts/testlab.sh, scripts/testlab-change.sh) against stand-ins for git, the nested harness (nested.sh, build-iso.sh), incus,
# notify.sh and systemd-run. No Incus, KVM or nix, no root. The real harness was never run here: Not tested on hardware yet.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en HS_EVENT_NOROOT=1
B=$WORK/fake; mkdir -p "$B/bin" "$B/tree/scripts/dev"
export HS_TESTLAB_DIR=$B/state HS_STATE_DB=$B/state.db HS_JOBS_DIR=$B/jobs HS_CAPABILITIES_FILE=$B/caps
export HS_TESTLAB_GIT=$B/git HS_NESTED_INCUS=$B/incus HS_NOTIFY=$B/notify.sh HS_SETTINGS_DIR=$B/settings
export HS_STATE_DIR=$B/hsstate
mkdir -p "$B/jobs" "$B/settings" "$B/hsstate"
printf 'testlab\n' > "$B/caps"
T="bash $SCRIPTS/testlab.sh"
C="bash $SCRIPTS/testlab-change.sh"

cat > "$B/git" <<'FAKE'
#!/usr/bin/env bash
# the stand-in: logs every call; checkout copies the fixture tree
dir=$(dirname "$0"); args=("$@"); i=0; wd=
while [ $i -lt ${#args[@]} ]; do
  case "${args[$i]}" in -c) i=$((i + 2)) ;; -C) wd=${args[$((i + 1))]}; i=$((i + 2)) ;; *) break ;; esac
done
sub=${args[$i]}; rest=("${args[@]:$((i + 1))}")
echo "$sub ${rest[*]}" >> "$dir/git.log"
case "$sub" in
  init) mkdir -p "$wd/.git" ;;
  checkout) cp -r "$dir/tree/." "$wd/" ;;
  rev-parse) echo 0123456789abcdef0123456789abcdef01234567 ;;
  fetch) [ -z "${FAKE_FETCH_FAIL:-}" ] || exit 128 ;;
esac
exit 0
FAKE
cat > "$B/tree/scripts/dev/nested.sh" <<'FAKE'
#!/usr/bin/env bash
# preflight | run --stage iso|all --name <vm>; FAKE_PREFLIGHT_RC, FAKE_MODE ok|iso-fail|smoke-fail
root=$(cd "$(dirname "$0")/../.." && pwd)
b=${FAKE_DIR:?}
[ "$1" != preflight ] || exit "${FAKE_PREFLIGHT_RC:-0}"
echo "nested $*" >> "$b/nested.log"
d=$root/.work/nested/run1; mkdir -p "$d"; ln -sfn run1 "$root/.work/nested/latest"
echo secret > "$d/password"; echo key > "$d/key"
case "${FAKE_MODE:-ok}" in
  iso-fail) echo '{"stage":"iso","ok":false}' > "$d/result-iso.json"; exit 1 ;;
  *) echo '{"stage":"iso","ok":true}' > "$d/result-iso.json" ;;
esac
[ "${3:-}" != iso ] && [ "$2" != iso ] || exit 0
case "${FAKE_MODE:-ok}" in
  smoke-fail) echo '{"stage":"smoke","ok":false}' > "$d/result-smoke.json"; exit 1 ;;
  *) echo '{"stage":"smoke","ok":true}' > "$d/result-smoke.json" ;;
esac
exit 0
FAKE
cat > "$B/tree/scripts/dev/build-iso.sh" <<'FAKE'
#!/usr/bin/env bash
echo build >> "${FAKE_DIR:?}/build.log"; [ -z "${FAKE_BUILD_FAIL:-}" ] || exit 1; mkdir -p result-iso; exit 0
FAKE
cat > "$B/incus" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$(dirname "$0")/incus.log"
FAKE
cat > "$B/notify.sh" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$(dirname "$0")/notify.log"
FAKE
cat > "$B/bin/systemd-run" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$(dirname "$0")/../systemd-run.log"
FAKE
chmod +x "$B/git" "$B/incus" "$B/notify.sh" "$B/bin/systemd-run" "$B/tree/scripts/dev/"*.sh
export FAKE_DIR=$B PATH="$B/bin:$PATH"

reset() { rm -rf "$B/state" "$B"/*.log "$B/state.db" "$B/jobs"/*; unset FAKE_MODE FAKE_PREFLIGHT_RC FAKE_FETCH_FAIL FAKE_BUILD_FAIL; }
lastrun() { ls -1 "$B/state/runs" | tail -n1; }
res() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["result"])' "$B/state/runs/$(lastrun)/stage-$1.json"; }
events() { python3 "$SCRIPTS/state-db.py" event-list 2>/dev/null | awk -F'\t' '{print $4}' | tr '\n' ' '; }
nlog() { cat "$B/$1.log" 2>/dev/null || true; }

echo "-- the capability is off by default"
printf '' > "$B/caps"
check_out "refused while off" "test-lab is off" $T run --dry-run
check_out "also the results" "test-lab is off" $T results
printf 'testlab\n' > "$B/caps"

echo "-- only Hobnix repositories and plain refs"
reset
for bad in refs/pull/12/head pull/12/head -x '../x' 'a..b' 'a b' 'refs/heads/main' 'x.lock' 'a//b'; do
  out=$($T run --ref "$bad" --dry-run 2>&1); rc=$?
  check_eq "ref '$bad' is refused (exit $rc)" "1" "$rc"
done
for url in https://github.com/evil/server.git http://github.com/hobnix/server.git https://github.com.evil.example/hobnix/server.git \
           'https://github.com/hobnix/../evil/x' https://user@github.com/hobnix/server.git git@github.com:hobnix/server.git /tmp/repo 'https://github.com/hobnix/'; do
  out=$(HS_TESTLAB_REPO=$url $T run --dry-run 2>&1); rc=$?
  check_eq "repository '$url' is refused" "1" "$rc"
done
for ok in develop v0.1.0 feature/430-testlab 0123456789abcdef0123456789abcdef01234567; do
  check "ref '$ok' is accepted" $T run --ref "$ok" --dry-run
done
check "another Hobnix repository is accepted" env HS_TESTLAB_REPO=https://github.com/hobnix/recipes.git $T run --dry-run
check_eq "none of it fetched anything" "" "$(nlog git)"

echo "-- the plan"
out=$($T run --dry-run 2>&1); rc=$?
check_eq "dry run exits 0" "0" "$rc"
check_out "names the ref" "Ref +develop" echo "$out"
check_out "names both stages" "Stages +1 \(install\) and 2" echo "$out"
check_out "says nothing was done" "Dry run: nothing was fetched" echo "$out"
check_out "stage 1 alone" "Stages +1 \(the ISO boots" $T run --stage 1 --dry-run
check_out "a stage that does not exist" "usage" $T run --stage 3 --dry-run
check_eq "the dry run changed nothing" "" "$(nlog git)$(ls "$B/state" 2>/dev/null)"
check_out "no terminal and no --yes: nothing starts" "without --yes" $T run

echo "-- a run that passes"
reset
out=$($T run --yes --foreground 2>&1); rc=$?
check_eq "exit 0" "0" "$rc"
check_eq "stage 1 ok" "ok" "$(res 1)"
check_eq "stage 2 ok" "ok" "$(res 2)"
check_out "fetched the ref, shallow, from the Hobnix repository" "fetch -q --depth 1 origin develop" cat "$B/git.log"
check_out "with that address" "remote add origin https://github.com/hobnix/server.git" cat "$B/git.log"
check_out "built the ISO once" "build" cat "$B/build.log"
check_out "ran the whole harness in a named VM" "nested run --stage all --name hs-testlab-" cat "$B/nested.log"
check_out "deleted the VM afterwards" "delete -f hs-testlab-" cat "$B/incus.log"
check_eq "no push message for a pass" "" "$(nlog notify)"
check_out "events: started and ok" "started ok" echo "$(events)"
check_out "the log is kept" "Result" cat "$B/state/runs/$(lastrun)/run.log"
check_eq "the throwaway password and key are not kept" "0" "$(ls "$B/state/runs/$(lastrun)/harness" | grep -cE '^(password|key)$')"
check_out "the stage file has the commit" '"commit": "0123456789abcdef' cat "$B/state/runs/$(lastrun)/stage-1.json"

echo "-- stage 1 only"
reset
$T run --stage 1 --yes --foreground >/dev/null 2>&1; rc=$?
check_eq "exit 0" "0" "$rc"
check_out "the harness only runs the ISO stage" "stage iso" cat "$B/nested.log"
check_eq "no stage 2 file" "no" "$([ -f "$B/state/runs/$(lastrun)/stage-2.json" ] && echo yes || echo no)"

echo "-- stage 2 fails"
reset; export FAKE_MODE=smoke-fail
$T run --yes --foreground >/dev/null 2>&1; rc=$?
check_eq "exit 1" "1" "$rc"
check_eq "stage 1 ok" "ok" "$(res 1)"
check_eq "stage 2 failed" "failed" "$(res 2)"
check_out "a push message names the stage" "problem Test-lab failed Stage 2" cat "$B/notify.log"
check_out "event failed" "started failed" echo "$(events)"
check_out "the VM is still deleted" "delete -f hs-testlab-" cat "$B/incus.log"

echo "-- stage 1 fails: stage 2 is skipped"
reset; export FAKE_MODE=iso-fail
$T run --yes --foreground >/dev/null 2>&1; rc=$?
check_eq "exit 1" "1" "$rc"
check_eq "stage 1 failed" "failed" "$(res 1)"
check_eq "stage 2 skipped" "skipped" "$(res 2)"

echo "-- this machine cannot run nested VMs"
reset; export FAKE_PREFLIGHT_RC=3
$T run --yes --foreground >/dev/null 2>&1; rc=$?
check_eq "exit 3" "3" "$rc"
check_eq "both stages skipped" "skipped skipped" "$(res 1) $(res 2)"
check_eq "no ISO was built" "" "$(nlog build)"
check_eq "a skip sends no push message" "" "$(nlog notify)"
check_out "event skipped" "started skipped" echo "$(events)"

echo "-- infrastructure errors"
reset; export FAKE_FETCH_FAIL=1
$T run --yes --foreground >/dev/null 2>&1; rc=$?
check_eq "a failed fetch is exit 4" "4" "$rc"
check_eq "stage 1 error" "error" "$(res 1)"
check_out "and a push message" "Test-lab failed" cat "$B/notify.log"
reset; export FAKE_BUILD_FAIL=1
$T run --yes --foreground >/dev/null 2>&1; rc=$?
check_eq "a failed ISO build is exit 4" "4" "$rc"
check_eq "the harness did not start" "" "$(nlog nested)"

echo "-- a run at the same time"
reset; mkdir -p "$B/state"
if have flock; then
  ( exec 8>"$B/state/lock"; flock -n 8; check_out "refused while the lock is held" "Another test-lab run" $T run --yes --foreground )
fi

echo "-- background and the job"
reset
out=$($T run --yes --background 2>&1); rc=$?
check_eq "starts and exits 0" "0" "$rc"
check_out "the job runs the command in the foreground with --yes" "testlab.sh run --ref develop --stage all --yes --foreground" cat "$B/systemd-run.log"
check_out "named after the command" "description=hs testlab run develop" cat "$B/systemd-run.log"
check_eq "nothing was fetched by the starter" "" "$(nlog git)"

echo "-- only the last runs are kept"
reset
for _ in 1 2 3; do HS_TESTLAB_KEEP=2 $T run --stage 1 --yes --foreground >/dev/null 2>&1; sleep 1; done
check_eq "two run folders" "2" "$(ls "$B/state/runs" | wc -l | tr -d ' ')"

echo "-- results"
reset
check_out "empty" "No test-lab run yet" $T results
check_eq "empty list" "" "$($T results --list)"
$T run --yes --foreground >/dev/null 2>&1
lines=$($T results --list)
check_eq "two lines for one run" "2" "$(wc -l <<<"$lines" | tr -d ' ')"
check_out "tab separated: run, stage, result, exit, ref, commit" $'^[0-9-]+\t1\tok\t0\tdevelop\t0123456789abcdef' echo "$lines"
have column && check_out "a table for people" "Result" $T results

echo "-- the web route (testlab-change.sh)"
reset
out=$($C plan run 2>&1); rc=$?
check_eq "plan exits 0" "0" "$rc"
check_out "status ok" "^status.ok" echo "$out"
check_out "long" "^long.yes" echo "$out"
check_out "names the command" "^command.hs testlab run --ref develop --stage all" echo "$out"
out=$($C plan run --ref refs/pull/1/head 2>&1); rc=$?
check_eq "a pull request ref is refused" "1" "$rc"
check_out "with a reason" "^status.refused" echo "$out"
out=$($C start run --ref develop --stage 1 2>&1); rc=$?
check_eq "start exits 0" "0" "$rc"
check_out "started with a unit" "^status.started" echo "$out"
check_out "unit" "^unit.hs-job-testlab-" echo "$out"
check_out "the job is the foreground run of stage 1" "ref develop --stage 1 --yes --foreground" cat "$B/systemd-run.log"
check_out "an unknown action is refused" "^status.refused" $C start nope
printf '' > "$B/caps"
check_out "refused while the capability is off" "capability testlab" $C start run
printf 'testlab\n' > "$B/caps"

echo "-- wiring"
check_out "the web accepts only run with ref and stage" '"testlab": \[\{"fixed": \[r"\^run\$"\]' cat "$SCRIPTS/web-serve.py"
check_out "the nightly unit starts a background run on develop" "testlab.sh run --ref develop --stage all --yes --background" cat "$ROOT/capabilities/testlab/module.nix"
check_out "the timer exists only with testlabNightly" "mkIf hs.machine.testlabNightly" cat "$ROOT/capabilities/testlab/module.nix"
check_out "the capability is off by default" "default = 'false'" grep -A8 'key = "testlabNightly"' "$ROOT/config/schema.toml"

finish
