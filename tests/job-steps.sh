#!/usr/bin/env bash
# Job steps (#389): a long job reports "step n of m" to its record. The record writer is a stand-in that logs every call
# (job.sh uses $HOBNIX_BIN job-record when it answers --probe). Checks the step() heading of ui.sh inside a job (what update,
# rebuild and gc use), the explicit steps of hs ct update-all, and that nothing is reported outside a job. No root, no systemd.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok:   $1"; else echo "FAIL: $1 (got: $3 | want: $2)"; fail=1; fi; }

cat > "$T/hobnix" <<'FAKE'
#!/usr/bin/env bash
[ "$1" = job-record ] || exit 1
shift
[ "$1" != --probe ] || exit 0
[ "$1" != step ] || echo "$*" >> "$(dirname "$0")/steps.log"
FAKE
chmod +x "$T/hobnix"
export HOBNIX_BIN=$T/hobnix HS_LANG=en HS_PLAIN=1 HS_STATE_DIR=$T/state

# 1. step() inside a job reports n of m with its heading, and only when the script declared `steps N`
HS_JOB_ID=j1 bash -c ". '$here/scripts/lib/ui.sh'; steps 3; step 'Update'; step 'Check'; step 'Rebuild'" >/dev/null 2>&1
check "steps 3 in a job: the sequence is in the record" "step j1 1 3 Update|step j1 2 3 Check|step j1 3 3 Rebuild" "$(paste -sd'|' "$T/steps.log")"
rm -f "$T/steps.log"
bash -c ". '$here/scripts/lib/ui.sh'; steps 2; step A; step B" >/dev/null 2>&1
check "outside a job nothing is reported" "none" "$([ -s "$T/steps.log" ] && echo some || echo none)"
HS_JOB_ID=j1 bash -c ". '$here/scripts/lib/ui.sh'; step A" >/dev/null 2>&1
check "a heading without a declared count reports nothing" "none" "$([ -s "$T/steps.log" ] && echo some || echo none)"

# 2. hs ct update-all: one step per container
B=$T/fake; mkdir -p "$B"
cat > "$B/incus" <<'FAKE'
#!/usr/bin/env bash
case "$1 $2" in "list -f") printf 'web,RUNNING,CONTAINER\ndb,RUNNING,CONTAINER\n' ;; esac
exit 0
FAKE
printf '#!/usr/bin/env bash\nexit 0\n' > "$B/manage-ct.sh"
chmod +x "$B/incus" "$B/manage-ct.sh"
HS_JOB_ID=j2 HS_CALLER=job HS_INCUS=$B/incus HS_MANAGE_CT=$B/manage-ct.sh bash "$here/scripts/ct-update-all.sh" >/dev/null 2>&1
check "ct update-all: a step per container" "step j2 1 2 Updating container web|step j2 2 2 Updating container db" "$(grep ' Updating container ' "$T/steps.log" | paste -sd'|')"
exit $fail
