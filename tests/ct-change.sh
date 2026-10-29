#!/usr/bin/env bash
# hs sys ct plan|start (scripts/ct-change.sh): the plan of an instance change as data, and the change as a background job.
# Fake manage-ct.sh (dry run only), fake ct-bindings and fake systemd-run: no root, no Incus.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en
unset HS_CALLER HS_GUIDED_TTY
BIN=$WORK/bin; mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/jobcalls"\n' "$WORK" > "$BIN/systemd-run"; chmod +x "$BIN/systemd-run"
export PATH="$BIN:$PATH"

cat > "$WORK/manage-ct" <<'FAKE'
#!/usr/bin/env bash
echo "mc $*" >> "$(dirname "$0")/mccalls"
ct=$1; shift
if [ "$ct" = --create ]; then echo "  incus init images:debian/13 $1"; exit 0; fi
dry=false; a=()
for x in "$@"; do if [ "$x" = --dry-run ]; then dry=true; else a+=("$x"); fi; done
case "${a[0]}" in
  --users) printf 'immich\t1000\t1000\tnode\npostgres\t999\t999\tpostgres\n' ;;
  --restore)
    if [ "${a[1]}" = nope ]; then echo "  ✗ '$ct' has no snapshot called 'nope'." ; exit 1; fi
    echo "  (newer snapshot, must be deleted to go back further:)"
    echo "  incus snapshot delete $ct auto-2"
    echo "  incus snapshot restore $ct ${a[1]}" ;;
  --delete-snapshot) echo "  incus snapshot delete $ct ${a[1]}" ;;
  --snapshot) echo "  incus snapshot create $ct ${a[1]:-manual-x}" ;;
  --start|--stop|--restart) echo "  incus ${a[0]#--} $ct" ;;
  --remove-storage) echo "  incus config device remove $ct ${a[1]}" ;;
  --set) echo "  incus config set $ct limits.memory=${a[1]#ram=}MiB" ;;
  --update) echo "  incus snapshot create $ct before-update-x"; echo "  incus exec $ct -- update" ;;
  --delete) echo "Delete '$ct' with all its snapshots. Attached storage stays:"; echo "  /bulk/shares/media -> /media"; echo "  incus delete -f $ct"
            $dry || { for x in "$@"; do [ "$x" = --yes ] && echo "yes given" >> "$(dirname "$0")/yes"; done; } ;;
  --add-storage) echo "  incus storage volume attach default ${a[2]} $ct ${a[2]} ${a[3]}" ;;
esac
FAKE
cat > "$WORK/ct-bindings" <<'FAKE'
#!/usr/bin/env bash
printf 'media\tshares\tbulk\t/bulk/shares/media\t/media\tread\toff\toff\tmedia\t1\tdata-01\tsonarr(rw)\nphotos\tsensitive\tbulk\t/x\t/y\twrite\toff\ton\tp\t1\tdata-01\t-\n'
FAKE
cat > "$WORK/ct-update-all" <<'FAKE'
#!/usr/bin/env bash
# stand-in for ct-update-all.sh: the plain output of its --dry-run (heading, the names as notes, a section per container)
echo "$*" >> "$(dirname "$0")/updall-args"
[ -z "${NONE:-}" ] || { echo "    No running container to update."; exit 0; }
printf '\n── Containers to update: 2 ──\n    immich\n    jellyfin\n'
for c in immich jellyfin; do printf '\n── %s ──\n      incus snapshot create %s before-update-x\n' "$c" "$c"; done
echo "    Dry run: nothing was changed."
FAKE
chmod +x "$WORK/ct-update-all"
export HS_CT_UPDATE_ALL=$WORK/ct-update-all
chmod +x "$WORK/manage-ct" "$WORK/ct-bindings"
export HS_MANAGE_CT=$WORK/manage-ct HS_CT_BINDINGS=$WORK/ct-bindings

run() { rc=0; out=$(timeout 20 bash "$SCRIPTS/ct-change.sh" "$@" </dev/null 2>/dev/null) || rc=$?; }
has() { grep -q -- "$1" <<<"$out"; }

echo "-- something is missing: exit 2"
run plan immich restore
check_eq "restore without a snapshot" "2 status	needs
needs	snapshot" "$rc $out"
run plan immich add-storage --kind fast
check_eq "add-storage names what is missing" "2 status	needs
needs	name
needs	path" "$rc $out"

