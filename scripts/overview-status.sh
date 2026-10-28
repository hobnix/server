#!/usr/bin/env bash
# help: the facts the Overview shows (backup age, encryption, parity sync and scrub, upload cache, disk health, instances, hottest disk, last disk event)
# help.de: die Angaben der Übersicht (Backup-Alter, Verschlüsselung, Paritäts-Sync und Scrub, Upload-Cache, Plattengesundheit, Instanzen, heißeste Platte, letztes Platten-Ereignis)
# args: -
# System command (hs sys status), read only, tab separated, one fact per line, in this order. The interface
# chooses words and colours; this script only says what is the case. A source that cannot be read leaves its line out.
#   backup      <ok|failed|new>   <seconds since the last good backup, - if none>
#   encryption  <locked|open|none>
#   job         <unit>  <ok|failed|never|noparity>  <last run>  <next run>       (hs-bulk-sync.service and hs-bulk-scrub.service; noparity = SnapRAID without a parity disk)
#   cache       <the "used of" text of the upload cache>  <percent>
#   smart       <number of disks>  <WATCH and BAD disks, "sda WATCH,sdb BAD", empty = all fine>
#   instances   <running>  <all>
#   hottest     <disk>  <degrees>
#   event       <when>  <what>                                          (the last line of the disk event log)
# Test knobs: HS_BULK_TYPE_FILE, HS_SNAPRAID_CONF, HS_STATE_DIR, HS_LOCKED_MARKER, HS_UNLOCK, HS_JOBS, HS_SHARE_CACHE, HS_DISK_HEALTH, HS_MONITOR, HS_INCUS, HS_DISK_EVENTS.
set -uo pipefail
here=$(dirname "$0")
state=${HS_STATE_DIR:-/var/lib/hs}
export HS_PLAIN=1 HS_LANG=en
now=$(date +%s)

# The sources are independent and each takes a moment (the encryption status, the timers, the cache, smartctl, incus, lsblk): they run side by side and
# the facts are printed in the fixed order below once all have answered (2.2 s one after the other on the server, about the slowest one now).
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
bash "${HS_UNLOCK:-$here/unlock.sh}" --status >"$tmp/crypt" 2>/dev/null </dev/null &
bash "${HS_JOBS:-$here/jobs.sh}" --list >"$tmp/jobs" 2>/dev/null </dev/null &
bash "${HS_SHARE_CACHE:-$here/share-cache.sh}" status >"$tmp/cache" 2>/dev/null </dev/null &
bash "${HS_DISK_HEALTH:-$here/disk-health.sh}" --list >"$tmp/smart" 2>/dev/null </dev/null &
${HS_INCUS:-incus} list -f csv -c s >"$tmp/inst" 2>/dev/null </dev/null &
bash "${HS_MONITOR:-$here/monitor.sh}" --disks >"$tmp/disks" 2>/dev/null </dev/null &
wait

# --- backup
if [ -r "$state/backup.state" ]; then
  get() { awk -F= -v k="$1" '$1 == k { print $2; exit }' "$state/backup.state"; }
  st=$(get status); ok=$(get last_ok)
  [ -n "$st" ] || st=new
  age=-; [ -z "$ok" ] || age=$((now - ok))
  printf 'backup\t%s\t%s\n' "$st" "$age"
fi

# --- encryption: the marker of a locked boot, else what `unlock --status` says
crypt=$(cat "$tmp/crypt")
if [ -e "${HS_LOCKED_MARKER:-/run/hs/storage-locked}" ] || { grep 'LOCKED' <<<"$crypt" | grep -qv 'not yet of this server'; }; then
  echo "encryption	locked"
elif grep -q 'Nothing encrypted' <<<"$crypt"; then
  echo "encryption	none"
elif grep -q ' open' <<<"$crypt"; then
  echo "encryption	open"
fi

# --- the two timers that matter for the bulk pool
jobs=$(cat "$tmp/jobs")
# Without a parity disk the units skip their run (ExecCondition), so their last result would still read "ok": say "noparity" instead.
noparity=
if [ "$(cat "${HS_BULK_TYPE_FILE:-/etc/hs/bulk-type}" 2>/dev/null || echo zfs)" = snapraid ] && ! grep -q '^parity ' "${HS_SNAPRAID_CONF:-/var/lib/snapraid/snapraid.conf}" 2>/dev/null; then noparity=1; fi
for unit in hs-bulk-sync.service hs-bulk-scrub.service; do
  awk -F'\t' -v u="$unit" -v np="$noparity" '$1 == u { print "job\t" $1 "\t" (np ? "noparity" : $5) "\t" $4 "\t" $3 }' <<<"$jobs"
done

# --- upload cache
cache=$(sed -n 's/^.*On the SSD pool: *//p' "$tmp/cache" | head -n 1 || true)
if [ -n "$cache" ]; then
  pct=$(sed -n 's/.*(\([0-9.]*\)%).*/\1/p' <<<"$cache")
  printf 'cache\t%s\t%s\n' "$cache" "${pct:-0}"
fi

# --- disk health: the WATCH and BAD disks of disk-health --list (name first, verdict in the fifth field)
smart=$(cat "$tmp/smart")
if [ -n "$smart" ]; then
  awk -F'\t' 'NF >= 5 { n++; if ($5 == "WATCH" || $5 == "BAD") f = f (f == "" ? "" : ",") $1 " " $5 } END { printf "smart\t%d\t%s\n", n, f }' <<<"$smart"
fi

# --- instances
inst=$(cat "$tmp/inst")
if [ -n "$inst" ]; then
  awk '{ n++; if ($1 == "RUNNING") r++ } END { printf "instances\t%d\t%d\n", r, n }' <<<"$inst"
fi

# --- the hottest disk (monitor.sh --disks: name, bytes, kind, role, temperature ...)
disks=$(cat "$tmp/disks")
awk -F'\t' '$5 ~ /^[0-9]+$/ && $5 + 0 > best { best = $5 + 0; name = $1 } END { if (name != "") printf "hottest\t%s\t%d\n", name, best }' <<<"$disks"

# --- the last disk event
ev=${HS_DISK_EVENTS:-$state/disk-events}
if [ -s "$ev" ]; then
  tail -n 1 "$ev" | awk -F'\t' '{ printf "event\t%s\t%s", $1, $2; for (i = 3; i <= NF; i++) printf " %s", $i; printf "\n" }'
fi
exit 0
