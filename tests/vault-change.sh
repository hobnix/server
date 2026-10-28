#!/usr/bin/env bash
# hs sys secrets plan|start (scripts/vault-change.sh): header backup, move, close (red) and root-only permissions of the secrets.
# Fake vault.sh and secrets.sh stand in: no LUKS, no vault. HS_VAULT_STATE picks the state the fake vault reports.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en
unset HS_CALLER HS_GUIDED_TTY
T=$'\t'
cat > "$WORK/vault.sh" <<FAKE
#!/usr/bin/env bash
case "\$1" in usage) [ "\$HS_VAULT_STATE" = none ] || printf 'state${T}%s\n' "\$HS_VAULT_STATE" ;; esac
FAKE
cp "$WORK/vault.sh" "$WORK/secrets.sh"
export HS_VAULT=$WORK/vault.sh HS_SECRETS=$WORK/secrets.sh
# a stand-in for the job runner: remember the command instead of starting a unit
mkdir -p "$WORK/lib"; cp "$SCRIPTS/lib/"*.sh "$WORK/lib/" 2>/dev/null || true
printf 'hs_job() { shift 3; echo "JOB $*" >> "%s"; echo hs-job-test-1; }\n' "$WORK/jobs" > "$WORK/lib/job.sh"
cp "$SCRIPTS/vault-change.sh" "$WORK/vault-change.sh"
run() { rc=0; out=$(timeout 20 bash "$WORK/vault-change.sh" "$@" </dev/null 2>/dev/null) || rc=$?; }
has() { grep -q -- "$1" <<<"$out"; }
: > "$WORK/jobs"

export HS_VAULT_STATE=open
run plan header-backup; check_eq "header-backup plan: exit 0" 0 "$rc"
has "^command${T}hs vault header-backup" && pass "names the command" || fail "$out"
has "^confirm_name" && fail "a header backup is not red" || pass "no typed word"
run plan move; check_eq "move plan: exit 0" 0 "$rc"
run plan move restic-password; check_eq "move one by name: exit 0" 0 "$rc"
has "restic-password" && pass "names the secret" || fail "$out"
run plan move 'a b'; check_eq "a bad name is refused" 1 "$rc"
run plan close; check_eq "close plan: exit 0" 0 "$rc"
has "^confirm_name${T}close" && pass "close asks for the word" || fail "$out"
has "^danger" && pass "close is red" || fail "$out"
run start close; check_eq "close without the word: refused" 1 "$rc"
run start close --confirm nope; check_eq "wrong word: refused" 1 "$rc"
run start close --confirm close; check_eq "right word: started" 0 "$rc"
has "^status${T}started" && pass "a job was started" || fail "$out"
grep -q "JOB bash .*vault.sh close --yes" "$WORK/jobs" && pass "vault.sh close --yes ran as a job" || fail "$(cat "$WORK/jobs")"
run plan secrets-fix; check_eq "secrets-fix plan: exit 0" 0 "$rc"

export HS_VAULT_STATE=closed
run plan header-backup; check_eq "closed vault: header-backup refused" 1 "$rc"; has "closed" && pass "reason" || fail "$out"
run plan move;          check_eq "closed vault: move refused" 1 "$rc"
run plan close;         check_eq "closed already: refused" 1 "$rc"
run plan secrets-fix;   check_eq "secrets-fix does not need the vault" 0 "$rc"
export HS_VAULT_STATE=none
run plan header-backup; check_eq "no vault: refused" 1 "$rc"; has "no vault" && pass "reason" || fail "$out"

run plan init;          check_eq "init is not offered" 1 "$rc"
run plan bind a b;      check_eq "bind is not offered" 1 "$rc"
run plan close --bogus; check_eq "unknown option: refused" 1 "$rc"
finish
