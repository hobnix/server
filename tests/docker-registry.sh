#!/usr/bin/env bash
# scripts/docker-registry-change.sh and scripts/lib/docker-auth.sh: registry logins for Docker. Fake vault (HS_VAULT_DIR), fake incus that
# records argv and stdin, no root. The token must never be in argv, the environment, the output or the tsv.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1
BIN=$WORK/bin; mkdir -p "$BIN"
export HS_STATE_DIR=$WORK/state HS_VAULT_DIR=$WORK/vault
mkdir -p "$HS_STATE_DIR" "$HS_VAULT_DIR"
export LOG=$WORK/incus.log INLOG=$WORK/incus-stdin.log
: > "$LOG"; : > "$INLOG"
SECRET=ghp_TESTtokenSECRET0123456789abcdefghij

# Fake incus: records argv; stdin of every exec goes to INLOG; `config --images` answers with a private and a public image;
# a login with the token WRONGTOKEN fails.
cat > "$BIN/incus" <<'FAKE'
#!/usr/bin/env bash
echo "incus $*" >> "$LOG"
case "$1" in
  exec)
    case "$*" in
      *"config --images"*) printf 'ghcr.io/me/app:1\nnginx:latest\n' ;;
      *hs_auth_login*)   # the script of docker_with_auth runs for real, here, with the fake docker
        shift 3; "$@" ;;
      *)
        in=$(cat)
        printf '%s\n' "$in" >> "$INLOG"
        case "$in" in *WRONGTOKEN*) exit 1 ;; esac ;;
    esac ;;
esac
exit 0
FAKE
# Fake docker.sh: Docker is on and running; the app "paperless" uses ghcr.io
cat > "$BIN/docker.sh" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  --status) printf 'state\ton\nrunning\tyes\n' ;;
  --apps) printf 'paperless\tdocker\tpaperless\trunning\t1/1\t8000\t10.0.0.5\tghcr.io/me/app:1,nginx:latest\tweb\t-\n' ;;
esac
FAKE
# Fake docker (inside the "container"): records login and compose; a login reads the token from stdin
cat > "$BIN/docker" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  login) tok=$(cat); printf '%s' "$tok" > "$WORK/docker-tok"; echo "$* CFG=${DOCKER_CONFIG:-}" >> "$DLOG"; [ -d "${DOCKER_CONFIG:-/nonexistent}" ] && [ "$tok" != WRONGTOKEN ] ;;
  compose) echo "$* CFG=${DOCKER_CONFIG:-} PWD=$PWD" >> "$DLOG" ;;
esac
FAKE
# mktemp for /run/hs-auth.XXXX: the template moves into the test directory
cat > "$BIN/mktemp" <<'FAKE'
#!/usr/bin/env bash
exec /usr/bin/mktemp -d "$WORK/auth.XXXXXX"
FAKE
chmod +x "$BIN/incus" "$BIN/docker.sh" "$BIN/docker" "$BIN/mktemp"
export WORK DLOG=$WORK/docker.log; : > "$DLOG"; mkdir -p "$WORK/app"
export PATH="$BIN:$PATH" HS_DOCKER_SH=$BIN/docker.sh
R="bash $SCRIPTS/docker-registry-change.sh"
T=$'\t'

echo "-- without a vault: add stores the token in a plain 0600 file"
out=$(printf '%s\n' "$SECRET" | $R start add ghcr.io --user wolf 2>&1) || true
echo "$out" | grep -qx "status${T}done" && pass "add done" || fail "add: $out"
check_eq "tsv" "ghcr.io${T}wolf" "$(cat "$HS_STATE_DIR/docker-registries.tsv")"
check_eq "token file" "$SECRET" "$(cat "$HS_STATE_DIR/docker-registry-ghcr.io")"
check_eq "token mode" "600" "$(stat -c %a "$HS_STATE_DIR/docker-registry-ghcr.io")"
grep -q "$SECRET" "$HS_STATE_DIR/docker-registries.tsv" && fail "token in the tsv" || pass "token not in the tsv"
grep -q "$SECRET" "$LOG" && fail "token in argv" || pass "token not in argv"
grep -q "$SECRET" "$INLOG" && pass "token went on stdin" || fail "token not on stdin"
echo "$out" | grep -q "$SECRET" && fail "token in output" || pass "token not in output"