echo "-- a plain change: no danger, no name to type"
run plan immich start
check_eq "start: exit 0" 0 "$rc"
has '^heading	start immich$' && has '^command	incus start immich$' && pass "start: heading and command" || fail "start: $out"
has '^danger' && fail "start has no danger line" || pass "no danger line"
has '^confirm_name' && fail "start needs no typed name" || pass "no confirm_name"
run plan immich stop
has '^note	Services that go down: immich, postgres$' && pass "stop names the services that go down" || fail "stop: $out"
run plan immich snapshot --label before
has '^command	incus snapshot create immich before$' && pass "snapshot with a label" || fail "snapshot: $out"

echo "-- what cannot be undone is red and needs the name"
run plan immich restore --snapshot manual-1
check_eq "restore: exit 0" 0 "$rc"
has '^danger	.*goes back to .manual-1.*1 newer snapshot' && has '^confirm_name	immich$' && pass "danger line and the name to type" || fail "restore: $out"
has '^command	incus snapshot delete immich auto-2$' && has '^command	incus snapshot restore immich manual-1$' && pass "the commands, in order" || fail "restore commands: $out"
has '^command	.*(newer' && fail "a remark is no command" || pass "remarks are not commands"
run plan immich delete-snapshot --snapshot manual-1
has '^danger	The snapshot .manual-1. of .immich. is deleted for good' && has '^confirm_name	immich$' && pass "delete snapshot is red" || fail "delete: $out"

echo "-- a refusal"
run plan immich restore --snapshot nope
check_eq "exit 1" 1 "$rc"
has '^status	refused$' && has "^reason	.*no snapshot called 'nope'" && pass "the reason is the script's" || fail "refusal: $out"
run plan Bad_Name start
check_eq "a bad instance name" 1 "$rc"
run plan immich fly
check_eq "an unknown action" 1 "$rc"
run plan immich start --bogus
check_eq "an unknown option" 1 "$rc"

echo "-- remove storage warns about other users of the folder"
run plan immich remove-storage --device media
has '^warn	Also mounted in: sonarr(rw)$' && has '^note	The data stays' && pass "warning with the other instance" || fail "remove: $out"
run plan immich remove-storage --device photos
has '^warn' && fail "no warning for a private folder" || pass "no warning when nobody else mounts it"

echo "-- start"
run start immich restore --snapshot manual-1
check_eq "start without the name is refused" 1 "$rc"
has 'type the name to confirm: immich' && pass "and says what to type" || fail "start: $out"
[ ! -s "$WORK/jobcalls" ] && pass "no job was started" || fail "a job was started"
run start immich restore --snapshot manual-1 --confirm immich
check_eq "start with the name: exit 0" 0 "$rc"
has '^status	started$' && has '^unit	hs-job-ct-restore-immich-' && pass "a job unit is printed" || fail "start: $out"
grep -q -- '--restore manual-1' "$WORK/jobcalls" && pass "the job runs manage-ct.sh --restore" || fail "job: $(cat "$WORK/jobcalls")"
run start immich restart
check_eq "a plain change starts without a name" 0 "$rc"


