#!/usr/bin/env bash
# hs doctor (scripts/doctor.sh): every check and its warning, with a stub health check and fake systemctl, df, timedatectl,
# getent and wbinfo on PATH. No root. Not covered here: the locked-storage and pending-removal lines (they read fixed
# paths under /run/hs and /var/lib/hs), see.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 TZ=UTC
BIN=$WORK/bin; D=$WORK/scripts; mkdir -p "$BIN" "$D/lib"
cp "$SCRIPTS/doctor.sh" "$SCRIPTS/jobs.sh" "$D/"
cp "$SCRIPTS"/lib/ui.sh "$SCRIPTS"/lib/vault.sh "$SCRIPTS"/lib/crypt.sh "$SCRIPTS"/lib/secret.sh "$SCRIPTS"/lib/i18n.sh "$SCRIPTS"/lib/setting.sh "$D/lib/"; cp -r "$SCRIPTS"/lib/i18n "$D/lib/"
cp "$SCRIPTS"/lib/machine.sh "$D/lib/"; cp "$SCRIPTS"/machine-toml.py "$D/"
cat > "$D/health-check.sh" <<'FAKE'
#!/usr/bin/env bash
if [ -n "${PROBLEMS:-}" ]; then printf '%s\n\n' "$PROBLEMS"; else printf 'No problems found.\n\n'; fi
FAKE

cat > "$BIN/systemctl" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  list-timers) echo "Mon 2026-10-05 04:00:00 UTC 3h left Sun 2026-10-04 04:00:00 UTC 21h ago hs-backup.timer hs-backup.service" ;;
  show)
    case "$2:$4" in
      hs-backup.service:ExecMainExitTimestamp) echo "Sun 2026-10-04 04:00:00 UTC" ;;
      hs-backup.service:Result) [ -z "${JOB_FAILED:-}" ] && echo success || echo exit-code ;;
      hs-backup.service:ExecMainStatus) [ -z "${JOB_FAILED:-}" ] && echo 0 || echo 1 ;;
      hs-job-gc.service:Description) echo "Clean up old generations" ;;
      hs-job-gc.service:ActiveEnterTimestamp) echo "Mon 2026-10-05 03:15:00 UTC" ;;
    esac ;;
  list-units) [ -z "${JOB_RUNNING:-}" ] || echo "hs-job-gc.service loaded active running Clean up old generations" ;;
esac
FAKE
cat > "$BIN/df" <<'FAKE'
#!/usr/bin/env bash
printf 'Use%%\n %s%%\n' "${ROOT_PCT:-40}"
FAKE
cat > "$BIN/timedatectl" <<'FAKE'
#!/usr/bin/env bash
[ -z "${NO_NTP:-}" ] && echo yes || echo no
FAKE
cat > "$BIN/getent" <<'FAKE'
#!/usr/bin/env bash
[ -z "${NO_DNS:-}" ] || exit 2
echo "104.16.0.1 cloudflare.com"
FAKE
cat > "$BIN/wbinfo" <<'FAKE'
#!/usr/bin/env bash
[ -z "${NO_TRUST:-}" ]
FAKE
chmod +x "$BIN"/* "$D/health-check.sh"
export PATH=$BIN:$PATH
printf 'hostName = "x"\n' > "$WORK/plain.toml"
printf 'adDomain = "ad.home.lan"\n' > "$WORK/domain.toml"
export HS_MACHINE_FILE=$WORK/plain.toml
Dr="env HS_DOCTOR_UID=0 bash $D/doctor.sh"   # the domain trust is only checked as root

echo "-- all good"
out=$($Dr 2>&1); rc=$?
check_eq "exit 0" "0" "$rc"
check_out "health check ok" "Problems: None" echo "$out"
check_out "jobs ok" "Failed jobs: None" echo "$out"
check_out "disk, clock, DNS ok" "The system disk is 40 % full" echo "$out"
check_out "the clock is synchronised" "The clock is synchronised" echo "$out"
check_out "names resolve" "Names resolve" echo "$out"
check_out "the verdict" "All good" echo "$out"
if grep -q "domain join" <<<"$out"; then fail "no domain configured: the join is not checked"; else pass "no domain configured: the join is not checked"; fi

echo "-- the vault (only where the server has one)"
mkdir -p "$WORK/vstate"; echo uuid > "$WORK/vstate/vault-uuid"
check_out "closed vault: a warning line, no failure" "Vault: closed" env HS_STATE_DIR=$WORK/vstate HS_VAULT_DIR=$WORK/novault $Dr
check_eq "closed alone is exit 0" "0" "$(HS_STATE_DIR=$WORK/vstate HS_VAULT_DIR=$WORK/novault $Dr >/dev/null 2>&1; echo $?)"
check_out "open vault" "Vault: open" env HS_STATE_DIR=$WORK/vstate HS_VAULT_OPEN=1 $Dr

echo "-- each thing that can be wrong"
out=$(PROBLEMS="The backup is 3 days old" $Dr 2>&1 || true)
check_out "a problem of the health check is shown" "The backup is 3 days old" echo "$out"
check_eq "and makes the exit status 1" "1" "$(PROBLEMS=x $Dr >/dev/null 2>&1; echo $?)"
check_out "a failed job is named with its journal command" "Failed: hs-backup.service \(see: hs job log hs-backup.service\)" env JOB_FAILED=1 $Dr
check_out "a running job is mentioned" "Running: Clean up old generations since 05.10. 03:15 \(hs job follow hs-job-gc.service\)" env JOB_RUNNING=1 $Dr
check_eq "a running job alone is not a problem" "0" "$(JOB_RUNNING=1 $Dr >/dev/null 2>&1; echo $?)"
check_out "a nearly full system disk is a problem, with the fix" "The system disk is 90 % full\. Free space: hs system gc" env ROOT_PCT=90 $Dr
check_eq "85 percent is the line" "1" "$(ROOT_PCT=85 $Dr >/dev/null 2>&1; echo $?)"
check_eq "84 percent is fine" "0" "$(ROOT_PCT=84 $Dr >/dev/null 2>&1; echo $?)"
check_out "an unsynchronised clock" "The clock is not synchronised" env NO_NTP=1 $Dr
check_out "broken DNS" "Names do not resolve" env NO_DNS=1 $Dr
out=$(HS_MACHINE_FILE=$WORK/domain.toml $Dr 2>&1)
check_out "with a domain: the join is checked, and healthy" "The domain join is healthy" echo "$out"
check_out "without root the trust check is skipped, not alarming" "cannot be checked without root" env HS_DOCTOR_UID=1000 HS_MACHINE_FILE=$WORK/domain.toml NO_TRUST=1 bash $D/doctor.sh
check_out "a broken trust says how to repair it" "The trust to the domain is broken" env HS_MACHINE_FILE=$WORK/domain.toml NO_TRUST=1 $Dr
check_out "the final line says something needs a look" "Something needs a look" env NO_DNS=1 $Dr
finish