echo "-- list shows host, user, state, used by; never the token"
out=$($R --list 2>&1)
check_eq "list row" "ghcr.io${T}wolf${T}ok${T}paperless" "$out"
out=$($R list 2>&1)
echo "$out" | grep -q "$SECRET" && fail "token in list" || pass "token not in list"

echo "-- a wrong token is refused and nothing is stored"
rm -f "$HS_STATE_DIR"/docker-registr*
out=$(printf 'WRONGTOKEN\n' | $R start add ghcr.io --user wolf 2>&1) && rc=0 || rc=$?
check_eq "wrong token exit" 1 "$rc"
[ ! -e "$HS_STATE_DIR/docker-registries.tsv" ] && pass "no tsv written" || fail "tsv written"

echo "-- plan: bad shapes"
for b in "plan add Bad_Host --user wolf" "plan add ghcr.io --user" "plan add ghcr.io --user -x" "plan remove nothere.io"; do
  rc=0; out=$($R $b </dev/null 2>&1) || rc=$?
  check_eq "refused: $b" 1 "$rc"
done

echo "-- with a vault: the token goes into it, a closed vault refuses"
echo uuid > "$HS_STATE_DIR/vault-uuid"
export HS_VAULT_OPEN=1
out=$(printf '%s\n' "$SECRET" | $R start add ghcr.io --user wolf 2>&1) || true
echo "$out" | grep -qx "status${T}done" && pass "vault add done" || fail "vault add: $out"
[ -L "$HS_STATE_DIR/docker-registry-ghcr.io" ] && pass "token is a link into the vault" || fail "no link"
check_eq "token in the vault" "$SECRET" "$(cat "$HS_VAULT_DIR/secrets/docker-registry-ghcr.io")"
unset HS_VAULT_OPEN
mv "$HS_VAULT_DIR/secrets" "$HS_VAULT_DIR/secrets.away"      # a closed vault: the link dangles
check_eq "closed: state locked" "ghcr.io${T}wolf${T}locked${T}paperless" "$($R --list 2>&1)"
rc=0; out=$($R plan add other.io --user wolf </dev/null 2>&1) || rc=$?
check_eq "closed: plan add refused" 1 "$rc"
echo "$out" | grep -qx "fix${T}hs vault open" && pass "closed: fix hs vault open" || fail "closed fix: $out"

mv "$HS_VAULT_DIR/secrets.away" "$HS_VAULT_DIR/secrets"
echo "-- docker_with_auth: the token only on stdin, a throwaway DOCKER_CONFIG"
: > "$LOG"; : > "$INLOG"
export HS_VAULT_OPEN=1
(
  . "$SCRIPTS/lib/ui.sh"; . "$SCRIPTS/lib/docker-auth.sh"
  DOCKER_AUTH_DIR=$WORK/app docker_with_auth paperless pull
) >/dev/null 2>&1 || true
check_eq "exactly one login for one registry (the last line is read too)" 1 "$(grep -c '^login ' "$DLOG")"
grep -q '^login -u wolf --password-stdin ghcr.io CFG='"$WORK"'/auth\.' "$DLOG" && pass "login with a throwaway DOCKER_CONFIG" || fail "login line: $(cat "$DLOG")"
grep -q "$SECRET" "$DLOG" && fail "token in the docker argv" || pass "token not in the docker argv"
grep -q "^compose -p paperless pull CFG=$WORK/auth\." "$DLOG" && pass "compose runs with that DOCKER_CONFIG" || fail "compose line: $(cat "$DLOG")"
grep -q "PWD=$WORK/app" "$DLOG" && pass "compose runs in the app directory" || fail "compose dir"
[ -z "$(ls -d "$WORK"/auth.* 2>/dev/null)" ] && pass "the throwaway config is removed" || fail "throwaway config left"
grep -q 'EXIT HUP INT TERM' "$LOG" && pass "cleanup trap also on HUP INT TERM" || fail "trap signals"
unset HS_VAULT_OPEN
grep -q "$SECRET" "$LOG" && fail "with_auth: token in argv" || pass "with_auth: token not in argv"
check_eq "with_auth: the token reached docker login on stdin" "$SECRET" "$(cat "$WORK/docker-tok" 2>/dev/null)"
grep -q 'mktemp -d /run/hs-auth' "$LOG" && grep -q 'DOCKER_CONFIG' "$LOG" && grep -q 'rm -rf' "$LOG" && pass "with_auth: throwaway config" || fail "with_auth config"
grep -q '/root/.docker' "$LOG" && fail "with_auth touched /root/.docker" || pass "/root/.docker untouched"

