#!/usr/bin/env bash
# hs ct update-all (scripts/ct-update-all.sh) against stand-ins for incus, manage-ct.sh and systemd-run.
# No root needed. Answers come from stdin (HS_GUIDED_TTY=1 = "there is a terminal").
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1
B=$WORK/fake; mkdir -p "$B/bin"
U="bash $SCRIPTS/ct-update-all.sh"

cat > "$B/incus" <<'FAKE'
#!/usr/bin/env bash
dir=$(dirname "$0")
case "$1 $2" in
  "list -f") cat "$dir/list.csv" ;;
  "snapshot list") cat "$dir/snaps-$3" 2>/dev/null ;;
esac
exit 0
FAKE
cat > "$B/manage-ct.sh" <<'FAKE'
#!/usr/bin/env bash
# manage-ct.sh <ct> --update [--dry-run]
dir=$(dirname "$0")
echo "$*" >> "$dir/calls"
if [ "${3:-}" = --dry-run ]; then echo "  incus snapshot create $1 before-update-x"; exit 0; fi
[ "$1" != nosnap ] || { echo "snapshot refused"; exit 1; }
n=$(( $(cat "$dir/snaps-$1" 2>/dev/null | wc -l) + 1 ))
echo "ct-0$n" >> "$dir/snaps-$1"
echo "updating $1"
[ "$1" != broken ] || { echo "apt: E: could not get lock"; exit 100; }
exit 0
FAKE
cat > "$B/bin/systemd-run" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$(dirname "$0")/../systemd-run.log"
FAKE
chmod +x "$B/incus" "$B/manage-ct.sh" "$B/bin/systemd-run"
export HS_INCUS=$B/incus HS_MANAGE_CT=$B/manage-ct.sh

reset() {
  rm -f "$B"/snaps-* "$B/calls" "$B/systemd-run.log"
  printf 'web,RUNNING,CONTAINER\nbroken,RUNNING,CONTAINER\ndb,RUNNING,CONTAINER\nstopped,STOPPED,CONTAINER\ndc1,RUNNING,VIRTUAL-MACHINE\n' > "$B/list.csv"
  echo "old-1" > "$B/snaps-web"
}
calls() { if [ -f "$B/calls" ]; then grep -c -- "--update$" "$B/calls"; else echo 0; fi; }

echo "-- dry run"
reset
out=$($U --dry-run 2>&1); rc=$?
check_eq "exits 0" "0" "$rc"
check_out "lists the running containers" "Containers to update: 3" echo "$out"
check_out "shows what manage-ct would do" "incus snapshot create web" echo "$out"
check_eq "the stopped container and the VM are not in it" "0" "$(grep -c 'stopped\|dc1' <<<"$out")"
check_eq "nothing was run for real" "0" "$(calls)"
check_out "says so" "Dry run" echo "$out"

echo "-- needs a yes"
reset
check_out "no terminal, no --yes: refused" "without --yes" $U
check_eq "and nothing ran" "0" "$(calls)"

echo "-- all containers, one fails"
reset
out=$($U --yes 2>&1); rc=$?
check_eq "exit code 1 because one failed" "1" "$rc"
check_eq "every container was tried (the failure did not stop it)" "3" "$(calls)"
check_out "web is ok with its new snapshot" "web +ok +ct-02" echo "$out"
check_out "broken is reported as failed" "broken +FAILED +ct-01" echo "$out"
check_out "db after the failure is ok" "db +ok +ct-01" echo "$out"
check_out "the failing output is shown" "could not get lock" echo "$out"
check_out "the way back for the failed one" "hs ct broken restore ct-01" echo "$out"
check_out "1 of 3 failed" "1 of 3 containers failed" echo "$out"
check_out "progress line per container" "Updating db \(3 of 3\)" echo "$out"

echo "-- a snapshot that could not be made"
reset
printf 'nosnap,RUNNING,CONTAINER\n' > "$B/list.csv"
out=$($U --yes 2>&1)
check_out "no snapshot, no way back needed" "nosnap: no snapshot was made" echo "$out"

echo "-- choosing"
reset
$U --yes web >/dev/null 2>&1
check_eq "a name limits the run" "1" "$(calls)"
reset
$U --yes --skip broken --skip db >/dev/null 2>&1
check_eq "--skip leaves containers out" "1" "$(calls)"
reset
$U --yes --include-vms >/dev/null 2>&1
check_eq "--include-vms adds the VM" "4" "$(calls)"
reset
printf 'web,STOPPED,CONTAINER\n' > "$B/list.csv"
check_out "nothing running: a note, exit 0" "No running container" $U --yes
check_eq "exit 0" "0" "$($U --yes >/dev/null 2>&1; echo $?)"

echo "-- on a terminal"
reset
out=$(printf 'n\n' | HS_GUIDED_TTY=1 $U 2>&1); rc=$?
check_out "asks once and can say no" "cancelled" echo "$out"
check_eq "nothing ran" "0" "$(calls)"
reset
out=$(printf 'y\nn\n' | HS_GUIDED_TTY=1 $U 2>&1)
check_eq "no to the background: it runs in front" "3" "$(calls)"

echo "-- background job"
reset
out=$(PATH="$B/bin:$PATH" $U --yes --background 2>&1); rc=$?
check_eq "exit 0" "0" "$rc"
check_out "reports the job" "Started as job hs-job-ct-update-all-" echo "$out"
check_eq "the run itself did not happen here" "0" "$(calls)"
check_out "systemd-run starts this script with the list" "ct-update-all.sh --yes web broken db" cat "$B/systemd-run.log"
reset
out=$(printf 'y\ny\n' | PATH="$B/bin:$PATH" HS_GUIDED_TTY=1 $U 2>&1)
check_out "yes to the question starts a job" "Started as job" echo "$out"
check_eq "and runs nothing in front" "0" "$(calls)"
reset
HS_CALLER=job $U >/dev/null 2>&1
check_eq "as a job (HS_CALLER) it asks nothing and runs" "3" "$(calls)"

finish
