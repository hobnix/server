#!/usr/bin/env bash
# scripts/storage-incident.sh (hobnix/server#255): the storage incident workflow against mocked command output (no root, no disks, no ZFS).
# ZFS mirror with one disk FAULTED, a SnapRAID array with a missing data disk, a failing disk behind an ONLINE member, the replace guard,
# pause/resume of the writing apps, the plan/start protocol for the web interface and the alert line. Not run on real hardware.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en HS_STATE_DIR=$WORK/state HS_BULK_TYPE_FILE=$WORK/bt HS_INCIDENT_PAUSED=$WORK/paused HS_LOCK_ADMIN=$WORK/noadmin
unset HS_CALLER HS_GUIDED_TTY
mkdir -p "$WORK/m" "$WORK/state"
S=$SCRIPTS/storage-incident.sh
scen() { printf '%s' "$1" > "$WORK/scen"; }
echo zfs > "$WORK/bt"

# stand-ins; the scenario word is in $WORK/scen: zfs-degraded, zfs-resilver, snap-missing, smart, healthy
cat > "$WORK/m/pool.sh" <<'X'
#!/usr/bin/env bash
sc=$(cat "$(dirname "$0")/../scen")
case "$*" in
  "bulk --members")
    case "$sc" in
      zfs-degraded|zfs-resilver) printf 'ata-A_SERA\t4000000000\tONLINE\tmirror-0\tzfs\t-\nata-B_SERB\t4000000000\tFAULTED\tmirror-0\tzfs\t-\n' ;;
      smart) printf 'ata-A_SERA\t4000000000\tONLINE\tmirror-0\tzfs\t-\nata-B_SERB\t4000000000\tONLINE\tmirror-0\tzfs\t-\n' ;;
      snap-missing) printf 'data-01\t4000000000\tONLINE\tdata\text4\t-\t-\ndata-02\t0\tMISSING\tdata\t-\t-\t-\nparity-1\t4000000000\tONLINE\tparity\text4\t-\t-\n' ;;
      *) printf 'ata-A_SERA\t4000000000\tONLINE\tmirror-0\tzfs\t-\nata-B_SERB\t4000000000\tONLINE\tmirror-0\tzfs\t-\n' ;;
    esac ;;
  "fast --members") ;;
  "--list-disks") [ -f "$(dirname "$0")/../newdisk" ] && printf 'ata-NEW_SERN\t4000000000\tfree\n' ;;
esac
X
cat > "$WORK/bin-zpool" <<'X'
#!/usr/bin/env bash
sc=$(cat "$(dirname "$0")/../scen")
[ "$4" = health ] || [ "$1" = status ] || true
case "$1 $2 $3 $4 $5" in
  "list -H -o health bulk") case "$sc" in zfs-*) echo DEGRADED ;; *) echo ONLINE ;; esac ;;
  "list -H -o health fast") exit 1 ;;
  "status bulk   ") [ "$sc" = zfs-resilver ] && printf '  scan: resilver in progress since Sun Nov  8 10:00:00 2026\n\t800G resilvered, 26.67%% done, 02:10:00 to go\n' ;;
esac
exit 0
X
cat > "$WORK/m/dh.sh" <<'X'
#!/usr/bin/env bash
[ "$(cat "$(dirname "$0")/../scen")" = smart ] && printf 'sdb\t4000000000\tHDD\tMODEL SERB\tBAD\t30000\t12 pending sectors\tspinning\n'
exit 0
X
cat > "$WORK/m/mon.sh" <<'X'
#!/usr/bin/env bash
printf 'sda\t4000000000\tHDD\tbulk\t30\tPASS\t100\t0\t0\t0\tMODEL SERA\t1\tspinning\tzfs\n'
printf 'sdb\t4000000000\tHDD\tbulk\t31\tPASS\t100\t0\t0\t0\tMODEL SERB\t1\tspinning\tzfs\n'
X
cat > "$WORK/m/sov.sh" <<'X'
#!/usr/bin/env bash
sc=$(cat "$(dirname "$0")/../scen")
if [ "$sc" = snap-missing ]; then
  printf 'docs\tshares\t/bulk/shares/docs\toff\t1\t-\ton\tdata-01\t-\n'
  printf 'media\tshares\t/bulk/shares/media\toff\t1\t-\ton\tdata-01,data-02\timmich(rw),jelly(ro)\n'