echo "-- settings, fixed address, update, delete, create"
run plan immich set
check_eq "set without a setting" "2 status	needs
needs	setting" "$rc $out"
run plan immich set --ram abc
check_eq "a bad number is refused" 1 "$rc"
run plan immich set --ram 4096 --autostart yes
check_eq "set: exit 0" 0 "$rc"
has '^step	memory limit: 4096 MiB$' && has '^step	start at boot: yes$' && has '^command	incus config set immich limits.memory=4096MiB$' && pass "set: the steps and the command" || fail "set: $out"
has '^danger' && fail "set is not red" || pass "set is not red"
run plan immich ip
check_eq "ip without an address" "2 status	needs
needs	address" "$rc $out"
run plan immich update
has '^long	yes$' && has '^command	incus snapshot create immich before-update-x$' && pass "update: long, snapshot first" || fail "update: $out"
run plan immich delete
check_eq "delete: exit 0" 0 "$rc"
has '^danger	.immich. is deleted with all its snapshots' && has '^confirm_name	immich$' && pass "delete is red and needs the name" || fail "delete: $out"
has '^command	incus delete -f immich$' && ! has '^command	/bulk' && pass "only commands are commands" || fail "delete commands: $out"
run start immich delete
check_eq "delete without the name is refused" 1 "$rc"
run start immich delete --confirm immich
check_eq "delete with the name starts a job" 0 "$rc"
grep -q -- '--delete --yes' "$WORK/jobcalls" && pass "the job passes --yes (it cannot ask)" || fail "job: $(cat "$WORK/jobcalls")"
run plan newone create --type docker --ram 2048
check_eq "create: exit 0" 0 "$rc"
has '^heading	create newone (docker)$' && has '^command	incus init images:debian/13 newone$' && has '^note	No fixed address yet' && pass "create: heading, command, note" || fail "create: $out"
run plan newone create --type toaster
check_eq "an unknown type" 1 "$rc"
echo "-- update all"
run plan all update-all
check_eq "update-all: exit 0" 0 "$rc"
has '^heading	update all running instances (2)$' && has '^step	snapshot immich, then update' && has '^step	snapshot jellyfin, then update' && has '^long	yes$' && pass "update-all: the instances, long" || fail "update-all: $out"
has '^warn	Every instance is snapshotted first' && pass "update-all warns" || fail "update-all warn: $out"
has '^danger' && fail "update-all is not red" || pass "update-all: no danger line, no name to type"
run start all update-all
check_eq "update-all starts a job" 0 "$rc"
grep -q -- 'ct-update-all.*--yes immich jellyfin' "$WORK/jobcalls" && pass "the job updates exactly the planned list" || fail "update-all job: $(cat "$WORK/jobcalls")"
run plan immich update-all
check_eq "update-all needs the instance 'all'" 1 "$rc"
run plan all update
check_eq "'all' is only for update-all" 1 "$rc"
NONE=1 run plan all update-all
check_eq "nothing running is refused" 1 "$rc"
has 'No running container' && pass "update-all: reason" || fail "update-all none: $out"

echo "-- create with a network profile and bindings"
run plan newone create --profile home --bind shares:media:/media:ro --bind fast:data:/data
check_eq "create with profile and bindings: exit 0" 0 "$rc"
has '^note	On the network (profile) home\.$' && has '^step	bind shares media at /media (read only)$' && has '^step	bind fast data at /data$' && pass "profile note and a step per binding" || fail "bind plan: $out"
grep -q -- '--create newone --profile home --dry-run' "$WORK/mccalls" && pass "the dry run gets --profile" || fail "calls: $(cat "$WORK/mccalls")"
for bad in 'shares:media' 'shares:media:media' 'shares:media:/a/../b' 'other:x:/x' 'shares:me;dia:/x' 'shares:media:/m:rw'; do
  run plan newone create --bind "$bad"
  check_eq "bad binding '$bad' is refused" 1 "$rc"
done
run plan newone create --bind shares:media:/a --bind fast:media:/b
check_eq "two bindings with one name" 1 "$rc"
run plan newone create --type vm --bind shares:media:/media
check_eq "bulk folders into a VM are refused" 1 "$rc"
run plan newone create --type vm --bind fast:data:/data
check_eq "a fast volume into a VM is fine" 0 "$rc"
run plan newone create --profile 'a b'
check_eq "a bad profile name" 1 "$rc"
run plan immich start --profile home
check_eq "--profile only for create" 1 "$rc"
run plan immich start --bind fast:x:/x
check_eq "--bind only for create" 1 "$rc"
: > "$WORK/jobcalls"
run start newone create --profile home --bind fast:data:/data
check_eq "start create with bindings: exit 0" 0 "$rc"
grep -q -- 'ct-change.sh apply-create --create newone --profile home --bind fast:data:/data' "$WORK/jobcalls" && pass "the job is apply-create" || fail "job: $(cat "$WORK/jobcalls")"
: > "$WORK/mccalls"
bash "$SCRIPTS/ct-change.sh" apply-create --create newone --profile home --bind fast:data:/data --bind shares:media:/media:ro >/dev/null
check_eq "create, then each binding" "mc --create newone --profile home
mc newone --add-storage fast data /data
mc newone --add-storage shares media /media --readonly" "$(cat "$WORK/mccalls")"
: > "$WORK/jobcalls"
run start newone create --type docker
grep -q -- 'manage-ct --create newone --docker' "$WORK/jobcalls" && pass "without bindings the job is manage-ct.sh as before" || fail "job: $(cat "$WORK/jobcalls")"
echo "-- device actions (stand-in for ct-device.sh)"
cat > "$WORK/ct-device" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$(dirname "$0")/devcalls"
case " $* " in
  *" nope "*) echo "  ✗ 0000:09:00.0 cannot be passed in: it is the server's screen" >&2; exit 1 ;;
  *" --remove "*) echo "step: give usb-04f9-0042 back to the server"; echo "  incus config device remove $1 usb-04f9-0042" ;;
  *" gpu "*) echo "step: pass 0000:03:00.0"; echo "warn: the VM stops and starts again"
             echo "  incus config device add $1 gpu-03-00-0 gpu gputype=physical pci=0000:03:00.0"
             echo "danger: 0000:03:00.0 (amd) is taken from the server while $1 runs."; echo "confirm: 0000:03:00.0" ;;
  *) echo "note: not plugged in now"; echo "  incus config device add $1 usb-x usb vendorid=04f9 productid=0042 required=false" ;;
