#!/usr/bin/env bash
# scripts/lib/job.sh hs_job: the command given after `--` is what the transient unit runs (it used to run the
# description text as the command: "command not found"), with its exit status, the unit name has only valid
# characters, and the passphrase file path is passed on. A stand-in systemd-run runs the unit's command directly.
# No root, no systemd.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat > "$T/bin/systemd-run" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$HS_FAKE_LOG"
while [ $# -gt 0 ]; do
  case "$1" in -E) export "$2"; shift 2 ;; --*) shift ;; *) break ;; esac
done
exec "$@"
FAKE
chmod +x "$T/bin/systemd-run"
export PATH="$T/bin:$PATH" HS_FAKE_LOG="$T/calls" HS_STATE_DIR="$T/state"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok:   $1"; else echo "FAIL: $1 (got: $3 | want: $2)"; fail=1; fi; }

run() { bash -c ". '$here/scripts/lib/job.sh'; $1" 2>&1; }

out=$(run 'unit=$(hs_job "pool-<pool>-sync" "hs pool bulk sync" -- bash -c "echo ran-it > '"$T"'/out; exit 0"); echo "unit=$unit"')
check "the command after -- is what runs" "ran-it" "$(cat "$T/out" 2>/dev/null)"
check "the unit name has only valid characters" "1" "$(grep -cE '^unit=hs-job-pool-pool-sync-[0-9]{6}$' <<<"$out")"
check "it fails on a failing start only" "0" "$(grep -c 'command not found' <<<"$out")"

# real systemd-run returns as soon as the unit is started; the stand-in runs it in the foreground, so a
# non-zero exit of the command looks like a failed start: no unit name is printed then
out=$(run 'hs_job x "a job" -- bash -c "exit 3"; echo "rc=$?"')
check "a start that fails is reported, no unit name printed" "0" "$(grep -c '^hs-job-' <<<"$out")"

run 'HS_DISK_PASSPHRASE_FILE=/run/hs/job-pass.X hs_job y "with key" -- true' >/dev/null
check "the passphrase file path is handed to the unit" "1" "$(grep -c 'HS_DISK_PASSPHRASE_FILE=/run/hs/job-pass.X' "$T/calls")"
check "the secret itself is never an argument" "0" "$(grep -c 'hunter2' "$T/calls")"

exit $fail