else
  printf 'docs\tshares\t/bulk/shares/docs\toff\t1\t-\ton\tbulk\timmich(rw),jelly(ro)\n'
fi
printf 'fastone\tshares\t/fast/shares/x\toff\t1\t-\ton\tfast\t-\n'
X
cat > "$WORK/m/incus.sh" <<'X'
#!/usr/bin/env bash
case "$1" in list) printf 'immich,RUNNING\njelly,RUNNING\n' ;; *) echo "incus $*" >> "$(dirname "$0")/../calls" ;; esac
X
cat > "$WORK/m/none.sh" <<'X'
#!/usr/bin/env bash
exit 0
X
cat > "$WORK/m/repl.sh" <<'X'
#!/usr/bin/env bash
echo "replace $*" >> "$(dirname "$0")/../calls"
X
mkdir -p "$WORK/bin"; cp "$WORK/bin-zpool" "$WORK/bin/zpool"; chmod +x "$WORK"/m/*.sh "$WORK/bin/zpool"
export HS_MANAGE_POOL=$WORK/m/pool.sh HS_ZPOOL=$WORK/bin/zpool HS_DISK_HEALTH=$WORK/m/dh.sh HS_MONITOR=$WORK/m/mon.sh HS_SHARE_OVERVIEW=$WORK/m/sov.sh \
  HS_INCUS=$WORK/m/incus.sh HS_JOBS=$WORK/m/none.sh HS_DISK_DETACH=$WORK/m/none.sh HS_DISK_REPLACE=$WORK/m/repl.sh
st() { bash "$S" --state "$@" 2>/dev/null; }
lines() { grep -c "^$1	" <<<"$out"; }

echo "-- healthy"
scen healthy; out=$(st)
check_eq "healthy: one ok line" "ok	-	no storage incident: every pool and every disk looks fine" "$out"
check_eq "healthy: no alert line" "" "$(bash "$S" --alert-line)"

echo "-- ZFS mirror, one disk FAULTED"
scen zfs-degraded; out=$(st)
check_eq "pool incident, error" "1" "$(grep -c '^incident	bulk:degraded	bulk	pool-degraded	error	' <<<"$out")"
check_eq "member down incident" "1" "$(grep -c '^incident	bulk:down:ata-B_SERB	bulk	member-down	error' <<<"$out")"
check_eq "the disk to pull is named with model and serial" "target	bulk	ata-B_SERB	sdb	MODEL SERB" "$(grep '^target' <<<"$out")"
check_eq "share is at risk" "share	bulk	docs	/bulk/shares/docs	at-risk" "$(grep '^share	bulk	docs' <<<"$out")"
check_eq "the writing app is found" "app	bulk	immich	RUNNING	docs	yes" "$(grep '^app	bulk	immich' <<<"$out")"
check_eq "the reading app does not write" "app	bulk	jelly	RUNNING	docs	no" "$(grep '^app	bulk	jelly' <<<"$out")"
check_eq "no new disk yet: phase detect" "phase	bulk	detect" "$(grep '^phase' <<<"$out")"
check_eq "pause is optional while a writer runs" "step	2	optional	Pause the apps that write to the pool" "$(grep '^step	2' <<<"$out")"
check_eq "alert line points at the workflow" "Guided steps: hs storage incident" "$(bash "$S" --alert-line)"
touch "$WORK/newdisk"; out=$(st)
check_eq "a free disk that is large enough: phase ready" "phase	bulk	ready" "$(grep '^phase' <<<"$out")"
check_eq "free disk listed" "free	ata-NEW_SERN	4000000000	free" "$(grep '^free' <<<"$out")"
check_eq "next step is the replace command" "1" "$(grep -c '^next	hs storage incident replace	' <<<"$out")"
rm -f "$WORK/newdisk"

echo "-- ZFS resilver running"
scen zfs-resilver; out=$(st)
check_eq "progress with percent" "1" "$(grep -c '^progress	bulk	resilver	26.67	' <<<"$out")"
check_eq "phase running" "phase	bulk	running" "$(grep '^phase' <<<"$out")"
check_eq "next step says wait" "1" "$(grep -c '^next	-	A replacement is running' <<<"$out")"

echo "-- SnapRAID, a data disk is missing"
echo snapraid > "$WORK/bt"; scen snap-missing; out=$(st)
check_eq "member incident" "1" "$(grep -c '^incident	bulk:down:data-02	bulk	member-down	error' <<<"$out")"
check_eq "no pool-degraded line for SnapRAID" "0" "$(grep -c 'pool-degraded' <<<"$out")"
check_eq "a share with files on the missing disk is unavailable" "share	bulk	media	/bulk/shares/media	unavailable" "$(grep '^share	bulk	media' <<<"$out")"
check_eq "a share on the healthy disk is only at risk" "share	bulk	docs	/bulk/shares/docs	at-risk" "$(grep '^share	bulk	docs' <<<"$out")"
check_eq "gone disk: nothing to pull" "target	bulk	data-02	-	-" "$(grep '^target' <<<"$out")"
echo zfs > "$WORK/bt"

echo "-- SMART BAD behind an ONLINE member"
scen smart; out=$(st)
check_eq "failing disk incident (warn)" "1" "$(grep -c '^incident	bulk:failing:ata-B_SERB	bulk	disk-failing	warn' <<<"$out")"
check_eq "pool itself is fine: no pool-degraded" "0" "$(grep -c 'pool-degraded' <<<"$out")"

echo "-- the replace guard"
scen zfs-degraded; : > "$WORK/calls"
rc=0; o=$(bash "$S" replace --member ata-A_SERA --disk x 2>&1) || rc=$?
check_eq "the good half of a degraded mirror is refused" "1" "$rc"
check_out "the refusal says why" "only good copy" echo "$o"
check_eq "nothing was handed to the replace command" "0" "$(grep -c '^replace' "$WORK/calls")"
rc=0; o=$(bash "$S" replace --disk ata-NEW_SERN 2>&1) || rc=$?; echo "$o" >&2
check_eq "the failed disk is replaced after the plan" "0" "$rc"
check_eq "handed to hs disk replace with member and disk" "replace --pool bulk --member ata-B_SERB --disk ata-NEW_SERN" "$(grep '^replace' "$WORK/calls")"
check_out "no free disk and no terminal: it says so" "No free disk" bash "$S" replace </dev/null
scen zfs-resilver
rc=0; bash "$S" replace --disk x >/dev/null 2>&1 || rc=$?
check_eq "a running replacement blocks a second one" "1" "$rc"

echo "-- pause and resume"
scen zfs-degraded; : > "$WORK/calls"; rm -f "$WORK/paused"
bash "$S" pause --yes >/dev/null 2>&1
check_eq "only the writer is frozen" "incus pause immich" "$(grep '^incus' "$WORK/calls")"
check_eq "it is remembered" "immich" "$(cat "$WORK/paused")"
check_eq "state says paused" "paused	yes	immich" "$(st | grep '^paused')"
bash "$S" resume >/dev/null 2>&1
check_eq "resume thaws exactly that one" "incus resume immich" "$(grep '^incus resume' "$WORK/calls")"
check_eq "and forgets it" "0" "$([ -e "$WORK/paused" ] && echo 1 || echo 0)"
rc=0; bash "$S" pause --yes jelly >/dev/null 2>&1 || rc=$?
check_eq "a read-only app is not paused" "0" "$(grep -c 'pause jelly' "$WORK/calls")"

echo "-- web plan/start"
out=$(bash "$S" plan pause 2>/dev/null)
check_eq "plan ok" "status	ok" "$(head -n1 <<<"$out")"
check_eq "plan names the app" "1" "$(grep -c '^step	freeze immich' <<<"$out")"
: > "$WORK/calls"; out=$(bash "$S" start pause 2>/dev/null)
check_eq "start done" "status	done" "$(tail -n1 <<<"$out")"
check_eq "start froze it" "incus pause immich" "$(grep '^incus' "$WORK/calls")"
rc=0; out=$(bash "$S" plan bogus 2>/dev/null) || rc=$?
check_eq "unknown action refused" "1" "$rc"
rm -f "$WORK/paused"
scen healthy; rc=0; out=$(bash "$S" plan pause 2>/dev/null) || rc=$?
check_eq "no incident: refused" "1" "$rc"

echo "-- human report"
scen zfs-degraded
out=$(bash "$S" 2>&1)
check_out "names the disk" "MODEL SERB" echo "$out"
check_out "names the affected share" "docs" echo "$out"
check_out "suggests the pause" "Suggestion: pause" echo "$out"
check_out "shows the next step" "hs storage incident replace" echo "$out"
finish
