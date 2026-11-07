#!/usr/bin/env bash
# hs docker import (scripts/docker-import.sh, scripts/lib/docker_import.py): the analyzer on fixtures, and the script with a fake incus (config JSON
# from a fixture) and a fake docker-app-change.sh (records what it is called with). No Docker, no root.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! have python3; then skip "python3 missing"; finish; exit 0; fi
export HS_LANG=en HS_PLAIN=1
echo "-- docker import analyzer"
if out=$(python3 -I "$ROOT/tests/docker-import-test.py" 2>&1); then pass "docker import analyzer tests ($(grep -E '^Ran ' <<<"$out"))"; else fail "docker import analyzer tests: $(tail -n 25 <<<"$out")"; fi

echo "-- docker import script"
BIN=$WORK/bin; mkdir -p "$BIN"
export FIX=$WORK/config.json ROUTE_LOG=$WORK/route.log
: > "$ROUTE_LOG"
cat > "$BIN/incus" <<'FAKE'
#!/usr/bin/env bash
cat >/dev/null
cat "$FIX"
FAKE
cat > "$BIN/route" <<'FAKE'
#!/usr/bin/env bash
doc=$(cat | tr '\0\n' '|~')
echo "$* :: $doc" >> "$ROUTE_LOG"
case "$1" in plan) printf 'status\tok\n' ;; start) printf 'status\tdone\n' ;; esac
FAKE
chmod +x "$BIN/incus" "$BIN/route"
export HS_INCUS=$BIN/incus HS_DOCKER_APP_CHANGE=$BIN/route HS_DOCKER_SKIP_CHECK=1 HS_DOCKER_APPS_ROOT=/shares/apps
IMP="bash $ROOT/scripts/docker-import.sh"
printf 'services:\n  web:\n    image: nginx\n' > "$WORK/c.yml"
printf 'DB_PASSWORD=hunter2-secret\n' > "$WORK/e.env"
D=/shares/apps/stacks/demo
cat > "$WORK/clean.json" <<J
{"services":{"web":{"image":"nginx","ports":[{"target":80,"published":"8080","protocol":"tcp"}],"environment":{"DB_PASSWORD":"hunter2-secret"},"volumes":[{"type":"bind","source":"$D/data","target":"/d"}]}}}
J
cat > "$WORK/risky.json" <<J
{"services":{"web":{"image":"nginx","network_mode":"host"}}}
J
cat > "$WORK/sock.json" <<J
{"services":{"web":{"image":"nginx","volumes":[{"type":"bind","source":"/var/run/docker.sock","target":"/s","read_only":true}]}}}
J
runi() { "$@" </dev/null 2>&1; }

cp "$WORK/clean.json" "$FIX"
out=$(runi $IMP "$WORK/c.yml" --name demo --env-file "$WORK/e.env" --dry-run) && rc=0 || rc=$?
check_eq "dry-run of a clean app exits 0" 0 "$rc"
check_out "dry-run prints the plan (port, bind, env name)" '8080:80/tcp.*' echo "$out"
grep -q 'DB_PASSWORD' <<<"$out" && pass "env name shown" || fail "env name missing"
grep -q 'hunter2-secret' <<<"$out" && fail "an env value was printed" || pass "env values never printed"
grep -q '^start ' "$ROUTE_LOG" && fail "dry-run started the route" || pass "dry-run starts nothing"

out=$(runi $IMP "$WORK/c.yml" --name demo) && rc=0 || rc=$?
check_eq "no --yes and no terminal refuses" 1 "$rc"
grep -q '^start ' "$ROUTE_LOG" && fail "start without confirmation" || pass "nothing started without confirmation"

out=$(runi $IMP "$WORK/c.yml" --name demo --yes --confirm wrong) && rc=0 || rc=$?
check_eq "wrong --confirm refuses" 1 "$rc"
grep -q '^start ' "$ROUTE_LOG" && fail "start with wrong confirm" || pass "wrong confirm starts nothing"

out=$(runi $IMP "$WORK/c.yml" --name demo --env-file "$WORK/e.env" --yes --confirm demo) && rc=0 || rc=$?
check_eq "--yes --confirm <app> imports" 0 "$rc"
check "route got start app-save --rev new with the env as a * record" grep -q 'start demo app-save --rev new :: services:.*|\*DB_PASSWORD=hunter2-secret' "$ROUTE_LOG"
grep -q 'hunter2-secret' <<<"$out" && fail "env value in the output" || pass "env value not in the output"

: > "$ROUTE_LOG"
cp "$WORK/risky.json" "$FIX"
out=$(runi $IMP "$WORK/c.yml" --name demo --yes --confirm demo) && rc=0 || rc=$?
check_eq "risky without --allow-risky refuses" 1 "$rc"
check_out "risky refusal names the flag" 'allow-risky' echo "$out"
out=$(runi $IMP "$WORK/c.yml" --name demo --dry-run) && rc=0 || rc=$?
check_eq "risky dry-run without --allow-risky exits 1" 1 "$rc"
out=$(runi $IMP "$WORK/c.yml" --name demo --yes --confirm demo --allow-risky) && rc=0 || rc=$?
check_eq "risky with --allow-risky and the name imports" 0 "$rc"
check "risky import reached the route" grep -q '^start demo' "$ROUTE_LOG"

: > "$ROUTE_LOG"
cp "$WORK/sock.json" "$FIX"
out=$(runi $IMP "$WORK/c.yml" --name demo --yes --confirm demo --allow-risky) && rc=0 || rc=$?
check_eq "refuse-level (docker.sock) refuses even with --allow-risky" 1 "$rc"
grep -q '^start ' "$ROUTE_LOG" && fail "refuse-level reached the route" || pass "refuse-level never reaches the route"

out=$(runi $IMP "$WORK/c.yml" --name 'Bad Name' --dry-run) && rc=0 || rc=$?
check_eq "an invalid app name refuses" 1 "$rc"
finish