esac
FAKE
chmod +x "$WORK/ct-device"
export HS_CT_DEVICE=$WORK/ct-device
run plan vm1 add-device --kind usb
check_eq "add-device without --id: exit 2" 2 "$rc"
has "needs	id" && pass "needs id" || fail "needs id: $out"
run plan vm1 add-device --kind usb --id '../x'
check_eq "a bad device id is refused" 1 "$rc"
run plan vm1 add-device --kind usb --id 04f9:0042
check_eq "plan add usb: exit 0" 0 "$rc"
has "heading	pass usb 04f9:0042 to vm1" && has "note	not plugged in now" && has "command	incus config device add vm1 usb-x" && pass "usb plan: heading, note, command" || fail "usb plan: $out"
has "confirm_name" && fail "a usb add asks no word" || pass "a usb add asks no word"
run plan vm1 add-device --kind gpu --id 0000:03:00.0
has "danger	0000:03:00.0 (amd)" && has "confirm_name	0000:03:00.0" && has "warn	the VM stops" && has "step	pass 0000:03:00.0" && pass "gpu plan: danger, warn, step, the PCI address is the word" || fail "gpu plan: $out"
run plan vm1 add-device --kind gpu --id 0000:09:00.0 --name nope
check_eq "a refusal of the device script: exit 1" 1 "$rc"
has "status	refused" && has "cannot be passed in" && pass "refusal text reaches the plan" || fail "refusal: $out"
: > "$WORK/jobcalls"
run start vm1 add-device --kind gpu --id 0000:03:00.0
check_eq "start gpu without the word: refused" 1 "$rc"
has "type the name to confirm: 0000:03:00.0" && pass "the refusal names the PCI address" || fail "confirm text: $out"
run start vm1 add-device --kind gpu --id 0000:03:00.0 --confirm vm1
check_eq "the instance name is not the word" 1 "$rc"
run start vm1 add-device --kind gpu --id 0000:03:00.0 --confirm 0000:03:00.0
check_eq "start gpu with the address: exit 0" 0 "$rc"
grep -q -- 'ct-device vm1 --add gpu 0000:03:00.0 --yes' "$WORK/jobcalls" && pass "the job is ct-device.sh --add ... --yes" || fail "job: $(cat "$WORK/jobcalls")"
: > "$WORK/jobcalls"
run start vm1 add-device --kind usb --id 04f9:0042 --name printer
check_eq "start usb: exit 0, no word" 0 "$rc"
grep -q -- 'ct-device vm1 --add usb 04f9:0042 --name printer --yes' "$WORK/jobcalls" && pass "usb job with --name and --yes" || fail "job: $(cat "$WORK/jobcalls")"
run plan vm1 remove-device
has "needs	device" && pass "remove-device needs a device" || fail "remove needs: $out"
run plan vm1 remove-device --device usb-04f9-0042
has "heading	remove device usb-04f9-0042 from vm1" && has "step	give usb-04f9-0042 back" && has "command	incus config device remove vm1 usb-04f9-0042" && pass "remove plan: heading, step mapped, command" || fail "remove plan: $out"
has "confirm_name" && fail "a remove asks no word" || pass "a remove asks no word"
: > "$WORK/jobcalls"
run start vm1 remove-device --device usb-04f9-0042
grep -q -- 'ct-device vm1 --remove usb-04f9-0042' "$WORK/jobcalls" && ! grep -q -- '--yes' "$WORK/jobcalls" && pass "remove job has no --yes" || fail "job: $(cat "$WORK/jobcalls")"
run plan immich stop
has "confirm_name" && fail "stop asks no word (unchanged)" || pass "stop has no confirm_name"
unset HS_CT_DEVICE
echo "-- the registry rows"
check_out "hs sys ct plan runs it" "status	ok" env HS_CALLER=test bash "$SCRIPTS/lib/hs.sh" sys ct plan immich start
finish