echo "-- docker_with_auth with a closed vault runs nothing"
mv "$HS_VAULT_DIR/secrets" "$HS_VAULT_DIR/secrets.away"
: > "$LOG"
rc=0; ( . "$SCRIPTS/lib/ui.sh"; . "$SCRIPTS/lib/docker-auth.sh"; docker_with_auth paperless pull ) >/dev/null 2>&1 || rc=$?
check_eq "closed: with_auth fails" 1 "$rc"
grep -q 'hs_auth_login' "$LOG" && fail "closed: compose ran" || pass "closed: compose did not run"

mv "$HS_VAULT_DIR/secrets.away" "$HS_VAULT_DIR/secrets"
echo "-- the token is not in the environment of the script"
env | grep -q "$SECRET" && fail "token in env" || pass "token not in env"

echo "-- remove with a closed vault is refused and the token stays"
mv "$HS_VAULT_DIR/secrets" "$HS_VAULT_DIR/secrets.away"
rc=0; out=$($R start remove ghcr.io --confirm ghcr.io </dev/null 2>&1) || rc=$?
check_eq "closed: remove refused" 1 "$rc"
echo "$out" | grep -qx "fix${T}hs vault open" && pass "closed: remove says hs vault open" || fail "remove fix: $out"
[ -L "$HS_STATE_DIR/docker-registry-ghcr.io" ] && pass "closed: the link is kept" || fail "link dropped"
check_eq "closed: the tsv keeps the entry" "ghcr.io${T}wolf" "$(cat "$HS_STATE_DIR/docker-registries.tsv")"
rc=0; $R remove ghcr.io --yes </dev/null >/dev/null 2>&1 || rc=$?
check_eq "closed: hs docker registry remove refused" 1 "$rc"
mv "$HS_VAULT_DIR/secrets.away" "$HS_VAULT_DIR/secrets"
echo "-- remove needs the typed host"
rc=0; out=$($R start remove ghcr.io </dev/null 2>&1) || rc=$?
check_eq "remove without confirm refused" 1 "$rc"
export HS_VAULT_OPEN=1
rc=0; out=$($R start remove ghcr.io --confirm ghcr.io </dev/null 2>&1) || rc=$?
unset HS_VAULT_OPEN
check_eq "remove with confirm" 0 "$rc"
[ ! -e "$HS_STATE_DIR/docker-registry-ghcr.io" ] && [ ! -e "$HS_VAULT_DIR/secrets/docker-registry-ghcr.io" ] && pass "token deleted" || fail "token kept"
check_eq "tsv empty" "" "$(cat "$HS_STATE_DIR/docker-registries.tsv" 2>/dev/null)"

echo "passed $T_PASS, failed $T_FAIL"
[ "$T_FAIL" -eq 0 ]
